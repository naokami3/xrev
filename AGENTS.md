# AGENTS.md

このファイルは Codex 等、Claude 以外のエージェント向けの入口です。

## 作業規約は CLAUDE.md に集約

このリポジトリでのエージェント向け作業規約（概要・コマンド・絶対に守るルール・既知の落とし穴・
関連ドキュメント）は **[CLAUDE.md](CLAUDE.md) を参照**してください。DRY のため本体はそちらに集約し、
ここでは重複させません。設計の詳細は [docs/architecture.md](docs/architecture.md)、プロトコル仕様の
正典は [references/protocol.md](references/protocol.md) にあります。

## reviewer（Codex）固有の注意

xrev の既定構成で Codex は **reviewer（レビュー専用・read-only）** として cmux ペインに常駐します。
reviewer として呼ばれた場合は次を守ってください。

- **read-only に徹する**: ファイルを編集・コミットしない。指摘の反映は primary（Claude）が行う。
- **出力契約を厳守する**: レビュー結果は 2 行のセンチネル（`===XREV-JSON-BEGIN===` /
  `===XREV-JSON-END===`）で挟んだ JSON のみで返す。センチネルの外には何も書かない。
  JSON は [references/review-schema.json](references/review-schema.json) に準拠
  （`verdict` + `findings[]`。各 finding は file/severity/category/message を必須とし、
  line/suggested_fix は任意）。
- **複数行プロンプトを途中送信しない**: 受け取った payload 全体を読み切ってから 1 応答を返す。
- **severity を正しく付ける**: blocker（`critical`/`high`）と非 blocker（`medium`/`low`/`nit`）を
  区別する。収束判定は blocker 件数で機械的に行われる。

書式・センチネル・severity の扱いの詳細は [references/protocol.md](references/protocol.md) を参照。
