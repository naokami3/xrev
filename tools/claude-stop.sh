#!/usr/bin/env bash
#
# claude-stop.sh — Claude Code の Stop フック。
#
#   作業ツリーに scripts/ hooks/ tests/ tools/ config/ の変更があるときだけ、
#   共通ゲート tools/verify.sh（構文 + JSON + テスト）を実行する。失敗なら exit 2 で
#   Claude に「終わる前に直せ」と差し戻す。コード変更が無い会話ターンでは何もしない。
#
#   無限ループ防止: stop_hook_active が true（既に一度差し戻している）なら再ブロックせず、
#   警告だけ出して exit 0 する。
#
set -uo pipefail

event="$(cat)"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

stop_active="$(printf '%s' "$event" | python3 -c 'import json,sys
try: print(str(json.load(sys.stdin).get("stop_hook_active",False)).lower())
except Exception: print("false")' 2>/dev/null)"

# 監視対象パスに変更があるか（修正・ステージ・新規 untracked をすべて含む）
cd "$ROOT"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  changes="$(git status --porcelain -- scripts hooks tests tools config 2>/dev/null)"
  [ -z "$changes" ] && exit 0   # コード変更なし → 何もしない
fi

# 検証コマンドは XREV_VERIFY_CMD で差し替え可能（テストでスタブを注入するため）。
out="$(bash "${XREV_VERIFY_CMD:-$ROOT/tools/verify.sh}" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && exit 0

# テスト/検証が失敗
if [ "$stop_active" = "true" ]; then
  # 既に一度差し戻し済み → ループ防止のため警告のみ（ブロックしない）
  printf '{"systemMessage":"%s"}\n' "テストが未通過のまま終了します。bash tools/verify.sh で確認してください。"
  exit 0
fi

# 末尾だけ Claude に渡して差し戻す
printf '[xrev] コード変更がありますが検証(tools/verify.sh)が失敗しています。終了前に修正してください:\n%s\n' \
  "$(printf '%s' "$out" | tail -n 25)" >&2
exit 2
