#!/usr/bin/env bash
# transport.sh::_scan_review_blocks のテスト（純粋関数）。
# 「センチネル間が JSON 妥当かつ verdict を持つ」ブロックだけを本物とみなす区別ロジック。

export XREV_CONFIG="$DEFAULT_CONFIG"
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"

B='===XREV-JSON-BEGIN==='
E='===XREV-JSON-END==='

# 1) エコー相当（センチネルはあるが間に JSON なし）→ 0 件
screen=$'noise\n'"$B"$'\n開始マーカー: 説明文\n'"$E"$'\nmore'
assert_eq "エコー(JSON無し)は 0 件" "0" "$(_scan_review_blocks "$screen" | head -1)"

# 2) テンプレート（不正 JSON）→ 0 件
screen="$B"$'\n{ ここに verdict と findings[] を持つ JSON }\n'"$E"
assert_eq "テンプレート(不正JSON)は 0 件" "0" "$(_scan_review_blocks "$screen" | head -1)"

# 3) verdict を持たない妥当 JSON → 0 件（本物の応答ではない）
screen="$B"$'\n{"foo":1}\n'"$E"
assert_eq "verdict 無しの JSON は 0 件" "0" "$(_scan_review_blocks "$screen" | head -1)"

# 4) 妥当な応答 1 件 → 1 件、中身を返す
screen=$'x\n'"$B"$'\n{"verdict":"approve","findings":[]}\n'"$E"$'\ny'
out="$(_scan_review_blocks "$screen")"
assert_eq "妥当 1 件は count=1" "1" "$(printf '%s' "$out" | head -1)"
assert_eq "1 件の中身を返す" '{"verdict":"approve","findings":[]}' "$(printf '%s' "$out" | tail -n +2)"

# 5) 古い応答 + 新しい応答 → 2 件、最後（新着）を返す
old='{"verdict":"request_changes","findings":[{"file":"a","severity":"high","category":"bug","message":"old"}]}'
new='{"verdict":"approve","findings":[]}'
screen="$B"$'\n'"$old"$'\n'"$E"$'\n中略\n'"$B"$'\n'"$new"$'\n'"$E"
out="$(_scan_review_blocks "$screen")"
assert_eq "新旧 2 件は count=2" "2" "$(printf '%s' "$out" | head -1)"
assert_eq "最後（新着）の中身を返す" "$new" "$(printf '%s' "$out" | tail -n +2)"

# 6) 何も無い画面 → 0 件
assert_eq "空画面は 0 件" "0" "$(_scan_review_blocks "ただのログ出力" | head -1)"
