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
#   分岐は必ず stdout の JSON の `decision` を読んで行う（exit code ではなく）。
#   終了コードは「レビューが完了したか」だけを表す:
#     0  = レビュー完了（decision = converged / continue / escalate のいずれか）
#     21 = invalid（reviewer 契約違反でレビュー取得できず）
#     22 = transport_error（送受信失敗でレビュー取得できず）
#   ＝ continue/escalate も exit 0。非ゼロを一律エラー扱いする呼び出し元での誤判定を避けるため。
#
set -uo pipefail

_xrev_script_dir() { cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd; }
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

# 純粋関数（cmux 非依存・単体テスト可能）: 終端判定の中核。
#   入力: transport 終了コード / parse 終了コード / blocker 件数 / 反復回数 / 上限
#   出力(stdout): "<decision> <exit_code>"（副作用なし・exit しない）
#   優先順位は固定: transport 失敗 > parse 失敗 > 収束 > 上限到達 > 継続
#
# 【終了コードの方針】decision の詳細は常に stdout の JSON で返す。exit code は
#   「レビューが綺麗に完了したか」だけを表す:
#     0  = レビュー完了（converged / continue / escalate）。JSON の decision を読んで分岐する。
#     21 = invalid（reviewer が契約違反の出力。レビューを取得できず）
#     22 = transport_error（送受信失敗。レビューを取得できず）
#   こうすることで「continue は正常なのに非ゼロでエラー扱いされる」誤判定を避ける。
_xrev_decide() {
  local trc="$1" prc="$2" blockers="$3" iter="$4" max="$5"
  if (( trc != 0 )); then echo "transport_error 22"; return 0; fi
  if (( prc != 0 )); then echo "invalid 21"; return 0; fi
  # critical/high が 0 → 収束。medium 以下は blocker でないため往復を止める（設計1.5）。
  if [[ "$blockers" == "0" ]]; then echo "converged 0"; return 0; fi
  # 安全弁：上限到達でも blocker が残る → 人間へエスカレーション（レビュー自体は完了=exit 0）。
  if (( iter >= max )); then echo "escalate 0"; return 0; fi
  # blocker が残り、上限未満 → Claude が修正して iteration+1 で再呼び出しすべき（exit 0）。
  echo "continue 0"
}

# 決定 JSON を stdout に整形する（exit はしない・呼び出し側が制御）。
_format_decision() {
  # _format_decision <decision> <iter> <max> <raw_json> <parsed_json> <transport_exit_code>
  # transport_exit_code は transport の生終了コード（0=成功）。transport_error 時に原因を機械区別するため
  # transport_reason へ写像して残す（外部 exit は従来どおり 22 のまま。Phase1 診断契約）。
  python3 - "$1" "$2" "$3" "$4" "$5" "${6:-0}" <<'PY'
import json, sys
decision, it, mx, raw, parsed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5]
trc = int(sys.argv[6]) if len(sys.argv) > 6 and sys.argv[6].lstrip("-").isdigit() else 0
try:
    p = json.loads(parsed) if parsed else {}
except Exception:
    p = {}
try:
    rawobj = json.loads(raw) if raw else {}
except Exception:
    rawobj = {}
# transport 終了コード → 安定 reason（利用者向け修正案を機械的に選ぶため）
REASONS = {
    3: "cmux_unavailable", 10: "resolve_failed", 11: "send_failed", 12: "timeout",
    13: "truncated", 14: "non_terminal", 15: "ws_mismatch", 16: "ambiguous",
    17: "process_mismatch", 30: "cmux_not_found", 31: "not_in_pane",
}
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
    "transport_exit_code": trc,
    "transport_reason": REASONS.get(trc) if decision == "transport_error" else None,
}
print(json.dumps(out, ensure_ascii=False, indent=2))
PY
}

# 1 ラウンドを実行する。
#   $1 = iteration。payload は stdin。決定 JSON を stdout に出し、decision の exit コードで返る。
#   transport の呼び出しは XREV_REVIEW_FN で差し替え可能（テストでスタブを注入するため）。
_xrev_review_loop_run() {
  local iter="${1:-1}"
  local max="${XREV_MAX_ITERATIONS:-$(_cfg_int max_iterations 5)}"
  local payload; payload="$(cat)"

  local raw trc parsed prc blockers
  raw="$("${XREV_REVIEW_FN:-xrev_transport_review}" "$payload")"; trc=$?
  if (( trc == 0 )); then
    parsed="$(printf '%s' "$raw" | "$SCRIPT_DIR/parse-review.sh")"; prc=$?
    blockers="$(printf '%s' "$parsed" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("blockers",0))' 2>/dev/null || echo 99)"
  else
    raw=""; parsed=""; prc=0; blockers=0
  fi

  local decision code
  read -r decision code <<< "$(_xrev_decide "$trc" "$prc" "$blockers" "$iter" "$max")"
  _format_decision "$decision" "$iter" "$max" "$raw" "$parsed" "$trc"
  return "$code"
}

# 直接実行されたときだけ 1 ラウンドを回す。source 時（テスト）は関数定義のみ。
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  _xrev_review_loop_run "${1:-1}"
  exit $?
fi
