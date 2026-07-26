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
# 不具合B対応（TOCTOU）: 上記3点は `_xrev_gate_reviewer` を経由し、プロセス証明
# （`_verify_reviewer_process`）と安全ポリシー実効検証（`_xrev_verify_reviewer_policy`）を
# **必ず同じゲートで一緒に**行う。どちらか一方だけを検証してもう一方が古いまま、という
# 構造的な穴を作らないことをここで固定する（プロセス名は一致し続けるがポリシーだけが途中から
# 崩れるケースを台本で作り、各ゲートで rc27 になることを検証する）。
#
# 純粋判定（_decide_foreground_owner）のテストは test_ws_scoped.sh にある。ここで固定するのは
# **どの時点で検証が走り、失敗したとき何を「しない」か**という制御フロー。実装の行番号ではなく
# 「send が呼ばれたか」「submit が呼ばれたか」という外部作用の有無と順序だけを見るので、
# ゲートが移動・削除されればこのテストが落ちる。
#
# 不具合A対応（stdoutの契約）: xrev_transport_review の stdout は「reviewer の review JSON
# だけ」を返す契約であることも固定する（検証系の関数が stdout に何か書いてしまう回帰があると
# review-loop 側の JSON パースが壊れた実績があるため）。
#
# cmux 非依存: 配管の入出力はすべてスタブし、検証結果の並びを台本で与える。

export XREV_CONFIG="$DEFAULT_CONFIG"
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"

# ── _verify_reviewer_process の観測リトライ（実装の本体をそのまま検証）────────────
#
# 【この節が守る仕様】cmux の surface 直下には周期的に消滅する sleep サイドカーが存在し、
# top 取得と ps 取得の間にそれが消えると「欠落」判定で拒否される（詳細は docs/cmux-behavior.md
# の「過渡プロセス（sleep サイドカー）の消滅による観測不一致」）。対処は判定条件を緩めることでは
# なく、top/ps を最初から取り直して最大3回まで試行し直すことだけ。ここでは _decide_foreground_owner
# はスタブせず本物を使い、_cmux_top_processes / _ps_snapshot だけを呼び出し回数で切り替えて
# スタブすることで「取り直しの回数」を検証する（test_ws_scoped.sh のスタブ手法を流用）。
_xrev_sleep() { :; }  # リトライ間の待ちを無効化（テストを遅くしない）

# 【注意】_verify_reviewer_process は _cmux_top_processes / _ps_snapshot をコマンド置換
# ("$(...)" やパイプライン)経由で呼ぶため、呼び出しはサブシェルで実行される。ふつうの変数
# インクリメントはサブシェル内で完結して親シェルへ戻らないので、呼び出し回数はファイルに
# 記録して数える（bash+python3 のみという依存方針は変えない。中間ファイルは repo 外の
# 一時領域に置き、このテストの最後に削除する）。
# 【移植性】mktemp -t <接頭辞> は macOS では通るが GNU coreutils(Linux) はテンプレートに
# XXXXXX を要求して失敗する（ubuntu CI だけ空パスになり全アサートが崩れた）。両対応の
# 明示テンプレート形式を使う。
_sg_call_file="$(mktemp "${TMPDIR:-/tmp}/xrev_sg_calls.XXXXXX")"
_sg_reset_calls() { printf '0' > "$_sg_call_file"; }
_sg_call_count() { cat "$_sg_call_file"; }
_sg_top_script=()   # 呼び出し順に返す top TSV の台本
_sg_ps_script=()    # 呼び出し順に返す ps 出力の台本（top と対で消費する）
_cmux_top_processes() {
  local n; n=$(( $(cat "$_sg_call_file") + 1 ))
  printf '%s' "$n" > "$_sg_call_file"
  printf '%s' "${_sg_top_script[$(( n - 1 ))]:-}"
}
_ps_snapshot() {
  cat >/dev/null
  local n; n="$(cat "$_sg_call_file")"
  printf '%s' "${_sg_ps_script[$(( n - 1 ))]:-}"
}
_sg_mk_top() { # 引数: "PID:name,PID:name,..." → surface:9 直下の top TSV
  local procs="$1" p
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 0.0 1 1 surface surface:9 pane:1 title
  IFS=','; for p in $procs; do
    [[ -n "$p" ]] && printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 0.0 1 1 process "${p%%:*}" surface:9 "${p#*:}"
  done; unset IFS
}
_sg_mk_ps() { local r; for r in "$@"; do printf '%s\n' "$r"; done; }  # "pid pgid tpgid comm"

