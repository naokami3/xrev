#!/usr/bin/env bash
#
# lib.sh — xrev 用の最小テストヘルパ（外部依存なし・bash + python3 のみ）。
#
# run.sh から source され、各 test_*.sh からアサート関数を使う。
# 集計用カウンタ PASS/FAIL を共有する。
#
# 提供する関数:
#   section <名前>                  … テストグループの見出し
#   assert_eq   <説明> <期待> <実際>
#   assert_rc   <説明> <期待rc> <実際rc>
#   assert_contains <説明> <文字列> <含むべき部分>
#   assert_not_contains <説明> <文字列> <含まないべき部分>
#   json_get <キー>                 … stdin の JSON からトップレベル値を取り出す
#   finish                          … 集計を出力し、失敗が無ければ 0、あれば 1 で返る

: "${PASS:=0}"
: "${FAIL:=0}"

# リポジトリのパス
XREV_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
XREV_ROOT="$(cd "$XREV_TESTS_DIR/.." && pwd)"
SCRIPTS="$XREV_ROOT/scripts"
HOOKS="$XREV_ROOT/hooks"
DEFAULT_CONFIG="$XREV_ROOT/config/xrev.default.json"

_c_green=$'\033[32m'; _c_red=$'\033[31m'; _c_dim=$'\033[2m'; _c_off=$'\033[0m'

section() { printf '\n%s── %s%s\n' "$_c_dim" "$1" "$_c_off"; }

pass() { PASS=$((PASS + 1)); printf '  %sok%s   %s\n' "$_c_green" "$_c_off" "$1"; }
fail() {
  FAIL=$((FAIL + 1))
  printf '  %sNG%s   %s\n' "$_c_red" "$_c_off" "$1"
  printf '        期待=[%s]\n        実際=[%s]\n' "$2" "$3"
}

assert_eq() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1" "$2" "$3"; }
assert_rc() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1" "rc=$2" "rc=$3"; }
assert_contains() { [[ "$2" == *"$3"* ]] && pass "$1" || fail "$1" "（…を含む）$3" "$2"; }
assert_not_contains() { [[ "$2" != *"$3"* ]] && pass "$1" || fail "$1" "（…を含まない）$3" "$2"; }

json_get() {
  python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    v=d.get(sys.argv[1],"")
    print(v if not isinstance(v,(dict,list)) else json.dumps(v))
except Exception:
    print("")' "$1"
}

finish() {
  printf '\n==== %d passed, %d failed ====\n' "$PASS" "$FAIL"
  [[ "$FAIL" -eq 0 ]]
}
