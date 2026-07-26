#!/usr/bin/env bash
#
# transport.sh — 配管抽象レイヤー（依存の局所化）
#
# このファイルは「reviewer にテキストを渡し、構造化結果（JSON）を受け取る」ことだけを
# 抽象化する。xrev のコア（review-loop 等）は本ファイルの公開関数しか呼ばない。
#
#   公開関数:
#     xrev_transport_review <payload_text>   # stdout に reviewer の JSON を出力
#
# 【重要・設計上の不変条件】
#   cmux 依存はこのファイルだけに存在させる。将来 `codex exec` 方式や別エージェントへ
#   差し替えるときは、XREV_TRANSPORT で実装を切り替えるか、本ファイルの cmux_* 関数だけを
#   書き換えれば済むようにする。review-loop / finalize 等に cmux コマンドを漏らさないこと。
#
# 【実機検証が必要な箇所（手順9）】
#   cmux は「ペインのタイトル名」で send/read-screen の宛先を直接指定できない（宛先は
#   surface ref/id/index のみ）。そこで命名規約方式は「list 系コマンドでタイトルから
#   surface ref を動的解決する」形で実装している。Codex を再起動して履歴を切っても
#   タイトルが不変なら都度解決できる、という設計判断 1.3 の意図は保たれる。
#   ただし list 系コマンド名・JSON 形状・rename での title 反映は cmux バージョン依存で
#   揺れるため、_cmux_resolve_surface() を実機で最優先検証すること。
#
set -uo pipefail

# ── 設定読み込み ─────────────────────────────────────────────────────────────
# XREV_CONFIG が未指定なら プラグイン同梱の既定 config を使う。
_xrev_script_dir() {
  cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd
}
: "${XREV_CONFIG:=${CLAUDE_PLUGIN_ROOT:-$(_xrev_script_dir)/..}/config/xrev.default.json}"

# config から 1 値を取り出す（jq 非依存・python3 で読む）。
# 使い方: val=$(_cfg key default)
_cfg() {
  local key="$1" default="${2:-}"
  python3 - "$XREV_CONFIG" "$key" "$default" <<'PY' 2>/dev/null || printf '%s' "$default"
import json, sys
cfg_path, key, default = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(cfg_path) as f:
        cfg = json.load(f)
    v = cfg.get(key, default)
    if isinstance(v, bool):
        print("true" if v else "false")
    elif isinstance(v, (list, dict)):
        print(json.dumps(v))
    else:
        print(v)
except Exception:
    print(default)
PY
}

_log() { printf '[xrev/transport] %s\n' "$*" >&2; }

# ── 数値設定の共通バリデータ ─────────────────────────────────────────────────
# env/config 由来の数値は、bash 算術式 (( )) に入れる前に必ずここを通す。
# 理由:
#   1) bash 算術は `x[$(コマンド)]` のような値を渡すとコマンド実行が起きる（インジェクション）。
#      生の値を絶対に算術へ渡さないため、正規表現検証を通過した文字列だけを算術評価する。
#   2) `^[0-9]+$` だけの検証では 64bit を超える巨大値（20桁など）が算術でオーバーフローしうる。
#      桁数を {1,10} に制限してから算術へ渡すことでオーバーフローを regex 段階で排除する。
#   3) 範囲外・非数値は可用性優先で既定値へフォールバックし、stderr に1行警告する（stdout は汚さない）。
#
# 使い方: val="$(_xrev_uint "$raw" "$min" "$max" "$def" "設定名")"
_xrev_uint() {
  local v="$1" min="$2" max="$3" def="$4" name="$5"
  if [[ "$v" =~ ^[0-9]{1,10}$ ]] && (( v >= min && v <= max )); then
    printf '%s' "$v"
    return 0
  fi
  _log "${name} が不正です（値='${v}'）。既定 ${def} を使います。"
  printf '%s' "$def"
}

# 環境変数で上書きできる設定（テスト・運用都合）
REVIEWER_PANE_TITLE="${XREV_REVIEWER_PANE_TITLE:-$(_cfg reviewer_pane_title 'Review Codex')}"
# config の reviewer 値（バイナリ名。既定 codex）。主従反転プリセット（primary=codex/reviewer=claude）
# でも同じ経路で解決できるよう、_xrev_reviewer_bin の解決基準として使う（C1）。
REVIEWER="$(_cfg reviewer 'codex')"
# 送信前の安全ゲートで「宛先サーフェスで動いているべきプロセス名」（既定 codex）。
# プロセス証明: cmux top でこのプロセスが対象サーフェスの直下で動いていることを確認する。
REVIEWER_PROCESS="${XREV_REVIEWER_PROCESS:-$(_cfg reviewer_process 'codex')}"
# 安全側既定の opt-in。CMUX_SURFACE_ID 未注入時のみグローバル解決を許す / 明示サーフェスの別WS送信を許す。
ALLOW_GLOBAL_RESOLVE="${XREV_ALLOW_GLOBAL_RESOLVE:-$(_cfg allow_global_resolve 'false')}"
ALLOW_CROSS_WS="${XREV_ALLOW_CROSS_WS:-$(_cfg allow_cross_ws 'false')}"
# reviewer ペインの自動生成（create-if-missing）。ask(既定)/auto/off。生成の起動確認・競合待ちの上限秒。
REVIEWER_AUTOCREATE="${XREV_REVIEWER_AUTOCREATE:-$(_cfg reviewer_autocreate 'ask')}"
# 以下は数値設定。_xrev_uint で「正整数 + キー別上限 + 桁数上限」を検証してから使う。
# 範囲外・非数値は既定へフォールバックし stderr へ警告する（根拠・詳細は references/protocol.md）。
CREATE_TIMEOUT="$(_xrev_uint "${XREV_REVIEWER_CREATE_TIMEOUT_SECONDS:-$(_cfg reviewer_create_timeout_seconds 30)}" 1 600 30 'reviewer_create_timeout_seconds')"
# wire（1物理行）の文字数上限（fail closed）。
WIRE_MAX_CHARS="$(_xrev_uint "${XREV_WIRE_MAX_CHARS:-$(_cfg wire_max_chars 64000)}" 1000 1000000 64000 'wire_max_chars')"
READ_LINES="$(_xrev_uint "${XREV_READ_SCREEN_LINES:-$(_cfg read_screen_lines 400)}" 10 10000 400 'read_screen_lines')"
SETTLE_SECS="$(_xrev_uint "${XREV_SEND_SETTLE_SECONDS:-$(_cfg send_settle_seconds 2)}" 0 60 2 'send_settle_seconds')"
RESP_TIMEOUT="$(_xrev_uint "${XREV_RESPONSE_TIMEOUT_SECONDS:-$(_cfg response_timeout_seconds 180)}" 1 3600 180 'response_timeout_seconds')"
# 最小 1 秒（0 だと応答待ちが busy-loop 化するため 0 は許可しない）。
RESP_POLL="$(_xrev_uint "${XREV_RESPONSE_POLL_SECONDS:-$(_cfg response_poll_seconds 3)}" 1 60 3 'response_poll_seconds')"

# reviewer の JSON 応答を画面から確実に切り出すためのセンチネル。
# Codex には「この 2 行で JSON を挟んで返せ」と指示し、画面ノイズから機械的に抽出する。
SENTINEL_BEGIN='===XREV-JSON-BEGIN==='
SENTINEL_END='===XREV-JSON-END==='

# ── cmux 配管（ここだけが cmux に依存）─────────────────────────────────────────
#
# 【重要・実行コンテキスト】
#   cmux のソケットは認証が要る。認証情報（CMUX_SOCKET_PASSWORD 等）と CMUX_SOCKET_PATH /
#   CMUX_SURFACE_ID は「cmux ペイン内のシェル」で自動注入される。したがって xrev（primary）は
#   cmux ペインの中で動かすこと。cmux の外（通常のターミナル）から実行するとソケットに弾かれる
#   （Broken pipe）。外部から動かす必要がある場合は CMUX_SOCKET_PASSWORD を明示する。

# cmux バイナリの解決:
#   XREV_CMUX_BIN > PATH 上の cmux（ペイン内なら自動で通る）> アプリ同梱の絶対パス
_resolve_cmux_bin() {
  if [[ -n "${XREV_CMUX_BIN:-}" ]]; then printf '%s' "$XREV_CMUX_BIN"; return; fi
  if command -v cmux >/dev/null 2>&1; then printf 'cmux'; return; fi
  local app="/Applications/cmux.app/Contents/Resources/bin/cmux"
  [[ -x "$app" ]] && { printf '%s' "$app"; return; }
  printf 'cmux'  # 最後の手段（見つからなくてもエラーメッセージは _cmux_preflight で出す）
}
CMUX_BIN="$(_resolve_cmux_bin)"

# cmux 呼び出しの一元ラッパ（差し替え点を1箇所に）
_cmux() { "$CMUX_BIN" "$@"; }

# 接続前チェック。ping が通らなければ実行コンテキストの問題を明示して止める。
_cmux_preflight() {
  if ! command -v "$CMUX_BIN" >/dev/null 2>&1 && [[ ! -x "$CMUX_BIN" ]]; then
    _log "cmux CLI が見つかりません。cmux ペイン内で実行するか、XREV_CMUX_BIN で絶対パスを指定してください。"
    return 30
  fi
  if ! _cmux ping >/dev/null 2>&1; then
    _log "cmux ソケットに接続できません（ping 失敗）。"
    _log "xrev は cmux ペインの中で実行してください（外部ターミナルからは認証情報が無く接続できません）。"
    _log "外部から動かす場合は CMUX_SOCKET_PASSWORD（または --password）を設定してください。"
    return 31
  fi
  return 0
}

# reviewer ペインの surface ref をタイトルから解決する。
# 解決順:
#   1) XREV_REVIEWER_SURFACE が指定されていればそれを優先（実機デバッグ用の明示指定）
#   2) `cmux tree --all --json` から、タイトルが一致する「サーフェス」の ref を引く
# 解決できなければ非ゼロで失敗する（暴走防止：宛先不明のまま送らない）。
#
# 実機知見:
#   - 全ペイン/ワークスペース横断で探すため tree --all を使う（list-pane-surfaces は
#     呼び出し元ペインのサーフェスしか返さない）。
#   - タイトルには実行中スピナー等の装飾接頭辞が付く（例 "⠂ Review Codex"）。
#     先頭の非単語記号を正規化で除去し、完全一致 → 部分一致の順で照合する。
#   - サーフェスは ref が "surface:" で始まり title を持つ object のみを対象にする
#     （workspace/pane の ref を誤って拾わないため）。
# 純粋関数（cmux 非依存・単体テスト可能）:
#   cmux の tree/list JSON 文字列とタイトルから、一致するサーフェスの ref を解決する。
#   $1 = 探すタイトル, $2 = JSON 文字列。成功時 ref を stdout、失敗時に非ゼロ。
#   exit: 0=解決 / 4=JSON不正 / 5=未検出 / 6=複数一致(曖昧)。
_resolve_surface_from_json() {
  local title="$1" listing="$2"
  # JSON はヒアドキュメント stdin と競合するため環境変数 XREV_LISTING で渡す。
  XREV_LISTING="$listing" python3 - "$title" <<'PY'
import json, os, re, sys
raw = os.environ.get("XREV_LISTING", "")
try:
    data = json.loads(raw)
except Exception:
    sys.exit(4)

def norm(s):
    # 小文字化 → 前後空白除去 → 先頭の非単語記号(スピナー等)と続く空白を除去
    s = (s or "").strip().lower()
    s = re.sub(r'^[\W_]+', '', s)
    return s.strip()

want = norm(sys.argv[1])

# tree/list いずれの形状でも、ネストを総当たりで surface object だけ集める。
# surface object = ref が "surface:" で始まり、title(str) を持つ dict。
surfaces = []  # (title_normalized, ref)
def walk(obj):
    if isinstance(obj, list):
        for x in obj:
            walk(x)
    elif isinstance(obj, dict):
        ref = obj.get("ref")
        title = obj.get("title")
        if isinstance(ref, str) and ref.startswith("surface:") and isinstance(title, str):
            surfaces.append((norm(title), ref))
        for v in obj.values():
            if isinstance(v, (list, dict)):
                walk(v)
walk(data)

# 1) 完全一致（正規化後）
for t, r in surfaces:
    if t == want:
        print(r); sys.exit(0)
# 2) 部分一致（装飾やサフィックスを許容）
matches = [(t, r) for t, r in surfaces if want and want in t]
if len(matches) == 1:
    print(matches[0][1]); sys.exit(0)
if len(matches) > 1:
    # 複数一致は曖昧。誤送信を避けるため候補を stderr に出して失敗。
    sys.stderr.write("[xrev/transport] タイトル '%s' に複数のサーフェスが一致: %s\n"
                     % (sys.argv[1], ", ".join("%s(%s)" % (r, t) for t, r in matches)))
    sys.exit(6)
sys.exit(5)
PY
}

# ── Phase1: 同一ワークスペース・スコープの宛先解決（誤配送防止・@xrev 承認設計）──────
#
# 要点（クロスレビュー収束済み）:
#   - 呼び出し元(primary)の CMUX_SURFACE_ID(UUID) で「同一ワークスペース」に限定して解決する。
#     複数WSに同名 "Review Codex" があっても別WSの Codex へ誤配送しない（実機で観測したバグの根絶）。
#   - active/focused では判定しない（フォーカスは他WSへ移動しうるため不安定）。
#   - reviewer の「役割」識別根拠はタイトル一致 or 明示サーフェス指定のみ（プロセス名での自動採用はしない）。
#   - 解決できなければ暴走防止のため必ず fail closed。
#
# 純粋関数（cmux 非依存・単体テスト可能）。tree(--id-format both) JSON と caller UUID から、
# 呼び出し元と同一WS内でタイトル一致する surface を1件に決める。
#   入力: $1=タイトル, env XREV_LISTING=tree JSON, env XREV_CALLER=caller surface UUID
#   出力(stdout): "<surface_ref>\t<surface_uuid>\t<workspace_id>"
#   exit: 0=決定 / 4=JSON不正 / 5=同一WS内に該当なし / 6=同一WS内で曖昧 / 7=caller WS を特定不能
_resolve_ws_scoped() {
  XREV_LISTING="${XREV_LISTING:-}" XREV_CALLER="${XREV_CALLER:-}" python3 - "$1" <<'PY'
import json, os, re, sys
raw = os.environ.get("XREV_LISTING", "")
caller = (os.environ.get("XREV_CALLER", "") or "").lower()
try:
    data = json.loads(raw)
except Exception:
    sys.exit(4)
def norm(s):
    s = (s or "").strip().lower()
    s = re.sub(r'^[\W_]+', '', s)
    return s.strip()
def gid(o):
    for k in ("uuid", "id", "uid"):
        v = o.get(k)
        if v:
            return str(v).lower()
    return None
want = norm(sys.argv[1])
rows = []  # (workspace_node, surface_node)
def walk(o, ws=None):
    if isinstance(o, dict):
        ref = str(o.get("ref", ""))
        cur = o if ref.startswith("workspace:") else ws
        if ref.startswith("surface:") and isinstance(o.get("title"), str):
            rows.append((cur, o))
        for v in o.values():
            if isinstance(v, (list, dict)):
                walk(v, cur)
    elif isinstance(o, list):
        for x in o:
            walk(x, ws)
walk(data)
if not caller:
    sys.exit(7)
# caller の所属 workspace を UUID 一致で特定（active/focused は使わない）
caller_ws = None
for ws, s in rows:
    if gid(s) == caller:
        caller_ws = ws
        break
if caller_ws is None:
    sys.exit(7)
ws_id = gid(caller_ws) or str(caller_ws.get("ref", "")) if caller_ws else ""
# 同一WS・caller自身を除外した候補からタイトル照合（完全一致 → 部分一致）
same = [s for ws, s in rows if ws is caller_ws and gid(s) != caller]
def pick(cands):
    if len(cands) == 1:
        return cands[0], 0
    if len(cands) > 1:
        return None, 6
    return None, -1
chosen, code = pick([s for s in same if norm(s.get("title")) == want])
if code == -1:
    chosen, code = pick([s for s in same if want and want in norm(s.get("title"))])
if code == -1:
    sys.exit(5)
if code != 0:
    sys.exit(code)
print("%s\t%s\t%s" % (chosen.get("ref"), gid(chosen) or "", ws_id))
PY
}

# 純粋関数: tree JSON 内で「ref または UUID」から surface を一意特定し、現在の ref/uuid/workspace を返す。
# 明示指定(ref/uuid どちらでも)・送信直前の同一性再検証の両方で使う。ref指定でも WS 検証を迂回させない。
#   入力: $1=ref または UUID, env XREV_LISTING=tree JSON
#   出力(stdout): "<surface_ref>\t<surface_uuid>\t<workspace_id>"
#   exit: 0=一意特定 / 4=JSON不正 / 5=未発見 / 6=曖昧
_locate_surface() {
  XREV_LISTING="${XREV_LISTING:-}" python3 - "$1" <<'PY'
import json, os, sys
raw = os.environ.get("XREV_LISTING", "")
token = (sys.argv[1] or "").strip().lower()
try:
    data = json.loads(raw)
except Exception:
    sys.exit(4)
def gid(o):
    for k in ("uuid", "id", "uid"):
        v = o.get(k)
        if v:
            return str(v).lower()
    return None
hits = []
def walk(o, ws=None):
    if isinstance(o, dict):
        ref = str(o.get("ref", ""))
        cur = o if ref.startswith("workspace:") else ws
        if ref.startswith("surface:") and token and (ref.lower() == token or gid(o) == token):
            ws_id = (gid(cur) or str(cur.get("ref", ""))) if cur else ""
            hits.append((ref, gid(o) or "", ws_id))
        for v in o.values():
            if isinstance(v, (list, dict)):
                walk(v, cur)
    elif isinstance(o, list):
        for x in o:
            walk(x, ws)
walk(data)
if not hits:
    sys.exit(5)
if len(hits) > 1:
    sys.exit(6)
print("%s\t%s\t%s" % hits[0])
PY
}

# 純粋関数: cmux top の TSV から、指定 surface ref の「直下プロセス」を列挙する。
# top の行(TSV): cpu, mem, count, kind, id, parent, name。kind=process かつ parent=surface ref が直下。
#   入力: $1=surface ref, env XREV_TOP=top TSV / 出力: "PID<TAB>name" を1行ずつ
# PID(5列目)も返すのが要点。cmux の name 列は実行ファイル名とは限らない（実機で Claude Code が
# "2.1.220" というバージョン文字列で報告される）ため、プロセス同定は PID 経由で ps に委ねる。
_top_surface_processes() {
  XREV_TOP="${XREV_TOP:-}" python3 - "$1" <<'PY'
import os, sys
ref = sys.argv[1]
for line in os.environ.get("XREV_TOP", "").splitlines():
    p = line.split("\t")
    if len(p) < 7:
        continue
    if p[3] == "process" and p[5] == ref:
        print("%s\t%s" % (p[4], p[6]))
PY
}

# ── cmux 配管ラッパ（uuid 付き tree / プロセス付き top）──────────────────────────
_cmux_tree_uuids() { _cmux tree --all --json --id-format both 2>/dev/null; }
_cmux_top_processes() { _cmux top --all --processes --format tsv 2>/dev/null; }

# 自分(呼び出し元)のタブタイトルを設定する。reviewer 起動ヘルパが規約タイトルを付けるために使う。
# cmux 依存をここ(transport.sh)に閉じるため、ヘルパは直接 cmux を叩かず本関数/サブコマンド経由で呼ぶ。
_cmux_set_title() {
  local title="$1"
  [[ -n "${CMUX_SURFACE_ID:-}" ]] || { _log "CMUX_SURFACE_ID が無いためタイトル設定できません（cmux ペイン内で実行してください）。"; return 31; }
  # rename-tab も workspace 文脈が要る場合がある（短縮 ref/uuid 単独で "Tab not found" になる実機知見）。
  # 自分のペインのリネームなので CMUX_WORKSPACE_ID が注入されていれば併せて渡す。
  local addr=(--surface "$CMUX_SURFACE_ID")
  [[ -n "${CMUX_WORKSPACE_ID:-}" ]] && addr=(--workspace "$CMUX_WORKSPACE_ID" "${addr[@]}")
  _cmux rename-tab "${addr[@]}" "$title"
}

