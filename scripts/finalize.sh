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
#   pr の base ブランチ解決順（高→低）:
#     1) 引数 $4（その場指定）
#     2) origin/HEAD（git remote set-head origin -a 済みなら自動解決）
#     3) 環境変数 XREV_PR_BASE
#     4) config の pr_base キー
#     いずれも無ければ base を決め打ちせず失敗する（exit 7）。
#
#   【exit code 一覧】（_die の第2引数で指定。省略時は 1）
#     1 = その他の失敗（メッセージ/タイトル未指定、git リポジトリ外、branch==base 等）
#     2 = 前提コマンド不足（gh CLI が見つからない）
#     3 = detached HEAD（commit/pr へ進めない）
#     4 = ステージ済み変更なし（commit 経路）
#     5 = push 失敗（pr 経路）
#     6 = PR 作成失敗（push は完了済み。pr 経路）
#     7 = base ブランチを特定できない（pr 経路）
#
set -uo pipefail

# _die <メッセージ> [exit code（省略時 1）]
_die() {
  local msg="$1" code="${2:-1}"
  printf '[xrev/finalize] %s\n' "$msg" >&2
  exit "$code"
}

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

# config から pr_base を読む（キーが無ければ空文字。config/xrev.default.json に
# pr_base を追加する必要はない — 無ければ env(XREV_PR_BASE) のみで解決させる）。
_cfg_pr_base() {
  python3 - "$XREV_CONFIG" <<'PY' 2>/dev/null || printf ''
import json, sys
try:
    with open(sys.argv[1]) as f:
        print(json.load(f).get("pr_base", "") or "")
except Exception:
    print("")
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
    # detached HEAD ではブランチが無いため commit しても回収できない。
    git symbolic-ref -q HEAD >/dev/null || \
      _die "detached HEAD では commit/pr へ進めません。ブランチを作成してください。" 3
    # ステージ済みの変更があることを確認（境界ルールに沿って Claude が git add 済みの想定）。
    if git diff --cached --quiet; then
      _die "ステージされた変更がありません。境界ルールに従って必要な変更を git add してから実行してください。" 4
    fi
    git commit -m "$MSG" || _die "コミットに失敗しました。"
    echo "[xrev/finalize] コミットしました: $(git rev-parse --short HEAD)"
    ;;

  pr)
    TITLE="${2:-}"
    BODY="${3:-}"
    BASE="${4:-}"
    [[ -n "$TITLE" ]] || _die "pr には PR タイトルが必要です。"
    command -v gh >/dev/null 2>&1 || _die "gh CLI が見つかりません。GitHub CLI を導入してください。" 2
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || _die "git リポジトリ内ではありません。"
    # detached HEAD では PR の --head に "HEAD" のような無意味な文字列が渡ってしまう。
    git symbolic-ref -q HEAD >/dev/null || \
      _die "detached HEAD では commit/pr へ進めません。ブランチを作成してください。" 3

    BRANCH="$(git rev-parse --abbrev-ref HEAD)"

    # base の決定（引数 → origin/HEAD → XREV_PR_BASE → config.pr_base → 特定不能で失敗）。
    if [[ -z "$BASE" ]]; then
      BASE="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
    fi
    [[ -n "$BASE" ]] || BASE="${XREV_PR_BASE:-}"
    [[ -n "$BASE" ]] || BASE="$(_cfg_pr_base)"
    [[ -n "$BASE" ]] || _die "base ブランチを特定できません。git remote set-head origin -a を実行するか XREV_PR_BASE を指定してください。" 7

    if [[ "$BRANCH" == "$BASE" ]]; then
      _die "現在のブランチ($BRANCH)が base($BASE)と同一です。作業ブランチを切ってから実行してください。"
    fi

    # リモートへ push（未設定なら upstream を張る）。失敗時は両段の stderr を利用者に見せる
    # （旧実装は 1 回目を 2>/dev/null していたため、1 回目の失敗理由が隠れていた）。
    PUSH_ERR1="$(git push -u origin "$BRANCH" 2>&1)"; PUSH_RC1=$?
    if [[ $PUSH_RC1 -ne 0 ]]; then
      PUSH_ERR2="$(git push origin "$BRANCH" 2>&1)"; PUSH_RC2=$?
      if [[ $PUSH_RC2 -ne 0 ]]; then
        printf '%s\n' "$PUSH_ERR1" >&2
        printf '%s\n' "$PUSH_ERR2" >&2
        _die "push に失敗しました（上記のエラー出力を確認してください）。" 5
      fi
    fi

    # 必ずドラフトで作成。--draft は固定。人間がマージ/Ready 化の最終トリガを引く。
    PR_OUT="$(gh pr create --draft --base "$BASE" --head "$BRANCH" \
      --title "$TITLE" --body "${BODY:-（本文未設定）}" 2>&1)"
    PR_RC=$?
    if [[ $PR_RC -ne 0 ]]; then
      printf '%s\n' "$PR_OUT" >&2
      _die "gh pr create に失敗しました。push は完了済み・PR は未作成です。原因を解消のうえ、次を再実行してください: gh pr create --draft --base \"$BASE\" --head \"$BRANCH\" --title \"...\" --body \"...\"" 6
    fi
    [[ -z "$PR_OUT" ]] || echo "$PR_OUT"
    echo "[xrev/finalize] ドラフト PR を作成しました（base: ${BASE} / head: ${BRANCH}）。"
    echo "人間が内容を確認し、Ready for review / マージの最終トリガを引いてください。"
    ;;

  *)
    _die "未知の stop_at: '$MODE'（review / commit / pr のいずれか）"
    ;;
esac
