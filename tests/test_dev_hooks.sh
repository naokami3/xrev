#!/usr/bin/env bash
# 開発フック（テスト強制）のユニットテスト。
#   - tools/claude-posttooluse.sh: 編集ファイルの構文/JSON 即時チェック
#   - tools/claude-stop.sh: 変更検知・verify 実行・差し戻し・ループ防止
# いずれも cmux 不要。tools 配下のパスに見せるため一時ディレクトリ(*/tools/*.sh 等)を使う。

PT="$XREV_ROOT/tools/claude-posttooluse.sh"
ST="$XREV_ROOT/tools/claude-stop.sh"

ev() { printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$1"; }

tmp="$(mktemp -d)"
mkdir -p "$tmp/tools" "$tmp/config"
printf '#!/usr/bin/env bash\necho ok\n' > "$tmp/tools/ok.sh"
printf 'if then fi\n'                    > "$tmp/tools/broken.sh"
printf '{"a":1}\n'                       > "$tmp/config/good.json"
printf '{bad json\n'                     > "$tmp/config/bad.json"

# ── claude-posttooluse.sh ──
ev "$tmp/tools/ok.sh"     | "$PT"; assert_rc "正しい .sh は rc=0" 0 "$?"
ev "$tmp/tools/broken.sh" | "$PT" 2>/dev/null; assert_rc "壊れた .sh は rc=2" 2 "$?"
ev "$tmp/config/good.json"| "$PT"; assert_rc "正しい .json は rc=0" 0 "$?"
ev "$tmp/config/bad.json" | "$PT" 2>/dev/null; assert_rc "壊れた .json は rc=2" 2 "$?"
ev "$tmp/README.md"       | "$PT"; assert_rc "対象外ファイルは rc=0" 0 "$?"
ev "$tmp/tools/none.sh"   | "$PT"; assert_rc "存在しないファイルは rc=0" 0 "$?"
printf '{"tool_input":{}}' | "$PT"; assert_rc "file_path 無しは rc=0" 0 "$?"
printf 'これはJSONでない'  | "$PT"; assert_rc "壊れたイベントJSONでも落ちず rc=0" 0 "$?"

# ── claude-stop.sh ──
# 変更検知は環境(リポジトリの dirty 状態)に依存しないよう、XREV_STOP_ROOT で一時 git リポジトリを
# 指し、XREV_VERIFY_CMD で verify をスタブ注入して決定論的に検証する。
pass_cmd="$tmp/verify_pass.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$pass_cmd"
fail_cmd="$tmp/verify_fail.sh"; printf '#!/usr/bin/env bash\necho NG; exit 1\n' > "$fail_cmd"
chmod +x "$pass_cmd" "$fail_cmd"

sroot="$tmp/repo"; mkdir -p "$sroot"
(
  cd "$sroot"
  git init -q; git config user.email t@e.com; git config user.name t
  echo readme > readme.txt; git add readme.txt; git commit -qm init
)

# 監視対象に変更なし（クリーン）→ verify を回さず rc=0（失敗スタブでも回さない）
printf '{"stop_hook_active":false}' | XREV_STOP_ROOT="$sroot" XREV_VERIFY_CMD="$fail_cmd" "$ST" >/dev/null 2>&1
assert_rc "監視対象に変更なしは verify を回さず rc=0" 0 "$?"

# 監視対象(scripts/)に変更を作る（untracked）
mkdir -p "$sroot/scripts"; echo "x" > "$sroot/scripts/change.sh"

# 変更あり + verify 通過 → rc=0
printf '{"stop_hook_active":false}' | XREV_STOP_ROOT="$sroot" XREV_VERIFY_CMD="$pass_cmd" "$ST" >/dev/null 2>&1
assert_rc "変更あり+verify通過は rc=0" 0 "$?"

# 変更あり + verify 失敗 + 初回 → rc=2 で差し戻し
printf '{"stop_hook_active":false}' | XREV_STOP_ROOT="$sroot" XREV_VERIFY_CMD="$fail_cmd" "$ST" >/dev/null 2>&1
assert_rc "変更あり+verify失敗・初回は rc=2（差し戻し）" 2 "$?"

# 変更あり + verify 失敗 + stop_hook_active=true → ループ防止で rc=0 + systemMessage
out="$(printf '{"stop_hook_active":true}' | XREV_STOP_ROOT="$sroot" XREV_VERIFY_CMD="$fail_cmd" "$ST" 2>/dev/null)"; rc=$?
assert_rc "変更あり+verify失敗・2回目は rc=0（ループ防止）" 0 "$rc"
assert_contains "ループ防止時は systemMessage を返す" "$out" "systemMessage"

rm -rf "$tmp"
