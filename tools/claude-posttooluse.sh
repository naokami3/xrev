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
#   前提: python3 が無い場合、またはイベント JSON の parse 自体が失敗する場合は
#   「検証できない」ことを exit 2 で明示する（fail-open で黙って検証をスキップしない）。
#   一方、JSON の parse には成功したが file_path が無い/空（対象外ツールの呼び出し）は
#   従来どおり exit 0（素通し）。
#
set -uo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  printf '[xrev] python3 が見つからないため編集ファイルの検証ができません。\n' >&2
  exit 2
fi

event="$(cat)"
# parse 失敗（入力契約破壊）と file_path 欠如（対象外ツール）を区別するため、
# parse 失敗時だけ専用マーカーを出力する。
fp="$(printf '%s' "$event" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print("__XREV_PARSE_ERROR__")
    sys.exit(0)
print(d.get("tool_input",{}).get("file_path","") or "")')"
rc=$?

if [ "$rc" -ne 0 ] || [ "$fp" = "__XREV_PARSE_ERROR__" ]; then
  printf '[xrev] イベントJSONの解析に失敗しました。Claude Code の入力仕様が変わっている可能性があります。\n' >&2
  exit 2
fi

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
