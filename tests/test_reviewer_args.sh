#!/usr/bin/env bash
# reviewer read-only 強制の単体テスト（cmux はスタブ不要・純粋ロジック部のみ）。
# _xrev_reviewer_launch_args（launch 引数の型検証・env/config 優先順位）と
# _xrev_reject_unsafe_reviewer_args（sandbox/approval 系フラグの拒否）を検証する。

export XREV_CONFIG="$DEFAULT_CONFIG"
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"

# ── (a) 既定 config で codex → sandbox と承認ポリシーの組 ──────────────────────
# 【この組を崩さないこと】--sandbox read-only は「何ができるか」を縛るだけで、コマンド実行のたびに
# 人間へ承認を求めるかは --ask-for-approval が決める別の軸。承認を既定のままにすると reviewer が
# git diff / tests/run.sh を実行するたびに承認プロンプトで停止し、「人間の操作なしで往復させる」
# という xrev の目的が成立しない（実機で発生。参照モードは必ずこの経路を踏む）。
# never は「承認を求めず失敗はモデルへ返す」であり、read-only サンドボックスはそのまま効いている。
# 逆に sandbox 指定なしで never だけを付けると承認もサンドボックスも無い状態になるため、
# **両方が揃っていること**を検証する。詳細は references/protocol.md。
out="$(_xrev_reviewer_launch_args codex)"; rc=$?
assert_rc "codex: 既定 launch 引数の取得は成功" 0 "$rc"
assert_eq "codex: 既定 launch 引数（sandbox と承認ポリシーの組）" \
  $'--sandbox\nread-only\n--ask-for-approval\nnever' "$out"

# ── (b) 既定 config で claude → --permission-mode / plan ──────────────────────
out="$(_xrev_reviewer_launch_args claude)"; rc=$?
assert_rc "claude: 既定 launch 引数の取得は成功" 0 "$rc"
assert_eq "claude: 既定 launch 引数" $'--permission-mode\nplan' "$out"

# basename を取ってから照合する（フルパス指定でも既定 config の codex 分が引ける）
out="$(_xrev_reviewer_launch_args /usr/local/bin/codex)"; rc=$?
assert_rc "フルパス指定も basename で照合され成功" 0 "$rc"
assert_eq "フルパス指定でも既定 launch 引数" \
  $'--sandbox\nread-only\n--ask-for-approval\nnever' "$out"

# 既定 config の不変条件: codex の launch 引数には sandbox と承認ポリシーが**両方**含まれること
# （片方だけの設定は「承認プロンプトで往復停止」か「無制限実行」のどちらかになる）。
assert_contains "既定 config: sandbox 指定を含む" "$out" "--sandbox"
assert_contains "既定 config: read-only を含む" "$out" "read-only"
assert_contains "既定 config: 承認ポリシー指定を含む" "$out" "--ask-for-approval"
assert_contains "既定 config: 承認ポリシーは never" "$out" "never"

# ── (c) 未知の reviewer（例 foobar）→ 非ゼロ・エラーメッセージに reviewer 名 ────────
err="$(_xrev_reviewer_launch_args foobar 2>&1 1>/dev/null)"; rc=$?
assert_rc "未知reviewer(foobar)は非ゼロ" 1 "$rc"
assert_contains "未知reviewerのエラーに reviewer 名を含む" "$err" "foobar"

# ── (d) config の reviewer_launch_args が配列でなく文字列 → 非ゼロ ────────────────
tmpcfg_d="$(mktemp)"
python3 -c 'import json;d=json.load(open("'"$DEFAULT_CONFIG"'"));d["reviewer_launch_args"]="oops";json.dump(d,open("'"$tmpcfg_d"'","w"))'
err="$(XREV_CONFIG="$tmpcfg_d" _xrev_reviewer_launch_args codex 2>&1 1>/dev/null)"; rc=$?
assert_rc "reviewer_launch_args が文字列は非ゼロ" 1 "$rc"
assert_contains "reviewer_launch_args 不正のエラーメッセージ" "$err" "reviewer_launch_args"
rm -f "$tmpcfg_d"

# ── (e) 配列に数値が混入 → 非ゼロ ────────────────────────────────────────────
tmpcfg_e="$(mktemp)"
python3 -c 'import json;d=json.load(open("'"$DEFAULT_CONFIG"'"));d["reviewer_launch_args"]={"codex":["--sandbox",1]};json.dump(d,open("'"$tmpcfg_e"'","w"))'
err="$(XREV_CONFIG="$tmpcfg_e" _xrev_reviewer_launch_args codex 2>&1 1>/dev/null)"; rc=$?
assert_rc "launch 引数配列に数値混入は非ゼロ" 1 "$rc"
rm -f "$tmpcfg_e"

