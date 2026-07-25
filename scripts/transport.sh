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

# 環境変数で上書きできる設定（テスト・運用都合）
REVIEWER_PANE_TITLE="${XREV_REVIEWER_PANE_TITLE:-$(_cfg reviewer_pane_title 'Review Codex')}"
# 送信前の安全ゲートで「宛先サーフェスで動いているべきプロセス名」（既定 codex）。
# プロセス証明: cmux top でこのプロセスが対象サーフェスの直下で動いていることを確認する。
REVIEWER_PROCESS="${XREV_REVIEWER_PROCESS:-$(_cfg reviewer_process 'codex')}"
# 安全側既定の opt-in。CMUX_SURFACE_ID 未注入時のみグローバル解決を許す / 明示サーフェスの別WS送信を許す。
ALLOW_GLOBAL_RESOLVE="${XREV_ALLOW_GLOBAL_RESOLVE:-$(_cfg allow_global_resolve 'false')}"
ALLOW_CROSS_WS="${XREV_ALLOW_CROSS_WS:-$(_cfg allow_cross_ws 'false')}"
# reviewer ペインの自動生成（create-if-missing）。ask(既定)/auto/off。生成の起動確認・競合待ちの上限秒。
REVIEWER_AUTOCREATE="${XREV_REVIEWER_AUTOCREATE:-$(_cfg reviewer_autocreate 'ask')}"
CREATE_TIMEOUT="${XREV_REVIEWER_CREATE_TIMEOUT_SECONDS:-$(_cfg reviewer_create_timeout_seconds 30)}"
[[ "$CREATE_TIMEOUT" =~ ^[0-9]+$ ]] || CREATE_TIMEOUT=30
# wire（1物理行）の文字数上限（fail closed）。数値検証に加え範囲も検証し、範囲外・非数値は既定へ
# フォールバックする（CREATE_TIMEOUT と同様の方針）。根拠・詳細は references/protocol.md 参照。
WIRE_MAX_CHARS="${XREV_WIRE_MAX_CHARS:-$(_cfg wire_max_chars 64000)}"
[[ "$WIRE_MAX_CHARS" =~ ^[0-9]+$ ]] || WIRE_MAX_CHARS=64000
(( WIRE_MAX_CHARS >= 1000 && WIRE_MAX_CHARS <= 1000000 )) || WIRE_MAX_CHARS=64000
READ_LINES="${XREV_READ_SCREEN_LINES:-$(_cfg read_screen_lines 400)}"
SETTLE_SECS="${XREV_SEND_SETTLE_SECONDS:-$(_cfg send_settle_seconds 2)}"
RESP_TIMEOUT="${XREV_RESPONSE_TIMEOUT_SECONDS:-$(_cfg response_timeout_seconds 180)}"
RESP_POLL="${XREV_RESPONSE_POLL_SECONDS:-$(_cfg response_poll_seconds 3)}"

# reviewer の JSON 応答を画面から確実に切り出すためのセンチネル。
# Codex には「この 2 行で JSON を挟んで返せ」と指示し、画面ノイズから機械的に抽出する。
SENTINEL_BEGIN='===XREV-JSON-BEGIN==='
SENTINEL_END='===XREV-JSON-END==='

_log() { printf '[xrev/transport] %s\n' "$*" >&2; }

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
_verify_reviewer_process() {
  local surface="$1" top direct ps_out detail
  top="$(_cmux_top_processes)"
  [[ -n "$top" ]] || { _log "cmux top を取得できません（プロセス証明不可）。"; return 1; }
  direct="$(XREV_TOP="$top" _top_surface_processes "$surface")"
  [[ -n "$direct" ]] || { _log "reviewer surface($surface)の直下プロセスを特定できません。"; return 1; }
  ps_out="$(printf '%s\n' "$direct" | cut -f1 | _ps_snapshot)"
  detail="$(XREV_DIRECT="$direct" XREV_PS="$ps_out" _decide_foreground_owner "$REVIEWER_PROCESS")" || {
    _log "reviewer surface($surface)のプロセス証明に失敗: ${detail}"
    return 1
  }
}

