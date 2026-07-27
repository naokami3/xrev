#!/usr/bin/env bash
# start-reviewer.sh の単体テスト（cmux はスタブ・codex もスタブ）。
#
# start-reviewer.sh は最後に exec でシェルを codex に置き換えるため、本体を source せず
# `bash <path>` でサブプロセスとして実行し、そのプロセスの終了コードを検証する
# （exec 成功時は codex スタブの exit code がそのままプロセスの終了コードになる）。
# cmux 依存は XREV_CMUX_BIN でスタブ cmux に差し替え、_cmux_preflight / _cmux_set_title を
# 無害化する（transport.sh を source する構造なので、この1点のスタブで cmux 呼び出し全体を
# 無害化できる）。codex 依存は XREV_CODEX_BIN でスタブ codex に差し替える。

START_REVIEWER="$SCRIPTS/start-reviewer.sh"

_str_dir="$(mktemp -d)"

# ── cmux スタブ: ping / rename-tab（set-title 経由）を無条件成功で返す ──────────────
# start-reviewer.sh 自体の _cmux_set_title 呼び出しと、exec 直前に起動する遅延リネームの
# バックグラウンドヘルパ（transport.sh set-title 経由）の両方がこのスタブを叩き得るが、
# どちらも「成功させて無害化する」だけでよく、呼び出し内容の検証はしない。
CMUX_STUB="$_str_dir/cmux-stub.sh"
cat > "$CMUX_STUB" <<'EOF'
#!/bin/sh
case "$1" in
  ping) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$CMUX_STUB"

# ── codex スタブ: 実行された記録をマーカーファイルへ残して即座に成功終了する ────────────
# マーカーの有無で「危険引数で中止した場合に codex が起動されていないこと」を確認する。
# 【ファイル名に注意】_xrev_reviewer_launch_args は basename で config の reviewer_launch_args
# （既定は "codex" / "claude" キー）を引く。basename が別名（例 codex-stub.sh）だと
# 「未知の reviewer」として rc64 で弾かれてしまうため、スタブのファイル名は必ず "codex" にする。
CODEX_STUB="$_str_dir/codex"
cat > "$CODEX_STUB" <<'EOF'
#!/bin/sh
[ -n "${XREV_TEST_CODEX_MARKER:-}" ] && echo ran >> "$XREV_TEST_CODEX_MARKER"
exit 0
EOF
chmod +x "$CODEX_STUB"

# ── (1) codex スタブで正常系: exec が成功しスタブの exit 0 がそのまま返る ───────────────
marker1="$_str_dir/marker1"
CMUX_SURFACE_ID=surf-test XREV_CONFIG="$DEFAULT_CONFIG" \
  XREV_CMUX_BIN="$CMUX_STUB" XREV_CODEX_BIN="$CODEX_STUB" \
  XREV_TEST_CODEX_MARKER="$marker1" \
  bash "$START_REVIEWER" >/dev/null 2>&1
rc=$?
assert_rc "codexスタブ起動 → exec成功でスタブのexit0が返る" 0 "$rc"
assert_eq "正常系ではcodexスタブが実行される" "ran" "$(cat "$marker1" 2>/dev/null)"

# ── (2) 危険引数（--sandbox danger-full-access）→ exit64・codexは起動されない ────────
marker2="$_str_dir/marker2"
CMUX_SURFACE_ID=surf-test XREV_CONFIG="$DEFAULT_CONFIG" \
  XREV_CMUX_BIN="$CMUX_STUB" XREV_CODEX_BIN="$CODEX_STUB" \
  XREV_TEST_CODEX_MARKER="$marker2" \
  bash "$START_REVIEWER" --sandbox danger-full-access >/dev/null 2>&1
rc=$?
assert_rc "危険引数(--sandbox danger-full-access) → exit64" 64 "$rc"
assert_eq "危険引数時はcodexスタブが実行されない" "" "$(cat "$marker2" 2>/dev/null)"

# ── (3) codex 不在（XREV_CODEX_BIN=/nonexistent）→ exit127 ────────────────────────
CMUX_SURFACE_ID=surf-test XREV_CONFIG="$DEFAULT_CONFIG" \
  XREV_CMUX_BIN="$CMUX_STUB" XREV_CODEX_BIN="/nonexistent/xrev-codex-does-not-exist" \
  bash "$START_REVIEWER" >/dev/null 2>&1
rc=$?
assert_rc "codex不在 → exit127" 127 "$rc"

# ── (4) 指摘3（2巡目）: reviewer 設定の矛盾は副作用（タイトル変更・exec）より前に拒否 ──────
# XREV_REVIEWER=codex（解決済み reviewer）と XREV_REVIEWER_PROCESS=claude（明示値の basename が
# codex/claude のどちらかで解決済み reviewer と異なる）を組み合わせ、matter 検査が exec の
# 前で発火し rc29 になること・codex が一切起動されないことを確認する。
marker4="$_str_dir/marker4"
CMUX_SURFACE_ID=surf-test XREV_CONFIG="$DEFAULT_CONFIG" \
  XREV_CMUX_BIN="$CMUX_STUB" XREV_CODEX_BIN="$CODEX_STUB" \
  XREV_REVIEWER=codex XREV_REVIEWER_PROCESS=claude \
  XREV_TEST_CODEX_MARKER="$marker4" \
  bash "$START_REVIEWER" >/dev/null 2>"$_str_dir/err4.log"
rc=$?
assert_rc "reviewer設定の矛盾 → exit29" 29 "$rc"
assert_eq "矛盾時はcodexが起動されない" "" "$(cat "$marker4" 2>/dev/null)"
assert_contains "矛盾ログを出力する" "$(cat "$_str_dir/err4.log")" "矛盾"

rm -rf "$_str_dir"
