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
import json, os, re, sys

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


def strip_noise(text: str) -> str:
    """誤発火の温床（コードブロック・インラインコード・引用・diff）を除去する。

    stdin から prompt、引数から keyword を受けて真偽を返す純粋関数
    (is_triggered) から呼ばれる下請け。ここで除去した残りのテキストにのみ
    キーワード境界照合をかける。
    """
    lines = text.split("\n")
    kept = []
    in_fence = False
    fence_marker = None
    for line in lines:
        stripped = line.lstrip()
        if in_fence:
            if stripped.startswith(fence_marker):
                # 閉じ fence 行。閉じが無ければ末尾まで in_fence のまま破棄され続ける。
                in_fence = False
                fence_marker = None
            continue
        if stripped.startswith("```") or stripped.startswith("~~~"):
            in_fence = True
            fence_marker = stripped[:3]
            continue
        kept.append(line)

    # 同一行内の `...`（インラインコード）を除去する。
    kept = [re.sub(r"`[^`\n]*`", "", line) for line in kept]

    # 引用行（行頭 >）を除去する。
    kept = [line for line in kept if not line.lstrip().startswith(">")]

    # diff 由来行を除去する。
    diff_prefixes = ("diff --git", "@@ ", "+++ ", "--- ", "index ")
    kept = [line for line in kept if not line.lstrip().startswith(diff_prefixes)]

    return "\n".join(kept)


def is_triggered(text: str, kw: str) -> bool:
    """prompt と keyword を受け、境界付きでキーワードが発火するかを返す純粋関数。"""
    if not kw:
        return False
    cleaned = strip_noise(text)
    # 直前が英数字/_/@/./- なら不一致（"foo@xrev" 等の部分一致を除外）。
    # 直後が英数字/_/- なら不一致（"@xrevfoo" 等を除外。日本語等はそのまま発火）。
    pattern = re.compile(
        r"(?<![A-Za-z0-9_@.\-])" + re.escape(kw) + r"(?![A-Za-z0-9_\-])"
    )
    return pattern.search(cleaned) is not None


# キーワード非検知 → 完全沈黙（何も出力せず終了）。
if not is_triggered(prompt, keyword):
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
