# ロードマップ

xrev のフェーズと進捗。詳細な設計は [architecture.md](architecture.md)、仕様は
[`../references/protocol.md`](../references/protocol.md) を参照。

## フェーズ 1: コアエンジン ✅ 完了

- [x] 配管抽象 `transport.sh`（cmux 依存の局所化・宛先解決・送信・応答検出・preflight）
- [x] レビュー出力のパースと severity 集計 `parse-review.sh`（jq 非依存）
- [x] 状態機械 `review-loop.sh`（1 ラウンド実行＋終端の機械判定・decision 返却）
- [x] 到達点分岐 `finalize.sh`（review / commit / ドラフト PR）
- [x] ADR 生成 `make-adr.sh`（往復ログ → `docs/adr/ADR-NNN.md`）

## フェーズ 2: プラグイン統合 ✅ 完了

- [x] 中核プレイブック `skills/xrev/SKILL.md`
- [x] `@xrev` 検知フック `hooks/user-prompt-submit.sh`（キーワード無しでは沈黙）
- [x] フォールバックコマンド `commands/xrev.md`（`/xrev`）
- [x] プラグインメタ `plugin.json`
- [x] 到達点 `stop_at` を 3 段階（引数 / env / config）で設定可能化
- [x] ADR の必要有無・出力ディレクトリを設定可能化

## フェーズ 3: 配布 ✅ 完了

- [x] マーケットプレイス配布対応（同一リポジトリ兼用 `marketplace.json`、`/plugin` で導入可能）
- [x] GitHub `naokami3/xrev` へ push 済み

## フェーズ 4: 実機検証 ✅ 完了

- [x] cmux ペイン内での配管検証（接続 preflight）
- [x] 宛先解決（`tree --all`、スピナー等の装飾タイトルの正規化）
- [x] 送信（本文一括送信＋Enter 分離）
- [x] 応答検出（新着の妥当 JSON ブロック方式）
- [x] `review-loop` の decision 分岐（approve → converged / request_changes(high) → continue）
- [x] 実機検証で判明した不具合の修正（list 範囲 → tree --all / タイトル装飾の正規化 /
      多バイト変数展開 / 空送信ガード / エコーの早期終了・古応答の誤検出 /
      TUI 折り返し＋ガター字下げの de-wrap）
- [x] ユニットテスト整備（`tests/`、純粋ロジックの回帰防止・cmux 不要）
- [x] **実際の Codex 対話セッションでの最終確認**
      - [x] Codex TUI が複数行プロンプトを受理する（送信成立）
      - [x] センチネル囲みのスキーマ準拠 JSON を返し、TUI 折り返しを de-wrap して安定取得できる
      - [x] 送信 → 検出 → parse → decision(continue) まで end-to-end 成立

## 将来の検討事項

- Codex 主・Claude レビューのプリセット（コアは主従非依存なので config 切替で対応予定）
- `transport` 実装の差し替え（`codex exec` 方式・別エージェント等）
