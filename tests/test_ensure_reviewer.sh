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

# ── _xrev_classify_reviewer（依存4関数をスタブ）──
# 指摘3への対処: present 判定は _verify_reviewer_process の成功後、さらに
# _xrev_verify_reviewer_policy（安全ポリシーの実効検証）を通す。既定は検証する(fail closed)。
# XREV_ALLOW_UNVERIFIED_REVIEWER=1 のときだけ検証を省略して present を返す（後方互換）。
_orig_resolve="$(declare -f _cmux_resolve_surface)"
_orig_probe="$(declare -f _probe_terminal_usable)"
_orig_proc="$(declare -f _verify_reviewer_process)"
_orig_policy="$(declare -f _xrev_verify_reviewer_policy)"
_set_stubs() { # $1=resolve_rc $2=probe_out $3=proc_rc $4=policy_rc(既定0=安全ポリシー合格)
  local policy_rc="${4:-0}"
  eval "_cmux_resolve_surface(){ _XREV_RES_REF=surface:7; _XREV_RES_UUID=u7; _XREV_RES_WS=w; return $1; }"
  eval "_probe_terminal_usable(){ printf '%s' '$2'; }"
  eval "_verify_reviewer_process(){ return $3; }"
  eval "_xrev_verify_reviewer_policy(){ return $policy_rc; }"
}
_set_stubs 0 usable 0
out="$(_xrev_classify_reviewer)"; assert_rc "resolve0+usable+codex+安全policy → present(0)" 0 "$?"
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

# ── 安全ポリシー実効検証（指摘3）: 既存ペインの argv が安全でない → policy_mismatch(27) ──────
_set_stubs 0 usable 0 1
out="$(_xrev_classify_reviewer 2>/dev/null)"; assert_rc "usable+codex だが安全policy不合格 → policy_mismatch(27)" 27 "$?"
assert_eq "policy_mismatch 文字列" "policy_mismatch" "$out"

# XREV_ALLOW_UNVERIFIED_REVIEWER=1（明示 opt-in）なら安全policy不合格でも present（警告付き・後方互換）
_pm_warn="$(mktemp)"
out="$(XREV_ALLOW_UNVERIFIED_REVIEWER=1 _xrev_classify_reviewer 2>"$_pm_warn")"; rc=$?
assert_rc "opt-out env は安全policy不合格でも present(0)" 0 "$rc"
assert_eq "opt-out env でも present 文字列" "present" "$out"
assert_contains "opt-out env は警告ログを出す" "$(cat "$_pm_warn")" "XREV_ALLOW_UNVERIFIED_REVIEWER"
rm -f "$_pm_warn"

eval "$_orig_resolve"; eval "$_orig_probe"; eval "$_orig_proc"; eval "$_orig_policy"

# ── _xrev_create_reviewer: launch 引数（read-only 強制）の実効検証 ─────────────────
# 生成本体そのものを cmux 非依存で動かすため、cmux 呼び出し・宛先解決・プロセス証明・
# launch 引数の実効検証をスタブする（_xrev_reviewer_launch_args 自体は本物を使い、既定
# config の codex 分がそのまま渡ることも併せて検証する）。
_orig_cmux="$(declare -f _cmux)"
_orig_tree="$(declare -f _cmux_tree_uuids)"
_orig_locate="$(declare -f _locate_surface)"
_orig_probe3="$(declare -f _probe_terminal_usable)"
_orig_proc3="$(declare -f _verify_reviewer_process)"
_orig_largs="$(declare -f _verify_reviewer_launch_args)"
_orig_sleep="$(declare -f _xrev_sleep)"

_cmux() { # new-pane 以外は無条件成功でよい（send/send-key/rename-tab の内容は本テストの対象外）
  case "$1" in
    new-pane) printf 'surface:42\n'; return 0 ;;
    *) return 0 ;;
  esac
}
_cmux_tree_uuids() { printf '{}'; }               # 中身は使わない（_locate_surface をスタブするため）
_locate_surface() { printf 'surface:42\tu42\tws1'; return 0; }
_probe_terminal_usable() { printf 'usable'; }
_verify_reviewer_process() { return 0; }
_xrev_sleep() { :; }  # 実待機を無くしてテストを高速化する

