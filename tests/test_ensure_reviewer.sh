#!/usr/bin/env bash
# Phase1c: ensure-reviewer 関連の単体テスト（cmux はスタブ／純粋ヘルパ）。
# create-if-missing の分類・冪等・安全クォート・ロックパスを cmux 非依存で検証する。

export XREV_CONFIG="$DEFAULT_CONFIG"
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"

# ── _xrev_shquote（XREV_CODEX_BIN を shell へ安全に渡す。printf %q ベース）──
assert_eq "shquote: 単純はそのまま" "codex" "$(_xrev_shquote codex)"
assert_eq "shquote: 空白はエスケープ" '/a\ b/codex' "$(_xrev_shquote '/a b/codex')"
assert_eq "shquote: 単一引用符をエスケープ" "x\\'y" "$(_xrev_shquote "x'y")"

# ── _xrev_lock_path（TMPDIR 配下・非英数は _ に・リポ外）──
out="$(TMPDIR=/tmp _xrev_lock_path 'ABC-12.3')"
assert_eq "lock path: TMPDIR配下＋サニタイズ" "/tmp/xrev-reviewer-ABC_12_3.lock" "$out"
assert_contains "lock は /tmp 配下（リポジトリに作らない）" "$out" "/tmp/"

# ── _xrev_classify_reviewer（依存3関数をスタブ）──
_orig_resolve="$(declare -f _cmux_resolve_surface)"
_orig_probe="$(declare -f _probe_terminal_usable)"
_orig_proc="$(declare -f _verify_reviewer_process)"
_set_stubs() { # $1=resolve_rc $2=probe_out $3=proc_rc
  eval "_cmux_resolve_surface(){ _XREV_RES_REF=surface:7; _XREV_RES_UUID=u7; _XREV_RES_WS=w; return $1; }"
  eval "_probe_terminal_usable(){ printf '%s' '$2'; }"
  eval "_verify_reviewer_process(){ return $3; }"
}
_set_stubs 0 usable 0
out="$(_xrev_classify_reviewer)"; assert_rc "resolve0+usable+codex → present(0)" 0 "$?"
assert_eq "present 文字列" "present" "$out"
_set_stubs 0 non_terminal 0
out="$(_xrev_classify_reviewer)"; assert_rc "非端末 → 14" 14 "$?"
assert_eq "non_terminal 文字列" "non_terminal" "$out"
_set_stubs 0 usable 1
out="$(_xrev_classify_reviewer)"; assert_rc "usable だが codex でない → 17" 17 "$?"
assert_eq "process_mismatch 文字列" "process_mismatch" "$out"
_set_stubs 10 usable 0
out="$(_xrev_classify_reviewer)"; assert_rc "解決失敗(10) → absent" 10 "$?"
assert_eq "absent 文字列" "absent" "$out"
_set_stubs 16 usable 0
out="$(_xrev_classify_reviewer)"; assert_rc "曖昧(16) → ambiguous" 16 "$?"
eval "$_orig_resolve"; eval "$_orig_probe"; eval "$_orig_proc"

# ── xrev_ensure_reviewer のフロー（preflight/classify/create をスタブ）──
_orig_pre="$(declare -f _cmux_preflight)"
_orig_cls="$(declare -f _xrev_classify_reviewer)"
_orig_create="$(declare -f _xrev_create_reviewer)"
_orig_callerws="$(declare -f _xrev_caller_ws)"
_MARK="$(mktemp)"
_cmux_preflight(){ return 0; }
_xrev_caller_ws(){ printf 'ws-test-uuid'; }
_xrev_create_reviewer(){ echo created >> "$_MARK"; _XREV_RES_REF=surface:NEW; return 0; }

# present → 既存 ref を返し、生成しない（冪等）
: > "$_MARK"
_xrev_classify_reviewer(){ _XREV_RES_REF=surface:99; return 0; }
out="$(xrev_ensure_reviewer)"; rc=$?
assert_rc "present は rc0" 0 "$rc"
assert_eq "present は既存 ref を返す" "surface:99" "$out"
assert_eq "present は生成しない(0回)" "0" "$(grep -c . "$_MARK")"

