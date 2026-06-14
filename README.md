# xrev

[![CI](https://github.com/naokami3/xrev/actions/workflows/ci.yml/badge.svg)](https://github.com/naokami3/xrev/actions/workflows/ci.yml)

**設計段階からのクロスレビュー往復**を、人間の操作なしで AI コーディングエージェント同士に行わせる
Claude Code プラグイン。

既定構成では **Claude が primary（設計・実装・修正反映）**、**Codex が reviewer（レビュー専用・read-only）**。
レビュー往復は [cmux](https://cmux.com/) のペイン間通信を介して行い、`critical`/`high` の指摘が 0 件になるまで
自動で往復する。収束後はオプションで ADR を生成し、到達点（**レビューのみ / コミット / ドラフト PR**）を選べる。

**最後の確認は必ず人間が行う。** PR は常にドラフトで作られ、マージ・確定の最終トリガは人間が引く。

> 対応エージェント: `claude-code` / `codex`（主従は設定で切り替え。将来 Codex 主・Claude レビュー構成も予定）

## なにが嬉しいか

- **筋の悪いプランを実装前に潰せる**。実装後だけでなく、設計・実装プランの段階から Codex レビューを回す。
- **無限ループしない**。レビューは severity 付きの構造化出力で受け取り、blocker（critical/high）が 0 件に
  なったら機械的に収束。最大反復数の安全弁付き。
- **リポジトリを汚さない**。エージェント間のやり取りに中間ファイルを使わない（ADR を除く）。
- **cmux 依存を 1 ファイルに隔離**。配管は `scripts/transport.sh` だけに閉じ込めてあり、将来別方式へ
  差し替え可能。

## 要件

- **cmux**（macOS, libghostty ベースのターミナル）。バージョンは最新を推奨（CLI 仕様がバージョンで揺れる）。
- **primary（Claude Code）を cmux ペインの中で起動すること（必須）。** cmux のソケットは認証が要り、
  認証情報は cmux ペイン内のシェルにのみ自動注入される。通常のターミナル（Apple Terminal 等）から
  起動すると配管がソケットに接続できない（Broken pipe）。
- **bash**, **python3**（JSON 処理に使用。`jq` は不要）。
- **reviewer 用 Codex ペインを固定タイトル `Review Codex` で 1 枚**開いておくこと（タイトルは設定で変更可）。
- 到達点に `pr` を使う場合は **GitHub CLI（`gh`）** が必要。

## インストール

xrev は **Claude Code のプラグインマーケットプレイス**として配布する（npm 等のパッケージマネージャは
使わない）。このリポジトリ自体がマーケットプレイスを兼ねており、ユーザーは 2 コマンドで導入できる。

### A. 個人で入れる（最短）

Claude Code 上で次を実行する:

```text
/plugin marketplace add naokami3/xrev
/plugin install xrev@xrev-marketplace
```

- 1 行目: GitHub リポジトリ `naokami3/xrev` をマーケットプレイスとして登録（`owner/repo` 形式）。
- 2 行目: その中の `xrev` プラグインをインストール。`defaultEnabled: true` のため有効化まで自動。
- 反映されない場合は `/reload-plugins`（または再起動）。`/plugin list` で確認できる。

更新は `/plugin marketplace update xrev-marketplace` → `/plugin install xrev@xrev-marketplace`。

### B. チーム/プロジェクトに自動配布（宣言的）

リポジトリの `.claude/settings.json` に次をコミットしておくと、その作業ツリーを開いた人に導入が促される
（初回に「このリポジトリを信頼するか」の確認が出る）:

```json
{
  "extraKnownMarketplaces": {
    "xrev-marketplace": {
      "source": { "source": "github", "repo": "naokami3/xrev" },
      "autoUpdate": true
    }
  },
  "enabledPlugins": {
    "xrev@xrev-marketplace": true
  }
}
```

### C. ローカルで開発・試用

clone 済みのこのディレクトリを直接マーケットプレイスに指定できる:

```text
/plugin marketplace add /path/to/xrev
/plugin install xrev@xrev-marketplace
```

> 構成（参考）:
> ```
> xrev/
> ├── .claude-plugin/
> │   ├── plugin.json          # プラグインメタ
> │   └── marketplace.json     # マーケットプレイス定義（同一リポジトリ兼用 / source: "./"）
> ├── skills/xrev/SKILL.md     # 中核プレイブック
> ├── commands/xrev.md         # /xrev（@xrev のフォールバック）
> ├── hooks/                   # @xrev 検知フック
> ├── scripts/                 # 配管・レビューループ・ADR・finalize
> ├── config/xrev.default.json # 既定設定
> └── references/              # プロトコル詳細・レビュー出力契約
> ```

> 注: 上記 A/B の `naokami3/xrev` は **GitHub に push 済みであること**が前提。まだの場合は先に
> リポジトリを GitHub へ公開する（`gh repo create naokami3/xrev --public --source . --push` など）。

### インストール後に必要なもの（プラグイン本体とは別）

プラグインを入れただけでは往復は動かない。実際に使うには次が必要:

- **cmux CLI を PATH に通す**（下記）。
- **reviewer 用 Codex ペインをタイトル `Review Codex` で 1 枚**開く（[使い方](#使い方)）。

### cmux CLI の symlink 設定（必須）

`scripts/transport.sh` は `cmux send` / `cmux read-screen` / `cmux list-*` を使う。cmux ターミナルの
**外側**のシェルからこれらを使うには CLI を PATH に通す:

- **GUI から（推奨）**: cmux のコマンドパレット（`Cmd+Shift+P`）→ **Install CLI to PATH** を実行。
- **手動 symlink**:
  ```bash
  sudo ln -sf "/Applications/cmux.app/Contents/Resources/bin/cmux" /usr/local/bin/cmux
  cmux version   # 確認
  ```

> 注: cmux はペインを**タイトル名で直接宛先指定できない**ため、xrev は `cmux list-*` でタイトルから
> surface を**動的に解決**する。`Review Codex` というタイトルのペインが見つからない場合は宛先解決に
> 失敗するので、ペインのタイトルを合わせるか `XREV_REVIEWER_SURFACE` で明示指定する。

## 使い方

0. **cmux のワークスペースを開き、その中のペインで primary の Claude Code を起動する**
   （cmux の外から起動した Claude Code では配管が動かない）。接続確認は
   `scripts/transport.sh ping` でできる。
1. cmux 上に reviewer 用 Codex ペインを**タイトル `Review Codex`**（`cmux rename-tab` 等で設定）、
   **履歴ゼロ**で 1 枚開く。
2. Claude Code への依頼文に **`@xrev`** を付ける（または `/xrev` を実行）。

   ```
   このAPI設計を @xrev でレビューしてから実装して
   ```
3. xrev は往復を即開始せず、**到達点（review/commit/pr）と ADR 有無を一度だけ確認**する。
4. 設計フェーズ → 実装フェーズの順でクロスレビュー往復が回り、blocker が 0 件で収束する。
5. （任意）ADR 生成 → 到達点処理。

`@xrev` が無い依頼では xrev は**完全に沈黙**する（暴発しない）。

## 到達点（stop_at）

| 値 | 動作 |
|----|------|
| `review`（既定・最も安全） | approve で収束したら停止。**コミットしない / リポジトリを書き換えない**。 |
| `commit` | 収束後、**1 コミット = 1 論理変更**の境界でコミットして停止。レビュー指摘の修正は元の変更にまとめる。 |
| `pr` | コミット後、**ドラフト PR** まで作成して停止。 |

**PR は必ずドラフト。** Ready 化・マージ・確定の最終トリガは人間が引く。これが「人間の最終チェックは
必要」という要件の物理的な保証。

### 到達点の設定方法（3段階）

到達点は次の優先順で決まる（上が優先）。

1. **その場で指定**（1 回限り）: 依頼文や `/xrev` 引数、または一拍確認への回答で伝える。
   ```
   このAPIを @xrev で commit まで進めて
   /xrev pr --adr <対象>
   ```
2. **環境変数 `XREV_STOP_AT`**（シェル / プロジェクト単位の既定）:
   ```bash
   export XREV_STOP_AT=commit   # review / commit / pr
   ```
3. **`config/xrev.default.json` の `stop_at`**（プロジェクト全体の既定）:
   ```json
   { "stop_at": "review" }   // review / commit / pr
   ```

いずれも指定が無ければ最終フォールバックは `review`（最も安全）。

### ADR の設定（必要有無・出力ディレクトリ）

ADR も同じ3段階で設定できる。

- **必要有無**（既定 `off`）: 一拍確認の回答 → 環境変数 `XREV_ADR`（`true`/`false`）→ `config` の `adr`。
  ```bash
  export XREV_ADR=true
  ```
- **出力ディレクトリ**（既定 `docs/adr`）: `make-adr.sh` の引数 → 環境変数 `XREV_ADR_DIR`
  → `config` の `adr_dir`。相対パスは対象リポジトリ基準、絶対パスも指定可。
  ```bash
  export XREV_ADR_DIR=docs/decisions
  ```
  ```json
  { "adr": false, "adr_dir": "docs/adr" }
  ```

## 運用上の注意

### 作業を切り替えるときは Codex を再起動して履歴を切る

reviewer Codex は対話モードで常駐し、会話履歴を Codex 自身が保持する。Claude は毎ターン「今回の差分」だけを
送る。**別の作業に移るときは Codex を再起動して履歴をゼロに戻す**こと。

### セッション復元フックに注意

cmux のセッション復元（`cmux hooks setup codex` 由来）が、新規作業のはずなのに**前セッションを意図せず
復元する**ことがある。新しい作業のレビューは必ず履歴ゼロから始めること。復元プロンプトが出たら復元しない、
あるいは自動復元を無効化しておくと安全。

## 課金についての注意

xrev は別ペインで**対話モードのまま常駐している** Claude/Codex にテキストを送る方式を採る。レビューのたびに
ヘッドレス実行（`claude -p` / `codex exec` 等）を起動する方式ではないため、ヘッドレス起動に伴う別枠課金を
避けやすい。

> ただし課金体系は変わり得る（例: 2026-06-15 の課金変更）。**最新の料金・カウント方法は各社の公式情報で
> 必ず確認すること。** 本 README の記述は設計意図の説明であり、課金の保証ではない。

## 主従プリセットと将来の拡張

内部はプリセットで主従を表現する。コアロジックは主従非依存。

| プリセット | primary | reviewer | 状態 |
|-----------|---------|----------|------|
| Claude 主（本リリース） | `claude` | `codex` | 提供中 |
| Codex 主（将来） | `codex` | `claude` | 予定 |

主従は `config/xrev.default.json` の `primary` / `reviewer` で切り替える。キーワードは共通で `@xrev`
（主従でキーワードを分けない）。

## 設計の詳細

- メッセージ書式・センチネル・act ラベル・終了コード・設定キー一覧 → [`references/protocol.md`](references/protocol.md)
- reviewer の出力契約（JSON Schema） → [`references/review-schema.json`](references/review-schema.json)
- 往復の手順そのもの → [`skills/xrev/SKILL.md`](skills/xrev/SKILL.md)

## ライセンス

MIT。詳細は [`LICENSE`](LICENSE) を参照。
