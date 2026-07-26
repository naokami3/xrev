#!/usr/bin/env bash
# make-adr.sh のテスト（ADR 連番・出力ディレクトリ解決・素材検証・上書き禁止・リポジトリ外拒否）。

export XREV_CONFIG="$DEFAULT_CONFIG"
MA="$SCRIPTS/make-adr.sh"
material='{"title":"テスト決定","context":"背景","decision":"採用","consequences":"利点と妥協","discussion":[{"actor":"claude","act":"propose","text":"案A"}]}'

tmp="$(mktemp -d)"
# $tmp はリポジトリ外の一時ディレクトリなので、既定拒否を回避するため
# 以下のテストは全て XREV_ADR_ALLOW_OUTSIDE=1 を明示する（特殊運用としての opt-in）。

# 既定（config の adr_dir=docs/adr）に ADR-001 を作成し、パスを返す
out="$(printf '%s' "$material" | CLAUDE_PROJECT_DIR="$tmp" XREV_ADR_ALLOW_OUTSIDE=1 "$MA")"
assert_eq "既定で docs/adr/ADR-001.md を作成" "$tmp/docs/adr/ADR-001.md" "$out"
assert_eq "ファイルが実在する" "yes" "$([[ -f "$tmp/docs/adr/ADR-001.md" ]] && echo yes || echo no)"
assert_contains "本文にタイトルが入る" "$(cat "$tmp/docs/adr/ADR-001.md")" "ADR-001: テスト決定"
assert_contains "本文に Decision が入る" "$(cat "$tmp/docs/adr/ADR-001.md")" "採用"

# 2 回目は連番が 002 になる
out="$(printf '%s' '{"title":"二件目"}' | CLAUDE_PROJECT_DIR="$tmp" XREV_ADR_ALLOW_OUTSIDE=1 "$MA")"
assert_eq "連番は 002 に増える" "$tmp/docs/adr/ADR-002.md" "$out"

# XREV_ADR_DIR（env）で出力先を変える（相対は CLAUDE_PROJECT_DIR 基準）
out="$(printf '%s' "$material" | CLAUDE_PROJECT_DIR="$tmp" XREV_ADR_DIR="docs/decisions" XREV_ADR_ALLOW_OUTSIDE=1 "$MA")"
assert_eq "XREV_ADR_DIR で docs/decisions へ" "$tmp/docs/decisions/ADR-001.md" "$out"

# 引数でその場指定（相対）。env より引数が優先
out="$(printf '%s' "$material" | CLAUDE_PROJECT_DIR="$tmp" XREV_ADR_DIR="docs/decisions" XREV_ADR_ALLOW_OUTSIDE=1 "$MA" "adr/custom")"
assert_eq "引数(相対)が env より優先" "$tmp/adr/custom/ADR-001.md" "$out"

# 引数で絶対パス指定
absdir="$tmp/abs/adr"
out="$(printf '%s' "$material" | XREV_ADR_ALLOW_OUTSIDE=1 "$MA" "$absdir")"
assert_eq "引数(絶対)はそのまま使う" "$absdir/ADR-001.md" "$out"

rm -rf "$tmp"

# 壊れた素材 JSON: parse 失敗 → exit 1、ファイルは作られない
btmp="$(mktemp -d)"
out="$(printf '%s' 'これはJSONではない' | CLAUDE_PROJECT_DIR="$btmp" XREV_ADR_ALLOW_OUTSIDE=1 "$MA" 2>&1)"; rc=$?
assert_rc "壊れたJSON(parse失敗)はrc=1" 1 "$rc"
assert_contains "parse失敗の理由がstderrに出る" "$out" "parse に失敗"
n="$(find "$btmp" -name 'ADR-*.md' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "parse失敗ではファイルが作られない" "0" "$n"

# 壊れた素材 JSON: title が空 → exit 1、ファイルは作られない
out="$(printf '%s' '{"title":""}' | CLAUDE_PROJECT_DIR="$btmp" XREV_ADR_ALLOW_OUTSIDE=1 "$MA" 2>&1)"; rc=$?
assert_rc "title空はrc=1" 1 "$rc"
assert_contains "title空の理由がstderrに出る" "$out" "title"
n="$(find "$btmp" -name 'ADR-*.md' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "title空ではファイルが作られない" "0" "$n"

# 壊れた素材 JSON: dict でない(配列) → exit 1、ファイルは作られない
out="$(printf '%s' '[1,2,3]' | CLAUDE_PROJECT_DIR="$btmp" XREV_ADR_ALLOW_OUTSIDE=1 "$MA" 2>&1)"; rc=$?
assert_rc "dictでない素材はrc=1" 1 "$rc"
n="$(find "$btmp" -name 'ADR-*.md' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "dictでない素材ではファイルが作られない" "0" "$n"
rm -rf "$btmp"

# 既存 ADR-001 があるとき、上書きせず ADR-002 に採番する
otmp="$(mktemp -d)"
mkdir -p "$otmp/docs/adr"
printf '既存のADR-001（保持されるはず）' > "$otmp/docs/adr/ADR-001.md"
out="$(printf '%s' "$material" | CLAUDE_PROJECT_DIR="$otmp" XREV_ADR_ALLOW_OUTSIDE=1 "$MA")"
assert_eq "既存ADR-001があるとADR-002に採番" "$otmp/docs/adr/ADR-002.md" "$out"
assert_contains "既存ADR-001の内容は上書きされない" "$(cat "$otmp/docs/adr/ADR-001.md")" "既存のADR-001（保持されるはず）"
rm -rf "$otmp"

# リポジトリ外出力は既定で拒否される
outside="$(mktemp -d)"
out="$(printf '%s' "$material" | "$MA" "$outside/adr" 2>&1)"; rc=$?
assert_rc "リポジトリ外出力は既定で拒否(rc1)" 1 "$rc"
assert_contains "拒否メッセージがXREV_ADR_ALLOW_OUTSIDEを案内" "$out" "XREV_ADR_ALLOW_OUTSIDE"
assert_eq "リポジトリ外拒否時はファイルが作られない" "no" "$([[ -f "$outside/adr/ADR-001.md" ]] && echo yes || echo no)"

# XREV_ADR_ALLOW_OUTSIDE=1 を明示すればリポジトリ外出力が許可される
out="$(printf '%s' "$material" | XREV_ADR_ALLOW_OUTSIDE=1 "$MA" "$outside/adr" 2>&1)"; rc=$?
assert_rc "XREV_ADR_ALLOW_OUTSIDE=1なら許可(rc0)" 0 "$rc"
assert_eq "許可時はファイルが作られる" "yes" "$([[ -f "$outside/adr/ADR-001.md" ]] && echo yes || echo no)"
rm -rf "$outside"
