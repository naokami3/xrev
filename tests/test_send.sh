#!/usr/bin/env bash
# transport.sh::_cmux_send_line の送信リトライ（cmux 非依存・スタブ注入でテスト）。
# 実機知見: 送信先 Codex がビジー/残留時は cmux send が失敗するため、クリア＋再試行する。
#
# 【スタブが状態をファイルで持つ理由】
# production は stderr をコマンド置換で受ける（一時ファイルを持ち込まないための設計判断）。
# その結果 _cmux はサブシェルで動くため、スタブがシェル変数でリトライ回数を数えると値が失われる。
# 「テストの都合で production に一時資源と trap を持ち込む」のは本末転倒なので、面倒はテスト側で
# 引き受ける。カウンタは TMPDIR 配下に排他生成し、確実に片付ける（リポジトリには作らない）。

export XREV_CONFIG="$DEFAULT_CONFIG"
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"

_TS_COUNTER="$(mktemp "${TMPDIR:-/tmp}/xrev-test-send.XXXXXX" 2>/dev/null)"
# 中断時の取りこぼし対策。run.sh は test_*.sh を同一シェルで source するため、
# 既存 trap を潰さないよう設定前の内容を保存し、末尾で復元する（現 runner に既存 trap は無いが、
# 将来 runner 側が trap を張っても壊さないようにしておく）。
_TS_TRAP_SAVE="$(trap -p EXIT INT TERM 2>/dev/null)"
trap '[[ -n "${_TS_COUNTER:-}" ]] && rm -f "$_TS_COUNTER"' EXIT INT TERM

_ts_bump() {   # 呼ばれた回数を返す（サブシェル跨ぎで保持）
  local n
  n="$(cat "$_TS_COUNTER" 2>/dev/null)"; [[ "$n" =~ ^[0-9]+$ ]] || n=0
  n=$(( n + 1 )); printf '%s' "$n" > "$_TS_COUNTER"; printf '%s' "$n"
}

# 実 sleep を潰す（リトライで待たない）
_xrev_sleep() { :; }

# 1) cmux send が毎回成功 → 1回で rc=0
_cmux() { return 0; }
_cmux_send_line "surfaceX" "line"; assert_rc "送信成功は rc=0" 0 "$?"

# 2) cmux send が2回失敗→3回目成功（send-key=clearは常に成功）→ rc=0
printf '0' > "$_TS_COUNTER"
_cmux() {
  if [[ "$1" == "send" ]]; then
    local n; n="$(_ts_bump)"
    (( n <= 2 )) && return 1 || return 0
  fi
  return 0   # send-key（クリア）は成功
}
_cmux_send_line "surfaceX" "line"; assert_rc "2回失敗後に成功で rc=0（リトライ）" 0 "$?"
assert_eq "リトライ回数が正しく数えられている（サブシェル跨ぎ）" "3" "$(cat "$_TS_COUNTER")"

# 3) cmux send が常に失敗 → 規定回数リトライ後 rc=6
_cmux() { [[ "$1" == "send" ]] && return 1; return 0; }
XREV_SEND_RETRIES=3 _cmux_send_line "surfaceX" "line" >/dev/null 2>&1
assert_rc "常に失敗なら rc=6" 6 "$?"

# 4) 送信前にクリア（send-key）が呼ばれる
_CLEAR_CALLS=0
_cmux() {
  [[ "$1" == "send-key" ]] && _CLEAR_CALLS=$(( _CLEAR_CALLS + 1 ))
  return 0
}
_cmux_send_line "surfaceX" "line" >/dev/null 2>&1
assert_eq "送信前に入力クリア(send-key)が呼ばれる" "yes" "$([[ $_CLEAR_CALLS -gt 0 ]] && echo yes || echo no)"

# 5) production は一時ファイルを作らない（案A の回帰防止）。
_before="$(ls "${TMPDIR:-/tmp}" 2>/dev/null | grep -c '^xrev-send-err\.')"
_cmux() { [[ "$1" == "send" ]] && { echo "boom" >&2; return 1; }; return 0; }
XREV_SEND_RETRIES=2 _cmux_send_line "surfaceX" "line" >/dev/null 2>&1
_cmux() { return 0; }
_cmux_send_line "surfaceX" "line" >/dev/null 2>&1
_after="$(ls "${TMPDIR:-/tmp}" 2>/dev/null | grep -c '^xrev-send-err\.')"
assert_eq "production は一時ファイルを作らない" "$_before" "$_after"

# 後始末: 一時カウンタを消し、trap を元に戻し、実関数を復元（後続テストへの影響回避）
rm -f "$_TS_COUNTER"
trap - EXIT INT TERM
[[ -n "$_TS_TRAP_SAVE" ]] && eval "$_TS_TRAP_SAVE"
unset _TS_COUNTER _TS_TRAP_SAVE _CLEAR_CALLS _before _after
unset -f _ts_bump
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"
