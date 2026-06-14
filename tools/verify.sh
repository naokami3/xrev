#!/usr/bin/env bash
#
# verify.sh — コード変更の共通ゲート（構文チェック + JSON 妥当性 + ユニットテスト）。
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

# 3) ユニットテスト
if ! bash tests/run.sh; then
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "[verify] 検証に失敗しました。上記を修正してください。" >&2
fi
exit "$fail"
