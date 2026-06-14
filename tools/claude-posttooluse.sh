#!/usr/bin/env bash
#
# claude-posttooluse.sh — Claude Code の PostToolUse(Edit|Write|MultiEdit) フック。
#
#   編集対象が scripts/ hooks/ tests/ tools/ 配下の .sh なら bash -n で構文チェック、
#   config/ ・ .claude-plugin/ ・ hooks/ 配下の .json なら JSON 妥当性をチェックする。
#   失敗なら exit 2 で Claude に差し戻す（即時フィードバック）。それ以外は exit 0。
#
#   stdin: フックイベント JSON（.tool_input.file_path を読む）。
#
set -uo pipefail

event="$(cat)"
fp="$(printf '%s' "$event" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get("tool_input",{}).get("file_path",""))
except Exception:
    print("")' 2>/dev/null)"

[ -n "$fp" ] || exit 0
[ -f "$fp" ] || exit 0

case "$fp" in
  */scripts/*.sh|*/hooks/*.sh|*/tests/*.sh|*/tools/*.sh)
    if ! err="$(bash -n "$fp" 2>&1)"; then
      printf '[xrev] 構文エラーを検知しました（%s）。修正してください:\n%s\n' "$fp" "$err" >&2
      exit 2
    fi
    ;;
  */config/*.json|*/.claude-plugin/*.json|*/hooks/*.json|*/references/*.json|*/.claude/*.json)
    if ! err="$(python3 -m json.tool "$fp" 2>&1 >/dev/null)"; then
      printf '[xrev] JSON が不正です（%s）。修正してください:\n%s\n' "$fp" "$err" >&2
      exit 2
    fi
    ;;
esac

exit 0
