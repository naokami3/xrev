#!/usr/bin/env bash
# parse-review.sh のテスト（構造化レビューの妥当性検証と severity 集計）。
# run.sh から source される前提（lib.sh のヘルパ・変数を利用）。

export XREV_CONFIG="$DEFAULT_CONFIG"
PR="$SCRIPTS/parse-review.sh"

# approve・findings なし → valid、blocker 0、rc 0
out="$(printf '%s' '{"verdict":"approve","findings":[]}' | "$PR")"; rc=$?
assert_rc "approve は rc=0" 0 "$rc"
assert_eq "approve は valid=true" "True" "$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["valid"])')"
assert_eq "approve は blockers=0" "0" "$(printf '%s' "$out" | json_get blockers)"

# critical+high+medium → counts 正確、blockers=2（critical/high のみ）
payload='{"verdict":"request_changes","findings":[
  {"file":"a","severity":"critical","category":"bug","message":"x"},
  {"file":"b","severity":"high","category":"security","message":"y"},
  {"file":"c","severity":"medium","category":"design","message":"z"}]}'
out="$(printf '%s' "$payload" | "$PR")"; rc=$?
assert_rc "妥当な request_changes は rc=0（=パース成功）" 0 "$rc"
assert_eq "blockers は critical+high=2（medium は除外）" "2" "$(printf '%s' "$out" | json_get blockers)"
assert_eq "total=3" "3" "$(printf '%s' "$out" | json_get total)"
assert_eq "counts.critical=1" "1" "$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["counts"]["critical"])')"

# 壊れた JSON（自由作文）→ valid=false、rc 1
out="$(printf '%s' 'これは自由作文のレビューです' | "$PR")"; rc=$?
assert_rc "壊れた入力は rc=1" 1 "$rc"
assert_eq "壊れた入力は valid=false" "False" "$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["valid"])')"

# verdict 不正 → valid=false
out="$(printf '%s' '{"verdict":"maybe","findings":[]}' | "$PR")"; rc=$?
assert_rc "verdict 不正は rc=1" 1 "$rc"

# 必須フィールド欠落（category 無し）→ valid=false
out="$(printf '%s' '{"verdict":"request_changes","findings":[{"file":"a","severity":"high","message":"x"}]}' | "$PR")"; rc=$?
assert_rc "必須フィールド欠落は rc=1" 1 "$rc"

# severity 不正 → valid=false
out="$(printf '%s' '{"verdict":"request_changes","findings":[{"file":"a","severity":"blocker","category":"bug","message":"x"}]}' | "$PR")"; rc=$?
assert_rc "severity 不正は rc=1" 1 "$rc"

# blocker 集合は config 依存: severity_blockers を medium だけにすると medium が blocker になる
tmpcfg="$(mktemp)"; python3 -c 'import json;d=json.load(open("'"$DEFAULT_CONFIG"'"));d["severity_blockers"]=["medium"];json.dump(d,open("'"$tmpcfg"'","w"))'
out="$(printf '%s' "$payload" | XREV_CONFIG="$tmpcfg" "$PR")"
assert_eq "severity_blockers=[medium] なら blockers=1" "1" "$(printf '%s' "$out" | json_get blockers)"
rm -f "$tmpcfg"
