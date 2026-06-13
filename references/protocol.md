# xrev プロトコル詳細

必要時のみ読む補足資料。日常の運用は `skills/xrev/SKILL.md` に従えばよい。
ここでは往復の内部仕様（メッセージ書式・act ラベル・終了コード設計）をまとめる。

## 1. メッセージ書式（reviewer への依頼と応答）

`scripts/transport.sh` は payload に続けて、reviewer へ次を要求する:

- レビュー結果を **2 行のセンチネルで挟んだ JSON** として返すこと。
  - 開始: `===XREV-JSON-BEGIN===`
  - 終了: `===XREV-JSON-END===`
- センチネルの外には何も書かない。
- JSON は `references/review-schema.json` に準拠（`verdict` + `findings[]`）。

センチネル方式の理由: 対話モードの Codex 画面はプロンプトやエコーでノイズが多い。
固定マーカーで挟むことで `cmux read-screen` の出力から機械的かつ確実に JSON を切り出せる。
往復で複数回出力された場合は**最後のブロック**を採用する。

### reviewer 出力の例

```
===XREV-JSON-BEGIN===
{
  "verdict": "request_changes",
  "summary": "宛先解決が再起動で壊れる懸念",
  "findings": [
    {
      "file": "scripts/transport.sh",
      "line": 60,
      "severity": "high",
      "category": "design",
      "message": "surface ID 直指定は Codex 再起動で無効化する",
      "suggested_fix": "タイトルから surface を動的解決する"
    }
  ]
}
===XREV-JSON-END===
```

## 2. severity と verdict

| severity   | blocker か | 往復での扱い |
|------------|-----------|--------------|
| `critical` | yes       | 0 件になるまで反映（収束条件） |
| `high`     | yes       | 同上 |
| `medium`   | no        | 1〜2 周のみ反映、以降は無視して収束扱い |
| `low`      | no        | 任意。収束を妨げない |
| `nit`      | no        | 任意 |

- blocker の集合は `config/xrev.default.json` の `severity_blockers` で定義（既定 `["critical","high"]`）。
- `verdict` は `approve` / `request_changes`。収束判定は verdict ではなく **blocker 件数**で機械的に行う
  （`blockers == 0` で収束）。verdict は人間向けの要約として保持する。

## 3. act ラベル（会話終端の思想）

`cmux-bridge` 等の知見に倣い、AI 同士の無限相槌を避けるため、各メッセージの意図をラベルで捉える。
xrev では severity/verdict による機械判定を主とするが、運用上の指針として次を踏襲する:

| act       | 意味             | 返信の扱い |
|-----------|------------------|------------|
| `propose` | 変更を提案        | レビュー対象 |
| `react`   | 指摘・反応        | 反映して次へ |
| `decide`  | 最終決定          | 確定（ADR の Decision に対応） |
| `think`   | 熟考中            | **追撃しない**（待つ） |
| `close`   | 議論終端          | **返信しない**（相槌も送らない） |

要点: **`think` には追撃しない / `close` には返信しない**。これが AI 同士の無限ループを防ぐ。

## 4. 終了コード設計

### `scripts/review-loop.sh`（decision と 1:1）

| decision          | exit | 意味 |
|-------------------|------|------|
| `converged`       | 0    | blocker 0 件。収束。 |
| `continue`        | 10   | blocker 残・上限未満。primary が修正して `ITER+1` で再実行。 |
| `escalate`        | 20   | 上限到達でも blocker 残。人間へエスカレーション。 |
| `invalid`         | 21   | reviewer 出力が契約違反（スキーマ不一致 / 壊れた JSON）。 |
| `transport_error` | 22   | 送受信失敗（ペイン解決不可・タイムアウト等）。 |

### `scripts/parse-review.sh`

| exit | 意味 |
|------|------|
| 0    | パース成功（`valid: true`）。集計を stdout に出力。 |
| 1    | JSON 不正・スキーマ不一致（`valid: false`）。 |

### `scripts/transport.sh`（内部の代表的な失敗コード）

| exit | 意味 |
|------|------|
| 10   | reviewer ペイン解決失敗（タイトル不一致 / 一覧取得不可） |
| 11   | 送信失敗 |
| 12   | 応答タイムアウト |
| 13   | センチネル間 JSON 抽出失敗 |

## 5. 設定キー一覧（`config/xrev.default.json`）

| キー | 既定 | 説明 |
|------|------|------|
| `primary` | `claude` | 設計・生成・修正反映を担う側 |
| `reviewer` | `codex` | レビュー専用（read-only）の側 |
| `reviewer_pane_title` | `Review Codex` | 宛先解決に使う cmux ペインタイトル |
| `keyword` | `@xrev` | 発火キーワード |
| `max_iterations` | `5` | 往復の安全弁（上限） |
| `stop_at` | `review` | 到達点（review / commit / pr） |
| `adr` | `false` | ADR 生成の既定（必要有無） |
| `adr_dir` | `docs/adr` | ADR の出力ディレクトリ（相対は対象リポジトリ基準 / 絶対パス可） |
| `transport` | `cmux` | 配管実装の選択（将来の差し替え点） |
| `severity_blockers` | `["critical","high"]` | 収束を妨げる severity |
| `read_screen_lines` | `400` | read-screen で読む行数 |
| `send_settle_seconds` | `2` | 送信直後の反映待ち秒 |
| `response_timeout_seconds` | `180` | 応答待ちタイムアウト秒 |
| `response_poll_seconds` | `3` | 応答ポーリング間隔秒 |

環境変数で個別上書き可: `XREV_CONFIG`, `XREV_REVIEWER_PANE_TITLE`, `XREV_REVIEWER_SURFACE`,
`XREV_CMUX_BIN`, `XREV_MAX_ITERATIONS`, `XREV_STOP_AT`, `XREV_ADR`, `XREV_ADR_DIR`,
`XREV_READ_SCREEN_LINES`, `XREV_SEND_SETTLE_SECONDS`, `XREV_RESPONSE_TIMEOUT_SECONDS`,
`XREV_RESPONSE_POLL_SECONDS`。

### 実行コンテキスト（重要）

cmux ソケットは認証が要る。認証情報（`CMUX_SOCKET_PASSWORD` 等）・`CMUX_SOCKET_PATH`・`CMUX_SURFACE_ID`
は **cmux ペイン内のシェルにのみ自動注入**される。よって xrev（primary）は cmux ペイン内で動かす。
cmux の外（通常ターミナル）からは接続できず `transport.sh` は preflight で `exit 31` を返す。
`transport.sh ping` で接続コンテキストを確認できる。`cmux` バイナリは PATH 優先、無ければアプリ同梱
（`/Applications/cmux.app/Contents/Resources/bin/cmux`）を使う。`XREV_CMUX_BIN` で明示指定も可。

### ADR（必要有無・出力先）の解決順

- 必要有無: 一拍確認の明示指定 → `XREV_ADR`（`true`/`false`）→ `config` の `adr` → `false`
- 出力先: `make-adr.sh` の引数 → `XREV_ADR_DIR` → `config` の `adr_dir` → `docs/adr`
  （相対は対象リポジトリ基準、絶対パスはそのまま）

### 到達点（stop_at）の解決順

`scripts/finalize.sh` は到達点を次の優先順で決める（高 → 低）:

1. 引数（その場指定。依頼文 / `/xrev` 引数 / 一拍確認の回答を Claude が渡す）
2. 環境変数 `XREV_STOP_AT`（シェル / プロジェクト単位の既定上書き）
3. `config` の `stop_at`（プロジェクト全体の既定）
4. `review`（最終フォールバック・最も安全）
