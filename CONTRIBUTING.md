# コントリビューションガイド

xrev への貢献を歓迎します。以下は設計上の不変条件です。**変更する場合は必ず議論してから**にしてください。

## 守るべき設計原則

1. **cmux 依存は `scripts/transport.sh` だけに閉じ込める。** 他のスクリプト・スキル・フックから
   cmux コマンドを直接叩かない。配管の差し替え可能性を壊さないこと。
2. **中間ファイルを生成しない。** エージェント間のやり取りはファイルを介さない。唯一の例外は ADR
   （`docs/adr/`、意図して残す成果物）。
3. **コアは主従非依存に保つ。** 特定エージェント名（`cc-` 等）をコアやリポジトリ名に固定しない。
   主従は `config` のプリセットで表現する。
4. **暴発させない。** `@xrev`（設定の `keyword`）や明示指示が無いときは完全に沈黙する。
5. **人間の最終チェックを物理的に保証する。** PR は必ずドラフト。非ドラフト PR を作る経路を追加しない。
6. **既定は最も安全な `review`。** 既定で commit / pr へ進めない。
7. **終端は機械的に判定する。** 収束条件（blocker 0 件）と最大反復はスクリプトが決定論的に握る。

## 開発メモ

- スクリプトは bash + python3 のみに依存（`jq` は使わない）。
- 変更後は `bash tests/run.sh`（ユニットテスト・cmux 不要）と `bash -n scripts/*.sh` を実行する。
  純粋ロジックを変えたらテストも追加・更新する（詳細は [`tests/README.md`](tests/README.md)）。
- cmux を要する配管の通し確認は実機（cmux 上の `Review Codex` ペイン）が必要。
- コメント・コミットメッセージは日本語で記述する。

## テストの強制（多層）

コードの追加・修正時にテストを必ず通すよう、3 層で強制している。共通ゲートは
`tools/verify.sh`（構文チェック + JSON 妥当性 + `tests/run.sh`）。

1. **git pre-commit フック** — `scripts/ hooks/ tools/ config/ tests/` をステージしてコミットすると
   `tools/verify.sh` が走り、失敗ならコミット中止。コードを変えたのにテスト未更新なら注意喚起する。
   - 有効化（クローン後に一度）: `bash tools/install-hooks.sh`（`core.hooksPath=.githooks` を設定）。
   - 緊急回避: `git commit --no-verify`（CI は回避できない）。
2. **CI（GitHub Actions）** — `.github/workflows/ci.yml` が push / PR で `tools/verify.sh` を実行する
   越えられないゲート。
3. **Claude Code フック** — `.claude/settings.json`:
   - PostToolUse（Edit/Write）で編集した `.sh` の構文・`.json` の妥当性を即時チェック。
   - Stop で、監視対象に変更があるとき `tools/verify.sh` を実行し、失敗なら終了前に差し戻す
     （`stop_hook_active` で無限ループを防止）。

## コミット境界

- 1 コミット = 1 つの論理的変更。レビュー指摘の修正は元の変更にまとめ、別コミットにしない。