# 実機形状（test_ws_scoped.sh の実測 fixture を踏襲）: codex=前景(pgid==tpgid), sleep=別pgid,
# zsh=ログインシェル。sleep が消える前後で top/ps の直下集合が変わる想定。
_SG_TOP_WITH_SLEEP="$(_sg_mk_top "4728:codex,13900:sleep,1489:zsh")"
_SG_TOP_NO_SLEEP="$(_sg_mk_top "4728:codex,1489:zsh")"
# codex+zsh の2件分の ps 出力。top 側が3件(sleep含む)のときに渡すと「sleep が欠落」の不一致に、
# top 側が2件(sleep なし)のときに渡すと「過不足なく一致」になる（同じ ps 出力を両方の意味で使う）。
_SG_PS_CODEX_ZSH_ONLY="$(_sg_mk_ps "4728 4728 4728 /Users/x/.local/bin/codex" \
                                    "1489 1489 4728 -/bin/zsh")"

# 1) 1回目=top:sleepあり/ps:sleep欠落(不一致) → リトライ → 2回目=top:sleepなし/ps一致 → 許可。
#    top 取得が2回であること＝観測を最初から取り直していることの確認。
_sg_reset_calls
_sg_top_script=("$_SG_TOP_WITH_SLEEP" "$_SG_TOP_NO_SLEEP")
_sg_ps_script=("$_SG_PS_CODEX_ZSH_ONLY" "$_SG_PS_CODEX_ZSH_ONLY")
_verify_reviewer_process "surface:9"
assert_rc "1回目不一致→2回目一致で許可(rc0)" 0 "$?"
assert_eq "取り直しにより top 取得は2回" "2" "$(_sg_call_count)"

# 2) 3回とも不一致 → 拒否(非0)。top 取得は3回で打ち切り、4回目は起きない。
_sg_reset_calls
_sg_top_script=("$_SG_TOP_WITH_SLEEP" "$_SG_TOP_WITH_SLEEP" "$_SG_TOP_WITH_SLEEP")
_sg_ps_script=("$_SG_PS_CODEX_ZSH_ONLY" "$_SG_PS_CODEX_ZSH_ONLY" "$_SG_PS_CODEX_ZSH_ONLY")
_verify_reviewer_process "surface:9" 2>/dev/null
assert_rc "3回とも不一致→拒否(rc1)" 1 "$?"
assert_eq "3回で打ち切り(4回目は呼ばれない)" "3" "$(_sg_call_count)"

# 3) 1回目から一致 → 許可(rc0)。成功時は余計な取り直しをしない(top 取得は1回のみ)。
_sg_reset_calls
_sg_top_script=("$_SG_TOP_NO_SLEEP")
_sg_ps_script=("$_SG_PS_CODEX_ZSH_ONLY")
_verify_reviewer_process "surface:9"
assert_rc "1回目から一致→許可(rc0)" 0 "$?"
assert_eq "成功時は取り直さず top 取得は1回のみ" "1" "$(_sg_call_count)"

# 元の実装へ戻す（以降のスタブ定義・他テストへ漏らさない）。
rm -f "$_sg_call_file"
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"
unset -f _sg_mk_top _sg_mk_ps _sg_reset_calls _sg_call_count
unset _sg_call_file _sg_top_script _sg_ps_script \
      _SG_TOP_WITH_SLEEP _SG_TOP_NO_SLEEP _SG_PS_CODEX_ZSH_ONLY

