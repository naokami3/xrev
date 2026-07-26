#!/usr/bin/env bash
#
# test_reviewer_bin.sh — C1: reviewer バイナリ解決の一般化（_xrev_reviewer_bin）。
#
# 解決優先順: 1) XREV_REVIEWER_BIN（新設 env・最優先）
#            2) XREV_CODEX_BIN（後方互換のエイリアス。config の reviewer が codex のときのみ有効。
#               reviewer が codex 以外なのに指定されていたら stderr に1行警告して無視する）
#            3) config の reviewer 値（バイナリ名。既定 codex）
#
# cmux 非依存: 文字列解決のみの純粋ロジック。

export XREV_CONFIG="$DEFAULT_CONFIG"
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"

# (1) XREV_REVIEWER_BIN が最優先（旧 env(XREV_CODEX_BIN) が指定されていても勝つ）
out="$(XREV_REVIEWER_BIN=/opt/bin/myreviewer XREV_CODEX_BIN=/opt/bin/oldcodex _xrev_reviewer_bin)"
assert_eq "XREV_REVIEWER_BIN が最優先" "/opt/bin/myreviewer" "$out"

# (2) 旧 env(XREV_CODEX_BIN)のみ・reviewer=codex(既定) → 後方互換として有効
out="$(XREV_CODEX_BIN=/opt/bin/oldcodex _xrev_reviewer_bin)"
assert_eq "reviewer=codex のとき XREV_CODEX_BIN(後方互換)は有効" "/opt/bin/oldcodex" "$out"

# (3) 何も指定なし → config の reviewer 値（既定 codex）
out="$(_xrev_reviewer_bin)"
assert_eq "既定 config(reviewer=codex)は codex を返す" "codex" "$out"

# (4) config の reviewer が codex 以外(claude)のとき、旧 env(XREV_CODEX_BIN)は無効化され
#     警告のうえ無視される（config の reviewer 値にフォールバック）。
tmpcfg="$(mktemp)"
python3 -c 'import json;d=json.load(open("'"$DEFAULT_CONFIG"'"));d["reviewer"]="claude";json.dump(d,open("'"$tmpcfg"'","w"))'
export XREV_CONFIG="$tmpcfg"
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"

out="$(XREV_CODEX_BIN=/opt/bin/oldcodex _xrev_reviewer_bin)"
err="$(XREV_CODEX_BIN=/opt/bin/oldcodex _xrev_reviewer_bin 2>&1 1>/dev/null)"
assert_eq "reviewer=claude のとき XREV_CODEX_BIN は無視されconfigのreviewer値(claude)になる" "claude" "$out"
assert_contains "reviewer=claude なのに XREV_CODEX_BIN 指定は警告する" "$err" "XREV_CODEX_BIN"

# (4') 同じ config(reviewer=claude)でも XREV_REVIEWER_BIN が指定されれば警告なく最優先で使われる
out2="$(XREV_REVIEWER_BIN=/opt/bin/myclaude XREV_CODEX_BIN=/opt/bin/oldcodex _xrev_reviewer_bin)"
err2="$(XREV_REVIEWER_BIN=/opt/bin/myclaude XREV_CODEX_BIN=/opt/bin/oldcodex _xrev_reviewer_bin 2>&1 1>/dev/null)"
assert_eq "reviewer=claude でも XREV_REVIEWER_BIN が最優先" "/opt/bin/myclaude" "$out2"
assert_eq "XREV_REVIEWER_BIN 指定時は警告を出さない" "" "$err2"

rm -f "$tmpcfg"
unset out out2 err err2 tmpcfg

# 後始末: 既定 config へ戻す（後続テストへ config 差し替えを漏らさない）
export XREV_CONFIG="$DEFAULT_CONFIG"
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"
