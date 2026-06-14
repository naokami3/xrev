#!/usr/bin/env bash
# transport.sh::_resolve_surface_from_json のテスト（純粋関数）。
# cmux の tree --all --json 相当の fixture から、タイトル一致の surface ref を解決する。

export XREV_CONFIG="$DEFAULT_CONFIG"
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"

# 実機 tree --all --json を模した fixture（windows→workspaces→panes→surfaces のネスト）。
fixture='{
  "windows":[{"ref":"window:1","workspaces":[{"ref":"workspace:1","title":"作業ws","panes":[
    {"ref":"pane:1","surfaces":[{"ref":"surface:1","title":"⠂ 別の作業タブ","type":"terminal"}]},
    {"ref":"pane:2","surfaces":[{"ref":"surface:2","title":"⠐ Review Codex","type":"terminal"}]}
  ]}]}]
}'

# 完全一致（スピナー装飾 "⠐ " を正規化して一致）→ surface:2
out="$(_resolve_surface_from_json "Review Codex" "$fixture")"; rc=$?
assert_rc "スピナー付きタイトルでも解決できる(rc0)" 0 "$rc"
assert_eq "Review Codex → surface:2" "surface:2" "$out"

# 別ペインのサーフェスも横断で解決できる（tree 全体を歩く）
out="$(_resolve_surface_from_json "別の作業タブ" "$fixture")"
assert_eq "別ペインのタイトルも解決(surface:1)" "surface:1" "$out"

# 部分一致（"Review" だけでも一意なら解決）
out="$(_resolve_surface_from_json "Review" "$fixture")"
assert_eq "部分一致で解決(surface:2)" "surface:2" "$out"

# 未検出 → rc=5
_resolve_surface_from_json "存在しないタイトル" "$fixture" >/dev/null 2>&1; rc=$?
assert_rc "未検出は rc=5" 5 "$rc"

# 不正 JSON → rc=4
_resolve_surface_from_json "Review Codex" "これはJSONではない" >/dev/null 2>&1; rc=$?
assert_rc "不正JSONは rc=4" 4 "$rc"

# 複数一致 → rc=6（曖昧。誤送信を避けて失敗）
multi='{"surfaces":[
  {"ref":"surface:3","title":"Review Codex A","type":"terminal"},
  {"ref":"surface:4","title":"Review Codex B","type":"terminal"}]}'
_resolve_surface_from_json "Review Codex" "$multi" >/dev/null 2>&1; rc=$?
assert_rc "複数一致は rc=6（曖昧）" 6 "$rc"

# workspace/pane の ref は拾わない（surface: のみ対象）
trap_pane='{"panes":[{"ref":"pane:9","title":"Review Codex","surfaces":[]}]}'
_resolve_surface_from_json "Review Codex" "$trap_pane" >/dev/null 2>&1; rc=$?
assert_rc "pane の同名タイトルは surface でないので未検出(rc5)" 5 "$rc"