# ── 参照モード(Phase2): 決定論的 diff ハッシュ ───────────────────────────────────
#
# 参照モードでは diff 本文を送らず、reviewer に「自分で diff を取得してレビュー」させる。primary と
# reviewer が「同一の変更を見ている」ことを、**固定 invocation の diff 生バイト列の sha256** で照合する
# （パス比較=symlink/submodule に弱い、を避ける。別リポ/別worktreeなら自動で不一致→inline へフォールバック）。
#
# 【重要】下の invocation は primary/reviewer が**一字一句同一**に実行すること。非決定性
# （色/外部diff/textconv/rename/prefix/algorithm/ロケール/設定注入/CRLF/pager）を固定・除去する。
# range は曖昧さ回避のため**解決済み OID** を渡すのが望ましい（既定 HEAD。ブランチは <baseOID>...<headOID>）。
#   使い方: hash="$(xrev_diff_hash "$range")"
# 設定注入の無効化（GIT_CONFIG_KEY_/VALUE_* は GIT_CONFIG_COUNT を unset すると無視される）。
# system/global/XDG config は GIT_CONFIG_SYSTEM=/dev/null / GIT_CONFIG_GLOBAL=/dev/null / GIT_CONFIG_NOSYSTEM で
# 明示無効化する（unset だけでは標準の読込を止められないため）。primary/reviewer はこの env ごと一字一句同一に実行。
# 【単一の真実源】primary も reviewer も **この `transport.sh diff-hash <range>` を実行**して diff_hash を得る
# （手書き invocation の同期ズレを無くす）。下の DOC は透明性のための表記で、関数と一字一句同一に保つこと。
XREV_DIFF_HASH_DOC='env -u GIT_EXTERNAL_DIFF -u GIT_PAGER -u GIT_CONFIG -u GIT_CONFIG_COUNT -u GIT_DIFF_OPTS -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 LC_ALL=C git --no-pager -c core.autocrlf=false -c core.quotepath=false -c diff.noprefix=false -c diff.mnemonicPrefix=false -c diff.renames=false -c diff.external= -c diff.algorithm=myers diff --no-color --no-ext-diff --no-textconv --full-index --binary <range>  | (raw stdout を sha256)'
xrev_diff_hash() {
  local range="${1:-HEAD}"
  # pipefail（本スクリプトで設定済み）により git 失敗時はパイプラインが非ゼロを返す。
  env -u GIT_EXTERNAL_DIFF -u GIT_PAGER -u GIT_CONFIG -u GIT_CONFIG_COUNT -u GIT_DIFF_OPTS \
      -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 LC_ALL=C \
    git --no-pager -c core.autocrlf=false -c core.quotepath=false -c diff.noprefix=false \
      -c diff.mnemonicPrefix=false -c diff.renames=false -c diff.external= -c diff.algorithm=myers \
      diff --no-color --no-ext-diff --no-textconv --full-index --binary "$range" 2>/dev/null \
    | python3 -c 'import sys,hashlib; sys.stdout.write(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
}

# reviewer surface を解決する（同一WSスコープ・fail closed）。
# 出力(stdout): surface ref。付随情報をグローバルに格納:
#   _XREV_RES_UUID / _XREV_RES_WS / _XREV_RES_PATH(explicit|same_ws|global)
# exit: 0=解決 / 3=一覧取得不可 / 10=同一WS内に該当なし / 15=WS不整合/未特定 / 16=同一WS内で曖昧
_cmux_resolve_surface() {
  _XREV_RES_REF=""; _XREV_RES_UUID=""; _XREV_RES_WS=""; _XREV_RES_PATH=""; _XREV_RES_SAMEWS=0
  local tree; tree="$(_cmux_tree_uuids)"
  [[ -n "$tree" ]] || { _log "cmux tree（--id-format both）を取得できません"; return 3; }

  # 1) 明示指定（最優先）。ref/uuid のどちらで指定されても tree 内で一意特定し、WS 検証を迂回させない。
  if [[ -n "${XREV_REVIEWER_SURFACE:-}" ]]; then
    _XREV_RES_PATH="explicit"
    local loc lrc
    loc="$(XREV_LISTING="$tree" _locate_surface "$XREV_REVIEWER_SURFACE")"; lrc=$?
    if (( lrc != 0 )); then
      _log "明示サーフェス($XREV_REVIEWER_SURFACE)を tree 内に一意特定できません（code=${lrc}。誤配送防止のため中止）。"
      return 15
    fi
    _XREV_RES_REF="$(printf '%s' "$loc" | cut -f1)"
    _XREV_RES_UUID="$(printf '%s' "$loc" | cut -f2)"
    _XREV_RES_WS="$(printf '%s' "$loc" | cut -f3)"
    # cross-WS 非許可（既定厳格）: caller を特定し、同一WSであることを必須にする（不明はすべて fail closed）。
    if [[ "$ALLOW_CROSS_WS" != "true" ]]; then
      if [[ -z "${CMUX_SURFACE_ID:-}" ]]; then
        _log "明示サーフェスの同一WS検証に CMUX_SURFACE_ID が必要です（cmux ペイン内で実行 / または XREV_ALLOW_CROSS_WS=true）。"
        return 15
      fi
      local cloc crc caller_ws
      cloc="$(XREV_LISTING="$tree" _locate_surface "$CMUX_SURFACE_ID")"; crc=$?
      if (( crc != 0 )); then
        _log "呼び出し元(CMUX_SURFACE_ID)を tree 内に特定できません（中止）。"; return 15
      fi
      caller_ws="$(printf '%s' "$cloc" | cut -f3)"
      if [[ -z "$_XREV_RES_WS" || -z "$caller_ws" || "$caller_ws" != "$_XREV_RES_WS" ]]; then
        _log "明示サーフェス($XREV_REVIEWER_SURFACE)が呼び出し元と別/不明ワークスペースです（cross-WS は XREV_ALLOW_CROSS_WS=true のみ）。"
        return 15
      fi
      _XREV_RES_SAMEWS=1
    fi
    printf '%s' "$_XREV_RES_REF"; return 0
  fi

  # 2) 同一WSスコープ解決（CMUX_SURFACE_ID 必須）
  if [[ -n "${CMUX_SURFACE_ID:-}" ]]; then
    local out rc
    out="$(XREV_LISTING="$tree" XREV_CALLER="$CMUX_SURFACE_ID" _resolve_ws_scoped "$REVIEWER_PANE_TITLE")"; rc=$?
    case "$rc" in
      0) _XREV_RES_PATH="same_ws"; _XREV_RES_SAMEWS=1
         _XREV_RES_REF="$(printf '%s' "$out" | cut -f1)"
         _XREV_RES_UUID="$(printf '%s' "$out" | cut -f2)"
         _XREV_RES_WS="$(printf '%s' "$out" | cut -f3)"
         printf '%s' "$_XREV_RES_REF"; return 0 ;;
      6) _log "同一ワークスペース内に '$REVIEWER_PANE_TITLE' が複数あり曖昧です。"; return 16 ;;
      5) _log "同一ワークスペース内に '$REVIEWER_PANE_TITLE' が見つかりません（reviewer を起動しタイトルを設定してください）。"; return 10 ;;
      7) _log "呼び出し元の所属ワークスペースを特定できません（CMUX_SURFACE_ID が tree に見つからない）。"; return 15 ;;
      *) _log "宛先解決に失敗しました（rc=${rc}）。"; return 10 ;;
    esac
  fi

  # 3) CMUX_SURFACE_ID 未注入時のみ、明示 opt-in でグローバル解決（同一WS保証なし・危険）
  if [[ "$ALLOW_GLOBAL_RESOLVE" == "true" ]]; then
    _log "警告: CMUX_SURFACE_ID 未注入のためグローバル解決します（別WSへ配送する恐れ）。"
    local ref
    ref="$(_resolve_surface_from_json "$REVIEWER_PANE_TITLE" "$tree")" || return 10
    _XREV_RES_PATH="global"; _XREV_RES_REF="$ref"; printf '%s' "$ref"; return 0
  fi
  _log "CMUX_SURFACE_ID が無く同一WS解決ができません。cmux ペイン内で実行するか XREV_REVIEWER_SURFACE を明示指定してください（やむを得ない場合のみ XREV_ALLOW_GLOBAL_RESOLVE=true）。"
  return 15
}

# cmux の宛先指定引数を _XREV_ADDR 配列に構築する（実機知見・@xrev/Codex 診断）。
# read-screen/send/send-key は短縮 ref だけだと「呼び出し元と別ワークスペースの文脈」で surface を
# TerminalPanel として解決できず "Surface is not a terminal" になる。**workspace UUID + surface UUID** で
# 指定すると確実に解決できる（実機確認: ref/surfaceUUID 単独は失敗、workspace+surfaceUUID は成功）。
# UUID が無い経路（global フォールバック・テスト）は従来どおり ref を使う。
_xrev_build_addr() {
  local fallback_ref="$1"
  if [[ -n "${_XREV_RES_WS:-}" && -n "${_XREV_RES_UUID:-}" ]]; then
    _XREV_ADDR=(--workspace "$_XREV_RES_WS" --surface "$_XREV_RES_UUID")
  else
    _XREV_ADDR=(--surface "$fallback_ref")
  fi
}

# read-screen の成否で端末性を判定（cmux 依存）。端末でないこと(=14)と宛先消失(=15)を分離する。
# 重要: tty フィールドは見ない（PTY 判定として不正確。read-screen の成否が唯一の受入条件）。
#   usable: 成功（空でも可） / non_terminal: "not a terminal" / gone: "not found"(消失) / transient: 一時失敗
_probe_terminal_usable() {
  local surface="$1" err rc
  _xrev_build_addr "$surface"
  err="$(_cmux read-screen "${_XREV_ADDR[@]}" --lines 1 2>&1 1>/dev/null)"; rc=$?
  if (( rc == 0 )); then printf 'usable'; return 0; fi
  if printf '%s' "$err" | grep -qiE 'not a terminal'; then printf 'non_terminal'; return 0; fi
  if printf '%s' "$err" | grep -qiE 'not[_ ]?found'; then printf 'gone'; return 0; fi
  printf 'transient'
}

