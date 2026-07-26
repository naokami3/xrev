#!/usr/bin/env bash
#
# test_print_agents_snippet.sh — C4b/D3: scripts/print-agents-snippet.sh の単体テスト。
#
#   (a) 出力に必須要素（XREV_ROOT 絶対パス・$XREV_ROOT 相対参照・keyword-match.sh 参照・
#       前提検査・doctor・マーカー）が含まれること
#   (b) プラグインキャッシュ配下（パスに /plugins/cache/ を含む）から実行すると stderr に
#       警告が出ること（補助警告。出力自体は止めない）。スクリプトをそのパスへコピーして検証する
#   (c) ファイルを一切生成しないこと（実行前後でディレクトリの中身が変わらない）
#
# D3（--append-global。グローバル codex AGENTS.md への一度きり導入）:
#   (d) _xrev_resolve_agents_target: 3経路の正規対象収束（symlink/file/new）と
#       fail closed 経路（dangling/nohome/other/error）。タブ・改行が"途中"にあるパスの復元。
#   末尾に改行があるパス: --append-global（実処理は単一 python プロセスで完結し、path は
#       bash の command substitution を一度も通らない）を通した「正確なファイルへの書き込み」を
#       ファイルシステムの状態で検証する（path文字列の再抽出比較はそれ自体が同じ欠陥を再現する
#       ため使わない）。
#   (e) 初回導入（new）と冪等（追記→置換）
#   (f) マーカー異常拒否（欠損・重複・逆順）は元ファイル不変
#   (g) パーミッション保持（stat→chmod）
#   (h) ディレクトリ不在拒否（mkdir しない）
#   (i) 異なる TMPDIR の二重実行で片方のみ取得（ロックは対象直下・TMPDIR非依存）
#   (j) symlink 経由と直接経路の排他収束（同じロックへ収束する）
#   (k) dangling symlink の拒否（リンク温存）
#   (l)(m) mv 直前の内容変化（内容書き換え/symlink置換/inode差し替え/chmodのみ変更）で無変更
#       拒否すること。いずれも継続レース（背景プロセス・巨大本文・sleep）は使わず、共有の
#       python ドライバから _xrev_write_agents_file の hook 引数へ「baseline取得後・mv直前
#       チェック前」に1回だけ変異を注入する決定論的な方式で検証する（CI環境でのタイミング依存
#       flakeを避けるため。env 経由のテスト専用フックは本番コードの安全境界にならないため使わない）。
#
# HOME/CODEX_HOME は一時ディレクトリへ向ける（実ホームディレクトリに触れない）。

SNIPPET_SCRIPT="$SCRIPTS/print-agents-snippet.sh"
# shellcheck source=/dev/null
source "$SNIPPET_SCRIPT"

# ── (a) 通常実行: 必須要素の存在確認 ────────────────────────────────────────
out="$(bash "$SNIPPET_SCRIPT" 2>/dev/null)"
rc=$?
assert_rc "通常実行は exit0" 0 "$rc"
# 実行モデル変更（codex は export を持ち越さない）に伴い、スニペットは export ではなく
# 「XREV_ROOT = <絶対パス>」の宣言と、絶対パスを直接埋めたコマンド例を出力する。
assert_contains "出力に XREV_ROOT の絶対パス（実リポジトリルート）の宣言を含む" "$out" "XREV_ROOT = $XREV_ROOT"
assert_contains "出力に絶対パス直埋めの transport.sh 参照を含む" "$out" "$XREV_ROOT/scripts/transport.sh"
assert_contains "出力にサンドボックス外実行（エスカレーション）の注意を含む" "$out" 'サンドボックス外実行'
assert_contains "出力に環境変数の毎コマンド前置の注意を含む" "$out" '前置'
assert_contains "出力に keyword-match.sh への参照を含む" "$out" 'keyword-match.sh'
assert_contains "出力に前提検査（期待ファイルの存在確認）を含む" "$out" '期待するファイルがありません'
assert_contains "出力に codex-primary-playbook.md への参照を含む" "$out" 'codex-primary-playbook.md'
assert_contains "出力に xrev.codex-primary.json への参照を含む" "$out" 'xrev.codex-primary.json'
assert_contains "出力に doctor 実行を含む" "$out" 'scripts/transport.sh" doctor'
assert_contains "出力に review-loop.sh への参照を含む" "$out" 'scripts/review-loop.sh'
assert_contains "出力にグローバル導入(CODEX_HOME/AGENTS.md)の説明を含む" "$out" 'CODEX_HOME/AGENTS.md'
assert_contains "出力に自己申告(XREV_PRIMARY=codex)の手順を含む" "$out" 'XREV_PRIMARY=codex'
assert_contains "出力にマーカーBEGINを含む" "$out" '<!-- xrev:snippet:BEGIN -->'
assert_contains "出力にマーカーENDを含む" "$out" '<!-- xrev:snippet:END -->'

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
assert_contains "キャッシュ配下実行でも出力自体は止めない（XREV_ROOT宣言を含む）" "$cache_out" "XREV_ROOT = "

