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

# reviewer ペインの surface ref をタイトルから解決する。
# 解決順:
#   1) XREV_REVIEWER_SURFACE が指定されていればそれを優先（実機デバッグ用の明示指定）
#   2) `cmux tree --all --json` から、タイトルが一致する「サーフェス」の ref を引く
#      （解析は純粋関数 _resolve_surface_from_json に委譲）
# 解決できなければ非ゼロで失敗する（暴走防止：宛先不明のまま送らない）。
#
# 実機知見:
#   - 全ペイン/ワークスペース横断で探すため tree --all を使う（list-pane-surfaces は
#     呼び出し元ペインのサーフェスしか返さない）。
#   - タイトルには実行中スピナー等の装飾接頭辞が付く（例 "⠂ Review Codex"）。
#     先頭の非単語記号を正規化で除去し、完全一致 → 部分一致の順で照合する。
#   - サーフェスは ref が "surface:" で始まり title を持つ object のみを対象にする
#     （workspace/pane の ref を誤って拾わないため）。
_cmux_resolve_surface() {
  if [[ -n "${XREV_REVIEWER_SURFACE:-}" ]]; then
    printf '%s' "$XREV_REVIEWER_SURFACE"
    return 0
  fi

  local listing
  listing="$(_cmux tree --all --json 2>/dev/null)" || listing=""
  if [[ -z "$listing" ]]; then
    # フォールバック（呼び出し元ペイン内に reviewer がいる構成のみ救済）
    listing="$(_cmux list-pane-surfaces --json 2>/dev/null)" || listing=""
  fi
  if [[ -z "$listing" ]]; then
    _log "cmux からサーフェス一覧を取得できません（tree --all / list-pane-surfaces 不可）"
    return 3
  fi

  _resolve_surface_from_json "$REVIEWER_PANE_TITLE" "$listing"
}

# reviewer ペインへ本文を送る（確定はしない）。
#
# 設計判断:
#   - 本文は「1回の cmux send」でまとめて送る。行ごとに Enter を送る方式は、対話型 TUI
#     （Codex 等）では最初の行で送信が確定してしまうため採らない。本文送信と確定(Enter)を
#     分離し、確定は _cmux_submit が 1 回だけ行う。
#   - 空文字列を送ると cmux send が弾く（<text> 必須）ため、空本文はガードする。
#   - 中間ファイルは使わない（要件）。本文は引数で渡す。
#
# 【実機検証が残る点】Codex の TUI が本文中の改行をどう扱うか（途中送信せず複数行を保持
#   できるか）は Codex 側仕様に依存する。早期送信される場合は本文を 1 行へ畳む等の調整を
#   この関数に閉じ込めて対応する（配管の局所化方針）。
_cmux_send_text() {
  local surface="$1" text="$2"
  [[ -n "$text" ]] || return 0
  _cmux send --surface "$surface" "$text" >/dev/null 2>&1 || return 6
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

# 画面テキストから「妥当な review JSON ブロック」を走査する。
#   妥当 = SENTINEL_BEGIN..SENTINEL_END に挟まれ、中身が JSON として parse でき、
#          dict かつ "verdict" を持つ（＝reviewer の本物の応答）。
#   出力: 1行目=妥当ブロック数, 2行目以降=最後の妥当ブロックの中身。
# これにより「プロンプトのエコー（センチネルだけで JSON 無し）」「テンプレート」
# 「前ラウンドの古い応答」を機械的に区別できる（数の増分で新着を判定する）。
_scan_review_blocks() {
  XREV_SCREEN="$1" python3 - "$SENTINEL_BEGIN" "$SENTINEL_END" <<'PY'
import os, sys, json
begin, end = sys.argv[1], sys.argv[2]
text = os.environ.get("XREV_SCREEN", "")

def parse_block(raw):
    # 対話型 TUI（Codex 等）は長い行を物理的に折り返し、各行にガター字下げを付けるため、
    # 画面から読んだ生テキストは JSON 文字列の途中に改行が入り json.loads に失敗する。
    # 1) まず素のままパース（cmux が論理行で返した場合）
    # 2) 失敗時は「各行の前後空白を除去して連結」で折り返し＋ガターを取り除いて再パース
    #    （Codex には JSON を1行コンパクトで出すよう指示しているので、行の前後空白＝TUI 由来）
    for cand in (raw, "".join(line.strip() for line in raw.splitlines())):
        try:
            o = json.loads(cand)
        except Exception:
            continue
        if isinstance(o, dict) and "verdict" in o:
            return o
    return None

blocks = []
i = 0
while True:
    b = text.find(begin, i)
    if b == -1:
        break
    e = text.find(end, b + len(begin))
    if e == -1:
        break
    obj = parse_block(text[b + len(begin):e])
    i = e + len(end)
    if obj is not None:
        # 下流（parse-review）が確実に読めるよう、正規化したクリーンな JSON を保持する。
        blocks.append(json.dumps(obj, ensure_ascii=False))
print(len(blocks))
if blocks:
    sys.stdout.write(blocks[-1])
PY
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
  _log "reviewer surface = ${surface}（title: '${REVIEWER_PANE_TITLE}'）"

  # 送信前のベースライン：既に画面にある妥当ブロック数を数える。
  # 以降は「この数を超える＝新着の本物の応答が来た」をもって完了判定する。
  local before_count
  before_count="$(_scan_review_blocks "$(_cmux_read_screen "$surface")" | head -1)"
  [[ "$before_count" =~ ^[0-9]+$ ]] || before_count=0

  # reviewer への指示を payload に前置きし、JSON をセンチネルで挟ませる。
  # 注意: プロンプト内にセンチネル文字列は出るが、その間に「妥当な JSON」は置かない。
  #       これによりエコーされても妥当ブロックとして誤検出されない。
  local framed
  framed="$(cat <<EOF
$payload

---
上記をレビューし、結果を必ず次の2つのマーカー行で挟んで出力してください。
マーカーの間には JSON だけを置き、マーカーの外や JSON の前後に説明文を書かないこと。
JSON は改行・インデントなしの「1行コンパクト形式」で出力すること（pretty-print しない）。
JSON は verdict（approve | request_changes）と findings[] を持ち、各 finding は
file / severity（critical|high|medium|low|nit）/ category（bug|security|design|perf|style）/ message を必須とする。
開始マーカー: $SENTINEL_BEGIN
終了マーカー: $SENTINEL_END
EOF
)"

  _cmux_send_text "$surface" "$framed" || { _log "送信に失敗しました。"; return 11; }
  _cmux_submit "$surface" || true

  # 応答待ち：妥当ブロック数が before_count を超える（新着）まで待つ。
  local waited=0 screen scan count block
  _xrev_sleep "$SETTLE_SECS"
  while (( waited < RESP_TIMEOUT )); do
    screen="$(_cmux_read_screen "$surface")"
    scan="$(_scan_review_blocks "$screen")"
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

  _log "reviewer の応答がタイムアウトしました（${RESP_TIMEOUT}s, 新しい妥当 JSON ブロックなし）。"
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
