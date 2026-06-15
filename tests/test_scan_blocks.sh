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

# 4) 妥当な応答 1 件 → 1 件、中身（正規化JSON）を返す
screen=$'x\n'"$B"$'\n{"verdict":"approve","findings":[]}\n'"$E"$'\ny'
out="$(_scan_review_blocks "$screen")"
assert_eq "妥当 1 件は count=1" "1" "$(printf '%s' "$out" | head -1)"
assert_eq "1 件の中身は verdict=approve" "approve" \
  "$(printf '%s' "$out" | tail -n +2 | python3 -c 'import json,sys;print(json.load(sys.stdin)["verdict"])')"

# 5) 古い応答 + 新しい応答 → 2 件、最後（新着）を返す
old='{"verdict":"request_changes","findings":[{"file":"a","severity":"high","category":"bug","message":"old"}]}'
new='{"verdict":"approve","findings":[]}'
screen="$B"$'\n'"$old"$'\n'"$E"$'\n中略\n'"$B"$'\n'"$new"$'\n'"$E"
out="$(_scan_review_blocks "$screen")"
assert_eq "新旧 2 件は count=2" "2" "$(printf '%s' "$out" | head -1)"
assert_eq "最後（新着=approve）の中身を返す" "approve" \
  "$(printf '%s' "$out" | tail -n +2 | python3 -c 'import json,sys;print(json.load(sys.stdin)["verdict"])')"

# 6) 何も無い画面 → 0 件
assert_eq "空画面は 0 件" "0" "$(_scan_review_blocks "ただのログ出力" | head -1)"

# 7) TUI 折り返し + ガター字下げ + 文字列途中の改行（実 Codex 画面の再現）→ de-wrap して検出
wrapped="$B"$'\n  {\n  "verdict": "request_changes",\n  "findings": [\n  {\n  "file": "design",\n  "severity": "high",\n  "category": "bug",\n  "message": "これは長いメッセージで途中で折り返\n  されてガター字下げが付いています"\n  }\n  ]\n  }\n'"$E"
out="$(_scan_review_blocks "$wrapped")"
assert_eq "折り返しJSONを 1 件として検出" "1" "$(printf '%s' "$out" | head -1)"
# 返却は正規化済みクリーンJSON → そのまま json.loads できる
assert_eq "返却JSONがパース可能で verdict を持つ" "request_changes" \
  "$(printf '%s' "$out" | tail -n +2 | python3 -c 'import json,sys;print(json.load(sys.stdin)["verdict"])')"
# 折り返しで割れた文字列が復元される（改行とガターが除去される）
assert_contains "折り返し文字列が連結復元される" \
  "$(printf '%s' "$out" | tail -n +2)" "途中で折り返されてガター字下げ"
