#!/usr/bin/env bash
# review-loop.sh のテスト。
#   - _xrev_decide: 終端判定の純粋関数（cmux 不要）
#   - 統合: XREV_REVIEW_FN で transport をスタブ注入し、決定 JSON と exit を確認

export XREV_CONFIG="$DEFAULT_CONFIG"
# source 時は main を実行しない設計（BASH_SOURCE ガード）。関数だけ取り込む。
# shellcheck source=/dev/null
source "$SCRIPTS/review-loop.sh"

# ── _xrev_decide（純粋）: 引数 (transport_rc, parse_rc, blockers, iter, max) ──
assert_eq "transport 失敗は最優先で transport_error" "transport_error 22" "$(_xrev_decide 22 0 0 1 5)"
assert_eq "parse 失敗は invalid" "invalid 21" "$(_xrev_decide 0 1 0 1 5)"
assert_eq "blocker 0 は converged" "converged 0" "$(_xrev_decide 0 0 0 3 5)"
assert_eq "blocker>0 かつ 上限到達は escalate" "escalate 20" "$(_xrev_decide 0 0 2 5 5)"
assert_eq "blocker>0 かつ 上限未満は continue" "continue 10" "$(_xrev_decide 0 0 1 1 5)"
assert_eq "transport 失敗は parse より優先" "transport_error 22" "$(_xrev_decide 22 1 0 9 5)"

# ── 統合: transport をスタブにして 1 ラウンドを通す ──
# approve を返すスタブ → converged / rc 0 / blockers 0
_stub_approve() { printf '%s' '{"verdict":"approve","findings":[]}'; }
out="$(printf '%s' "ダミー差分" | XREV_REVIEW_FN=_stub_approve _xrev_review_loop_run 1)"; rc=$?
assert_rc "approve スタブで rc=0" 0 "$rc"
assert_eq "approve スタブで decision=converged" "converged" "$(printf '%s' "$out" | json_get decision)"
assert_eq "approve スタブで blockers=0" "0" "$(printf '%s' "$out" | json_get blockers)"

# request_changes(high) を返すスタブ、iter=1<max → continue / rc 10 / blockers 1
_stub_changes() { printf '%s' '{"verdict":"request_changes","findings":[{"file":"x","severity":"high","category":"bug","message":"NG"}]}'; }
out="$(printf '%s' "ダミー差分" | XREV_REVIEW_FN=_stub_changes _xrev_review_loop_run 1)"; rc=$?
assert_rc "request_changes スタブで rc=10(continue)" 10 "$rc"
assert_eq "decision=continue" "continue" "$(printf '%s' "$out" | json_get decision)"
assert_eq "blockers=1" "1" "$(printf '%s' "$out" | json_get blockers)"
assert_eq "findings が決定JSONに含まれる" "x" "$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["findings"][0]["file"])')"

# 同じスタブで iter=max → escalate / rc 20
out="$(printf '%s' "ダミー差分" | XREV_MAX_ITERATIONS=3 XREV_REVIEW_FN=_stub_changes _xrev_review_loop_run 3)"; rc=$?
assert_rc "上限到達で rc=20(escalate)" 20 "$rc"
assert_eq "decision=escalate" "escalate" "$(printf '%s' "$out" | json_get decision)"

# 契約違反（自由作文）を返すスタブ → invalid / rc 21
_stub_garbage() { printf '%s' 'ただの感想文です'; }
out="$(printf '%s' "ダミー差分" | XREV_REVIEW_FN=_stub_garbage _xrev_review_loop_run 1)"; rc=$?
assert_rc "契約違反で rc=21(invalid)" 21 "$rc"
assert_eq "decision=invalid" "invalid" "$(printf '%s' "$out" | json_get decision)"

# transport 自体が失敗するスタブ → transport_error / rc 22
_stub_fail() { return 12; }
out="$(printf '%s' "ダミー差分" | XREV_REVIEW_FN=_stub_fail _xrev_review_loop_run 1)"; rc=$?
assert_rc "transport 失敗で rc=22" 22 "$rc"
assert_eq "decision=transport_error" "transport_error" "$(printf '%s' "$out" | json_get decision)"
