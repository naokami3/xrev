#!/usr/bin/env bash
#
# test_codex_primary_config.sh — C3: 主従反転プリセット config/xrev.codex-primary.json。
#
#   (a) JSON として妥当
#   (b) 既定 config とキー集合が完全一致（乖離=更新漏れの検出。C2 で追加した設定キー等の
#       同期漏れをここで機械的に検出する）
#   (c) 差分キーは許可リスト {primary, reviewer, reviewer_pane_title, reviewer_process} のみ。
#       それ以外のキーは既定 config と値まで一致すること。

CODEX_PRIMARY_CONFIG="$XREV_ROOT/config/xrev.codex-primary.json"

# (a) JSON として妥当
# 【注意】サブシェル(command substitution)を介さず python3 を素の前景コマンドとして呼ぶと、
# 現在シェルのコマンドハッシュキャッシュに python3 の解決パスが残り、後続の test_dev_hooks.sh
# （PATH スタブで python3 を不可視化するテスト）がハッシュキャッシュ経由で発見してしまい
# 誤って通過する（実際に観測した回帰）。command substitution はサブシェルを作るため安全。
_ok="$(python3 -c 'import json; json.load(open("'"$CODEX_PRIMARY_CONFIG"'"))' 2>&1)"
assert_rc "codex-primary config は妥当な JSON" 0 "$?"

# (b) キー集合の完全一致（乖離 = 既定config更新時の追従漏れ）
out="$(python3 -c '
import json
d = json.load(open("'"$DEFAULT_CONFIG"'"))
c = json.load(open("'"$CODEX_PRIMARY_CONFIG"'"))
missing = sorted(set(d) - set(c))
extra = sorted(set(c) - set(d))
print("missing=%s extra=%s" % (missing, extra))
')"
assert_eq "キー集合は既定configと完全一致" "missing=[] extra=[]" "$out"

# (c) 差分キーは許可リストのみで、それ以外の値は既定と一致
# 【reviewer_reads_workspace について】このプリセットは claude reviewer が参照モード必須
# （修正1・decision-impl-1.json 指摘1への対処。inline は最小 wire が全文可視上限を超え常に
# exit28 になるため）なので true に固定する。既定(false)との意図した差分として許可リストに含める。
out="$(python3 -c '
import json
d = json.load(open("'"$DEFAULT_CONFIG"'"))
c = json.load(open("'"$CODEX_PRIMARY_CONFIG"'"))
allow = {"primary", "reviewer", "reviewer_pane_title", "reviewer_process", "reviewer_reads_workspace"}
diff = sorted(k for k in d if d.get(k) != c.get(k))
unexpected = sorted(set(diff) - allow)
print("diff=%s unexpected=%s" % (diff, unexpected))
')"
assert_contains "許可リスト以外の差分は無い" "$out" "unexpected=[]"
assert_contains "primary は差分に含まれる" "$out" "'primary'"
assert_contains "reviewer は差分に含まれる" "$out" "'reviewer'"
assert_contains "reviewer_pane_title は差分に含まれる" "$out" "'reviewer_pane_title'"
assert_contains "reviewer_process は差分に含まれる" "$out" "'reviewer_process'"
assert_contains "reviewer_reads_workspace は差分に含まれる" "$out" "'reviewer_reads_workspace'"

# reviewer_reads_workspace そのものの値も固定で確認する（true・参照モード必須）
assert_eq "reviewer_reads_workspace=true" "True" \
  "$(python3 -c 'import json;print(json.load(open("'"$CODEX_PRIMARY_CONFIG"'"))["reviewer_reads_workspace"])')"

# 期待値そのものの確認（R1 実測値・design-final.md で確定した値）
assert_eq "primary=codex" "codex" \
  "$(python3 -c 'import json;print(json.load(open("'"$CODEX_PRIMARY_CONFIG"'"))["primary"])')"
assert_eq "reviewer=claude" "claude" \
  "$(python3 -c 'import json;print(json.load(open("'"$CODEX_PRIMARY_CONFIG"'"))["reviewer"])')"
assert_eq "reviewer_pane_title='Review Claude'" "Review Claude" \
  "$(python3 -c 'import json;print(json.load(open("'"$CODEX_PRIMARY_CONFIG"'"))["reviewer_pane_title"])')"
assert_eq "reviewer_process=claude" "claude" \
  "$(python3 -c 'import json;print(json.load(open("'"$CODEX_PRIMARY_CONFIG"'"))["reviewer_process"])')"

# reviewer_launch_args は既定と同一（claude エントリ ["--permission-mode","plan"] を含む）
def_largs="$(python3 -c 'import json;print(json.dumps(json.load(open("'"$DEFAULT_CONFIG"'"))["reviewer_launch_args"], sort_keys=True))')"
val_largs="$(python3 -c 'import json;print(json.dumps(json.load(open("'"$CODEX_PRIMARY_CONFIG"'"))["reviewer_launch_args"], sort_keys=True))')"
assert_eq "reviewer_launch_args は既定と同一" "$def_largs" "$val_largs"
assert_contains "reviewer_launch_args に claude エントリを含む" "$val_largs" '"claude"'

unset CODEX_PRIMARY_CONFIG out _ok def_largs val_largs
