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
# ROOT は通常リポジトリルート。テストでは XREV_STOP_ROOT で差し替え可能（変更検知を決定論化）。
ROOT="${XREV_STOP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}"

stop_active="$(printf '%s' "$event" | python3 -c 'import json,sys
try: print(str(json.load(sys.stdin).get("stop_hook_active",False)).lower())
except Exception: print("false")' 2>/dev/null)"

# 監視対象パスに変更があるか（修正・ステージ・新規 untracked をすべて含む）
if ! cd "$ROOT" 2>/dev/null; then
  # cd 失敗 = XREV_STOP_ROOT（または算出した ROOT）が不正で検証できない
  if [ "$stop_active" = "true" ]; then
    printf '[xrev] XREV_STOP_ROOT が不正で検証できません（%s）。ループ防止のため続行します。\n' "$ROOT" >&2
    exit 0
  fi
  printf '[xrev] XREV_STOP_ROOT が不正で検証できません（%s）。終了前に修正してください。\n' "$ROOT" >&2
  exit 2
fi
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  changes="$(git status --porcelain -- scripts hooks tests tools config 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    # git status 自体が失敗 = 変更の有無を確認できない（「変更なし」とは区別する）
    if [ "$stop_active" = "true" ]; then
      printf '[xrev] git status に失敗し変更有無を確認できませんでした。ループ防止のため続行します。\n' >&2
      exit 0
    fi
    printf '[xrev] git status に失敗し変更有無を確認できませんでした。手動で bash tools/verify.sh を実行してください。\n' >&2
    exit 2
  fi
  [ -z "$changes" ] && exit 0   # コード変更なし（git status 成功で出力空） → 何もしない
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
