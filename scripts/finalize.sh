#!/usr/bin/env bash
#
# finalize.sh — 到達点分岐: review / commit / pr
#
# 【役割分担】
#   「何をステージするか」「コミットメッセージ」「PR の本文」は論理判断であり Claude が決める。
#   本スクリプトはその決定を受けて git/gh を機械実行するだけ。
#
# 【設計上の不変条件】
#   - 既定到達点は review（最も安全）。明示指定が無ければ何も書き換えない。
#   - PR は必ず --draft。非ドラフト PR を作る経路を持たない（設計1.7／人間が最終確認）。
#   - コミット境界は「1コミット=1論理変更」。レビュー指摘の修正は元の変更にまとめる。
#     （ステージ操作は Claude が SKILL.md の境界ルールに従って事前に行う前提）
#
#   使い方:
#     finalize.sh review
#     finalize.sh commit "<commit message>"
#     finalize.sh pr "<pr title>" "<pr body>"  [base_branch]
#
set -uo pipefail

_die() { printf '[xrev/finalize] %s\n' "$*" >&2; exit 1; }

_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" && pwd; }
: "${XREV_CONFIG:=${CLAUDE_PLUGIN_ROOT:-$(_dir)/..}/config/xrev.default.json}"

# config から stop_at の既定を読む（jq 非依存）。
_cfg_stop_at() {
  python3 - "$XREV_CONFIG" <<'PY' 2>/dev/null || printf 'review'
import json, sys
try:
    with open(sys.argv[1]) as f:
        print(json.load(f).get("stop_at", "review"))
except Exception:
    print("review")
PY
}

# 到達点の解決（優先順位 高→低）:
#   1) 引数 $1（その場指定。依頼文 / /xrev 引数 / 一拍確認の回答を Claude が渡す）
#   2) 環境変数 XREV_STOP_AT（シェル/プロジェクト単位の既定上書き）
#   3) config の stop_at（プロジェクト全体の既定）
#   4) 最終フォールバック review（最も安全）
MODE="${1:-}"
[[ -n "$MODE" ]] || MODE="${XREV_STOP_AT:-}"
[[ -n "$MODE" ]] || MODE="$(_cfg_stop_at)"
[[ -n "$MODE" ]] || MODE="review"

case "$MODE" in
  review)
    echo "[xrev/finalize] stop_at=review: リポジトリは書き換えません（コミットしない）。"
    echo "レビューは approve で収束しました。コミット/PR が必要なら stop_at を commit/pr で再実行してください。"
    ;;

  commit)
    MSG="${2:-}"
    [[ -n "$MSG" ]] || _die "commit にはコミットメッセージが必要です。"
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || _die "git リポジトリ内ではありません。"
    # ステージ済みの変更があることを確認（境界ルールに沿って Claude が git add 済みの想定）。
    if git diff --cached --quiet; then
      _die "ステージされた変更がありません。境界ルールに従って必要な変更を git add してから実行してください。"
    fi
    git commit -m "$MSG" || _die "コミットに失敗しました。"
    echo "[xrev/finalize] コミットしました: $(git rev-parse --short HEAD)"
    ;;

  pr)
    TITLE="${2:-}"
    BODY="${3:-}"
    BASE="${4:-}"
    [[ -n "$TITLE" ]] || _die "pr には PR タイトルが必要です。"
    command -v gh >/dev/null 2>&1 || _die "gh CLI が見つかりません。GitHub CLI を導入してください。"
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || _die "git リポジトリ内ではありません。"

    BRANCH="$(git rev-parse --abbrev-ref HEAD)"
    DEFAULT_BRANCH="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
    DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
    [[ -z "$BASE" ]] && BASE="$DEFAULT_BRANCH"

    if [[ "$BRANCH" == "$BASE" ]]; then
      _die "現在のブランチ($BRANCH)が base($BASE)と同一です。作業ブランチを切ってから実行してください。"
    fi

    # リモートへ push（未設定なら upstream を張る）。
    if ! git push -u origin "$BRANCH" 2>/dev/null; then
      git push origin "$BRANCH" || _die "push に失敗しました。"
    fi

    # 必ずドラフトで作成。--draft は固定。人間がマージ/Ready 化の最終トリガを引く。
    gh pr create --draft --base "$BASE" --head "$BRANCH" \
      --title "$TITLE" --body "${BODY:-（本文未設定）}" \
      || _die "ドラフト PR の作成に失敗しました。"
    echo "[xrev/finalize] ドラフト PR を作成しました（base: $BASE / head: $BRANCH）。"
    echo "人間が内容を確認し、Ready for review / マージの最終トリガを引いてください。"
    ;;

  *)
    _die "未知の stop_at: '$MODE'（review / commit / pr のいずれか）"
    ;;
esac
