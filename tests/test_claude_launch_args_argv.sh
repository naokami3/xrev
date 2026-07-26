#!/usr/bin/env bash
#
# test_claude_launch_args_argv.sh — 指摘2: argv 境界保持取得（sysctl KERN_PROCARGS2）の回帰テスト。
#
# 背景: 旧実装は `ps -o args=` の表示文字列を空白分割して argv を再構成しており、値自体に空白を
# 含む単一 argv 要素（cmux が claude へ注入する `--settings <JSON>` 等。probe-report.md R1 で実測）の
# **内部**に `--permission-mode plan` という文字列が現れると、それを独立した実フラグと誤認しうる
# （安全ポリシーの誤判定に直結する high 指摘）。sysctl(KERN_PROCARGS2) 経由の新方式
# （`_xrev_procargs2_snapshot`）でこれが解消したことを、**実際に子プロセスを起動し**、その本物の
# argv・本物の PID を対象に検証する（スタブでの回避はしない）。
#
# 【指摘1・2巡目（decision-impl-2.json）】さらに、取得した argv 境界を「PID 受領 → argv 取得 →
# 安全ポリシー判定」まで単一 python プロセス内で完結させず改行区切りで bash へ戻す実装
# （旧 `_xrev_procargs2_argv_tail`）は、argv 要素自体に生の改行を含む単一要素（例:
# `--permission-mode\nplan`）を後段の `while read` が2要素に分割し、実在しない安全フラグとして
# 誤認しうる再帰的な同種バグを持っていた。(b2)(b3) で TAB・改行を挟んだ単一 argv 要素でも合格
# しないことを確認する（`_verify_reviewer_launch_args` は現在この判定を単一プロセス内で完結させる）。
#
# sysctl(KERN_PROCARGS2) は macOS 専用の機構である。
#   - Darwin: (a) 境界保持の実測復元 (b)(b2)(b3) 偽フラグ（空白/TAB/改行での埋め込み）は不合格
#     (c) 本物フラグは合格 (d) probe-report.md R1 の実測 argv フィクスチャでも合格、を
#     すべて実測で確認する。
#   - 非 Darwin（sysctl(KERN_PROCARGS2) 未対応環境）: 取得できないため fail closed（検証不能→不合格）に
#     なることを確認する（「取得できないなら安全側に倒れる」という実装契約そのものの回帰テスト）。
#
# cmux 依存: `_cmux_top_processes` だけをスタブし、実体の対象は実際に spawn した子プロセスの PID。
# `_top_surface_processes` / `_verify_reviewer_launch_args` / `_xrev_procargs2_snapshot` は
# すべて本物を使う。

export XREV_CONFIG="$DEFAULT_CONFIG"
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"

_orig_top="$(declare -f _cmux_top_processes)"

_IS_DARWIN=0
[[ "$(uname -s)" == "Darwin" ]] && _IS_DARWIN=1

# 実子プロセスを起動する（十分長く待たせ、テスト中は生存させる）。$@ をそのまま子の argv[1:] にする。
_CLAA_PID=""
_claa_spawn() {
  python3 -c 'import time; time.sleep(60)' "$@" &
  _CLAA_PID=$!
}
_claa_kill() {
  if [[ -n "${_CLAA_PID:-}" ]]; then
    kill "$_CLAA_PID" 2>/dev/null
    wait "$_CLAA_PID" 2>/dev/null
  fi
  _CLAA_PID=""
}
trap '_claa_kill' EXIT INT TERM

# cmux top のスタブ: 直下プロセスは spawn した子プロセス1件のみ（surface:15 直下）。
_cmux_top_processes() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 0.0 1 1 process "$_CLAA_PID" surface:15 python3
}

# ── (a) 境界保持の実測: 新ヘルパが argv 境界を正しく復元すること ──────────────────
# cmux が claude へ注入する --settings <JSON>（値の内部に空白を含む）を模したうえで、
# 本物の --permission-mode / plan を独立 argv として付ける（probe-report.md R1 の実測に相当）。
_claa_spawn --settings '{"a": "--permission-mode plan"}' --permission-mode plan
sleep 0.3
argv_json="$(printf '%s\n' "$_CLAA_PID" | _xrev_procargs2_snapshot | cut -f2-)"
if (( _IS_DARWIN )); then
  assert_eq "procargs2: この環境ではargv取得が非空で成立する" "1" \
    "$([[ -n "$argv_json" ]] && echo 1 || echo 0)"
  got="$(printf '%s' "$argv_json" | python3 -c '