# ── (c) ファイルを一切生成しない ──────────────────────────────────────────
_before="$(find "$_pas_dir" -type f | sort)"
bash "$FAKE_CACHE_DIR/print-agents-snippet.sh" >/dev/null 2>&1
_after="$(find "$_pas_dir" -type f | sort)"
assert_eq "実行前後でファイル一覧が変わらない（生成物なし）" "$_before" "$_after"

rm -rf "$_pas_dir"
unset out rc err _pas_dir FAKE_CACHE_DIR cache_out cache_rc cache_err _before _after

# ── (d) _xrev_resolve_agents_target: 3経路の正規対象収束 + fail closed 経路 ────────
# 【注意】macOS は /tmp が /private/tmp への symlink。realpath 正規化後のパスと比較するため、
# 期待値側も pwd -P で物理パスへ正規化しておく（さもないと /var/... vs /private/var/... の
# 表記差だけで誤って不一致になる）。
# 【指摘1(3巡目)】出力は JSON（cut -f ではなく _xrev_json_field で単一回パースして復元する）。
_pas_home="$(cd "$(mktemp -d)" && pwd -P)"

# new: CODEX_HOME ディレクトリのみ存在、AGENTS.md 無し。
mkdir -p "$_pas_home/new/.codex"
out="$(CODEX_HOME="$_pas_home/new/.codex" _xrev_resolve_agents_target)"
assert_eq "new: kind=new" "new" "$(printf '%s' "$out" | _xrev_json_field kind)"
assert_eq "new: canonical_pathはCODEX_HOME/AGENTS.md" "$_pas_home/new/.codex/AGENTS.md" "$(printf '%s' "$out" | _xrev_json_field detail)"

# file: 既存の通常ファイル。
mkdir -p "$_pas_home/file/.codex"
printf 'existing\n' > "$_pas_home/file/.codex/AGENTS.md"
out="$(CODEX_HOME="$_pas_home/file/.codex" _xrev_resolve_agents_target)"
assert_eq "file: kind=file" "file" "$(printf '%s' "$out" | _xrev_json_field kind)"
assert_eq "file: canonical_pathは実ファイル" "$_pas_home/file/.codex/AGENTS.md" "$(printf '%s' "$out" | _xrev_json_field detail)"

# symlink: 別の実ファイルを指す symlink。
mkdir -p "$_pas_home/symlink/.codex" "$_pas_home/symlink/real"
printf 'real content\n' > "$_pas_home/symlink/real/AGENTS.md"
ln -s "$_pas_home/symlink/real/AGENTS.md" "$_pas_home/symlink/.codex/AGENTS.md"
out="$(CODEX_HOME="$_pas_home/symlink/.codex" _xrev_resolve_agents_target)"
assert_eq "symlink: kind=symlink" "symlink" "$(printf '%s' "$out" | _xrev_json_field kind)"
assert_eq "symlink: canonical_pathはリンク先の実ファイル" "$_pas_home/symlink/real/AGENTS.md" "$(printf '%s' "$out" | _xrev_json_field detail)"

# dangling: リンク切れの symlink。
mkdir -p "$_pas_home/dangling/.codex"
ln -s "$_pas_home/dangling/.codex/does-not-exist.md" "$_pas_home/dangling/.codex/AGENTS.md"
out="$(CODEX_HOME="$_pas_home/dangling/.codex" _xrev_resolve_agents_target)"
assert_eq "dangling: kind=dangling" "dangling" "$(printf '%s' "$out" | _xrev_json_field kind)"

# nohome: CODEX_HOME ディレクトリ自体が存在しない。
out="$(CODEX_HOME="$_pas_home/nohome/.codex" _xrev_resolve_agents_target)"
assert_eq "nohome: kind=nohome" "nohome" "$(printf '%s' "$out" | _xrev_json_field kind)"

# other: 対象パスがディレクトリ（想定外の種類）。
mkdir -p "$_pas_home/other/.codex/AGENTS.md"
out="$(CODEX_HOME="$_pas_home/other/.codex" _xrev_resolve_agents_target)"
assert_eq "other: kind=other" "other" "$(printf '%s' "$out" | _xrev_json_field kind)"

# symlink-to-dir: symlink のリンク先がディレクトリ（通常ファイルでない）→ other 扱い（指摘1・2巡目）。
# canonical target としてディレクトリを返してはならない。
mkdir -p "$_pas_home/symdir/.codex" "$_pas_home/symdir/realdir"
ln -s "$_pas_home/symdir/realdir" "$_pas_home/symdir/.codex/AGENTS.md"
out="$(CODEX_HOME="$_pas_home/symdir/.codex" _xrev_resolve_agents_target)"
assert_eq "symlinkのリンク先がディレクトリ → kind=other(指摘1)" "other" "$(printf '%s' "$out" | _xrev_json_field kind)"

