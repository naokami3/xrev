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

# --- ここから境界付きパーサの誤発火防止テスト（CLAUDE.md 絶対ルール3対応） ---

# 1) 自然文中の @xrev はそのまま発火する
out="$(printf '%s' '{"prompt":"@xrev でレビューして"}' | "$HOOK")"
assert_contains "自然文『@xrev でレビューして』は発火する" "$out" "additionalContext"

# 2) 直後が日本語（英数字/_/- 以外）なら発火する
out="$(printf '%s' '{"prompt":"@xrevで直して"}' | "$HOOK")"
assert_contains "直後が日本語の『@xrevで直して』は発火する" "$out" "additionalContext"

# 3) fenced code block（```）の中だけに @xrev → 沈黙
prompt_json="$(python3 -c 'import json;print(json.dumps({"prompt":"説明\n```\n@xrev はコード内\n```\n以上です"}))')"
out="$(printf '%s' "$prompt_json" | "$HOOK")"
assert_eq "fenced code block 内のみの @xrev は沈黙" "" "$out"

# 4) inline code（\`@xrev\`）のみ → 沈黙
out="$(printf '%s' '{"prompt":"これは `@xrev` というコード片です"}' | "$HOOK")"
assert_eq "inline code の @xrev のみは沈黙" "" "$out"

# 5) 引用行（行頭 >）のみに @xrev → 沈黙
out="$(printf '%s' "{\"prompt\":\"> ユーザーの依頼に '@xrev' が含まれています\"}" | "$HOOK")"
assert_eq "引用行のみの @xrev は沈黙" "" "$out"

# 6) 直前直後が英数字等に連結 → 沈黙（部分一致除外）
out="$(printf '%s' '{"prompt":"foo@xrev という文字列があります"}' | "$HOOK")"
assert_eq "『foo@xrev』は直前が英字なので沈黙" "" "$out"
out="$(printf '%s' '{"prompt":"@xrevfoo という文字列があります"}' | "$HOOK")"
assert_eq "『@xrevfoo』は直後が英字なので沈黙" "" "$out"

# 7) keyword を config で変更した場合の発火/非発火。
#    正規表現メタ文字を含む keyword（"@x.rev"）が誤爆しないことも確認する。
tmpcfg2="$(mktemp)"; python3 -c 'import json;d=json.load(open("'"$DEFAULT_CONFIG"'"));d["keyword"]="@review";json.dump(d,open("'"$tmpcfg2"'","w"))'
out="$(printf '%s' '{"prompt":"@review でお願いします"}' | XREV_CONFIG="$tmpcfg2" "$HOOK")"
assert_contains "keyword を @review に変えると発火する" "$out" "additionalContext"
out="$(printf '%s' '{"prompt":"@xrev では発火しない"}' | XREV_CONFIG="$tmpcfg2" "$HOOK")"
assert_eq "keyword を @review に変えると旧 @xrev は沈黙" "" "$out"
rm -f "$tmpcfg2"

tmpcfg3="$(mktemp)"; python3 -c 'import json;d=json.load(open("'"$DEFAULT_CONFIG"'"));d["keyword"]="@x.rev";json.dump(d,open("'"$tmpcfg3"'","w"))'
out="$(printf '%s' '{"prompt":"@x.rev でお願いします"}' | XREV_CONFIG="$tmpcfg3" "$HOOK")"
assert_contains "メタ文字を含む keyword『@x.rev』はエスケープされ正しく発火する" "$out" "additionalContext"
out="$(printf '%s' '{"prompt":"@xyrev でお願いします"}' | XREV_CONFIG="$tmpcfg3" "$HOOK")"
assert_eq "『.』が任意の1文字にマッチせず『@xyrev』は沈黙（re.escape 確認）" "" "$out"
rm -f "$tmpcfg3"
