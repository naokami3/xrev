# AGENTS.md

このファイルは、**xrev リポジトリ自身を codex で開発するとき**の Codex 向け入口です
（Claude 以外のエージェントが xrev のコードに触るときの導線）。

## 作業規約は CLAUDE.md に集約

このリポジトリでのエージェント向け作業規約（概要・コマンド・絶対に守るルール・既知の落とし穴・
関連ドキュメント）は **[CLAUDE.md](CLAUDE.md) を参照**してください。DRY のため本体はそちらに集約し、
ここでは重複させません。設計の詳細は [docs/architecture.md](docs/architecture.md)、プロトコル仕様の
正典は [references/protocol.md](references/protocol.md) にあります。

## codex を primary にして xrev の往復を回す（主従反転プリセット）

xrev のコアは主従非依存で、`config` の `primary`/`reviewer` を入れ替えれば codex が設計・実装・
修正反映を担う側（primary）、Claude が reviewer（レビュー専用・plan mode）になる構成も動きます。
その手順書は **[references/codex-primary-playbook.md](references/codex-primary-playbook.md)**
（`config/xrev.codex-primary.json` を使う）にまとめてあります。既定構成（primary=Claude・
reviewer=Codex）の正典である [skills/xrev/SKILL.md](skills/xrev/SKILL.md) と同一のスクリプト契約を
codex 視点で書き直したものです。

## reviewer（Codex）固有の注意（既定構成: primary=Claude・reviewer=Codex）

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

## reviewer（Claude）固有の注意（主従反転プリセット: primary=Codex・reviewer=Claude）

主従反転プリセットでは Claude Code が `--permission-mode plan` で reviewer として常駐します。

- **出力契約は codex reviewer と同一**: 上記「reviewer（Codex）固有の注意」と同じセンチネル・
  JSON スキーマ・severity 区分に従う（reviewer 種別によらず出力契約は共通）。
- **plan mode で動く**: ファイル編集・コミットはしない（read-only）。
- **復号契約**: wire の `LEN_*` 不一致・末尾 `END_ROUND_<id>` マーカー欠落を検出したら、レビューを
  行わず `decode_error` の finding を 1 件だけ返す。この finding は severity 設定に関わらず常に
  blocker として集計される。
- **実装フェーズは参照モードで動く（送信完全性は inline では成立しない）**: 送信完全性は
  全文一致照合（codex 向けのペースト文字数照合とは異なる方式）で検証されるが、実測では空
  payload でも最小 wire（約3,231文字）が composer の全文可視上限（約800文字）を常に超えるため、
  inline（本文を wire にそのまま載せる方式）は payload の内容に関わらず primary 側で送信前に
  拒否される（`exit 28`）。そのため primary は実装フェーズで必ず参照モードを使い、reviewer に
  自分の作業ツリーで diff を取得させる（`transport.sh diff-hash` を実行し結果を返す）。
  reviewer 自身が payload の長さを気にすることは無いが、応答が来ない・`decision=transport_error`
  になる場合はこの inline 制約が原因のことがある。設計フェーズのクロスレビューは claude reviewer
  では現状非対応（常に inline になるため）。

詳細は [references/codex-primary-playbook.md](references/codex-primary-playbook.md) と
[references/protocol.md](references/protocol.md) を参照。
