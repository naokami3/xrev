#!/usr/bin/env bash
#
# install-hooks.sh — このリポジトリの git フックを有効化する。
#   core.hooksPath を .githooks に向けるだけ（追跡された .githooks/pre-commit が動くようになる）。
#   クローン後に一度実行する。
#
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
git -C "$ROOT" config core.hooksPath .githooks
chmod +x "$ROOT/.githooks/"* 2>/dev/null || true
echo "[install-hooks] core.hooksPath=.githooks を設定しました。pre-commit が有効です。"
