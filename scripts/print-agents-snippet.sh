#!/usr/bin/env bash
#
# print-agents-snippet.sh — 導入スニペット出力（C4b）。
#
# 役割:
#   codex を primary にして xrev（主従反転プリセット）を使う利用者プロジェクト向けに、
#   AGENTS.md へ貼り付けるスニペットを stdout に出力する。**ファイルは一切生成しない**
#   （貼り付け・保存は人間が行う）。
#
# 埋め込むパスは XREV_ROOT（このスクリプト自身の位置から `cd .. && pwd` で解決した絶対パス）の
# 1 点のみ。playbook・XREV_CONFIG・各スクリプトはスニペット内で $XREV_ROOT 相対に解決させる
# （単一ルート解決でバージョン不整合を構造的に防止する）。
#
# 入出力仕様:
#   stdin  … 使わない
#   stdout … AGENTS.md へ貼るスニペット本文
#   stderr … プラグインキャッシュ配下から実行された場合の補助警告のみ（出力自体は止めない）
#   exit   … 常に 0（スニペット生成自体は失敗し得ない）
#
set -uo pipefail

_dir() { cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd; }
XREV_ROOT="$(cd "$(_dir)/.." && pwd)"

# 補助警告: プラグインキャッシュ配下からの実行を検出する（安定 checkout からの実行が前提。
# README で利用者責任として明示する運用のため、ここでは警告に留め出力自体は止めない）。
case "$XREV_ROOT" in
  */plugins/cache/*)
    echo "[print-agents-snippet] 警告: プラグインキャッシュ配下（${XREV_ROOT}）から実行されています。" \
         "キャッシュはアップデートで再配置されるため、このスニペットに埋め込む XREV_ROOT が" \
         "無効になるおそれがあります。安定した checkout（git clone 済みのディレクトリ等）から" \
         "実行し直すことを推奨します。" >&2
    ;;
esac

# スニペット本文は python3 の文字列フォーマットで組み立てる（シェルのクォート地獄を避ける）。
# python コードはクォート済みヒアドキュメント(<<'PY')で渡すのでシェル展開は起きない。
# 埋め込む実値は XREV_ROOT の絶対パス 1 点のみで、それ以外はすべて $XREV_ROOT のリテラル参照
# （貼り付け先で実行されるときに解決される）。
# 本文中に bash の `{ ... }` が多数出てくるため str.format は使わず、単純な置換にする
# （プレースホルダ __XREV_ROOT_ABS__ を実パスへ置換。中括弧の二重エスケープを避ける）。
XREV_ROOT_ABS="$XREV_ROOT" python3 <<'PY'
import os

root = os.environ["XREV_ROOT_ABS"]

print("""## xrev（codex 主プレイブック・主従反転プリセット）

このプロジェクトは xrev の主従反転プリセット（primary=codex / reviewer=claude）を使う。
以下を AGENTS.md に貼り付けて使う（このファイル自体は生成されていない。貼り付けは人間が行う）。

### XREV_ROOT の設定

```bash
export XREV_ROOT="__XREV_ROOT_ABS__"
```

### 前提検査（使う前に毎回確認する）

```bash
test -d "$XREV_ROOT" || { echo "XREV_ROOT ($XREV_ROOT) が見つかりません"; exit 1; }
for f in scripts/transport.sh scripts/review-loop.sh \\
         references/codex-primary-playbook.md config/xrev.codex-primary.json; do
  test -e "$XREV_ROOT/$f" || { echo "期待するファイルがありません: $XREV_ROOT/$f"; exit 1; }
done
"$XREV_ROOT/scripts/transport.sh" doctor
```

### 発火判定

依頼文を $XREV_ROOT/scripts/keyword-match.sh にかけて判定する（config の keyword を
ハードコードしない。既定は @xrev）。

```bash
printf '%s' "$依頼文" | XREV_CONFIG="$XREV_ROOT/config/xrev.codex-primary.json" \\
  bash "$XREV_ROOT/scripts/keyword-match.sh"
```

### 手順

発火したら $XREV_ROOT/references/codex-primary-playbook.md を読み、その手順に従うこと。
""".replace("__XREV_ROOT_ABS__", root))
PY
