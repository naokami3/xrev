#!/usr/bin/env bash
#
# test_foreground_policy_argv.sh — 指摘1（2巡目・decision-impl-2.json）:
# 既存ペイン採用時の実効検証（_xrev_verify_reviewer_policy → _xrev_verify_foreground_policy）
# における argv 境界保持の回帰テスト。
#
# 背景: KERN_PROCARGS2 で取得した argv 境界は、_xrev_procargs2_argv_tail（旧実装）が各要素を
# 改行区切りで stdout に戻す時点で再び失われていた。argv 要素には改行を含められるため、単一要素
# `--permission-mode\nplan` 等が後段の while read で2要素に分割され、実際には存在しない安全フラグ
# として認識され得た（high 指摘）。修正後は「PID の受領 → KERN_PROCARGS2 での argv 取得 →
# 安全ポリシー判定」までを単一の python プロセス内で完結させ、argv を区切り文字ベースの形で
# bash に戻さない（_xrev_verify_foreground_policy）。本テストは実際に子プロセスを起動し、その
# 本物の argv・本物の PID を対象に、単一 argv 要素の内部に「空白」「TAB」「改行」のいずれかを
# 挟んで --permission-mode plan という文字列を仕込んでも、既存ペイン採用経路
# （_xrev_verify_reviewer_policy）の検証がすべて不合格になることを確認する。独立 argv の本物は
# 合格することも確認する。
#
# cmux 依存: `_cmux_top_processes` と `_ps_snapshot` だけをスタブする。前景プロセスグループの
# 判定はテスト実行環境の実 tty には依存させず（tty のフォアグラウンドプロセスグループを CI 等の
# 非対話シェルから決定的に制御するのは非現実的なため）、_ps_snapshot が返す pgid/tpgid を
# 一致させることで単一の直下プロセスをそのまま前景として確定させる。comm 列も任意の文字列を
# 返せるため REVIEWER_PROCESS の期待名と一致させる（実行ファイルの実名とは無関係）。
# argv 取得(procargs2)・安全ポリシー判定(_xrev_check_policy)は本物を使う（一切スタブしない）。
#
# sysctl(KERN_PROCARGS2) は macOS 専用の機構である。非 Darwin では argv を取得できず
# fail closed（検証不能→不合格）になる（test_claude_launch_args_argv.sh と同じ契約）。

export XREV_CONFIG="$DEFAULT_CONFIG"
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"

_IS_DARWIN=0
[[ "$(uname -s)" == "Darwin" ]] && _IS_DARWIN=1

# 実子プロセスを起動する（十分長く待たせ、テスト中は生存させる）。$@ をそのまま子の argv[1:] にする。
_FPA_PID=""
_fpa_spawn() {
  python3 -c 'import time; time.sleep(60)' "$@" &
  _FPA_PID=$!
}
_fpa_kill() {
  if [[ -n "${_FPA_PID:-}" ]]; then
    kill "$_FPA_PID" 2>/dev/null
    wait "$_FPA_PID" 2>/dev/null
  fi
  _FPA_PID=""
}
trap '_fpa_kill' EXIT INT TERM

# cmux top のスタブ: 直下プロセスは spawn した子プロセス1件のみ（surface:20 直下）。
_cmux_top_processes() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 0.0 1 1 process "$_FPA_PID" surface:20 claude
}
# ps スナップショットのスタブ: pgid=tpgid=PID（そのプロセス自身のグループが tty の前景という
# 体にする。tty のフォアグラウンドプロセスグループの実機挙動には依存しない）。comm は
# REVIEWER_PROCESS（claude）の basename と一致させる（実行ファイルの実名=python3 とは無関係。
# 前景の識別はここで完全に制御し、テストの対象は argv 取得〜安全ポリシー判定の部分に絞る）。
_ps_snapshot() {
  local p
  while IFS= read -r p; do
    [[ -n "$p" ]] && printf '%s %s %s claude\n' "$p" "$p" "$p"
  done
}

REVIEWER_PROCESS=claude

# ── (a) 偽フラグ: 単一 argv 要素の内部に空白区切りで --permission-mode plan を埋め込む ──────
_fpa_spawn --settings '{"a": "--permission-mode plan"}'
sleep 0.3
_xrev_verify_reviewer_policy "surface:20" >/dev/null 2>&1
rc=$?
if (( _IS_DARWIN )); then
  assert_rc "偽フラグ(空白入り単一argv内部)は既存ペイン採用経路で不合格" 1 "$rc"
else
  assert_rc "非macOSは検証不能でfail closed" 1 "$rc"
fi
_fpa_kill

# ── (b) 偽フラグ: 単一 argv 要素の内部に TAB を挟んで --permission-mode<TAB>plan ────────────
_fpa_spawn "$(printf -- '--permission-mode\tplan')"
sleep 0.3
_xrev_verify_reviewer_policy "surface:20" >/dev/null 2>&1
rc=$?
if (( _IS_DARWIN )); then
  assert_rc "偽フラグ(TAB入り単一argv)は既存ペイン採用経路で不合格" 1 "$rc"
else
  assert_rc "非macOSは検証不能でfail closed" 1 "$rc"
fi
_fpa_kill

# ── (c) 偽フラグ: 単一 argv 要素の内部に改行を挟んで --permission-mode\nplan ─────────────
# 【本命】旧実装（_xrev_procargs2_argv_tail による改行区切り出力 → while read 再構成）が
# 誤って合格させていた具体的な入力（指摘1・2巡目の再現条件そのもの）。
_fpa_spawn "$(printf -- '--permission-mode\nplan')"
sleep 0.3
_xrev_verify_reviewer_policy "surface:20" >/dev/null 2>&1
rc=$?
if (( _IS_DARWIN )); then
  assert_rc "偽フラグ(改行入り単一argv)は既存ペイン採用経路で不合格" 1 "$rc"
else
  assert_rc "非macOSは検証不能でfail closed" 1 "$rc"
fi
_fpa_kill

# ── (d) 本物: 独立した argv として --permission-mode / plan があれば合格する ───────────────
_fpa_spawn --permission-mode plan
sleep 0.3
_xrev_verify_reviewer_policy "surface:20" >/dev/null 2>&1
rc=$?
if (( _IS_DARWIN )); then
  assert_rc "本物の--permission-mode plan(独立argv)は既存ペイン採用経路で合格する" 0 "$rc"
else
  assert_rc "非macOSでは検証不能としてfail closed" 1 "$rc"
fi
_fpa_kill

# ── (e) 本物+偽フラグ混在: probe-report.md R1 相当（空白入りJSONの後ろに独立フラグ）でも合格 ──
_fpa_spawn --settings '{"a": "--permission-mode plan"}' --permission-mode plan
sleep 0.3
_xrev_verify_reviewer_policy "surface:20" >/dev/null 2>&1
rc=$?
if (( _IS_DARWIN )); then
  assert_rc "偽フラグ混在でも独立argvの本物があれば合格する" 0 "$rc"
else
  assert_rc "非macOSでは検証不能としてfail closed" 1 "$rc"
fi
_fpa_kill

trap - EXIT INT TERM
unset _IS_DARWIN _FPA_PID rc
unset -f _fpa_spawn _fpa_kill

# ── 後片付け: 実体を読み直してスタブ・REVIEWER_PROCESS 上書きを捨てる（後続の test_*.sh へ漏らさない）──
export XREV_CONFIG="$DEFAULT_CONFIG"
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"
