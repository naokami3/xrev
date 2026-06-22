#!/usr/bin/env bash
# transport.sh の送信エンコード（純粋関数）テスト。
#   _build_framed_line: payload を1物理行にエンコード（cmux が \n,\t を展開する問題を回避）
#   _detect_content_type / _compute_submit_settle

export XREV_CONFIG="$DEFAULT_CONFIG"
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"

has_newline() { printf '%s' "$1" | python3 -c 'import sys;print("yes" if "\n" in sys.stdin.read() else "no")'; }

# ── plain ──
out="$(_build_framed_line plain rID1 "$(printf '行1\n行2')")"
assert_eq "plain は1物理行（実改行を含まない）" "no" "$(has_newline "$out")"
assert_contains "round_id を含む" "$out" "round_id=rID1"
assert_contains "PAYLOAD_PLAIN マーカー" "$out" "PAYLOAD_PLAIN"
assert_contains "改行は <XREV-NL> に畳まれる" "$out" "行1 <XREV-NL> 行2"
assert_contains "末尾 END_ROUND マーカー" "$out" "END_ROUND_rID1"

# バックスラッシュ・タブの無害化（cmux send が \n,\t を展開するため）
out="$(_build_framed_line plain rID2 'a\nb')"   # 単一引用符 → a,\,n,b（リテラル backslash）
assert_contains "バックスラッシュは <XREV-BS> に置換" "$out" "a<XREV-BS>nb"
out="$(_build_framed_line plain rID3 "$(printf 'x\ty')")"  # 実タブ
assert_contains "タブは <XREV-TAB> に置換" "$out" "x<XREV-TAB>y"
assert_eq "タブ置換後も1物理行" "no" "$(has_newline "$out")"

# ── unified_diff（番号付き line framing）──
out="$(_build_framed_line unified_diff rDF "$(printf '@@ -1 +1 @@\n-old\n+    new')")"
assert_eq "framed も1物理行" "no" "$(has_newline "$out")"
assert_contains "PAYLOAD_FRAMED と lines 数" "$out" "PAYLOAD_FRAMED content_type=unified_diff lines=3"
assert_contains "行境界 L0001" "$out" "|| L0001: @@ -1 +1 @@"
assert_contains "行頭の - と内容を保持" "$out" "|| L0002: -old"
assert_contains "行頭の + とインデントを保持" "$out" "|| L0003: +    new"

# ── 制御トークンの衝突回避（可逆エスケープ）──
# 本文に制御トークンが元から含まれても、区切りとして誤解されないよう退避される。
out="$(_build_framed_line plain rESC '本文に<XREV-NL>と|| L0001:とEND_ROUND_xとXREVQが出る')"
assert_eq "本文の制御トークンは区切りを生まない（real改行0なので ' <XREV-NL> ' は0個）" "0" \
  "$(printf '%s' "$out" | grep -oF ' <XREV-NL> ' | wc -l | tr -d ' ')"
assert_contains "本文の <XREV-NL> は XREVQnl へ退避" "$out" "XREVQnl"
assert_contains "本文の '|| L' は XREVQll へ退避" "$out" "XREVQll0001:"
assert_contains "本文の END_ROUND_ は XREVQer へ退避" "$out" "XREVQerx"
assert_contains "導入子 XREVQ は二重化して退避" "$out" "XREVQXREVQ"
# 実改行は区切りになり、本文の <XREV-NL> は退避される（混在）
out="$(_build_framed_line plain rESC2 "$(printf 'A<XREV-NL>B\n2行目')")"
assert_eq "実改行は区切り1個" "1" "$(printf '%s' "$out" | grep -oF ' <XREV-NL> ' | wc -l | tr -d ' ')"
assert_contains "本文中の <XREV-NL> は退避される" "$out" "AXREVQnlB"

# ── content_type 判定 ──
assert_eq "散文は plain" "plain" "$(_detect_content_type 'これは設計の説明文です')"
assert_eq "hunk ヘッダがあれば unified_diff" "unified_diff" "$(_detect_content_type "$(printf '@@ -1 +1 @@\n-a\n+b')")"
assert_eq "diff --git も unified_diff" "unified_diff" "$(_detect_content_type "$(printf 'diff --git a b\n+x')")"
assert_eq "先頭が箇条書きのハイフンだけなら plain（誤判定しない）" "plain" "$(_detect_content_type "$(printf -- '- 項目1\n- 項目2')")"
assert_eq "コードフェンスを含むと code" "code" "$(_detect_content_type "$(printf '説明\n```python\nx=1\n```')")"

# ── submit 待機の長さ比例 ──
assert_eq "len0 は base=1" "1" "$(_compute_submit_settle 0)"
assert_eq "len4000 は 1+2=3" "3" "$(_compute_submit_settle 4000)"
assert_eq "len20000 は上限8" "8" "$(_compute_submit_settle 20000)"
