#!/usr/bin/env bash
#
# verify.sh — コード変更の共通ゲート（構文チェック + JSON 妥当性 + 生成物の最新性 + ユニットテスト）。
#
#   pre-commit フック・CI・Claude Code の Stop フックがいずれもこれを呼ぶ（DRY）。
#   依存は bash + python3 のみ。失敗が 1 件でもあれば非ゼロで終了する。
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$ROOT"

fail=0

# 1) シェルスクリプトの構文チェック
for f in scripts/*.sh hooks/*.sh tests/*.sh tools/*.sh .githooks/*; do
  [ -e "$f" ] || continue
  if ! bash -n "$f"; then
    echo "[verify] 構文エラー: $f" >&2
    fail=1
  fi
done

# 2) JSON の妥当性
for j in config/*.json references/*.json .claude-plugin/*.json hooks/hooks.json .claude/settings.json; do
  [ -f "$j" ] || continue
  if ! python3 -m json.tool "$j" >/dev/null 2>&1; then
    echo "[verify] JSON 不正: $j" >&2
    fail=1
  fi
done

# 3) 人間向け詳細仕様 HTML（docs/spec/）の最新性
#    非変更型: 一時ディレクトリへ生成してコミット済み生成物と cmp 照合する。
#    作業ツリーには一切書き込まない（md だけ直して再生成を忘れる乖離を機械的に検出する）。
specdir="$(mktemp -d "${TMPDIR:-/tmp}/xrev-spec-verify.XXXXXX")"
if bash tools/render-spec.sh --out "$specdir" >/dev/null; then
  for f in "$specdir"/*.html; do
    b="$(basename "$f")"
    if ! cmp -s "$f" "docs/spec/$b"; then
      echo "[verify] docs/spec/$b が正典 md と不整合です（tools/render-spec.sh で再生成してください）" >&2
      fail=1
    fi
  done
  for f in docs/spec/*.html; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"
    if [ ! -f "$specdir/$b" ]; then
      echo "[verify] docs/spec/$b は生成対象に無い余剰ファイルです" >&2
      fail=1
    fi
  done
else
  echo "[verify] tools/render-spec.sh の実行に失敗しました" >&2
  fail=1
fi
rm -rf "$specdir"

# 4) ユニットテスト
if ! bash tests/run.sh; then
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "[verify] 検証に失敗しました。上記を修正してください。" >&2
fi
exit "$fail"