# error(権限拒否): 親ディレクトリの権限を落とし、lstat 自体が失敗する状況を作る。
# 「存在しない」と誤分類せず専用の error kind で fail closed になることを確認する（指摘1・2巡目）。
if [[ "$(id -u)" != "0" ]]; then
  mkdir -p "$_pas_home/permdenied/.codex"
  printf 'x\n' > "$_pas_home/permdenied/.codex/AGENTS.md"
  chmod 000 "$_pas_home/permdenied/.codex"
  out="$(CODEX_HOME="$_pas_home/permdenied/.codex" _xrev_resolve_agents_target)"
  assert_eq "権限拒否(lstat失敗) → kind=error(存在しない扱いにしない)" "error" "$(printf '%s' "$out" | _xrev_json_field kind)"
  chmod 755 "$_pas_home/permdenied/.codex"
else
  pass "権限拒否テストは root 実行のため skip(常にRW可でテスト不能)"
fi

# ── 指摘1（3巡目）: CODEX_HOME・symlink 解決先にタブ/改行が含まれても正しく復元される ──────
# cut -f1/-f2/-f3 だとフィールド境界が壊れて誤った target/lock path へ書き込みかねなかった。
# JSON + 単一回パースへ切り替えたことで、タブ・改行を含むパスでも正しく1個のフィールドとして
# 復元されることを固定する（グローバル指示ファイルという対象上、誤配送は許容できない）。
_pas_weird_root="$(cd "$(mktemp -d)" && pwd -P)"
_pas_weird_home="$_pas_weird_root/weird"$'\t'"tab"$'\n'"newline/.codex"
mkdir -p "$_pas_weird_home"
out="$(CODEX_HOME="$_pas_weird_home" _xrev_resolve_agents_target)"
assert_eq "タブ+改行入りCODEX_HOME: kind=new" "new" "$(printf '%s' "$out" | _xrev_json_field kind)"
assert_eq "タブ+改行入りCODEX_HOME: canonical_pathが正しく1個のフィールドとして復元される" \
  "$_pas_weird_home/AGENTS.md" "$(printf '%s' "$out" | _xrev_json_field detail)"
assert_eq "タブ+改行入りCODEX_HOME: home_dirも正しく復元される" \
  "$_pas_weird_home" "$(printf '%s' "$out" | _xrev_json_field home_dir)"

# symlink 解決先にもタブ/改行を含むケース（realpath 側に含まれる場合）。
_pas_weird_real_dir="$_pas_weird_root/real"$'\t'"weird"$'\n'"dir"
mkdir -p "$_pas_weird_real_dir" "$_pas_weird_root/symhome"
printf 'x\n' > "$_pas_weird_real_dir/AGENTS.md"
ln -s "$_pas_weird_real_dir/AGENTS.md" "$_pas_weird_root/symhome/AGENTS.md"
out="$(CODEX_HOME="$_pas_weird_root/symhome" _xrev_resolve_agents_target)"
_pas_weird_expected="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$_pas_weird_real_dir/AGENTS.md")"
assert_eq "タブ+改行入りsymlink解決先: kind=symlink" "symlink" "$(printf '%s' "$out" | _xrev_json_field kind)"
assert_eq "タブ+改行入りsymlink解決先: canonical_pathが正しく復元される" \
  "$_pas_weird_expected" "$(printf '%s' "$out" | _xrev_json_field detail)"

# --append-global 経由でも、タブ+改行入りパスの「正確なそのファイル」にだけ書き込まれること。
CODEX_HOME="$_pas_weird_home" HOME="$_pas_weird_root" bash "$SNIPPET_SCRIPT" --append-global >/dev/null
assert_rc "タブ+改行入りCODEX_HOMEでも --append-global が成功する" 0 "$?"
assert_eq "期待した1個のパスにだけAGENTS.mdが生成される" "yes" \
  "$([[ -f "$_pas_weird_home/AGENTS.md" ]] && echo yes || echo no)"

rm -rf "$_pas_home" "$_pas_weird_root"
unset _pas_home out _pas_weird_root _pas_weird_home _pas_weird_real_dir _pas_weird_expected

# ── 指摘1（4巡目）: CODEX_HOME・symlink 解決先が「末尾に改行を含む」有効なパスでも
#    canonical target が変化しない ─────────────────────────────────────────────
# 【背景】旧実装（3巡目の修正）は対象解決の結果を JSON で受け渡していたが、呼び出し側が
# フィールドごとに別の python 呼び出しで再抽出し、その結果を `$(...)` で bash 変数へ捕捉していた。
# コマンド置換は末尾の改行を無条件に取り除くため、値の末尾が改行で終わる有効なパスだと
# その時点で改行が失われ、canonical target が別パスに化けてしまっていた（3巡目のタブ+改行の
# テストは改行がパス"途中"にしかなく、この欠陥を検出できなかった）。
# 4巡目の修正で --append-global の実処理は単一 python プロセス内で完結し、path が bash の
# コマンド置換を一度も通らない構成になった。ここではその契約を、抽出したパス文字列を比較する
# のではなく「期待した正確なファイルシステム上のパスが更新されたか」で検証する
# （パス文字列の比較そのものが `$(...)` を経由すると同じ欠陥を再現してしまうため、
# bash 側で構築した期待パスへの `test -f` で確認するのが正しい検証方法）。
_pas_nl_root="$(cd "$(mktemp -d)" && pwd -P)"

