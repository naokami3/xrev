#!/usr/bin/env bash
#
# test_send_diag.sh — 送信失敗時の診断ログが payload を漏らさないことを検証する（変更2の担当）。
#
# 変更1（プロセス証明の3段ゲート）のテストは test_send_gates.sh にある。
# 論理変更ごとにファイルを分けておく（1コミット=1論理変更の境界をテストでも保つため）。
#
# cmux 非依存: _xrev_redact_diag は純粋関数（env 入力・stdout 出力）なのでそのまま呼べる。

export XREV_CONFIG="$DEFAULT_CONFIG"
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"

# ── _xrev_redact_diag（送信失敗時の診断ログ。payload を漏らさない）────────────────
# レビュー payload には未公開のコード・差分が入る。cmux は実際に
# `Unknown command '<送信テキストの一部>'` の形で入力をエコーするため、そのまま出すと本文が漏れる。
#
# 【固定する仕様】「本文と一致しないから安全」という推定を使わない。実測済みの既知形式に**完全一致**
# したときだけ構造化した安全表現を出し、外れたものは既定で全体を伏せる（fail closed）。
# 推測で allowlist を広げないため、接頭辞・接尾辞・引用構造が少しでも違えば未知扱いになることも固定する。
_rd() { printf '%s' "$2" | XREV_DIAG_ERR="$1" _xrev_redact_diag; }
_KNOWN="Error: ERROR: Unknown command ':'. Use 'help' for available commands."

assert_eq "stderr が空なら明示する" "(stderr は空)" "$(_rd "" "本文")"

# 既知形式1: Unknown command → 種別は残し、断片は構造化して伏せる。
_out="$(_rd "$_KNOWN" "本文")"
assert_contains "既知形式はエラー種別を残す" "$_out" "Unknown command"
assert_not_contains "既知形式でも断片の中身は出さない" "$_out" "':'"
assert_contains "断片は文字数で記述する" "$_out" "payload断片 1文字"

# 既知形式2: timeout は payload を含まない定型なのでそのまま読める。
assert_eq "timeout はそのまま出す" \
  "Error: Command timed out" "$(_rd "Error: Command timed out" "本文")"

# 未知形式は内容を一切出さない（長さ・引用符有無・ASCII純度のみ）。
_out="$(_rd "cmux: send failed" "秘密の差分本文")"
assert_contains "未知形式は全体を秘匿する" "$_out" "未知形式"
assert_not_contains "未知形式は内容を出さない" "$_out" "send failed"

# 既知形式に似ていても完全一致でなければ未知扱い（推測で allowlist を広げない）。
assert_contains "接尾辞が違えば未知扱い" \
  "$(_rd "Error: ERROR: Unknown command ':'." "本文")" "未知形式"
assert_contains "接頭辞が付けば未知扱い" \
  "$(_rd "WARN $_KNOWN" "本文")" "未知形式"
assert_contains "timeout も完全一致でなければ未知扱い" \
  "$(_rd "Error: Command timed out (retrying)" "本文")" "未知形式"

# 引用構造の異常（閉じ忘れ・空引用・両種混在）はすべて未知扱いで伏せる。
assert_contains "閉じ引用符の欠落は未知扱い" \
  "$(_rd "Error: ERROR: Unknown command 'abc" "prefix abc suffix")" "未知形式"
assert_not_contains "閉じ忘れ時も断片を出さない" \
  "$(_rd "Error: ERROR: Unknown command 'abc" "prefix abc suffix")" "abc"
assert_contains "二重引用符の未知形式も伏せる" \
  "$(_rd 'Unknown command "tok123"' "prefix tok123 suffix")" "未知形式"
assert_not_contains "二重引用符の断片を出さない" \
  "$(_rd 'Unknown command "tok123"' "prefix tok123 suffix")" "tok123"

# 断片自身が引用符を含む場合も、後置アンカーの貪欲マッチで正しく切り出して伏せる。
_out="$(_rd "Error: ERROR: Unknown command 'a'b'. Use 'help' for available commands." "x a'b y")"
assert_contains "断片が引用符を含んでも既知形式として扱う" "$_out" "Unknown command"
assert_not_contains "引用符入り断片の中身は出さない" "$_out" "a'b"

# 位置情報は補助情報。一意なときだけ byte offset、複数なら件数、無ければ存在しない旨。
_out="$(_rd "Error: ERROR: Unknown command 'X'. Use 'help' for available commands." "あいうX")"
assert_contains "一意な断片は byte offset を添える（補助情報）" "$_out" "byte offset 9"
_out="$(_rd "$_KNOWN" "a:b:c:d")"
assert_contains "複数出現する断片は位置を報告しない" "$_out" "位置は特定不能"
assert_not_contains "複数出現時に byte offset を出さない" "$_out" "byte offset"
_out="$(_rd "$_KNOWN" "コロンを含まない本文")"
assert_contains "本文に無い断片は payload 由来と断定しない" "$_out" "本文中に存在しない"

# 制御文字・改行はログ偽装に使えるため潰す（未知扱いになっても中身は出ない）。
assert_not_contains "改行を含む stderr の中身は出さない" \
  "$(_rd $'line1\nline2\ttab' "")" "line2"

# 【分類の厳密性】畳み込みで既知形式に化ける偽装を、既知エラーとして分類しない。
# 改行を挟んだだけの文字列は正規化すると既知形式に一致してしまうため、元の改行有無で弾く。
_spoof=$'Error: ERROR: Unknown command\n\':\'. Use \'help\' for available commands.'
_out="$(_rd "$_spoof" "本文")"
assert_contains "改行で偽装された既知形式は未知扱いにする" "$_out" "改行/タブを含む"
assert_not_contains "偽装時に既知形式として分類しない" "$_out" "help 案内は省略"
assert_contains "タブを含む場合も未知扱い" \
  "$(_rd $'Error: Command timed\tout' "本文")" "改行/タブを含む"

# 巨大な stderr は正規化の前に打ち切り、未知形式として伏せる（payload を表示しない）。
_out="$(_rd "$(python3 -c 'print("z"*9000)')" "zzzzzzzzzzzzzzzzzzzz")"
assert_contains "巨大な stderr は長すぎるとして秘匿する" "$_out" "長すぎます"
assert_not_contains "巨大な stderr の中身は出さない" "$_out" "zzzzzzzzzz"
assert_contains "未知形式の長さは raw で報告する" "$_out" "長さ=9000(raw)"

unset _rd _out _KNOWN