# reviewer ペインの最終確定入力（プロンプト送信）。本文（1物理行）を送り終えたあとに呼ぶ。
_cmux_submit() {
  local surface="$1"
  _xrev_build_addr "$surface"
  _cmux send-key "${_XREV_ADDR[@]}" enter >/dev/null 2>&1 || return 7
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
  base="${XREV_SUBMIT_SETTLE_SECONDS:-$(_cfg submit_settle_seconds 1)}"
  [[ "$base" =~ ^[0-9]+$ ]] || base=1
  extra=$(( len / 2000 ))
  settle=$(( base + extra ))
  (( settle > 8 )) && settle=8
  printf '%s' "$settle"
}

# reviewer ペインの入力欄をクリアする（残留テキスト/ペーストチップの除去）。best-effort。
# ctrl-u（行クリア）と backspace（ペーストチップ削除）のみ使う。ctrl-c/Escape は
# 生成を中断し得るので使わない（アイドル化はしない=実行中の処理は止めない）。
_cmux_clear_input() {
  local surface="$1" _i
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
_cmux_send_line() {
  local surface="$1" line="$2" tries=0 max="${XREV_SEND_RETRIES:-5}"
  local err rc rcs="" last_err=""
  # stderr はコマンド置換で受ける。**production に一時ファイルを持ち込まない**のが要点で、
  # 予測可能な名前による symlink 追従・権限・シグナル時の残留という問題群を構造的に排除する。
  # （_cmux は "$CMUX_BIN" "$@" で状態を持たないため、サブシェル化しても実挙動は変わらない。
  #   スタブが状態を持つのはテストの都合であり、その面倒はテスト側で引き受ける。）
  _cmux_clear_input "$surface"          # 残留を除去してから送る（混入による prompt 破壊を防ぐ）
  _xrev_build_addr "$surface"
  while (( tries < max )); do
    err="$(_cmux send "${_XREV_ADDR[@]}" "$line" 2>&1 1>/dev/null)"; rc=$?
    (( rc == 0 )) && return 0
    rcs="${rcs}${rcs:+,}${rc}"; last_err="$err"
    # 失敗：busy/残留の可能性 → 少し待ち、再度クリアして再試行（busy 解消を待つ）。
    tries=$(( tries + 1 ))
    _xrev_sleep 2
    _cmux_clear_input "$surface"
  done
  # 全滅時のみ診断を出す（成功時に無用なログを増やさない）。バイト長は仮説検証の主要な手掛かり。
  local nbytes; nbytes="$(printf '%s' "$line" | wc -c | tr -d ' ')"
  _log "送信に ${max} 回失敗しました（rc=[${rcs}] 文字数=${#line} バイト数=${nbytes}）。"
  _log "cmux stderr: $(printf '%s' "$line" | XREV_DIAG_ERR="$last_err" _xrev_redact_diag)"
  return 6
}

# 送信本文が入力欄に欠落なく到達したかを判定する（切り詰め検出）。
#   stdout: "ok"（到達確認）/ "truncated"（文字数不一致＝切り詰め）/ "unknown"（確認不能）
# Codex の TUI は長いペーストを「[Pasted Content N chars]」へ畳むため、END_ROUND マーカーは
# 画面に出ない。その代わり表示される文字数 N が送信長と一致するかで欠落を検出する。
# 短いペーストはインライン表示されるので、その場合は de-wrap して末尾マーカーで確認する。
_check_paste_intact() {
  local surface="$1" elen="$2" marker="$3" screen
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

# シェルに渡す値を単一引数として安全にクォート（XREV_CODEX_BIN 注入対策）。printf %q は shell-safe。
_xrev_shquote() { printf '%q' "$1"; }

# 呼び出し元(CMUX_SURFACE_ID)の所属ワークスペース UUID を返す。
_xrev_caller_ws() {
  [[ -n "${CMUX_SURFACE_ID:-}" ]] || return 1
  local tree loc
  tree="$(_cmux_tree_uuids)"; [[ -n "$tree" ]] || return 1
  loc="$(XREV_LISTING="$tree" _locate_surface "$CMUX_SURFACE_ID")" || return 1
  printf '%s' "$(printf '%s' "$loc" | cut -f3)"
}

# 同一WSの reviewer の状態を分類する（_cmux_resolve_surface ＋ probe）。
#   stdout: present|absent|ambiguous|non_terminal|process_mismatch|ws_error|transient
#   exit:   0(present) / 10(absent) / 16(ambiguous) / 14(non_terminal) / 17(process_mismatch) / 15(ws_error) / 1(transient)
# present のときグローバル _XREV_RES_* に解決結果が入る。
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
  if _verify_reviewer_process "$_XREV_RES_REF"; then
    printf 'present'; return 0
  fi
  printf 'process_mismatch'; return 17
}

# ロックパス（TMPDIR 配下・WS UUID 鍵。リポジトリには絶対に作らない）。
_xrev_lock_path() {
  local ws="$1" base safe
  base="${TMPDIR:-/tmp}"; base="${base%/}"
  safe="$(printf '%s' "$ws" | tr -c 'A-Za-z0-9' '_')"
  printf '%s/xrev-reviewer-%s.lock' "$base" "$safe"
}

# 生成本体: caller WS に terminal ペインを作り、所有 surface UUID を固定して codex を起動・確認する。
# 成功で _XREV_RES_* に生成結果を入れて 0、起動確認失敗で 19。
_xrev_create_reviewer() {
  local ws="$1" codex="${XREV_CODEX_BIN:-codex}"
  command -v "$codex" >/dev/null 2>&1 || { _log "codex バイナリ '$codex' が見つかりません（XREV_CODEX_BIN で指定可）。"; return 19; }
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
  # codex を exec で起動（shell-safe にクォート）。
  # 【実機知見】タブのリネームは「codex 起動の前」に行うと、codex が起動時に cwd 由来の名前(例 "xrev")で
  #   タブ名を上書きしてしまい、reviewer_pane_title が定着しない（→ 次回の title 解決が当たらず冪等性が崩れる）。
  #   そのため rename は**起動確認の後**に行う（post-startup rename は上書きされず定着することを実機確認）。
  #   また rename-tab も read/send 同様 workspace+surface UUID 指定が必要（短縮 ref/uuid 単独は "Tab not found"）。
  _cmux send --workspace "$ws" --surface "$sf" "exec $(_xrev_shquote "$codex")" >/dev/null 2>&1
  _cmux send-key --workspace "$ws" --surface "$sf" enter >/dev/null 2>&1
  # 起動確認（同一試行内で read+top）。所有 UUID にだけ作用。
  local deadline=$(( SECONDS + CREATE_TIMEOUT )) term
  while (( SECONDS < deadline )); do
    _xrev_sleep 1
    term="$(_probe_terminal_usable "$_XREV_RES_REF")"
    if [[ "$term" == "usable" ]] && _verify_reviewer_process "$_XREV_RES_REF"; then
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
# exit: 0 / 10(absent かつ autocreate=off) / 14/16/17(既存が壊れ/曖昧/別物→人間) / 15(ws不明) /
#       19(生成したが起動確認失敗) / 20(競合で期限切れ→人間)。
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
        16|14|17|15) return "$rc" ;;
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

# ── 公開 API ─────────────────────────────────────────────────────────────────

# xrev_transport_review <payload_text>
#   payload を 1物理行にエンコードして reviewer へ送り、round_id 一致の SENTINEL JSON を返す。
#   成功: 0 / JSON を stdout。失敗: 非ゼロ / stderr にログ。
xrev_transport_review() {
  local payload="$1"
  _cmux_preflight || return $?
  # 宛先解決（同一WSスコープ）。グローバル(_XREV_RES_*)を使うためサブシェルにしない。
  # 失敗コード（10/15/16/3）はそのまま返す（review-loop 側で transport_reason に写像）。
  local surface
  _XREV_RES_REF=""
  _cmux_resolve_surface >/dev/null; local rrc=$?
  if (( rrc != 0 )); then
    _log "reviewer ペイン（タイトル: '$REVIEWER_PANE_TITLE'）を解決できませんでした（code=${rrc}）。"
    _log "cmux 上に該当タイトルの Codex ペインを 1 枚開いているか、XREV_REVIEWER_SURFACE で明示指定してください。"
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

  # (iii) プロセス証明（前景プロセスが許可名=$REVIEWER_PROCESS か。Codex 終了後に shell へ戻った端末への誤送信を防ぐ）
  # ここは早期棄却のゲート。payload 構築や画面読み取りの前に壊れた宛先を弾く。
  if ! _verify_reviewer_process "$surface"; then
    _log "reviewer surface($surface)の前景プロセスが '$REVIEWER_PROCESS' ではありません（reviewer 未稼働/別用途の端末の恐れ）。送信を中止します。"
    _log "復旧: 当該ペインで codex を起動し直すか、タブ名 '$REVIEWER_PANE_TITLE' が別用途の端末に付いていないか確認してください。"
    return 17
  fi

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
  local before_count
  before_count="$(_cmux_read_screen "$surface" | _scan_review_blocks "$round_id" | head -1)"
  [[ "$before_count" =~ ^[0-9]+$ ]] || before_count=0

  # (iii-b) 本文送信の直前に再検証。(iii) からベースライン取得（read-screen）を挟むため、
  # その間に codex が終了していれば本文がシェルの入力バッファへ流れ込む。窓を最小化する。
  if ! _verify_reviewer_process "$surface"; then
    _log "本文送信の直前に reviewer の前景プロセスが変化しました（誤送信防止のため中止）。"
    return 17
  fi

  # 1物理行を送信 → 描画待ち → 切り詰め検出 → Enter 1回で確定。
  _cmux_send_line "$surface" "$line" || { _log "送信に失敗しました。"; return 11; }
  _xrev_sleep "$(_compute_submit_settle "${#line}")"
  # 切り詰め検出: 入力欄に送信本文が欠落なく到達したかを確認する。
  #   確認できた(ok) → submit / 文字数不一致(truncated) → 中止 / 確認不能(unknown) → 警告して続行。
  # 確認不能で中止すると正常な往復まで壊すため、確実な不一致のときだけ失敗にする。
  local end_marker="END_ROUND_${round_id}" intact="unknown" t=0
  while (( t < 8 )); do
    intact="$(_check_paste_intact "$surface" "${#line}" "$end_marker")"
    [[ "$intact" == "ok" || "$intact" == "truncated" ]] && break
    _xrev_sleep 1; t=$(( t + 1 ))
  done
  if [[ "$intact" == "truncated" ]]; then
    _log "ペースト文字数が送信長(${#line})と一致しません。切り詰めの恐れがあるため中止します。"
    return 13
  fi
  [[ "$intact" == "ok" ]] || _log "ペースト到達を確認できませんでした（確認不能）。続行します。"

  # (iii-c) 最終ゲート: Enter の直前に再検証する。ここが安全目標の要。
  # 本文送信から描画待ち・切り詰め検出まで最大10秒前後あり、その間に codex が終了すると本文は
  # シェルの入力行に残る。しかも _check_paste_intact はシェルがエコーした行でも END マーカーを
  # 見つけて "ok" を返すため、切り詰め検出は誤送信の防波堤にならない。Enter を送るか否かを
  # 決める直前の観測だけが、payload がコマンド実行される事故を防げる。
  if ! _verify_reviewer_process "$surface"; then
    _log "Enter 送信の直前に reviewer の前景プロセスが変化しました。コマンド実行を避けるため Enter を送りません。"
    # 【重要】Enter を送らないだけでは安全な終端にならない。送信済みの本文は入力行に残り、
    # 前景が shell に戻っている以上、その後の偶発的な Enter や再送でコマンド実行され得る。
    # かつ Codex の composer は ctrl+u/ctrl+a/ctrl+k/ctrl+w で消去できないことを実機確認済みで
    # （反応するのは backspace の1文字ずつのみ）、xrev には残留を自動破棄する確実な手段が無い。
    # したがってこのペインは**汚染された**ものとして扱い、再利用を禁止する。
    _log "【重要】送信済みの本文が reviewer ペイン($surface)の入力行に残っています。xrev はこれを自動破棄できません。"
    _log "このペインは汚染されたものとして扱ってください: Enter を押さずにペインを閉じ、reviewer を開き直してから再実行してください。"
    _log "（残留したまま再送すると本文が混入します。同じペインを使い回さないでください。）"
    return 17
  fi
  _cmux_submit "$surface" || true

  # 応答待ち：round_id 一致の新着妥当ブロックが出るまで待つ。
  local waited=0 screen scan count block
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
    _xrev_sleep "$RESP_POLL"
    waited=$(( waited + RESP_POLL ))
  done

  _log "reviewer の応答がタイムアウトしました（${RESP_TIMEOUT}s, round_id=${round_id} の新着なし）。"
  return 12
}

# sleep ラッパ（フォアグラウンド sleep が制限される環境向けの薄い抽象）。
_xrev_sleep() { sleep "$1" 2>/dev/null || true; }

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
USAGE
      exit 64 ;;
  esac
fi
