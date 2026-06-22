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

### `scripts/review-loop.sh`

**分岐は必ず stdout の JSON の `decision` で行う**（exit code ではない）。exit code は
「レビューを綺麗に完了できたか」だけを表す。これにより「`continue` は正常なのに非ゼロで
エラー扱いされる」誤判定（非ゼロを一律エラーとみなす Bash 呼び出し等）を避ける。

| decision          | exit | 意味 |
|-------------------|------|------|
| `converged`       | 0    | blocker 0 件。収束。 |
| `continue`        | 0    | blocker 残・上限未満。primary が修正して `ITER+1` で再実行（正常系）。 |
| `reference_unverified` | 0 | 参照モードで reviewer の diff_hash が期待値と不一致/未取得。レビューを採用せず、primary が**同一 ITER を inline で再試行**（正常系）。通算が `max_reference_fallbacks` 超で `escalate`。 |
| `escalate`        | 0    | 上限到達でも blocker 残。人間へエスカレーション（レビューは完了）。 |
| `invalid`         | 21   | reviewer 出力が契約違反（スキーマ不一致 / 壊れた JSON）→ レビュー取得できず。 |
| `transport_error` | 22   | 送受信失敗（ペイン解決不可・タイムアウト等）→ レビュー取得できず。 |

`transport_error` の決定 JSON には `transport_exit_code`（transport の生終了コード）と `transport_reason`
（安定文字列）を含める。外部 exit は 22 のままだが、primary はこの reason で利用者向け修正案を機械的に選べる:
`cmux_unavailable`/`resolve_failed`/`send_failed`/`timeout`/`truncated`/`non_terminal`/`ws_mismatch`/
`ambiguous`/`process_mismatch`/`cmux_not_found`/`not_in_pane`。

**ループ安全弁（round_state・Phase1b）**: review-loop は決定 JSON に `round_state`（`{iter, transport_attempts}`）
を含める。primary は**この round_state を次回呼び出しの `XREV_ROUND_STATE`(JSON) にそのまま渡す契約**。
review-loop は受け取った状態から通算 `transport_attempts` を1つ進め、`max_transport_attempts` 超過、または
`iter` の巻戻し（前回より小さい）を検知したら、レビュー取得に成功していても `decision=escalate` に倒し
（`state_violation` に `max_transport_attempts`/`rollback` を記録）人間へ委ねる。中間ファイルは作らず状態は
呼び出し連鎖で授受するため、巻戻しの完全強制は不可能で「primary 信頼＋欠落/巻戻し時 fail closed」を
プロトコル限界として明記する。transport/parse 失敗（レビュー取得不可）はそれ自体の扱いを優先し上書きしない。

### `scripts/parse-review.sh`

| exit | 意味 |
|------|------|
| 0    | パース成功（`valid: true`）。集計を stdout に出力。 |
| 1    | JSON 不正・スキーマ不一致（`valid: false`）。 |

### `scripts/transport.sh`（内部の代表的な失敗コード）

| exit | 意味 |
|------|------|
| 10   | reviewer ペイン解決失敗（同一WS内にタイトル一致なし / 一覧取得不可） |
| 11   | 送信失敗 |
| 12   | 応答タイムアウト（round_id 一致の新着なし） |
| 13   | 切り詰め検出（ペースト文字数が送信長と不一致） |
| 14   | reviewer surface が実ターミナルでない（read-screen 不可。cmux エージェント統合パネル等） |
| 15   | ワークスペース不整合（caller WS 特定不能 / 解決後に WS が変化 / 明示が別WS） |
| 16   | 同一WS内で reviewer タイトルが複数一致（曖昧） |
| 17   | プロセス証明失敗（対象 surface の直下プロセスが許可名でない / top 取得不可） |
| 30   | cmux CLI が見つからない |
| 31   | cmux 接続不可（preflight 失敗・ペイン外実行） |

## 5. 設定キー一覧（`config/xrev.default.json`）

