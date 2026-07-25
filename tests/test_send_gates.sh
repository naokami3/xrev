#!/usr/bin/env bash
#
# test_send_gates.sh — 送信経路のプロセス証明ゲートを「外部作用の順序」で検証する。
#
# 【このテストが守る仕様】
# xrev_transport_review は前景プロセスの検証を 3 点で行う:
#   (iii)   payload 構築前の早期棄却
#   (iii-b) 本文送信（_cmux_send_line）の直前
#   (iii-c) 確定入力（_cmux_submit = Enter）の直前 ← 安全目標の最終ゲート
#
# 純粋判定（_decide_foreground_owner）のテストは test_ws_scoped.sh にある。ここで固定するのは
# **どの時点で検証が走り、失敗したとき何を「しない」か**という制御フロー。実装の行番号ではなく
# 「send が呼ばれたか」「submit が呼ばれたか」という外部作用の有無と順序だけを見るので、
# ゲートが移動・削除されればこのテストが落ちる。
#
# cmux 非依存: 配管の入出力はすべてスタブし、検証結果の並びを台本で与える。

export XREV_CONFIG="$DEFAULT_CONFIG"
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"

# ── スタブ群（このファイルの最後に transport.sh を読み直して元に戻す）──────────────
_SG_CALLS=""                      # 外部作用の記録（"send submit" のように順に積む）
_SG_VP_SEQ=()                     # _verify_reviewer_process の戻り値台本（0=許可 / 1=拒否）
_SG_VP_I=0                        # 台本の消費位置

_cmux_preflight() { return 0; }
# uuid を空にして (i) の WS 再検証ブロックを迂回する（そこは別テストの担当）。
_cmux_resolve_surface() {
  _XREV_RES_REF="surface:9"; _XREV_RES_UUID=""; _XREV_RES_WS=""
  _XREV_RES_PATH="global"; _XREV_RES_SAMEWS=0
  printf '%s' "$_XREV_RES_REF"; return 0
}
_probe_terminal_usable() { printf 'usable'; }
_verify_reviewer_process() {
  local r="${_SG_VP_SEQ[$_SG_VP_I]:-0}"
  _SG_VP_I=$(( _SG_VP_I + 1 ))
  return "$r"
}
_detect_content_type() { printf 'plain'; }
_build_framed_line() { printf 'FRAMED_LINE_FOR_TEST'; }
_cmux_read_screen() { printf ''; }
# submit 済みなら「新着1件」を返す。応答待ちループを抜けさせると同時に、
# submit より前に応答が観測されないこと（＝順序）も担保する。
_scan_review_blocks() {
  case "$_SG_CALLS" in
    *submit*) printf '1\n{"round_id":"x","verdict":"approve","findings":[]}' ;;
    *)        printf '0' ;;
  esac
}
_cmux_send_line() { _SG_CALLS="$_SG_CALLS send"; return 0; }
_cmux_submit()    { _SG_CALLS="$_SG_CALLS submit"; return 0; }
_check_paste_intact() { printf 'ok'; }
_compute_submit_settle() { printf '0'; }
_xrev_sleep() { :; }

# 台本を仕込んで 1 回走らせ、rc と外部作用の記録を返すヘルパ。
_sg_run() {
  _SG_VP_SEQ=("$@"); _SG_VP_I=0; _SG_CALLS=""
  xrev_transport_review "テスト用 payload" >/dev/null 2>&1
  _SG_RC=$?
}

# 1) 全ゲート通過: send → submit がこの順で各1回だけ起きる。
_sg_run 0 0 0
assert_rc   "全ゲート通過 → rc0" 0 "$_SG_RC"
assert_eq   "全ゲート通過 → send の次に submit（順序と回数）" " send submit" "$_SG_CALLS"

# 2) (iii) で拒否: payload を組む前に止まる。送信も確定入力も起きない。
_sg_run 1 0 0
assert_rc   "(iii) 拒否 → rc17" 17 "$_SG_RC"
assert_eq   "(iii) 拒否 → send も submit も呼ばれない" "" "$_SG_CALLS"

# 3) (iii-b) で拒否: 本文を一切送らずに止まる（入力欄を汚さない）。
_sg_run 0 1 0
assert_rc   "(iii-b) 拒否 → rc17" 17 "$_SG_RC"
assert_eq   "(iii-b) 拒否 → 本文は送信されない" "" "$_SG_CALLS"

# 4) (iii-c) で拒否: 本文は送信済みだが **Enter は送らない**。安全目標の核。
_sg_run 0 0 1
assert_rc   "(iii-c) 拒否 → rc17" 17 "$_SG_RC"
assert_eq   "(iii-c) 拒否 → send のみで submit は呼ばれない" " send" "$_SG_CALLS"

# 5) 検証は 3 回呼ばれる（ゲートを減らす変更を検知する）。
_sg_run 0 0 0
assert_eq   "プロセス証明は 1 往復で 3 回走る" "3" "$_SG_VP_I"

# ── 後片付け: 実体を読み直してスタブを捨てる（後続の test_*.sh へ漏らさない）────────
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"
unset _SG_CALLS _SG_VP_SEQ _SG_VP_I _SG_RC
