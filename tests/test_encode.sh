#!/usr/bin/env bash
# transport.sh の送信エンコード（純粋関数）テスト。
#   _build_framed_line / _xrev_decode_line: payload を ASCII-only の1物理行へ相互変換する
#   _detect_content_type / _compute_submit_settle
#
# 【この節が守る仕様】wire は ASCII に閉じる（XREV-ASCII-V1）。cmux 0.64.20 の受信側は
# 4095 バイトずつ read して各チャンクを独立に UTF-8 変換し、多バイト文字が境界で分断されると
# そのチャンクを丸ごと捨てるため、非ASCII を含む送信が間欠的に失われる。ASCII は各バイトが
# 単独で正しい UTF-8 なので影響を受けない。
#
# 可逆性の要は「XREVQ 列の復元を最長一致・左から右へ単一走査・出力を再走査しない」で行うこと。
# 単純な逆順 replace だと原文 XREVQnl（encode 後 XREVQXREVQnl）を復元できない。

export XREV_CONFIG="$DEFAULT_CONFIG"
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"

has_newline() { printf '%s' "$1" | python3 -c 'import sys;print("yes" if "\n" in sys.stdin.read() else "no")'; }
is_ascii()    { printf '%s' "$1" | python3 -c 'import sys;d=sys.stdin.buffer.read();print("yes" if all(0x20<=b<=0x7e for b in d) else "no")'; }

# 往復ヘルパ: encode → decode が元に戻ることを確認する
# 【注意】コマンド置換は末尾改行を削るため、番兵 X を付けてから剥がして比較する。
# これをしないと「末尾改行が保持されるか」を検証できない。
# ただし `cmd; printf X` にすると置換全体の終了ステータスが常に printf の成功になり失敗を見逃す。
# `cmd && printf X` にして「末尾に X が無い＝失敗」で判定する。
rt() { # $1=説明 $2=content_type $3=payload
  local line dec
  line="$(_build_framed_line "$2" "rT1" "$3" 2>/dev/null && printf X)"
  [[ "$line" == *X ]] || { fail "$1（encode 失敗）" "encode成功" "失敗"; return; }
  line="${line%X}"
  dec="$(XREV_DECODE_LINE="$line" _xrev_decode_line 2>/dev/null && printf X)"
  [[ "$dec" == *X ]] || { fail "$1（decode 失敗）" "decode成功" "失敗"; return; }
  dec="${dec%X}"
  assert_eq "$1" "$3" "$dec"
}

# ── wire 不変条件 ──────────────────────────────────────────────────────────
out="$(_build_framed_line plain rID1 "$(printf '行1\n行2')")"
assert_eq "1物理行（実改行を含まない）" "no" "$(has_newline "$out")"
assert_eq "全文字が印字可能 ASCII" "yes" "$(is_ascii "$out")"
assert_contains "round_id を含む" "$out" "round_id=rID1"
assert_contains "ENCODING で版を宣言する" "$out" "ENCODING=XREV-ASCII-V1"
assert_contains "長さ付きフィールドで領域を切り出せる" "$out" "LEN_INSTR="
assert_contains "末尾 END_ROUND マーカー" "$out" "END_ROUND_rID1"
assert_not_contains "非ASCII は wire に残らない" "$out" "行"

# ASCII-only なので文字数とバイト数が一致する（_check_paste_intact の照合前提）
assert_eq "文字数とバイト数が一致する" "${#out}" "$(printf '%s' "$out" | wc -c | tr -d ' ')"

# ── 往復（可逆性）──────────────────────────────────────────────────────────
rt "空本文" plain ""
rt "ASCII のみ" plain "hello world"
rt "日本語と改行" plain "$(printf '行1\n行2')"
rt "連続改行" plain "$(printf 'a\n\n\nb')"
# 末尾改行は command substitution が削るため $'...' で直に渡す（最終空行の保持を固定する）
_nl_body=$'a\n'
rt "末尾改行（最終空行を保持する）" plain "$_nl_body"
_nl_body=$'a\n\n'
rt "末尾に連続改行" plain "$_nl_body"
_nl_body=$'\n'
rt "改行のみ" plain "$_nl_body"
rt "実タブ" plain "$(printf 'x\ty')"
rt "実バックスラッシュ" plain 'a\nb'
rt "日本語（escape と紛れない）" plain 'あ'

# BMP 境界と非BMP
rt "U+007F" plain "$(python3 -c 'import sys;sys.stdout.write(chr(0x7F))')"
rt "U+0080" plain "$(python3 -c 'import sys;sys.stdout.write(chr(0x80))')"
rt "U+FFFF" plain "$(python3 -c 'import sys;sys.stdout.write(chr(0xFFFF))')"
rt "U+10000（非BMP）" plain "$(python3 -c 'import sys;sys.stdout.write(chr(0x10000))')"
rt "U+1F600（絵文字）" plain "😀"
rt "U+10FFFF（上限）" plain "$(python3 -c 'import sys;sys.stdout.write(chr(0x10FFFF))')"