| キー | 既定 | 説明 |
|------|------|------|
| `primary` | `claude` | 設計・生成・修正反映を担う側 |
| `reviewer` | `codex` | レビュー専用（read-only）の側 |
| `reviewer_pane_title` | `Review Codex` | 宛先解決に使う cmux ペインタイトル |
| `keyword` | `@xrev` | 発火キーワード |
| `max_iterations` | `5` | 往復の安全弁（論理ラウンドの上限） |
| `max_transport_attempts` | `12` | 通算 transport 試行の上限（論理ラウンドとは別の総量安全弁。超過で escalate） |
| `reviewer_reads_workspace` | `false` | 参照モード(Phase2)を許可するか。`true` かつ同一WS解決時のみ、diff 本文の代わりにファイル参照を送る |
| `max_reference_fallbacks` | `3` | 参照→inline フォールバックの通算上限（超過で escalate。無限往復を防ぐ） |
| `stop_at` | `review` | 到達点（review / commit / pr） |
| `adr` | `false` | ADR 生成の既定（必要有無） |
| `adr_dir` | `docs/adr` | ADR の出力ディレクトリ（相対は対象リポジトリ基準 / 絶対パス可） |
| `transport` | `cmux` | 配管実装の選択（将来の差し替え点） |
| `reviewer_process` | `codex` | 送信前プロセス証明で対象 surface の直下に在るべきプロセス名 |
| `allow_global_resolve` | `false` | `CMUX_SURFACE_ID` 未注入時のグローバル解決を許すか（危険・opt-in） |
| `allow_cross_ws` | `false` | 明示サーフェスが呼び出し元と別WSでも送信を許すか（危険・opt-in） |
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
`XREV_CHUNK_SIZE`, `XREV_CONTENT_TYPE`, `XREV_ROUND_ID`, `XREV_SEND_RETRIES`,
`XREV_RESPONSE_TIMEOUT_SECONDS`, `XREV_RESPONSE_POLL_SECONDS`,
`XREV_REVIEWER_PROCESS`, `XREV_ALLOW_GLOBAL_RESOLVE`, `XREV_ALLOW_CROSS_WS`,
`XREV_MAX_TRANSPORT_ATTEMPTS`, `XREV_ROUND_STATE`, `XREV_CODEX_BIN`,
`XREV_REFERENCE_MODE`, `XREV_EXPECT_DIFF_HASH`, `XREV_EXPECT_HEAD`, `XREV_MAX_REFERENCE_FALLBACKS`。
`XREV_CONTENT_TYPE`/`XREV_ROUND_ID` は通常自動決定で、テスト・デバッグ時のみ明示する。

### 送信の堅牢化（実機知見）

送信先が Codex のとき、**ビジー（前応答の処理中）や入力欄の残留（テキスト/ペーストチップ）**が
あると `cmux send` が非ゼロで失敗する（`cmux send` 自体の長さ上限ではない。プレーンシェルへは
長文も成功する）。そのため `_cmux_send_line` は **送信前に入力欄をクリア（ctrl-u/backspace）し、
失敗時は待って再試行**する（既定 5 回・`XREV_SEND_RETRIES`）。残留が混入したまま送ると prompt が
壊れるため、クリアと、応答検出側のペースト文字数照合（切り詰め検出）で二重に守る。

### 参照モード（Phase2: コンテキスト削減・diff 本文を送らない）

`reviewer_reads_workspace=true` かつ**同一WS解決(resolve_path=same_ws)**のときのみ使える。diff 本文を
cmux に流さず、reviewer に「自分で diff を取得してレビュー」させて送受信・reviewer 双方のコンテキストを削減する。
別WS/別worktreeの誤レビューは **diff 内容ハッシュの不一致**で自動的に弾き、inline へ落とす。設計は 7 ラウンドの
クロスレビューで収束。

- **適用は実装フェーズのみ**（設計フェーズはコードが無く常に inline）。
- **同一性照合 = diff 内容ハッシュ ＋ 基底 OID**（パス比較=symlink/submodule に弱い、を避ける）。primary と reviewer は
  **同一コード `scripts/transport.sh diff-hash <range>` を実行**して diff_hash を得る（手書き invocation の同期ズレを
  無くす単一の真実源）。primary は参照 payload に「`transport.sh diff-hash <range>` の実行指示・range（解決済み OID
  推奨）・expected_diff_hash・expected_head(=`git rev-parse HEAD`)」を載せる（diff 本文は載せない）。reviewer は同じ
  `transport.sh diff-hash` を自分の作業ツリーで実行した sha256 を `reference_context.diff_hash`、自分の `git rev-parse HEAD`
  を `reference_context.head`、さらに `mode:"reference"` / `status:"verified"` を返す。
- **diff_hash だけでなく基底 HEAD OID も照合する**（同一 patch は別 HEAD・別基底でも作れるため。diff 一致＋HEAD 一致で
  「同一の基底・同一の変更を見た」を担保）。
- **`diff-hash` の内部 invocation**（透明性のため。実体は `XREV_DIFF_HASH_DOC` と一字一句同一。非決定性を固定/除去）:
  `env -u GIT_EXTERNAL_DIFF -u GIT_PAGER -u GIT_CONFIG -u GIT_CONFIG_COUNT -u GIT_DIFF_OPTS -u GIT_DIR -u GIT_WORK_TREE
   -u GIT_INDEX_FILE GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 LC_ALL=C git --no-pager
   -c core.autocrlf=false -c core.quotepath=false -c diff.noprefix=false -c diff.mnemonicPrefix=false -c diff.renames=false
   -c diff.external= -c diff.algorithm=myers diff --no-color --no-ext-diff --no-textconv --full-index --binary <range>`
   の生 stdout を sha256。system/global/XDG config と設定注入(GIT_CONFIG_KEY_/VALUE_*)を無効化する。