# ── (f) XREV_REVIEWER_LAUNCH_ARGS が config より優先される ────────────────────
# 【注意】_xrev_reviewer_launch_args は決定した launch 引数そのものを安全ポリシーの意味検証
# （_xrev_verify_effective_policy）に通すため、env override も sandbox=read-only と承認=never を
# 満たす必要がある。ここでは config の既定値に無い要素(--model gpt-5)を付け足し、config より
# 優先されることは示しつつ安全ポリシーは満たす値にする。
out="$(XREV_REVIEWER_LAUNCH_ARGS='["--sandbox","read-only","--ask-for-approval","never","--model","gpt-5"]' _xrev_reviewer_launch_args codex)"; rc=$?
assert_rc "env override は成功" 0 "$rc"
assert_eq "env override が config より優先される" \
  $'--sandbox\nread-only\n--ask-for-approval\nnever\n--model\ngpt-5' "$out"

# ── (g) XREV_REVIEWER_LAUNCH_ARGS が壊れた JSON → 非ゼロ ──────────────────────
err="$(XREV_REVIEWER_LAUNCH_ARGS='not-json' _xrev_reviewer_launch_args codex 2>&1 1>/dev/null)"; rc=$?
assert_rc "env override の壊れたJSONは非ゼロ" 1 "$rc"

# env override も型検証を通る（文字列以外混入・空文字列も拒否）
err="$(XREV_REVIEWER_LAUNCH_ARGS='["--x",2]' _xrev_reviewer_launch_args codex 2>&1 1>/dev/null)"; rc=$?
assert_rc "env override の数値混入は非ゼロ" 1 "$rc"
err="$(XREV_REVIEWER_LAUNCH_ARGS='{"a":1}' _xrev_reviewer_launch_args codex 2>&1 1>/dev/null)"; rc=$?
assert_rc "env override が配列でない(object)は非ゼロ" 1 "$rc"

# ── (h) _xrev_reject_unsafe_reviewer_args: 危険引数は拒否・無害な引数は通過 ────────
_xrev_reject_unsafe_reviewer_args --sandbox danger-full-access; rc=$?
assert_rc "--sandbox danger-full-access は拒否" 64 "$rc"

_xrev_reject_unsafe_reviewer_args --full-auto; rc=$?
assert_rc "--full-auto は拒否" 64 "$rc"

_xrev_reject_unsafe_reviewer_args -a; rc=$?
assert_rc "-a は拒否" 64 "$rc"

# 指摘2: codex の短縮形 -s（拒否リストに無かったため素通りしていた）を拒否リストへ追加。
_xrev_reject_unsafe_reviewer_args -s danger-full-access; rc=$?
assert_rc "-s（短縮形）は拒否" 64 "$rc"

_xrev_reject_unsafe_reviewer_args -sdanger-full-access; rc=$?
assert_rc "-s の結合形式(-sdanger-full-access)は拒否" 64 "$rc"

_xrev_reject_unsafe_reviewer_args --ask-for-approval never; rc=$?
assert_rc "--ask-for-approval は拒否" 64 "$rc"

_xrev_reject_unsafe_reviewer_args --permission-mode bypassPermissions; rc=$?
assert_rc "--permission-mode の後置上書きは拒否" 64 "$rc"

_xrev_reject_unsafe_reviewer_args --model gpt-5; rc=$?
assert_rc "無害な引数列(--model gpt-5)は通過" 0 "$rc"

_xrev_reject_unsafe_reviewer_args; rc=$?
assert_rc "引数無しは通過" 0 "$rc"

# ── (i) 引数に改行や非ASCIIを含む config → 非ゼロ ─────────────────────────────
tmpcfg_i1="$(mktemp)"
python3 -c 'import json;d=json.load(open("'"$DEFAULT_CONFIG"'"));d["reviewer_launch_args"]={"codex":["--sandbox\n","read-only"]};json.dump(d,open("'"$tmpcfg_i1"'","w"))'
err="$(XREV_CONFIG="$tmpcfg_i1" _xrev_reviewer_launch_args codex 2>&1 1>/dev/null)"; rc=$?
assert_rc "改行を含む要素は非ゼロ" 1 "$rc"
rm -f "$tmpcfg_i1"