# 制御トークンのリテラル出現（単純な逆順 replace だと壊れる系）
rt "リテラル <XREV-NL>" plain "<XREV-NL>"
rt "リテラル <XREV-BS>" plain "<XREV-BS>"
rt "リテラル <XREV-TAB>" plain "<XREV-TAB>"
rt "リテラル END_ROUND_" plain "END_ROUND_x"
rt "リテラル || L0001:" plain "|| L0001: x"
rt "リテラル XREVQ" plain "XREVQ"
rt "XREVQnl（導入子の前方一致）" plain "XREVQnl"
rt "XREVQXREVQnl" plain "XREVQXREVQnl"
rt "XREVQ の連続" plain "XREVQXREVQXREVQ"
rt "全制御トークンの隣接列" plain "XREVQ<XREV-NL><XREV-BS><XREV-TAB>END_ROUND_|| LXREVQnl"
rt "<XREV-NL>XREVQnl" plain "<XREV-NL>XREVQnl"

# 説明文や本文中の偽マーカーを構造として解釈しない
rt "本文中の偽 PAYLOAD マーカー" plain "PAYLOAD_FRAMED content_type=x lines=9 || L0001: にせ"
rt "本文中の偽 END マーカー" plain "END_ROUND_rT1 の直後に続く文"

# ── framed（番号付き line framing）──────────────────────────────────────────
out="$(_build_framed_line unified_diff rDF "$(printf '@@ -1 +1 @@\n-old\n+    new')")"
assert_eq "framed も1物理行" "no" "$(has_newline "$out")"
assert_eq "framed も ASCII のみ" "yes" "$(is_ascii "$out")"
assert_contains "PAYLOAD_FRAMED と lines 数" "$out" "PAYLOAD_FRAMED content_type=unified_diff lines=3"
assert_contains "行境界 L0001" "$out" "|| L0001: @@ -1 +1 @@"
rt "framed の往復（行頭の +/- とインデント保持）" unified_diff "$(printf '@@ -1 +1 @@\n-old\n+    new')"
rt "framed + 日本語 + タブ" unified_diff "$(printf '日本語\n2行目\tタブ')"
rt "framed + 空行を含む" unified_diff "$(printf 'a\n\nb')"
_nl_body=$'a\nb\n'
rt "framed + 末尾改行" unified_diff "$_nl_body"

# 行番号の検証（欠番・重複・順序変更・桁あふれを検出する）
_f="$(_build_framed_line unified_diff rSEQ "$(printf 'a\nb\nc')")"
XREV_DECODE_LINE="${_f/|| L0002: /|| L0003: }" _xrev_decode_line >/dev/null 2>&1
assert_rc "行番号の重複 → decode 拒否" 1 "$?"
XREV_DECODE_LINE="${_f/|| L0002: /|| L0009: }" _xrev_decode_line >/dev/null 2>&1
assert_rc "行番号の飛び → decode 拒否" 1 "$?"
# 10000 行以上でも往復できる（encoder の %04d は5桁になるので decoder が受理する必要がある）
_big="$(python3 -c 'import sys;sys.stdout.write("\n".join("L%d" % i for i in range(1, 10002)))')"
rt "10001行（行番号が5桁になる）" unified_diff "$_big"
unset _f _big

# ── 異常系（fail closed）────────────────────────────────────────────────────
_build_framed_line plain "bad id" "x" >/dev/null 2>&1
assert_rc "round_id に空白 → encode 拒否" 1 "$?"
_build_framed_line "bad type" rX "x" >/dev/null 2>&1
assert_rc "content_type に空白 → encode 拒否" 1 "$?"

_line="$(_build_framed_line plain rOK "test")"
XREV_DECODE_LINE="${_line/ENCODING=XREV-ASCII-V1/ENCODING=XREV-ASCII-V9}" _xrev_decode_line >/dev/null 2>&1
assert_rc "未知の encoding 版 → decode 拒否" 1 "$?"
XREV_DECODE_LINE="${_line}余分" _xrev_decode_line >/dev/null 2>&1
assert_rc "末尾マーカー不一致 → decode 拒否" 1 "$?"
XREV_DECODE_LINE="${_line:0:${#_line}-5}" _xrev_decode_line >/dev/null 2>&1
assert_rc "切り詰められた wire → decode 拒否" 1 "$?"
XREV_DECODE_LINE='XREV_REVIEW round_id=rX ENCODING=XREV-ASCII-V1 LEN_INSTR=1 LEN_OUT=1 LEN_PAYLOAD=1 :: h :: abc :: END_ROUND_rX' \
  _xrev_decode_line >/dev/null 2>&1
assert_rc "PAYLOAD マーカーが無い → decode 拒否" 1 "$?"

