#!/usr/bin/env bash
#
# keyword-match.sh — キーワード判定の単一の真実源（C4c）。
#
# 役割:
#   依頼文テキストに config の keyword（既定 @xrev）が境界付きで含まれるかを判定する。
#   hooks/user-prompt-submit.sh のキーワード判定ロジック（config の keyword 読み・語境界判定・
#   fenced/inline コードブロック除外）をここへ切り出し、hook はこのヘルパを呼ぶだけにする
#   （挙動不変のリファクタ。将来の C4a プレイブック・C4b スニペットも同じヘルパで発火判定する）。
#
# 入出力仕様:
#   stdin  … 依頼文テキスト（プレーン文字列。JSON ではない）
#   stdout … 出力しない
#   exit 0 … キーワードが（境界付きで）発火する
#   exit 1 … 発火しない
#
set -uo pipefail

_dir() { cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd; }
CONFIG="${XREV_CONFIG:-${CLAUDE_PLUGIN_ROOT:-$(_dir)/..}/config/xrev.default.json}"

# python3 でキーワード読み・境界判定を行う（jq 非依存）。
# 依頼文は stdin のまま python3 へ渡す（env/argv 経由にしない）。env は 1 本あたり
# MAX_ARG_STRLEN（Linux 約128KiB）の上限があり、巨大な貼り付けを含む依頼文で判定自体が
# 失敗するため（protocol.md「巨大な payload の受け渡し」と同じ理由・同じ流儀）。
# `python3 - <<'PY'` は stdin をプログラム本文が占有してしまうので、`read -r -d ''` で
# 本文を変数化して `python3 -c` に渡し、stdin を依頼文のために空ける
# （bash 3.2 の command substitution とヒアドキュメントの相性問題も同時に回避する）。
read -r -d '' _XREV_KWM_PROG <<'PY' || true
import json, re, sys

config_path = sys.argv[1]
try:
    with open(config_path) as f:
        keyword = json.load(f).get("keyword", "@xrev")
except Exception:
    keyword = "@xrev"

# 依頼文は stdin から読む（巨大な貼り付けでも env/argv 上限に当たらない）。
text = sys.stdin.read()


def strip_noise(text: str) -> str:
    """誤発火の温床（コードブロック・インラインコード・引用・diff）を除去する。

    境界判定(is_triggered)から呼ばれる下請け。ここで除去した残りのテキストにのみ
    キーワード境界照合をかける。
    """
    lines = text.split("\n")
    kept = []
    in_fence = False
    fence_marker = None
    for line in lines:
        stripped = line.lstrip()
        if in_fence:
            if stripped.startswith(fence_marker):
                # 閉じ fence 行。閉じが無ければ末尾まで in_fence のまま破棄され続ける。
                in_fence = False
                fence_marker = None
            continue
        if stripped.startswith("```") or stripped.startswith("~~~"):
            in_fence = True
            fence_marker = stripped[:3]
            continue
        kept.append(line)

    # 同一行内の `...`（インラインコード）を除去する。
    kept = [re.sub(r"`[^`\n]*`", "", line) for line in kept]

    # 引用行（行頭 >）を除去する。
    kept = [line for line in kept if not line.lstrip().startswith(">")]

    # diff 由来行を除去する。
    diff_prefixes = ("diff --git", "@@ ", "+++ ", "--- ", "index ")
    kept = [line for line in kept if not line.lstrip().startswith(diff_prefixes)]

    return "\n".join(kept)


def is_triggered(text: str, kw: str) -> bool:
    """prompt と keyword を受け、境界付きでキーワードが発火するかを返す純粋関数。"""
    if not kw:
        return False
    cleaned = strip_noise(text)
    # 直前が英数字/_/@/./- なら不一致（"foo@xrev" 等の部分一致を除外）。
    # 直後が英数字/_/- なら不一致（"@xrevfoo" 等を除外。日本語等はそのまま発火）。
    pattern = re.compile(
        r"(?<![A-Za-z0-9_@.\-])" + re.escape(kw) + r"(?![A-Za-z0-9_\-])"
    )
    return pattern.search(cleaned) is not None


sys.exit(0 if is_triggered(text, keyword) else 1)
PY

python3 -c "$_XREV_KWM_PROG" "$CONFIG"