# ps スナップショット取得（cmux 非依存の外部コマンド。テストではスタブする）。
#   入力(stdin): PID を1行1件 / 出力: "pid pgid tpgid comm" を1行1件（ps の既定区切り＝空白）
# 【注意】ps は「一部の PID が消えていても残りを出して exit 0」を返す（実機確認）。したがって
# 呼び出し側で「要求した PID が過不足なく返ったか」を必ず検証すること（欠落を完全なスナップショットと
# 誤認しないため）。ここでは取得のみを行い、判定は _decide_foreground_owner に委ねる。
_ps_snapshot() {
  local args=() p
  while IFS= read -r p; do
    [[ -n "$p" ]] && args+=(-p "$p")
  done
  (( ${#args[@]} )) || return 1
  ps -o pid=,pgid=,tpgid=,comm= "${args[@]}" 2>/dev/null
}

# 【共有の実体・その1】指定 PID の実 argv を sysctl(KERN_PROCARGS2) から取得する python 関数定義
# （`_procargs2(pid)` 1個）だけを stdout に返す（副作用なし・実行はしない）。
#
# 【指摘2への対処】従来は `ps -o pid=,args=` が返す「引数を空白で連結した表示用文字列」を後段で
# 再度空白分割して argv を復元していた。しかし ps の args= はシェルが表示するための整形済み文字列に
# すぎず、argv の要素境界を保持しない。値自体に空白を含む単一 argv 要素（cmux が claude へ注入する
# `--settings <JSON>` 等。probe-report.md R1 で実測）の内部に `--permission-mode plan` のような
# フラグ文字列が現れると、空白分割はそれを独立した引数と誤認しうる（安全ポリシーの誤判定に直結する
# high 指摘）。ここでは表示用文字列を経由せず、カーネルが保持する実 argv を sysctl(KERN_PROCARGS2)
# で直接取得する（macOS 専用。`ps` 自身も内部でこの sysctl を使っており、境界情報を持つのは
# カーネル側だけである）。
#
# 【指摘1（2巡目）への対処・この関数を共有する理由】`_procargs2` が返す argv は要素ごとに任意の
# バイト列（空白・TAB・改行を含む）を持ちうる。これを呼び出し側が改行区切りの文字列へ変換して
# stdout へ返すと、argv 要素**自体**に生の改行が含まれる場合に再び境界を失う（1要素が2行に
# 分割され、後段の bash `while read` が別々の argv と誤認する）。そこで「PID 受領 → argv 取得 →
# 安全ポリシー判定」を単一の python プロセス内で完結させる `_xrev_verify_foreground_policy` /
# `_verify_reviewer_launch_args`（いずれも下方で定義）がこの関数定義をそのまま埋め込んで使う。
# 自己診断用の一括スナップショット（`_xrev_procargs2_snapshot`。JSON を経由するため境界保持は
# 維持されるが、そこから先の bash 側再構成はしない用途にのみ使う）もこれを共有し、判定原理を
# 二重管理しない。
_xrev_procargs2_py_src() {
  cat <<'PY'
import ctypes, ctypes.util

def _procargs2(pid):
    if sys.platform != "darwin":
        return None
    libc_path = ctypes.util.find_library("c") or "libSystem.dylib"
    try:
        libc = ctypes.CDLL(libc_path, use_errno=True)
    except OSError:
        return None
    CTL_KERN, KERN_PROCARGS2 = 1, 49
    mib = (ctypes.c_int * 3)(CTL_KERN, KERN_PROCARGS2, pid)
    size = ctypes.c_size_t(0)
    # 1回目: 必要バッファサイズだけを問い合わせる。
    if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0:
        return None
    if size.value < 4:
        return None
    # 問い合わせから実取得までの間にプロセスの argv は変化しない前提だが、念のため余裕を持たせる。
    size = ctypes.c_size_t(size.value + 4096)
    buf = ctypes.create_string_buffer(size.value)
    size2 = ctypes.c_size_t(size.value)
    if libc.sysctl(mib, 3, buf, ctypes.byref(size2), None, 0) != 0:
        return None
    n = size2.value
    if n < 4:
        return None
    # レイアウト: 先頭4バイトが argc（native int）、続いて exec_path(NUL終端) + NUL パディング、
    # その後 argc 個の NUL 区切り argv 文字列が続く（Apple 公開情報無し・実機/複数実装で確認済みの
    # 既知レイアウト）。
    argc = ctypes.cast(buf, ctypes.POINTER(ctypes.c_int))[0]
    data = buf.raw[4:n]
    nul = data.find(b"\x00")
    if nul < 0:
        return None
    data = data[nul:]
    j = 0
    while j < len(data) and data[j] == 0:
        j += 1
    data = data[j:]
    argv = []
    for _ in range(argc):
        nul = data.find(b"\x00")
        if nul < 0:
            return None
        try:
            argv.append(data[:nul].decode("utf-8"))
        except UnicodeDecodeError:
            return None
        data = data[nul + 1:]
    return argv
PY
}

# argv スナップショット取得（境界保持・cmux 非依存の外部呼び出し。テストではスタブする）。
# 自己診断（doctor）専用。安全ポリシー判定の入力には使わない（判定は単一プロセス内で完結させる
# `_xrev_verify_foreground_policy` / `_verify_reviewer_launch_args` を使うこと）。
#   入力(stdin): PID を1行1件 / 出力: "<pid><TAB><argvのJSON配列(argv[0]込み)>" を1行1件。
#   取得できない PID（非対象OS・権限不足・ESRCH・パース不能）は出力から省略する
#   （_ps_snapshot と同じ「欠落は呼び出し側が要求PIDとの過不足で検証する」契約）。
# JSON エンコードは制御文字を必ず \uXXXX 形式でエスケープするため、argv 要素に生の TAB/改行が
# 含まれていても出力の行区切り（本関数が使う実 TAB・実改行）と衝突しない。
_xrev_procargs2_snapshot() {
  # 【注意】`python3 - <<'PY' ... PY` は使わない: `-` はスクリプト本体を stdin から読む指定なので、
  # ヒアドキュメントが stdin を占有してしまい、本関数が読むべき PID 一覧（呼び出し側の stdin）が
  # 届かなくなる（_build_framed_line と同じ理由・同じ対処）。プログラム本文を変数化して
  # `python3 -c` へ渡すことで、stdin を PID 一覧のためだけに空ける。
  local prog
  prog="import json, sys
$(_xrev_procargs2_py_src)
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        pid = int(line)
    except ValueError:
        continue
    if pid <= 0:
        continue
    argv = _procargs2(pid)
    if argv is None:
        continue
    sys.stdout.write(\"%d\t%s\n\" % (pid, json.dumps(argv, ensure_ascii=True)))
"
  python3 -c "$prog"
}

# 純粋関数: 「対象 surface でキー入力を受け取るプロセス」が許可名かを判定する。
#   入力: $1=許可名, env XREV_DIRECT="PID<TAB>name" 行群, env XREV_PS=_ps_snapshot 出力
#   出力: 成功時は検出したプロセス名 / 失敗時は拒否理由。exit 0=許可 / 1=拒否（fail closed）
#
# 【判定原理】件数ではなく **tty のフォアグラウンドプロセスグループ** を見る。実機の cmux では
# surface の直下は常に [アプリ, sleep, ログインシェル] の複数件になり「直下が厳密に1件」は原理的に
# 成立しない。一方 pgid == tpgid を満たす直下プロセスはちょうど1件存在し、それが実際にキー入力を
# 受け取るプロセスなので、安全目標（shell へ payload を送り込みコマンド実行される事故の防止）を
# 件数条件より正確に表現できる。素のシェルペインでは shell が前景として検出され従来どおり拒否される。
_decide_foreground_owner() {
  XREV_DIRECT="${XREV_DIRECT:-}" XREV_PS="${XREV_PS:-}" python3 - "$1" <<'PY'
import os, sys

def deny(msg):
    sys.stdout.write(msg)
    sys.exit(1)

def as_int(s):
    try:
        return int(s, 10)
    except ValueError:
        return None

expected = os.path.basename(sys.argv[1])
if not expected:
    deny("許可プロセス名(reviewer_process)が空です")

# 1) cmux top 由来の直下プロセス。PID は正の整数かつ重複なしを要求する。
direct = {}
for line in os.environ.get("XREV_DIRECT", "").splitlines():
    if not line.strip():
        continue
    parts = line.split("\t")
    if len(parts) < 2:
        deny("直下プロセス一覧の形式が不正です")
    pid, name = as_int(parts[0].strip()), parts[1].strip()
    if pid is None or pid <= 0:
        deny("直下プロセスの PID が不正です (%s)" % parts[0].strip())
    if pid in direct:
        deny("直下プロセスの PID が重複しています (%d)" % pid)
    direct[pid] = name
if not direct:
    deny("直下プロセスを特定できません")

# 2) ps 結果。要求 PID と過不足なく一致することを要求する（部分欠落を完全な観測と誤認しない）。
rows = {}
for line in os.environ.get("XREV_PS", "").splitlines():
    if not line.strip():
        continue
    f = line.split(None, 3)
    if len(f) < 4:
        deny("ps 出力の形式が不正です")
    pid, pgid, tpgid = as_int(f[0]), as_int(f[1]), as_int(f[2])
    if pid is None or pgid is None or tpgid is None:
        deny("ps 出力の数値フィールドが不正です")
    if pid in rows:
        deny("ps 出力に PID の重複があります (%d)" % pid)
    rows[pid] = (pgid, tpgid, f[3].strip())
if set(rows) != set(direct):
    missing = sorted(set(direct) - set(rows))
    extra = sorted(set(rows) - set(direct))
    deny("ps の観測が直下プロセスと一致しません（欠落=%s 余剰=%s）" % (missing or "なし", extra or "なし"))

# 3) 全プロセスが同一 tty を共有し、前景プロセスグループが確定していること。
tpgids = {v[1] for v in rows.values()}
if len(tpgids) != 1:
    deny("直下プロセスの制御端末が一致しません（tpgid=%s）" % sorted(tpgids))
tpgid = tpgids.pop()
if tpgid <= 0:
    deny("制御端末の前景プロセスグループを特定できません（tpgid=%d）" % tpgid)

# 4) 前景プロセスグループに属する直下プロセスがちょうど1件であること。
fg = [pid for pid, v in rows.items() if v[0] == tpgid]
if len(fg) != 1:
    names = sorted(os.path.basename(rows[p][2]) for p in fg)
    deny("前景プロセスが一意に定まりません（該当=%d件 %s）" % (len(fg), names or "なし"))

# 5) その1件が許可名であること。ps の comm は絶対パス（ログインシェルは "-/bin/zsh"）で返るため
#    basename 化して比較する。部分一致・引数照合は偽陽性を招くので採らない。
actual = os.path.basename(rows[fg[0]][2])
if actual != expected:
    deny("前景プロセスが '%s' ではありません（実際=%s）" % (expected, actual or "不明"))
sys.stdout.write(actual)
PY
}

# プロセス証明: 対象 surface でキー入力を受け取るプロセスが許可名(REVIEWER_PROCESS)かを検証する。
#   top を検査のたびに取得して鮮度を担保。取得不能・観測不整合・許可名以外はいずれも非ゼロ(=送信拒否)。
# 【重要】この検証は「その瞬間」の観測にすぎない。検査から実際の入力確定(Enter)までの間に codex が
# 終了すれば payload が shell へ渡りうるため、呼び出し側は **Enter の直前を最終ゲート**として
# 再検証すること（xrev_transport_review の (iii-c) を参照）。
# 【観測の取り直し】cmux の surface 直下には周期的に生成・消滅する sleep サイドカーが存在し、top と
# ps の取得時刻がミリ秒単位でずれるだけで「欠落」判定になりうる（実測で発生。docs/cmux-behavior.md
# 参照）。これは判定条件を緩めるのではなく、top/ps を最初から取り直して最大3回までやり直す＝壊れた
# 観測のみを捨てて撮り直す対処であり、検証窓を広げるものではない。_decide_foreground_owner の判定
# 条件（完全一致・前景1件・許可名一致）はそのまま維持する。
_verify_reviewer_process() {
  local surface="$1" top direct ps_out detail attempt
  for attempt in 1 2 3; do
    top="$(_cmux_top_processes)"
    if [[ -z "$top" ]]; then
      detail="cmux top を取得できません（プロセス証明不可）。"
    else
      direct="$(XREV_TOP="$top" _top_surface_processes "$surface")"
      if [[ -z "$direct" ]]; then
        detail="reviewer surface($surface)の直下プロセスを特定できません。"
      else
        ps_out="$(printf '%s\n' "$direct" | cut -f1 | _ps_snapshot)"
        if detail="$(XREV_DIRECT="$direct" XREV_PS="$ps_out" _decide_foreground_owner "$REVIEWER_PROCESS")"; then
          if (( attempt > 1 )); then
            _log "プロセス証明を ${attempt} 回目の試行で確認しました（過渡プロセスの消滅による観測不一致の可能性）。"
          fi
          return 0
        fi
      fi
    fi
    (( attempt < 3 )) && _xrev_sleep 1
  done
  _log "reviewer surface($surface)のプロセス証明に失敗: ${detail}"
  return 1
}

# 純粋関数: 「対象 surface でキー入力を受け取るプロセス（前景プロセス）」を一意に特定し、その
# 実 argv が安全ポリシーを満たすかまでを**単一 python プロセス内**で完結させて判定する
# （既存ペイン採用時の実効検証・`_xrev_verify_reviewer_policy` 用）。foreground 選定の原理は
# `_decide_foreground_owner` と同じ（pgid==tpgid の直下プロセスが一意に決まること・許可名と
# 一致すること）だが、`_decide_foreground_owner` は既存のテスト（test_send_gates.sh）が固定する
# 契約（bool 相当の許可/拒否のみを返す）を持つため、それを変えずに argv も欲しい本用途のために
# 別関数として複製する（意図的な重複。foreground 選定の判定条件は一字一句合わせること）。
#
# 【指摘1（2巡目）への対処】旧実装（`_xrev_foreground_argv`）は特定した前景プロセスの argv を
# JSON から decode した生文字列のまま1行1要素で print し、呼び出し側の bash が `while read` で
# 配列へ再構成していた。argv 要素自体に生の改行が含まれる場合（例: 単一要素
# `--permission-mode\nplan`）、この print → 改行区切りテキスト → while read という往復で境界が
# 再び失われ、実在しない安全フラグ（`--permission-mode` と `plan` という2要素）が現れたかのように
# 誤判定しうる（high 指摘）。ここでは「前景プロセスの特定 → argv 取得(procargs2) → 安全ポリシー
# 判定」までを同一 python プロセス内で完結させ、argv を改行・空白などの区切り文字ベースの形へ
# 変換して bash へ戻すことを一切しない。argv 取得(`_procargs2`)・ポリシー判定
# (`_xrev_check_policy`) はいずれも他経路（`_xrev_verify_effective_policy` /
# `_verify_reviewer_launch_args`）と共有する実体（`_xrev_procargs2_py_src` /
# `_xrev_policy_check_py_src`）を使い、判定リストを二重管理にしない。
#   入力: $1=許可名(reviewer_process。basename を取って前景プロセスの期待名・安全ポリシー種別kind
#         の両方に使う。従来 kind は basename(REVIEWER_PROCESS) と常に同値だったため1引数へ統合する),
#         env XREV_DIRECT="PID<TAB>name" 行群(_top_surface_processes 出力),
#         env XREV_PS="pid pgid tpgid comm" 行群(_ps_snapshot 出力)
#   出力: stdout には何も書かない（exit のみ。_xrev_verify_reviewer_policy の契約をそのまま透過する。
#     不具合Aの教訓により、この関数は成功時に stdout へ何も書いてはならない）。
#   exit 0=前景プロセスを一意特定し、その実 argv が安全ポリシーに合格 /
#   1=特定不能・不一致・不合格（fail closed）
_xrev_verify_foreground_policy() {
  # 【注意】ここで `prog="$(cat <<'PY' ... PY)"` を使わないこと: bash 3.2（macOS既定）は $(...) の
  # 対応括弧探索がヒアドキュメント本文中の不均衡な括弧・引用符で誤爆する（_build_framed_line 参照）。
  # `read -r -d ''` で変数化してから、共有実体（`_xrev_procargs2_py_src` / `_xrev_policy_check_py_src`。
  # いずれも短い関数呼び出しを command substitution するだけなので上記の罠に当たらない）と
  # 文字列連結する。
  local drv
  read -r -d '' drv <<'PY' || true
import os, sys

def as_int(s):
    try:
        return int(s, 10)
    except ValueError:
        return None

expected = os.path.basename(sys.argv[1]) if len(sys.argv) > 1 else ""
if not expected:
    sys.exit(1)

direct = {}
for line in os.environ.get("XREV_DIRECT", "").splitlines():
    if not line.strip():
        continue
    parts = line.split("\t")
    if len(parts) < 2:
        sys.exit(1)
    pid = as_int(parts[0].strip())
    if pid is None or pid <= 0 or pid in direct:
        sys.exit(1)
    direct[pid] = parts[1].strip()
if not direct:
    sys.exit(1)

rows = {}
for line in os.environ.get("XREV_PS", "").splitlines():
    if not line.strip():
        continue
    f = line.split(None, 3)
    if len(f) < 4:
        sys.exit(1)
    pid, pgid, tpgid = as_int(f[0]), as_int(f[1]), as_int(f[2])
    if pid is None or pgid is None or tpgid is None or pid in rows:
        sys.exit(1)
    rows[pid] = (pgid, tpgid, f[3].strip())
if set(rows) != set(direct):
    sys.exit(1)

tpgids = {v[1] for v in rows.values()}
if len(tpgids) != 1:
    sys.exit(1)
tpgid = tpgids.pop()
if tpgid <= 0:
    sys.exit(1)
fg = [pid for pid, v in rows.items() if v[0] == tpgid]
if len(fg) != 1:
    sys.exit(1)
fg_pid = fg[0]
actual = os.path.basename(rows[fg_pid][2])
if actual != expected:
    sys.exit(1)

# 前景プロセスの実 argv を同一プロセス内で取得し、そのまま判定へ渡す（境界保持のまま。
# bash へ一度も戻さない＝改行区切りの再構成を経由しない）。
argv = _procargs2(fg_pid)
if argv is None:
    sys.stderr.write("[xrev/transport] 前景プロセス(pid=%d)の argv を取得できません\n" % fg_pid)
    sys.exit(1)
_err = _xrev_check_policy(expected, argv[1:])
if _err is not None:
    sys.stderr.write("[xrev/transport] 安全ポリシー検証失敗: %s\n" % _err)
    sys.exit(1)
sys.exit(0)
PY
  local prog
  prog="$(_xrev_procargs2_py_src)"$'\n'"$(_xrev_policy_check_py_src)"$'\n'"$drv"
  XREV_DIRECT="${XREV_DIRECT:-}" XREV_PS="${XREV_PS:-}" python3 -c "$prog" "$1"
}

# 既存 reviewer を「採用」する経路（_xrev_classify_reviewer の present 判定・および送信直前の
# xrev_transport_review）の実効ポリシー検証（指摘3）。対象 surface の前景プロセスを特定し、
# `_xrev_verify_foreground_policy`（単一プロセス内で argv 取得〜判定まで完結）で安全ポリシー
# （sandbox=read-only かつ承認=never）が実効に有効かを確認する。従来は前景プロセス名が
# REVIEWER_PROCESS と一致することしか見ておらず、手動起動・旧版の書き込み可能なペインがそのまま
# 採用され得た。
#   入力: $1=surface ref
#   出力: stdout には何も書かない（exit のみ。_xrev_verify_foreground_policy の契約をそのまま透過する。
#     不具合Aの教訓により、この関数は成功時に stdout へ何も書いてはならない — 呼び出し元の
#     xrev_transport_review は stdout が「reviewer の review JSON だけ」という契約を持つため）。
#   exit 0=安全ポリシー確認 / 1=確認できない（fail closed）
_xrev_verify_reviewer_policy() {
  local surface="$1" top direct ps_out
  top="$(_cmux_top_processes)"
  if [[ -z "$top" ]]; then
    _log "cmux top を取得できません（既存 reviewer の安全ポリシー検証不可）。"
    return 1
  fi
  direct="$(XREV_TOP="$top" _top_surface_processes "$surface")"
  if [[ -z "$direct" ]]; then
    _log "reviewer surface($surface)の直下プロセスを特定できません（安全ポリシー検証不可）。"
    return 1
  fi
  ps_out="$(printf '%s\n' "$direct" | cut -f1 | _ps_snapshot)"
  XREV_DIRECT="$direct" XREV_PS="$ps_out" _xrev_verify_foreground_policy "$REVIEWER_PROCESS"
}

# 起動後の実効検証: reviewer 自動生成（_xrev_create_reviewer）が起動したプロセスの実コマンド
# ラインが、安全ポリシー（read-only 強制）を一意に満たしていることを確認する。「起動できた」
# だけでは read-only が実際に効いているかは分からない（引数生成のバグ・cmux send の欠落等でも
# 起動確認自体は通ってしまうため）ので、ここで実プロセスの args を見て機械的に裏取りする。
#
# 【指摘2への対処・旧版】従来は「期待する launch 引数が部分文字列として含まれるか」の判定だったため、
# launch 引数の**後ろ**に危険な引数（例 `-s danger-full-access`）が付いていても、期待した部分
# 文字列さえ含まれていれば通ってしまっていた。ここでは部分文字列判定をやめ、実コマンドラインを
# argv へ分解して `_xrev_check_policy` の意味検証（最終 argv 全体で安全ポリシーが一意に有効か）に通す。
#   入力: $1=surface ref, $2=reviewer 種別（basename。codex/claude）
#   出力: なし（exit のみ）。exit: 0=直下プロセスのいずれかで安全ポリシーの実効を確認できた /
#   1=確認できない（呼び出し側は起動を採用しない＝fail closed）
# 【argv 取得は sysctl(KERN_PROCARGS2) 経由（指摘2・再対処）】以前は「起動確認済みの launch 引数は
# 印字可能ASCIIのみ・空文字列不可という型検証を経ているので、要素自体に空白を含める運用は想定しない」
# という理由で `ps -o args=` の表示文字列を空白分割していた。だがこの理屈は cmux 自身が起動時に
# 追加注入する argv（`--settings <JSON>` 等。probe-report.md R1 で実測）には及ばない — 注入された
# 単一 argv 要素の**値の中**に空白区切りのフラグ文字列が現れると、空白分割はそれを独立した引数と
# 誤認しうる（安全ポリシーの誤判定に直結する high 指摘）。
#
# 【指摘1（2巡目）への対処】以前は procargs2 の結果を「PID<TAB>argvのJSON配列」で受け取ってから
# argv[1:] を bash へ改行区切りで戻し(`_xrev_procargs2_argv_tail`)、`while read` で配列へ再構成して
# いた。argv 要素に生の改行が含まれる場合にこの往復で境界を失う（修正1と同根の high 指摘）。ここでは
# PID の一覧だけを python へ渡し、「argv 取得(procargs2) → 安全ポリシー判定」を候補 PID ごとに同一
# プロセス内で完結させる（いずれか1件が合格すればよい・従来と同じ判定契約）。
_verify_reviewer_launch_args() {
  local surface="$1" kind="$2"
  local top direct
  top="$(_cmux_top_processes)"
  if [[ -z "$top" ]]; then
    _log "cmux top を取得できません（launch 引数の実効検証不可）。"
    return 1
  fi
  direct="$(XREV_TOP="$top" _top_surface_processes "$surface")"
  if [[ -z "$direct" ]]; then
    _log "reviewer surface($surface)の直下プロセスを特定できません（launch 引数の実効検証不可）。"
    return 1
  fi
  local drv
  read -r -d '' drv <<'PY' || true
import sys

kind = sys.argv[1] if len(sys.argv) > 1 else ""
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        pid = int(line)
    except ValueError:
        continue
    if pid <= 0:
        continue
    argv = _procargs2(pid)
    if argv is None:
        continue
    # 直下プロセスは複数あり得て「いずれか1件が合格すればよい」判定なので、他の候補
    # （例: sleep サイドカーやログインシェル）が不合格になるのは正常フローであり、そのたびに
    # 理由を診断ログへ出すとノイズが積み重なる（_xrev_classify_reviewer と同じ理由）。
    if _xrev_check_policy(kind, argv[1:]) is None:
        sys.exit(0)
sys.exit(1)
PY
  local prog
  prog="$(_xrev_procargs2_py_src)"$'\n'"$(_xrev_policy_check_py_src)"$'\n'"$drv"
  printf '%s\n' "$direct" | cut -f1 | python3 -c "$prog" "$kind"
}

# reviewer ペインの最終確定入力（プロンプト送信）。本文（1物理行）を送り終えたあとに呼ぶ。
_cmux_submit() {
  local surface="$1"
  _xrev_build_addr "$surface"
  _cmux send-key "${_XREV_ADDR[@]}" enter >/dev/null 2>&1 || return 7
}

# 「Enter を送らない/これ以上再送しない」と決めたときの共通ログ（汚染ペイン警告一式）。
#   $1=surface, $2=状況説明（呼び出し元ごとに変わるのはこの1行だけ）
# 呼び出し元: (iii-c) 最終ゲート失敗時、および Enter 再送前の再検証失敗時（変更1）。
_xrev_log_tainted_pane() {
  local surface="$1" reason="$2"
  _log "$reason"
  # 【重要】Enter を送らないだけでは安全な終端にならない。送信済みの本文は入力行に残り、
  # 前景が shell に戻っている以上、その後の偶発的な Enter や再送でコマンド実行され得る。
  # かつ Codex の composer は ctrl+u/ctrl+a/ctrl+k/ctrl+w で消去できないことを実機確認済みで
  # （反応するのは backspace の1文字ずつのみ）、xrev には残留を自動破棄する確実な手段が無い。
  # したがってこのペインは**汚染された**ものとして扱い、再利用を禁止する。
  _log "【重要】送信済みの本文が reviewer ペイン($surface)の入力行に残っています。xrev はこれを自動破棄できません。"
  _log "このペインは汚染されたものとして扱ってください: Enter を押さずにペインを閉じ、reviewer を開き直してから再実行してください。"
  _log "（残留したまま再送すると本文が混入します。同じペインを使い回さないでください。）"
}

# reviewer ペインの画面を読み取る（スクロールバック込み）。
_cmux_read_screen() {
  local surface="$1"
  _xrev_build_addr "$surface"
  _cmux read-screen "${_XREV_ADDR[@]}" --scrollback --lines "$READ_LINES" 2>/dev/null
}

# 画面テキストから「妥当な review JSON ブロック」を走査する。
#   $1 = 画面テキスト, $2(任意) = 期待 round_id（指定時はそれを含むブロックのみ採用）。
#   出力: 1行目=妥当ブロック数, 2行目以降=最後の妥当ブロックの中身（正規化 JSON）。
#
# 【実機知見・堅牢化】センチネルの begin/end 対照合には依存しない。理由は2つ:
#   (1) 指示文に書いたセンチネル文字列が画面で折り返され、対照合が壊れて本物の応答を
#       巨大ブロックに飲み込むことがある。
#   (2) スクロールバックに前ラウンドの応答が残る。
# 代わりに「全画面を de-wrap（各行 strip して連結＝TUI 折り返しとガター除去）→ JSON を
# raw_decode で走査 → dict かつ verdict を持ち（round_id 指定時は一致する）ものだけ採用」する。
# 完成した JSON だけが parse できるため、ストリーミング途中の未完成応答も自然に除外される。
_scan_review_blocks() {
  # 画面テキスト（$1、巨大になり得る）は stdin から読む。ヒアドキュメントが stdin を占有して
  # 競合するため、プログラム本文を `read -r -d ''` で変数化し `python3 -c` へ渡して stdin を
  # 空ける。round_id は小さいので従来どおり argv のまま。
  # 【注意】ここで `prog="$(cat <<'PY' ... PY)"` を使わないこと: bash 3.2（macOS既定）は
  # $(...) の対応括弧探索がヒアドキュメント本文の中身（括弧・引用符の個数）まで数えてしまう
  # バグ/仕様があり、本文中の括弧が不均衡な行（Python の複数行文字列連結等）があると
  # 「unexpected EOF while looking for matching」で構文エラーになる。`read -d ''` は
  # command substitution を経由しないため影響を受けない。
  local prog
  read -r -d '' prog <<'PY' || true
import sys, json
text = sys.stdin.read()
expect_rid = sys.argv[1] if len(sys.argv) > 1 else ""

# TUI の折り返し＋ガター字下げを除く（各行 strip して連結）。
dw = "".join(line.strip() for line in text.splitlines())

# 走査上限（暴走・誤検出の防御）。read-screen は行数で有界だが、念のため末尾側のみを対象に
# サイズ上限をかけ、検出件数にも上限を設ける（最新の応答は末尾に出るため末尾優先）。
MAX_SCAN = 500000
MAX_BLOCKS = 200
if len(dw) > MAX_SCAN:
    dw = dw[-MAX_SCAN:]

dec = json.JSONDecoder()
blocks = []
i, n = 0, len(dw)
while i < n:
    if dw[i] != "{":
        i += 1
        continue
    try:
        obj, end = dec.raw_decode(dw, i)
    except Exception:
        i += 1
        continue
    i = end
    if isinstance(obj, dict) and "verdict" in obj:
        # round_id 指定時は一致するものだけ（古い/別ラウンドの誤検出を防ぐ）。
        if expect_rid and str(obj.get("round_id", "")) != expect_rid:
            continue
        blocks.append(json.dumps(obj, ensure_ascii=False))
        if len(blocks) > MAX_BLOCKS:
            blocks.pop(0)  # 末尾優先で件数を有界に保つ
print(len(blocks))
if blocks:
    sys.stdout.write(blocks[-1])
PY
  python3 -c "$prog" "${1:-}"
}

# 純粋関数（cmux 非依存・テスト可能）: 「センチネルで完成しているが JSON として不正な応答」を検出する。
#   実機で観測した不具合: reviewer が SENTINEL_BEGIN/END の2行マーカーで挟んだ本文を返したが、
#   JSON 文字列値の中に生の二重引用符が混じっていて JSON として不正だった。_scan_review_blocks は
#   「parse できたブロックだけ」を採用するためこの応答を永遠に検出できず、本来 invalid（契約違反
#   →再出力を促す）であるべきものが timeout(12) と誤診断され、応答タイムアウトの全時間を無駄にする。
#   本関数はそれを区別するため「BEGIN と END が両方揃った完成領域」のうち、期待 round_id を含み
#   かつ妥当な review JSON（dict かつ verdict を持ち round_id 一致）が1つも取り出せない領域を数える。
#   END が無い領域（ストリーミング途中の未完成応答）は invalid と誤検出しないよう数えない。
#   入力: stdin=画面テキスト・$1(任意)=期待 round_id。出力: 壊れた完成応答の件数のみ(1行)。
_scan_broken_blocks() {
  # 実装方針は _scan_review_blocks と同じ（read -r -d '' prog + python3 -c 方式・de-wrap・
  # 走査上限）。SENTINEL 文字列はシェル変数 SENTINEL_BEGIN/SENTINEL_END を argv で渡し、
  # ハードコードの二重管理をしない。
  local prog
  read -r -d '' prog <<'PY' || true
import sys, json
text = sys.stdin.read()
expect_rid = sys.argv[1] if len(sys.argv) > 1 else ""
sb = sys.argv[2]
se = sys.argv[3]

# TUI の折り返し＋ガター字下げを除く（各行 strip して連結）。_scan_review_blocks と同じ方式。
dw = "".join(line.strip() for line in text.splitlines())

# 走査上限（暴走・誤検出の防御）。最新の応答は末尾に出るため末尾側を優先して切り詰める。
MAX_SCAN = 500000
MAX_REGIONS = 200
if len(dw) > MAX_SCAN:
    dw = dw[-MAX_SCAN:]

dec = json.JSONDecoder()

def has_valid_review(region):
    # region 内に「dict かつ verdict を持ち（round_id 指定時は一致する）」JSON が
    # 1つでも raw_decode できれば、その領域は妥当な応答を含むとみなす。
    i, n = 0, len(region)
    while i < n:
        if region[i] != "{":
            i += 1
            continue
        try:
            obj, end = dec.raw_decode(region, i)
        except Exception:
            i += 1
            continue
        i = end
        if isinstance(obj, dict) and "verdict" in obj:
            if expect_rid and str(obj.get("round_id", "")) != expect_rid:
                continue
            return True
    return False

broken = 0
regions = 0
pos, n = 0, len(dw)
while pos < n and regions < MAX_REGIONS:
    b = dw.find(sb, pos)
    if b == -1:
        break
    e = dw.find(se, b + len(sb))
    if e == -1:
        # END が無い＝ストリーミング途中の未完成応答。数えず、以降も走査を打ち切る
        # （残りは同じ未完成応答の続きである可能性が高いため）。
        break
    region = dw[b + len(sb):e]
    pos = e + len(se)
    regions += 1
    # 期待 round_id 指定時は、それを含まない領域（他ラウンド・無関係な表示）は対象外にする。
    if expect_rid and expect_rid not in region:
        continue
    if not has_valid_review(region):
        broken += 1
print(broken)
PY
  python3 -c "$prog" "${1:-}" "$SENTINEL_BEGIN" "$SENTINEL_END"
}

# 純粋関数（cmux 非依存・テスト可能）: payload を「画面上は1物理行・意味上は複数行」に
# エンコードし、reviewer への指示と出力契約を含む完全な1行メッセージを stdout に返す。
#   $1 = content_type(plain|unified_diff|code|markdown), $2 = round_id, $3 = payload
# 実機知見に基づく不変条件:
#   - cmux send は \n,\t を実改行/実タブへ自動展開するため、本文の \ と tab をトークン化する。
#   - 改行は plain なら <XREV-NL>、framed なら "|| LNNNN:" の行境界へ畳む（実改行を送らない）。
#   - 末尾に END_ROUND_<id> を置き切り詰めを検出可能にする。
# ── ASCII-only wire encoding (XREV-ASCII-V1) ────────────────────────────────────
#
# 【なぜ ASCII に閉じるか】cmux 0.64.20 の受信側 ControlClientLineReader は最大 4095 バイトずつ
# read(2) し、各チャンクを独立に UTF-8 変換して、失敗したチャンクを丸ごと捨てる。Unix domain socket の
# read は write 境界を保存しないため、多バイト文字が読み取り境界で分断されると最大 4095 バイトが消え、
# 残った断片が V1 コマンドとして解釈されて "Unknown command '<断片>'" になる。ASCII は各バイトが
# 単独で正しい UTF-8 なのでこの欠陥の影響を受けない（実測: ASCII 100KB は 5/5 成功、日本語 30KB は
# 3/5 失敗、同じ本文を ASCII 化した 62KB は 5/5 成功）。
# **これは cmux 側の不具合に対する暫定回避策**であり、上流修正が普及したら削除可否を判断する。
# 判断できるよう encoding にバージョン(XREV-ASCII-V1)を付ける。詳細は references/protocol.md。
#
# 【wire 形式】機械処理は ENCODING の値だけで版を判定する（後続の HINT は reviewer 向けの補助）。
#   XREV_REVIEW round_id=<rid> ENCODING=XREV-ASCII-V1 LEN_INSTR=<a> LEN_OUT=<b> LEN_PAYLOAD=<c>
#     :: <ASCII hint> :: <instr_esc><out_esc><payload_esc> :: END_ROUND_<rid>
# 長さ付きフィールドにするのは、区切り文字が本文へ紛れても領域を一意に切り出せるようにするため
# （instr/out には '|| LNNNN:' や '<XREV-NL>' という**説明文**が含まれるので、区切り探索では分離できない）。
XREV_ASCII_ENCODING="XREV-ASCII-V1"
XREV_ASCII_HINT="ASCII-ONLY WIRE. Slice fields by LEN_INSTR/LEN_OUT/LEN_PAYLOAD (counts are characters of this line). Unescape backslash-uXXXX in every field exactly once; pair high+low surrogates for non-BMP; reject any other backslash. Then, ONLY for the payload field, parse the frame and decode tokens in a single left-to-right pass with longest match, and never rescan decoded output."


# payload を1物理行にエンコードする（送信の正典）。
#   $1=content_type / $2=round_id / $3=payload
# 手順（reverse は _xrev_decode_line が正典）:
#   1) "XREVQ" を二重化 → 2) 制御トークンを XREVQ 表記へ退避 → 3) \ と TAB をトークン化
#   4) 改行を行境界へ畳む → 5) 各フィールドを ASCII 化（非ASCIIのみ \uXXXX）
# 5 の直前に「バックスラッシュ・改行・CR・TAB が残っていない」ことを、直後に「全文字が 0x20-0x7E」を
# 検証する。前者が成り立つので、wire 上の "\" は必ず xrev が生成した \uXXXX の一部になり復号が一意になる。
_build_framed_line() {
  # payload（$3、巨大になり得る）は stdin から読む。ヒアドキュメントが stdin を占有して
  # 競合するため、プログラム本文を `read -r -d ''` で変数化し `python3 -c` へ渡して
  # stdin を空ける（Linux の ARG_MAX/MAX_ARG_STRLEN を env/argv 経由で踏み抜かないため）。
  # ct/round_id/sentinel は小さいので従来どおり argv、ENCODING/HINT は固定小サイズなので env のまま。
  # 【注意】`prog="$(cat <<'PY' ... PY)"` は使わない: bash 3.2（macOS既定）は $(...) の対応
  # 括弧探索がヒアドキュメント本文中の括弧・引用符の個数まで数えてしまい、本文中の括弧が
  # 不均衡な行（Python の複数行文字列連結等、本関数のように多い）があると
  # 「unexpected EOF while looking for matching」で構文エラーになる。`read -d ''` は
  # command substitution を経由しないため影響を受けない。
  local prog
  read -r -d '' prog <<'PY' || true
import os, sys
ct, rid, sb, se = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
body = sys.stdin.read()
enc_name = os.environ["XREV_ENC"]
hint = os.environ["XREV_HINT"]

def die(msg):
    sys.stderr.write("[xrev/transport] エンコード失敗: %s\n" % msg)
    sys.exit(1)

# round_id はヘッダーの機械可読値なので許可文字と長さを検証する。
_HDR_OK = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
# str.isalnum() は日本語なども真になるため使わない。decoder 側の [A-Za-z0-9_-] と定義を揃える。
if not (1 <= len(rid) <= 64) or any(c not in _HDR_OK for c in rid):
    die("round_id が不正です（ASCII 英数字と - _ のみ、1〜64文字）")
if not (1 <= len(ct) <= 32) or any(c not in _HDR_OK for c in ct):
    die("content_type が不正です（ASCII 英数字と - _ のみ、1〜32文字）")

# 1) 制御トークン衝突の回避（可逆エスケープ）。導入子 XREVQ を最初に二重化して衝突を避ける。
#    復号は「最長一致・左から右へ単一走査・出力を再走査しない」で行う（_xrev_decode_line 参照）。
body = body.replace("XREVQ", "XREVQXREVQ")
for tok, esc in (("<XREV-NL>", "XREVQnl"), ("<XREV-BS>", "XREVQbs"),
                 ("<XREV-TAB>", "XREVQtab"), ("END_ROUND_", "XREVQer"), ("|| L", "XREVQll")):
    body = body.replace(tok, esc)
# 2) cmux が実改行/実タブへ展開する文字をトークン化（退避後に行うので衝突しない）
body = body.replace("\\", "<XREV-BS>").replace("\t", "<XREV-TAB>")
lines = body.split("\n")
if ct == "plain":
    payload = "PAYLOAD_PLAIN || " + " <XREV-NL> ".join(lines)
else:
    recs = " ".join("|| L%04d: %s" % (i + 1, ln) for i, ln in enumerate(lines))
    payload = "PAYLOAD_FRAMED content_type=%s lines=%d %s" % (ct, len(lines), recs)

instr = ("これはエンコードされたレビュー依頼です。復元規則: <XREV-NL>=改行 / "
         "'|| LNNNN:'=行境界(framed時) / <XREV-BS>=バックスラッシュ / <XREV-TAB>=タブ。"
         "XREVQ で始まる列は本文のリテラル文字列(区切りではない): "
         "XREVQnl='<XREV-NL>' / XREVQbs='<XREV-BS>' / XREVQtab='<XREV-TAB>' / "
         "XREVQer='END_ROUND_' / XREVQll='|| L' / XREVQXREVQ='XREVQ'。"
         "これらの復元は payload フィールドだけに適用し、左から右へ一度だけ走査してください"
         "(復元後の文字列を再走査しない)。この説明文自体には適用しません。"
         "復元して内容を理解し、批判的にレビューしてください。")
out = ("出力は必ず %s と %s の2行マーカーで挟み、間には1行コンパクトJSONのみを置くこと"
       "(マーカー外・JSON前後に説明文を書かない)。JSONはトップレベルに round_id(=\"%s\") と "
       "verdict(approve|request_changes) と findings[] を持ち、各 finding は "
       "file/severity(critical|high|medium|low|nit)/category(bug|security|design|perf|style)/message を必須とする。"
       "JSON文字列値の中に二重引用符を含める場合は必ずJSON仕様どおりエスケープ済みの形にし、"
       "エスケープしていない生の二重引用符を値の中に含めないこと"
       "(壊れたJSONは契約違反として扱われ、レビュー全体が無効になる)。"
       "wire の復号に失敗した場合はレビューを行わず、verdict=\"request_changes\" と "
       "findings に category=\"bug\" message=\"decode_error\" を1件だけ入れて返すこと。"
       % (sb, se, rid))

# 3) ASCII 化の前提検証。ここが成り立つので wire 上の "\" は必ず xrev 由来になる。
for name, field in (("instr", instr), ("out", out), ("payload", payload)):
    for bad, label in (("\\", "バックスラッシュ"), ("\n", "改行"), ("\r", "CR"), ("\t", "TAB")):
        if bad in field:
            die("%s フィールドに%sが残っています" % (name, label))

def esc(s):
    # 印字可能 ASCII(0x20-0x7E)はそのまま、それ以外はすべて \uXXXX へ。
    # DEL(0x7F)やその他の制御文字も wire へ生で出さない（不変条件を常に満たせるようにする）。
    o = []
    for ch in s:
        c = ord(ch)
        if 0x20 <= c <= 0x7E:
            o.append(ch)
        elif c <= 0xFFFF:
            if 0xD800 <= c <= 0xDFFF:
                die("サロゲートコードポイント単体は送信できません")
            o.append("\\u%04X" % c)
        else:
            v = c - 0x10000
            o.append("\\u%04X\\u%04X" % (0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF)))
    return "".join(o)

fi, fo, fp = esc(instr), esc(out), esc(payload)
line = ("XREV_REVIEW round_id=%s ENCODING=%s LEN_INSTR=%d LEN_OUT=%d LEN_PAYLOAD=%d :: %s :: %s%s%s :: END_ROUND_%s"
        % (rid, enc_name, len(fi), len(fo), len(fp), hint, fi, fo, fp, rid))

# 4) wire 不変条件: 全文字が印字可能 ASCII（0x20-0x7E）で、1物理行であること。
for ch in line:
    if not (0x20 <= ord(ch) <= 0x7E):
        die("wire に印字可能 ASCII 以外が残っています (U+%04X)" % ord(ch))
sys.stdout.write(line)
PY
  XREV_ENC="$XREV_ASCII_ENCODING" XREV_HINT="$XREV_ASCII_HINT" \
    python3 -c "$prog" "$1" "$2" "$SENTINEL_BEGIN" "$SENTINEL_END"
}

# 純粋関数: wire 1行を元の payload へ復号する（プロトコルの正典実装。テストの往復検証に使う）。
#   入力: stdin=wire（巨大になり得る） / 出力: 復号した payload。不正な wire は exit 1（fail closed）。
_xrev_decode_line() {
  # wire は stdin から読む。ENCODING 名は固定小サイズなので env のまま。
  # `prog="$(cat <<'PY' ... PY)"` は使わない（bash 3.2 の $(...) 対応括弧探索がヒアドキュメント
  # 本文中の不均衡な括弧・引用符で誤爆するため。詳細は _build_framed_line のコメント参照）。
  local prog
  read -r -d '' prog <<'PY' || true
import os, re, sys
line = sys.stdin.read()
enc_name = os.environ["XREV_ENC"]

def die(msg):
    sys.stderr.write("[xrev/transport] 復号失敗: %s\n" % msg)
    sys.exit(1)

m = re.match(r"^XREV_REVIEW round_id=([A-Za-z0-9_-]{1,64}) ENCODING=([A-Za-z0-9_.-]{1,32}) "
             r"LEN_INSTR=(\d+) LEN_OUT=(\d+) LEN_PAYLOAD=(\d+) :: ", line)
if not m:
    die("ヘッダーを解釈できません")
rid, enc, a, b, c = m.group(1), m.group(2), int(m.group(3)), int(m.group(4)), int(m.group(5))
if enc != enc_name:
    die("未知の encoding: %s（対応は %s のみ）" % (enc, enc_name))

rest = line[m.end():]
sep = rest.find(" :: ")            # HINT は固定 ASCII で ' :: ' を含まない
if sep < 0:
    die("HINT の終端が見つかりません")
fields = rest[sep + 4:]
if len(fields) < a + b + c:
    die("フィールド長がヘッダーの宣言に足りません（切り詰めの恐れ）")
f_instr, f_out, f_payload = fields[:a], fields[a:a + b], fields[a + b:a + b + c]
tail = fields[a + b + c:]
if tail != " :: END_ROUND_%s" % rid:
    die("末尾マーカーが一致しません")

def unesc(s):
    o = []; i = 0; n = len(s)
    while i < n:
        ch = s[i]
        if ch != "\\":
            o.append(ch); i += 1; continue
        if s[i:i + 2] != "\\u" or not re.fullmatch(r"[0-9A-Fa-f]{4}", s[i + 2:i + 6]):
            die("バックスラッシュが \\uXXXX を開始していません")
        v = int(s[i + 2:i + 6], 16); i += 6
        if 0xD800 <= v <= 0xDBFF:                       # high surrogate → low が続くこと
            if s[i:i + 2] != "\\u" or not re.fullmatch(r"[0-9A-Fa-f]{4}", s[i + 2:i + 6]):
                die("high surrogate に low surrogate が続いていません")
            w = int(s[i + 2:i + 6], 16); i += 6
            if not (0xDC00 <= w <= 0xDFFF):
                die("low surrogate が範囲外です")
            o.append(chr(0x10000 + ((v - 0xD800) << 10) + (w - 0xDC00)))
        elif 0xDC00 <= v <= 0xDFFF:
            die("孤立した low surrogate です")
        elif 0x20 <= v <= 0x7E:
            # encoder は印字可能 ASCII を escape しない。これを受理すると、復号後に
            # '|| L0002: ' や '<XREV-BS>' といった構造トークンを合成でき、payload の
            # 衝突退避を経由せずに frame/token 解析へ流し込めてしまう。canonical な
            # wire には現れない表現なので拒否する。
            die("印字可能 ASCII の escape は canonical wire に現れません (U+%04X)" % v)
        else:
            o.append(chr(v))
    return "".join(o)

# instr / out は Unicode 復号のみ（説明文中の '|| LNNNN:' 等を構造として解釈しない）
unesc(f_instr); unesc(f_out)
payload = unesc(f_payload)

# frame 解析は payload 領域だけに適用する
if payload.startswith("PAYLOAD_PLAIN || "):
    lines = payload[len("PAYLOAD_PLAIN || "):].split(" <XREV-NL> ")
elif payload.startswith("PAYLOAD_FRAMED "):
    hm = re.match(r"^PAYLOAD_FRAMED content_type=[A-Za-z0-9_-]{1,32} lines=(\d+) ", payload)
    if not hm:
        die("PAYLOAD_FRAMED のヘッダーを解釈できません")
    n = int(hm.group(1))
    body = payload[hm.end():]
    # 行番号は 1..n が欠番・重複・順序変更なく並ぶことを検証する（読み捨てない）。
    # 桁数は encoder の %04d が 10000 行以降で 5 桁になるため \d{4,} で受ける。
    marks = list(re.finditer(r"\|\| L(\d{4,}): ", body))
    if len(marks) != n:
        die("行境界の数が宣言(%d)と一致しません（実際=%d）" % (n, len(marks)))
    if marks and marks[0].start() != 0:
        die("PAYLOAD_FRAMED の本文が行境界で始まっていません")
    lines = []
    for idx, mk in enumerate(marks):
        # encoder の %04d が出す表現は一意なので、数値ではなく文字列で照合する
        # （L00001 のような余分な先頭ゼロを持つ非 canonical 表現を受理しない）。
        if mk.group(1) != "%04d" % (idx + 1):
            die("行番号が canonical ではありません（位置%d で L%s）" % (idx + 1, mk.group(1)))
        end = marks[idx + 1].start() if idx + 1 < len(marks) else len(body)
        seg = body[mk.end():end]
        # レコードは " " で連結されているので、最終行以外は連結由来の空白を1つだけ取り除く。
        if idx + 1 < len(marks):
            if not seg.endswith(" "):
                die("行境界の連結空白が見つかりません（位置%d）" % (idx + 1))
            seg = seg[:-1]
        lines.append(seg)
else:
    die("PAYLOAD マーカーがありません")

def detok(s):
    # 生成トークンの復元（本文由来の同名文字列は XREVQ 表記へ退避済みなので衝突しない）
    s = s.replace("<XREV-BS>", "\\").replace("<XREV-TAB>", "\t")
    # XREVQ 列の復元: 最長一致・左から右へ単一走査・出力は再走査しない
    rules = (("XREVQXREVQ", "XREVQ"), ("XREVQtab", "<XREV-TAB>"), ("XREVQnl", "<XREV-NL>"),
             ("XREVQbs", "<XREV-BS>"), ("XREVQer", "END_ROUND_"), ("XREVQll", "|| L"))
    o = []; i = 0; n = len(s)
    while i < n:
        for pat, rep in rules:
            if s.startswith(pat, i):
                o.append(rep); i += len(pat); break
        else:
            o.append(s[i]); i += 1
    return "".join(o)

sys.stdout.write("\n".join(detok(ln) for ln in lines))
PY
  XREV_ENC="$XREV_ASCII_ENCODING" python3 -c "$prog"
}

# payload の content_type を推定する（純粋）。
#   - unified diff の明確な兆候（hunk ヘッダ等）→ unified_diff
#   - コードフェンス ``` を含む → code（行構造が重要なので framed に寄せる）
#   - それ以外 → plain
_detect_content_type() {
  if printf '%s' "$1" | grep -qE '^(@@ |diff --git |\+\+\+ |--- )'; then
    printf 'unified_diff'
  elif printf '%s' "$1" | grep -qF '```'; then
    printf 'code'
  else
    printf 'plain'
  fi
}

# submit 前の描画待ち秒を本文長から決める（純粋）。長いほど長く待つ（上限8s）。
_compute_submit_settle() {
  local len="$1" base extra settle
  base="$(_xrev_uint "${XREV_SUBMIT_SETTLE_SECONDS:-$(_cfg submit_settle_seconds 1)}" 0 8 1 'submit_settle_seconds')"
  extra=$(( len / 2000 ))
  settle=$(( base + extra ))
  (( settle > 8 )) && settle=8
  printf '%s' "$settle"
}

# claude reviewer 向けの composer クリア用: 送信する 0x08(BS) バイトの文字数（C2）。
# 実測（probe-report.md R3）: claude composer は ctrl-u/ctrl-a/ctrl-k/ctrl-w/escape が効かず、
# backspace は1回1文字で遅い。生の 0x08 バイトを1回の cmux send でまとめて送るのが実用的だった。
# claude reviewer は参照モード専用（inline は送信前に拒否済み）なので、実際に cmux へ送る本文は
# 参照 payload（diff 本文を含まない指示文）に限られ、想定される残骸長は小さい。マージンを載せた
# 固定量を送る（上限あり）。
_XREV_CLAUDE_CLEAR_BS_CHARS=4000

# claude reviewer の composer クリア（cmux 依存）。generateした 0x08 バイト列を1回の send で送る。
_cmux_clear_input_claude() {
  local surface="$1" bs
  _xrev_build_addr "$surface"
  bs="$(python3 -c 'import sys; sys.stdout.write(chr(8) * '"$_XREV_CLAUDE_CLEAR_BS_CHARS"')')"
  _cmux send "${_XREV_ADDR[@]}" "$bs" >/dev/null 2>&1 || true
}

# reviewer ペインの入力欄をクリアする（残留テキスト/ペーストチップの除去）。best-effort。
# 種別ごとにクリア手段が異なる（C2: reviewer 種別対応・実測知見）:
#   codex : ctrl-u（行クリア）と backspace（ペーストチップ削除）が有効。
#   claude: ctrl-u/ctrl-a/ctrl-k/ctrl-w/escape は無効（probe-report.md R3）。
#           生の 0x08(BS) バイトの一括送信を使う（_cmux_clear_input_claude）。
# ctrl-c/Escape は生成を中断し得るので使わない（アイドル化はしない=実行中の処理は止めない）。
#   $1=surface, $2=reviewer種別(basename。省略時は codex 相当の挙動)
_cmux_clear_input() {
  local surface="$1" kind="${2:-codex}" _i
  if [[ "$kind" == "claude" ]]; then
    _cmux_clear_input_claude "$surface"
    return
  fi
  _xrev_build_addr "$surface"
  for _i in 1 2 3; do _cmux send-key "${_XREV_ADDR[@]}" ctrl-u >/dev/null 2>&1 || true; done
  for _i in 1 2 3 4 5 6; do _cmux send-key "${_XREV_ADDR[@]}" backspace >/dev/null 2>&1 || true; done
}

# 純粋関数: cmux の stderr を診断ログへ出せる形に整える。
#   入力: env XREV_DIAG_ERR=cmux の stderr, XREV_DIAG_LINE=送信しようとした本文
#   出力: 安全な1行の診断文字列
#
# 【なぜ秘匿処理が要るか】レビュー payload には未公開のコードや差分が入る。cmux は実際に
# `Unknown command '<送信テキストの一部>'` の形で入力をエコーして返すため、stderr をそのまま
# ログへ出すと本文が漏れる。
#
# 【方針】「本文と一致しないから安全」という推定を使わない。cmux が引用・省略・エスケープした断片や
# 24 文字未満の秘密値は一致判定をすり抜けるため、それだけでは秘匿の契約にならない。代わりに
# **既知形式の allowlist を先に完全一致で当て、外れたものは既定で全体を伏せる** fail closed 構造にする。
#   1) 実測済みの既知形式に**完全一致**するときだけ、構造化した安全な表現を出す
#   2) それ以外は未知形式とみなし、内容を一切出さない（長さ・引用符の有無・ASCII 純度のみ）
# 新しいエラー種別を診断で読めるようにしたいときは allowlist に形式を追加する＝人間のレビューを経る。
# 推測で allowlist を広げないこと（接頭辞・接尾辞・引用構造が少しでも違えば未知扱いにする）。
_xrev_redact_diag() {
  # 送信本文(XREV_DIAG_LINE。巨大になり得る)は stdin から読む。stderr(XREV_DIAG_ERR)は
  # 呼び出し側で常に 4096 文字に打ち切られる契約（下の MAX_INPUT 参照）で ENV 1本の上限には
  # 遠く及ばず、stdin 化すると呼び出し側が2本のパイプ/リダイレクトを使い分ける必要が出て
  # 複雑になるだけなので、単純さを優先して env のままにする。
  # `prog="$(cat <<'PY' ... PY)"` は使わない（bash 3.2 の $(...) 対応括弧探索がヒアドキュメント
  # 本文中の不均衡な括弧・引用符で誤爆するため。詳細は _build_framed_line のコメント参照）。
  local prog
  read -r -d '' prog <<'PY' || true
import os, re, sys
err = os.environ.get("XREV_DIAG_ERR", "")
line = sys.stdin.read()

# 巨大な stderr は**正規化する前に**打ち切る（正規表現や走査のコストを抑える DoS 抑制。
# 正規化後に判定すると、畳み込みのコストを先に払ってしまい抑制にならない）。
MAX_INPUT = 4096
raw_len = len(err)

def unknown(reason, s=""):
    has_quote = ("'" in s) or ('"' in s)
    print("(%s。長さ=%d(raw) 引用符=%s ASCIIのみ=%s。安全のため全体を秘匿)"
          % (reason, raw_len, "有" if has_quote else "無",
             "真" if s.isascii() else "偽"))
    raise SystemExit(0)

if raw_len > MAX_INPUT:
    unknown("stderr が長すぎます")

# 【分類の厳密性】元の stderr に改行・タブが含まれていた場合は、畳み込み後に既知形式へ
# 一致しても未知扱いにする。畳み込みで偽装された未知エラーを既知エラーと誤分類しないため
# （秘匿性は畳み込み後でも保たれるが、診断の分類まで信用できる状態にしておく）。
had_multiline = bool(re.search(r"[\r\n\t]", err))

# 制御文字を除去し、空白を畳んで1行にする（ログの可読性と、改行によるログ偽装の防止）。
s = re.sub(r"[\x00-\x1f\x7f]", " ", err)
s = re.sub(r"\s+", " ", s).strip()

if not s:
    print("(stderr は空)")
    raise SystemExit(0)
if had_multiline:
    unknown("改行/タブを含む stderr", s)

def describe(frag):
    """引用断片を、内容を明かさない記述へ置き換える。位置は一意に定まるときだけ添える。"""
    note = "payload断片 %d文字" % len(frag)
    if not line:
        return "<%s>" % note
    cnt = line.count(frag) if frag else 0
    if cnt == 1:
        # 一意に定まるときだけ byte 位置を出す。ただしこれは**補助情報**であって、
        # フレーミング境界の証拠ではない（境界特定には既知マーカーの埋め込みが要る）。
        note += " / 本文の byte offset %d（補助情報）" % len(line[:line.find(frag)].encode("utf-8"))
    elif cnt > 1:
        note += " / 本文中に %d 箇所（位置は特定不能）" % cnt
    else:
        # 本文に無い断片を payload 由来と誤認しないよう明示する。
        note += " / 本文中に存在しない"
    return "<%s>" % note

# 1) 既知形式（実測済みの2形式のみ）。完全一致を必須にする。
#    Unknown command の断片は引用符を含みうるため、後置部分をアンカーにした貪欲マッチで切り出す。
m = re.fullmatch(r"Error: ERROR: Unknown command '(.*)'\. Use 'help' for available commands\.", s)
if m:
    print("Error: ERROR: Unknown command '%s'（help 案内は省略）" % describe(m.group(1)))
    raise SystemExit(0)
if re.fullmatch(r"Error: Command timed out", s):
    print(s)   # payload を含まない定型
    raise SystemExit(0)

# 2) 既知形式に当たらないものは未知形式として全体を伏せる。
unknown("未知形式の stderr", s)
PY
  XREV_DIAG_ERR="${XREV_DIAG_ERR:-}" python3 -c "$prog"
}

# 1物理行を reviewer 入力欄へ送る（確定はしない）。cmux 依存。
# 【実機知見】送信先が Codex のとき、ビジー（前応答の処理中）や入力欄の残留（テキスト/
#   ペーストチップ）があると cmux send が非ゼロで失敗する。そこで「送信前にクリア →
#   失敗なら待って再試行」する。
# 【未解決・重要】この関数は実機で全リトライ失敗する事例が確認されている（往復が完走しない）。
#   単純な文字数・バイト数の上限という仮説は**否定済み**:
#     ASCII 60000 バイト = 成功 / 日本語 60000 バイト(2万文字) = 失敗 /
#     実 payload 43149 バイト = 失敗 / 同一入力が1回目失敗・2回目成功（**非決定的**）。
#   観測できたエラーは 2 種:
#     "Error: Command timed out" と "Error: ERROR: Unknown command '<送信テキストの断片>'"。
#   後者の断片は送信テキスト中の文字列と一致する（実 payload では byte offset 32769 の文字）。
#   同期ずれ・RPC のフレーミング境界・UTF-8 の境界処理・受信側 TUI の負荷はいずれも**未確定の仮説**。
#   確定するまで分割送信などの恒久修正を決め打ちしない。各試行の rc と stderr を捕捉して
#   最終失敗時に診断ログへ出す（本文は伏せる）。
#   $3=reviewer種別(basename。省略時 codex。C2: composer クリア手段の分岐に使う)
_cmux_send_line() {
  local surface="$1" line="$2" kind="${3:-codex}" tries=0
  local max; max="$(_xrev_uint "${XREV_SEND_RETRIES:-5}" 1 20 5 'XREV_SEND_RETRIES')"
  local err rc rcs="" last_err=""
  # stderr はコマンド置換で受ける。**production に一時ファイルを持ち込まない**のが要点で、
  # 予測可能な名前による symlink 追従・権限・シグナル時の残留という問題群を構造的に排除する。
  # （_cmux は "$CMUX_BIN" "$@" で状態を持たないため、サブシェル化しても実挙動は変わらない。
  #   スタブが状態を持つのはテストの都合であり、その面倒はテスト側で引き受ける。）
  _cmux_clear_input "$surface" "$kind"   # 残留を除去してから送る（混入による prompt 破壊を防ぐ）
  _xrev_build_addr "$surface"
  while (( tries < max )); do
    err="$(_cmux send "${_XREV_ADDR[@]}" "$line" 2>&1 1>/dev/null)"; rc=$?
    (( rc == 0 )) && return 0
    rcs="${rcs}${rcs:+,}${rc}"; last_err="$err"
    # 失敗：busy/残留の可能性 → 少し待ち、再度クリアして再試行（busy 解消を待つ）。
    tries=$(( tries + 1 ))
    _xrev_sleep 2
    _cmux_clear_input "$surface" "$kind"
  done
  # 全滅時のみ診断を出す（成功時に無用なログを増やさない）。バイト長は仮説検証の主要な手掛かり。
  local nbytes; nbytes="$(printf '%s' "$line" | wc -c | tr -d ' ')"
  _log "送信に ${max} 回失敗しました（rc=[${rcs}] 文字数=${#line} バイト数=${nbytes}）。"
  _log "cmux stderr: $(printf '%s' "$line" | XREV_DIAG_ERR="$last_err" _xrev_redact_diag)"
  return 6
}

# 純粋関数（C2）: reviewer 種別ごとの送信完全性検証手段を決定する（fail closed）。
#   入力: $1 = reviewer 種別（basename。呼び出し側が basename -- で取ってから渡す）
#   出力(stdout): "paste_chip"（codex）/ "reference_only"（claude）。exit: 0=決定 / 1=未知種別(fail closed)
# 【なぜ未知種別を拒否するか】codex はペーストチップの文字数照合を使う。claude はペーストチップに
# 文字数を表示せず（実測 R2）codex と同じ照合が成立しないうえ、inline 向けの代替照合（空白非依存の
# 全文一致照合）は完全性証明にならないと判明し撤去した（指摘3・2巡目）ため、claude は参照モード
# 専用（inline は wire 長に関わらず無条件で送信前拒否。呼び出し元 xrev_transport_review 参照）。
# それ以外の reviewer は検証手段が未確立なので、確認できないまま送信することを避け送信前に拒否する。
_xrev_integrity_kind() {
  case "$1" in
    codex)  printf 'paste_chip' ;;
    claude) printf 'reference_only' ;;
    *) return 1 ;;
  esac
}

