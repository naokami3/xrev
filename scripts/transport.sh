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

# 純粋関数: cmux top の TSV から、指定 surface ref の「直下プロセス名」を列挙する。
# top の行(TSV): cpu, mem, count, kind, id, parent, name。kind=process かつ parent=surface ref が直下。
#   入力: $1=surface ref, env XREV_TOP=top TSV / 出力: 直下プロセス名を1行ずつ
_top_surface_processes() {
  XREV_TOP="${XREV_TOP:-}" python3 - "$1" <<'PY'
import os, sys
ref = sys.argv[1]
for line in os.environ.get("XREV_TOP", "").splitlines():
    p = line.split("\t")
    if len(p) < 7:
        continue
    if p[3] == "process" and p[5] == ref:
        print(p[6])
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
  _cmux rename-tab --surface "$CMUX_SURFACE_ID" "$title"
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
      _log "明示サーフェス($XREV_REVIEWER_SURFACE)を tree 内に一意特定できません（code=$lrc。誤配送防止のため中止）。"
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
      *) _log "宛先解決に失敗しました（rc=$rc）。"; return 10 ;;
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

# read-screen の成否で端末性を判定（cmux 依存）。端末でないこと(=14)と宛先消失(=15)を分離する。
#   usable: 成功（空でも可） / non_terminal: "not a terminal"（恒久・実ターミナルでない）/
#   gone: "not found"（送信直前に surface 消失＝同一性喪失） / transient: 一時失敗
_probe_terminal_usable() {
  local surface="$1" err rc
  err="$(_cmux read-screen --surface "$surface" --lines 1 2>&1 1>/dev/null)"; rc=$?
  if (( rc == 0 )); then printf 'usable'; return 0; fi
  if printf '%s' "$err" | grep -qiE 'not a terminal'; then printf 'non_terminal'; return 0; fi
  if printf '%s' "$err" | grep -qiE 'not[_ ]?found'; then printf 'gone'; return 0; fi
  printf 'transient'
}

# プロセス証明: 対象 surface の直下プロセスが「厳密に1件 かつ 許可名(REVIEWER_PROCESS)と完全一致」か。
#   top を送信直前に1回取得して鮮度を担保。取得不能・複数直下・空・許可名以外はいずれも非ゼロ(=送信拒否)。
#   「1件でも含めば通す」だと shell と codex が同居する surface で入力先が shell の可能性を排除できないため、
#   厳密1件を要求する（shell へ payload を Enter 送信する事故を防ぐ）。
_verify_reviewer_process() {
  local surface="$1" top names count
  top="$(_cmux_top_processes)"
  [[ -n "$top" ]] || { _log "cmux top を取得できません（プロセス証明不可）。"; return 1; }
  names="$(XREV_TOP="$top" _top_surface_processes "$surface")"
  [[ -n "$names" ]] || { _log "reviewer surface($surface)の直下プロセスを特定できません。"; return 1; }
  count="$(printf '%s\n' "$names" | grep -c .)"
  if [[ "$count" -ne 1 || "$names" != "$REVIEWER_PROCESS" ]]; then
    _log "reviewer surface($surface)の直下プロセスが '$REVIEWER_PROCESS' 単独ではありません（直下=[$(printf '%s' "$names" | paste -sd, -)]）。"
    return 1
  fi
}

# reviewer ペインの最終確定入力（プロンプト送信）。本文（1物理行）を送り終えたあとに呼ぶ。
_cmux_submit() {
  local surface="$1"
  _cmux send-key --surface "$surface" enter >/dev/null 2>&1 || return 7
}

# reviewer ペインの画面を読み取る（スクロールバック込み）。
_cmux_read_screen() {
  local surface="$1"
  _cmux read-screen --surface "$surface" --scrollback --lines "$READ_LINES" 2>/dev/null
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
  XREV_SCREEN="$1" XREV_EXPECT_ROUND_ID="${2:-}" python3 <<'PY'
import os, sys, json
text = os.environ.get("XREV_SCREEN", "")
expect_rid = os.environ.get("XREV_EXPECT_ROUND_ID", "")

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
}

