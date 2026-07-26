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
out="$(XREV_REVIEWER_LAUNCH_ARGS='["--x","y"]' _xrev_reviewer_launch_args codex)"; rc=$?
assert_rc "env override は成功" 0 "$rc"
assert_eq "env override が config より優先される" $'--x\ny' "$out"

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