# CODEX_HOME 自体が改行で終わるケース。
_pas_nl_home="$_pas_nl_root/codexhome-ends-in-newline"$'\n'
mkdir -p "$_pas_nl_home"
CODEX_HOME="$_pas_nl_home" HOME="$_pas_nl_root" bash "$SNIPPET_SCRIPT" --append-global >/dev/null 2>"$_pas_nl_root/err1.log"
assert_rc "末尾改行のCODEX_HOMEでも成功する" 0 "$?"
assert_eq "末尾改行CODEX_HOME: 正確な期待パスにAGENTS.mdが作られる" "yes" \
  "$([[ -f "${_pas_nl_home}/AGENTS.md" ]] && echo yes || echo no)"
# 「改行の手前で切られた別パス」に誤配送していないことも確認する
_pas_nl_home_truncated="${_pas_nl_home%$'\n'}"
assert_eq "誤った(改行で切られた)パスには生成されない" "no" \
  "$([[ -f "${_pas_nl_home_truncated}AGENTS.md" ]] && echo yes || echo no)"

# symlink 解決先が改行で終わるケース。
_pas_nl_real="$_pas_nl_root/real-ends-in-newline"$'\n'
mkdir -p "$_pas_nl_real" "$_pas_nl_root/symhome2"
printf 'existing\n' > "${_pas_nl_real}/AGENTS.md"
ln -s "${_pas_nl_real}/AGENTS.md" "$_pas_nl_root/symhome2/AGENTS.md"
CODEX_HOME="$_pas_nl_root/symhome2" HOME="$_pas_nl_root" bash "$SNIPPET_SCRIPT" --append-global >/dev/null
assert_rc "末尾改行のsymlink解決先でも成功する" 0 "$?"
assert_contains "末尾改行symlink解決先: 正確な実ファイルにスニペットが書き込まれる" \
  "$(cat "${_pas_nl_real}/AGENTS.md")" "xrev:snippet:BEGIN"
assert_eq "symlinkは温存される" "yes" \
  "$([[ -L "$_pas_nl_root/symhome2/AGENTS.md" ]] && echo yes || echo no)"

rm -rf "$_pas_nl_root"
unset _pas_nl_root _pas_nl_home _pas_nl_home_truncated _pas_nl_real

# ── (e) --append-global: 初回導入(new)と冪等（追記→置換）───────────────────────
_pas_e="$(mktemp -d)"
mkdir -p "$_pas_e/.codex"

out="$(CODEX_HOME="$_pas_e/.codex" HOME="$_pas_e" bash "$SNIPPET_SCRIPT" --append-global)"
rc=$?
assert_rc "初回導入(new) → exit0" 0 "$rc"
assert_contains "初回導入 → append と報告する" "$out" "(append):"
_pas_e_content="$(cat "$_pas_e/.codex/AGENTS.md")"
assert_contains "初回導入 → BEGINマーカーを含む" "$_pas_e_content" '<!-- xrev:snippet:BEGIN -->'
assert_contains "初回導入 → ENDマーカーを含む" "$_pas_e_content" '<!-- xrev:snippet:END -->'
_pas_e_begin_count="$(grep -c 'xrev:snippet:BEGIN' "$_pas_e/.codex/AGENTS.md")"
assert_eq "初回導入 → BEGINマーカーはちょうど1個" "1" "$_pas_e_begin_count"
# 指摘2（2巡目）: BEGIN/END は独立行であること（本文最終行に END が連結されない）。
assert_rc "初回導入 → BEGINは独立行(grep -x)" 0 \
  "$(grep -qx '<!-- xrev:snippet:BEGIN -->' "$_pas_e/.codex/AGENTS.md"; echo $?)"
assert_rc "初回導入 → ENDは独立行(grep -x。本文と連結していない)" 0 \
  "$(grep -qx '<!-- xrev:snippet:END -->' "$_pas_e/.codex/AGENTS.md"; echo $?)"

