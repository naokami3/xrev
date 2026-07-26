#!/usr/bin/env bash
#
# test_integrity.sh — C2: 送信完全性検証の reviewer 種別対応（fail closed）。
#
# 対象:
#   (a) _xrev_integrity_kind        … reviewer 種別(codex/claude/未知)の決定ロジック
#   (c) _cmux_clear_input           … reviewer 種別ごとの composer クリア手段の分岐
#   (e) xrev_transport_review 統合: 未知種別→28 / claude・inlineは無条件28 / 参照モードは送信継続 /
#       review-loop 側の 28→integrity_unverifiable 写像は test_review_loop.sh 側で確認
#
# 【指摘3（2巡目・decision-impl-2.json）】claude inline 向けの全文一致照合（_xrev_check_full_match）と
# その上限（integrity_full_match_max_chars）は、「空白の削除と挿入が相殺すれば比較・frame 検証の
# どちらもすり抜ける」ため完全性証明にならないと判明し撤去した。claude reviewer は参照モード専用に
# なり、inline は wire 長に関わらず無条件で exit 28 になる。旧 (b)(d) の全文一致照合単体テスト・
# 上限の _xrev_uint 範囲検証は対象の関数/設定キーごと削除し、(e) を「claude inline は短い wire でも
# exit 28」「参照モードは通過」の統合テスト（実物 _build_framed_line）に置き換えた。
#
# cmux 非依存: 通信層の入出力はすべてスタブする。

export XREV_CONFIG="$DEFAULT_CONFIG"
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"

# ── (a) _xrev_integrity_kind（純粋関数）─────────────────────────────────────────
out="$(_xrev_integrity_kind codex)"; rc=$?
assert_rc "codex は決定できる(rc0)" 0 "$rc"
assert_eq "codex は paste_chip" "paste_chip" "$out"

out="$(_xrev_integrity_kind claude)"; rc=$?
assert_rc "claude は決定できる(rc0)" 0 "$rc"
assert_eq "claude は reference_only" "reference_only" "$out"

_xrev_integrity_kind gemini >/dev/null 2>&1
assert_rc "未知種別(gemini)は非ゼロ(fail closed)" 1 "$?"

_xrev_integrity_kind "" >/dev/null 2>&1
assert_rc "空文字列も非ゼロ(fail closed)" 1 "$?"

unset out rc

# ── (c) _cmux_clear_input: reviewer 種別ごとのクリア手段（C2）───────────────────
_orig_cmux="$(declare -f _cmux)"
_TI_CI_LOG=""
_cmux() {
  local -a _ci_args=("$@")
  local last="${_ci_args[$(( ${#_ci_args[@]} - 1 ))]}"
  if [[ "$1" == "send" ]]; then
    _TI_CI_LOG="$_TI_CI_LOG send:len=${#last}"
  else
    _TI_CI_LOG="$_TI_CI_LOG ${1}:${last}"
  fi
  return 0
}

_TI_CI_LOG=""
_cmux_clear_input "surfaceX" codex
assert_eq "codex: ctrl-u が3回呼ばれる" "3" \
  "$(grep -o 'send-key:ctrl-u' <<<"$_TI_CI_LOG" | wc -l | tr -d ' ')"
assert_eq "codex: backspace が6回呼ばれる" "6" \
  "$(grep -o 'send-key:backspace' <<<"$_TI_CI_LOG" | wc -l | tr -d ' ')"
assert_not_contains "codex: 生のBS一括送信(send)は使わない" "$_TI_CI_LOG" "send:len="

_TI_CI_LOG=""
_cmux_clear_input "surfaceX" claude
assert_not_contains "claude: send-key(ctrl-u/backspace)は使わない" "$_TI_CI_LOG" "send-key:"
assert_eq "claude: send が1回だけ呼ばれる" "1" \
  "$(grep -o 'send:len=' <<<"$_TI_CI_LOG" | wc -l | tr -d ' ')"
assert_contains "claude: 送信するBSバイト列の長さは想定量" "$_TI_CI_LOG" "send:len=${_XREV_CLAUDE_CLEAR_BS_CHARS}"

_TI_CI_LOG=""
_cmux_clear_input "surfaceX"
assert_eq "kind省略時はcodex相当(ctrl-u3回)" "3" \
  "$(grep -o 'send-key:ctrl-u' <<<"$_TI_CI_LOG" | wc -l | tr -d ' ')"

eval "$_orig_cmux"
unset _TI_CI_LOG _orig_cmux

