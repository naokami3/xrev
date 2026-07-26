#!/usr/bin/env bash
#
# test_print_agents_snippet.sh — C4b: scripts/print-agents-snippet.sh の単体テスト。
#
#   (a) 出力に必須要素（XREV_ROOT 絶対パス・$XREV_ROOT 相対参照・keyword-match.sh 参照・
#       前提検査・doctor）が含まれること
#   (b) プラグインキャッシュ配下（パスに /plugins/cache/ を含む）から実行すると stderr に
#       警告が出ること（補助警告。出力自体は止めない）。スクリプトをそのパスへコピーして検証する
#   (c) ファイルを一切生成しないこと（実行前後でディレクトリの中身が変わらない）

SNIPPET_SCRIPT="$SCRIPTS/print-agents-snippet.sh"

# ── (a) 通常実行: 必須要素の存在確認 ────────────────────────────────────────
out="$(bash "$SNIPPET_SCRIPT" 2>/dev/null)"
rc=$?
assert_rc "通常実行は exit0" 0 "$rc"
assert_contains "出力に XREV_ROOT の絶対パス（実リポジトリルート）を含む" "$out" "export XREV_ROOT=\"$XREV_ROOT\""
assert_contains "出力に \$XREV_ROOT 相対参照（transport.sh）を含む" "$out" '$XREV_ROOT/scripts/transport.sh'
assert_contains "出力に keyword-match.sh への参照を含む" "$out" 'keyword-match.sh'
assert_contains "出力に前提検査（期待ファイルの存在確認）を含む" "$out" '期待するファイルがありません'
assert_contains "出力に codex-primary-playbook.md への参照を含む" "$out" 'codex-primary-playbook.md'
assert_contains "出力に xrev.codex-primary.json への参照を含む" "$out" 'xrev.codex-primary.json'
assert_contains "出力に doctor 実行を含む" "$out" 'scripts/transport.sh" doctor'
assert_contains "出力に review-loop.sh への参照を含む" "$out" 'scripts/review-loop.sh'

# 通常実行（キャッシュ配下でない）では警告が出ない
err="$(bash "$SNIPPET_SCRIPT" 2>&1 1>/dev/null)"
assert_eq "リポジトリ直下から実行した場合は警告なし" "" "$err"

# ── (b) プラグインキャッシュ配下からの実行 → 補助警告（出力自体は止めない）────────
_pas_dir="$(mktemp -d)"
FAKE_CACHE_DIR="$_pas_dir/home/.claude/plugins/cache/xrev-marketplace/xrev/scripts"
mkdir -p "$FAKE_CACHE_DIR"
cp "$SNIPPET_SCRIPT" "$FAKE_CACHE_DIR/print-agents-snippet.sh"
chmod +x "$FAKE_CACHE_DIR/print-agents-snippet.sh"

cache_out="$(bash "$FAKE_CACHE_DIR/print-agents-snippet.sh" 2>"$_pas_dir/stderr.log")"
cache_rc=$?
cache_err="$(cat "$_pas_dir/stderr.log")"

assert_rc "キャッシュ配下実行でも exit0" 0 "$cache_rc"
assert_contains "キャッシュ配下実行で警告が出る" "$cache_err" "プラグインキャッシュ配下"
assert_contains "キャッシュ配下実行でも出力自体は止めない（XREV_ROOT定義を含む）" "$cache_out" "export XREV_ROOT="

# ── (c) ファイルを一切生成しない ──────────────────────────────────────────
_before="$(find "$_pas_dir" -type f | sort)"
bash "$FAKE_CACHE_DIR/print-agents-snippet.sh" >/dev/null 2>&1
_after="$(find "$_pas_dir" -type f | sort)"
assert_eq "実行前後でファイル一覧が変わらない（生成物なし）" "$_before" "$_after"

rm -rf "$_pas_dir"
unset SNIPPET_SCRIPT out rc err _pas_dir FAKE_CACHE_DIR cache_out cache_rc cache_err _before _after