# 冪等: 2回目は既存マーカーを検出し replace になる。マーカー数は増えない。
out2="$(CODEX_HOME="$_pas_e/.codex" HOME="$_pas_e" bash "$SNIPPET_SCRIPT" --append-global)"
rc2=$?
assert_rc "2回目実行(replace) → exit0" 0 "$rc2"
assert_contains "2回目実行 → replace と報告する" "$out2" "(replace):"
assert_eq "冪等: マーカー対は2回実行後も1組のまま" "1" "$(grep -c 'xrev:snippet:BEGIN' "$_pas_e/.codex/AGENTS.md")"
assert_rc "2回目実行(replace)後もENDは独立行のまま" 0 \
  "$(grep -qx '<!-- xrev:snippet:END -->' "$_pas_e/.codex/AGENTS.md"; echo $?)"

# マーカー外の既存コンテンツは保持される（末尾追記の前提）。
_pas_e2="$(mktemp -d)"
mkdir -p "$_pas_e2/.codex"
printf '# 利用者の既存メモ\nこの行は消えてはいけない。\n' > "$_pas_e2/.codex/AGENTS.md"
CODEX_HOME="$_pas_e2/.codex" HOME="$_pas_e2" bash "$SNIPPET_SCRIPT" --append-global >/dev/null
assert_contains "追記時に既存コンテンツ(マーカー外)を保持する" "$(cat "$_pas_e2/.codex/AGENTS.md")" "この行は消えてはいけない"
assert_rc "既存コンテンツへの追記でもENDは独立行" 0 \
  "$(grep -qx '<!-- xrev:snippet:END -->' "$_pas_e2/.codex/AGENTS.md"; echo $?)"

rm -rf "$_pas_e" "$_pas_e2"
unset _pas_e _pas_e2 out rc out2 rc2 _pas_e_content _pas_e_begin_count

# ── (e2) --append-global: 対象解決の I/O エラーは exit16（指摘1・2巡目）────────────
if [[ "$(id -u)" != "0" ]]; then
  _pas_e3="$(mktemp -d)"
  mkdir -p "$_pas_e3/.codex"
  printf 'x\n' > "$_pas_e3/.codex/AGENTS.md"
  chmod 000 "$_pas_e3/.codex"
  CODEX_HOME="$_pas_e3/.codex" HOME="$_pas_e3" bash "$SNIPPET_SCRIPT" --append-global \
    >/dev/null 2>"$_pas_e3/err.log"
  rc=$?
  chmod 755 "$_pas_e3/.codex"
  assert_rc "対象解決でI/Oエラー(権限拒否) → exit16" 16 "$rc"
  assert_contains "エラー診断ログにエラーの案内を含む" "$(cat "$_pas_e3/err.log")" "エラーが発生しました"
  rm -rf "$_pas_e3"
  unset _pas_e3 rc
else
  pass "権限拒否テスト(--append-global)は root 実行のため skip"
fi

# ── (f) マーカー異常拒否（欠損・重複・逆順）は元ファイル不変 ─────────────────────
_pas_f="$(mktemp -d)"
mkdir -p "$_pas_f/.codex"

# 重複BEGIN（END無し）
printf '<!-- xrev:snippet:BEGIN -->\nfoo\n<!-- xrev:snippet:BEGIN -->\nbar\n' > "$_pas_f/.codex/AGENTS.md"
_pas_f_before="$(cat "$_pas_f/.codex/AGENTS.md")"
CODEX_HOME="$_pas_f/.codex" HOME="$_pas_f" bash "$SNIPPET_SCRIPT" --append-global >/dev/null 2>"$_pas_f/err.log"
rc=$?
assert_rc "重複BEGIN(END無し) → exit14" 14 "$rc"
assert_eq "重複BEGIN → 元ファイル不変" "$_pas_f_before" "$(cat "$_pas_f/.codex/AGENTS.md")"

# 逆順（END が BEGIN より前）
printf '<!-- xrev:snippet:END -->\nfoo\n<!-- xrev:snippet:BEGIN -->\n' > "$_pas_f/.codex/AGENTS.md"
_pas_f_before="$(cat "$_pas_f/.codex/AGENTS.md")"
CODEX_HOME="$_pas_f/.codex" HOME="$_pas_f" bash "$SNIPPET_SCRIPT" --append-global >/dev/null 2>&1
rc=$?
assert_rc "逆順(END が先) → exit14" 14 "$rc"
assert_eq "逆順 → 元ファイル不変" "$_pas_f_before" "$(cat "$_pas_f/.codex/AGENTS.md")"

# BEGINのみ（ENDが無い＝欠損）
printf '<!-- xrev:snippet:BEGIN -->\nfoo\n' > "$_pas_f/.codex/AGENTS.md"
_pas_f_before="$(cat "$_pas_f/.codex/AGENTS.md")"
CODEX_HOME="$_pas_f/.codex" HOME="$_pas_f" bash "$SNIPPET_SCRIPT" --append-global >/dev/null 2>&1
rc=$?
assert_rc "欠損(BEGINのみ) → exit14" 14 "$rc"
assert_eq "欠損 → 元ファイル不変" "$_pas_f_before" "$(cat "$_pas_f/.codex/AGENTS.md")"

rm -rf "$_pas_f"
unset _pas_f _pas_f_before rc

