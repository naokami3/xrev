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
# レビュー完了系(converged/continue/escalate)は exit 0、取得失敗系(invalid/transport_error)のみ非ゼロ
assert_eq "blocker 0 は converged(exit0)" "converged 0" "$(_xrev_decide 0 0 0 3 5)"
assert_eq "上限到達の escalate も exit0（レビューは完了）" "escalate 0" "$(_xrev_decide 0 0 2 5 5)"
assert_eq "continue も exit0（continue は正常）" "continue 0" "$(_xrev_decide 0 0 1 1 5)"
assert_eq "transport 失敗は parse より優先" "transport_error 22" "$(_xrev_decide 22 1 0 9 5)"

# ── 統合: transport をスタブにして 1 ラウンドを通す ──
# approve を返すスタブ → converged / rc 0 / blockers 0
_stub_approve() { printf '%s' '{"verdict":"approve","findings":[]}'; }
out="$(printf '%s' "ダミー差分" | XREV_REVIEW_FN=_stub_approve _xrev_review_loop_run 1)"; rc=$?
assert_rc "approve スタブで rc=0" 0 "$rc"
assert_eq "approve スタブで decision=converged" "converged" "$(printf '%s' "$out" | json_get decision)"
assert_eq "approve スタブで blockers=0" "0" "$(printf '%s' "$out" | json_get blockers)"

# request_changes(high) を返すスタブ、iter=1<max → continue / rc 0 / blockers 1
_stub_changes() { printf '%s' '{"verdict":"request_changes","findings":[{"file":"x","severity":"high","category":"bug","message":"NG"}]}'; }
out="$(printf '%s' "ダミー差分" | XREV_REVIEW_FN=_stub_changes _xrev_review_loop_run 1)"; rc=$?
assert_rc "request_changes スタブで rc=0（continue は正常）" 0 "$rc"
assert_eq "decision=continue" "continue" "$(printf '%s' "$out" | json_get decision)"
assert_eq "blockers=1" "1" "$(printf '%s' "$out" | json_get blockers)"
assert_eq "findings が決定JSONに含まれる" "x" "$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["findings"][0]["file"])')"

# 同じスタブで iter=max → escalate / rc 0（レビューは完了。decision で判別）
out="$(printf '%s' "ダミー差分" | XREV_MAX_ITERATIONS=3 XREV_REVIEW_FN=_stub_changes _xrev_review_loop_run 3)"; rc=$?
assert_rc "上限到達でも rc=0（escalate）" 0 "$rc"
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

# ── _format_decision（純粋）: 異常系で壊れず既定値の決定JSONを出す ──
# raw も parsed も壊れている（transport_error/invalid 相当）→ 既定値で整形できる
out="$(_format_decision transport_error 1 5 "" "")"
assert_eq "空 raw/parsed でも decision を保持" "transport_error" "$(printf '%s' "$out" | json_get decision)"
assert_eq "空時 blockers 既定 0" "0" "$(printf '%s' "$out" | json_get blockers)"
assert_eq "空時 verdict は null" "null" "$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["verdict"]))')"

# 壊れた JSON 文字列を渡しても例外で死なず既定にフォールバック
out="$(_format_decision invalid 2 5 "これはJSONでない" "これも壊れている")"
assert_eq "壊れた raw でも decision=invalid" "invalid" "$(printf '%s' "$out" | json_get decision)"
assert_eq "壊れた parsed でも blockers=0" "0" "$(printf '%s' "$out" | json_get blockers)"
assert_eq "raw_review は渡した生文字列を保持" "これはJSONでない" "$(printf '%s' "$out" | json_get raw_review)"

# 正常: parsed の counts/blockers と raw の findings を決定JSONに反映
raw='{"verdict":"request_changes","findings":[{"file":"a","severity":"high","category":"bug","message":"m"}],"summary":"要約"}'
parsed='{"valid":true,"verdict":"request_changes","counts":{"critical":0,"high":1,"medium":0,"low":0,"nit":0},"blockers":1,"total":1}'
out="$(_format_decision continue 1 5 "$raw" "$parsed")"
assert_eq "正常時 blockers を parsed から反映" "1" "$(printf '%s' "$out" | json_get blockers)"
assert_eq "正常時 summary を raw から反映" "要約" "$(printf '%s' "$out" | json_get summary)"
assert_eq "正常時 findings を raw から反映" "a" "$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["findings"][0]["file"])')"