# ── スタブ群（このファイルの最後に transport.sh を読み直して元に戻す）──────────────
_SG_CALLS=""                      # 外部作用の記録（"send submit" のように順に積む）
_SG_VP_SEQ=()                     # _verify_reviewer_process の戻り値台本（0=許可 / 1=拒否）
_SG_VP_I=0                        # 台本の消費位置
_SG_POL_SEQ=()                    # _xrev_verify_reviewer_policy の戻り値台本（呼び出し順。
                                   # 空なら常に0=成功。不具合Bのゲート統合テストで使う）
_SG_POL_I=0                       # 台本の消費位置

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
# 指摘3(変更2)/不具合B: 送信前の安全ポリシー実効検証。台本(_SG_POL_SEQ)が空のときは常に「安全」
# （0）を返し、本ファイルの対象であるプロセス証明ゲートの順序・回数の検証に影響させない。
# 台本を仕込んだときは呼び出し順に消費する（不具合B: プロセス証明と同じゲートで毎回再検証される
# ことを検証するため、呼び出し回数そのものが意味を持つ）。
_xrev_verify_reviewer_policy() {
  if (( ${#_SG_POL_SEQ[@]} == 0 )); then return 0; fi
  local r="${_SG_POL_SEQ[$_SG_POL_I]:-0}"
  _SG_POL_I=$(( _SG_POL_I + 1 ))
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
  _SG_VP_SEQ=("$@"); _SG_VP_I=0; _SG_POL_I=0; _SG_CALLS=""
  xrev_transport_review "テスト用 payload" >/dev/null 2>&1
  _SG_RC=$?
}

# _sg_run と同じ台本仕込みだが、stdout と stderr を別々に残す（不具合Aのstdout純度確認・
# 不具合Bの汚染ペイン警告確認で使う）。
# 【注意】$(...) コマンド置換はサブシェルを作るため、その中で xrev_transport_review を呼ぶと
# _SG_CALLS/_SG_VP_I/_SG_POL_I への書き込みが親シェルへ戻らない（本ファイル冒頭の
# 「_verify_reviewer_process の観測リトライ」節と同じ注意点）。単純コマンドへのリダイレクトは
# サブシェルを作らないため、一時ファイル2本（リポジトリ外・テスト内で必ず削除）を介して
# stdout/stderr を分離することでこれを避ける。
_sg_run_capture() {
  _SG_VP_SEQ=("$@"); _SG_VP_I=0; _SG_POL_I=0; _SG_CALLS=""
  local _sg_outfile _sg_errfile
  _sg_outfile="$(mktemp "${TMPDIR:-/tmp}/xrev_sg_stdout.XXXXXX")"
  _sg_errfile="$(mktemp "${TMPDIR:-/tmp}/xrev_sg_stderr.XXXXXX")"
  xrev_transport_review "テスト用 payload" >"$_sg_outfile" 2>"$_sg_errfile"
  _SG_RC=$?
  _SG_STDOUT="$(cat "$_sg_outfile")"
  _SG_STDERR="$(cat "$_sg_errfile")"
  rm -f "$_sg_outfile" "$_sg_errfile"
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

# 6) wire_max_chars（変更2: fail closed）: エンコード後の wire が上限を超えたら rc26 で中止し、
#    cmux へは一切送信しない（send/submit いずれも呼ばれない）。巨大 payload を実際に作らずに
#    検証するため、上限そのものを小さく差し替え、_build_framed_line のスタブ出力を上限超にする。
_SG_SAVED_MAX="$WIRE_MAX_CHARS"
WIRE_MAX_CHARS=1000
_build_framed_line() { printf 'x%.0s' {1..2000}; }
_sg_run 0 0 0
assert_rc   "wire 上限超 → rc26" 26 "$_SG_RC"
assert_eq   "wire 上限超 → send も submit も呼ばれない" "" "$_SG_CALLS"
WIRE_MAX_CHARS="$_SG_SAVED_MAX"
_build_framed_line() { printf 'FRAMED_LINE_FOR_TEST'; }

# 7) 変更1: 完成しているが壊れた応答（実機で観測したバグ）→ タイムアウトを待たず即座に rc24。
#    _scan_review_blocks は「妥当な応答なし」を返すよう固定し、_cmux_read_screen は
#    submit 前は空・submit 後は「センチネルは揃っているが JSON 文字列値に生の二重引用符を含む
#    壊れた応答」を返す（_scan_broken_blocks はスタブせず本物を使う）。submit 前後で画面を
#    変えるのは、before_broken のベースライン取得時点で既に broken=1 だと「新着」判定が
#    成立せずポーリングがタイムアウトまで回り続けてしまうため。RESP_TIMEOUT を十分大きく・
#    直接代入し、それでもタイムアウト(180s既定)まで待たずに返ることを確認する。
_SG_SAVED_TIMEOUT="$RESP_TIMEOUT"; _SG_SAVED_POLL="$RESP_POLL"; _SG_SAVED_SETTLE="$SETTLE_SECS"
RESP_TIMEOUT=100000    # 意図的に巨大値。もしタイムアウト待ちに落ちればテストがハングして検知できる。
RESP_POLL=1
SETTLE_SECS=0
XREV_ROUND_ID="rBROKEN"
_scan_review_blocks() { printf '0'; }  # 妥当な応答は一切無い（常に新着0件）
_SG_BROKEN_SCREEN="$SENTINEL_BEGIN"$'\n{"round_id":"rBROKEN","verdict":"approve","findings":[{"file":"a","severity":"high","category":"bug","message":"彼は"だめ"と言った"}]}\n'"$SENTINEL_END"
_cmux_read_screen() {
  case "$_SG_CALLS" in
    *submit*) printf '%s' "$_SG_BROKEN_SCREEN" ;;
    *)        printf '' ;;
  esac
}
_sg_run 0 0 0
assert_rc "壊れた完成応答 → rc24（invalid_response）" 24 "$_SG_RC"
assert_eq "壊れた完成応答でも send/submit は正常に完了している" " send submit" "$_SG_CALLS"
RESP_TIMEOUT="$_SG_SAVED_TIMEOUT"; RESP_POLL="$_SG_SAVED_POLL"; SETTLE_SECS="$_SG_SAVED_SETTLE"
unset XREV_ROUND_ID _SG_BROKEN_SCREEN
_scan_review_blocks() {
  case "$_SG_CALLS" in
    *submit*) printf '1\n{"round_id":"x","verdict":"approve","findings":[]}' ;;
    *)        printf '0' ;;
  esac
}
_cmux_read_screen() { printf ''; }