# 送信本文が入力欄に欠落なく到達したかを判定する（切り詰め検出）。reviewer 種別で照合手段が
# 異なる（C2: reviewer 種別対応・fail closed）。
#   stdout: "ok"（到達確認）/ "truncated"（切り詰め）/ "unknown"（確認不能。codex のみの縮退）
# codex: TUI は長いペーストを「[Pasted Content N chars]」へ畳むため、END_ROUND マーカーは
#   画面に出ない。その代わり表示される文字数 N が送信長と一致するかで欠落を検出する。
#   短いペーストはインライン表示されるので、その場合は de-wrap して末尾マーカーで確認する
#   （どちらも確認できなければ unknown＝縮退。続行するが警告する）。
# claude: 参照モード専用（xrev_transport_review が inline を無条件 exit28 で拒否するため、本関数は
#   常に参照モードでのみ呼ばれる）。呼び出し元は claude のとき本関数自体を呼ばず intact="ok" を
#   直接立てる（完全性は diff_hash + 基底 HEAD の端到端照合で別途保証されるため。呼び出し元の
#   コメント参照）。かつて inline 向けに wire 文字列の空白非依存な全文一致照合を試みていたが、
#   完全性証明にならないと判明し撤去した（経緯は references/protocol.md「切り詰め検出」節）。
#   $1=surface, $2=elen(codex用の送信長), $3=marker(codex用の末尾マーカー),
#   $4=reviewer種別(basename。省略時 codex。claude では呼ばれない)
_check_paste_intact() {
  local surface="$1" elen="$2" marker="$3" kind="${4:-codex}" screen
  screen="$(_cmux_read_screen "$surface")"
  XREV_ELEN="$elen" XREV_MARK="$marker" python3 -c '
import os, sys, re
elen = int(os.environ["XREV_ELEN"]); mark = os.environ["XREV_MARK"]
dw = "".join(l.strip() for l in sys.stdin.read().splitlines())
# スクロールバックには過去ラウンドの "Pasted Content N chars" も残る。最初の一致を採ると
# 前のラウンドの数値と今回の送信長を比べて誤判定するため、**最後の一致**を今回の分とみなす。
ms = re.findall(r"Pasted Content\s+(\d+)\s+chars", dw)
if ms:
    print("ok" if int(ms[-1]) == elen else "truncated"); sys.exit(0)
print("ok" if mark in dw else "unknown")
' <<<"$screen"
}

