#!/usr/bin/env bash
# transport.sh の Phase1 純粋関数テスト（同一WSスコープ解決・UUID探索・top プロセス抽出）。
# cmux 不要。tree(--id-format both 相当) / top(--processes tsv 相当) の fixture で検証する。

export XREV_CONFIG="$DEFAULT_CONFIG"
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"

# 2 ワークスペースそれぞれに同名 "Review Codex" がある tree。--id-format both 相当で uuid を持つ。
# caller(me=surface:4)は ws2。誤って ws1 の Review Codex を選ばないことが要点（誤配送バグの回帰防止）。
tree='{"windows":[{"ref":"window:1","uuid":"w1","workspaces":[
  {"ref":"workspace:1","uuid":"ws1","panes":[
    {"ref":"pane:1","uuid":"p1","surfaces":[
      {"ref":"surface:1","uuid":"cl1","title":"Claude A","type":"terminal"},
      {"ref":"surface:2","uuid":"rc1","title":"⠐ Review Codex","type":"terminal"}]}]},
  {"ref":"workspace:2","uuid":"ws2","panes":[
    {"ref":"pane:3","uuid":"p3","surfaces":[
      {"ref":"surface:4","uuid":"me","title":"Claude B","type":"terminal"}]},
    {"ref":"pane:6","uuid":"p6","surfaces":[
      {"ref":"surface:9","uuid":"rc2","title":"Review Codex","type":"terminal"}]}]}
]}]}'

# 1) 誤配送防止: caller=ws2 なら同一WSの surface:9 を選び、ws1 の surface:2 は選ばない
out="$(XREV_LISTING="$tree" XREV_CALLER="me" _resolve_ws_scoped "Review Codex")"; rc=$?
assert_rc "同一WS解決は rc0" 0 "$rc"
assert_eq "caller=ws2 → 自WSの surface:9 を選ぶ(誤配送防止)" "surface:9" "$(printf '%s' "$out" | cut -f1)"
assert_eq "surface_uuid も返す" "rc2" "$(printf '%s' "$out" | cut -f2)"
assert_eq "workspace_id も返す" "ws2" "$(printf '%s' "$out" | cut -f3)"

# 2) caller=ws1 なら ws1 側の surface:2 を選ぶ
out="$(XREV_LISTING="$tree" XREV_CALLER="cl1" _resolve_ws_scoped "Review Codex")"
assert_eq "caller=ws1 → ws1 の surface:2" "surface:2" "$(printf '%s' "$out" | cut -f1)"

# 3) 部分一致（自WSで一意なら解決）
out="$(XREV_LISTING="$tree" XREV_CALLER="me" _resolve_ws_scoped "Review")"
assert_eq "部分一致で自WSの surface:9" "surface:9" "$(printf '%s' "$out" | cut -f1)"

# 4) 自WSに無いタイトル（他WSには在る）→ 採用しない rc5（cross-pick しない）
XREV_LISTING="$tree" XREV_CALLER="me" _resolve_ws_scoped "Claude A" >/dev/null 2>&1; rc=$?
assert_rc "他WSにしか無いタイトルは rc5（cross-pick 防止）" 5 "$rc"

# 5) caller 自身のタイトルは除外する（自分を reviewer にしない）
XREV_LISTING="$tree" XREV_CALLER="me" _resolve_ws_scoped "Claude B" >/dev/null 2>&1; rc=$?
assert_rc "caller 自身は候補から除外(rc5)" 5 "$rc"

# 6) caller UUID が tree に無い → rc7（WS 特定不能・fail closed）
XREV_LISTING="$tree" XREV_CALLER="unknown" _resolve_ws_scoped "Review Codex" >/dev/null 2>&1; rc=$?
assert_rc "caller WS 特定不能は rc7" 7 "$rc"

# 7) 同一WS内でタイトル一致が複数 → rc6（曖昧・fail closed）
tree_multi='{"windows":[{"ref":"window:1","uuid":"w1","workspaces":[
  {"ref":"workspace:2","uuid":"ws2","panes":[
    {"ref":"pane:3","uuid":"p3","surfaces":[{"ref":"surface:4","uuid":"me","title":"Claude","type":"terminal"}]},
    {"ref":"pane:6","uuid":"p6","surfaces":[
      {"ref":"surface:9","uuid":"rc2","title":"Review Codex","type":"terminal"},
      {"ref":"surface:10","uuid":"rc3","title":"Review Codex","type":"terminal"}]}]}
]}]}'
XREV_LISTING="$tree_multi" XREV_CALLER="me" _resolve_ws_scoped "Review Codex" >/dev/null 2>&1; rc=$?
assert_rc "同一WSで複数一致は rc6（曖昧）" 6 "$rc"

# 8) 不正 JSON → rc4
XREV_LISTING="これはJSONではない" XREV_CALLER="me" _resolve_ws_scoped "Review Codex" >/dev/null 2>&1; rc=$?
assert_rc "不正JSONは rc4" 4 "$rc"

# ── _locate_surface（ref または UUID から一意特定。3フィールド出力）──────────────
out="$(XREV_LISTING="$tree" _locate_surface "rc2")"; rc=$?
assert_rc "UUID 探索は rc0" 0 "$rc"
assert_eq "rc2 → ref(surface:9)" "surface:9" "$(printf '%s' "$out" | cut -f1)"
assert_eq "rc2 → uuid(rc2)" "rc2" "$(printf '%s' "$out" | cut -f2)"
assert_eq "rc2 → workspace(ws2)" "ws2" "$(printf '%s' "$out" | cut -f3)"