# 実在する codex という名前のダミー実行ファイルを PATH に用意する（既定 config の codex 分をそのまま使う）。
_crt_bindir="$(mktemp -d)"
cat > "$_crt_bindir/codex" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$_crt_bindir/codex"

# 【注意】_xrev_create_reviewer は結果を戻り値と _XREV_RES_* グローバルで返す（stdout には出さない）。
# xrev_ensure_reviewer 側の既存コメントどおり、$() で捕捉するとサブシェルでグローバルが失われるため、
# ここでも $() を使わず直接呼び出して rc と _XREV_RES_REF を確認する。

# launch 引数の実効検証が失敗 → 採用しない(return 19)。CREATE_TIMEOUT を短くして待ち過ぎを防ぐ。
_verify_reviewer_launch_args() { return 1; }
_XREV_RES_REF=""
PATH="$_crt_bindir:$PATH" CREATE_TIMEOUT=1 _xrev_create_reviewer ws1 >/dev/null 2>/dev/null; rc=$?
assert_rc "launch引数の実効検証に失敗 → rc19（採用しない）" 19 "$rc"

# launch 引数の実効検証が成功 → 採用（所有 surface ref をグローバルに設定）
_verify_reviewer_launch_args() { return 0; }
_XREV_RES_REF=""
PATH="$_crt_bindir:$PATH" _xrev_create_reviewer ws1 >/dev/null 2>/dev/null; rc=$?
assert_rc "launch引数の実効検証に成功 → rc0（採用）" 0 "$rc"
assert_eq "採用時は生成した surface ref を _XREV_RES_REF に設定する" "surface:42" "$_XREV_RES_REF"

rm -rf "$_crt_bindir"
eval "$_orig_cmux"; eval "$_orig_tree"; eval "$_orig_locate"; eval "$_orig_probe3"; eval "$_orig_proc3"
eval "$_orig_largs"; eval "$_orig_sleep"

# ── xrev_ensure_reviewer のフロー（preflight/classify/create をスタブ）──
_orig_pre="$(declare -f _cmux_preflight)"
_orig_cls="$(declare -f _xrev_classify_reviewer)"
_orig_create="$(declare -f _xrev_create_reviewer)"
_orig_callerws="$(declare -f _xrev_caller_ws)"
_MARK="$(mktemp)"
_cmux_preflight(){ return 0; }
_xrev_caller_ws(){ printf 'ws-test-uuid'; }
_xrev_create_reviewer(){ echo created >> "$_MARK"; _XREV_RES_REF=surface:NEW; return 0; }

# ── 指摘3（2巡目）: reviewer 設定の矛盾検査はペイン生成の副作用より前に行う ──────────
# 従来は xrev_transport_review にしか組み込まれておらず、xrev_ensure_reviewer は矛盾があっても
# _xrev_classify_reviewer（宛先解決・プロセス証明）まで進んでから気づく形だった。ここでは
# classify が一切呼ばれずに rc29 で拒否されることを固定する。
_CLS_CALLS="$(mktemp)"; : > "$_CLS_CALLS"
_xrev_classify_reviewer(){ echo x >> "$_CLS_CALLS"; _XREV_RES_REF=surface:99; return 0; }
_SAVED_REVIEWER="$REVIEWER"; _SAVED_RP_EXPLICIT="$_XREV_REVIEWER_PROCESS_EXPLICIT"
REVIEWER="codex"
_XREV_REVIEWER_PROCESS_EXPLICIT="claude"   # codex/claude のどちらかで解決済み reviewer と矛盾
xrev_ensure_reviewer >/dev/null 2>"$_MARK.err"; rc=$?
assert_rc "reviewer_process矛盾がある場合 → xrev_ensure_reviewerはrc29" 29 "$rc"
assert_eq "矛盾検出は classify(宛先解決) より前に起きる(呼ばれない)" "0" "$(grep -c . "$_CLS_CALLS")"
assert_contains "矛盾ログを出力する" "$(cat "$_MARK.err")" "矛盾"
REVIEWER="$_SAVED_REVIEWER"; _XREV_REVIEWER_PROCESS_EXPLICIT="$_SAVED_RP_EXPLICIT"
rm -f "$_CLS_CALLS" "$_MARK.err"
unset _CLS_CALLS _SAVED_REVIEWER _SAVED_RP_EXPLICIT rc

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
