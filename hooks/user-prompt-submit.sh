#!/usr/bin/env bash
#
# user-prompt-submit.sh — UserPromptSubmit フック
#
# 役割（設計1.8）:
#   ユーザーの依頼文にキーワード（既定 @xrev）が含まれるときだけ、
#   「このタスクは設計段階から Codex クロスレビューを回す」という指示を
#   Claude のコンテキストへ決定論的に注入する。
#   キーワードが無ければ完全に沈黙する（無出力 / 暴発させない）。
#
#   このフックはあくまで「指示の注入」担当。実際にレビューを回すタイミングの判断は
#   スキル(Claude)が担う（設計が一区切りした点はライフサイクルイベントに対応しないため）。
#
# 入出力仕様:
#   stdin  … UserPromptSubmit イベント JSON（.prompt にユーザー入力）
#   stdout … キーワード検知時のみ、additionalContext を含む JSON を出力（exit 0）
#            非検知時は何も出力しない（exit 0）
#
set -uo pipefail

# 設定（キーワード）を読む。CLAUDE_PLUGIN_ROOT があればそれ基準、無ければ相対。
_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" && pwd; }
CONFIG="${XREV_CONFIG:-${CLAUDE_PLUGIN_ROOT:-$(_dir)/..}/config/xrev.default.json}"

EVENT_JSON="$(cat)"

# python3 で prompt 抽出とキーワード判定を行う（jq 非依存）。
# キーワード一致時のみ additionalContext 入りの JSON を stdout に出す。
XREV_EVENT="$EVENT_JSON" python3 - "$CONFIG" <<'PY'
import json, os, sys

config_path = sys.argv[1]
try:
    with open(config_path) as f:
        keyword = json.load(f).get("keyword", "@xrev")
except Exception:
    keyword = "@xrev"

try:
    event = json.loads(os.environ.get("XREV_EVENT", "") or "{}")
except Exception:
    event = {}

prompt = event.get("prompt", "") or ""

# キーワード非検知 → 完全沈黙（何も出力せず終了）。
if keyword not in prompt:
    sys.exit(0)

# 検知 → 設計段階からのクロスレビューを回す指示をコンテキスト注入。
context = (
    "【xrev 起動】ユーザーの依頼に '" + keyword + "' が含まれています。"
    "このタスクは設計段階から Codex とのクロスレビュー往復を回す対象です。\n"
    "次の手順を厳守してください:\n"
    "1. xrev スキルを使う。往復を即開始せず、まず到達点（review/commit/pr。既定は review）と "
    "ADR 生成の有無（既定 off）をユーザーに一拍確認する。\n"
    "2. 設計・実装プランの段階から reviewer(Codex) のレビューを回す（筋の悪いプランを実装前に潰す）。\n"
    "3. レビュー往復・終端判定・到達点処理はプラグイン同梱スクリプトに従う。"
    "中間ファイルは生成しない（ADR を除く）。\n"
    "4. PR を作る場合は必ずドラフト。マージ等の最終トリガは人間が引く。"
)

out = {
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": context,
    }
}
print(json.dumps(out, ensure_ascii=False))
sys.exit(0)
PY
