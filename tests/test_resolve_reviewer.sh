#!/usr/bin/env bash
#
# test_resolve_reviewer.sh — D1: reviewer の auto 解決・semantic kind 分離・矛盾検査。
#
# 対象:
#   _xrev_resolve_primary / _xrev_resolve_reviewer（純粋関数・優先順位・fail closed）
#   派生3キー（reviewer_pane_title/reviewer_process/reviewer_reads_workspace）の auto 導出と
#     後方互換（既定configでの解決が旧既定値と完全一致すること）
#   主従反転プリセットとの等価性（既定config + XREV_PRIMARY=codex ≡ xrev.codex-primary.json）
#   _xrev_check_reviewer_conflicts（矛盾検査。fail closed）と xrev_transport_review への統合(exit29)
#   ラッパバイナリでも semantic kind(REVIEWER)が維持されること（launch引数解決がbasenameに
#     依存すると起きていた欠陥の回帰防止）
#
# cmux 非依存: xrev_transport_review の統合テストは _cmux_preflight / _cmux_resolve_surface のみ
# スタブする（test_integrity.sh / test_send_gates.sh と同じ流儀）。

export XREV_CONFIG="$DEFAULT_CONFIG"
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"

# ── _xrev_resolve_primary（純粋関数・優先順位）──────────────────────────────
out="$(_xrev_resolve_primary)"
assert_eq "primary未指定+既定config → claude" "claude" "$out"

out="$(XREV_PRIMARY=codex _xrev_resolve_primary)"
assert_eq "XREV_PRIMARY が最優先" "codex" "$out"

tmpcfg_primary="$(mktemp "${TMPDIR:-/tmp}/xrev-test-rr-primary.XXXXXX")"
python3 -c 'import json;d=json.load(open("'"$DEFAULT_CONFIG"'"));d["primary"]="codex";json.dump(d,open("'"$tmpcfg_primary"'","w"))'
out="$(XREV_CONFIG="$tmpcfg_primary" _xrev_resolve_primary)"
assert_eq "XREV_PRIMARY未指定時はconfigのprimaryを使う" "codex" "$out"
rm -f "$tmpcfg_primary"

# ── _xrev_resolve_reviewer（純粋関数・優先順位・fail closed）────────────────
out="$(_xrev_resolve_reviewer)"; rc=$?
assert_rc "既定config(primary=claude,reviewer=auto) → 解決成功" 0 "$rc"
assert_eq "既定config → reviewer=codex（後方互換）" "codex" "$out"

out="$(XREV_PRIMARY=codex _xrev_resolve_reviewer)"; rc=$?
assert_rc "XREV_PRIMARY=codex → 解決成功" 0 "$rc"
assert_eq "XREV_PRIMARY=codex+既定config(reviewer=auto) → reviewer=claude" "claude" "$out"

out="$(XREV_REVIEWER=gemini XREV_PRIMARY=codex _xrev_resolve_reviewer)"; rc=$?
assert_rc "XREV_REVIEWER明示 → 解決成功" 0 "$rc"
assert_eq "XREV_REVIEWER が最優先（primaryを無視）" "gemini" "$out"

tmpcfg_rev="$(mktemp "${TMPDIR:-/tmp}/xrev-test-rr-reviewer.XXXXXX")"
python3 -c 'import json;d=json.load(open("'"$DEFAULT_CONFIG"'"));d["reviewer"]="gemini";json.dump(d,open("'"$tmpcfg_rev"'","w"))'
out="$(XREV_CONFIG="$tmpcfg_rev" _xrev_resolve_reviewer)"; rc=$?
assert_rc "config のreviewerがauto以外 → 解決成功" 0 "$rc"
assert_eq "config のreviewer値(gemini)がそのまま使われる(primary不問)" "gemini" "$out"
rm -f "$tmpcfg_rev"

XREV_PRIMARY=foo _xrev_resolve_reviewer >/dev/null 2>&1
assert_rc "primaryが不正値でauto解決 → fail closed(rc1)" 1 "$?"
err="$(XREV_PRIMARY=foo _xrev_resolve_reviewer 2>&1 1>/dev/null)"
assert_contains "fail closed時のエラーメッセージにprimary値を含む" "$err" "foo"

unset out rc err

# ── 派生3キーの auto 導出・後方互換（既定config再source で固定）────────────────
export XREV_CONFIG="$DEFAULT_CONFIG"
unset XREV_PRIMARY XREV_REVIEWER
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"
assert_eq "後方互換: PRIMARY" "claude" "$PRIMARY"
assert_eq "後方互換: REVIEWER" "codex" "$REVIEWER"
assert_eq "後方互換: REVIEWER_PANE_TITLE" "Review Codex" "$REVIEWER_PANE_TITLE"
assert_eq "後方互換: REVIEWER_PROCESS" "codex" "$REVIEWER_PROCESS"
assert_eq "後方互換: REVIEWER_READS_WORKSPACE" "false" "$REVIEWER_READS_WORKSPACE"