# ── Phase1c: reviewer ペインの create-if-missing 自動生成（@xrev 承認設計）───────────
#
# 設計（4ラウンドのクロスレビューで収束）の要点:
#   - 冪等: 同一WSに使える reviewer があれば採用、無ければ1枚だけ生成。
#   - 競合は WS UUID 鍵の mkdir ロック（原子取得）で直列化。ロックは**回収しない**（stale 回収レースを構造的に排除）。
#     取れない側は奪わず deadline まで present を待ち、期限切れは exit20 で人間へ（残留ロックは案内に従い手動削除）。
#   - 生成所有物は new-pane が返した surface UUID に固定（title は一意でないので生成判定に使わない）。
#   - read/send は workspace+surface UUID 指定（実機修正）。read-screen probe 成功＋直下=codex で起動確認。

# シェルに渡す値を単一引数として安全にクォート（reviewer バイナリ名注入対策）。printf %q は shell-safe。
_xrev_shquote() { printf '%q' "$1"; }

# ── reviewer バイナリ解決の一般化（C1）─────────────────────────────────────────
#
# 【背景】従来は ensure-reviewer 経路(_xrev_create_reviewer)・start-reviewer.sh とも
# `${XREV_CODEX_BIN:-codex}` を素朴に埋め込んでおり、reviewer=claude のような主従反転
# プリセット（primary=codex/reviewer=claude）に切り替えても解決先が codex 固定のままだった。
# ここで両経路が共有する単一の解決関数を設け、config の reviewer 値（既定 codex）を基準にする。
#
# 【解決優先順】
#   1) XREV_REVIEWER_BIN（新設 env・最優先。reviewer 種別を問わず常に有効）
#   2) XREV_CODEX_BIN（後方互換のエイリアス。config の reviewer が codex のときのみ有効。
#      reviewer が codex 以外なのに指定されていたら stderr に1行警告して無視する＝
#      「codex 用のはずの上書きが別 reviewer に紛れ込む」事故を防ぐ）
#   3) config の reviewer 値（バイナリ名。既定 codex）
#
# kind 判定（_xrev_reviewer_launch_args / _xrev_verify_effective_policy の第1引数）は
# 従来どおり解決済みバイナリの basename を使う（呼び出し側が basename -- で取る）。
_xrev_reviewer_bin() {
  if [[ -n "${XREV_REVIEWER_BIN:-}" ]]; then
    printf '%s' "$XREV_REVIEWER_BIN"
    return 0
  fi
  if [[ -n "${XREV_CODEX_BIN:-}" ]]; then
    if [[ "$REVIEWER" == "codex" ]]; then
      printf '%s' "$XREV_CODEX_BIN"
      return 0
    fi
    _log "警告: XREV_CODEX_BIN が指定されていますが reviewer='${REVIEWER}' のため無視します（後方互換エイリアスは reviewer=codex のときのみ有効です。XREV_REVIEWER_BIN を使ってください）。"
  fi
  printf '%s' "$REVIEWER"
}

# ── reviewer read-only 強制（launch 引数の機械生成・危険引数の拒否）─────────────────
#
# 【設計】SKILL.md は「reviewer = レビュー専用・read-only」と約束するが、これまでは素の
# `exec codex` とユーザー引数の素通しで、read-only は codex 側の既定設定に完全依存していた。
# ここで起動経路（start-reviewer.sh の手動経路 / _xrev_create_reviewer の自動生成経路）が
# 共有する単一の引数生成関数を設け、read-only 相当の引数を機械的に強制する。
#   - eval は使わない（1行1要素で stdout に出し、呼び出し側は while read で配列へ集める）。
#   - 型検証（object であること・キー存在・文字列のみの配列・印字可能ASCIIのみ）は python 側で行い、
#     違反時は空配列へフォールバックせず fail closed（非ゼロ）にする。
#   - 未知の reviewer（config に launch 引数が無い）も fail closed（暴発防止の設計原則7とは別に、
#     「read-only を強制できないなら起動しない」という安全側の既定）。
#
# 【最終 argv の意味検証が正典】launch 引数の型検証（文字列のみ・印字可能ASCIIのみ）は「壊れた値を
# 通さない」ためのものにすぎず、「安全なポリシーか」（sandbox=read-only かつ承認=never が一意に
# 有効か）は別に検証しなければならない。空配列や ["--sandbox","danger-full-access"] のような config も
# 型検証だけは通ってしまうし、launch 引数の後ろにユーザー引数で `-s danger-full-access` のような
# 短縮形・結合形式を後置されると拒否リスト方式（前方一致）ではすり抜ける。そこで
# `_xrev_verify_effective_policy` を「最終的に reviewer へ渡る argv 列」に対して通し、拒否リストでは
# なく実効値の意味検証で合否を決める。この関数を (a) launch 引数決定直後
# （`_xrev_reviewer_launch_args` 内）, (b) start-reviewer.sh の最終 argv（launch 引数＋ユーザー追加引数）,
# (c) 起動後に実際に走っているプロセスの argv（`_verify_reviewer_launch_args`）, (d) 既存ペイン採用時の
# 実効検証（`_xrev_verify_reviewer_policy`）の4箇所で共有する。

# 【共有の実体・その2】「argv 列が安全ポリシーを一意に満たすか」を判定する純粋 python 関数
# `_xrev_check_policy(kind, argv)` の定義だけを stdout に返す（副作用なし・実行はしない・
# sys.exit や stderr 出力もしない）。戻り値は合格時 None / 不合格時は理由の文字列。
#   入力: kind = reviewer 種別（basename。codex / claude）, argv = 最終 argv 列（0件可）
#   認識する引数形式（codex）:
#     sandbox   = `--sandbox <値>` / `--sandbox=<値>` / `-s <値>` / `-s<値>`（結合形式）
#     approval  = `--ask-for-approval <値>` / `--ask-for-approval=<値>` / `-a <値>` / `-a<値>`（結合形式）
#   判定（codex）:
#     - sandbox・approval それぞれの指定を左から集め、**ちょうど1回だけ**現れることを要求する
#       （0回=指定なし・2回以上=同じ軸の複数指定は、たとえ最後の値が安全でも fail closed で拒否。
#       「後勝ちで良しとする」寛容さは意図的に採らない＝意図の曖昧さを許さない）。
#     - sandbox の実効値が `read-only`、かつ approval の実効値が `never` であることを要求する。
#     - `--dangerously-bypass-approvals-and-sandbox` / `--full-auto` / `--yolo`（完全一致。前方一致では
#       ない）のいずれかが argv に含まれていたら、他条件を満たしていても拒否する。危険フラグの
#       リストはこの関数の中の1箇所にまとめる（拒否リストの多重管理をしない）。
#     - 値を要求する形式で値が無い（末尾で切れている）場合も拒否する。
#   判定（claude）: `--permission-mode <値>` / `--permission-mode=<値>` の実効値が一意に `plan` である
#     ことを要求する（claude は短縮形を持たないため、それ以外の形式は単に「該当なし」として扱われ、
#     結果的に「指定なし」で fail closed になる）。
#   未知の reviewer 種別: fail closed（拒否）。
#
# 【指摘1（2巡目）への対処・この関数を共有する理由】判定の実体（sandbox/approval/permission-mode の
# 認識形式・危険フラグ一覧）をここ1箇所にまとめ、(a) 改行を含まない trusted argv（launch 引数決定
# 直後・start-reviewer.sh の最終 argv）を検証する `_xrev_verify_effective_policy`、(b) KERN_PROCARGS2
# 由来の untrusted argv（既存ペイン採用・起動後検証）を単一 python プロセス内で判定する
# `_xrev_verify_foreground_policy` / `_verify_reviewer_launch_args` の両方がこの1関数を呼ぶ。
# 判定リストを二重管理しない。
_xrev_policy_check_py_src() {
  cat <<'PY'
def _xrev_check_policy(kind, argv):
    def collect(args, long_flag, short_flag=None):
        # long_flag（空白区切り/=形式）と short_flag（空白区切り/結合形式）の実効値を左から集める。
        # 呼び出し側で len(values) を検証する（0=指定なし、2以上=複数指定として fail closed）。
        values = []
        long_eq = long_flag + "="
        i, n = 0, len(args)
        while i < n:
            a = args[i]
            if a == long_flag:
                if i + 1 >= n:
                    return None, "%s の値がありません" % long_flag
                values.append(args[i + 1]); i += 2; continue
            if a.startswith(long_eq):
                values.append(a[len(long_eq):]); i += 1; continue
            if short_flag is not None:
                if a == short_flag:
                    if i + 1 >= n:
                        return None, "%s の値がありません" % short_flag
                    values.append(args[i + 1]); i += 2; continue
                if a.startswith(short_flag) and len(a) > len(short_flag):
                    values.append(a[len(short_flag):]); i += 1; continue
            i += 1
        return values, None

    if kind == "codex":
        # サンドボックス/承認を丸ごと外す既知フラグ（完全一致。1箇所にまとめる）。
        DANGEROUS_EXACT = (
            "--dangerously-bypass-approvals-and-sandbox",
            "--full-auto",
            "--yolo",
        )
        for a in argv:
            if a in DANGEROUS_EXACT:
                return "サンドボックス/承認を丸ごと外すフラグが含まれています: %s" % a
        sandbox_vals, err = collect(argv, "--sandbox", "-s")
        if err:
            return err
        approval_vals, err = collect(argv, "--ask-for-approval", "-a")
        if err:
            return err
        if len(sandbox_vals) != 1:
            return "sandbox 指定が一意ではありません（%d 件）" % len(sandbox_vals)
        if len(approval_vals) != 1:
            return "承認ポリシー指定が一意ではありません（%d 件）" % len(approval_vals)
        if sandbox_vals[0] != "read-only":
            return "sandbox の実効値が read-only ではありません: %s" % sandbox_vals[0]
        if approval_vals[0] != "never":
            return "承認ポリシーの実効値が never ではありません: %s" % approval_vals[0]
        return None  # 合格
    elif kind == "claude":
        perm_vals, err = collect(argv, "--permission-mode", None)
        if err:
            return err
        if len(perm_vals) != 1:
            return "--permission-mode 指定が一意ではありません（%d 件）" % len(perm_vals)
        if perm_vals[0] != "plan":
            return "--permission-mode の実効値が plan ではありません: %s" % perm_vals[0]
        return None  # 合格
    else:
        return "未知の reviewer 種別です: %s" % kind
PY
}