- **検証と状態遷移**: review-loop は `XREV_REFERENCE_MODE=1` のとき、採用前に reviewer の `reference_context` を
  `mode=reference` / `status=verified` / `head==XREV_EXPECT_HEAD` / `diff_hash==XREV_EXPECT_DIFF_HASH` の**全一致**で照合する。
  いずれか不一致/未取得/期待値未設定/同一WS外(transport が exit18 で拒否)なら `decision=reference_unverified`(exit0)で、
  primary は**同一 ITER を inline で再試行**する。フォールバック通算 `reference_fallbacks` が `max_reference_fallbacks`
  を超えたら `escalate`（無限往復防止）。`reference_fallbacks` は round_state に載り次回へ引き継ぐ。
- **意味の限定**: `reference_context` は「primary と reviewer が同一 diff を取得した」ことの同一性検証であり、
  reviewer がその diff を実際にレビューしたこと・品質を保証しない（信頼済み reviewer 前提）。
- **read-only 不変・安定窓**: reviewer は読むだけ。primary は参照 payload 送信〜応答受領まで作業ツリーを編集しない。
- クロスホスト/別FSは参照モード非対応（inline 固定）。同一WSは必要条件、最終判定は diff ハッシュ一致。

### 宛先解決と送信ゲート（Phase1: 誤配送・shell 誤実行の防止）

複数ワークスペースに同名 `Review Codex` があると、旧実装は「最初に見つかった1件」を返して
**呼び出し元と別ワークスペースの Codex へ誤配送**し得た（実機で観測）。Phase1 でこれを根絶する。
設計は 7 ラウンドのクロスレビューで収束（critical/high 0）。

**宛先解決（`_cmux_resolve_surface`）の順序**:

1. `XREV_REVIEWER_SURFACE`（明示指定・最優先）。`CMUX_SURFACE_ID` があり `allow_cross_ws` が false の
   ときは、明示先が呼び出し元と同一WSであることを検証（別WSは `exit 15`、`XREV_ALLOW_CROSS_WS=true` で許可）。
2. **同一ワークスペース・スコープ解決**（`CMUX_SURFACE_ID` 必須）。`cmux tree --all --json --id-format both`
   を呼び出し元 surface の UUID で辿り、**同一WS内**で `reviewer_pane_title` にタイトル一致（完全→部分）する
   surface を選ぶ。1件→採用 / 複数→`exit 16`（曖昧）/ 0件→`exit 10`。**`active`/`focused` は使わない**
   （フォーカスは他WSへ移動しうるため）。reviewer の役割識別根拠は**タイトル一致 or 明示指定のみ**
   （プロセス名での自動採用はしない＝別作業中の Codex を誤って reviewer にしない）。
3. `CMUX_SURFACE_ID` 未注入時のみ、`XREV_ALLOW_GLOBAL_RESOLVE=true` の明示 opt-in でグローバル解決
   （同一WS保証なし・危険・強い診断）。未許可なら `exit 15`。

**送信前ゲート（`xrev_transport_review`、全段通過で初めて送信）**:

1. **UUID 同一性・WS 所属の再検証**（same_ws 経路）。送信直前に最新 tree を取り直し、解決した surface UUID が
   今も同一WSに存在し、呼び出し元も同一WSに居続けているかを確認（ref 再利用・WS移動・差し替えを `exit 15` で弾く）。
2. **端末性プリフライト**。`read-screen` の成否で判定（成功＝空でも usable / `not a terminal` 等＝`exit 14` /
   一時失敗は限定リトライ）。cmux のエージェント統合パネル（PTY 無し）は read-screen 不可なので reviewer に使えない。
3. **プロセス証明**。`cmux top --all --processes --format tsv` を送信直前に1回取得し、対象 surface の**直下プロセス**が
   `reviewer_process`（既定 `codex`）であることを確認（`exit 17`）。Codex 終了後に shell へ戻った端末へ payload を
   送って**コマンド実行**される事故を防ぐ。tree の `identify` はプロセスを出さないため top を使う。

`transport.sh resolve --json` は機械可読の診断契約（`{ok, exit_code, surface_ref, surface_uuid, workspace,
resolve_path}`）を返す。`resolve_path` は `explicit|same_ws|global`。

**read-screen/send/send-key は `--workspace <workspace_uuid> --surface <surface_uuid>` で指定する（実機知見）**:
短縮 ref（`surface:N`）や surface UUID 単独だと、呼び出し元と別ワークスペースの文脈で cmux が surface を
TerminalPanel として解決できず `Surface is not a terminal` を返す（＝ワークスペース文脈が要る）。UUID が取れない
グローバルフォールバック経路のみ従来の `--surface <ref>` に縮退する。**`tty` フィールドは読み取り可否の指標では
ない**（シェル統合が報告するメタデータに過ぎない）。読めるかどうかの唯一の受入条件は read-screen probe の成否。

> **参照モード（diff 本文を送らずファイル参照を渡す方式）は別節「参照モード（Phase2）」**を参照。
> Phase1 の宛先解決＋送信ゲートが前提（同一WS解決時のみ参照モードを許可）。

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
