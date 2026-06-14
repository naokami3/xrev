#!/usr/bin/env bash
# make-adr.sh のテスト（ADR 連番・出力ディレクトリ解決）。

export XREV_CONFIG="$DEFAULT_CONFIG"
MA="$SCRIPTS/make-adr.sh"
material='{"title":"テスト決定","context":"背景","decision":"採用","consequences":"利点と妥協","discussion":[{"actor":"claude","act":"propose","text":"案A"}]}'

tmp="$(mktemp -d)"

# 既定（config の adr_dir=docs/adr）に ADR-001 を作成し、パスを返す
out="$(printf '%s' "$material" | CLAUDE_PROJECT_DIR="$tmp" "$MA")"
assert_eq "既定で docs/adr/ADR-001.md を作成" "$tmp/docs/adr/ADR-001.md" "$out"
assert_eq "ファイルが実在する" "yes" "$([[ -f "$tmp/docs/adr/ADR-001.md" ]] && echo yes || echo no)"
assert_contains "本文にタイトルが入る" "$(cat "$tmp/docs/adr/ADR-001.md")" "ADR-001: テスト決定"
assert_contains "本文に Decision が入る" "$(cat "$tmp/docs/adr/ADR-001.md")" "採用"

# 2 回目は連番が 002 になる
out="$(printf '%s' '{"title":"二件目"}' | CLAUDE_PROJECT_DIR="$tmp" "$MA")"
assert_eq "連番は 002 に増える" "$tmp/docs/adr/ADR-002.md" "$out"

# XREV_ADR_DIR（env）で出力先を変える（相対は CLAUDE_PROJECT_DIR 基準）
out="$(printf '%s' "$material" | CLAUDE_PROJECT_DIR="$tmp" XREV_ADR_DIR="docs/decisions" "$MA")"
assert_eq "XREV_ADR_DIR で docs/decisions へ" "$tmp/docs/decisions/ADR-001.md" "$out"

# 引数でその場指定（相対）。env より引数が優先
out="$(printf '%s' "$material" | CLAUDE_PROJECT_DIR="$tmp" XREV_ADR_DIR="docs/decisions" "$MA" "adr/custom")"
assert_eq "引数(相対)が env より優先" "$tmp/adr/custom/ADR-001.md" "$out"

# 引数で絶対パス指定
absdir="$tmp/abs/adr"
out="$(printf '%s' "$material" | "$MA" "$absdir")"
assert_eq "引数(絶対)はそのまま使う" "$absdir/ADR-001.md" "$out"

rm -rf "$tmp"