# 純粋関数: 「最終的に reviewer へ渡る argv 列」が安全ポリシーを一意に満たすかを検証する（正典）。
# 判定の実体は `_xrev_policy_check_py_src`（共有）。本関数はその薄いドライバで、コマンドライン引数
# として渡された argv（改行を含まない trusted な入力: launch 引数決定直後・start-reviewer.sh の
# 最終 argv）を検証する用途に使う。KERN_PROCARGS2 由来の untrusted argv は本関数を経由せず
# `_xrev_verify_foreground_policy` / `_verify_reviewer_launch_args`（単一プロセス内で完結）を使う。
#   入力: $1 = reviewer 種別（basename。codex / claude）, $2.. = 最終 argv 列（0件可）
#   出力: 合格時は stdout に何も書かない（exit 0。終了コードのみで成否を表現する）/ 不合格時は
#     stderr に理由（exit 非ゼロ）。
#   【重要・不具合A（実機で発生した回帰）への対処】この関数は「stdout が結果チャネルである経路」
#   （例: xrev_transport_review は stdout に reviewer の review JSON だけを返す契約）から直接・間接に
#   呼ばれる。以前は合格時に stdout へ "ok" を書いており、呼び出し側の1箇所（xrev_transport_review の
#   (iii) 送信ゲート内、`_xrev_verify_reviewer_policy` 経由）でリダイレクトが漏れていたため、"ok" が
#   review JSON の手前に混入して JSON パース失敗（decision=invalid）を起こした。原因は「呼び出し側の
#   リダイレクト漏れ」ではなく「この関数が stdout を結果チャネルとして使っていたこと」自体なので、
#   合格時に何も出力しないことで、この種の事故を構造的に起こり得なくする。
_xrev_verify_effective_policy() {
  local prog
  prog="$(_xrev_policy_check_py_src)
import sys

if len(sys.argv) < 2:
    sys.stderr.write(\"[xrev/transport] 安全ポリシー検証失敗: reviewer 種別が指定されていません\n\")
    sys.exit(1)
_err = _xrev_check_policy(sys.argv[1], sys.argv[2:])
if _err:
    sys.stderr.write(\"[xrev/transport] 安全ポリシー検証失敗: %s\n\" % _err)
    sys.exit(1)
"
  python3 -c "$prog" "$@"
}

# reviewer の launch 引数を決定する（config/env → 型検証 → 1行1要素で stdout）。
#   入力: $1 = reviewer バイナリ名（basename を取ってから照合する）
#   優先順位: env XREV_REVIEWER_LAUNCH_ARGS（JSON 配列文字列。文字列のみの配列を要求） >
#             config の reviewer_launch_args[<basename>]
#   出力(stdout): 引数を1行1要素（改行区切り）。引数自体に改行を含むことは型検証で拒否するため
#     区切りとして安全。exit: 0=決定 / 1=型不正・未知reviewer・JSON不正・安全ポリシー不合格（fail closed）
#
# 【指摘1への対処】型検証（object/文字列配列/印字可能ASCII）を通っただけでは「安全なポリシーか」は
# 分からない。空配列や `["--sandbox","danger-full-access"]` も型としては正しいため、決定した
# launch 引数列そのものを `_xrev_verify_effective_policy` に通し、config/env が壊れている（＝read-only
# 強制を回避する値になっている）場合は fail closed で拒否する。
_xrev_reviewer_launch_args() {
  local name; name="$(basename -- "$1")"
  local prog
  read -r -d '' prog <<'PY' || true
import json, os, sys

def die(msg):
    sys.stderr.write("[xrev/transport] %s\n" % msg)
    sys.exit(1)

def validate_list(val, label):
    # object の値（launch 引数列）が「文字列のみの配列・印字可能ASCIIのみ・空文字列不可」であることを
    # 検証する。1つでも違反があれば fail closed（部分的に有効な要素だけを使うことはしない）。
    if not isinstance(val, list):
        die("%s が不正です（配列ではありません）" % label)
    out = []
    for item in val:
        if not isinstance(item, str):
            die("%s に文字列以外の要素が含まれています" % label)
        if item == "":
            die("%s に空文字列の要素が含まれています" % label)
        for ch in item:
            code = ord(ch)
            if code < 0x20 or code > 0x7E:
                die("%s の要素に印字可能ASCII以外の文字が含まれています（該当要素は伏せます）" % label)
        out.append(item)
    return out

name = sys.argv[1]
override = os.environ.get("XREV_LAUNCH_OVERRIDE", "")

if override:
    try:
        parsed = json.loads(override)
    except Exception:
        die("XREV_REVIEWER_LAUNCH_ARGS が不正な JSON です")
    launch_args = validate_list(parsed, "XREV_REVIEWER_LAUNCH_ARGS")
else:
    cfg_path = os.environ.get("XREV_CONFIG_PATH", "")
    try:
        with open(cfg_path) as f:
            cfg = json.load(f)
    except Exception:
        die("config を読み込めません（%s）" % cfg_path)
    launch_map = cfg.get("reviewer_launch_args")
    if not isinstance(launch_map, dict):
        die("reviewer_launch_args が不正です（object ではありません）")
    if name not in launch_map:
        die("未知の reviewer '%s'（launch 引数が未定義）。"
            "config の reviewer_launch_args に追加するか "
            "XREV_REVIEWER_LAUNCH_ARGS を指定してください" % name)
    launch_args = validate_list(launch_map[name], "reviewer_launch_args['%s']" % name)

for a in launch_args:
    print(a)
PY
  local out
  out="$(XREV_LAUNCH_OVERRIDE="${XREV_REVIEWER_LAUNCH_ARGS:-}" XREV_CONFIG_PATH="$XREV_CONFIG" \
    python3 -c "$prog" "$name")" || return $?
  local -a args=()
  local _la_out_line
  while IFS= read -r _la_out_line; do
    [[ -n "$_la_out_line" ]] && args+=("$_la_out_line")
  done <<< "$out"
  # stdout のみ捨てる（合格時は不具合Aの対処により何も出さないが念のための防御）。stderr は
  # 捨てない: ここは「決定した launch 引数が壊れている」という実害のある失敗であり、
  # _xrev_verify_effective_policy が返す具体的な理由（どの軸が・どんな値で不合格か）は
  # 診断に必要なので、以降の _log による総括メッセージに加えて表示させる。
  if ! _xrev_verify_effective_policy "$name" "${args[@]+"${args[@]}"}" >/dev/null; then
    _log "reviewer(${name}) の launch 引数が安全ポリシー（read-only 強制）を満たしません（config/env の reviewer_launch_args を確認してください）。"
    return 1
  fi
  printf '%s\n' "$out"
}

# 危険な launch 引数上書きの拒否。sandbox/approval 系フラグの前方一致で判定する。
# 【判定リストはここ1箇所にまとめる】codex/claude の sandbox・承認モード系フラグ。
#   launch 引数（read-only 強制）の後置上書きを防ぐ（start-reviewer.sh のユーザー追加引数向け）。
#
# 【位置づけ（指摘2への対処後）】この拒否リストは前方一致にすぎず、`-s`（codex の sandbox 短縮形）や
# 未知の危険フラグを漏らしうる。正典の最終判定は `_xrev_verify_effective_policy` による「最終 argv の
# 意味検証」であり、本関数はそれより前段で分かりやすいエラーメッセージを即座に返すための
# best-effort な早期棄却にすぎない（本関数を通過しても、後段の意味検証が改めて拒否しうる）。
_xrev_reject_unsafe_reviewer_args() {
  local -a unsafe_prefixes=(
    "--sandbox" "-s" "--ask-for-approval" "--approval" "--full-auto"
    "--dangerously" "--permission-mode" "--yolo" "-a"
  )
  local arg prefix
  for arg in "$@"; do
    for prefix in "${unsafe_prefixes[@]}"; do
      if [[ "$arg" == "$prefix"* ]]; then
        _log "危険な引数 '${arg}' は許可されません（sandbox/approval 系フラグの上書きは拒否します）。"
        return 64
      fi
    done
  done
  return 0
}

# 呼び出し元(CMUX_SURFACE_ID)の所属ワークスペース UUID を返す。
_xrev_caller_ws() {
  [[ -n "${CMUX_SURFACE_ID:-}" ]] || return 1
  local tree loc
  tree="$(_cmux_tree_uuids)"; [[ -n "$tree" ]] || return 1
  loc="$(XREV_LISTING="$tree" _locate_surface "$CMUX_SURFACE_ID")" || return 1
  printf '%s' "$(printf '%s' "$loc" | cut -f3)"
}

# 同一WSの reviewer の状態を分類する（_cmux_resolve_surface ＋ probe）。
#   stdout: present|absent|ambiguous|non_terminal|process_mismatch|policy_mismatch|ws_error|transient
#   exit:   0(present) / 10(absent) / 16(ambiguous) / 14(non_terminal) / 17(process_mismatch) /
#           27(policy_mismatch) / 15(ws_error) / 1(transient)
# present のときグローバル _XREV_RES_* に解決結果が入る。
#
# 【指摘3への対処】従来は「前景プロセス名が REVIEWER_PROCESS か」しか見ておらず、手動起動・旧版の
# 書き込み可能なままの端末がそのまま present（採用）扱いになり得た。ここで前景プロセスの argv を
# 取得し、安全ポリシー（sandbox=read-only かつ承認=never）が実効に有効かを検証してから present と
# 判定する。既定は検証する（fail closed）。XREV_ALLOW_UNVERIFIED_REVIEWER=1（明示 opt-in）のときだけ
# 検証を省略する（手動で用意した reviewer を使う運用を壊さないための後方互換。警告ログを出す）。
_xrev_classify_reviewer() {
  _XREV_RES_REF=""
  _cmux_resolve_surface >/dev/null; local rc=$?
  case "$rc" in
    0) : ;;
    10) printf 'absent'; return 10 ;;
    16) printf 'ambiguous'; return 16 ;;
    15) printf 'ws_error'; return 15 ;;
    # 重要: absent(10)以外の解決失敗(tree取得不能 exit3 等)を absent に正規化しない。
    # 「不在を証明できない」障害で create-if-missing を発火させる fail-open を防ぐ。
    *)  printf 'transient'; return 1 ;;
  esac
  local term; term="$(_probe_terminal_usable "$_XREV_RES_REF")"
  case "$term" in
    usable) ;;
    non_terminal) printf 'non_terminal'; return 14 ;;
    *) printf 'transient'; return 1 ;;   # gone/transient は過渡。待機側で再評価
  esac
  if ! _verify_reviewer_process "$_XREV_RES_REF"; then
    printf 'process_mismatch'; return 17
  fi
  if [[ "${XREV_ALLOW_UNVERIFIED_REVIEWER:-}" == "1" ]]; then
    _log "警告: XREV_ALLOW_UNVERIFIED_REVIEWER=1 のため既存 reviewer の安全ポリシー検証を省略します（read-only/承認 never を保証しません）。"
    printf 'present'; return 0
  fi
  # stderr も含めて捨てる: ここは「分類」であり policy_mismatch は失敗ではなく正常な分類結果の
  # 1つ（呼び出し元の xrev_ensure_reviewer が rc=27 を受けて既に案内メッセージを出す）。
  # _xrev_verify_effective_policy の理由文言を二重に出す必要はない。
  if _xrev_verify_reviewer_policy "$_XREV_RES_REF" >/dev/null 2>&1; then
    printf 'present'; return 0
  fi
  printf 'policy_mismatch'; return 27
}

# ロックパス（TMPDIR 配下・WS UUID 鍵。リポジトリには絶対に作らない）。
_xrev_lock_path() {
  local ws="$1" base safe
  base="${TMPDIR:-/tmp}"; base="${base%/}"
  safe="$(printf '%s' "$ws" | tr -c 'A-Za-z0-9' '_')"
  printf '%s/xrev-reviewer-%s.lock' "$base" "$safe"
}

# 生成本体: caller WS に terminal ペインを作り、所有 surface UUID を固定して codex を起動・確認する。
# 成功で _XREV_RES_* に生成結果を入れて 0、起動確認失敗（read-only 引数の実効確認できず、を含む）で 19。
_xrev_create_reviewer() {
  local ws="$1" codex
  codex="$(_xrev_reviewer_bin)"
  command -v "$codex" >/dev/null 2>&1 || { _log "reviewer バイナリ '$codex' が見つかりません（XREV_REVIEWER_BIN で指定可。reviewer=codex のときは XREV_CODEX_BIN も後方互換で使えます）。"; return 19; }
  # launch 引数（read-only 強制）を先に決定する。cmux にペインを作る前に検証しておくことで、
  # config/env が壊れている場合に無駄なペイン生成をしない。生成できなければ fail closed で中止。
  local -a launch_args=()
  local launch_out
  if ! launch_out="$(_xrev_reviewer_launch_args "$codex")"; then
    _log "reviewer(${codex}) の launch 引数を決定できませんでした（生成を中止します）。"
    return 19
  fi
  local _la_line
  while IFS= read -r _la_line; do
    [[ -n "$_la_line" ]] && launch_args+=("$_la_line")
  done <<< "$launch_out"
  local out nrc ref
  # new-pane の rc を確認し、成功時の stdout のみから surface を抽出する（失敗メッセージの誤抽出を防ぐ）。
  out="$(_cmux new-pane --type terminal --workspace "$ws" --focus false 2>/dev/null)"; nrc=$?
  (( nrc == 0 )) || { _log "reviewer ペインの生成(new-pane)に失敗しました（rc=${nrc}）。"; return 19; }
  ref="$(printf '%s' "$out" | grep -oE 'surface:[0-9]+' | head -1)"
  [[ -n "$ref" ]] || { _log "new-pane 出力から surface を特定できません: $out"; return 19; }
  # 生成 surface の UUID を tree から固定（＝所有物。以後この UUID にだけ作用する）。
  local tree loc sf
  tree="$(_cmux_tree_uuids)"
  loc="$(XREV_LISTING="$tree" _locate_surface "$ref")" || { _log "生成した surface($ref)を特定できません。"; return 19; }
  sf="$(printf '%s' "$loc" | cut -f2)"
  _XREV_RES_REF="$ref"; _XREV_RES_UUID="$sf"; _XREV_RES_WS="$ws"; _XREV_RES_PATH="created"; _XREV_RES_SAMEWS=1
  # codex を launch 引数付きで exec 起動（各要素を個別に shell-safe クォートし、eval は使わない）。
  # 【実機知見】タブのリネームは「codex 起動の前」に行うと、codex が起動時に cwd 由来の名前(例 "xrev")で
  #   タブ名を上書きしてしまい、reviewer_pane_title が定着しない（→ 次回の title 解決が当たらず冪等性が崩れる）。
  #   そのため rename は**起動確認の後**に行う（post-startup rename は上書きされず定着することを実機確認）。
  #   また rename-tab も read/send 同様 workspace+surface UUID 指定が必要（短縮 ref/uuid 単独は "Tab not found"）。
  local cmd_str; cmd_str="exec $(_xrev_shquote "$codex")"
  # bash 3.2（macOS既定）は set -u 下で「宣言済みだが要素0件」の配列展開が unbound variable に
  # なるバグがある（bash 4.4 で修正）。"${arr[@]+...}" イディオムで 0 件配列でも安全に展開する。
  for _la_line in "${launch_args[@]+"${launch_args[@]}"}"; do
    cmd_str+=" $(_xrev_shquote "$_la_line")"
  done
  _cmux send --workspace "$ws" --surface "$sf" "$cmd_str" >/dev/null 2>&1
  _cmux send-key --workspace "$ws" --surface "$sf" enter >/dev/null 2>&1
  # 起動確認（同一試行内で read+top）。所有 UUID にだけ作用。
  local deadline=$(( SECONDS + CREATE_TIMEOUT )) term
  while (( SECONDS < deadline )); do
    _xrev_sleep 1
    term="$(_probe_terminal_usable "$_XREV_RES_REF")"
    if [[ "$term" == "usable" ]] && _verify_reviewer_process "$_XREV_RES_REF"; then
      # read-only 引数の実効検証。ここまでは「起動できた」だけで、launch 引数が実際に効いて
      # いる保証にはならない（引数生成のバグ・cmux send の欠落等でも起動確認は通り得る）ため、
      # 実プロセスのコマンドラインで裏取りしてから採用する。確認できなければ採用しない(fail closed)。
      if ! _verify_reviewer_launch_args "$_XREV_RES_REF" "$(basename -- "$codex")"; then
        _log "reviewer は起動しましたが read-only 引数の実効を確認できませんでした（surface=${ref}）。"
        return 19
      fi
      # 起動確認後にリネーム（codex のタブ名上書きを上書きし返して定着させる）。失敗は致命でない
      # （当該セッションは UUID で操作できる）が、冪等性のため診断ログは残す。
      _cmux rename-tab --workspace "$ws" --surface "$sf" "$REVIEWER_PANE_TITLE" >/dev/null 2>&1 \
        || _log "reviewer タブのリネームに失敗しました（title 解決の冪等性に影響しうる。UUID 解決は可能）。"
      _log "reviewer を生成しました（surface=$ref, title='$REVIEWER_PANE_TITLE'）。"
      return 0
    fi
  done
  _log "reviewer 生成: codex の起動を確認できませんでした（surface uuid=${_XREV_RES_UUID}）。"
  return 19
}

# 公開: 同一WSの reviewer を保証する（あれば採用・無ければ生成）。stdout に採用 surface ref。
# exit: 0 / 10(absent かつ autocreate=off) / 14/16/17(既存が壊れ/曖昧/別物→人間) /
#       27(既存が安全ポリシー不合格→人間) / 15(ws不明) / 19(生成したが起動確認失敗) / 20(競合で期限切れ→人間)。
xrev_ensure_reviewer() {
  _cmux_preflight || return $?
  # 注意: classify は _XREV_RES_* グローバルをセットするため $() で捕捉しない（サブシェルで失われる）。
  local rc
  _xrev_classify_reviewer >/dev/null; rc=$?
  case "$rc" in
    0)  printf '%s' "$_XREV_RES_REF"; return 0 ;;
    10) : ;;  # absent → 生成判断へ
    16) _log "同一WSに reviewer が複数あり曖昧です。作成せず確認してください。"; return 16 ;;
    14) _log "同一WSの reviewer が実ターミナルでありません（壊れ）。作成せず確認してください。"; return 14 ;;
    17) _log "同一WSの reviewer の前景プロセスが '$REVIEWER_PROCESS' ではありません。作成せず確認してください。"; return 17 ;;
    27) _log "reviewer ペインが安全ポリシー（read-only + 承認 never）で起動していません。ペインを閉じて ensure-reviewer で作り直すか、start-reviewer.sh で起動し直してください。"; return 27 ;;
    15) _log "呼び出し元のワークスペースを特定できません（cmux ペイン内で実行してください）。"; return 15 ;;
    # 一時障害(tree取得不能等)は「不在を証明できない」ので生成しない。再試行/人間判断に委ねる。
    *)  _log "reviewer の状態を確認できませんでした（一時障害）。生成せず中止します。"; return 11 ;;
  esac
  if [[ "$REVIEWER_AUTOCREATE" == "off" ]]; then
    _log "reviewer が見つかりません（autocreate=off）。reviewer 用の codex ペインを用意してください。"
    return 10
  fi
  local ws; ws="$(_xrev_caller_ws)" || { _log "呼び出し元のワークスペースを特定できません。"; return 15; }
  local lock; lock="$(_xrev_lock_path "$ws")"
  if mkdir "$lock" 2>/dev/null; then
    _XREV_LOCK="$lock"
    printf '%s' "$$" > "$lock/pid" 2>/dev/null || true
    trap '[[ -n "${_XREV_LOCK:-}" ]] && rm -rf "$_XREV_LOCK" 2>/dev/null' EXIT INT TERM
    # ロック下で再確認（ダブルチェック）。生成するのは **absent(10) のときだけ**。
    # この間に他/人間が壊れ(14)・曖昧(16)・別物(17)を作っていたら作り直さず返す。一時障害(transient)も生成しない。
    _xrev_classify_reviewer >/dev/null; rc=$?
    if (( rc != 10 )); then
      rm -rf "$lock"; _XREV_LOCK=""; trap - EXIT INT TERM
      case "$rc" in
        0)  printf '%s' "$_XREV_RES_REF"; return 0 ;;
        16|14|17|27|15) return "$rc" ;;
        *)  _log "ロック下で reviewer 状態を確認できませんでした（一時障害）。生成せず中止します。"; return 11 ;;
      esac
    fi
    _xrev_create_reviewer "$ws"; rc=$?
    rm -rf "$lock"; _XREV_LOCK=""; trap - EXIT INT TERM
    if (( rc == 0 )); then printf '%s' "$_XREV_RES_REF"; return 0; fi
    return "$rc"
  fi
  # 競合: 奪わず deadline まで present（read+codex 確認済み）だけを待つ。
  local deadline=$(( SECONDS + CREATE_TIMEOUT ))
  while (( SECONDS < deadline )); do
    _xrev_sleep "$(( (RANDOM % 2) + 1 ))"
    _xrev_classify_reviewer >/dev/null; rc=$?
    if (( rc == 0 )); then printf '%s' "$_XREV_RES_REF"; return 0; fi
    # absent/transient/non_terminal/process_mismatch/ambiguous は生成中の過渡かもしれないので待つ。
  done
  _log "reviewer 生成の競合で期限切れです（別 primary が生成中か、残留ロックの可能性）。"
  _log "残留ロックなら、このパスのみを安全に解除してください（rm -rf は使わない）:"
  _log "  rm -f \"$lock/pid\" 2>/dev/null; rmdir \"$lock\" 2>/dev/null"
  return 20
}

