#!/usr/bin/env bash
#
# parse-review.sh — reviewer の構造化出力(JSON)をパースし severity を集計する。
#
#   入力: stdin から review JSON（review-schema.json 準拠）
#   出力: stdout に集計結果 JSON（review-loop が機械判定に使う）
#
#     {
#       "valid": true,
#       "verdict": "request_changes",
#       "counts": {"critical":1,"high":0,"medium":2,"low":0,"nit":1},
#       "blockers": 1,            # severity_blockers に該当する件数の合計
#       "total": 4
#     }
#
#   終了コード:
#     0  パース成功（valid=true）
#     1  JSON 不正・スキーマ不一致（valid=false を出力）
#
# jq 非依存（python3 で処理）。blocker の定義は config の severity_blockers に従う。
#
set -uo pipefail

_xrev_script_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" && pwd; }
: "${XREV_CONFIG:=${CLAUDE_PLUGIN_ROOT:-$(_xrev_script_dir)/..}/config/xrev.default.json}"

input="$(cat)"

# 注意: `python3 - <<'PY'` はヒアドキュメントが stdin を占有するため、レビュー本文は
# パイプではなく環境変数 XREV_REVIEW_INPUT で渡す（stdin 競合の回避）。
XREV_REVIEW_INPUT="$input" python3 - "$XREV_CONFIG" <<'PY'
import json, os, sys

cfg_path = sys.argv[1]
try:
    with open(cfg_path) as f:
        cfg = json.load(f)
except Exception:
    cfg = {}
blockers_set = set(cfg.get("severity_blockers", ["critical", "high"]))

raw = os.environ.get("XREV_REVIEW_INPUT", "")

def fail(reason):
    print(json.dumps({"valid": False, "reason": reason,
                      "verdict": None, "counts": {}, "blockers": 0, "total": 0},
                     ensure_ascii=False))
    sys.exit(1)

try:
    data = json.loads(raw)
except Exception as e:
    fail("JSON パース不可: %s" % e)

if not isinstance(data, dict):
    fail("トップレベルが object でない")

verdict = data.get("verdict")
if verdict not in ("approve", "request_changes"):
    fail("verdict が approve/request_changes でない: %r" % verdict)

findings = data.get("findings")
if not isinstance(findings, list):
    fail("findings が配列でない")

levels = ["critical", "high", "medium", "low", "nit"]
counts = {lv: 0 for lv in levels}
for i, f in enumerate(findings):
    if not isinstance(f, dict):
        fail("findings[%d] が object でない" % i)
    sev = f.get("severity")
    if sev not in counts:
        fail("findings[%d].severity が不正: %r" % (i, sev))
    # 必須フィールドの最低限チェック（file/category/message）
    for req in ("file", "category", "message"):
        if req not in f:
            fail("findings[%d] に必須フィールド %s が無い" % (i, req))
    counts[sev] += 1

blockers = sum(counts[s] for s in counts if s in blockers_set)
total = sum(counts.values())

print(json.dumps({
    "valid": True,
    "verdict": verdict,
    "counts": counts,
    "blockers": blockers,
    "total": total,
}, ensure_ascii=False))
PY