# ── (g) パーミッション保持（stat→chmod）────────────────────────────────────────
_pas_g="$(mktemp -d)"
mkdir -p "$_pas_g/.codex"
printf 'existing\n' > "$_pas_g/.codex/AGENTS.md"
chmod 640 "$_pas_g/.codex/AGENTS.md"
CODEX_HOME="$_pas_g/.codex" HOME="$_pas_g" bash "$SNIPPET_SCRIPT" --append-global >/dev/null
_pas_g_mode="$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$_pas_g/.codex/AGENTS.md")"
assert_eq "既存ファイルのパーミッション(0o640)が引き継がれる" "0o640" "$_pas_g_mode"
rm -rf "$_pas_g"
unset _pas_g _pas_g_mode

# ── (h) ディレクトリ不在拒否（mkdir しない）───────────────────────────────────
_pas_h="$(mktemp -d)"
CODEX_HOME="$_pas_h/nope/.codex" HOME="$_pas_h" bash "$SNIPPET_SCRIPT" --append-global >/dev/null 2>"$_pas_h/err.log"
rc=$?
assert_rc "CODEX_HOMEディレクトリ不在 → exit11" 11 "$rc"
assert_eq "ディレクトリを作らない(mkdirしない)" "no" "$([[ -d "$_pas_h/nope" ]] && echo yes || echo no)"
rm -rf "$_pas_h"
unset _pas_h rc

# ── (i) 異なる TMPDIR の二重実行で片方のみ取得（ロックは対象直下・TMPDIR非依存）─────
_pas_i="$(mktemp -d)"
mkdir -p "$_pas_i/.codex"
_pas_i_lock="$_pas_i/.codex/.AGENTS.md.xrev-lock"
mkdir "$_pas_i_lock"   # 他プロセスが既にロック取得済みという体を作る
TMPDIR="$(mktemp -d)" CODEX_HOME="$_pas_i/.codex" HOME="$_pas_i" bash "$SNIPPET_SCRIPT" --append-global \
  >/dev/null 2>"$_pas_i/err.log"
rc=$?
assert_rc "ロック競合(別TMPDIR) → exit13" 13 "$rc"
assert_contains "競合ログにロックパスを含む" "$(cat "$_pas_i/err.log")" ".AGENTS.md.xrev-lock"
assert_eq "競合時はファイルを生成しない" "no" "$([[ -e "$_pas_i/.codex/AGENTS.md" ]] && echo yes || echo no)"
rmdir "$_pas_i_lock"
# ロックを外せば別 TMPDIR からでも成功する（ロックが TMPDIR に依存しないことの裏取り）。
out="$(TMPDIR="$(mktemp -d)" CODEX_HOME="$_pas_i/.codex" HOME="$_pas_i" bash "$SNIPPET_SCRIPT" --append-global)"
assert_rc "ロック解除後は別TMPDIRからでも成功(exit0)" 0 "$?"
rm -rf "$_pas_i"
unset _pas_i _pas_i_lock rc out

# ── (j) symlink 経由と直接経路の排他収束（同じロックへ収束する）───────────────────
_pas_j="$(mktemp -d)"
mkdir -p "$_pas_j/.codex" "$_pas_j/real"
printf 'existing real\n' > "$_pas_j/real/AGENTS.md"
ln -s "$_pas_j/real/AGENTS.md" "$_pas_j/.codex/AGENTS.md"
_pas_j_reallock="$_pas_j/real/.AGENTS.md.xrev-lock"
mkdir "$_pas_j_reallock"   # 正規対象(realpath先)の直下に他プロセスのロックがある体を作る
CODEX_HOME="$_pas_j/.codex" HOME="$_pas_j" bash "$SNIPPET_SCRIPT" --append-global >/dev/null 2>&1
rc=$?
assert_rc "symlink経由でもrealpath側のロックと衝突する(exit13)" 13 "$rc"
rmdir "$_pas_j_reallock"
CODEX_HOME="$_pas_j/.codex" HOME="$_pas_j" bash "$SNIPPET_SCRIPT" --append-global >/dev/null
assert_rc "ロック解除後はsymlink経由でも成功(exit0)" 0 "$?"
assert_eq "symlinkは温存され実ファイルが更新される" "yes" "$([[ -L "$_pas_j/.codex/AGENTS.md" ]] && echo yes || echo no)"
_pas_j_real_content="$(cat "$_pas_j/real/AGENTS.md")"
assert_contains "実ファイル側の既存コンテンツは保持される" "$_pas_j_real_content" "existing real"
assert_contains "実ファイル側にスニペットが追記される" "$_pas_j_real_content" "xrev:snippet:BEGIN"
unset _pas_j_real_content
rm -rf "$_pas_j"
unset _pas_j _pas_j_reallock rc