# 送信ゲート統合ヘルパ（不具合B対応: 安全ポリシー検証の TOCTOU）。
# 【背景】従来は安全ポリシー実効検証を送信処理の序盤（旧(iii)直後の(iii')）で1回だけ行い、
# その後の「本文送信直前(iii-b)」「Enter直前の最終ゲート(iii-c)」「Enter再送前」の各ゲートは
# _verify_reviewer_process（プロセス名のみ）しか再検証していなかった。初回のポリシー検証後に
# reviewer プロセスが終了し、同名だが書き込み可能な reviewer（例 --sandbox workspace-write の
# codex）が起動し直した場合、本文送信〜Enter確定までの描画待ち（最大約10秒）の窓で「プロセス名は
# 一致するがポリシーは既に崩れている」状態を名前検証だけが通過し、無承認のまま payload を確定できて
# しまう。既存の「shell 誤送信対策(プロセス証明の3点検査)」と同じ形の TOCTOU が安全ポリシー側に
# 残っていた。
# 【対処】プロセス証明と安全ポリシー検証を「常に同じゲート」でまとめて行う。送信経路の全ゲート
# （早期棄却・本文送信直前・Enter直前・Enter再送前）をこのヘルパの呼び出しに置き換え、片方だけを
# 再検証して他方が古いまま残る構造的な穴を塞ぐ。
#   入力: $1=surface
#   出力: なし（理由に応じたログは呼び出し側が出す。ゲートごとに文言が異なるため）。
#   exit: 0=プロセス証明・安全ポリシーとも確認 / 17=プロセス不一致 / 27=安全ポリシー不一致
# 【キャッシュしない】安全ポリシー検証は ps を追加で叩くため、ゲートのたびに実行コストが増える。
# それでもキャッシュしない: キャッシュした結果を後続ゲートで使い回すことは「検査した時点」と
# 「実際に Enter を送る時点」を再び分離することになり、まさにこの関数が塞ごうとしている TOCTOU を
# 再導入してしまう。可用性よりも安全側を優先し、毎回取り直す。
# 【XREV_ALLOW_UNVERIFIED_REVIEWER=1】既存の opt-out 挙動を維持し、ポリシー検証部分だけを省略する
# （プロセス証明は省略しない）。警告ログは1往復（xrev_transport_review 1回の呼び出し）につき1回だけ
# 出す。ゲートは1往復で最大5回（(iii)/(iii-b)/(iii-c)/Enter再送最大2回）呼ばれ得るため、素朴に毎回
# 警告すると同じ内容が繰り返しログに積まれる。xrev_transport_review の先頭で _XREV_UNVERIFIED_WARNED
# をリセットし、このヘルパは「まだ警告していなければ出す」だけにする。
_xrev_gate_reviewer() {
  local surface="$1"
  _verify_reviewer_process "$surface" || return 17
  if [[ "${XREV_ALLOW_UNVERIFIED_REVIEWER:-}" == "1" ]]; then
    if [[ "${_XREV_UNVERIFIED_WARNED:-}" != "1" ]]; then
      _log "警告: XREV_ALLOW_UNVERIFIED_REVIEWER=1 のため reviewer の安全ポリシー検証を省略します（read-only/承認 never を保証しません）。"
      _XREV_UNVERIFIED_WARNED=1
    fi
    return 0
  fi
  # stdout のみ捨てる（不具合Aの対処により合格時は何も出さない契約だが、念のための防御）。
  # stderr は捨てない: 呼び出し側は理由文言をゲートごとに出し分けるため直接は使わないが、
  # 診断の手がかりとして残す。
  _xrev_verify_reviewer_policy "$surface" >/dev/null || return 27
  return 0
}

# ── 公開 API ─────────────────────────────────────────────────────────────────

# xrev_transport_review <payload_text>
#   payload を 1物理行にエンコードして reviewer へ送り、round_id 一致の SENTINEL JSON を返す。
#   成功: 0 / JSON を stdout。失敗: 非ゼロ / stderr にログ。
xrev_transport_review() {
  local payload="$1"
  # 不具合B対応: XREV_ALLOW_UNVERIFIED_REVIEWER=1 の警告は1往復につき1回に抑える
  # （_xrev_gate_reviewer が複数回呼ばれるため。往復ごとに毎回リセットする）。
  _XREV_UNVERIFIED_WARNED=""
  _cmux_preflight || return $?

  # reviewer 種別（REVIEWER_PROCESS の basename）に応じた送信完全性検証手段を決定する（C2）。
  # 未知種別（codex/claude 以外）は検証手段が確立していないため、cmux とやり取りする前に
  # fail closed で拒否する（新設 exit 28 = integrity_unverifiable）。
  local kind integrity_kind
  kind="$(basename -- "$REVIEWER_PROCESS")"
  if ! integrity_kind="$(_xrev_integrity_kind "$kind")"; then
    _log "reviewer 種別 '${kind}' は送信完全性の検証手段が確立していません（codex/claude 以外は fail closed）。"
    return 28
  fi

  # 【指摘3への対処・claude は参照モード専用】claude reviewer への inline 送信（本文をそのまま
  # wire に載せる方式）は、wire 長に関わらず完全性を確認する手段が無い。以前は composer 上で
  # wire 文字列と de-wrap 後の画面テキストを空白非依存で全文一致照合する経路を、一定の wire 長
  # 以下でのみ試みていたが、「空白の削除と挿入が相殺すれば比較・frame 検証のどちらもすり抜ける」
  # という2巡目クロスレビューの指摘（medium）を受け、完全性の証明にはならない可用性ヒューリス
  # ティックにすぎないと判断し撤去した（経緯は references/protocol.md「切り詰め検出」節）。
  # よって claude・inline は wire 長に関わらず無条件で cmux へは一切送信せず中止する
  # （exit 28 = integrity_unverifiable）。参照モード（XREV_REFERENCE_MODE=1）は本文を wire に
  # 載せず reviewer に自分の作業ツリーで diff-hash を取得させて返させる方式のため、この制限の
  # 対象外（完全性は diff_hash + 基底 HEAD の端到端照合が別途保証する。「参照モード」節参照）。
  if [[ "$kind" == "claude" && "${XREV_REFERENCE_MODE:-}" != "1" ]]; then
    _log "claude reviewer は参照モード専用です（inline は送信完全性を検証できないため無条件で拒否します）。実装フェーズは参照モード（XREV_REFERENCE_MODE=1）を使うこと。"
    return 28
  fi

  # 宛先解決（同一WSスコープ）。グローバル(_XREV_RES_*)を使うためサブシェルにしない。
  # 失敗コード（10/15/16/3）はそのまま返す（review-loop 側で transport_reason に写像）。
  local surface
  _XREV_RES_REF=""
  _cmux_resolve_surface >/dev/null; local rrc=$?
  if (( rrc != 0 )); then
    _log "reviewer ペイン（タイトル: '$REVIEWER_PANE_TITLE'）を解決できませんでした（code=${rrc}）。"
    _log "cmux 上に該当タイトルの reviewer（${REVIEWER_PROCESS}）ペインを 1 枚開いているか、XREV_REVIEWER_SURFACE で明示指定してください。"
    return "$rrc"
  fi
  surface="$_XREV_RES_REF"
  _log "reviewer surface = ${surface} path=${_XREV_RES_PATH}（title: '${REVIEWER_PANE_TITLE}'）"

  # 参照モード(Phase2)は同一WS解決時のみ許可（別worktree/別repoへの参照依頼=誤レビューを防ぐ機械強制）。
  # global / cross-WS 明示宛先では参照 payload を送らず、呼び出し側に inline 切替を促す。
  if [[ "${XREV_REFERENCE_MODE:-}" == "1" && "$_XREV_RES_PATH" != "same_ws" ]]; then
    _log "参照モードは同一WS解決(same_ws)時のみ許可します（現在 path=${_XREV_RES_PATH}）。inline へ切り替えてください。"
    return 18
  fi

  # ── 送信前ゲート（誤配送・shell誤実行の防止。@xrev 承認設計）──────────────────
  # (i) UUID 同一性・WS 所属の再検証（uuid を持つ経路 = same_ws / explicit）。
  #     ref再利用・WS移動・差し替え・宛先/呼び出し元の消失をすべて fail closed で弾く（fail-open を作らない）。
  if [[ -n "$_XREV_RES_UUID" && "$_XREV_RES_PATH" != "global" ]]; then
    local rtree; rtree="$(_cmux_tree_uuids)"
    if [[ -z "$rtree" ]]; then _log "送信直前の tree 取得に失敗しました（中止）。"; return 15; fi
    local rloc rlrc
    rloc="$(XREV_LISTING="$rtree" _locate_surface "$_XREV_RES_UUID")"; rlrc=$?
    if (( rlrc != 0 )); then
      _log "解決した reviewer surface(uuid=$_XREV_RES_UUID)を送信直前に一意特定できません（code=${rlrc}・中止）。"; return 15
    fi
    local cur_ref cur_ws
    cur_ref="$(printf '%s' "$rloc" | cut -f1)"; cur_ws="$(printf '%s' "$rloc" | cut -f3)"
    # 同一WS必須の経路では、reviewer の現WS一致 と caller の同一WS在席 をともに必須にする。
    if [[ "$_XREV_RES_SAMEWS" == "1" ]]; then
      if [[ -z "$_XREV_RES_WS" || -z "$cur_ws" || "$cur_ws" != "$_XREV_RES_WS" ]]; then
        _log "reviewer surface の所属ワークスペースが解決時から変化/不明です（誤配送防止のため中止）。"; return 15
      fi
      local rcloc rcrc caller_ws
      rcloc="$(XREV_LISTING="$rtree" _locate_surface "${CMUX_SURFACE_ID:-}")"; rcrc=$?
      caller_ws="$(printf '%s' "$rcloc" | cut -f3)"
      if (( rcrc != 0 )) || [[ -z "$caller_ws" || "$caller_ws" != "$_XREV_RES_WS" ]]; then
        _log "呼び出し元が同一ワークスペースに見つからない/別WSへ移動しました（誤配送防止のため中止）。"; return 15
      fi
    fi
    surface="$cur_ref"
  fi

  # (ii) 端末性プリフライト（read-screen 可否。非端末=exit14 / 消失=exit15 / 一時失敗は限定リトライ）
  local term tries=0
  while :; do
    term="$(_probe_terminal_usable "$surface")"
    [[ "$term" != "transient" ]] && break
    (( ++tries >= 3 )) && break
    _xrev_sleep 1
  done
  case "$term" in
    usable) ;;
    non_terminal)
      _log "reviewer surface($surface)は実ターミナルではありません。シェル端末内で codex CLI を起動してください（cmux エージェント統合パネルは read-screen 不可）。"
      return 14 ;;
    gone)
      _log "reviewer surface($surface)が送信直前に消失しました（誤配送防止のため中止）。"; return 15 ;;
    *) _log "reviewer surface($surface)の画面取得に繰り返し失敗しました（中止）。"; return 11 ;;
  esac

  # (iii) 早期ゲート: プロセス証明＋安全ポリシー実効検証を同じゲートでまとめて行う（不具合B対応。
  # 詳細は _xrev_gate_reviewer のコメント参照）。ここは早期棄却のゲート。payload 構築や画面読み取りの
  # 前に壊れた宛先を弾く。
  local gate_rc
  _xrev_gate_reviewer "$surface"; gate_rc=$?
  case "$gate_rc" in
    0) ;;
    17)
      _log "reviewer surface($surface)の前景プロセスが '$REVIEWER_PROCESS' ではありません（reviewer 未稼働/別用途の端末の恐れ）。送信を中止します。"
      _log "復旧: 当該ペインで codex を起動し直すか、タブ名 '$REVIEWER_PANE_TITLE' が別用途の端末に付いていないか確認してください。"
      return 17 ;;
    27)
      _log "reviewer surface($surface)が安全ポリシー（read-only + 承認 never）で起動していません。送信を中止します。"
      _log "復旧: ペインを閉じて ensure-reviewer で作り直すか、start-reviewer.sh で起動し直してください。"
      return 27 ;;
  esac

  # round_id（ラウンド識別子）と content_type を決め、payload を1物理行にエンコードする。
  # round_id は高エントロピー（衝突でスクロールバックの過去応答と混同しないため）。
  local round_id ct line
  round_id="${XREV_ROUND_ID:-$(python3 -c 'import secrets;print("r"+secrets.token_hex(8))' 2>/dev/null)}"
  [[ -n "$round_id" ]] || round_id="r$$$RANDOM$RANDOM"
  ct="${XREV_CONTENT_TYPE:-$(_detect_content_type "$payload")}"
  # encode の失敗（round_id/content_type 不正、不変条件違反、サロゲート単体など）は必ず送信中止にする。
  # 本スクリプトは set -e ではないため、rc を見ないと壊れた/空の wire をそのまま送ってしまう。
  # 専用コード(23)にするのは、cmux へ一度も送っていない失敗を「送信失敗(11)」として報告すると
  # 利用者向け診断や将来の再試行判断が不正確になるため。
  if ! line="$(printf '%s' "$payload" | _build_framed_line "$ct" "$round_id")" || [[ -z "$line" ]]; then
    _log "payload のエンコードに失敗しました（cmux へは送信していません）。"
    return 23
  fi
  _log "round_id=${round_id} content_type=${ct} len=${#line}"

  # wire 長の上限（fail closed）。実測（docs/cmux-behavior.md）で ASCII 100KB の送信が成功して
  # いるが、想定外に巨大な payload を安全側に倒して早期に弾くため保守的な既定値を設けている。
  if (( ${#line} > WIRE_MAX_CHARS )); then
    _log "wire が上限を超えました（実長=${#line} 上限=${WIRE_MAX_CHARS}）。payload を前回からの差分に縮めるか、XREV_WIRE_MAX_CHARS を明示して拡大してください。"
    return 26
  fi

  # 送信前ベースライン：この round_id に一致する妥当ブロック数（通常0、防御的に数える）。
  # broken（完成しているが不正なブロック）も同様にベースラインを取り、送信前から既に画面に
  # 残っている壊れた表示を「新着の契約違反」と誤検出しないようにする。
  local before_count before_broken screen_snapshot
  screen_snapshot="$(_cmux_read_screen "$surface")"
  before_count="$(printf '%s' "$screen_snapshot" | _scan_review_blocks "$round_id" | head -1)"
  [[ "$before_count" =~ ^[0-9]+$ ]] || before_count=0
  before_broken="$(printf '%s' "$screen_snapshot" | _scan_broken_blocks "$round_id")"
  [[ "$before_broken" =~ ^[0-9]+$ ]] || before_broken=0

  # (iii-b) 本文送信の直前に再検証。(iii) からベースライン取得（read-screen）を挟むため、
  # その間に reviewer が終了/入れ替わっていれば本文がシェルの入力バッファへ流れ込む、または
  # 無承認で確定されうる。プロセス証明と安全ポリシーを同じゲートで再検証する（不具合B対応）。
  _xrev_gate_reviewer "$surface"; gate_rc=$?
  case "$gate_rc" in
    0) ;;
    17) _log "本文送信の直前に reviewer の前景プロセスが変化しました（誤送信防止のため中止）。"; return 17 ;;
    27) _log "本文送信の直前に reviewer の安全ポリシーが不成立になりました（誤送信防止のため中止）。"; return 27 ;;
  esac

  # 1物理行を送信 → 描画待ち → 切り詰め検出 → Enter 1回で確定。
  _cmux_send_line "$surface" "$line" "$kind" || { _log "送信に失敗しました。"; return 11; }
  _xrev_sleep "$(_compute_submit_settle "${#line}")"
  # 切り詰め検出: 入力欄に送信本文が欠落なく到達したかを確認する（reviewer 種別で照合手段が異なる。
  # C2: codex=ペーストチップ文字数照合 / claude=参照モード専用のため本節の照合自体を行わない）。
  #   確認できた(ok) → submit / 不一致(truncated) → 中止 / 確認不能(unknown。codex のみ) → 警告して続行。
  # 確認不能で中止すると正常な往復まで壊すため、確実な不一致のときだけ失敗にする。
  #
  # 【claude は必ず参照モード】上の送信前ゲートで claude・inline は無条件 exit28 済みなので、
  # ここに到達する claude は常に参照モード（XREV_REFERENCE_MODE=1）である。参照モードは本文を
  # wire に載せないため、この照合を行っても意味を持たない（完全性は diff_hash + 基底 HEAD の
  # 端到端照合が別途保証する。「参照モード」節参照）。よって claude は常に照合をスキップして
  # "ok" 扱いにする。
  local end_marker="END_ROUND_${round_id}" intact="unknown" t=0
  if [[ "$kind" == "claude" ]]; then
    intact="ok"
  else
    while (( t < 8 )); do
      intact="$(_check_paste_intact "$surface" "${#line}" "$end_marker" "$kind")"
      [[ "$intact" == "ok" || "$intact" == "truncated" ]] && break
      _xrev_sleep 1; t=$(( t + 1 ))
    done
  fi
  if [[ "$intact" == "truncated" ]]; then
    _log "送信本文の到達を確認できませんでした（長さ=${#line}）。切り詰めの恐れがあるため中止します。"
    return 13
  fi
  # 【縮退の可視化・変更2】ここに到達するのは "ok" か "unknown" のみ（"truncated" は上で return 済み）。
  # unknown は codex 経路のみの縮退（claude は常に上の分岐で "ok" になるためここへは来ない）。
  # fail closed にすると正常運用まで壊すため続行はするが、この経路が恒常化するのは切り詰め検出
  # そのものが実質無効化されている（＝防護の縮退）ことを意味するため、利用者が見逃さないよう
  # 理由候補と保守手順まで含めた警告にする（挙動自体は従来どおり「続行」のまま）。
  if [[ "$intact" != "ok" ]]; then
    _log "警告: ペースト到達を確認できませんでした（確認不能=unknown）。続行しますが切り詰め検出は機能していません。"
    _log "確認不能の理由候補: (a) Codex TUI の「Pasted Content N chars」表示文言がバージョンアップで変わった"
    _log "                     (b) 本文が短くインライン表示された（END マーカー不可視）"
    _log "この警告が毎回出る場合は Codex TUI の文言変更が疑われます。切り詰め検出が実質無効化されているため、"
    _log "docs/cmux-behavior.md の該当節を確認のうえ _check_paste_intact の正規表現を実機の表示に合わせて更新してください。"
  fi

  # (iii-c) 最終ゲート: Enter の直前に再検証する。ここが安全目標の要。
  # 本文送信から描画待ち・切り詰め検出まで最大10秒前後あり、その間に reviewer が終了する/
  # 同名だが書き込み可能なプロセスへ挿げ替わる窓がある。しかも _check_paste_intact はシェルが
  # エコーした行でも END マーカーを見つけて "ok" を返すため、切り詰め検出は誤送信の防波堤にならない。
  # Enter を送るか否かを決める直前に、プロセス証明と安全ポリシーを同じゲートで再検証する
  # （不具合B対応）ことだけが、payload がコマンド実行される/無承認で確定される事故を防げる。
  _xrev_gate_reviewer "$surface"; gate_rc=$?
  if (( gate_rc != 0 )); then
    local taint_reason
    if (( gate_rc == 17 )); then
      taint_reason="Enter 送信の直前に reviewer の前景プロセスが変化しました。コマンド実行を避けるため Enter を送りません。"
    else
      taint_reason="Enter 送信の直前に reviewer の安全ポリシーが不成立になりました。コマンド実行を避けるため Enter を送りません。"
    fi
    _xrev_log_tainted_pane "$surface" "$taint_reason"
    return "$gate_rc"
  fi

  # (変更1) Enter 送信（プロンプト確定）の失敗を検知・限定リトライする。
  # 【なぜ無視してはいけないか】従来は `_cmux_submit || true` で失敗を握りつぶしていた。送信できて
  # いなければ Codex には何も届いておらず応答が来ないのは当然なのに、RESP_TIMEOUT(既定180秒)を
  # 丸ごと待って timeout(12) と誤診断してしまい、「送れなかった」と「Codex が返さない」を区別できない。
  # 【再試行の安全条件】Enter の再送は「前景が codex のまま、かつ安全ポリシーが崩れていない」ときだけ
  # 安全である。codex が死んで shell に落ちていれば Enter はコマンド実行になってしまうし、書き込み
  # 可能な同名プロセスへ挿げ替わっていれば無承認で確定してしまう。そのため各再試行の直前に必ず
  # _xrev_gate_reviewer（プロセス証明＋安全ポリシー、不具合B対応）を再実行し、いずれかが崩れていたら
  # 再試行せず (iii-c) と同じ汚染ペイン扱いにする。この安全条件は絶対に外さないこと。
  local submit_tries=0 submit_max_retries=2 submit_ok=0
  while :; do
    if _cmux_submit "$surface"; then
      submit_ok=1
      break
    fi
    (( submit_tries >= submit_max_retries )) && break
    submit_tries=$(( submit_tries + 1 ))
    _xrev_sleep 1
    _xrev_gate_reviewer "$surface"; gate_rc=$?
    if (( gate_rc != 0 )); then
      local taint_reason
      if (( gate_rc == 17 )); then
        taint_reason="Enter 再送の直前に reviewer の前景プロセスが変化しました。コマンド実行を避けるため再送しません。"
      else
        taint_reason="Enter 再送の直前に reviewer の安全ポリシーが不成立になりました。コマンド実行を避けるため再送しません。"
      fi
      _xrev_log_tainted_pane "$surface" "$taint_reason"
      return "$gate_rc"
    fi
  done
  if (( submit_ok == 0 )); then
    _log "Enter 送信(プロンプト確定)に失敗しました。本文は入力欄に残っています。"
    _log "reviewer ペインで手動で Enter を押すか、ペインを開き直してから再実行してください。"
    _log "注: 前景は codex のまま（直前に検証済み）なので shell への流入ではありませんが、"
    _log "残留本文があるため再送時に混入するおそれがあります。同じペインを使い回さないでください。"
    return 25
  fi

  # 応答待ち：round_id 一致の新着妥当ブロックが出るまで待つ。
  local waited=0 screen scan count block broken
  _xrev_sleep "$SETTLE_SECS"
  while (( waited < RESP_TIMEOUT )); do
    screen="$(_cmux_read_screen "$surface")"
    scan="$(printf '%s' "$screen" | _scan_review_blocks "$round_id")"
    count="$(printf '%s' "$scan" | head -1)"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    if (( count > before_count )); then
      block="$(printf '%s' "$scan" | tail -n +2)"
      printf '%s\n' "$block"
      return 0
    fi
    # 妥当ブロックが増えていない場合、「完成しているが JSON として不正」な応答が新規に
    # 現れていないかを確認する。実機で観測: reviewer がセンチネルで挟んだ本文を返したが
    # JSON が壊れていて _scan_review_blocks では永遠に検出できず、タイムアウト(12)まで
    # 全時間を無駄に待った。ここで先に検出し、タイムアウトを待たず即座に契約違反として返す。
    broken="$(printf '%s' "$screen" | _scan_broken_blocks "$round_id")"
    [[ "$broken" =~ ^[0-9]+$ ]] || broken=0
    if (( broken > before_broken )); then
      _log "reviewer の応答はセンチネルで完成していますが JSON として不正です（契約違反, round_id=${round_id}）。内容は画面に出ているためログには件数のみ記録します（broken=${broken}）。"
      return 24
    fi
    _xrev_sleep "$RESP_POLL"
    waited=$(( waited + RESP_POLL ))
  done

  _log "reviewer の応答がタイムアウトしました（${RESP_TIMEOUT}s, round_id=${round_id} の新着なし）。"
  return 12
}

# sleep ラッパ（フォアグラウンド sleep が制限される環境向けの薄い抽象）。
_xrev_sleep() { sleep "$1" 2>/dev/null || true; }

# ── doctor: 外部ツール契約の一括診断（非破壊・再実行可能）───────────────────────
#
# 【背景】xrev は cmux / Codex / Claude Code のバージョンアップのたびに壊れるが、壊れ方が
# 「全拒否」「タイムアウト」「無言沈黙」に化けて原因が読めない。ここで外部ツールへの契約仮定
# （tree/top の JSON・TSV 形状、ps の出力形式、フックの入出力契約 等）を一括検査し、
# 人間可読な診断を出す。
#
# 【不変条件】検査はすべて非変更・再実行可能。ペイン生成・送信・タイトル変更などの副作用を
# 持つ検査は絶対に追加しないこと（doctor は「壊れているかもしれない配管に触れず調べる」ためのもの）。
#
# 出力: 1検査1行 "[ok]/[warn]/[fail] 検査名: 詳細"（stdout。機械処理より人間可読を優先するため
# あえて stderr ではなく stdout に出す）。最後に "ok=N warn=N fail=N" のサマリ行。
# exit: fail>0 → 1 / fail=0 → 0（warn は exit に影響しない）。詳細は references/protocol.md。

# 純粋関数（cmux 非依存・単体テスト可能）: cmux tree の JSON が想定形状か検査する（doctor 検査5）。
#   入力: stdin=tree(--all --json --id-format both 相当)の JSON 文字列
#   出力: 1行診断（成功・失敗いずれも1行）
#   exit: 0=形状OK（ref="surface:*" title(str) uuid/id/uidいずれか、を持つ要素が1件以上）/ 非0=崩れ
_doctor_check_tree_shape() {
  local prog
  read -r -d '' prog <<'PY' || true
import json, sys
raw = sys.stdin.read()
if not raw.strip():
    print("tree の出力が空です")
    sys.exit(1)
try:
    data = json.loads(raw)
except Exception as e:
    print("JSON として parse できません: %s" % e)
    sys.exit(1)

count = 0
def walk(o):
    global count
    if isinstance(o, dict):
        ref = o.get("ref")
        title = o.get("title")
        if isinstance(ref, str) and ref.startswith("surface:") and isinstance(title, str):
            if any(k in o for k in ("uuid", "id", "uid")):
                count += 1
        for v in o.values():
            if isinstance(v, (list, dict)):
                walk(v)
    elif isinstance(o, list):
        for x in o:
            walk(x)
walk(data)
if count == 0:
    print('ref="surface:*" title(str) かつ uuid/id/uid のいずれかを持つ要素が見つかりません')
    sys.exit(1)
print("surface 要素を %d 件確認しました" % count)
PY
  python3 -c "$prog"
}

# 純粋関数（cmux 非依存・単体テスト可能）: cmux top の TSV が想定形状か検査する（doctor 検査6）。
#   入力: stdin=top(--all --processes --format tsv 相当)の TSV 文字列
#   出力: 1行診断
#   exit: 0=形状OK（7列以上・kind列(4列目)にprocessが存在・process行の5列目が数値PID）/ 非0=崩れ
_doctor_check_top_shape() {
  local prog
  read -r -d '' prog <<'PY' || true
import sys
raw = sys.stdin.read()
if not raw.strip():
    print("top の出力が空です")
    sys.exit(1)
lines = [l for l in raw.splitlines() if l.strip() != ""]
has_process = False
for l in lines:
    cols = l.split("\t")
    if len(cols) < 7:
        print("TSV の列数が7列未満の行があります: %r" % l)
        sys.exit(1)
    if cols[3] == "process":
        has_process = True
        pid = cols[4]
        if not pid.isdigit():
            print("process 行の PID(5列目)が数値ではありません: %r" % pid)
            sys.exit(1)
if not has_process:
    print("kind(4列目)=process の行が見つかりません")
    sys.exit(1)
print("top TSV を確認しました（%d 行・process 行あり）" % len(lines))
PY
  python3 -c "$prog"
}

# doctor: 1検査1行の報告と ok/warn/fail 集計。
_DOCTOR_OK=0; _DOCTOR_WARN=0; _DOCTOR_FAIL=0
_doctor_report() {
  local level="$1" name="$2" detail="$3"
  case "$level" in
    ok)   _DOCTOR_OK=$(( _DOCTOR_OK + 1 )) ;;
    warn) _DOCTOR_WARN=$(( _DOCTOR_WARN + 1 )) ;;
    fail) _DOCTOR_FAIL=$(( _DOCTOR_FAIL + 1 )) ;;
  esac
  printf '[%s] %s: %s\n' "$level" "$name" "$detail"
}

