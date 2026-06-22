#!/usr/bin/env bash
# transport.sh::xrev_diff_hash の決定性テスト（参照モードの同一性照合の基盤）。
# 固定 invocation の diff 生バイト列 sha256 が、同一変更で決定的・別ディレクトリでも一致・
# 異なる変更で別ハッシュになることを、一時 git リポジトリで検証する（cmux 不要）。

export XREV_CONFIG="$DEFAULT_CONFIG"
# shellcheck source=/dev/null
source "$SCRIPTS/transport.sh"

if ! command -v git >/dev/null 2>&1; then
  pass "git 不在のため diff_hash テストはスキップ"
  return 0 2>/dev/null || true
fi

# 未コミット変更（a→B）を持つ一時リポジトリを作る。
_mk_repo() {
  local d; d="$(mktemp -d)"
  (
    cd "$d" || exit 1
    git init -q
    git config user.email t@example.com
    git config user.name tester
    printf 'a\nb\nc\n' > f.txt
    git add f.txt
    git commit -qm init
    printf 'a\nB\nc\n' > f.txt
  ) >/dev/null 2>&1
  printf '%s' "$d"
}

r1="$(_mk_repo)"
h_a="$(cd "$r1" && xrev_diff_hash HEAD)"
h_b="$(cd "$r1" && xrev_diff_hash HEAD)"
assert_eq "同一 diff は同一ハッシュ（決定的）" "$h_a" "$h_b"
assert_eq "ハッシュは sha256（64桁hex）" "64" "${#h_a}"

# 同一内容の別ディレクトリでも同一ハッシュ（パスに依存しない＝別worktree/別cloneでも一致）。
r2="$(_mk_repo)"
h_c="$(cd "$r2" && xrev_diff_hash HEAD)"
assert_eq "同一変更なら別ディレクトリでも同一ハッシュ" "$h_a" "$h_c"

# 異なる変更は異なるハッシュ（別リポの誤レビューは不一致で弾ける）。
r3="$(mktemp -d)"
(
  cd "$r3" || exit 1
  git init -q; git config user.email t@example.com; git config user.name tester
  printf 'a\nb\nc\n' > f.txt; git add f.txt; git commit -qm init
  printf 'a\nb\nC\n' > f.txt
) >/dev/null 2>&1
h_d="$(cd "$r3" && xrev_diff_hash HEAD)"
assert_eq "異なる変更は異なるハッシュ" "diff" "$([[ "$h_d" != "$h_a" ]] && echo diff || echo same)"

# 単一の真実源: 関数 xrev_diff_hash と CLI サブコマンド `transport.sh diff-hash` が同一ハッシュ
# （primary/reviewer が同じコードパスを使う＝手書き invocation の同期ズレを生まないことの担保）。
h_sub="$(cd "$r1" && "$SCRIPTS/transport.sh" diff-hash HEAD)"
assert_eq "関数と diff-hash サブコマンドは同一ハッシュ（単一の真実源）" "$h_a" "$h_sub"

# diff-hash サブコマンドは不正 range で非ゼロ（空ハッシュを正常返ししない）
( cd "$r1" && "$SCRIPTS/transport.sh" diff-hash "存在しない:::range" ) >/dev/null 2>&1; rc=$?
assert_eq "不正 range の diff-hash は非ゼロ" "nonzero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)"

rm -rf "$r1" "$r2" "$r3"