# ── (k) dangling symlink の拒否（リンク温存）───────────────────────────────────
_pas_k="$(mktemp -d)"
mkdir -p "$_pas_k/.codex"
ln -s "$_pas_k/.codex/nonexistent.md" "$_pas_k/.codex/AGENTS.md"
CODEX_HOME="$_pas_k/.codex" HOME="$_pas_k" bash "$SNIPPET_SCRIPT" --append-global >/dev/null 2>"$_pas_k/err.log"
rc=$?
assert_rc "dangling symlink → exit10" 10 "$rc"
assert_eq "dangling symlinkは温存される(削除・置換されない)" "yes" \
  "$([[ -L "$_pas_k/.codex/AGENTS.md" ]] && echo yes || echo no)"
assert_contains "診断ログにリンク切れの案内を含む" "$(cat "$_pas_k/err.log")" "リンク切れ"
rm -rf "$_pas_k"
unset _pas_k rc

# ── (l)(m) 指摘2（3巡目）: 内容が同一でも symlink への置換・inode 差し替え・chmod のみの
#        変更は changed として無変更拒否する（exists/digest だけの比較では見逃していた）────
# 【方針（flake 修正・5巡目）】旧実装は「巨大本文で書き込みを遅くしつつバックグラウンドプロセスで
# 数秒間継続的に書き換え続ける」という継続レースで検証していたが、CI ランナー（背景 python の
# 起動が遅い環境）では変異が注入される前に書き込みが完走して ok=True になり flake した
# （リポジトリ規約「非決定的な事象を1回の試行で判定しない」に反する。ローカルで通ることは
# 決定論の証明にならない）。ここでは (m-3) の chmod テストと同じ **hook 注入方式** に統一する:
# `_xrev_write_agents_file(..., hook=...)` の hook は baseline 取得後・mv 直前チェックの直前に
# ちょうど1回呼ばれる契約なので、そこで該当の変異（内容書き換え／symlink 置換／同内容の新 inode
# への差し替え／chmod）を1回だけ確定的に行う。背景プロセス・巨大本文・sleep・秒単位の待ち時間は
# 一切不要になり、テストは高速かつ決定論的になる。
_pas_json_ok() { python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("ok"))
except Exception:
    print("")'; }
_pas_json_reason() { python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("reason",""))
except Exception:
    print("")'; }

# 汎用ヘルパ: 任意の hook 本体（python の文。4スペースインデント済みで、ローカル変数 target を
# 参照できる。追加データが要る場合は $5 以降を渡せば hook 内から sys.argv[5].. で参照できる）を
# _xrev_write_agents_file の hook として注入し、実行結果(JSON)をそのまま返す。共有実体
# _xrev_agents_write_py_src（本番の --append-global と同一定義）に薄いドライバを結合するだけで、
# 本番の呼び出し経路・env はいずれも一切経由しない。
#   引数: $1=target $2=begin $3=end $4=hook本体のpythonコード [$5..=hook本体が参照する追加データ]
#   stdin: 挿入するスニペット本文
_pas_write_with_hook() {
  local target="$1" begin="$2" end="$3" hookbody="$4"
  shift 4
  local prog
  prog="$(_xrev_agents_write_py_src)"$'\n''import json, os, sys

target = sys.argv[1]


def _hook():
'"$hookbody"'


_result = _xrev_write_agents_file(sys.argv[1], sys.argv[2], sys.argv[3], sys.stdin.read(), hook=_hook)
print(json.dumps(_result, ensure_ascii=False))
'
  python3 -c "$prog" "$target" "$begin" "$end" "$@"
}

# (l) mv 直前に対象の内容そのものが書き換えられるケース。
_pas_l="$(mktemp -d)"
_pas_l_target="$_pas_l/AGENTS.md"
printf 'baseline\n' > "$_pas_l_target"
_pas_l_result="$(printf 'hi\n' | _pas_write_with_hook "$_pas_l_target" \
  "$XREV_SNIPPET_MARKER_BEGIN" "$XREV_SNIPPET_MARKER_END" '
    with open(target, "w") as f:
        f.write("changed-by-other-process\n")
')"
assert_eq "mv直前の内容変化を検出して拒否する(ok=False)" "False" "$(printf '%s' "$_pas_l_result" | _pas_json_ok)"
assert_eq "拒否理由はchanged" "changed" "$(printf '%s' "$_pas_l_result" | _pas_json_reason)"
rm -rf "$_pas_l"
unset _pas_l _pas_l_target _pas_l_result

# (m-1) mv 直前に、通常ファイルが「同一バイト列」の別ファイルへの symlink へ置換されるケース。
# digest・exists の比較だけでは見逃す（os.replace が symlink 自体を破壊しかねない）。
_pas_m1="$(mktemp -d)"
_pas_m1_target="$_pas_m1/AGENTS.md"
printf 'baseline\n' > "$_pas_m1_target"
_pas_m1_elsewhere="$_pas_m1/elsewhere.md"
printf 'baseline\n' > "$_pas_m1_elsewhere"   # target と同一バイト列
_pas_m1_result="$(printf 'hi\n' | _pas_write_with_hook "$_pas_m1_target" \
  "$XREV_SNIPPET_MARKER_BEGIN" "$XREV_SNIPPET_MARKER_END" '
    tmp = target + ".swaptmp"
    os.symlink(sys.argv[4], tmp)
    os.replace(tmp, target)