# 8) 変更1: Enter 送信(send-key)が常に失敗する → 最大2回まで再試行し、全滅したら rc25 で
#    応答待ちループに入らない（RESP_TIMEOUT を巨大値にしてもすぐ返ることで確認する。手法は
#    上の rBROKEN テストと同じ：もし誤って応答待ちへ落ちればテストがハングして検知できる）。
#    再試行の直前は必ずプロセス証明を再実行する契約なので、台本は5回分(iii/iii-b/iii-c/
#    retry1前/retry2前)すべて許可(0)にし、send-key(=_cmux_submit)の失敗だけで rc25 に
#    倒れることを検証する。
_SG_SUBMIT_COUNT=0
_cmux_submit() { _SG_SUBMIT_COUNT=$(( _SG_SUBMIT_COUNT + 1 )); _SG_CALLS="$_SG_CALLS submit"; return 1; }
_SG_SAVED_RESP_TIMEOUT="$RESP_TIMEOUT"
RESP_TIMEOUT=100000
_sg_run 0 0 0 0 0
assert_rc "Enter送信が全滅 → rc25（submit_failed、timeoutとは別コード）" 25 "$_SG_RC"
assert_eq "Enter送信が全滅 → send-key は計3回(初回+再試行2回)呼ばれる" "3" "$_SG_SUBMIT_COUNT"
RESP_TIMEOUT="$_SG_SAVED_RESP_TIMEOUT"

