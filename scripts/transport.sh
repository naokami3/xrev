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
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
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
#   2) cmux の list 系コマンド(JSON)からタイトル一致の surface ref を引く
# 解決できなければ非ゼロで失敗する（暴走防止：宛先不明のまま送らない）。
_cmux_resolve_surface() {
  if [[ -n "${XREV_REVIEWER_SURFACE:-}" ]]; then
    printf '%s' "$XREV_REVIEWER_SURFACE"
    return 0
  fi

  # cmux のバージョンで list コマンド名が揺れるため候補を順に試す。
  local listing="" cmd
  for cmd in "list-pane-surfaces" "list-panes" "list-surfaces"; do
    listing="$(_cmux "$cmd" --json 2>/dev/null)" || listing=""
    [[ -n "$listing" ]] && break
  done
  if [[ -z "$listing" ]]; then
    _log "cmux の pane 一覧取得に失敗（list-pane-surfaces / list-panes / list-surfaces すべて不可）"
    return 3
  fi

  # JSON 形状差異に耐えるよう python3 で寛容にパース。
  # title/name が REVIEWER_PANE_TITLE に一致するエントリの surface 参照を返す。
  # 一覧はヒアドキュメント stdin と競合するため環境変数 XREV_LISTING で渡す。
  XREV_LISTING="$listing" python3 - "$REVIEWER_PANE_TITLE" <<'PY'
import json, os, sys
want = sys.argv[1].strip().lower()
raw = os.environ.get("XREV_LISTING", "")
try:
    data = json.loads(raw)
except Exception:
    sys.exit(4)

# あり得る形状: list / {"panes":[...]} / {"surfaces":[...]} などを総当たりで平坦化
def candidates(obj):
    if isinstance(obj, list):
        for x in obj:
            yield from candidates(x)
    elif isinstance(obj, dict):
        yield obj
        for v in obj.values():
            if isinstance(v, (list, dict)):
                yield from candidates(v)

def title_of(d):
    for k in ("title", "name", "surfaceTitle", "tabTitle", "label"):
        if isinstance(d.get(k), str):
            return d[k]
    return None

def ref_of(d):
    # surface ref を表すフィールドの候補。refs 形式("surface:4")か uuid か index。
    for k in ("surfaceRef", "surface", "ref", "surfaceId", "id"):
        v = d.get(k)
        if isinstance(v, str) and v:
            return v if v.startswith("surface:") or "-" in v else ("surface:%s" % v)
        if isinstance(v, int):
            return "surface:%d" % v
    return None

for d in candidates(data):
    t = title_of(d)
    if t and t.strip().lower() == want:
        r = ref_of(d)
        if r:
            print(r)
            sys.exit(0)
sys.exit(5)
PY
}

# reviewer ペインへ 1 メッセージ送信する。
# cmux send は「常に 1 行」として扱うのが安全（複数行は別入力に割れて壊れる）ため、
# 本文を base64 で 1 行に畳んで送り、reviewer 側で復元させる前提のラッパにはしない。
# 代わりに「ヒアドキュメントを使わず、改行を含む payload はファイル経由ではなく
# send を行単位で繰り返す」方式を取る（中間ファイル禁止の要件を守る）。
_cmux_send_text() {
  local surface="$1" text="$2"
  # 改行ごとに send し、各行のあとに改行キーを送る。
  # （cmux send は \n を含めても自動実行されない場合があるため send-key enter で確定）
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    _cmux send --surface "$surface" "$line" >/dev/null 2>&1 || return 6
    _cmux send-key --surface "$surface" enter >/dev/null 2>&1 || return 6
  done <<< "$text"
  return 0
}

# reviewer ペインの最終確定入力（プロンプト送信）。本文を送り終えたあとに呼ぶ。
_cmux_submit() {
  local surface="$1"
  _cmux send-key --surface "$surface" enter >/dev/null 2>&1 || return 7
}

# reviewer ペインの画面を読み取る（スクロールバック込み）。
_cmux_read_screen() {
  local surface="$1"
  _cmux read-screen --surface "$surface" --scrollback --lines "$READ_LINES" 2>/dev/null
}