' "$_pas_m1_elsewhere")"
assert_eq "同内容symlinkへの置換を検出して拒否する(ok=False)" "False" "$(printf '%s' "$_pas_m1_result" | _pas_json_ok)"
assert_eq "拒否理由はchanged(symlink置換)" "changed" "$(printf '%s' "$_pas_m1_result" | _pas_json_reason)"
rm -rf "$_pas_m1"
unset _pas_m1 _pas_m1_target _pas_m1_elsewhere _pas_m1_result

# (m-2) mv 直前に、内容は完全に同一のまま新しい inode の通常ファイルへ差し替えられるケース
# （エディタの atomic-save 相当）。digest だけの比較では見逃す。
_pas_m2="$(mktemp -d)"
_pas_m2_target="$_pas_m2/AGENTS.md"
printf 'baseline\n' > "$_pas_m2_target"
_pas_m2_result="$(printf 'hi\n' | _pas_write_with_hook "$_pas_m2_target" \
  "$XREV_SNIPPET_MARKER_BEGIN" "$XREV_SNIPPET_MARKER_END" '
    tmp = target + ".newtmp"
    with open(tmp, "wb") as f:
        f.write(b"baseline\n")
    os.replace(tmp, target)
')"
assert_eq "同内容でもinode差し替えを検出して拒否する(ok=False)" "False" "$(printf '%s' "$_pas_m2_result" | _pas_json_ok)"
assert_eq "拒否理由はchanged(inode差し替え)" "changed" "$(printf '%s' "$_pas_m2_result" | _pas_json_reason)"
rm -rf "$_pas_m2"
unset _pas_m2 _pas_m2_target _pas_m2_result

# (m-3) mv 直前に、内容は不変のまま chmod だけが変化するケース。
# 【mode 固有の事情】mode（パーミッション）は取り得る値の集合が小さいため、そもそも継続レースでは
# 「baseline取得前に既に変化後の値へ収束している」等の理由で運任せの検出しかできなかった
# （本番コードに env 経由のテスト専用フックを持たせる案は「利用者環境や上位エージェントから
# 継承されるだけで任意ディレクトリへ書き込める外部フック」になり安全境界にならないと判定され
# 撤回した）。(l)/(m-1)/(m-2) と同じ hook 注入方式に統一したことで、mode 固有の追加機構は不要になった。
_pas_m3="$(mktemp -d)"
_pas_m3_target="$_pas_m3/AGENTS.md"
printf 'baseline\n' > "$_pas_m3_target"
chmod 644 "$_pas_m3_target"
_pas_m3_result="$(printf 'hi\n' | _pas_write_with_hook "$_pas_m3_target" \
  "$XREV_SNIPPET_MARKER_BEGIN" "$XREV_SNIPPET_MARKER_END" '
    os.chmod(target, 0o640)
')"
assert_eq "chmodのみの変更を検出して拒否する(ok=False)" "False" "$(printf '%s' "$_pas_m3_result" | _pas_json_ok)"
assert_eq "拒否理由はchanged(chmod変更)" "changed" "$(printf '%s' "$_pas_m3_result" | _pas_json_reason)"
# 元ファイルの mode 自体は hook が直接変更したとおり(0640)のまま残る（書き込みは拒否されている）。
assert_eq "拒否時は対象のmodeがhookで変更されたまま(書き込みは行われない)" "0o640" \
  "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$_pas_m3_target")"
rm -rf "$_pas_m3"
unset _pas_m3 _pas_m3_target _pas_m3_result

# (m-3b) 対照: 同じ hook 機構を使っても、hook が何もしなければ通常どおり成功する
# （hook 機構自体が誤検出を作らないことの確認）。
_pas_m3b="$(mktemp -d)"
_pas_m3b_target="$_pas_m3b/AGENTS.md"
printf 'baseline\n' > "$_pas_m3b_target"
chmod 644 "$_pas_m3b_target"
_pas_m3b_result="$(printf 'hi\n' | _pas_write_with_hook "$_pas_m3b_target" \
  "$XREV_SNIPPET_MARKER_BEGIN" "$XREV_SNIPPET_MARKER_END" '
    pass
')"
assert_eq "hookが何もしなければok=Trueのまま(誤検出しない)" "True" "$(printf '%s' "$_pas_m3b_result" | _pas_json_ok)"
rm -rf "$_pas_m3b"
unset _pas_m3b _pas_m3b_target _pas_m3b_result

unset -f _pas_json_ok _pas_json_reason _pas_write_with_hook

unset SNIPPET_SCRIPT
