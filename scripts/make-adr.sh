#!/usr/bin/env bash
#
# make-adr.sh — 往復ログを ADR(docs/adr/ADR-NNN.md) に整形する（--adr 指定時のみ呼ばれる）。
#
# 【ファイル生成方針との関係】
#   xrev は中間ファイルを一切生成しない（設計1.2）。ADR だけが唯一の例外で、
#   「意図して残す成果物」として docs/adr/ に出力する（設計1.6）。
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
#   出力先ルートは CLAUDE_PROJECT_DIR（無ければ現在の git トップ、無ければ CWD）。
#
set -uo pipefail

# 出力先リポジトリのルートを決定
ROOT="${CLAUDE_PROJECT_DIR:-}"
if [[ -z "$ROOT" ]]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
ADR_DIR="$ROOT/docs/adr"
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