# ── ループ安全弁: round_state（通算 transport 試行の上限・巻戻し検知）──
_stub_approve2() { printf '%s' '{"verdict":"approve","findings":[]}'; }

# 既定（round_state 無し）: transport_attempts は 1 から始まり、違反は無い
out="$(printf '%s' "x" | XREV_REVIEW_FN=_stub_approve2 _xrev_review_loop_run 1)"
assert_eq "round_state 無し → transport_attempts=1" "1" \
  "$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["round_state"]["transport_attempts"])')"
assert_eq "round_state 無し → state_violation は null" "null" \
  "$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["state_violation"]))')"
assert_eq "round_state 無し → 通常どおり converged" "converged" "$(printf '%s' "$out" | json_get decision)"

# 前回 attempts を引き継ぐ: 2 → 3 に増える
out="$(printf '%s' "x" | XREV_ROUND_STATE='{"transport_attempts":2,"iter":1}' XREV_REVIEW_FN=_stub_approve2 _xrev_review_loop_run 2)"
assert_eq "前回 attempts=2 を引き継いで 3" "3" \
  "$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["round_state"]["transport_attempts"])')"

# 通算上限到達 → escalate（converged になるはずでも安全弁が優先）/ exit0。境界: prev>=max で送信しない。
out="$(printf '%s' "x" | XREV_MAX_TRANSPORT_ATTEMPTS=3 XREV_ROUND_STATE='{"transport_attempts":3,"iter":2}' XREV_REVIEW_FN=_stub_approve2 _xrev_review_loop_run 3)"; rc=$?
assert_rc "上限到達でも rc=0（escalate）" 0 "$rc"
assert_eq "通算上限到達 → escalate" "escalate" "$(printf '%s' "$out" | json_get decision)"
assert_eq "違反理由 max_transport_attempts" "max_transport_attempts" "$(printf '%s' "$out" | json_get state_violation)"

# 境界の厳密性: 上限到達時は transport を「呼ばない」(追加送信0回)。呼出し回数を一時ファイルで数える。
_cf="$(mktemp)"; _stub_count() { echo x >> "$_cf"; printf '%s' '{"verdict":"approve","findings":[]}'; }
out="$(printf '%s' "x" | XREV_MAX_TRANSPORT_ATTEMPTS=2 XREV_ROUND_STATE='{"transport_attempts":2,"iter":1}' XREV_REVIEW_FN=_stub_count _xrev_review_loop_run 2)"
assert_eq "上限到達時は transport を呼ばない(0回)" "0" "$(grep -c . "$_cf")"
assert_eq "上限到達時の decision=escalate" "escalate" "$(printf '%s' "$out" | json_get decision)"
: > "$_cf"
out="$(printf '%s' "x" | XREV_MAX_TRANSPORT_ATTEMPTS=5 XREV_ROUND_STATE='{"transport_attempts":1,"iter":1}' XREV_REVIEW_FN=_stub_count _xrev_review_loop_run 2)"
assert_eq "上限未満なら transport を1回呼ぶ" "1" "$(grep -c . "$_cf")"
rm -f "$_cf"

# 巻戻し（前回 iter=3 なのに今 iter=1）→ escalate / 違反理由 rollback（送信しない）
out="$(printf '%s' "x" | XREV_ROUND_STATE='{"transport_attempts":1,"iter":3}' XREV_REVIEW_FN=_stub_approve2 _xrev_review_loop_run 1)"
assert_eq "巻戻し → escalate" "escalate" "$(printf '%s' "$out" | json_get decision)"
assert_eq "違反理由 rollback" "rollback" "$(printf '%s' "$out" | json_get state_violation)"

# round_state の原子的検証（fail closed）: iter>1 での欠落 / 負値 / 破損 は escalate(bad_round_state)
out="$(printf '%s' "x" | XREV_REVIEW_FN=_stub_approve2 _xrev_review_loop_run 2)"
assert_eq "iter>1 で round_state 欠落 → escalate" "escalate" "$(printf '%s' "$out" | json_get decision)"
assert_eq "欠落の違反理由 bad_round_state" "bad_round_state" "$(printf '%s' "$out" | json_get state_violation)"

out="$(printf '%s' "x" | XREV_ROUND_STATE='{"transport_attempts":-100,"iter":1}' XREV_REVIEW_FN=_stub_approve2 _xrev_review_loop_run 1)"
assert_eq "負値 transport_attempts → escalate" "escalate" "$(printf '%s' "$out" | json_get decision)"
assert_eq "負値の違反理由 bad_round_state" "bad_round_state" "$(printf '%s' "$out" | json_get state_violation)"

