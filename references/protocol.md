# xrev プロトコル詳細（索引）

必要時のみ読む補足資料。日常の運用は `skills/xrev/SKILL.md` に従えばよい。
往復の内部仕様（メッセージ書式・act ラベル・終了コード設計）の**正典は
[`protocol/`](protocol/) 配下の分割ファイル**にある。本書は索引で、分割前の見出しを
互換アンカーとして保持する（`references/protocol.md#見出し` 形式の既存リンクを壊さないため）。

| 分割先 | 内容 |
|--------|------|
| [protocol/message-format.md](protocol/message-format.md) | メッセージ書式・センチネル・1物理行エンコード・`XREV-ASCII-V1`・wire 長上限・切り詰め検出・stdin 受け渡し |
| [protocol/review-contract.md](protocol/review-contract.md) | severity と verdict・act ラベル（会話終端の思想） |
| [protocol/exit-codes.md](protocol/exit-codes.md) | review-loop / parse-review / transport の終了コード設計 |
| [protocol/config.md](protocol/config.md) | 設定キー一覧・reviewer の auto 解決（D1）・実行コンテキスト・ADR / stop_at の解決順 |
| [protocol/delivery-gates.md](protocol/delivery-gates.md) | 宛先解決と送信ゲート（Phase1）・送信の堅牢化 |
| [protocol/reviewer-lifecycle.md](protocol/reviewer-lifecycle.md) | reviewer ペインの自動生成（Phase1c）・read-only 強制・グローバル導入（D3） |
| [protocol/reference-mode.md](protocol/reference-mode.md) | 参照モード（Phase2: diff 本文を送らないコンテキスト削減） |
| [protocol/doctor.md](protocol/doctor.md) | `transport.sh doctor`（外部ツール契約の一括診断） |

以下は分割前の見出し（互換アンカー）。本文は各リンク先へ移動した。

## 1. メッセージ書式（reviewer への依頼と応答）

→ [protocol/message-format.md](protocol/message-format.md)

### 送信プロトコル（1物理行エンコード・ADR-001）

→ [protocol/message-format.md](protocol/message-format.md)（「切り詰め検出（reviewer 種別対応・C2）」を含む）

### wire encoding `XREV-ASCII-V1`（ASCII-only・暫定措置）

→ [protocol/message-format.md](protocol/message-format.md)

### wire 長の上限（fail closed）

→ [protocol/message-format.md](protocol/message-format.md)

### 巨大な payload の受け渡し（stdin 経由・env/argv 上限の回避）

→ [protocol/message-format.md](protocol/message-format.md)

### reviewer 出力の例

→ [protocol/message-format.md](protocol/message-format.md)

## 2. severity と verdict

→ [protocol/review-contract.md](protocol/review-contract.md)

## 3. act ラベル（会話終端の思想）

→ [protocol/review-contract.md](protocol/review-contract.md)

## 4. 終了コード設計

→ [protocol/exit-codes.md](protocol/exit-codes.md)（review-loop.sh / parse-review.sh / transport.sh）

## 5. 設定キー一覧（`config/xrev.default.json`）

→ [protocol/config.md](protocol/config.md)

### reviewer の auto 解決と semantic kind（D1）

→ [protocol/config.md](protocol/config.md)

### print-agents-snippet.sh --append-global（D3・グローバル導入）

→ [protocol/reviewer-lifecycle.md](protocol/reviewer-lifecycle.md)

### 送信の堅牢化（実機知見）

→ [protocol/delivery-gates.md](protocol/delivery-gates.md)

### reviewer ペインの自動生成（Phase1c: create-if-missing・冪等）

→ [protocol/reviewer-lifecycle.md](protocol/reviewer-lifecycle.md)

### reviewer read-only 強制（最終 argv の意味検証が正典）

→ [protocol/reviewer-lifecycle.md](protocol/reviewer-lifecycle.md)

### 参照モード（Phase2: コンテキスト削減・diff 本文を送らない）

→ [protocol/reference-mode.md](protocol/reference-mode.md)

### 宛先解決と送信ゲート（Phase1: 誤配送・shell 誤実行の防止）

→ [protocol/delivery-gates.md](protocol/delivery-gates.md)

### 実行コンテキスト（重要）

→ [protocol/config.md](protocol/config.md)

### ADR（必要有無・出力先）の解決順

→ [protocol/config.md](protocol/config.md)

### 完了アクション（stop_at）の解決順

→ [protocol/config.md](protocol/config.md)

### `transport.sh doctor`（外部ツール契約の一括診断）

→ [protocol/doctor.md](protocol/doctor.md)
