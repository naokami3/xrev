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
  local surface
  surface="$(_cmux_resolve_surface)" || {
    _log "reviewer ペイン（タイトル: '$REVIEWER_PANE_TITLE'）を解決できませんでした。"
    _log "cmux 上に該当タイトルの Codex ペインを 1 枚開いているか、XREV_REVIEWER_SURFACE で明示指定してください。"
    return 10
  }
  _log "reviewer surface = ${surface}（title: '${REVIEWER_PANE_TITLE}'）"

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