tmpcfg_i2="$(mktemp)"
python3 -c 'import json;d=json.load(open("'"$DEFAULT_CONFIG"'"));d["reviewer_launch_args"]={"codex":["日本語"]};json.dump(d,open("'"$tmpcfg_i2"'","w"))'
err="$(XREV_CONFIG="$tmpcfg_i2" _xrev_reviewer_launch_args codex 2>&1 1>/dev/null)"; rc=$?
assert_rc "非ASCIIを含む要素は非ゼロ" 1 "$rc"
rm -f "$tmpcfg_i2"

# 空文字列の要素も拒否する（型検証の一部）
tmpcfg_i3="$(mktemp)"
python3 -c 'import json;d=json.load(open("'"$DEFAULT_CONFIG"'"));d["reviewer_launch_args"]={"codex":[""]};json.dump(d,open("'"$tmpcfg_i3"'","w"))'
err="$(XREV_CONFIG="$tmpcfg_i3" _xrev_reviewer_launch_args codex 2>&1 1>/dev/null)"; rc=$?
assert_rc "空文字列の要素は非ゼロ" 1 "$rc"
rm -f "$tmpcfg_i3"

# ── (j) 指摘1: config/env の意味検証 ────────────────────────────────────────
# launch 引数の型検証を通っても、安全なポリシー（sandbox=read-only かつ承認=never）を満たさない
# config/env は _xrev_reviewer_launch_args 自体が拒否する（自動生成経路がそのまま起動しないため）。
err="$(XREV_REVIEWER_LAUNCH_ARGS='[]' _xrev_reviewer_launch_args codex 2>&1 1>/dev/null)"; rc=$?
assert_rc "env override が空配列は非ゼロ（意味検証で拒否）" 1 "$rc"
assert_contains "空配列拒否のエラーに reviewer 名を含む" "$err" "codex"

err="$(XREV_REVIEWER_LAUNCH_ARGS='["--sandbox","danger-full-access"]' _xrev_reviewer_launch_args codex 2>&1 1>/dev/null)"; rc=$?
assert_rc "env override が danger-full-access は非ゼロ（意味検証で拒否）" 1 "$rc"

tmpcfg_j1="$(mktemp)"
python3 -c 'import json;d=json.load(open("'"$DEFAULT_CONFIG"'"));d["reviewer_launch_args"]={"codex":[]};json.dump(d,open("'"$tmpcfg_j1"'","w"))'
err="$(XREV_CONFIG="$tmpcfg_j1" _xrev_reviewer_launch_args codex 2>&1 1>/dev/null)"; rc=$?
assert_rc "config の codex launch 引数が空配列は非ゼロ（意味検証で拒否）" 1 "$rc"
rm -f "$tmpcfg_j1"

tmpcfg_j2="$(mktemp)"
python3 -c 'import json;d=json.load(open("'"$DEFAULT_CONFIG"'"));d["reviewer_launch_args"]={"codex":["--sandbox","workspace-write","--ask-for-approval","never"]};json.dump(d,open("'"$tmpcfg_j2"'","w"))'
err="$(XREV_CONFIG="$tmpcfg_j2" _xrev_reviewer_launch_args codex 2>&1 1>/dev/null)"; rc=$?
assert_rc "config の codex launch 引数が workspace-write は非ゼロ（意味検証で拒否）" 1 "$rc"
rm -f "$tmpcfg_j2"

# ── (k) _xrev_verify_effective_policy（最終 argv の意味検証。正典）の単体テスト ──────

# 不具合A回帰防止: 合格時は stdout に何も書かない（終了コードのみで成否を表現する契約）。
# 【背景】以前はここで stdout に "ok" を書いており、この関数を stdout がそのまま結果チャネルに
# なる経路（xrev_transport_review）から呼び出す箇所でリダイレクトが漏れて "ok" が review JSON の
# 手前に混入し、JSON パース失敗（decision=invalid）を実機で起こした。原因は「呼び出し側の
# リダイレクト漏れ」ではなく本関数が stdout を結果チャネルとして使っていたことなので、
# 合格時に完全に無出力であることをこの関数自体の契約として固定する。
out="$(_xrev_verify_effective_policy codex --sandbox read-only --ask-for-approval never)"; rc=$?
assert_rc "policy: 合格時のrcは0" 0 "$rc"
assert_eq "policy: 合格時に stdout へ何も書かない(codex)" "" "$out"

out="$(_xrev_verify_effective_policy claude --permission-mode plan)"; rc=$?
assert_rc "policy: 合格時のrcは0(claude)" 0 "$rc"
assert_eq "policy: 合格時に stdout へ何も書かない(claude)" "" "$out"

# 合格: 長形式・=形式・短縮形・結合形式のいずれでも sandbox=read-only かつ承認=never なら合格。
_xrev_verify_effective_policy codex --sandbox read-only --ask-for-approval never >/dev/null
assert_rc "policy: 長形式(空白区切り)は合格" 0 "$?"

