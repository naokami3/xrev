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

# ユーザー追加引数(「$@」)に sandbox/approval 系の上書きが無いか検証する。
# read-only は launch 引数（下）で機械強制するため、ユーザー引数による後置上書きを許すと無意味になる。
# transport.sh と同じ判定関数（_xrev_reject_unsafe_reviewer_args）を使い、判定リストを二重管理しない。
if ! _xrev_reject_unsafe_reviewer_args "$@"; then
  echo "[start-reviewer] 指定された引数に危険なフラグが含まれるため中止しました。タイトルは変更していません。" >&2
  exit 64
fi

# launch 引数（read-only 強制）を決定する。transport.sh の単一の生成関数
# （_xrev_reviewer_launch_args）を使い、自動生成経路(_xrev_create_reviewer)と実装を共有する。
# config/env が壊れている・未知の reviewer 名の場合は fail closed（exec せず中止）。
launch_args=()
if ! _xrev_launch_out="$(_xrev_reviewer_launch_args "$codex_bin")"; then
  echo "[start-reviewer] '$codex_bin' の launch 引数を決定できませんでした（config の reviewer_launch_args を確認してください）。タイトルは変更していません。" >&2
  exit 64
fi
while IFS= read -r _xrev_launch_line; do
  [[ -n "$_xrev_launch_line" ]] && launch_args+=("$_xrev_launch_line")
done <<< "$_xrev_launch_out"

# 【最終ゲート（指摘2への対処）】上の _xrev_reject_unsafe_reviewer_args は前方一致の拒否リストに
# すぎず、codex の短縮形 `-s`/結合形式 `-sdanger-full-access` 等の後置上書きを漏らしうる
# （拒否リストに `-s` を足しても、リスト方式である限り将来の新形式には追随できない）。正典の判定は
# 「launch 引数 + ユーザー追加引数」を連結した**最終 argv**に対する意味検証
# （_xrev_verify_effective_policy）であり、ここで安全ポリシー（sandbox=read-only かつ承認=never）が
# 一意に有効であることを確認してから exec する。
_xrev_codex_kind="$(basename -- "$codex_bin")"
if ! _xrev_verify_effective_policy "$_xrev_codex_kind" "${launch_args[@]+"${launch_args[@]}"}" "$@" >/dev/null 2>&1; then
  echo "[start-reviewer] 最終的な起動引数（launch 引数＋追加引数）が安全ポリシー（read-only 強制）を一意に満たしません。タイトルは変更していません。" >&2
  echo "[start-reviewer] sandbox/承認系フラグを追加していないか、同じ軸を二重に指定していないか確認してください。" >&2
  exit 64
fi

if ! _cmux_set_title "$REVIEWER_PANE_TITLE"; then
  echo "[start-reviewer] タブタイトルの設定に失敗しました（rename-tab 不可）。" >&2
  exit 1
fi
echo "[start-reviewer] タブを '$REVIEWER_PANE_TITLE' に設定しました。codex を起動します…" >&2

# 【遅延リネーム（実機知見）】codex は起動時に cwd 由来の名前（例 "xrev"）でタブ名を自ら
# 上書きすることが実機で確認されている（transport.sh の _xrev_create_reviewer 内コメント参照）。
# 上の「exec 前」のタイトル設定は即時フィードバックとして有用だが、codex 起動後に上書きされて
# しまう可能性が高く、規約タイトル 'Review Codex' が定着しないと宛先解決（title 一致）が
# exit 10 で失敗しうる。本プロセスは直後に exec で codex に置き換わるため、「起動確認後に
# 同一プロセスから追いリネームする」ことはできない。そこで exec 前にバックグラウンドの子プロセス
# を起動し、codex 起動後と思われるタイミングで transport.sh set-title により定着させ直す
# （best-effort）。子プロセスには CMUX_SURFACE_ID 等の env がそのまま継承されるため、
# set-title は自分自身のペインに効く。
# 4秒間隔×3回（最後は約12秒後）にしているのは、codex がタブ名を上書きする正確な時点が
# 起動環境やマシン負荷で揺れて読めないため。複数回リトライし、最後の1回で確実に上書きし
# 返すことを狙う控えめな固定値（回数・間隔とも根拠はここまでの理由のみで、実測による
# 最適化ではない）。失敗は無視する（best-effort。失敗してもタイトルが codex 上書き後の
# ままで残るだけで、ensure-reviewer 経路とは独立に手動で set-title をやり直せる）。
(
  for _xrev_delay_i in 1 2 3; do
    sleep 4
    "$DIR/transport.sh" set-title "$REVIEWER_PANE_TITLE" >/dev/null 2>&1
  done
) &
disown $! 2>/dev/null || true

# exec で置き換えるのはシェルを残さず codex に tty の前景を握らせるため（プロセス証明ゲートの前提）。
# 【注意】exec してもサーフェス直下プロセスが codex 単独にはならない。cmux はペインのログインシェルと
# 周期 sleep も直下として報告し続けるため、直下は複数件のまま。ゲートが見るのは件数ではなく
# 「前景プロセスグループを握るのが codex か」である（references/protocol.md 参照）。
# 万一 exec に失敗した場合は、規約タイトルのまま codex でない状態が残るため復旧手順を明示する。
# launch 引数（read-only 強制）を先に、ユーザー追加引数("$@")を後に置く。危険引数は上で拒否済みなので
# 後置でも sandbox/approval 系の上書きは起きない。
# 【注意】bash 3.2（macOS既定）は set -u 下で「宣言済みだが要素0件」の配列展開が unbound variable に
# なるバグがある。"${arr[@]+...}" イディオムで launch_args が0件（例: env override='[]'）でも安全に展開する。
exec "$codex_bin" "${launch_args[@]+"${launch_args[@]}"}" "$@"
echo "[start-reviewer] codex の起動(exec)に失敗しました。タブ名が '$REVIEWER_PANE_TITLE' のまま残っています。" >&2
echo "[start-reviewer] このタブで手動で codex を起動するか、タブを閉じて開き直してください。" >&2
exit 126