# 純粋関数（cmux 非依存・テスト可能）: payload を「画面上は1物理行・意味上は複数行」に
# エンコードし、reviewer への指示と出力契約を含む完全な1行メッセージを stdout に返す。
#   $1 = content_type(plain|unified_diff|code|markdown), $2 = round_id, $3 = payload
# 実機知見に基づく不変条件:
#   - cmux send は \n,\t を実改行/実タブへ自動展開するため、本文の \ と tab をトークン化する。
#   - 改行は plain なら <XREV-NL>、framed なら "|| LNNNN:" の行境界へ畳む（実改行を送らない）。
#   - 末尾に END_ROUND_<id> を置き切り詰めを検出可能にする。
_build_framed_line() {
  XREV_BUILD_PAYLOAD="$3" python3 - "$1" "$2" "$SENTINEL_BEGIN" "$SENTINEL_END" <<'PY'
import os, sys
ct, rid, sb, se = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
body = os.environ.get("XREV_BUILD_PAYLOAD", "")

# 1) 制御トークン衝突の回避（可逆エスケープ）。本文に元から含まれる制御トークンを、
#    導入子 XREVQ で始まるリテラル表記へ退避する。導入子自身を最初に二重化して衝突回避。
#    （reviewer は復元規則に従い、XREVQ 列を区切りでなく本文の文字列として読む）
body = body.replace("XREVQ", "XREVQXREVQ")
for tok, esc in (("<XREV-NL>", "XREVQnl"), ("<XREV-BS>", "XREVQbs"),
                 ("<XREV-TAB>", "XREVQtab"), ("END_ROUND_", "XREVQer"), ("|| L", "XREVQll")):
    body = body.replace(tok, esc)
# 2) cmux が実改行/実タブへ展開する文字をトークン化（退避後に行うので衝突しない）
body = body.replace("\\", "<XREV-BS>").replace("\t", "<XREV-TAB>")
lines = body.split("\n")
if ct == "plain":
    enc = "PAYLOAD_PLAIN || " + " <XREV-NL> ".join(lines)
else:
    recs = " ".join("|| L%04d: %s" % (i + 1, ln) for i, ln in enumerate(lines))
    enc = "PAYLOAD_FRAMED content_type=%s lines=%d %s" % (ct, len(lines), recs)
instr = ("これはエンコードされたレビュー依頼です。復元規則: <XREV-NL>=改行 / "
         "'|| LNNNN:'=行境界(framed時) / <XREV-BS>=バックスラッシュ / <XREV-TAB>=タブ。"
         "XREVQ で始まる列は本文のリテラル文字列(区切りではない): "
         "XREVQnl='<XREV-NL>' / XREVQbs='<XREV-BS>' / XREVQtab='<XREV-TAB>' / "
         "XREVQer='END_ROUND_' / XREVQll='|| L' / XREVQXREVQ='XREVQ'。"
         "これらを元の複数行に復元して内容を理解し、批判的にレビューしてください。")
out = ("出力は必ず %s と %s の2行マーカーで挟み、間には1行コンパクトJSONのみを置くこと"
       "(マーカー外・JSON前後に説明文を書かない)。JSONはトップレベルに round_id(=\"%s\") と "
       "verdict(approve|request_changes) と findings[] を持ち、各 finding は "
       "file/severity(critical|high|medium|low|nit)/category(bug|security|design|perf|style)/message を必須とする。"
       % (sb, se, rid))
line = "XREV_REVIEW round_id=%s :: %s :: %s :: %s :: END_ROUND_%s" % (rid, instr, out, enc, rid)
# 保険: エンコード後に実改行/タブが残らないよう最終中和
line = line.replace("\n", " <XREV-NL> ").replace("\t", "<XREV-TAB>")
sys.stdout.write(line)
PY
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
  for _i in 1 2 3; do _cmux send-key --surface "$surface" ctrl-u >/dev/null 2>&1 || true; done
  for _i in 1 2 3 4 5 6; do _cmux send-key --surface "$surface" backspace >/dev/null 2>&1 || true; done
}

