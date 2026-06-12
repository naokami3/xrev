---
description: クロスレビュー往復（xrev）を明示的に起動する。@xrev キーワードのフォールバック。
argument-hint: "[review|commit|pr] [--adr] <レビュー対象や依頼>"
---

# /xrev — クロスレビュー往復の明示起動

このコマンドは `@xrev` キーワード起動のフォールバック。`xrev` スキルを明示的に呼び出す。

引数 `$ARGUMENTS` を、到達点（`review` / `commit` / `pr`、既定 `review`）と ADR 有無（`--adr` で on）、
およびレビュー対象として解釈する。指定が曖昧なら、往復を始める前にユーザーへ一度だけ確認すること。

その後の手順は **xrev スキル本体（`skills/xrev/SKILL.md`）に完全に従う**:

1. 到達点と ADR 有無を一拍確認する（往復を即開始しない）。
2. reviewer 用 Codex ペイン（既定タイトル `Review Codex`）が履歴ゼロで 1 枚開いているか確認する。
3. 設計フェーズ → 実装フェーズの順でクロスレビュー往復を回す
   （`${CLAUDE_PLUGIN_ROOT}/scripts/review-loop.sh` を介す。cmux は直接叩かない）。
4. `critical`/`high` が 0 件で収束。最大反復到達時は人間へエスカレーション。
5. （任意）ADR 生成 → 到達点分岐（PR は必ずドラフト。最終トリガは人間）。

詳細な分岐・終端判定・コミット境界ルールはスキル本文を参照すること。