import json, sys
a = json.load(sys.stdin)
print("\n".join(a[-4:]))
')"
  expect=$'--settings\n{"a": "--permission-mode plan"}\n--permission-mode\nplan'
  assert_eq "procargs2: --settings の値(空白入り)が1個の argv 要素として境界保持のまま復元される" \
    "$expect" "$got"
else
  assert_eq "procargs2: 非macOSではargv取得が成立しない(fail closed)" "" "$argv_json"
fi
_claa_kill

# ── (b) 偽フラグ: --settings の値の内部に --permission-mode plan があっても合格しない ──────
# 独立した --permission-mode / plan の argv は一切存在しない（JSON 値の中だけに文字列として現れる）。
_claa_spawn --settings '{"a": "--permission-mode plan"}'
sleep 0.3
( _verify_reviewer_launch_args "surface:15" claude )
rc=$?
assert_rc "偽フラグ(--settingsの値内部の--permission-mode plan)は合格させない" 1 "$rc"
_claa_kill

# ── (b2) 偽フラグ: 単一 argv 要素の内部に TAB を挟んで --permission-mode<TAB>plan ────────────
# 【指摘1・2巡目への対処の回帰確認】単一 argv 要素自体に区切り文字（TAB/改行）を含めても、
# 独立した --permission-mode / plan とは認識されないこと（区切り文字ベースの再構成をしていない）。
_claa_spawn "$(printf -- '--permission-mode\tplan')"
sleep 0.3
( _verify_reviewer_launch_args "surface:15" claude )
rc=$?
assert_rc "偽フラグ(TAB入り単一argv)は合格させない" 1 "$rc"
_claa_kill

# ── (b3) 偽フラグ: 単一 argv 要素の内部に改行を挟んで --permission-mode\nplan ───────────────
# 【本命】argv を改行区切りで bash へ戻す旧実装（_xrev_procargs2_argv_tail）では、この単一要素が
# while read で2要素に分割され、実在しない --permission-mode / plan として誤って合格しえた
# （decision-impl-2.json 指摘1・high）。単一プロセス内で完結する新実装では合格しないことを確認する。
_claa_spawn "$(printf -- '--permission-mode\nplan')"
sleep 0.3
( _verify_reviewer_launch_args "surface:15" claude )
rc=$?
assert_rc "偽フラグ(改行入り単一argv)は合格させない" 1 "$rc"
_claa_kill

# ── (c) 本物フラグ: --settings の後ろに独立した --permission-mode plan があれば合格する ─────
# probe-report.md R1 の実測と同じ形（前方に空白入りJSON、後方に本物の独立フラグ）。
_claa_spawn --settings '{"a": "--permission-mode plan"}' --permission-mode plan
sleep 0.3
( _verify_reviewer_launch_args "surface:15" claude )
rc=$?
if (( _IS_DARWIN )); then
  assert_rc "本物の--permission-mode plan(独立argv)は合格させる" 0 "$rc"
else
  assert_rc "非macOSでは検証不能としてfail closed(不合格)" 1 "$rc"
fi
_claa_kill

# ── (d) probe-report.md R1 の実測 argv をそのままフィクスチャ化（境界保持形）───────────
# 元の実測は `ps -o args=` が返す1本の文字列だったが、ここでは各要素を独立した argv として
# 実際に子プロセスへ渡す（= 実際の argv 配列そのものの再現。文字列の結合ではない）。
_claa_spawn --session-id 0ba8c78d-0093-4f4e-9321-0fed77139c37 \
  --settings '{"preferredNotifChannel":"notifications_disabled","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"cmux hooks claude auto-name","timeout":120,"async":true}]}]}}' \
  --permission-mode plan
sleep 0.3
( _verify_reviewer_launch_args "surface:15" claude )
rc=$?
if (( _IS_DARWIN )); then
  assert_rc "probe-report.md R1 実測argv(--session-id/--settings JSON注入)でも --permission-mode plan の実効を合格させる" 0 "$rc"
else
  assert_rc "非macOSでは検証不能としてfail closed(不合格)" 1 "$rc"
fi
_claa_kill

trap - EXIT INT TERM
eval "$_orig_top"
unset _orig_top _IS_DARWIN _CLAA_PID argv_json got expect rc
unset -f _claa_spawn _claa_kill
