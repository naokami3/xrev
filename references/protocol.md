# xrev プロトコル詳細

必要時のみ読む補足資料。日常の運用は `skills/xrev/SKILL.md` に従えばよい。
ここでは往復の内部仕様（メッセージ書式・act ラベル・終了コード設計）をまとめる。

## 1. メッセージ書式（reviewer への依頼と応答）

`scripts/transport.sh` は payload に続けて、reviewer へ次を要求する:

- レビュー結果を **2 行のセンチネルで挟んだ JSON** として返すこと。
  - 開始: `===XREV-JSON-BEGIN===`
  - 終了: `===XREV-JSON-END===`
- センチネルの外には何も書かない。
- JSON は **1 行コンパクト形式**（改行・インデントなし）で出力すること。
- JSON は `references/review-schema.json` に準拠（`verdict` + `findings[]`）。

センチネル方式の理由: 対話モードの Codex 画面はプロンプトやエコーでノイズが多い。
固定マーカーで挟むことで `cmux read-screen` の出力から機械的かつ確実に JSON を切り出せる。
往復で複数回出力された場合は**最後のブロック**を採用する。

**TUI 折り返しへの対応（実機知見）**: 対話型 TUI（Codex 等）は長い行を物理的に折り返し、
各行にガター字下げを付ける。そのため `read-screen` で得たセンチネル間テキストは JSON 文字列の
途中に生の改行が入り、そのままでは `json.loads` に失敗する。`_scan_review_blocks` は
「素のままパース → 失敗時は各行の前後空白を除去して連結（de-wrap）」で復元し、検出時は
正規化したクリーンな JSON を下流へ渡す。JSON を 1 行で出させるのはこの復元を確実にするため。

### 送信プロトコル（1物理行エンコード・ADR-001）

完全自動 submit のため、送信本文は「画面上は1物理行・意味上は複数行」にエンコードする
（`_build_framed_line`）。背景・決定は [ADR-001](../docs/adr/ADR-001.md)。

- **不変条件**: cmux に実改行を渡さない（常に1物理行）／`round_id` 相関で完了判定／クォート済み引数で送る。
- **理由**: `cmux send` は引数中の `\n`/`\t` を実改行/実タブへ自動展開する（実機確認済み）。
  そのため本文の `\`→`<XREV-BS>`、tab→`<XREV-TAB>`、改行は下記方式で畳む。
- **content_type で二段構え**:
  - `plain`（散文）: 改行を `<XREV-NL>` に置換したコンパクト1行（`PAYLOAD_PLAIN || …`）。
  - `unified_diff`/`code` 等: 番号付き line framing（`PAYLOAD_FRAMED … || L0001: … || L0002: …`）。
    `|| L[0-9]+:` だけが行境界。行頭 `+/-` とインデントを保持し diff 精度を落とさない。
- **末尾 `END_ROUND_<id>`** で切り詰めを検出可能にする。
- **送信手順**: 1物理行を `cmux send` → 描画待ち（本文長に比例・上限8s）→ `send-key enter` 1回。
- **応答検出**: reviewer の JSON にトップレベル `round_id` を返させ、`_scan_review_blocks` は
  **全画面を de-wrap → JSON を raw_decode 走査 → round_id 一致の妥当ブロックだけ**を採用する
  （マーカー折り返し・前ラウンド残存・未完成JSONに強い。走査サイズ/件数に上限あり）。
- reviewer 側はトークン（`<XREV-NL>`/`|| LNNNN:`/`<XREV-BS>`/`<XREV-TAB>`）を元の複数行へ復元して読む。
- **トークン衝突回避**: 本文に制御トークンが元から含まれても区切りと誤解されないよう、導入子
  `XREVQ` で始まるリテラル表記へ可逆エスケープする（例: 本文の `<XREV-NL>`→`XREVQnl`）。
- **round_id** は高エントロピー（`secrets` 由来）。スクロールバックの過去応答との衝突を避ける。
- **切り詰め検出**: Codex の TUI は長いペーストを `[Pasted Content N chars]` に畳むため、その
  文字数 N が送信長と一致するかで欠落を検出する（不一致=中止、確認不能=警告して続行）。

### reviewer 出力の例

実際は1行コンパクトで返させる（読みやすさのため整形して例示）。トップレベルに依頼の
`round_id` を含めること（応答検出の相関に使う）:

```
===XREV-JSON-BEGIN===
{
  "round_id": "r3c98be8691dfd20",
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
| 12   | 応答タイムアウト（round_id 一致の新着なし） |
| 13   | 切り詰め検出（ペースト文字数が送信長と不一致） |
| 30   | cmux CLI が見つからない |
| 31   | cmux 接続不可（preflight 失敗・ペイン外実行） |

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
| `medium_low_max_rounds` | `2` | medium 以下の指摘に付き合う上限周回（助言値。収束は blocker 0 件で機械判定するためスクリプトは消費せず、スキルが運用指針として参照する） |
| `read_screen_lines` | `400` | read-screen で読む行数 |
| `send_settle_seconds` | `2` | 送信（submit）後の反映待ち秒 |
| `submit_settle_seconds` | `1` | submit 前のペースト描画待ちの基準秒（本文長に比例・上限8s） |
| `chunk_size` | `0` | 1物理行の分割送信サイズ（0=分割なし・一括送信） |
| `response_timeout_seconds` | `180` | 応答待ちタイムアウト秒 |
| `response_poll_seconds` | `3` | 応答ポーリング間隔秒 |

環境変数で個別上書き可: `XREV_CONFIG`, `XREV_REVIEWER_PANE_TITLE`, `XREV_REVIEWER_SURFACE`,
`XREV_CMUX_BIN`, `XREV_MAX_ITERATIONS`, `XREV_STOP_AT`, `XREV_ADR`, `XREV_ADR_DIR`,
`XREV_READ_SCREEN_LINES`, `XREV_SEND_SETTLE_SECONDS`, `XREV_SUBMIT_SETTLE_SECONDS`,
`XREV_CHUNK_SIZE`, `XREV_CONTENT_TYPE`, `XREV_ROUND_ID`, `XREV_RESPONSE_TIMEOUT_SECONDS`,
`XREV_RESPONSE_POLL_SECONDS`。`XREV_CONTENT_TYPE`/`XREV_ROUND_ID` は通常自動決定で、テスト・
デバッグ時のみ明示する。

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
