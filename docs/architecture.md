# アーキテクチャ

xrev のディレクトリ構造・設計原則と、transport プロトコル詳細への案内をまとめる。
メッセージ書式・センチネル・act ラベル・終了コード・設定キーの**詳細仕様の正典**は
[`../references/protocol.md`](../references/protocol.md)（索引）配下の分割ファイルにあるので、
ここでは重複させずに案内とリンクに留める。図で概観するなら [overview.html](overview.html) を参照。

## ディレクトリ構造

```
xrev/
├── .claude-plugin/
│   ├── plugin.json            # プラグインメタ（name/version/skills/commands/hooks）
│   └── marketplace.json       # マーケットプレイス定義（同一リポジトリ兼用 / source "./"）
├── skills/xrev/SKILL.md       # 中核プレイブック（発火条件・一拍確認・設計/実装フェーズ・終端判定・ADR・完了アクション・コミット境界）
├── commands/xrev.md           # /xrev（@xrev キーワード起動のフォールバック）
├── hooks/
│   ├── user-prompt-submit.sh  # @xrev 検知時のみコンテキスト注入。無ければ無出力（jq 非依存・python3）
│   └── hooks.json             # ${CLAUDE_PLUGIN_ROOT} 経由でフック宣言
├── scripts/
│   ├── transport.sh           # 通信層抽象。cmux 依存をここだけに局所化。宛先解決・送信・応答検出・preflight
│   ├── parse-review.sh        # 構造化レビューの妥当性検証と severity 集計（jq 非依存）
│   ├── review-loop.sh         # 1 ラウンド実行＋終端の機械判定（decision を返す）。修正反映は LLM が担う
│   ├── make-adr.sh            # 往復ログ → ADR 整形（ADR 生成 on のときのみ）。出力先は引数/env/config/既定で解決
│   ├── start-reviewer.sh      # reviewer(Codex)を実ターミナル内で規約タイトル付き起動（目標C。cmux依存はtransport経由）
│   ├── keyword-match.sh       # keyword 判定の単一の真実源（hook・codex 主プレイブック・スニペットが共有）
│   ├── print-agents-snippet.sh # codex のグローバル AGENTS.md（$CODEX_HOME/AGENTS.md）への導入スニペット。
│   │                            既定は stdout 出力のみ（ファイル生成しない）。--append-global で
│   │                            マーカー管理の冪等な追記/更新（対象解決・排他ロック付き）を行う
│   └── finalize.sh            # 完了アクション分岐 review/commit/pr。PR は --draft 固定
├── config/
│   ├── xrev.default.json      # 既定設定（primary=claude/reviewer=codex。設定キー一覧は protocol.md）
│   └── xrev.codex-primary.json # 主従反転プリセット（primary=codex/reviewer=claude）
├── references/
│   ├── protocol.md                    # プロトコル正典の索引（旧見出しを互換アンカーとして保持）
│   ├── protocol/                      # 正典の実体（message-format / review-contract / exit-codes /
│   │                                  #   config / delivery-gates / reviewer-lifecycle / reference-mode / doctor）
│   ├── codex-primary-playbook.md      # 主従反転プリセット向けの codex 主プレイブック
│   └── review-schema.json             # reviewer 出力契約（JSON Schema）
├── tools/                     # 開発用: verify.sh（テスト強制ゲート）/ render-spec.sh（詳細仕様 HTML 生成 +
│                              #   --site で GitHub Pages 用サイトの組み立て）/
│                              #   claude-posttooluse.sh / claude-stop.sh / install-hooks.sh
├── tests/                     # ユニットテスト(cmux 不要・bash+python3): run.sh / lib.sh / test_*.sh
├── docs/                      # 人間向けドキュメント: overview.html（図付き概観）/ cmux.html（cmux 詳細解説）/
│                              #   spec/（詳細仕様 HTML。references/protocol/ から render-spec.sh で自動生成。
│                              #   図は tools/spec-figures/ のフラグメントを注入）/
│                              #   architecture.md / cmux-integration.md（cmux 依存の対応マップ）/
│                              #   cmux-behavior.md（実測）/ roadmap.md / security-design.md /
│                              #   setup-codex.md / adr/（ADR-NNN）
├── llms.txt                   # エージェント向けの主要ドキュメント地図（人間=HTML / エージェント=md）
├── .githooks/pre-commit       # コミット前にテストを強制（core.hooksPath）
└── .github/workflows/         # ci.yml（push / PR で tools/verify.sh）/ pages.yml（main 更新で
                               #   render-spec.sh --site を組み立てて GitHub Pages へ公開）
```

