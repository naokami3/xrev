#!/usr/bin/env bash
#
# review-loop.sh — 状態機械本体（終端判定・最大反復・エスカレーションの機械的制御）
#
# 【設計上の役割分担（重要）】
#   レビュー往復の「コード修正反映(apply_fixes)」は LLM である primary(Claude) の仕事であり、
#   シェルスクリプトでは実行できない。よって本スクリプトはループそのものを回し切らず、
#   「1ラウンド = 1回の transport.review + 終端の機械判定」だけを担う純粋な制御部とする。
#   ループの駆動（修正して次ラウンドへ）は SKILL.md の手順に従い Claude が行う。
#   こうすることで「終端条件・最大反復・blocker 集計」という暴走防止の判断は決定論的に
#   スクリプトが握り（設計1.5）、創造的な修正は Claude が握る、という分離になる。
#
#   入力:
#     stdin            … reviewer へ渡す payload（初回=設計/プラン or diff、以降=差分のみ）
#     $1 (iteration)   … 現在の反復回数（1 始まり）
#   出力(stdout): 決定 JSON
#     {
#       "decision": "converged" | "continue" | "escalate" | "invalid" | "transport_error",
#       "iteration": 2,
#       "max_iterations": 5,
#       "verdict": "request_changes",
#       "blockers": 1,
#       "counts": {...},
#       "total": 4,
#       "findings": [...],          # continue/invalid 時に Claude が修正対象に使う
#       "raw_review": "<reviewerの生JSON>"
#     }
#   終了コード: decision に対応（converged=0 / continue=10 / escalate=20 / invalid=21 / transport_error=22）
#
set -uo pipefail

_xrev_script_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" && pwd; }
SCRIPT_DIR="$(_xrev_script_dir)"
: "${XREV_CONFIG:=${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}/config/xrev.default.json}"

# shellcheck source=transport.sh
source "$SCRIPT_DIR/transport.sh"

_cfg_int() {
  python3 - "$XREV_CONFIG" "$1" "$2" <<'PY' 2>/dev/null || printf '%s' "$2"
import json, sys
try:
    with open(sys.argv[1]) as f:
        print(int(json.load(f).get(sys.argv[2], sys.argv[3])))
except Exception:
    print(sys.argv[3])
PY
}

ITER="${1:-1}"
MAX_ITER="${XREV_MAX_ITERATIONS:-$(_cfg_int max_iterations 5)}"
PAYLOAD="$(cat)"

_emit() {
  # _emit <decision> <exit> <raw_json> <parsed_json>
  local decision="$1" code="$2" raw="$3" parsed="$4"
  python3 - "$decision" "$ITER" "$MAX_ITER" "$raw" "$parsed" <<'PY'
import json, sys
decision, it, mx, raw, parsed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5]
try:
    p = json.loads(parsed) if parsed else {}
except Exception:
    p = {}
try:
    rawobj = json.loads(raw) if raw else {}
except Exception:
    rawobj = {}
out = {
    "decision": decision,
    "iteration": it,
    "max_iterations": mx,
    "verdict": p.get("verdict"),
    "blockers": p.get("blockers", 0),
    "counts": p.get("counts", {}),
    "total": p.get("total", 0),
    "findings": rawobj.get("findings", []),
    "summary": rawobj.get("summary"),
    "raw_review": raw,
}
print(json.dumps(out, ensure_ascii=False, indent=2))
PY
  exit "$code"
}

# ── 1 ラウンド実行 ───────────────────────────────────────────────────────────
RAW="$(xrev_transport_review "$PAYLOAD")"
TRANSPORT_RC=$?
if (( TRANSPORT_RC != 0 )); then
  _emit "transport_error" 22 "" ""
fi

PARSED="$(printf '%s' "$RAW" | "$SCRIPT_DIR/parse-review.sh")"
PARSE_RC=$?
if (( PARSE_RC != 0 )); then
  # reviewer が契約に反した出力（自由作文・壊れた JSON）。次工程に渡さない。
  _emit "invalid" 21 "$RAW" "$PARSED"
fi

BLOCKERS="$(printf '%s' "$PARSED" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("blockers",0))' 2>/dev/null || echo 99)"

# ── 終端判定（機械的）─────────────────────────────────────────────────────────
if [[ "$BLOCKERS" == "0" ]]; then
  # critical/high が 0 → 収束。medium 以下は blocker でないため往復を止める（設計1.5）。
  _emit "converged" 0 "$RAW" "$PARSED"
fi

if (( ITER >= MAX_ITER )); then
  # 安全弁：上限到達でも blocker が残る → 人間へエスカレーション。
  _emit "escalate" 20 "$RAW" "$PARSED"
fi

# blocker が残り、上限未満 → Claude が修正して iteration+1 で再呼び出しすべき。
_emit "continue" 10 "$RAW" "$PARSED"
