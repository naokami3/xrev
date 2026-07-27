# codex 主のセットアップガイド

codex を primary（設計・実装・修正反映）、claude を reviewer にして xrev を使うためのセットアップ手順。
すべて実機検証済みの手順のみを載せる（2026-07-27 実運用で完走確認）。手順の正典は
[../references/codex-primary-playbook.md](../references/codex-primary-playbook.md)、契約の正典は
[../references/protocol.md](../references/protocol.md)。本書は「導入と起動」だけを扱う。

## 全体像: セットアップは 3 層

| 層 | 頻度 | やること |
|----|------|----------|
| マシン単位 | **一度きり** | xrev の checkout + `--append-global` でグローバル AGENTS.md へ導入 |
| プロジェクト単位 | **不要** | 何もしない（対象が git リポジトリであることだけが前提） |
| セッション単位 | 毎回 | cmux 内のペインで対象プロジェクトから codex を起動 |

対称性の注意: claude 主（既定構成）はプラグインのインストールだけで済む。本書は codex 主の話。

## 1. マシン単位（一度きり）

1. xrev を**自分で管理する安定した場所**へ clone する（バージョン付きプラグインキャッシュは不可。
   更新で消えるため）:

   ```bash
   git clone https://github.com/naokami3/xrev.git ~/Works/xrev   # 場所は任意
   ```

2. グローバル導入スニペットを `$CODEX_HOME/AGENTS.md`（既定 `~/.codex/AGENTS.md`）へ追記する:

   ```bash
   ~/Works/xrev/scripts/print-agents-snippet.sh --append-global
   ```

   - マーカーブロック（`<!-- xrev:snippet:BEGIN/END -->`）による**冪等追記**。再実行すると
     ブロックだけが置換され、ファイルの他の内容には触れない。
   - `--append-global` を付けなければ stdout に出力するだけなので、内容を確認してから
     手で貼ることもできる。
   - codex がグローバル AGENTS.md を全セッションで読むことは実測確認済み。

3. **checkout を移動・改名したら再実行**する。移動後は前提検査が「XREV_ROOT が見つかりません」で
   明確に失敗するので、気づいたら `--append-global` を再実行すればブロックが新パスで置換される。

## 2. プロジェクト単位（不要）

対象プロジェクトの AGENTS.md / CLAUDE.md への追記、`XREV_CONFIG` の設定、プリセットの指定は
すべて**不要**。前提は「git リポジトリであること」のみ（レビューは diff ベース・参照モードは git 前提）。

## 3. セッション単位（毎回）

**codex を cmux 内のペインで、対象プロジェクトのディレクトリから起動する。** これだけ。

- cmux ソケットの認証情報はペイン内シェルにのみ注入される。通常ターミナルから起動すると
  通信層が `exit 31` で止まる（何を準備しても往復できない）。
- reviewer（`Review Claude` ペイン）は**用意しなくてよい**。往復開始時に codex が許可を取って
  `ensure-reviewer` で自動生成する（`claude --permission-mode plan`・read-only 検証付き）。

## 4. 使い方

依頼文に `@xrev`（config の `keyword`）を含めて codex に依頼する。以後は codex が
プレイブックに従って進める:

1. 一拍確認（完了アクション review/commit/pr・ADR 有無・reviewer 自動生成の許可）
2. 往復中、`transport.sh` / `review-loop.sh` の実行に**サンドボックス外実行（エスカレーション）の
   承認**を求められるので承認する（理由は下記 5-1。毎回が煩わしければセッション単位で承認する）
3. `critical`/`high` が 0 件になるまで反復し、収束後に確認済みの完了アクションへ（PR は必ずドラフト）

制約（設計上の仕様）:

- **claude reviewer は参照モード専用**。実装フェーズ（diff のレビュー）のみ対応で、
  **設計フェーズのクロスレビューは非対応**（TUI に送信完全性の検証手段が無いため。
  経緯は [adr/ADR-003.md](adr/ADR-003.md)）。設計もレビューさせたい作業は claude 主
  （reviewer=codex）で行う。
- reviewer の応答待ちは既定 600 秒（`response_timeout_seconds`。深い思考や大きい diff で
  時間がかかるための実測値。個別に `XREV_RESPONSE_TIMEOUT_SECONDS` で上書き可）。

## 5. トラブルシュート

### 5-1. `exit 31`（cmux 接続不可）が出る

2 つの原因がある。順に確認する:

1. **codex が cmux ペインの外で動いている** — `env | grep -c CMUX` が 0 なら確定。
   cmux 内のペインで codex を起動し直す。
2. **サンドボックスがソケット接続を遮断している** — `CMUX_*` はあるのに ping が失敗する場合。
   codex はシェルコマンドをサンドボックス内で実行するため、ペイン内でも遮断される（実測）。
   `transport.sh` / `review-loop.sh` は**サンドボックス外実行（エスカレーション承認）**で実行する。

### 5-2. その他の終了コード早見表

| 症状 | 意味 | 対処 |
|------|------|------|
| `exit 10` | reviewer ペインが同一ワークスペースに無い | `ensure-reviewer` で自動生成（codex に任せる） |
| `exit 27` | reviewer が read-only ポリシーで動いていない | **cmux 再起動・セッション復元の後に必ず起きる**（復元は claude/codex を別引数で再起動し read-only を落とす。実測は [cmux-behavior.md](cmux-behavior.md) 10節）。ペインを閉じて `ensure-reviewer` で作り直す |
| `exit 29` | reviewer 設定の矛盾（例: reviewer=claude なのに `reviewer_process=codex` 明示） | 診断に従い明示値を外す（既定 auto に戻す） |
| `transport_error`（`truncated`/`send_failed`） | 生成直後ペインへの初回送信で高頻度の既知事象 | 異常ではない。`round_state` を引き継ぎ同一 ITER を再試行（[cmux-behavior.md](cmux-behavior.md) 9節） |
| `timeout` | reviewer の応答が `response_timeout_seconds` を超過 | reviewer ペインを目視。考え中なら `XREV_RESPONSE_TIMEOUT_SECONDS` を延ばして再試行 |

### 5-3. codex 固有の実行モデル（ハマりどころ）

- **`export` は次のコマンドへ持ち越されない**（シェルがコマンドごとに新規）。環境変数
  （`XREV_PRIMARY=codex` 等）は毎コマンド前置する。グローバル AGENTS.md のスニペットと
  プレイブックはこの前提で書かれている。

## 関連ドキュメント

- 手順の正典（往復・分岐・収束） → [../references/codex-primary-playbook.md](../references/codex-primary-playbook.md)
- 契約の正典（exit code・設定キー） → [../references/protocol.md](../references/protocol.md)
- cmux の実挙動（設計前提の実測） → [cmux-behavior.md](cmux-behavior.md)
- 設計判断の経緯 → [adr/ADR-003.md](adr/ADR-003.md) / [adr/ADR-004.md](adr/ADR-004.md)