# ── 公開 API ─────────────────────────────────────────────────────────────────

# xrev_transport_review <payload_text>
#   payload_text を reviewer に渡し、SENTINEL で挟まれた JSON を stdout に返す。
#   成功: 0 / JSON を stdout。失敗: 非ゼロ / stderr にログ。
xrev_transport_review() {
  local payload="$1"
  _cmux_preflight || return $?
  local surface
  surface="$(_cmux_resolve_surface)" || {
    _log "reviewer ペイン（タイトル: '$REVIEWER_PANE_TITLE'）を解決できませんでした。"
    _log "cmux 上に該当タイトルの Codex ペインを 1 枚開いているか、XREV_REVIEWER_SURFACE で明示指定してください。"
    return 10
  }
  _log "reviewer surface = $surface（title: '$REVIEWER_PANE_TITLE'）"

  # reviewer への指示を payload に前置きし、JSON をセンチネルで挟ませる。
  local framed
  framed="$(cat <<EOF
$payload

---
上記をレビューし、結果を必ず次の2行のセンチネルで挟んで出力してください。
センチネルの外には何も書かないでください。JSON は references/review-schema.json に準拠。
$SENTINEL_BEGIN
{ ここに verdict と findings[] を持つ JSON }
$SENTINEL_END
EOF
)"

  _cmux_send_text "$surface" "$framed" || { _log "送信に失敗しました。"; return 11; }
  _cmux_submit "$surface" || true

  # 応答待ち：END センチネルが画面に出るまでポーリング。
  local waited=0 screen=""
  # settle（送信直後の反映待ち）
  _xrev_sleep "$SETTLE_SECS"
  while (( waited < RESP_TIMEOUT )); do
    screen="$(_cmux_read_screen "$surface")"
    if printf '%s' "$screen" | grep -qF "$SENTINEL_END"; then
      break
    fi
    _xrev_sleep "$RESP_POLL"
    waited=$(( waited + RESP_POLL ))
  done

  if ! printf '%s' "$screen" | grep -qF "$SENTINEL_END"; then
    _log "reviewer の応答がタイムアウトしました（${RESP_TIMEOUT}s）。"
    return 12
  fi

  # 最後のセンチネル対をスクリーンから抽出して JSON を取り出す。
  local json
  json="$(XREV_SCREEN="$screen" python3 - "$SENTINEL_BEGIN" "$SENTINEL_END" <<'PY'
import os, sys
begin, end = sys.argv[1], sys.argv[2]
text = os.environ.get("XREV_SCREEN", "")
# 最後の begin..end ブロックを採用（往復で複数回出るため最新を使う）
b = text.rfind(begin)
if b == -1:
    sys.exit(20)
e = text.find(end, b)
if e == -1:
    sys.exit(21)
block = text[b + len(begin):e].strip()
print(block)
PY
)" || { _log "センチネル間の JSON 抽出に失敗しました。"; return 13; }

  printf '%s\n' "$json"
  return 0
}

# sleep ラッパ（フォアグラウンド sleep が制限される環境向けの薄い抽象）。
_xrev_sleep() { sleep "$1" 2>/dev/null || true; }

# 直接実行されたら簡易セルフテスト（実機用）。source されたときは何もしない。
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    ping)
      _cmux_preflight && echo "(cmux 接続OK: $CMUX_BIN)" >&2 ;;
    resolve)
      _cmux_preflight || exit $?
      _cmux_resolve_surface && echo "(resolve ok)" >&2 ;;
    review)
      shift
      xrev_transport_review "${1:-テスト payload}" ;;
    *)
      cat >&2 <<USAGE
usage:
  transport.sh ping                 # cmux 接続（実行コンテキスト）の確認
  transport.sh resolve              # reviewer surface の解決のみ確認
  transport.sh review "<payload>"   # 1往復だけ送って JSON を受ける
USAGE
      exit 64 ;;
  esac
fi