out="$(printf '%s' "x" | XREV_ROUND_STATE='これは壊れたJSON' XREV_REVIEW_FN=_stub_approve2 _xrev_review_loop_run 2)"
assert_eq "破損 round_state → escalate" "escalate" "$(printf '%s' "$out" | json_get decision)"

# 上限・状態が健全なら通常どおり transport 失敗は transport_error（安全弁は誤発火しない）
_stub_fail2() { return 12; }
out="$(printf '%s' "x" | XREV_ROUND_STATE='{"transport_attempts":1,"iter":1}' XREV_REVIEW_FN=_stub_fail2 _xrev_review_loop_run 2)"; rc=$?
assert_rc "健全状態での transport 失敗は rc22" 22 "$rc"
assert_eq "transport 失敗は transport_error" "transport_error" "$(printf '%s' "$out" | json_get decision)"

# round_state の厳密型・範囲検証（float/数値文字列/巨大値を受理しない・送信前に拒否）
_cf2="$(mktemp)"; _stub_count2() { echo x >> "$_cf2"; printf '%s' '{"verdict":"approve","findings":[]}'; }
for bad in '{"transport_attempts":-0.9,"iter":1}' '{"transport_attempts":1.9,"iter":1}' \
           '{"transport_attempts":"1","iter":1}' '{"transport_attempts":1,"iter":true}' \
           '{"transport_attempts":99999999999999999999,"iter":1}'; do
  : > "$_cf2"
  out="$(printf '%s' "x" | XREV_ROUND_STATE="$bad" XREV_REVIEW_FN=_stub_count2 _xrev_review_loop_run 1)"
  assert_eq "不正型/範囲の round_state は escalate: $bad" "escalate" "$(printf '%s' "$out" | json_get decision)"
  assert_eq "不正型/範囲は bad_round_state: $bad" "bad_round_state" "$(printf '%s' "$out" | json_get state_violation)"
  assert_eq "不正型/範囲は transport を呼ばない: $bad" "0" "$(grep -c . "$_cf2")"
done
rm -f "$_cf2"

# ── 参照モード(Phase2): mode/status/head(基底OID)/diff_hash の厳密照合 ──
# 完全一致する reviewer 応答（mode=reference・status=verified・head=H1・diff_hash=ABC）
_stub_ref_ok()      { printf '%s' '{"verdict":"approve","findings":[],"reference_context":{"mode":"reference","status":"verified","head":"H1","diff_hash":"ABC"}}'; }
# diff だけ一致するが基底 HEAD が違う（別コンテキストを読んだ＝採用してはいけない）
_stub_ref_head_ng() { printf '%s' '{"verdict":"approve","findings":[],"reference_context":{"mode":"reference","status":"verified","head":"H2","diff_hash":"ABC"}}'; }
# diff_hash 不一致
_stub_ref_diff_ng() { printf '%s' '{"verdict":"approve","findings":[],"reference_context":{"mode":"reference","status":"verified","head":"H1","diff_hash":"XYZ"}}'; }
# status 未 verified
_stub_ref_unver()   { printf '%s' '{"verdict":"approve","findings":[],"reference_context":{"mode":"reference","status":"unavailable","head":"H1","diff_hash":"ABC"}}'; }
_stub_ref_none()    { printf '%s' '{"verdict":"approve","findings":[]}'; }
_stub_ref_18()      { return 18; }

# 完全一致 → converged（reference_fallbacks は増えない）
out="$(printf '%s' "x" | XREV_REFERENCE_MODE=1 XREV_EXPECT_DIFF_HASH=ABC XREV_EXPECT_HEAD=H1 XREV_REVIEW_FN=_stub_ref_ok _xrev_review_loop_run 1)"
assert_eq "mode/status/head/diff_hash 全一致 → converged" "converged" "$(printf '%s' "$out" | json_get decision)"
assert_eq "一致時 reference_fallbacks=0" "0" \
  "$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["round_state"]["reference_fallbacks"])')"

