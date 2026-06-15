#!/usr/bin/env bash
# transport.sh::_cmux_send_line の送信リトライ（cmux 非依存・スタブ注入でテスト）。
# 実機知見: 送信先 Codex がビジー/残留時は cmux send が失敗するため、クリア＋再試行する。

export XREV_CONFIG="$DEFAULT_CONFIG"
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"

# 実 sleep を潰す（リトライで待たない）
_xrev_sleep() { :; }

# 1) cmux send が毎回成功 → 1回で rc=0
_cmux() { return 0; }
_cmux_send_line "surfaceX" "line"; assert_rc "送信成功は rc=0" 0 "$?"

# 2) cmux send が2回失敗→3回目成功（send-key=clearは常に成功）→ rc=0
_SEND_CALLS=0
_cmux() {
  if [[ "$1" == "send" ]]; then
    _SEND_CALLS=$(( _SEND_CALLS + 1 ))
    (( _SEND_CALLS <= 2 )) && return 1 || return 0
  fi
  return 0   # send-key（クリア）は成功
}
_cmux_send_line "surfaceX" "line"; assert_rc "2回失敗後に成功で rc=0（リトライ）" 0 "$?"

# 3) cmux send が常に失敗 → 規定回数リトライ後 rc=6
_cmux() { [[ "$1" == "send" ]] && return 1; return 0; }
XREV_SEND_RETRIES=3 _cmux_send_line "surfaceX" "line"; assert_rc "常に失敗なら rc=6" 6 "$?"

# 4) 送信前にクリア（send-key）が呼ばれる
_CLEAR_CALLS=0
_cmux() {
  [[ "$1" == "send-key" ]] && _CLEAR_CALLS=$(( _CLEAR_CALLS + 1 ))
  return 0
}
_cmux_send_line "surfaceX" "line" >/dev/null 2>&1
assert_eq "送信前に入力クリア(send-key)が呼ばれる" "yes" "$([[ $_CLEAR_CALLS -gt 0 ]] && echo yes || echo no)"

# 後始末: 実関数を復元（後続テストへの影響回避）
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"