## 公開サイト（GitHub Pages）

人間向けドキュメントは [naokami3.github.io/xrev](https://naokami3.github.io/xrev/) で公開している。GitHub の blob 表示は
`.html` をソースとして見せてしまうため、ブラウザで読むための経路を別に用意している。

サイトは `tools/render-spec.sh --site <DIR>` が組み立て、`.github/workflows/pages.yml` が main の
更新ごとに実行する。要点は 3 つ。

- **リポジトリと同じディレクトリ構造で並べる**（`docs/overview.html` → `<サイト>/docs/overview.html`）。
  こうすると手書き HTML と md の既存の相対リンクがそのまま解決し、リポジトリ側のファイルを
  書き換えずに済む。リンクの `.md` → `.html` 変換はビルド時にだけ行う。
- **リポジトリ内の md はすべてページ化する**。ただし `references/protocol/*.md` は詳細仕様ページ
  （`docs/spec/`）が人間向けの表現なのでそちらへ寄せ、二重のページを作らない。md 以外の
  ファイル（スクリプト・JSON・LICENSE 等）へのリンクは GitHub 上のソースへ送る。
- **リンク切れは fail closed**。リンク先がリポジトリに存在しなければ組み立てが非ゼロで止まる。
  `tools/verify.sh` が一時ディレクトリへの組み立てを試すので、壊れたリンクはコミット前に落ちる。

生成物はコミットしない（CI が毎回組み立て直す）。ローカルで確認するときは
`tools/render-spec.sh --site _site` を実行して `_site/index.html` を開く。

## 設計原則

1. **cmux 依存は `scripts/transport.sh` だけに閉じ込める** — 他スクリプト・スキル・フックから
   cmux を直接叩かない。`transport` 設定で将来別方式へ差し替え可能にする。
2. **中間ファイルを生成しない** — エージェント間のやり取りはファイルを介さない。意図して残す
   成果物だけが例外: ADR（`docs/adr/`）と、docs/spec/ の生成 HTML（`tools/render-spec.sh` が
   正典 md から生成する人間向けレンダリング。最新性は `tools/verify.sh` が検査する）。
3. **コアは主従非依存** — 特定エージェント名をコアやリポジトリ名に固定しない。主従は
   `config` の `primary`/`reviewer` プリセットで表現する。**Codex 主・Claude レビュー構成は対応済み**
   （`config/xrev.codex-primary.json`。[references/codex-primary-playbook.md](../references/codex-primary-playbook.md)
   参照。フェーズ 5、[roadmap.md](roadmap.md)）。既定 config の `reviewer` は `auto` であり、
   入口で `XREV_PRIMARY` を自己申告するだけで「primary の相手方」が reviewer に機械的に解決される
   （D1・フェーズ 6）。プリセットファイルは値を config へ明示的に固定したい場合のみ使う。
   導入は非対称: **claude 側（primary=claude・既定）はプラグイン導入のみ**で完結するのに対し、
   **codex 側（primary=codex）は加えてグローバル一度きりの導入**（`print-agents-snippet.sh
   --append-global` による `$CODEX_HOME/AGENTS.md` への追加。フェーズ 6・R7 実測で codex が
   これを読み込むことを確認済み）が要る。
4. **判断の分離** — 終端条件（blocker 0 件）・最大反復・severity 集計といった暴走防止の判断は
   スクリプトが決定論的に握り、設計・実装・修正反映といった創造的な作業は LLM（primary）が握る。
   `review-loop.sh` は 1 ラウンドと終端判定だけを担い、ループの駆動（修正して次へ）は Claude が行う。
5. **暴発させない** — `@xrev`（設定の `keyword`）や明示指示が無いときは完全に沈黙する。
6. **人間の最終確認を物理的に保証** — PR は必ずドラフト。既定の完了アクションは最も安全な `review`。

## transport プロトコルの読み方（分割後の案内）

詳細仕様の正典は [`../references/protocol.md`](../references/protocol.md)（索引）配下の分割ファイルと
[ADR-001](adr/ADR-001.md)。図で全体を概観するなら [overview.html](overview.html)、cmux の実挙動と
対処の対応から入るなら [cmux-integration.md](cmux-integration.md) を先に読むとよい。
**人間が正典を読む場合は HTML 版**（[spec/index.html](spec/index.html)。正典 md から
`tools/render-spec.sh` で自動生成・内容同一）が読みやすい。

| 知りたいこと | 正典 |
|--------------|------|
| 送信の仕組み（1物理行エンコード・ASCII wire `XREV-ASCII-V1`・round_id 相関の応答検出・切り詰め検出） | [protocol/message-format.md](../references/protocol/message-format.md) |
| レビュー出力の契約（severity / verdict / act ラベル。収束は blocker 0 件の機械判定） | [protocol/review-contract.md](../references/protocol/review-contract.md) |
| decision 分岐・終了コード・ループ安全弁 round_state（分岐は stdout JSON の `decision` で行う） | [protocol/exit-codes.md](../references/protocol/exit-codes.md) |
| 設定キー一覧・reviewer の auto 解決（D1）・実行コンテキスト・stop_at / ADR の解決順 | [protocol/config.md](../references/protocol/config.md) |
| 宛先解決（同一WSスコープ）と送信ゲート（UUID 再検証・端末性・プロセス証明・安全ポリシー実効検証） | [protocol/delivery-gates.md](../references/protocol/delivery-gates.md) |
| reviewer ペインの自動生成（Phase1c）・read-only 強制・グローバル一度きり導入（D3） | [protocol/reviewer-lifecycle.md](../references/protocol/reviewer-lifecycle.md) |
| 参照モード（Phase2: diff 本文を送らないコンテキスト削減） | [protocol/reference-mode.md](../references/protocol/reference-mode.md) |
| バージョンアップ後の診断（doctor） | [protocol/doctor.md](../references/protocol/doctor.md) |

## 既知の制約

- **実行コンテキスト**: primary は cmux ペイン内で起動する必要がある（認証情報がペイン内シェルにのみ
  自動注入されるため）。cmux 外からは通信層が接続できない。
- **環境依存**: macOS の cmux（libghostty ベース）が前提。`cmux` の list/tree 系コマンド名・JSON 形状・
  rename での title 反映・**プロセスツリーの報告形状**はバージョンで揺れる（現在の検証は cmux 0.64.20）。
  実測でしか分からない挙動は [cmux-behavior.md](cmux-behavior.md) に集約している。設計前提そのものなので、
  通信層に手を入れる前に必ず読むこと。
- **cmux の未修正バグに依存した回避策がある**: ソケット受信側の UTF-8 チャンク欠陥のため、送信 wire を
  ASCII に閉じている（`XREV-ASCII-V1`）。上流が修正されたら削除可否を判断する。詳細は
  [cmux-behavior.md](cmux-behavior.md) の 4 と
  [`../references/protocol/message-format.md`](../references/protocol/message-format.md)。
- **reviewer ペイン運用**: 固定タイトル `Review Codex` で 1 枚、履歴ゼロから開く。作業切替時は
  Codex を再起動し、cmux のセッション復元が前作業を復元しないよう注意する。
- **reviewer は「実ターミナル内の codex CLI」であること**: cmux のエージェント統合パネル
  （`--type agent-session`）は PTY を持たず `read-screen` 不可（`Surface is not a terminal`）なので reviewer に
  使えない。codex を**シェル端末の中で**起動する（matomeblog 等の通常運用と同じ形態）。
- **依存**: bash + python3 必須（jq 不要）。完了アクション `pr` には `gh` が必要。