# 9) 変更1: Enter 送信が失敗し、かつ再試行前のプロセス証明で前景が変化（codex が死んで
#    shell に落ちた等）→ 安全条件（前景が codex のままのときだけ再送してよい）により
#    Enter を再送せず、既存の (iii-c) 最終ゲート失敗と同じ汚染ペイン扱い(rc17)にする。
#    台本: (iii)=許可 (iii-b)=許可 (iii-c初回)=許可 → ここで初回 send-key 失敗 →
#    再試行直前の検証(4回目)=拒否 → Enter は1回しか呼ばれない。
_SG_SUBMIT_COUNT=0
_cmux_submit() { _SG_SUBMIT_COUNT=$(( _SG_SUBMIT_COUNT + 1 )); _SG_CALLS="$_SG_CALLS submit"; return 1; }
_sg_run 0 0 0 1
assert_rc "Enter送信失敗+再試行前に前景変化 → rc17（汚染ペイン扱い）" 17 "$_SG_RC"
assert_eq "Enter送信失敗+前景変化 → 再送せず送信は初回の1回だけ" "1" "$_SG_SUBMIT_COUNT"

_cmux_submit() { _SG_CALLS="$_SG_CALLS submit"; return 0; }
unset _SG_SUBMIT_COUNT _SG_SAVED_RESP_TIMEOUT

# 10) 変更2(指摘3): 既存 reviewer が安全ポリシー（read-only+承認never）の実効検証(iii')に
#     不合格 → プロセス証明(iii)の直後、payload 構築の前に rc27 で中止する（send/submit いずれも
#     呼ばれない）。XREV_ALLOW_UNVERIFIED_REVIEWER=1（明示 opt-in）のときだけ検証を省略して
#     通常どおり続行する（手動運用を壊さないための後方互換）。
_xrev_verify_reviewer_policy() { return 1; }
_sg_run 0 0 0
assert_rc "安全ポリシー不合格 → rc27" 27 "$_SG_RC"
assert_eq "安全ポリシー不合格 → send も submit も呼ばれない" "" "$_SG_CALLS"

XREV_ALLOW_UNVERIFIED_REVIEWER=1 _sg_run 0 0 0
assert_rc "opt-out env → 安全ポリシー不合格でも続行(rc0)" 0 "$_SG_RC"
assert_eq "opt-out env → send/submit は通常どおり実行される" " send submit" "$_SG_CALLS"