# diff 一致でも基底 HEAD 不一致 → reference_unverified（基底コンテキスト相違を弾く＝Phase2 の肝）
out="$(printf '%s' "x" | XREV_REFERENCE_MODE=1 XREV_EXPECT_DIFF_HASH=ABC XREV_EXPECT_HEAD=H1 XREV_REVIEW_FN=_stub_ref_head_ng _xrev_review_loop_run 1)"; rc=$?
assert_rc "HEAD 不一致でも rc=0（正常系）" 0 "$rc"
assert_eq "diff一致でもHEAD不一致 → reference_unverified" "reference_unverified" "$(printf '%s' "$out" | json_get decision)"
assert_eq "不一致で reference_fallbacks=1" "1" \
  "$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["round_state"]["reference_fallbacks"])')"

# diff_hash 不一致 → reference_unverified
out="$(printf '%s' "x" | XREV_REFERENCE_MODE=1 XREV_EXPECT_DIFF_HASH=ABC XREV_EXPECT_HEAD=H1 XREV_REVIEW_FN=_stub_ref_diff_ng _xrev_review_loop_run 1)"
assert_eq "diff_hash 不一致 → reference_unverified" "reference_unverified" "$(printf '%s' "$out" | json_get decision)"

# status!=verified → reference_unverified
out="$(printf '%s' "x" | XREV_REFERENCE_MODE=1 XREV_EXPECT_DIFF_HASH=ABC XREV_EXPECT_HEAD=H1 XREV_REVIEW_FN=_stub_ref_unver _xrev_review_loop_run 1)"
assert_eq "status 未verified → reference_unverified" "reference_unverified" "$(printf '%s' "$out" | json_get decision)"

# reference_context 欠落 → reference_unverified
out="$(printf '%s' "x" | XREV_REFERENCE_MODE=1 XREV_EXPECT_DIFF_HASH=ABC XREV_EXPECT_HEAD=H1 XREV_REVIEW_FN=_stub_ref_none _xrev_review_loop_run 1)"
assert_eq "reference_context 欠落 → reference_unverified" "reference_unverified" "$(printf '%s' "$out" | json_get decision)"

# 期待 HEAD 未設定 → reference_unverified（fail closed）
out="$(printf '%s' "x" | XREV_REFERENCE_MODE=1 XREV_EXPECT_DIFF_HASH=ABC XREV_REVIEW_FN=_stub_ref_ok _xrev_review_loop_run 1)"
assert_eq "期待HEAD未設定 → reference_unverified" "reference_unverified" "$(printf '%s' "$out" | json_get decision)"

# transport が同一WS外を拒否(exit18) → reference_unverified（inline へ切替）
out="$(printf '%s' "x" | XREV_REFERENCE_MODE=1 XREV_EXPECT_DIFF_HASH=ABC XREV_EXPECT_HEAD=H1 XREV_REVIEW_FN=_stub_ref_18 _xrev_review_loop_run 1)"; rc=$?
assert_rc "同一WS外拒否(18)でも rc=0" 0 "$rc"
assert_eq "同一WS外(exit18) → reference_unverified" "reference_unverified" "$(printf '%s' "$out" | json_get decision)"

# フォールバック通算が上限超 → escalate（無限の参照→inline 往復を防ぐ）
out="$(printf '%s' "x" | XREV_MAX_REFERENCE_FALLBACKS=3 XREV_REFERENCE_MODE=1 XREV_EXPECT_DIFF_HASH=ABC XREV_EXPECT_HEAD=H1 XREV_ROUND_STATE='{"transport_attempts":1,"iter":1,"reference_fallbacks":3}' XREV_REVIEW_FN=_stub_ref_diff_ng _xrev_review_loop_run 1)"
assert_eq "fallback 上限超 → escalate" "escalate" "$(printf '%s' "$out" | json_get decision)"
assert_eq "fallback 上限超の理由 max_reference_fallbacks" "max_reference_fallbacks" "$(printf '%s' "$out" | json_get state_violation)"

# 参照モード OFF（既定）では検証しない（inline は従来どおり）
out="$(printf '%s' "x" | XREV_REVIEW_FN=_stub_ref_diff_ng _xrev_review_loop_run 1)"
assert_eq "inline(参照OFF)は検証せず converged" "converged" "$(printf '%s' "$out" | json_get decision)"

# reference_fallbacks も round_state 検証の対象（負値は bad_round_state）
out="$(printf '%s' "x" | XREV_ROUND_STATE='{"transport_attempts":1,"iter":1,"reference_fallbacks":-1}' XREV_REVIEW_FN=_stub_ref_ok _xrev_review_loop_run 1)"
assert_eq "負の reference_fallbacks → escalate(bad_round_state)" "bad_round_state" "$(printf '%s' "$out" | json_get state_violation)"