# 1物理行を reviewer 入力欄へ送る（確定はしない）。cmux 依存。
# 【実機知見】送信先が Codex のとき、ビジー（前応答の処理中）や入力欄の残留（テキスト/
#   ペーストチップ）があると cmux send が非ゼロで失敗する。cmux send 自体の長さ上限ではない
#   （プレーンシェルへは長文も成功）。そこで「送信前にクリア → 失敗なら待って再試行」する。
# （長大時のチャンク送信は XREV_CHUNK_SIZE で将来対応。既定は一括送信）
_cmux_send_line() {
  local surface="$1" line="$2" tries=0 max="${XREV_SEND_RETRIES:-5}"
  _cmux_clear_input "$surface"          # 残留を除去してから送る（混入による prompt 破壊を防ぐ）
  while (( tries < max )); do
    _cmux send --surface "$surface" "$line" >/dev/null 2>&1 && return 0
    # 失敗：busy/残留の可能性 → 少し待ち、再度クリアして再試行（busy 解消を待つ）。
    tries=$(( tries + 1 ))
    _xrev_sleep 2
    _cmux_clear_input "$surface"
  done
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
m = re.search(r"Pasted Content\s+(\d+)\s+chars", dw)
if m:
    print("ok" if int(m.group(1)) == elen else "truncated"); sys.exit(0)
print("ok" if mark in dw else "unknown")
' <<<"$screen"
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
    _log "reviewer ペイン（タイトル: '$REVIEWER_PANE_TITLE'）を解決できませんでした（code=$rrc）。"
    _log "cmux 上に該当タイトルの Codex ペインを 1 枚開いているか、XREV_REVIEWER_SURFACE で明示指定してください。"
    return "$rrc"
  fi
  surface="$_XREV_RES_REF"
  _log "reviewer surface = ${surface} path=${_XREV_RES_PATH}（title: '${REVIEWER_PANE_TITLE}'）"

  # ── 送信前ゲート（誤配送・shell誤実行の防止。@xrev 承認設計）──────────────────
  # (i) UUID 同一性・WS 所属の再検証（uuid を持つ経路 = same_ws / explicit）。
  #     ref再利用・WS移動・差し替え・宛先/呼び出し元の消失をすべて fail closed で弾く（fail-open を作らない）。
  if [[ -n "$_XREV_RES_UUID" && "$_XREV_RES_PATH" != "global" ]]; then
    local rtree; rtree="$(_cmux_tree_uuids)"
    if [[ -z "$rtree" ]]; then _log "送信直前の tree 取得に失敗しました（中止）。"; return 15; fi
    local rloc rlrc
    rloc="$(XREV_LISTING="$rtree" _locate_surface "$_XREV_RES_UUID")"; rlrc=$?
    if (( rlrc != 0 )); then
      _log "解決した reviewer surface(uuid=$_XREV_RES_UUID)を送信直前に一意特定できません（code=$rlrc・中止）。"; return 15
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

  # (iii) プロセス証明（直下プロセスが許可名=$REVIEWER_PROCESS か。Codex 終了後に shell へ戻った端末への誤送信を防ぐ）
  if ! _verify_reviewer_process "$surface"; then
    _log "reviewer surface($surface)の直下プロセスが '$REVIEWER_PROCESS' ではありません（reviewer 未稼働/別用途の端末の恐れ）。送信を中止します。"
    return 17
  fi

  # round_id（ラウンド識別子）と content_type を決め、payload を1物理行にエンコードする。
  # round_id は高エントロピー（衝突でスクロールバックの過去応答と混同しないため）。
  local round_id ct line
  round_id="${XREV_ROUND_ID:-$(python3 -c 'import secrets;print("r"+secrets.token_hex(8))' 2>/dev/null)}"
  [[ -n "$round_id" ]] || round_id="r$$$RANDOM$RANDOM"
  ct="${XREV_CONTENT_TYPE:-$(_detect_content_type "$payload")}"
  line="$(_build_framed_line "$ct" "$round_id" "$payload")"
  _log "round_id=${round_id} content_type=${ct} len=${#line}"

  # 送信前ベースライン：この round_id に一致する妥当ブロック数（通常0、防御的に数える）。
  local before_count
  before_count="$(_scan_review_blocks "$(_cmux_read_screen "$surface")" "$round_id" | head -1)"
  [[ "$before_count" =~ ^[0-9]+$ ]] || before_count=0

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
  _cmux_submit "$surface" || true

  # 応答待ち：round_id 一致の新着妥当ブロックが出るまで待つ。
  local waited=0 screen scan count block
  _xrev_sleep "$SETTLE_SECS"
  while (( waited < RESP_TIMEOUT )); do
    screen="$(_cmux_read_screen "$surface")"
    scan="$(_scan_review_blocks "$screen" "$round_id")"
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
  transport.sh review "<payload>"   # 1往復だけ送って JSON を受ける
USAGE
      exit 64 ;;
  esac
fi