# 台本消費型の既定スタブへ戻す（以降のテストで _SG_POL_SEQ を使えるようにする）。
_xrev_verify_reviewer_policy() {
  if (( ${#_SG_POL_SEQ[@]} == 0 )); then return 0; fi
  local r="${_SG_POL_SEQ[$_SG_POL_I]:-0}"
  _SG_POL_I=$(( _SG_POL_I + 1 ))
  return "$r"
}

# 11) 不具合B(TOCTOU): プロセス名は一貫して許可されるが、2回目以降（本文送信直前 (iii-b)）の
#     安全ポリシー検証だけが不合格になるケース。初回検証後に reviewer が終了し、同名だが
#     書き込み可能な reviewer へ挿げ替わった状況を模す。プロセス証明とポリシー検証を同じゲートで
#     毎回まとめて検証していれば、(iii-b) の時点で rc27 になり、本文送信(_cmux_send_line)も
#     Enter(_cmux_submit)も一切呼ばれないはず（本文が入力欄に渡る前に止まる）。
_SG_POL_SEQ=(0 1)
_sg_run 0 0 0
assert_rc "(iii-b)でポリシーだけ不合格 → rc27" 27 "$_SG_RC"
assert_eq "(iii-b)不合格 → send も submit も呼ばれない" "" "$_SG_CALLS"
_SG_POL_SEQ=()

# 12) 不具合B(TOCTOU): 3回目（Enter直前の最終ゲート (iii-c)）でだけ安全ポリシーが不合格になる
#     ケース → rc27。本文(_cmux_send_line)は送信済みだが Enter(_cmux_submit)は呼ばれず、
#     プロセス不一致のときと同じ汚染ペイン警告（_xrev_log_tainted_pane）が出ること。
_SG_POL_SEQ=(0 0 1)
_sg_run_capture 0 0 0
assert_rc "(iii-c)でポリシーだけ不合格 → rc27" 27 "$_SG_RC"
assert_eq "(iii-c)不合格 → send のみで submit は呼ばれない" " send" "$_SG_CALLS"
assert_contains "(iii-c)不合格 → 汚染ペイン警告が出る" "$_SG_STDERR" "汚染されたものとして扱ってください"
_SG_POL_SEQ=()

# 13) 不具合B: ポリシー検証が全ゲートで成功する正常系では、ポリシー検証の呼び出し回数は
#     プロセス証明と同数（3回）になること＝プロセス証明とポリシー検証が常に同じゲートで
#     一緒に呼ばれている（片方だけを間引く変更を検知できる）ことの確認。
#     （台本を明示的に3件与える。空配列は「常に成功」だが呼び出し回数を数えないショートカットに
#     なるため、ここでは回数そのものを検証したいので使わない。）
_SG_POL_SEQ=(0 0 0)
_sg_run 0 0 0
assert_rc "全ゲート成功（ポリシー込み） → rc0" 0 "$_SG_RC"
assert_eq "ポリシー検証もプロセス証明と同じ3回走る" "3" "$_SG_POL_I"
assert_eq "プロセス証明とポリシー検証の呼び出し回数が一致" "$_SG_VP_I" "$_SG_POL_I"
_SG_POL_SEQ=()

# 14) 不具合B: XREV_ALLOW_UNVERIFIED_REVIEWER=1 のときは安全ポリシー検証そのものを一切呼ばない
#     （プロセス証明は従来どおり実施する）。かつ、ゲートは1往復で最大3回（(iii)/(iii-b)/(iii-c)）
#     呼ばれるが、opt-out の警告ログは1往復につき1回だけ出ること（毎ゲートで出さない）。
XREV_ALLOW_UNVERIFIED_REVIEWER=1 _sg_run_capture 0 0 0
assert_rc "opt-out env → 完走(rc0)" 0 "$_SG_RC"
assert_eq "opt-out env → send/submit は通常どおり実行される" " send submit" "$_SG_CALLS"
assert_eq "opt-out env → 安全ポリシー検証そのものが呼ばれない" "0" "$_SG_POL_I"
_SG_WARN_COUNT="$(printf '%s\n' "$_SG_STDERR" | grep -c 'XREV_ALLOW_UNVERIFIED_REVIEWER=1 のため')"
assert_eq "opt-out env → 警告ログは1往復につき1回だけ" "1" "$_SG_WARN_COUNT"
unset _SG_WARN_COUNT

# 15) 不具合A回帰防止（実機で発生: 検証関数の"ok"がtransportのstdoutを汚染し、review-loopの
#     JSONパースが失敗する事故が起きた）: xrev_transport_review の成功経路で stdout に
#     「review JSON のみ」が出ることを検証する。前後に余分な文字（例: 検証関数の"ok"漏れ）が
#     付いていれば json.loads が例外を投げ、PARSE_OK が出力されない形で落ちる。将来また別の
#     関数が stdout を汚しても検出できるよう、返り値そのものをパースして確認する。
_sg_run_capture 0 0 0
assert_rc "stdout純度確認: 成功経路は rc0" 0 "$_SG_RC"
_SG_PURITY_PARSED="$(printf '%s' "$_SG_STDOUT" | python3 -c 'import json,sys
json.loads(sys.stdin.read())
print("PARSE_OK")' 2>/dev/null)"
assert_eq "stdout純度確認: stdout は review JSON のみでパース可能" "PARSE_OK" "$_SG_PURITY_PARSED"
unset _SG_PURITY_PARSED

# ── 後片付け: 実体を読み直してスタブを捨てる（後続の test_*.sh へ漏らさない）────────
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"
unset _SG_CALLS _SG_VP_SEQ _SG_VP_I _SG_POL_SEQ _SG_POL_I _SG_RC _SG_STDOUT _SG_STDERR \
      _SG_SAVED_MAX _SG_SAVED_TIMEOUT _SG_SAVED_POLL _SG_SAVED_SETTLE
