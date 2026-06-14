#!/usr/bin/env bash
# hooks/user-prompt-submit.sh のテスト（@xrev 検知時のみ注入、無ければ沈黙）。

export XREV_CONFIG="$DEFAULT_CONFIG"
HOOK="$HOOKS/user-prompt-submit.sh"

# @xrev あり → additionalContext を含む JSON を出力、rc 0
out="$(printf '%s' '{"prompt":"このAPI設計を @xrev でレビューして"}' | "$HOOK")"; rc=$?
assert_rc "@xrev ありは rc=0" 0 "$rc"
assert_contains "additionalContext を注入する" "$out" "additionalContext"
assert_contains "UserPromptSubmit イベント名を含む" "$out" "UserPromptSubmit"
assert_contains "注入文に xrev 起動の指示が入る" "$out" "xrev"

# @xrev なし → 完全沈黙（無出力）、rc 0
out="$(printf '%s' '{"prompt":"普通の依頼です"}' | "$HOOK")"; rc=$?
assert_rc "@xrev なしは rc=0" 0 "$rc"
assert_eq "@xrev なしは無出力（沈黙）" "" "$out"

# prompt が空 → 沈黙
out="$(printf '%s' '{"prompt":""}' | "$HOOK")"
assert_eq "空 prompt は無出力" "" "$out"

# キーワードは config 依存: keyword を変えると検知語も変わる
tmpcfg="$(mktemp)"; python3 -c 'import json;d=json.load(open("'"$DEFAULT_CONFIG"'"));d["keyword"]="@xreview";json.dump(d,open("'"$tmpcfg"'","w"))'
out="$(printf '%s' '{"prompt":"@xrev では発火しない"}' | XREV_CONFIG="$tmpcfg" "$HOOK")"
assert_eq "keyword 変更後は旧キーワードで沈黙" "" "$out"
out="$(printf '%s' '{"prompt":"@xreview で発火する"}' | XREV_CONFIG="$tmpcfg" "$HOOK")"
assert_contains "新キーワードで注入する" "$out" "additionalContext"
rm -f "$tmpcfg"
