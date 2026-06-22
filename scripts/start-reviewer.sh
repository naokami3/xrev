#!/usr/bin/env bash
#
# start-reviewer.sh — reviewer(Codex)を「実ターミナル内の codex CLI」として規約タイトルで起動する
# ヘルパ（目標C: 使い方によらず手間なく reviewer を用意する）。
#
# 【使い方】reviewer 用に開いた cmux の**実ターミナルペインの中**で実行する:
#     scripts/start-reviewer.sh [codex への引数...]
#
# 【動作】
#   1) 自分のタブのタイトルを reviewer_pane_title（既定 "Review Codex"）に設定する。
#      cmux 依存は transport.sh に閉じるため、本ヘルパは直接 cmux を叩かず transport.sh の set-title を使う。
#   2) codex を exec で起動する（このシェルを codex に置き換える＝サーフェス直下プロセスが codex 単独になり、
#      Phase1 の宛先解決＋送信ゲート（同一WS・実tty・直下=codex のプロセス証明）が確実に通る）。
#
# 【なぜ「実ターミナル内」か】cmux のエージェント統合パネル（--type agent-session）は xrev の宛先解決の
#   契約外。必ず通常のシェル端末で起動すること。
#
# 【ensure-reviewer との関係】これは「ユーザーが既に開いた端末をその場で reviewer にする」手動経路。
#   primary が自分のWSにペインを新規生成する自動経路は `transport.sh ensure-reviewer`。タイトル・codex バイナリ
#   解決は transport.sh の同じ設定（REVIEWER_PANE_TITLE / XREV_CODEX_BIN）を共有し、仕様の乖離を避ける。
#
set -uo pipefail

_dir() { cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd; }
DIR="$(_dir)"
: "${XREV_CONFIG:=${CLAUDE_PLUGIN_ROOT:-$DIR/..}/config/xrev.default.json}"
export XREV_CONFIG

# REVIEWER_PANE_TITLE / cmux ラッパ / preflight を再利用（source 時は self-test を走らせない）。
# shellcheck source=transport.sh
source "$DIR/transport.sh"

_cmux_preflight || {
  echo "[start-reviewer] cmux に接続できません。reviewer 用の cmux ペイン内で実行してください。" >&2
  exit 31
}

# codex の実行可能性は「タイトル変更より前」に確認する。
# そうしないと codex 未導入時に、素の shell に規約タイトルだけが残り、後続の宛先解決を誤らせる。
codex_bin="${XREV_CODEX_BIN:-codex}"
if ! command -v "$codex_bin" >/dev/null 2>&1; then
  echo "[start-reviewer] '$codex_bin' が見つかりません（XREV_CODEX_BIN で明示指定できます）。タイトルは変更していません。" >&2
  exit 127
fi

if ! _cmux_set_title "$REVIEWER_PANE_TITLE"; then
  echo "[start-reviewer] タブタイトルの設定に失敗しました（rename-tab 不可）。" >&2
  exit 1
fi
echo "[start-reviewer] タブを '$REVIEWER_PANE_TITLE' に設定しました。codex を起動します…" >&2

# exec で置き換える＝サーフェス直下プロセスが codex 単独になる（プロセス証明ゲートの前提）。
# 万一 exec に失敗した場合は、規約タイトルのまま codex でない状態が残るため復旧手順を明示する。
exec "$codex_bin" "$@"
echo "[start-reviewer] codex の起動(exec)に失敗しました。タブ名が '$REVIEWER_PANE_TITLE' のまま残っています。" >&2
echo "[start-reviewer] このタブで手動で codex を起動するか、タブを閉じて開き直してください。" >&2
exit 126