# 既存が曖昧(16) → 作らず 16
: > "$_MARK"
_xrev_classify_reviewer(){ _XREV_RES_REF=""; return 16; }
xrev_ensure_reviewer >/dev/null 2>&1; rc=$?
assert_rc "曖昧は rc16（作らない）" 16 "$rc"
assert_eq "曖昧は生成しない" "0" "$(grep -c . "$_MARK")"

# absent + autocreate=off → 10、生成しない
: > "$_MARK"
_xrev_classify_reviewer(){ _XREV_RES_REF=""; return 10; }
REVIEWER_AUTOCREATE=off xrev_ensure_reviewer >/dev/null 2>&1; rc=$?
assert_rc "absent+off は rc10" 10 "$rc"
assert_eq "off は生成しない" "0" "$(grep -c . "$_MARK")"

# absent + auto → ロック取得して生成（mkdir は実ファイルだが /tmp の一時ロック）
: > "$_MARK"
_xrev_classify_reviewer(){ _XREV_RES_REF=""; return 10; }
out="$(TMPDIR=/tmp REVIEWER_AUTOCREATE=auto xrev_ensure_reviewer 2>/dev/null)"; rc=$?
assert_rc "absent+auto+生成成功 は rc0" 0 "$rc"
assert_eq "生成した ref を返す" "surface:NEW" "$out"
assert_eq "create が1回呼ばれる" "1" "$(grep -c . "$_MARK")"
assert_eq "ロックは後始末される（残らない）" "no" "$([[ -d /tmp/xrev-reviewer-ws_test_uuid.lock ]] && echo yes || echo no)"

# 生成が起動確認失敗(19) → 19 を返す
: > "$_MARK"
_xrev_create_reviewer(){ echo created >> "$_MARK"; return 19; }
TMPDIR=/tmp REVIEWER_AUTOCREATE=auto xrev_ensure_reviewer >/dev/null 2>&1; rc=$?
assert_rc "生成したが起動確認失敗 → rc19" 19 "$rc"

# 状態不明(transient=rc1) → 生成しない(11)。「不在を証明できない」障害で勝手に作らない。
: > "$_MARK"
_xrev_create_reviewer(){ echo created >> "$_MARK"; _XREV_RES_REF=surface:NEW; return 0; }
_xrev_classify_reviewer(){ _XREV_RES_REF=""; return 1; }
TMPDIR=/tmp REVIEWER_AUTOCREATE=auto xrev_ensure_reviewer >/dev/null 2>&1; rc=$?
assert_rc "状態不明(transient)は rc11（生成しない）" 11 "$rc"
assert_eq "transient は生成しない" "0" "$(grep -c . "$_MARK")"

# ロック下で absent→壊れ(14)に変化 → 作り直さず 14（二枚目を作らない）
: > "$_MARK"; _CNT="$(mktemp)"; : > "$_CNT"
_xrev_classify_reviewer(){ echo x >> "$_CNT"; if (( $(grep -c . "$_CNT") == 1 )); then _XREV_RES_REF=""; return 10; else _XREV_RES_REF=""; return 14; fi; }
TMPDIR=/tmp REVIEWER_AUTOCREATE=auto xrev_ensure_reviewer >/dev/null 2>&1; rc=$?
assert_rc "ロック下で壊れに変化 → 作らず14" 14 "$rc"
assert_eq "ロック下が非absentなら生成しない" "0" "$(grep -c . "$_MARK")"
rm -f "$_CNT"

rm -f "$_MARK"; rm -rf /tmp/xrev-reviewer-ws_test_uuid.lock
eval "$_orig_pre"; eval "$_orig_cls"; eval "$_orig_create"; eval "$_orig_callerws"