# ref 指定でも特定でき WS を返す（明示 ref が WS 検証を迂回しないことの土台）
out="$(XREV_LISTING="$tree" _locate_surface "surface:2")"; rc=$?
assert_rc "ref 指定でも rc0" 0 "$rc"
assert_eq "surface:2 → uuid(rc1)" "rc1" "$(printf '%s' "$out" | cut -f2)"
assert_eq "surface:2 → workspace(ws1)" "ws1" "$(printf '%s' "$out" | cut -f3)"

XREV_LISTING="$tree" _locate_surface "nope" >/dev/null 2>&1; rc=$?
assert_rc "未知トークンは rc5" 5 "$rc"

XREV_LISTING="badjson" _locate_surface "rc2" >/dev/null 2>&1; rc=$?
assert_rc "不正JSONは rc4" 4 "$rc"

# 曖昧拒否(rc6): token が「ある surface の ref」かつ「別 surface の UUID」に一致するケース
tree_collide='{"windows":[{"ref":"window:1","workspaces":[{"ref":"workspace:1","panes":[{"ref":"pane:1","surfaces":[
  {"ref":"surface:1","uuid":"x1","title":"A","type":"terminal"},
  {"ref":"surface:2","uuid":"surface:1","title":"B","type":"terminal"}]}]}]}]}'
XREV_LISTING="$tree_collide" _locate_surface "surface:1" >/dev/null 2>&1; rc=$?
assert_rc "ref と別surfaceのUUIDが衝突 → 曖昧 rc6" 6 "$rc"

# 曖昧拒否(rc6): 同一 UUID が複数 surface に現れる壊れた tree
tree_dupuuid='{"windows":[{"ref":"window:1","workspaces":[{"ref":"workspace:1","panes":[{"ref":"pane:1","surfaces":[
  {"ref":"surface:1","uuid":"dup","title":"A","type":"terminal"},
  {"ref":"surface:2","uuid":"dup","title":"B","type":"terminal"}]}]}]}]}'
XREV_LISTING="$tree_dupuuid" _locate_surface "dup" >/dev/null 2>&1; rc=$?
assert_rc "重複UUID → 曖昧 rc6" 6 "$rc"

# ── _verify_reviewer_process（プロセス証明: 直下が厳密に1件 codex のときだけ送信許可）──
# _cmux_top_processes をスタブして top 取得をテスト下に置く。
_orig_top_fn="$(declare -f _cmux_top_processes)"
_mk_top() { # 引数: "surface:N=proc[,proc...]" を TSV 行へ
  local spec row
  for spec in "$@"; do
    local s="${spec%%=*}" procs="${spec#*=}" p
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 0.0 1 1 surface "$s" pane:1 title
    IFS=','; for p in $procs; do [[ -n "$p" ]] && printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 0.0 1 1 process 100 "$s" "$p"; done; unset IFS
  done
}
_TEST_TOP=""; _cmux_top_processes() { printf '%s' "$_TEST_TOP"; }

_TEST_TOP="$(_mk_top "surface:9=codex")"
_verify_reviewer_process "surface:9"; assert_rc "直下が codex 単独 → 許可(rc0)" 0 "$?"

_TEST_TOP="$(_mk_top "surface:9=codex,zsh")"
_verify_reviewer_process "surface:9" 2>/dev/null; assert_rc "codex と shell が同居 → 拒否(非0)" 1 "$?"

_TEST_TOP="$(_mk_top "surface:9=zsh")"
_verify_reviewer_process "surface:9" 2>/dev/null; assert_rc "直下が shell のみ → 拒否(非0)" 1 "$?"

_TEST_TOP="$(_mk_top "surface:8=codex")"  # 対象 surface に直下プロセス無し
_verify_reviewer_process "surface:9" 2>/dev/null; assert_rc "対象surfaceに直下プロセス無し → 拒否(非0)" 1 "$?"

_TEST_TOP=""
_verify_reviewer_process "surface:9" 2>/dev/null; assert_rc "top 取得不可 → 拒否(非0)" 1 "$?"

eval "$_orig_top_fn"  # スタブを元に戻す

# ── _top_surface_processes（top TSV から直下プロセスを抽出）──────────────────
top="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  0.0 1 1 surface surface:2 pane:2 'Review Codex' \
  0.0 1 1 process 96186 surface:2 codex \
  0.0 1 1 process 5220 96186 caffeinate \
  0.0 1 1 surface surface:4 pane:3 Claude \
  0.0 1 1 process 46530 surface:4 2.1.185)"

assert_eq "surface:2 の直下は codex のみ（孫の caffeinate は含めない）" \
  "codex" "$(XREV_TOP="$top" _top_surface_processes "surface:2" | paste -sd, -)"
assert_eq "surface:4 の直下は claude プロセス" \
  "2.1.185" "$(XREV_TOP="$top" _top_surface_processes "surface:4" | paste -sd, -)"
assert_eq "存在しない surface は空" \
  "" "$(XREV_TOP="$top" _top_surface_processes "surface:99")"