# ── 主従反転（XREV_PRIMARY=codex）と xrev.codex-primary.json の等価性 ────────────
XREV_PRIMARY=codex
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"
PRESET="$XREV_ROOT/config/xrev.codex-primary.json"
_rr_preset_get() { python3 -c 'import json;print(json.load(open("'"$PRESET"'"))["'"$1"'"])'; }
assert_eq "等価性: primary" "$(_rr_preset_get primary)" "$PRIMARY"
assert_eq "等価性: reviewer" "$(_rr_preset_get reviewer)" "$REVIEWER"
assert_eq "等価性: reviewer_pane_title" "$(_rr_preset_get reviewer_pane_title)" "$REVIEWER_PANE_TITLE"
assert_eq "等価性: reviewer_process" "$(_rr_preset_get reviewer_process)" "$REVIEWER_PROCESS"
_rr_preset_rw="$(python3 -c 'import json;print(str(json.load(open("'"$PRESET"'"))["reviewer_reads_workspace"]).lower())')"
assert_eq "等価性: reviewer_reads_workspace" "$_rr_preset_rw" "$REVIEWER_READS_WORKSPACE"
unset -f _rr_preset_get
unset PRESET _rr_preset_rw XREV_PRIMARY

# ── _xrev_check_reviewer_conflicts（純粋関数・矛盾検査）───────────────────────
out="$(_xrev_check_reviewer_conflicts codex claude "")"; rc=$?
assert_rc "reviewer=codexにreviewer_process明示claudeは矛盾(rc1)" 1 "$rc"
assert_contains "矛盾理由にreviewer_processを含む" "$out" "reviewer_process"

out="$(_xrev_check_reviewer_conflicts codex my-wrapper "")"; rc=$?
assert_rc "ラッパ名(codex/claude以外)の明示値は矛盾にしない(rc0)" 0 "$rc"

_xrev_check_reviewer_conflicts claude "" false >/dev/null 2>&1
assert_rc "reviewer=claudeにreviewer_reads_workspace明示falseは矛盾(rc1)" 1 "$?"

_xrev_check_reviewer_conflicts claude "" true >/dev/null
assert_rc "reviewer=claudeでもreads_workspace明示trueは矛盾でない(rc0)" 0 "$?"

_xrev_check_reviewer_conflicts codex "" "" >/dev/null
assert_rc "明示値なし(auto由来)は矛盾なし(rc0)" 0 "$?"

unset out rc

# ── xrev_transport_review への統合: 矛盾検出時は resolve すら試みず rc29 ──────────
export XREV_CONFIG="$DEFAULT_CONFIG"
unset XREV_PRIMARY XREV_REVIEWER
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"
_RR_RESOLVE_CALLS=0
_cmux_preflight() { return 0; }
_cmux_resolve_surface() { _RR_RESOLVE_CALLS=$(( _RR_RESOLVE_CALLS + 1 )); _XREV_RES_REF="surface:9"; return 0; }
# 既定config(primary=claude) → REVIEWER=codex解決。reviewer_process を明示 claude にして矛盾させる。
REVIEWER_PROCESS="claude"
_XREV_REVIEWER_PROCESS_EXPLICIT="claude"
_rr_errfile="$(mktemp "${TMPDIR:-/tmp}/xrev-test-rr-err.XXXXXX")"
xrev_transport_review "テスト payload" >/dev/null 2>"$_rr_errfile"
_RR_RC=$?
_RR_ERR="$(cat "$_rr_errfile")"
rm -f "$_rr_errfile"
assert_rc "reviewer_process矛盾 → rc29" 29 "$_RR_RC"
assert_eq "矛盾検出はresolveより前に起きる(resolveは呼ばれない)" "0" "$_RR_RESOLVE_CALLS"
assert_contains "矛盾ログに矛盾の説明を含む" "$_RR_ERR" "矛盾"
unset _RR_RESOLVE_CALLS _RR_RC _RR_ERR _rr_errfile

# ── ラッパバイナリでも semantic kind(REVIEWER)が維持されること ─────────────────
export XREV_CONFIG="$DEFAULT_CONFIG"
unset XREV_PRIMARY XREV_REVIEWER
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"
# REVIEWER=codex（既定）のまま、バイナリ解決だけをラッパパスに差し替える（basenameはcodex/claudeでない）。
out="$(XREV_REVIEWER_BIN=/opt/bin/my-codex-wrapper _xrev_reviewer_bin)"
assert_eq "バイナリ解決はラッパパスを返す" "/opt/bin/my-codex-wrapper" "$out"
_rr_wrapper_basename="$(basename -- "$out")"
assert_eq "前提: ラッパのbasenameはcodex/claudeではない" "my-codex-wrapper" "$_rr_wrapper_basename"
# D1で修正した箇所: launch引数の解決キーは semantic kind(REVIEWER)であり、バイナリのbasenameではない。
_xrev_reviewer_launch_args "$REVIEWER" >/dev/null
assert_rc "semantic kind(REVIEWER=codex)で呼べば既定launch引数を解決できる" 0 "$?"
_xrev_reviewer_launch_args "$_rr_wrapper_basename" >/dev/null 2>&1
assert_rc "回帰防止: basename(ラッパ)で呼ぶと未知reviewerとして拒否される(修正前の欠陥の再現)" 1 "$?"
unset out _rr_wrapper_basename

# ── 後片付け: 実体を読み直して環境変数上書きを捨てる（後続の test_*.sh へ漏らさない）──────
unset XREV_PRIMARY XREV_REVIEWER
export XREV_CONFIG="$DEFAULT_CONFIG"
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"
