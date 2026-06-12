#!/usr/bin/env bash
#
# make-adr.sh — 往復ログを ADR(docs/adr/ADR-NNN.md) に整形する（--adr 指定時のみ呼ばれる）。
#
# 【ファイル生成方針との関係】
#   xrev は中間ファイルを一切生成しない（設計1.2）。ADR だけが唯一の例外で、
#   「意図して残す成果物」として docs/adr/ に出力する（設計1.6）。
#
#   使い方:
#     printf '%s' "$material_json" | make-adr.sh                  # 出力先は env/config/既定
#     printf '%s' "$material_json" | make-adr.sh docs/decisions   # 出力先をその場指定（相対）
#     printf '%s' "$material_json" | make-adr.sh /abs/adr/dir      # 出力先をその場指定（絶対）
#
#   入力(stdin): ADR 素材 JSON（Claude が往復結果から組み立てて渡す）
#     {
#       "title": "Codex レビュー宛先を命名規約で解決する",
#       "context": "...なぜこの議論が必要だったか（元課題 / diff の背景）",
#       "decision": "...最終的に何を採用したか",
#       "consequences": "...利点と妥協点",
#       "discussion": [
#         {"actor": "claude", "act": "propose", "text": "..."},
#         {"actor": "codex",  "act": "react",   "text": "...", "severity": "high"},
#         {"actor": "claude", "act": "decide",  "text": "..."}
#       ]
#     }
#   出力: docs/adr/ADR-NNN.md を新規作成し、そのパスを stdout に出力。
#
#   出力ディレクトリの解決順（高 → 低）:
#     1) 引数 $1（その場指定。相対なら下記 ROOT 基準、絶対パスはそのまま）
#     2) 環境変数 XREV_ADR_DIR
#     3) config の adr_dir
#     4) docs/adr（既定）
#   出力先ルート(相対パスの基準)は CLAUDE_PROJECT_DIR（無ければ git トップ、無ければ CWD）。
#
set -uo pipefail

_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" && pwd; }
: "${XREV_CONFIG:=${CLAUDE_PLUGIN_ROOT:-$(_dir)/..}/config/xrev.default.json}"

# config から adr_dir の既定を読む（jq 非依存）。
_cfg_adr_dir() {
  python3 - "$XREV_CONFIG" <<'PY' 2>/dev/null || printf 'docs/adr'
import json, sys
try:
    with open(sys.argv[1]) as f:
        print(json.load(f).get("adr_dir", "docs/adr"))
except Exception:
    print("docs/adr")
PY
}

# 相対パスの基準となるリポジトリルートを決定
ROOT="${CLAUDE_PROJECT_DIR:-}"
if [[ -z "$ROOT" ]]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

# 出力ディレクトリを解決（引数 → XREV_ADR_DIR → config.adr_dir → docs/adr）
ADR_DIR_SPEC="${1:-}"
[[ -n "$ADR_DIR_SPEC" ]] || ADR_DIR_SPEC="${XREV_ADR_DIR:-}"
[[ -n "$ADR_DIR_SPEC" ]] || ADR_DIR_SPEC="$(_cfg_adr_dir)"
[[ -n "$ADR_DIR_SPEC" ]] || ADR_DIR_SPEC="docs/adr"

# 絶対パスはそのまま、相対パスは ROOT 基準にする。
case "$ADR_DIR_SPEC" in
  /*) ADR_DIR="$ADR_DIR_SPEC" ;;
  *)  ADR_DIR="$ROOT/$ADR_DIR_SPEC" ;;
esac
mkdir -p "$ADR_DIR"

# 次の ADR 番号を決定（ADR-001 形式。既存の最大値 +1）。
next_num() {
  local max=0 n
  shopt -s nullglob
  for f in "$ADR_DIR"/ADR-*.md; do
    n="$(basename "$f")"
    n="${n#ADR-}"; n="${n%%-*}"; n="${n%.md}"
    if [[ "$n" =~ ^[0-9]+$ ]] && (( 10#$n > max )); then max=$((10#$n)); fi
  done
  printf '%03d' $(( max + 1 ))
}

NUM="$(next_num)"
INPUT="$(cat)"

OUT_PATH="$ADR_DIR/ADR-$NUM.md"

# 素材 JSON はヒアドキュメント stdin と競合するため環境変数 XREV_ADR_INPUT で渡す。
XREV_ADR_INPUT="$INPUT" python3 - "$NUM" "$OUT_PATH" <<'PY'
import json, os, sys

num, out_path = sys.argv[1], sys.argv[2]
raw = os.environ.get("XREV_ADR_INPUT", "")
try:
    d = json.loads(raw)
except Exception:
    d = {}

title = d.get("title") or "（タイトル未設定）"
context = d.get("context") or "（背景未記入）"
decision = d.get("decision") or "（決定未記入）"
consequences = d.get("consequences") or "（影響未記入）"
discussion = d.get("discussion") or []

def fmt_log(items):
    if not items:
        return "（往復ログなし）"
    lines = []
    for it in items:
        actor = it.get("actor", "?")
        act = it.get("act", "")
        sev = it.get("severity")
        text = (it.get("text") or "").strip().replace("\n", " ")
        tag = f"[{actor}/{act}" + (f"/{sev}" if sev else "") + "]"
        lines.append(f"- {tag} {text}")
    return "\n".join(lines)

md = f"""# ADR-{num}: {title}

## Status: Accepted

## Context
{context}

## Decision
{decision}

## Consequences
{consequences}

## Discussion log
{fmt_log(discussion)}
"""

with open(out_path, "w") as f:
    f.write(md)
print(out_path)
PY