# ── (e) xrev_transport_review 統合テスト（実物 _build_framed_line で確認）──────────────
# 【方針（指摘3・2巡目）】claude reviewer は参照モード専用になり、inline は wire 長に関わらず
# 無条件で exit 28 になる。ここではエンコーダをスタブせず本物をそのまま使い、「claude inline は
# 極端に短い wire でも exit 28」「参照モードは通過」を確認する。

# 【まず実測前提を固定する】極端に短い payload でエンコードした wire でも、claude・inline は
# 送信前に無条件拒否される（wire の実長を理由にした拒否ではないことの裏取り）。
_short_wire="$(printf '' | _build_framed_line plain r1234567890123456)"
if (( ${#_short_wire} < 1 )); then
  fail "実測前提: 空payloadの wire は非空のはず" ">=1" "${#_short_wire}"
else
  pass "実測前提: 空payloadの wire(${#_short_wire}文字)を計測した"
fi
unset _short_wire

# 共通スタブ（cmux 非依存）。_cmux_send_line は本物を使い、_cmux（低レベル）をスタブして
# 送信・クリアの外部作用を記録する。応答検出は _scan_review_blocks/_scan_broken_blocks を
# スタブし、submit 済みかどうかで新着応答の有無を切り替える（test_send_gates.sh の手法を踏襲）。
# _build_framed_line / _xrev_procargs2 系は一切スタブしない（本物を使う）。
#
# 【_cmux 呼び出しの記録はファイル経由】production の _cmux_send_line は実送信を
# `err="$(_cmux send ... )"` というコマンド置換(サブシェル)経由で行うため、スタブがシェル変数へ
# 記録してもサブシェル内の変更は親シェルへ戻らない（test_send.sh 冒頭の注意と同じ理由）。
# そのためログは TMPDIR 配下の一時ファイルに追記し、確実に片付ける。
#
# 【注意】REVIEWER_PROCESS・_TI_RES_PATH はサブテストごとに書き換えるが、transport.sh の
# 再 source は行わない。再 source すると本節で定義したスタブ一式が実体で上書きされてしまうため
# （どちらも単なる変数なので、再sourceせず直接代入すれば済む）。
_TI_RESOLVE_CALLS=0
_TI_SUBMIT_CALLS=0
_TI_RES_PATH="global"
_TI_CMUX_LOG_FILE="$(mktemp "${TMPDIR:-/tmp}/xrev-test-integrity.XXXXXX")"
_TI_ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/xrev-test-integrity-err.XXXXXX")"
_TI_TRAP_SAVE="$(trap -p EXIT INT TERM 2>/dev/null)"
trap '[[ -n "${_TI_CMUX_LOG_FILE:-}" ]] && rm -f "$_TI_CMUX_LOG_FILE"; [[ -n "${_TI_ERR_FILE:-}" ]] && rm -f "$_TI_ERR_FILE"' EXIT INT TERM

_cmux_preflight() { return 0; }
_cmux_resolve_surface() {
  _TI_RESOLVE_CALLS=$(( _TI_RESOLVE_CALLS + 1 ))
  _XREV_RES_REF="surface:9"; _XREV_RES_UUID=""; _XREV_RES_WS=""
  _XREV_RES_PATH="$_TI_RES_PATH"; _XREV_RES_SAMEWS=0
  printf '%s' "$_XREV_RES_REF"; return 0
}
_probe_terminal_usable() { printf 'usable'; }
_xrev_gate_reviewer() { return 0; }
_detect_content_type() { printf 'plain'; }
_compute_submit_settle() { printf '0'; }
_xrev_sleep() { :; }
_cmux_submit() { _TI_SUBMIT_CALLS=$(( _TI_SUBMIT_CALLS + 1 )); return 0; }
_cmux_read_screen() { printf '対象なし'; }
_scan_review_blocks() {
  cat >/dev/null
  if (( _TI_SUBMIT_CALLS > 0 )); then
    printf '1\n{"round_id":"x","verdict":"approve","findings":[]}'
  else
    printf '0'
  fi
}
_scan_broken_blocks() { cat >/dev/null; printf '0'; }
_cmux() {
  local -a _ti_args=("$@")
  local last="${_ti_args[$(( ${#_ti_args[@]} - 1 ))]}"
  printf '%s:len=%s\n' "$1" "${#last}" >> "$_TI_CMUX_LOG_FILE"
  return 0
}

_ti_run() {
  # xrev_transport_review を走らせ rc を _TI_RC・stderr を _TI_LAST_ERR に格納する。
  # 【注意】呼び出しをコマンド置換( $(...) )で包まない: xrev_transport_review 自体をサブシェル化すると
  # _cmux_resolve_surface/_cmux_submit スタブが更新する _TI_RESOLVE_CALLS/_TI_SUBMIT_CALLS が
  # サブシェル内に閉じ込められ、親シェルへ反映されなくなる（本ファイル冒頭の注意と同じ理由）。
  # stderr は一時ファイルへ直接リダイレクトし、そのファイルを後から cat で読む。
  local payload="$1"
  _TI_RESOLVE_CALLS=0; _TI_SUBMIT_CALLS=0
  : > "$_TI_CMUX_LOG_FILE"
  : > "$_TI_ERR_FILE"
  xrev_transport_review "$payload" >/dev/null 2>"$_TI_ERR_FILE"
  _TI_RC=$?
  _TI_LAST_ERR="$(cat "$_TI_ERR_FILE")"
}
_ti_cmux_log() { tr '\n' ' ' < "$_TI_CMUX_LOG_FILE"; }

# (e-1) 未知種別（REVIEWER_PROCESS=gemini）→ 28。resolve すら試みない（早期 fail closed）。
REVIEWER_PROCESS=gemini
_ti_run ""
assert_rc "未知種別(gemini) → rc28" 28 "$_TI_RC"
assert_eq "未知種別 → resolve は一切呼ばれない" "0" "$_TI_RESOLVE_CALLS"

# (e-2)〜(e-4) claude・inline（参照モード無し）→ wire 長に関わらず無条件で rc28（指摘3・2巡目）。
# resolve すら試みない（kind 判定直後・wire を組む前に fail closed）。診断メッセージは参照モードへの
# 案内になっている。
REVIEWER_PROCESS=claude
_TI_RES_PATH="global"
unset XREV_REFERENCE_MODE

_ti_run ""
assert_rc "claude・inline・空payload → rc28(無条件拒否)" 28 "$_TI_RC"
assert_eq "claude・inline・空payload → resolve は一切呼ばれない" "0" "$_TI_RESOLVE_CALLS"
assert_eq "claude・inline・空payload → cmuxへは一切送信しない" "" "$(_ti_cmux_log)"
assert_contains "claude・inline → 参照モードへの案内メッセージ" "$_TI_LAST_ERR" "参照モード"

_ti_run "short payload"
assert_rc "claude・inline・短文payload → rc28(短い wire でも無条件拒否)" 28 "$_TI_RC"
assert_eq "claude・inline・短文payload → resolve は一切呼ばれない" "0" "$_TI_RESOLVE_CALLS"

_ti_run 'これは日本語の短い payload です'
assert_rc "claude・inline・日本語payload → rc28" 28 "$_TI_RC"

# (e-5) claude・参照モード(XREV_REFERENCE_MODE=1・同一WS解決) → inline 向けの無条件拒否ゲートは
# 参照モードのときは適用されないため送信を許可する（完全性は diff_hash+基底HEADの端到端照合が
# 別途保証するため）。
_TI_RES_PATH="same_ws"
export XREV_REFERENCE_MODE=1
_ti_run "これは参照モードの payload です"
assert_rc "claude・参照モード → rc0(inline無条件拒否の対象外)" 0 "$_TI_RC"
assert_eq "claude・参照モード → submit まで到達する" "1" "$_TI_SUBMIT_CALLS"
assert_contains "claude・参照モード → composerクリア(BS一括送信)が起きる" "$(_ti_cmux_log)" "send:len=${_XREV_CLAUDE_CLEAR_BS_CHARS}"
unset XREV_REFERENCE_MODE

# (e-6) claude・参照モードでも同一WS解決でなければ rc18（既存仕様。resolve 後の同一WS必須ゲートで拒否）。
_TI_RES_PATH="global"
export XREV_REFERENCE_MODE=1
_ti_run "これは参照モードの payload です"
assert_rc "claude・参照モードでもsame_wsでなければrc18" 18 "$_TI_RC"
unset XREV_REFERENCE_MODE

rm -f "$_TI_CMUX_LOG_FILE" "$_TI_ERR_FILE"
trap - EXIT INT TERM
[[ -n "$_TI_TRAP_SAVE" ]] && eval "$_TI_TRAP_SAVE"
unset _TI_RESOLVE_CALLS _TI_SUBMIT_CALLS _TI_RES_PATH _TI_RC _TI_LAST_ERR _TI_CMUX_LOG_FILE _TI_ERR_FILE _TI_TRAP_SAVE
unset -f _ti_run _ti_cmux_log

# ── 後片付け: 実体を読み直してスタブを捨てる（後続の test_*.sh へ漏らさない）────────
export XREV_CONFIG="$DEFAULT_CONFIG"
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"
