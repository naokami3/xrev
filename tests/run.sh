#!/usr/bin/env bash
#
# run.sh — xrev の全テストを実行するランナー。
#
#   使い方:
#     tests/run.sh            # 全 test_*.sh を実行
#     tests/run.sh parse scan # 名前に parse / scan を含むものだけ実行
#
#   依存は bash + python3 のみ（cmux 不要。cmux 配管の純粋ロジック部だけを検証する）。
#   失敗が 1 件でもあれば非ゼロで終了する（CI で使える）。
#
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

filters=("$@")
matches() {
  [[ ${#filters[@]} -eq 0 ]] && return 0
  local f
  for f in "${filters[@]}"; do [[ "$1" == *"$f"* ]] && return 0; done
  return 1
}

shopt -s nullglob
for t in "$DIR"/test_*.sh; do
  name="$(basename "$t")"
  matches "$name" || continue
  section "$name"
  # shellcheck source=/dev/null
  source "$t"
done

finish
