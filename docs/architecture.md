# アーキテクチャ

xrev のディレクトリ構造・設計原則・transport プロトコルの要約をまとめる。
メッセージ書式・センチネル・act ラベル・終了コード・設定キーの**詳細仕様の正典**は
[`../references/protocol.md`](../references/protocol.md) にあるので、ここでは重複させずに要約と
リンクに留める。

## ディレクトリ構造

```
xrev/
├── .claude-plugin/
│   ├── plugin.json            # プラグインメタ（name/version/skills/commands/hooks）
│   └── marketplace.json       # マーケットプレイス定義（同一リポジトリ兼用 / source "./"）
├── skills/xrev/SKILL.md       # 中核プレイブック（発火条件・一拍確認・設計/実装フェーズ・終端判定・ADR・到達点・コミット境界）
├── commands/xrev.md           # /xrev（@xrev キーワード起動のフォールバック）
├── hooks/
│   ├── user-prompt-submit.sh  # @xrev 検知時のみコンテキスト注入。無ければ無出力（jq 非依存・python3）
│   └── hooks.json             # ${CLAUDE_PLUGIN_ROOT} 経由でフック宣言
├── scripts/
│   ├── transport.sh           # 配管抽象。cmux 依存をここだけに局所化。宛先解決・送信・応答検出・preflight
│   ├── parse-review.sh        # 構造化レビューの妥当性検証と severity 集計（jq 非依存）
│   ├── review-loop.sh         # 1 ラウンド実行＋終端の機械判定（decision を返す）。修正反映は LLM が担う
│   ├── make-adr.sh            # 往復ログ → ADR 整形（ADR 生成 on のときのみ）。出力先は引数/env/config/既定で解決
│   └── finalize.sh            # 到達点分岐 review/commit/pr。PR は --draft 固定
├── config/xrev.default.json   # 既定設定（設定キー一覧は protocol.md）
├── references/
│   ├── protocol.md            # 送信プロトコル・act ラベル・終了コード・設定キーの正典
│   └── review-schema.json     # reviewer 出力契約（JSON Schema）
├── tools/                     # 開発用(テスト強制): verify.sh / claude-posttooluse.sh / claude-stop.sh / install-hooks.sh
├── tests/                     # ユニットテスト(cmux 不要・bash+python3): run.sh / lib.sh / test_*.sh
├── docs/                      # architecture.md / roadmap.md / security-design.md / adr/（ADR-NNN）
├── .githooks/pre-commit       # コミット前にテストを強制（core.hooksPath）
└── .github/workflows/ci.yml   # CI（push / PR で tools/verify.sh を実行）
```

## 設計原則

1. **cmux 依存は `scripts/transport.sh` だけに閉じ込める** — 他スクリプト・スキル・フックから
   cmux を直接叩かない。`transport` 設定で将来別方式へ差し替え可能にする。
2. **中間ファイルを生成しない** — エージェント間のやり取りはファイルを介さない。唯一の例外は ADR
   （`docs/adr/`、意図して残す成果物）。
3. **コアは主従非依存** — 特定エージェント名をコアやリポジトリ名に固定しない。主従は
   `config` の `primary`/`reviewer` プリセットで表現し、将来 Codex 主・Claude レビュー構成にも対応する。
4. **判断の分離** — 終端条件（blocker 0 件）・最大反復・severity 集計といった暴走防止の判断は
   スクリプトが決定論的に握り、設計・実装・修正反映といった創造的な作業は LLM（primary）が握る。
   `review-loop.sh` は 1 ラウンドと終端判定だけを担い、ループの駆動（修正して次へ）は Claude が行う。
5. **暴発させない** — `@xrev`（設定の `keyword`）や明示指示が無いときは完全に沈黙する。
6. **人間の最終確認を物理的に保証** — PR は必ずドラフト。既定の到達点は最も安全な `review`。

## transport プロトコル要約

詳細仕様は [`../references/protocol.md`](../references/protocol.md) と [ADR-001](adr/ADR-001.md) を
正典とする。要点のみ:

- **送信は1物理行エンコード**（ADR-001）。完全自動 submit のため、複数行 payload を「画面上は1物理行・
  意味上は複数行」に変換して送る（`content_type` で plain=`<XREV-NL>` / diff・code=番号付き line framing）。
  cmux が `\n`/`\t` を実改行/実タブへ展開する事実への対処。本文の制御トークンは可逆エスケープする。
- **応答検出は round_id 相関**: reviewer の JSON にトップレベル `round_id` を返させ、全画面を de-wrap
  （TUI 折り返し除去）→ JSON を raw_decode 走査 → round_id 一致の妥当ブロックだけを採用する。
  マーカー折り返し・前ラウンド残存・未完成 JSON に強い。
- 宛先は `cmux tree --all --json` でタイトル → surface を**動的解決**する（再起動で surface ID が
  変わってもタイトルは不変、という前提）。
- 接続不可は preflight（ping）で検知し `transport.sh` が `exit 31` を返して明示停止する。
- `review-loop.sh` の decision と exit は 1:1:
  `converged`=0 / `continue`=10 / `escalate`=20 / `invalid`=21 / `transport_error`=22。

severity（blocker の定義）・act ラベル・各スクリプトの内部終了コード・設定キー一覧は
[`../references/protocol.md`](../references/protocol.md) を参照。

## 既知の制約

- **実行コンテキスト**: primary は cmux ペイン内で起動する必要がある（認証情報がペイン内シェルにのみ
  自動注入されるため）。cmux 外からは配管が接続できない。
- **環境依存**: macOS の cmux（libghostty ベース）が前提。`cmux` の list/tree 系コマンド名・JSON 形状・
  rename での title 反映はバージョンで揺れる（検証時 cmux 0.64.15）。
- **reviewer ペイン運用**: 固定タイトル `Review Codex` で 1 枚、履歴ゼロから開く。作業切替時は
  Codex を再起動し、cmux のセッション復元が前作業を復元しないよう注意する。
- **依存**: bash + python3 必須（jq 不要）。到達点 `pr` には `gh` が必要。