# 公開: 外部ツール契約の一括診断本体。検査は独立に実行し、1つの失敗で後続を止めない。
xrev_doctor() {
  _DOCTOR_OK=0; _DOCTOR_WARN=0; _DOCTOR_FAIL=0

  # 1) python3: 存在とバージョン
  if command -v python3 >/dev/null 2>&1; then
    _doctor_report ok "python3" "$(python3 --version 2>&1)"
  else
    _doctor_report fail "python3" "python3 が見つかりません（以降 python3 が要る検査は実行できません）"
  fi

  # 2) cmux バイナリ: 解決結果とバージョン。実測検証済み(0.64.20)と異なれば warn（fail にはしない）。
  local known_ver="0.64.20" cmux_ver
  if command -v "$CMUX_BIN" >/dev/null 2>&1 || [[ -x "$CMUX_BIN" ]]; then
    cmux_ver="$(_cmux --version 2>&1 | head -1)"
    if [[ -z "$cmux_ver" ]]; then
      _doctor_report warn "cmux バイナリ" "bin=${CMUX_BIN} バージョンを取得できません"
    elif printf '%s' "$cmux_ver" | grep -qF "$known_ver"; then
      _doctor_report ok "cmux バイナリ" "bin=${CMUX_BIN} version=${cmux_ver}"
    else
      _doctor_report warn "cmux バイナリ" "bin=${CMUX_BIN} version=${cmux_ver}（実測検証済みは ${known_ver}。docs/cmux-behavior.md の実測知見が当てはまらない可能性。挙動が変わっていないか注意してください）"
    fi
  else
    _doctor_report fail "cmux バイナリ" "見つかりません（bin=${CMUX_BIN}）。cmux ペイン内で実行するか XREV_CMUX_BIN で絶対パスを指定してください"
  fi

  # 3) cmux 接続: _cmux_preflight 相当（ping）。
  if _cmux_preflight >/dev/null 2>&1; then
    _doctor_report ok "cmux 接続" "ping 成功（bin=${CMUX_BIN}）"
  else
    _doctor_report fail "cmux 接続" "ping に失敗しました。xrev は cmux ペイン内で実行してください（外部から動かす場合は CMUX_SOCKET_PASSWORD を設定）"
  fi

  # 4) env 注入: CMUX_SURFACE_ID(無しはfail) / CMUX_WORKSPACE_ID(無しはwarn)
  if [[ -n "${CMUX_SURFACE_ID:-}" ]]; then
    _doctor_report ok "env 注入(CMUX_SURFACE_ID)" "CMUX_SURFACE_ID=${CMUX_SURFACE_ID}"
  else
    _doctor_report fail "env 注入(CMUX_SURFACE_ID)" "未注入です（同一ワークスペースの宛先解決ができません。cmux ペイン内で実行してください）"
  fi
  if [[ -n "${CMUX_WORKSPACE_ID:-}" ]]; then
    _doctor_report ok "env 注入(CMUX_WORKSPACE_ID)" "CMUX_WORKSPACE_ID=${CMUX_WORKSPACE_ID}"
  else
    _doctor_report warn "env 注入(CMUX_WORKSPACE_ID)" "未注入です"
  fi

  # 5) tree 形状（_doctor_check_tree_shape に委譲）
  local tree tree_msg tree_rc
  tree="$(_cmux_tree_uuids)"
  tree_msg="$(printf '%s' "$tree" | _doctor_check_tree_shape)"; tree_rc=$?
  if (( tree_rc == 0 )); then
    _doctor_report ok "tree 形状" "$tree_msg"
  else
    _doctor_report fail "tree 形状" "cmux tree の JSON 形状が想定と異なります（バージョンアップで宛先解決が壊れている可能性）: ${tree_msg}"
  fi

  # 6) top 形状（_doctor_check_top_shape に委譲）
  local top top_msg top_rc
  top="$(_cmux_top_processes)"
  top_msg="$(printf '%s' "$top" | _doctor_check_top_shape)"; top_rc=$?
  if (( top_rc == 0 )); then
    _doctor_report ok "top 形状" "$top_msg"
  else
    _doctor_report fail "top 形状" "cmux top の TSV 形状が想定と異なります（プロセス証明が全拒否になっている可能性）: ${top_msg}"
  fi

  # 7) ps 契約: 「pid pgid tpgid comm」の4フィールドを返すこと
  local ps_out
  ps_out="$(printf '%s\n' "$$" | _ps_snapshot)"
  if [[ -n "$ps_out" ]] && printf '%s\n' "$ps_out" | awk 'NF != 4 { exit 1 }'; then
    _doctor_report ok "ps 契約" "pid pgid tpgid comm の4フィールドを確認しました（$(printf '%s' "$ps_out" | head -1)）"
  else
    _doctor_report fail "ps 契約" "ps が「pid pgid tpgid comm」の4フィールドを返しません（出力=${ps_out}）"
  fi

  # 7b) argv 境界保持取得(procargs2) 自己診断: 自プロセスの argv を sysctl(KERN_PROCARGS2) で
  # 取得できるか（指摘2で導入した新方式そのものの生死診断）。非 macOS・権限不足では成立しないのが
  # 仕様（安全ポリシー実効検証は fail closed に倒れる）なので、ここでは warn に留めて環境情報として
  # 扱う（fail にはしない。CI の Linux ジョブでも成立しない前提）。
  local procargs_out
  procargs_out="$(printf '%s\n' "$$" | _xrev_procargs2_snapshot)"
  if [[ -n "$procargs_out" ]] && printf '%s\n' "$procargs_out" | python3 -c '
import json, sys
ok = True
seen = False
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    pid_s, tab, blob = line.partition("\t")
    if not tab:
        ok = False; break
    try:
        argv = json.loads(blob)
    except ValueError:
        ok = False; break
    if not isinstance(argv, list) or not argv:
        ok = False; break
    seen = True
sys.exit(0 if (ok and seen) else 1)
' 2>/dev/null; then
    _doctor_report ok "argv境界保持取得(procargs2)" "自プロセスの argv を sysctl(KERN_PROCARGS2) 経由で取得できました"
  else
    _doctor_report warn "argv境界保持取得(procargs2)" "この環境では sysctl(KERN_PROCARGS2) 経由の argv 取得ができません（非macOS・権限不足の可能性。安全ポリシー実効検証は fail closed で exit 27/19 になります）"
  fi

  # 8) reviewer 解決: 環境状態の情報表示（present以外もfailにはしない）
  _XREV_RES_REF=""
  _cmux_resolve_surface >/dev/null 2>&1
  local resolve_rc=$?
  case "$resolve_rc" in
    0)  _doctor_report ok "reviewer 解決" "present（surface=${_XREV_RES_REF} path=${_XREV_RES_PATH}）" ;;
    10) _doctor_report warn "reviewer 解決" "absent（ensure-reviewer で生成可能です）" ;;
    *)  _doctor_report warn "reviewer 解決" "code=${resolve_rc}（環境状態の情報であり契約違反ではないため fail にはしません）" ;;
  esac

  # 9) reviewer バイナリ（不在は警告）・launch 引数の決定可否（失敗は fail）
  local codex; codex="$(_xrev_reviewer_bin)"
  if command -v "$codex" >/dev/null 2>&1; then
    _doctor_report ok "reviewer バイナリ" "bin=${codex} version=$("$codex" --version 2>&1 | head -1)"
  else
    _doctor_report warn "reviewer バイナリ" "見つかりません（bin=${codex}）。送信検証は前景プロセス名しか見ないため致命ではありませんが、ensure-reviewer は失敗します"
  fi
  local largs_out
  if largs_out="$(_xrev_reviewer_launch_args "$codex" 2>&1)"; then
    _doctor_report ok "reviewer launch 引数" "$(printf '%s' "$largs_out" | tr '\n' ' ')"
  else
    _doctor_report fail "reviewer launch 引数" "決定できません（自動生成が全滅します）: ${largs_out}"
  fi

  # 10) フック契約セルフテスト
  # 【限界】これは「xrev 側の実装が契約どおりか」の検証にすぎない。Claude Code 本体が
  # UserPromptSubmit のフィールド名やイベント仕様そのものを変えた場合は検出できない。
  local hook_path out_a out_b
  hook_path="$(_xrev_script_dir)/../hooks/user-prompt-submit.sh"
  if [[ -f "$hook_path" ]]; then
    out_a="$(printf '%s' '{"prompt":"@xrev テスト"}' | XREV_CONFIG="$XREV_CONFIG" bash "$hook_path" 2>/dev/null)"
    out_b="$(printf '%s' '{"prompt":"関係ない話"}' | XREV_CONFIG="$XREV_CONFIG" bash "$hook_path" 2>/dev/null)"
    if [[ "$out_a" == *additionalContext* && -z "$out_b" ]]; then
      _doctor_report ok "フック契約セルフテスト" "@xrev 検知時に additionalContext を出力し、非検知時は無出力でした"
    else
      _doctor_report fail "フック契約セルフテスト" "フックの入出力契約が壊れています（Claude Code の仕様変更または plugin 破損）"
    fi
  else
    _doctor_report fail "フック契約セルフテスト" "フック本体が見つかりません（path=${hook_path}）"
  fi

  # 11) 検出不能な既知の縮退（検査ではなく固定の info 行）
  printf '[info] 既知の検出不能な縮退: Codex TUI の "Pasted Content N chars" 文言と cmux エラー文言（"not a terminal" 等）の変更は doctor では検出できません。切り詰め検出の unknown 警告が毎回出る場合は文言変更を疑ってください。\n'

  printf 'ok=%d warn=%d fail=%d\n' "$_DOCTOR_OK" "$_DOCTOR_WARN" "$_DOCTOR_FAIL"
  (( _DOCTOR_FAIL == 0 ))
}

# 直接実行されたら簡易セルフテスト（実機用）。source されたときは何もしない。
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  case "${1:-}" in
    ping)
      _cmux_preflight && echo "(cmux 接続OK: $CMUX_BIN)" >&2 ;;
    resolve)
      _cmux_preflight || exit $?
      if [[ "${2:-}" == "--json" ]]; then
        # 機械可読の診断契約: 解決結果と検証状態を JSON で返す（スキル/デバッグ用）。
        _XREV_RES_REF=""
        _cmux_resolve_surface >/dev/null; rc=$?
        XREV_RREF="$_XREV_RES_REF" XREV_RUUID="$_XREV_RES_UUID" XREV_RWS="$_XREV_RES_WS" \
        XREV_RPATH="$_XREV_RES_PATH" XREV_RRC="$rc" python3 -c '
import json, os
rc = int(os.environ.get("XREV_RRC", "1") or 1)
print(json.dumps({
    "ok": rc == 0,
    "exit_code": rc,
    "surface_ref": os.environ.get("XREV_RREF", "") or None,
    "surface_uuid": os.environ.get("XREV_RUUID", "") or None,
    "workspace": os.environ.get("XREV_RWS", "") or None,
    "resolve_path": os.environ.get("XREV_RPATH", "") or None,
}, ensure_ascii=False))'
        exit "$rc"
      fi
      _cmux_resolve_surface && echo " (resolve ok: path=${_XREV_RES_PATH})" >&2 ;;
    set-title)
      # 呼び出し元タブのタイトルを設定（起動ヘルパ用。cmux 依存を transport.sh に閉じる）。
      _cmux_preflight || exit $?
      shift
      [[ -n "${1:-}" ]] || { _log "set-title: タイトルを指定してください"; exit 64; }
      _cmux_set_title "$1" ;;
    diff-hash)
      # 参照モードの期待ハッシュを計算する（cmux 不要・git のみ）。primary が expected_diff_hash を得る。
      # git/hash 失敗は非ゼロで返し、空ハッシュを正常結果として返さない。
      shift
      _h="$(xrev_diff_hash "${1:-HEAD}")"; _rc=$?
      (( _rc == 0 )) || exit "$_rc"
      [[ -n "$_h" ]] || exit 1
      printf '%s\n' "$_h" ;;
    ensure-reviewer)
      # 同一WSの reviewer を保証（あれば採用・無ければ生成）。採用 surface ref を stdout に出す。
      xrev_ensure_reviewer; exit $? ;;
    review)
      shift
      xrev_transport_review "${1:-テスト payload}" ;;
    doctor)
      # 外部ツール契約の一括診断（バージョンアップ後はまず実行）。非破壊・再実行可能。
      xrev_doctor; exit $? ;;
    *)
      cat >&2 <<USAGE
usage:
  transport.sh ping                 # cmux 接続（実行コンテキスト）の確認
  transport.sh resolve              # reviewer surface の解決のみ確認
  transport.sh resolve --json       # 解決結果＋検証状態を JSON で返す（診断契約）
  transport.sh set-title "<title>"  # 呼び出し元タブのタイトルを設定（起動ヘルパ用）
  transport.sh diff-hash [<range>]  # 参照モードの決定論 diff ハッシュ（既定 HEAD）
  transport.sh ensure-reviewer      # 同一WSの reviewer を保証（あれば採用・無ければ生成）
  transport.sh review "<payload>"   # 1往復だけ送って JSON を受ける
  transport.sh doctor               # 外部ツール契約の一括診断（非破壊・再実行可能）
USAGE
      exit 64 ;;
  esac
fi
