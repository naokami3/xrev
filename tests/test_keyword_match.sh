#!/usr/bin/env bash
#
# test_keyword_match.sh — C4c: keyword 判定の単一真実源化（scripts/keyword-match.sh）。
#
# hooks/user-prompt-submit.sh はこのヘルパへ判定ロジック（config の keyword 読み・語境界判定・
# fenced/inline コードブロック除外）を委譲している。ここでは test_hook.sh の判定系ケースを
# ヘルパへの直叩き（stdin=依頼文テキスト・exit 0/1）で再検証し、境界・コードブロック除外の
# 回帰を防ぐ（既存ケースの流用）。

export XREV_CONFIG="$DEFAULT_CONFIG"
KEYWORD_MATCH="$SCRIPTS/keyword-match.sh"

# 既定 keyword(@xrev) が境界付きで発火する
printf '%s' "このAPI設計を @xrev でレビューして" | "$KEYWORD_MATCH"
assert_rc "@xrev ありは exit0（発火）" 0 "$?"

printf '%s' "普通の依頼です" | "$KEYWORD_MATCH"
assert_rc "@xrev なしは exit1（非発火）" 1 "$?"

printf '%s' "" | "$KEYWORD_MATCH"
assert_rc "空文字は exit1（非発火）" 1 "$?"

# stdout には何も出さない契約
out="$(printf '%s' "@xrev でレビューして" | "$KEYWORD_MATCH")"
assert_eq "ヘルパは stdout に何も出さない" "" "$out"

# keyword は config 依存
tmpcfg="$(mktemp)"
python3 -c 'import json;d=json.load(open("'"$DEFAULT_CONFIG"'"));d["keyword"]="@xreview";json.dump(d,open("'"$tmpcfg"'","w"))'
printf '%s' "@xrev では発火しない" | XREV_CONFIG="$tmpcfg" "$KEYWORD_MATCH"
assert_rc "keyword変更後は旧キーワードで非発火" 1 "$?"
printf '%s' "@xreview で発火する" | XREV_CONFIG="$tmpcfg" "$KEYWORD_MATCH"
assert_rc "新キーワードで発火" 0 "$?"
rm -f "$tmpcfg"

# --- 境界付きパーサの誤発火防止（test_hook.sh のケースを流用）---

printf '%s' "@xrevで直して" | "$KEYWORD_MATCH"
assert_rc "直後が日本語の『@xrevで直して』は発火する" 0 "$?"

printf '%s' $'説明\n```\n@xrev はコード内\n```\n以上です' | "$KEYWORD_MATCH"
assert_rc "fenced code block 内のみの @xrev は非発火" 1 "$?"

printf '%s' 'これは `@xrev` というコード片です' | "$KEYWORD_MATCH"
assert_rc "inline code の @xrev のみは非発火" 1 "$?"

printf '%s' "> ユーザーの依頼に '@xrev' が含まれています" | "$KEYWORD_MATCH"
assert_rc "引用行のみの @xrev は非発火" 1 "$?"

printf '%s' "foo@xrev という文字列があります" | "$KEYWORD_MATCH"
assert_rc "『foo@xrev』は直前が英字なので非発火" 1 "$?"

printf '%s' "@xrevfoo という文字列があります" | "$KEYWORD_MATCH"
assert_rc "『@xrevfoo』は直後が英字なので非発火" 1 "$?"

tmpcfg2="$(mktemp)"
python3 -c 'import json;d=json.load(open("'"$DEFAULT_CONFIG"'"));d["keyword"]="@x.rev";json.dump(d,open("'"$tmpcfg2"'","w"))'
printf '%s' "@x.rev でお願いします" | XREV_CONFIG="$tmpcfg2" "$KEYWORD_MATCH"
assert_rc "メタ文字を含む keyword『@x.rev』はエスケープされ正しく発火する" 0 "$?"
printf '%s' "@xyrev でお願いします" | XREV_CONFIG="$tmpcfg2" "$KEYWORD_MATCH"
assert_rc "『.』が任意の1文字にマッチせず『@xyrev』は非発火（re.escape 確認）" 1 "$?"
rm -f "$tmpcfg2"

unset out tmpcfg tmpcfg2
