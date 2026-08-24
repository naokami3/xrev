# CLAUDE.md

xrev は **設計段階からのクロスレビュー往復**を人間の操作なしで AI エージェント同士に
行わせる Claude Code プラグイン。既定構成は primary=Claude（設計・実装・修正反映）、
reviewer=Codex（レビュー専用・read-only）。往復は cmux のペイン間通信を介し、
`critical`/`high` が 0 件になるまで指摘を反映して収束する。実装言語は bash + python3。

設計の詳細・往復手順・構造は [docs/architecture.md](docs/architecture.md) を参照。
プロトコル仕様の正典は [references/protocol.md](references/protocol.md)。

## コマンド

```bash
bash tests/run.sh                         # ユニットテスト（cmux 不要・変更後は必ず実行）
tools/render-spec.sh                      # docs/spec/ の HTML を正典 md から再生成
tools/render-spec.sh --site _site         # 公開サイトをローカルに組み立てて確認（_site は非追跡）
bash -n scripts/*.sh hooks/*.sh           # 構文チェック
scripts/transport.sh ping                 # cmux 接続確認（cmux ペイン内で実行）
scripts/transport.sh resolve              # reviewer ペインの宛先解決確認
scripts/transport.sh doctor               # 外部ツール契約の一括診断（バージョンアップ後はまず実行）
scripts/transport.sh review "<payload>"   # 1 往復の手動テスト（実機）
```

利用者の導入: `/plugin marketplace add naokami3/xrev` →
`/plugin install xrev@xrev-marketplace`。

## コーディング規約

- 依存は **bash + python3 のみ**（`jq` は使わない。JSON は python3 で処理）。
- コメント・コミットメッセージは **日本語**。
- コミット境界は **1 コミット = 1 論理変更**。レビュー指摘の修正は元の変更にまとめ、
  別コミットに分けない。
- **テストは強制**: コード変更時は `tools/verify.sh`（構文 + JSON + テスト）が pre-commit /
  CI / Stop フックで走る。純粋ロジックを変えたらテストも追加・更新する（[CONTRIBUTING.md](CONTRIBUTING.md)）。

## 絶対に守るルール

1. **中間ファイルをリポジトリに生成しない** — エージェント間のやり取りはファイルを介さない。
   意図して残す成果物だけが例外: ADR（`docs/adr/`）と、docs/spec/ の生成 HTML
   （`tools/render-spec.sh` が正典 md から生成。最新性は `tools/verify.sh` が検査）。
2. **cmux 依存を `scripts/transport.sh` の外へ漏らさない** — スキル・他スクリプトから
   cmux を直接叩かない。通信層の差し替え可能性を壊さないため。
3. **`@xrev`（設定の `keyword`）や明示指示が無いのに発火しない** — 暴発防止。
4. **PR は非ドラフトで作らない／人間の確認なしにマージ・確定しない** — 人間の最終確認を
   物理的に保証するため。`scripts/finalize.sh` の PR は `--draft` 固定。
5. **既定で commit / pr へ進まない** — 既定の完了アクションは最も安全な `review`。
6. **リポジトリ名やコアに特定エージェント名（`cc-` 等）を固定しない** — 主従非依存を保つ。
   主従は `config/xrev.default.json` の `primary`/`reviewer` で切り替える。
7. **上限到達（escalate）時に人間を飛ばして完了アクションへ進めない** — 必ずエスカレーションする。

## 既知の落とし穴

- **primary は cmux ペイン内で起動すること（必須）**: cmux ソケットは認証が要り、認証情報は
  cmux ペイン内シェルにのみ自動注入される。通常ターミナル（Apple Terminal 等）から起動すると
  通信層が接続できず、`transport.sh` が preflight で `exit 31` を返す。`scripts/transport.sh ping` で確認。
- **reviewer ペインは固定タイトル `Review Codex` で 1 枚、履歴ゼロで開く**: 作業切替時は Codex を
  再起動して履歴を切る。cmux のセッション復元が前作業を復元しないよう注意。
- **cmux の実挙動は推測しない**: surface の直下プロセス構成、`top` の name 列、ソケットの
  UTF-8 チャンク欠陥、composer の消去可否など、公式ドキュメントに無く実測でしか分からない挙動が
  設計前提になっている。通信層に手を入れる前に [docs/cmux-behavior.md](docs/cmux-behavior.md) を読むこと。
  過去に「直下プロセスが1件」という未検証の前提で往復が全停止した実績がある。
- **非決定的な事象を1回の試行で判定しない**: cmux の送信は間欠的に失敗する。単調性を仮定した
  二分探索は誤った境界を返す（実際に2度誤った結論が出ている）。

環境・依存（macOS の cmux、完了アクション `pr` の `gh`、cmux のバージョン揺れ）の詳細は
[docs/architecture.md](docs/architecture.md)、実測知見は
[docs/cmux-behavior.md](docs/cmux-behavior.md) を参照。

## 関連ドキュメント

- 構造・設計原則・transport プロトコル要約 → [docs/architecture.md](docs/architecture.md)
- cmux の実挙動（実測ベース・設計前提） → [docs/cmux-behavior.md](docs/cmux-behavior.md)
- フェーズと進捗 → [docs/roadmap.md](docs/roadmap.md)
- 脅威モデル（何を守り何を守らないか） → [docs/security-design.md](docs/security-design.md)
- 往復の手順そのもの → [skills/xrev/SKILL.md](skills/xrev/SKILL.md)
- プロトコル詳細の正典 → [references/protocol.md](references/protocol.md)
- 利用者向け概要・導入 → [README.md](README.md) / 貢献規約 → [CONTRIBUTING.md](CONTRIBUTING.md)
