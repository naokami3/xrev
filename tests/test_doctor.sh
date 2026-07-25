#!/usr/bin/env bash
#
# test_doctor.sh — transport.sh doctor の単体テスト。
#
# 純粋関数 _doctor_check_tree_shape / _doctor_check_top_shape はフィクスチャで単体検証する
# （cmux 非依存）。doctor 全体は XREV_CMUX_BIN を正常フィクスチャ／ping失敗フィクスチャの
# スタブ cmux に向けてサブプロセスとして実行し、exit 契約（fail>0→1 / fail=0→0）を確認する。
# フック契約セルフテストは実フックをそのまま呼ぶので、実装済みの実フックで通ることを前提にする。

export XREV_CONFIG="$DEFAULT_CONFIG"
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"

# ── _doctor_check_tree_shape ────────────────────────────────────────────────

# 正常フィクスチャ（ref="surface:*" title(str) uuid あり）→ rc0
valid_tree='{"windows":[{"ref":"window:1","uuid":"w1","workspaces":[
  {"ref":"workspace:1","uuid":"ws1","panes":[
    {"ref":"pane:1","uuid":"p1","surfaces":[
      {"ref":"surface:1","uuid":"s1","title":"Review Codex","type":"terminal"}]}]}]}]}'
out="$(printf '%s' "$valid_tree" | _doctor_check_tree_shape)"; rc=$?
assert_rc "tree: 正常フィクスチャは rc0" 0 "$rc"
assert_contains "tree: 正常時は件数入りの1行診断を返す" "$out" "件"

# 空 → rc非0
printf '' | _doctor_check_tree_shape >/dev/null 2>&1
assert_rc "tree: 空入力は rc1" 1 "$?"

# JSON 不正 → rc非0
printf '%s' 'これはJSONではありません' | _doctor_check_tree_shape >/dev/null 2>&1
assert_rc "tree: 不正JSONは rc1" 1 "$?"

# surface が1件も無い JSON（構文的には正しい）→ rc非0
printf '%s' '{"windows":[]}' | _doctor_check_tree_shape >/dev/null 2>&1
assert_rc "tree: surfaceが1件も無いJSONは rc1" 1 "$?"

# ref はあるが title が無い → rc非0
printf '%s' '{"surfaces":[{"ref":"surface:1","uuid":"s1"}]}' | _doctor_check_tree_shape >/dev/null 2>&1
assert_rc "tree: titleが無いsurfaceのみは rc1" 1 "$?"

# ── _doctor_check_top_shape ─────────────────────────────────────────────────

_mk_top_line() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7"; }

# 正常 TSV（surface行＋process行、PID数値）→ rc0
valid_top="$(_mk_top_line 0.0 1 1 surface surface:1 pane:1 title
_mk_top_line 0.0 1 1 process 4728 surface:1 codex)"
out="$(printf '%s' "$valid_top" | _doctor_check_top_shape)"; rc=$?
assert_rc "top: 正常TSVは rc0" 0 "$rc"
assert_contains "top: 正常時は行数入りの1行診断を返す" "$out" "行"

# 列不足（7列未満）→ rc非0
printf '%s' "$(printf 'a\tb\tc\n')" | _doctor_check_top_shape >/dev/null 2>&1
assert_rc "top: 列不足は rc1" 1 "$?"

# process 行の PID が非数値 → rc非0
bad_pid_top="$(_mk_top_line 0.0 1 1 surface surface:1 pane:1 title
_mk_top_line 0.0 1 1 process abc surface:1 codex)"
printf '%s' "$bad_pid_top" | _doctor_check_top_shape >/dev/null 2>&1
assert_rc "top: process行のPID非数値は rc1" 1 "$?"

# 空 → rc非0
printf '' | _doctor_check_top_shape >/dev/null 2>&1
assert_rc "top: 空入力は rc1" 1 "$?"

# ── doctor 全体（cmux はスタブ・実フックはそのまま呼ぶ）───────────────────────

_dr_dir="$(mktemp -d)"

# 正常系スタブ: ping成功・--version・tree・top をすべて正常フィクスチャで返す。
CMUX_STUB_OK="$_dr_dir/cmux-ok"
cat > "$CMUX_STUB_OK" <<'EOF'
#!/bin/sh
case "$1" in
  ping) exit 0 ;;
  --version) echo "cmux 0.64.20 (test-stub)"; exit 0 ;;
  tree)
    cat <<'JSON'
{"windows":[{"ref":"window:1","uuid":"w1","workspaces":[{"ref":"workspace:1","uuid":"ws-doctor","panes":[
  {"ref":"pane:1","uuid":"p1","surfaces":[{"ref":"surface:1","uuid":"caller-uuid","title":"Claude","type":"terminal"}]},
  {"ref":"pane:2","uuid":"p2","surfaces":[{"ref":"surface:2","uuid":"rc-uuid","title":"Review Codex","type":"terminal"}]}
]}]}]}
JSON
    ;;
  top)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 0.0 1 1 surface surface:2 pane:2 title
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 0.0 1 1 process 4242 surface:2 codex
    ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$CMUX_STUB_OK"

out="$(CMUX_SURFACE_ID=caller-uuid CMUX_WORKSPACE_ID=ws-doctor XREV_CONFIG="$DEFAULT_CONFIG" \
  XREV_CMUX_BIN="$CMUX_STUB_OK" bash "$SCRIPTS/transport.sh" doctor)"; rc=$?
assert_rc "doctor: 正常フィクスチャ一式は rc0" 0 "$rc"
assert_contains "doctor: サマリ行(ok=/warn=/fail=)を出力する" "$out" "ok="
assert_contains "doctor: fail=0 を含む" "$out" "fail=0"
assert_contains "doctor: 検出不能な縮退のinfo行を出力する" "$out" "[info]"

# ping失敗スタブ: cmux接続だけ落ちる → fail>0 で rc1（他の検査への波及は問わない）
CMUX_STUB_NG="$_dr_dir/cmux-ng"
cat > "$CMUX_STUB_NG" <<'EOF'
#!/bin/sh
case "$1" in
  ping) exit 1 ;;
  --version) echo "cmux 0.64.20 (test-stub)"; exit 0 ;;
  tree)
    cat <<'JSON'
{"windows":[{"ref":"window:1","uuid":"w1","workspaces":[{"ref":"workspace:1","uuid":"ws-doctor","panes":[
  {"ref":"pane:1","uuid":"p1","surfaces":[{"ref":"surface:1","uuid":"caller-uuid","title":"Claude","type":"terminal"}]}
]}]}]}
JSON
    ;;
  top)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 0.0 1 1 surface surface:1 pane:1 title
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 0.0 1 1 process 4242 surface:1 zsh
    ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$CMUX_STUB_NG"

out="$(CMUX_SURFACE_ID=caller-uuid XREV_CONFIG="$DEFAULT_CONFIG" \
  XREV_CMUX_BIN="$CMUX_STUB_NG" bash "$SCRIPTS/transport.sh" doctor)"; rc=$?
assert_rc "doctor: ping失敗は rc1" 1 "$rc"
assert_contains "doctor: cmux接続の検査がfailで出力される" "$out" "[fail] cmux 接続"

rm -rf "$_dr_dir"