_xrev_verify_effective_policy codex --sandbox=read-only --ask-for-approval=never >/dev/null
assert_rc "policy: =形式は合格" 0 "$?"

_xrev_verify_effective_policy codex -s read-only -a never >/dev/null
assert_rc "policy: 短縮形(空白区切り)は合格" 0 "$?"

_xrev_verify_effective_policy codex -sread-only -anever >/dev/null
assert_rc "policy: 短縮形の結合形式は合格" 0 "$?"

# 拒否: 空配列・片方のみ指定
_xrev_verify_effective_policy codex >/dev/null 2>&1
assert_rc "policy: 空配列は拒否" 1 "$?"

_xrev_verify_effective_policy codex --sandbox read-only >/dev/null 2>&1
assert_rc "policy: sandbox のみは拒否" 1 "$?"

_xrev_verify_effective_policy codex --ask-for-approval never >/dev/null 2>&1
assert_rc "policy: approval のみは拒否" 1 "$?"

# 拒否: 安全でない実効値
_xrev_verify_effective_policy codex --sandbox workspace-write --ask-for-approval never >/dev/null 2>&1
assert_rc "policy: sandbox=workspace-write は拒否" 1 "$?"

_xrev_verify_effective_policy codex --sandbox danger-full-access --ask-for-approval never >/dev/null 2>&1
assert_rc "policy: sandbox=danger-full-access は拒否" 1 "$?"

# 拒否（指摘2の攻撃）: 安全な組の後ろに危険な sandbox を後置（短縮形・結合形式いずれも）。
# 「同じ軸の指定が複数回現れたら、たとえ最後が安全でも拒否」という fail closed 方針を検証する。
_xrev_verify_effective_policy codex --sandbox read-only --ask-for-approval never -s danger-full-access \
  >/dev/null 2>&1
assert_rc "policy: 安全な組の後に -s danger-full-access を後置は拒否" 1 "$?"

_xrev_verify_effective_policy codex --sandbox read-only --ask-for-approval never -sdanger-full-access \
  >/dev/null 2>&1
assert_rc "policy: 安全な組の後に結合形式(-sdanger-full-access)を後置は拒否" 1 "$?"

# 拒否: 同じ軸の複数指定（どちらも安全な値であっても曖昧さを許さず拒否）
_xrev_verify_effective_policy codex --sandbox read-only --sandbox read-only --ask-for-approval never \
  >/dev/null 2>&1
assert_rc "policy: sandbox の複数指定は最後が安全でも拒否" 1 "$?"

# 拒否: サンドボックス/承認を丸ごと外すフラグ（完全一致）
_xrev_verify_effective_policy codex --dangerously-bypass-approvals-and-sandbox >/dev/null 2>&1
assert_rc "policy: --dangerously-bypass-approvals-and-sandbox は拒否" 1 "$?"

_xrev_verify_effective_policy codex --sandbox read-only --ask-for-approval never --full-auto \
  >/dev/null 2>&1
assert_rc "policy: --full-auto の混在は拒否" 1 "$?"

_xrev_verify_effective_policy codex --sandbox read-only --ask-for-approval never --yolo \
  >/dev/null 2>&1
assert_rc "policy: --yolo の混在は拒否" 1 "$?"

# 拒否: 値なしの末尾（切れている）
_xrev_verify_effective_policy codex --ask-for-approval never --sandbox >/dev/null 2>&1
assert_rc "policy: 値なしの末尾(--sandbox)は拒否" 1 "$?"

# 拒否: 未知の reviewer 種別
_xrev_verify_effective_policy foobar --sandbox read-only --ask-for-approval never >/dev/null 2>&1
assert_rc "policy: 未知reviewer(foobar)は拒否" 1 "$?"

# claude: --permission-mode の実効値のみで判定
_xrev_verify_effective_policy claude --permission-mode plan >/dev/null
assert_rc "policy(claude): permission-mode=plan は合格" 0 "$?"

_xrev_verify_effective_policy claude --permission-mode acceptEdits >/dev/null 2>&1
assert_rc "policy(claude): permission-mode=acceptEdits は拒否" 1 "$?"

_xrev_verify_effective_policy claude --permission-mode=plan >/dev/null
assert_rc "policy(claude): =形式でも合格" 0 "$?"

_xrev_verify_effective_policy claude --permission-mode plan --permission-mode plan >/dev/null 2>&1
assert_rc "policy(claude): 複数指定は最後が安全でも拒否" 1 "$?"