# 孤立サロゲート・不正 escape は拒否する（リテラル維持にしない）。
# 【重要】異常文字列は payload フィールドの**内側**へ入れ、LEN_PAYLOAD も併せて増やす。
# 末尾マーカーの直前へ足すと、Unicode 復号へ到達する前に「末尾マーカー不一致」で弾かれてしまい、
# unesc の各拒否分岐を検証できない（テスト名だけが通る状態になる）。
# $2 は wire へそのまま挿入する文字列。escape 列を試すときは '\\u007C' のように
# バックスラッシュ込みで渡す（リテラル文字を渡しても escape の検証にならない）。
_mk_bad() { python3 -c "
import re, sys
base, bad = sys.argv[1], sys.argv[2]
m = re.match(r'^(.*LEN_PAYLOAD=)(\d+)( :: .*)\$', base, re.S)
head, ln, rest = m.group(1), int(m.group(2)), m.group(3)
i = rest.index(' :: END_ROUND_')
sys.stdout.write(head + str(ln + len(bad)) + rest[:i] + bad + rest[i:])" "$1" "$2"; }
# 仕込みが payload 領域へ届いていること自体を確認する（届かないとテストが無意味になる）
_probe="$(XREV_DECODE_LINE="$(_mk_bad "$_line" 'ZZ')" _xrev_decode_line 2>/dev/null)"
assert_contains "異常系の仕込みが payload 領域へ届く" "$_probe" "ZZ"
XREV_DECODE_LINE="$(_mk_bad "$_line" '\uD800')" _xrev_decode_line >/dev/null 2>&1
assert_rc "孤立 high surrogate → decode 拒否" 1 "$?"
XREV_DECODE_LINE="$(_mk_bad "$_line" '\uDC00')" _xrev_decode_line >/dev/null 2>&1
assert_rc "孤立 low surrogate → decode 拒否" 1 "$?"
XREV_DECODE_LINE="$(_mk_bad "$_line" '\u12')" _xrev_decode_line >/dev/null 2>&1
assert_rc "桁不足の \\u 列 → decode 拒否" 1 "$?"
XREV_DECODE_LINE="$(_mk_bad "$_line" '\uZZZZ')" _xrev_decode_line >/dev/null 2>&1
assert_rc "非16進の \\u 列 → decode 拒否" 1 "$?"
XREV_DECODE_LINE="$(_mk_bad "$_line" '\n')" _xrev_decode_line >/dev/null 2>&1
assert_rc "\\u 以外のバックスラッシュ → decode 拒否" 1 "$?"
# 印字可能 ASCII の escape は encoder が出さない。受理すると復号後に構造トークンを合成できる。
XREV_DECODE_LINE="$(_mk_bad "$_line" '\u007C')" _xrev_decode_line >/dev/null 2>&1
assert_rc "印字可能 ASCII の escape（\\u007C='|'）→ decode 拒否" 1 "$?"
XREV_DECODE_LINE="$(_mk_bad "$_line" '\u0020')" _xrev_decode_line >/dev/null 2>&1
assert_rc "空白の escape（\\u0020）→ decode 拒否" 1 "$?"
# 行番号は canonical 表現のみ受理する（余分な先頭ゼロを拒否）。framed の wire で確認する。
_fseq="$(_build_framed_line unified_diff rSEQ2 "$(printf 'a\nb')")"
XREV_DECODE_LINE="${_fseq/|| L0001: /|| L00001: }" _xrev_decode_line >/dev/null 2>&1
assert_rc "行番号の非 canonical 表現（L00001）→ decode 拒否" 1 "$?"
unset _fseq

# ── property test（ランダム生成の往復）──────────────────────────────────────
# サロゲートコードポイントは入力として認めない仕様なので生成対象から外す。
_pt_fails=0
for _i in $(seq 1 40); do
  _body="$(XREV_SEED=$_i python3 -c '
import os, random, sys
random.seed(int(os.environ["XREV_SEED"]))
toks = ["XREVQ", "XREVQnl", "XREVQXREVQ", "<XREV-NL>", "<XREV-BS>", "<XREV-TAB>",
        "END_ROUND_", "|| L", chr(92), chr(9), chr(10), "あ", "😀", "a", " ", "PAYLOAD_PLAIN"]
sys.stdout.write("".join(random.choice(toks) for _ in range(random.randint(0, 60))))')"
  _ct=$([[ $((_i % 2)) -eq 0 ]] && echo plain || echo unified_diff)
  _l="$(_build_framed_line "$_ct" "rP$_i" "$_body" 2>/dev/null)" || { _pt_fails=$((_pt_fails + 1)); continue; }
  _d="$(XREV_DECODE_LINE="$_l" _xrev_decode_line 2>/dev/null)" || { _pt_fails=$((_pt_fails + 1)); continue; }
  [[ "$_d" == "$_body" ]] || _pt_fails=$((_pt_fails + 1))
  [[ "$(is_ascii "$_l")" == "yes" ]] || _pt_fails=$((_pt_fails + 1))
done
assert_eq "property test 40件がすべて往復一致かつ ASCII-only" "0" "$_pt_fails"

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

unset _line _pt_fails _i _body _ct _l _d
unset -f rt has_newline is_ascii _mk_bad
