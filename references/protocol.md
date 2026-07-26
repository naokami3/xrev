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
- **JSON 文字列値の中の二重引用符は必ず `\"` とエスケープし、生の二重引用符を含めないこと。**
  実機で「センチネルは正しいが JSON 文字列値に生の二重引用符が混じり不正 JSON になる」契約違反が
  観測されている（`_scan_broken_blocks` が検出し `exit 24` に区別する。4節参照）。

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
- **壊れた完成応答の検出**（`_scan_broken_blocks`）: `_scan_review_blocks` は parse に成功した
  ブロックだけを採用するため、センチネルで完成しているが JSON として不正な応答（例: 文字列値に
  生の二重引用符が混入）は永遠に検出できず、本来 `invalid`（契約違反）であるべきものが応答
  タイムアウト（`exit 12`）と誤診断され、タイムアウト全時間を無駄に待つ実機バグが観測された。
  `_scan_broken_blocks` は SENTINEL_BEGIN/END が両方揃った完成領域のうち、期待 `round_id` を
  含みながら妥当な review JSON を1つも取り出せない領域を数える。応答待ちループはこれをポーリング
  ごとに確認し、新規に増えていればタイムアウトを待たず即座に `exit 24` で返す。END が無い領域
  （ストリーミング途中）は数えない。
- reviewer 側はトークン（`<XREV-NL>`/`|| LNNNN:`/`<XREV-BS>`/`<XREV-TAB>`）を元の複数行へ復元して読む。
- **トークン衝突回避**: 本文に制御トークンが元から含まれても区切りと誤解されないよう、導入子
  `XREVQ` で始まるリテラル表記へ可逆エスケープする（例: 本文の `<XREV-NL>`→`XREVQnl`）。
- **round_id** は高エントロピー（`secrets` 由来）。スクロールバックの過去応答との衝突を避ける。
- **切り詰め検出**: Codex の TUI は長いペーストを `[Pasted Content N chars]` に畳むため、その
  文字数 N が送信長と一致するかで欠落を検出する（不一致=中止、確認不能=警告して続行）。
  スクロールバックには過去ラウンドの表示も残るため、**最後の一致**を今回の分とみなす。

### wire encoding `XREV-ASCII-V1`（ASCII-only・暫定措置）

**これは cmux 側の不具合に対する暫定回避策**である。上流が修正され普及したら削除可否を判断できるよう、
encoding にバージョンを付けている。

- **なぜ必要か**: cmux 0.64.20 の受信側 `ControlClientLineReader` は最大 4095 バイトずつ `read(2)` し、
  **各チャンクを独立に UTF-8 変換して、失敗したチャンクを丸ごと捨てる**。Unix domain socket の
  `read(2)` は write 境界を保存しないため、多バイト文字が読み取り境界で分断されると最大 4095 バイトが
  消え、残った断片が V1 コマンドとして解釈されて `ERROR: Unknown command '<断片>'` になる。
  ASCII は各バイトが単独で正しい UTF-8 なのでこの欠陥の影響を受けない。
  実測（各5回）: ASCII 100KB=0失敗 / 日本語 30KB=3失敗 / 日本語 36KB=5失敗 /
  同一本文を ASCII 化した 62KB=0失敗。**長さではなく非ASCIIの有無で分離する。**

- **wire 形式**（機械処理は `ENCODING` の値だけで版を判定する。後続の HINT は reviewer 向けの補助）:

  ```
  XREV_REVIEW round_id=<rid> ENCODING=XREV-ASCII-V1 LEN_INSTR=<a> LEN_OUT=<b> LEN_PAYLOAD=<c>
    :: <ASCII hint> :: <instr><out><payload> :: END_ROUND_<rid>
  ```

  ヘッダーの正規表現:
  `^XREV_REVIEW round_id=([A-Za-z0-9_-]{1,64}) ENCODING=([A-Za-z0-9_.-]{1,32}) LEN_INSTR=(\d+) LEN_OUT=(\d+) LEN_PAYLOAD=(\d+) :: `
  未知の `ENCODING` 値は**拒否**する。長さは wire 上の文字数で数える。

- **長さ付きフィールドにする理由**: `instr` には `'|| LNNNN:'` や `<XREV-NL>` が**説明文として**
  含まれる。区切り探索では領域を分離できないため、長さで切り出す。

- **escape 規則**: 印字可能 ASCII（0x20–0x7E）以外のコードポイントをすべて `\uXXXX` にする。
  非BMP はサロゲート対（`\uXXXX\uXXXX`）。DEL や制御文字も生では出さない。
  encode 直前に「バックスラッシュ・改行・CR・TAB が 0 個」、直後に「全文字が 0x20–0x7E」を検証する。
  前者が成り立つので **wire 上の `\` は必ず xrev が生成した `\uXXXX` の一部**になり、復号が一意に定まる。

- **復号手順（正典）**。実装は `_xrev_decode_line`。

  1. ヘッダーを解釈し `ENCODING` を検証、長さでフィールドを切り出す（不足・末尾マーカー不一致は拒否）
  2. 各フィールドの `\uXXXX` を復号する。`\u[0-9A-Fa-f]{4}` **のみ**を認識し、正しい high+low
     サロゲート対だけを非BMP文字へ統合する。孤立サロゲート・桁不足・非16進・`\u` 以外の
     バックスラッシュは**すべて拒否**（リテラル維持にしない）
  3. **`payload` 領域だけ**に frame 解析を適用する。`instr`/`out` は Unicode 復号のみ。
     `PAYLOAD_FRAMED` は行番号が 1..n で欠番・重複・順序変更なく並ぶことを検証する
     （桁数は 10000 行以降 5 桁になるので `\d{4,}` で受ける）

     **frame の字句仕様**: レコードは `|| L<NNNN>: <行本文>` で、`%04d` の canonical 表現のみ受理する
     （`L00001` のような先頭ゼロ付きは拒否）。レコード同士は**単一の空白1文字**で連結されるため、
     decoder は**最終行以外の末尾から空白をちょうど1つだけ**取り除く。本文が行境界で始まらない場合と、
     非最終行の末尾に連結空白が無い場合は拒否する。`\uXXXX` 復号では**印字可能 ASCII（0x20–0x7E）の
     escape も拒否する** — encoder は生成しないため、受理すると復号後に `|| L0002: ` や `<XREV-BS>` を
     合成でき、payload の衝突退避を経由せず frame/token 解析へ流し込めてしまう。
  4. 生成トークンを戻す（`<XREV-BS>`→`\` / `<XREV-TAB>`→tab）
  5. `XREVQ` 列を**最長一致・左から右へ単一走査・出力を再走査しない**で復元する

  手順5が単一走査でなければならない理由: 原文 `XREVQnl` は encode で `XREVQXREVQnl` になる。
  `XREVQnl` を先に置換しても `XREVQXREVQ` を先に置換しても、反復置換では制御トークンへ誤変換される。

- **失敗時の契約**: 送信側は encode/検証に失敗したら**送信せず**中止する。
  reviewer 側は復号に失敗したらレビューを行わず、`verdict="request_changes"` と
  `category="bug"` / `message="decode_error"` の finding を1件だけ返す。
  inline へのフォールバックは**しない**（同じ ASCII wire を通るので回避にならない）。
  `message="decode_error"` の finding は、その severity や config の `severity_blockers`
  設定に関わらず、常に blocker として集計される（誤収束防止）。

### wire 長の上限（fail closed）

`_build_framed_line` が生成した wire（1物理行）の文字数が `wire_max_chars`（既定 `64000`。
`XREV_WIRE_MAX_CHARS` / config の `wire_max_chars`。1000〜1000000 の範囲外、または
`_xrev_uint` の検証（後述）を満たさなければ既定値へフォールバック）を超えたら、
`xrev_transport_review` は エンコード後・送信前に **cmux へ一切送らず** `exit 26` で中止する。

根拠: [docs/cmux-behavior.md](../docs/cmux-behavior.md) の実測で ASCII 100KB の送信が 5/5
成功しているが、Linux の env/argv 1本あたり上限（`MAX_ARG_STRLEN` 約128KiB）や巨大 payload
が想定外に混入するリスクを踏まえ、実測より保守的な値を既定にして早期に fail closed する。

### 巨大な payload の受け渡し（stdin 経由・env/argv 上限の回避）

`_build_framed_line` / `_xrev_decode_line` / `_scan_review_blocks` / `_xrev_redact_diag`（送信本文側）
や `parse-review.sh`（reviewer JSON）は、巨大になり得るデータを **環境変数や argv ではなく stdin**
で python3 へ渡す。Linux は env/argv 1本あたり `MAX_ARG_STRLEN`（約128KiB）の上限があり、これを
超えるとシェルやプロセス起動が失敗するため（macOS の `ARG_MAX` も合計約1MBで同種の制約がある）。

実装上の注意（bash 3.2 対策）: プログラム本文を `prog="$(cat <<'PY' ... PY)"` のように command
substitution で変数化する書き方は使わない。bash 3.2（macOS 既定）は `$(...)` の対応する閉じ括弧を
探す処理がヒアドキュメント本文の中身（括弧・引用符の個数）まで数えてしまう既知の癖があり、本文中に
不均衡な括弧を含む行（Python の複数行文字列連結など）があると `unexpected EOF while looking for
matching` という構文エラーになる。代わりに `read -r -d '' prog <<'PY' ... PY` でヒアドキュメントを
変数へ読み込む（command substitution を経由しないため影響を受けない）。

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
| `invalid`         | 21   | reviewer 出力が契約違反（スキーマ不一致 / 壊れた JSON / transport `exit 24`）→ レビュー取得できず。 |
| `transport_error` | 22   | 送受信失敗（ペイン解決不可・タイムアウト等）→ レビュー取得できず。 |

`transport_error` の決定 JSON には `transport_exit_code`（transport の生終了コード）と `transport_reason`
（安定文字列）を含める。外部 exit は 22 のままだが、primary はこの reason で利用者向け修正案を機械的に選べる:
`cmux_unavailable`/`resolve_failed`/`send_failed`/`timeout`/`truncated`/`non_terminal`/`ws_mismatch`/
`ambiguous`/`process_mismatch`/`reviewer_policy_mismatch`/`autocreate_failed`/`reviewer_contention`/
`encode_failed`/`payload_too_large`/`submit_failed`/`cmux_not_found`/`not_in_pane`。

`transport_exit_code=24`（`invalid_response`。センチネルで完成した応答はあるが妥当な review JSON
を含まない契約違反。`timeout` と区別され primary は再出力を促す）は `transport_error` ではなく
`decision=invalid` に写像される特例。`transport_reason` は従来どおり `decision=transport_error`
のときだけ埋まる（`decision=invalid` では `null`）が、`transport_exit_code` 自体は透明性のため
`decision=invalid` でも決定 JSON に残る（`=24`）。

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
| 17   | プロセス証明失敗（対象 surface の前景プロセスが許可名でない / top・ps 取得不可 / 各送信ゲート（早期棄却・本文送信直前・Enter直前・Enter再送前）のいずれかで前景が変化） |
| 18   | 参照モードなのに同一WS解決でない（reference モードを拒否し inline へ切替を促す） |
| 19   | reviewer 自動生成は試みたが codex の起動を確認できなかった。launch 引数（read-only 強制）の決定失敗・起動未確認・実効未確認のいずれも含む（autocreate_failed） |
| 20   | reviewer 生成の競合で期限切れ（別 primary が生成中 or 残留ロック→人間。reviewer_contention） |
| 23   | payload のエンコードに失敗（cmux へは未送信。encode_failed。round_id/content_type 不正・不変条件違反等） |
| 24   | センチネルで完成した応答はあるが妥当な review JSON を含まない（契約違反。invalid_response）。`timeout`(12) と区別され、primary は再出力を促す。 |
| 25   | Enter 送信(プロンプト確定)に失敗（最大2回まで再試行しても失敗）。本文は入力欄に残存。`timeout`(12) と区別される（submit_failed）。 |
| 26   | wire（1物理行）の文字数が上限(`wire_max_chars`)を超過（cmux へは未送信。payload_too_large） |
| 27   | reviewer が安全ポリシー（sandbox=read-only かつ承認=never）で起動していない（最終 argv の意味検証に不合格。reviewer_policy_mismatch）。`xrev_transport_review` では各送信ゲート（早期棄却・本文送信直前・Enter直前・Enter再送前）でプロセス証明と同じゲートで毎回再検証される（不具合Bへの対処。TOCTOU防止）。`XREV_ALLOW_UNVERIFIED_REVIEWER=1` で opt-out 可（下記「reviewer read-only 強制」参照） |
| 30   | cmux CLI が見つからない |
| 31   | cmux 接続不可（preflight 失敗・ペイン外実行） |

## 5. 設定キー一覧（`config/xrev.default.json`）

| キー | 既定 | 説明 |
|------|------|------|
| `primary` | `claude` | 設計・生成・修正反映を担う側 |
| `reviewer` | `codex` | レビュー専用（read-only）の側 |
| `reviewer_pane_title` | `Review Codex` | 宛先解決に使う cmux ペインタイトル |
| `keyword` | `@xrev` | 発火キーワード |
| `max_iterations` | `5` | 往復の安全弁（論理ラウンドの上限）。範囲 1..50 |
| `max_transport_attempts` | `12` | 通算 transport 試行の上限（論理ラウンドとは別の総量安全弁。超過で escalate）。範囲 1..100 |
| `reviewer_reads_workspace` | `false` | 参照モード(Phase2)を許可するか。`true` かつ同一WS解決時のみ、diff 本文の代わりにファイル参照を送る |
| `max_reference_fallbacks` | `3` | 参照→inline フォールバックの通算上限（超過で escalate。無限往復を防ぐ）。範囲 0..10 |
| `stop_at` | `review` | 到達点（review / commit / pr） |
| `adr` | `false` | ADR 生成の既定（必要有無） |
| `adr_dir` | `docs/adr` | ADR の出力ディレクトリ（相対は対象リポジトリ基準 / 絶対パス可） |
| `transport` | `cmux` | 配管実装の選択（将来の差し替え点） |
| `reviewer_process` | `codex` | 送信前プロセス証明で対象 surface の直下に在るべきプロセス名 |
| `reviewer_launch_args` | `{"codex":["--sandbox","read-only","--ask-for-approval","never"],"claude":["--permission-mode","plan"]}` | reviewer バイナリ名をキーに持つ object。起動経路（`start-reviewer.sh` / `ensure-reviewer` の自動生成）で機械的に付与する read-only 相当の起動引数。値そのものが安全ポリシー（sandbox=read-only かつ承認=never）を満たすことを意味検証する（満たさなければ fail closed）。既存ペインを採用する経路では launch 引数の付与はしないが、前景プロセスの実効ポリシーは既定で検証する（`XREV_ALLOW_UNVERIFIED_REVIEWER=1` で opt-out 可） |
| `reviewer_autocreate` | `ask` | reviewer ペインの自動生成方針。`ask`(スキルが一拍確認で確認後生成)/`auto`(無確認で生成)/`off`(生成せず案内) |
| `reviewer_create_timeout_seconds` | `30` | 自動生成時の codex 起動確認・競合待ちの上限秒。範囲 1..600 |
| `allow_global_resolve` | `false` | `CMUX_SURFACE_ID` 未注入時のグローバル解決を許すか（危険・opt-in） |
| `allow_cross_ws` | `false` | 明示サーフェスが呼び出し元と別WSでも送信を許すか（危険・opt-in） |
| `severity_blockers` | `["critical","high"]` | 収束を妨げる severity |
| `medium_low_max_rounds` | `2` | medium 以下の指摘に付き合う上限周回（助言値。収束は blocker 0 件で機械判定するためスクリプトは消費せず、スキルが運用指針として参照する） |
| `read_screen_lines` | `400` | read-screen で読む行数。範囲 10..10000 |
| `send_settle_seconds` | `2` | 送信（submit）後の反映待ち秒。範囲 0..60 |
| `submit_settle_seconds` | `1` | submit 前のペースト描画待ちの基準秒（本文長に比例・上限8s）。範囲 0..8 |
| `chunk_size` | `0` | 1物理行の分割送信サイズ（0=分割なし・一括送信） |
| `response_timeout_seconds` | `180` | 応答待ちタイムアウト秒。範囲 1..3600 |
| `response_poll_seconds` | `3` | 応答ポーリング間隔秒。範囲 1..60（**最小1**。0 だと応答待ちが busy-loop 化するため許可しない） |
| `wire_max_chars` | `64000` | 送信直前の wire（1物理行）文字数の上限。超過は送信せず fail closed（`exit 26`）。範囲 1000..1000000 |

上記の数値設定と `XREV_SEND_RETRIES`（範囲 1..20、既定 `5`）は、すべて `transport.sh` の
共通バリデータ `_xrev_uint <値> <最小> <最大> <既定> <名前>` を経由してから bash の算術式
`(( ))` に入る。`_xrev_uint` は「正整数（`^[0-9]{1,10}$`。桁数上限で 64bit 算術オーバーフローを
regex 段階で排除する）+ キー別の範囲」を検証し、範囲外・非数値な値は既定値へフォールバックして
stderr に1行警告する（可用性優先。stdout は汚さない）。生の値が検証前に算術式へ渡ることはない
— bash 算術は `x[$(コマンド)]` のような値でコマンド実行を許すため、env/config 由来の数値を
無検証で `(( ))` に渡すとインジェクションが成立してしまう。`review-loop.sh` の `max_iterations` /
`max_transport_attempts` / `max_reference_fallbacks` も同じ `_xrev_uint` を通す。

環境変数で個別上書き可: `XREV_CONFIG`, `XREV_REVIEWER_PANE_TITLE`, `XREV_REVIEWER_SURFACE`,
`XREV_CMUX_BIN`, `XREV_MAX_ITERATIONS`, `XREV_STOP_AT`, `XREV_ADR`, `XREV_ADR_DIR`,
`XREV_READ_SCREEN_LINES`, `XREV_SEND_SETTLE_SECONDS`, `XREV_SUBMIT_SETTLE_SECONDS`,
`XREV_CHUNK_SIZE`, `XREV_CONTENT_TYPE`, `XREV_ROUND_ID`, `XREV_SEND_RETRIES`,
`XREV_RESPONSE_TIMEOUT_SECONDS`, `XREV_RESPONSE_POLL_SECONDS`,
`XREV_REVIEWER_PROCESS`, `XREV_ALLOW_GLOBAL_RESOLVE`, `XREV_ALLOW_CROSS_WS`,
`XREV_MAX_TRANSPORT_ATTEMPTS`, `XREV_ROUND_STATE`, `XREV_CODEX_BIN`,
`XREV_REFERENCE_MODE`, `XREV_EXPECT_DIFF_HASH`, `XREV_EXPECT_HEAD`, `XREV_MAX_REFERENCE_FALLBACKS`,
`XREV_REVIEWER_AUTOCREATE`, `XREV_REVIEWER_CREATE_TIMEOUT_SECONDS`, `XREV_WIRE_MAX_CHARS`,
`XREV_REVIEWER_LAUNCH_ARGS`（JSON 配列文字列。`reviewer_launch_args` の該当 reviewer 分を上書きする。
文字列のみの配列・印字可能ASCIIのみという型検証は config 由来の値と同じ。さらに決定した引数列
そのものを安全ポリシーの意味検証に通すため、安全ポリシーを満たさない上書きは fail closed で拒否される
—詳細は「reviewer read-only 強制」参照）、
`XREV_ALLOW_UNVERIFIED_REVIEWER`（`1` で「既存 reviewer 採用時の安全ポリシー実効検証」を明示 opt-out
する。手動で用意した reviewer を使う運用を壊さないための後方互換フラグ。既定は検証する
=fail closed。詳細は「reviewer read-only 強制」参照）。
`XREV_CONTENT_TYPE`/`XREV_ROUND_ID` は通常自動決定で、テスト・デバッグ時のみ明示する。

### 送信の堅牢化（実機知見）

送信先が Codex のとき、**ビジー（前応答の処理中）や入力欄の残留（テキスト/ペーストチップ）**が
あると `cmux send` が非ゼロで失敗する（`cmux send` 自体の長さ上限ではない。プレーンシェルへは
長文も成功する）。そのため `_cmux_send_line` は **送信前に入力欄をクリア（ctrl-u/backspace）し、
失敗時は待って再試行**する（既定 5 回・`XREV_SEND_RETRIES`）。残留が混入したまま送ると prompt が
壊れるため、クリアと、応答検出側のペースト文字数照合（切り詰め検出）で二重に守る。

### reviewer ペインの自動生成（Phase1c: create-if-missing・冪等）

`transport.sh ensure-reviewer` は「同一WSに使える reviewer があれば採用、無ければ1枚だけ生成」する（冪等）。
マーケット導入ユーザーがスクリプトのパスを知らなくても、何も手実行せず reviewer が用意されることを狙う。
設計は 4 ラウンドのクロスレビューで収束。

- **分類**: resolve＋probe で `present`/`absent`/`ambiguous`(16)/`non_terminal`(14)/`process_mismatch`(17) を判別。
  既存が**壊れ(14)/曖昧(16)/別物(17)**のときは**作り直さず人間へ**（誤って二重生成しない）。
- **生成は absent のときだけ**: caller の WS UUID を明示して `cmux new-pane --type terminal --workspace <WS>` で生成し、
  **new-pane が返した surface UUID を所有物に固定**（title は一意でないので生成判定に使わない）→
  `reviewer_launch_args`（read-only 強制。下記参照）を決定して各要素を shell-safe クォート →
  `send 'exec <quoted codex> <quoted launch args...>'` → read-screen probe 成功＋直下=codex で起動確認 →
  直下プロセスの実コマンドラインに launch 引数が含まれることを検証（`_verify_reviewer_launch_args`）→
  `rename-tab` で規約タイトル。launch 引数の決定失敗・起動未確認・実効未確認はいずれも `exit 19`。
- **競合の直列化**: WS UUID 鍵の `mkdir` ロック（${TMPDIR}/xrev-reviewer-<wsuuid>.lock・**リポジトリには作らない**）を
  原子取得。**ロックは回収しない**（stale 回収レースを構造的に排除）。取れない側は**奪わず** deadline まで
  read+codex 確認済みの present を待ち、期限切れは `exit 20`（残留ロックは案内に従い手動削除）。これで複数 primary
  同時実行でも「1枚だけ生成・他は採用」へ収束する。
- **モード**: `reviewer_autocreate` = `ask`(既定)/`auto`/`off`。`ask` はスキルが一拍確認で「作成しますか？」を確認して
  から `auto` 相当で呼ぶ（ペイン生成はレイアウトを変える副作用のため暴発させない）。`off` は生成せず案内のみ。
- 手動経路 `scripts/start-reviewer.sh`（既に開いた端末をその場で reviewer にする）とはタイトル・codex バイナリ解決を
  共有し、仕様の乖離を避ける。
- **タブ名は codex 起動の「後」に設定する（実機知見）**: codex は起動時にタブ名を cwd 由来の名前で上書きするため、
  起動前に rename しても定着しない。生成は「起動確認 → rename」の順にする。`rename-tab` も read/send 同様
  `--workspace <ws_uuid> --surface <surface_uuid>` 指定が要る（短縮 ref/uuid 単独は `Tab not found`）。これにより
  reviewer_pane_title が定着し、次回の title 解決が当たる（create-if-missing の冪等性を保つ）。

### reviewer read-only 強制（最終 argv の意味検証が正典）

SKILL.md は「reviewer = レビュー専用・read-only」と約束する。これを起動経路（`start-reviewer.sh` の
手動起動 / `_xrev_create_reviewer` の自動生成）と、既存ペインを「採用」する経路の**両方**で機械的に
強制する。設計はクロスレビューで収束。

**正典は「拒否リスト」ではなく「最終 argv の意味検証」である。** 拒否リスト（前方一致でフラグを
弾く方式）は、型として不正な値（空配列・危険値）を持つ config/env や、`-s`（codex の sandbox 短縮形）
のような未収録の表現・結合形式（`-sdanger-full-access`）による後置上書きを原理的に漏らす。そこで
`transport.sh` の純粋関数 `_xrev_verify_effective_policy <reviewer 種別> <argv...>` を単一の判定基盤とし、
「最終的に reviewer へ渡る argv 列」に対して**実効値**を合成してから合否を判定する。

- **認識する引数形式（codex）**: sandbox = `--sandbox <値>` / `--sandbox=<値>` / `-s <値>` /
  `-s<値>`（結合形式）。承認 = `--ask-for-approval <値>` / `--ask-for-approval=<値>` / `-a <値>` /
  `-a<値>`（結合形式）。
- **複数指定は理由を問わず拒否する**: sandbox・承認それぞれの指定は argv 全体を左から走査して集め、
  **ちょうど1回**だけ現れることを要求する。0回（指定なし）はもちろん、2回以上（例: 安全な組の
  直後に `-s danger-full-access` を後置する攻撃）も、**たとえ最後の値が安全でも拒否**する。
  「後勝ちで良しとする」寛容さは意図的に採らない — 同じ軸への複数指定それ自体が「意図が曖昧な
  argv」であり、fail closed の対象にする。
- **合格条件**: sandbox の実効値が `read-only`、かつ承認の実効値が `never` であること。加えて
  `--dangerously-bypass-approvals-and-sandbox` / `--full-auto` / `--yolo`（完全一致。前方一致では
  なく、リストは関数内の1箇所にまとめる）のいずれも含まれていないこと。claude は
  `--permission-mode <値>` / `--permission-mode=<値>` の実効値が一意に `plan` であることを要求し、
  短縮形を持たないため他の形式は「該当なし」として扱われ結果的に拒否される（fail closed）。
  未知の reviewer 種別も fail closed。
- **`_xrev_verify_effective_policy` を通す4箇所**:
  1. **launch 引数の決定直後**（`_xrev_reviewer_launch_args` 内）。config/env の型検証を通っても
     「安全なポリシーか」は別問題（空配列や `["--sandbox","danger-full-access"]` も型としては正しい）
     なので、決定した引数列そのものを意味検証にかけ、不合格なら非ゼロ（fail closed）にする。
  2. **`start-reviewer.sh` の最終 argv**（launch 引数 + ユーザー追加引数を連結した後の列全体）。
     これにより `-s` の短縮形・結合形式によるあらゆる後置上書きを検出する。
  3. **起動後、実際に走っているプロセスの argv**（`_verify_reviewer_launch_args`）。`ps -o pid=,args=`
     で取得したコマンドラインを空白区切りで argv へ分解し（launch 引数は印字可能ASCIIのみ・空文字列
     不可という型検証を経ており、要素自体に空白を含める運用を想定しないため十分）、意味検証にかける。
     従来の「launch 引数が部分文字列として含まれるか」という判定は、launch 引数の**後ろ**に
     危険な引数が付いていても部分一致さえ満たせば通ってしまう欠陥があったため置き換えた。
  4. **既存ペインを「採用」する経路の実効検証**（`_xrev_verify_reviewer_policy`。下記参照）。
     `xrev_transport_review` では不具合Bの対処により、この検証を送信序盤の1回だけでなく
     `_xrev_gate_reviewer` を介して全ての送信ゲート（早期棄却・本文送信直前・Enter直前・
     Enter再送前）で毎回行う（詳細は「送信前ゲート」節）。
- **単一の生成関数（型検証）**: `transport.sh` の `_xrev_reviewer_launch_args <reviewer バイナリ名>` を
  両起動経路が共有する。優先順位は env `XREV_REVIEWER_LAUNCH_ARGS`（JSON 配列文字列）> config の
  `reviewer_launch_args[<basename>]`。型検証（object であること・キー存在・文字列のみの配列・
  印字可能ASCIIのみ・空文字列不可）に加えて上記の意味検証を通り、違反時・未知 reviewer 時は
  fail closed。出力は1行1要素（改行区切り）で、呼び出し側は `while read` で bash 配列へ集める
  （**eval は使わない**）。
- **拒否リストは早期棄却の best-effort（正典ではない）**: `_xrev_reject_unsafe_reviewer_args`
  （前方一致: `--sandbox` `-s` `--ask-for-approval` `--approval` `--full-auto` `--dangerously`
  `--permission-mode` `--yolo` `-a`）は分かりやすいエラーメッセージを即座に返すための早期ゲートに
  すぎない。`start-reviewer.sh` はユーザー追加引数をこれに通してから launch 引数の**後ろ**に連結する
  が、最終的な合否は必ず上記の意味検証（最終 argv 全体）で決まる。
- **起動後の実効検証**: 自動生成経路は起動確認（read-screen probe + プロセス証明）に加え、
  `_verify_reviewer_launch_args` で対象 surface の直下プロセスの実効ポリシーを確認してから採用する。
  確認できなければ `exit 19`（採用しない）。
- **既存ペインを「採用」する経路の実効検証（指摘3への対処）**: 従来は前景プロセス名が
  `reviewer_process`（既定 `codex`）と一致することしか見ておらず、手動起動・旧版の書き込み可能な
  ままの端末がそのまま present（採用）扱いになり得た。`_xrev_classify_reviewer` の present 判定
  （`_verify_reviewer_process` 成功後）と、`xrev_transport_review` の全送信ゲート（`_xrev_gate_reviewer`
  経由。不具合Bへの対処により1回だけでなく毎ゲート）の双方で `_xrev_verify_reviewer_policy` を通し、
  対象 surface の前景プロセスの argv を取得して意味検証にかける。不合格なら `_xrev_classify_reviewer`
  は `policy_mismatch` を返し `exit 27`、
  `xrev_ensure_reviewer` / `xrev_transport_review` の呼び出し側はこれを受けて「ペインを閉じて
  ensure-reviewer で作り直すか、start-reviewer.sh で起動し直してください」と案内して中止する。
  既定はこの検証を行う（fail closed）。`XREV_ALLOW_UNVERIFIED_REVIEWER=1`（明示 opt-in）のときだけ
  検証を省略し警告ログを出す — 手動で用意した reviewer を使う運用を完全に壊さないための後方互換。
- **サンドボックスと承認は別軸である（既定に両方を含める理由）**: codex の `--sandbox read-only` は
  「何ができるか」を縛るが、コマンド実行のたびに人間へ承認を求めるかどうかは `--ask-for-approval` が
  決める別の軸である。承認ポリシーを既定のままにすると、reviewer が `git diff` や `tests/run.sh` を
  実行しようとするたびに承認プロンプトで停止し、**人間の操作なしに往復させる**という xrev の目的が
  成立しない（応答が来ないまま `response_timeout_seconds` を使い切る）。とくに参照モードは reviewer 自身に
  diff 取得を行わせるため必ずこの経路を踏む。よって既定は `--sandbox read-only --ask-for-approval never`
  の**組**とする。`never` は「承認を求めず、実行失敗はモデルへ返す」の意味であり、サンドボックスは
  そのまま効いている（書き込み・ネットワークは read-only サンドボックスが禁じる）。承認プロンプトを
  外すことは権限の緩和ではなく、権限の強制を sandbox 側へ一本化することである。
  **片方だけを設定してはならない**: `--ask-for-approval never` を sandbox 指定なしで使うと、承認も
  サンドボックスも無い状態になる。この組を崩す変更は安全性の変更として扱うこと。
- **限界**: 同名の別バイナリへの差し替えや、codex/claude 自身の設定ファイル側での上書きまでは
  検出・保証しない（詳細は [`../docs/security-design.md`](../docs/security-design.md)）。

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
3. **プロセス証明＋安全ポリシー実効検証（`_xrev_gate_reviewer` に統合。不具合Bへの対処）**。
   対象 surface の tty で**前景プロセスグループ**を握るプロセスが `reviewer_process`
   （既定 `codex`）であることを確認し（`exit 17`）、**同じゲートで続けて**前景プロセスの argv を
   取得し `_xrev_verify_effective_policy` により sandbox=read-only かつ承認=never が実効に有効かを
   確認する（`exit 27`）。Codex 終了後に shell へ戻った端末へ payload を送って**コマンド実行**される
   事故と、無承認でワークスペースを変更されてしまう事故の両方をここで防ぐ。手順は
   `cmux top --all --processes --format tsv` で対象 surface の直下プロセスを **PID 付き**で取得し、
   その PID 群を `ps -o pid=,pgid=,tpgid=,comm=`（安全ポリシー検証時はさらに `args=`）に渡して
   `pgid == tpgid` を満たす1件を特定、その `comm` の basename を許可名と完全一致で照合したうえで、
   その argv を意味検証にかける。tree の `identify` はプロセスを出さないため top を使う。

   直下プロセスの**件数**では判定しない。実機の cmux では surface 直下が常に
   `[アプリ, sleep, ログインシェル]` の複数件になり、「直下が厳密に1件」は原理的に成立しない
   （旧実装はこれで全ペインを拒否していた）。また cmux の name 列は実行ファイル名とは限らない
   （Claude Code が `2.1.220` 等のバージョン文字列で報告される）ため、プロセス同定は必ず PID 経由で
   `ps` に委ねる。

   検査は **3 点**で行う: (iii) payload 構築前の早期棄却 / (iii-b) 本文送信の直前 /
   (iii-c) **Enter の直前（最終ゲート）**。Enter 送信が失敗し再送する場合も再送の直前に同じゲートを
   通す。いずれの点でも**プロセス証明と安全ポリシー実効検証を必ず同じゲートで行い、どちらか一方
   だけを再検証して他方が古いまま残ることを許さない**（後述「TOCTOU は安全ポリシー側にも残る」参照）。
   (iii-c) やそれ以降のゲートで不一致（前景プロセス不一致・安全ポリシー不成立のいずれか）が
   検出されれば Enter を送らずに中止し、送信済みの本文が入力行に残る旨を案内する。限界は
   [`../docs/security-design.md`](../docs/security-design.md) を参照。

   `XREV_ALLOW_UNVERIFIED_REVIEWER=1`（明示 opt-in）のときは各ゲートの安全ポリシー部分だけを
   省略する（プロセス証明は省略しない）。既定は検証する（fail closed）。警告ログは1往復
   （`xrev_transport_review` の1回の呼び出し）につき1回だけ出す（ゲートごとに出すと同じ警告が
   最大5回積み重なるため）。

   **TOCTOU は安全ポリシー側にも残る（不具合Bの教訓）**: 従来は安全ポリシー実効検証を送信処理の
   序盤（旧(iii)直後の(iii')）で1回だけ行い、以降の各ゲートはプロセス名しか再検証していなかった。
   初回検証後に reviewer プロセスが終了し、同名だが書き込み可能な reviewer（例
   `--sandbox workspace-write` の codex）が起動し直した場合、本文送信〜Enter確定までの描画待ち
   （最大約10秒）の窓で「名前は一致するがポリシーは崩れている」状態を名前検証だけが通過し、
   無承認のまま payload を確定できてしまっていた。プロセス証明と安全ポリシー検証を常に同じゲートで
   行う現在の構成はこれを塞ぐが、**検査から実際の Enter 送出までのごく短い競合窓自体は原理的に
   排除できない**（安全ポリシー検証は ps を追加で叩くためコストが増えるが、結果をキャッシュすると
   まさにこの TOCTOU を再導入するためキャッシュしない）。

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

### `transport.sh doctor`（外部ツール契約の一括診断）

cmux / Codex / Claude Code のバージョンアップで xrev は壊れるが、壊れ方が「全拒否」「タイムアウト」
「無言沈黙」に化けて原因が読めない。`transport.sh doctor` は外部ツールへの契約仮定を一括検査し、
人間可読な診断を返す。**検査はすべて非変更・再実行可能**（ペイン生成・送信・タイトル変更などの
副作用を持つ検査は含まない）。各検査は独立に実行され、1つの失敗で後続を止めない。

**出力契約**: 1検査1行 `[ok|warn|fail] 検査名: 詳細`（stdout。機械処理より人間可読を優先する）。
最後に `ok=N warn=N fail=N` のサマリ行を出す。

**exit 契約**: `fail` が1件でもあれば `exit 1`。`fail=0`（`warn` のみ含む場合を含む）なら `exit 0`。
`warn` は exit に影響しない。

**検査項目**:

| # | 検査 | ok/warn/fail の基準 |
|---|------|----------------------|
| 1 | python3 | 存在＋バージョン表示=ok / 不在=fail |
| 2 | cmux バイナリ | 存在＋実測検証済み(`0.64.20`)と一致=ok / 存在するがバージョン相違=warn / 不在=fail |
| 3 | cmux 接続 | `_cmux_preflight`（ping）成功=ok / 失敗=fail |
| 4 | env 注入 | `CMUX_SURFACE_ID` 有=ok・無=fail（同一WS解決不可） / `CMUX_WORKSPACE_ID` 有=ok・無=warn |
| 5 | tree 形状 | `_doctor_check_tree_shape` が0=ok / 非0=fail |
| 6 | top 形状 | `_doctor_check_top_shape` が0=ok / 非0=fail |
| 7 | ps 契約 | `printf '%s\n' "$$" \| _ps_snapshot` が `pid pgid tpgid comm` の4フィールドを返す=ok / 崩れ=fail |
| 8 | reviewer 解決 | `_cmux_resolve_surface` が present=ok / absent=warn / それ以外(曖昧・ws不整合・一時障害等)=warn（環境状態の情報であり契約違反ではないため fail にしない） |
| 9 | reviewer バイナリ・launch 引数 | バイナリ存在=ok・不在=warn（`ensure-reviewer` は失敗するが送信検証は前景プロセス名しか見ないため致命ではない） / `_xrev_reviewer_launch_args` 成功=ok・失敗=fail |
| 10 | フック契約セルフテスト | `hooks/user-prompt-submit.sh` に `@xrev` 入り prompt→`additionalContext` を含む出力・無関係 prompt→無出力、の両方を確認=ok / いずれか崩れ=fail |
| - | info | 検出不能な既知の縮退の注意書き。検査ではなく固定の `[info]` 行 |

純粋関数 `_doctor_check_tree_shape`（stdin=`cmux tree --all --json --id-format both` 相当の JSON、
1行診断をstdoutに・exit 0/非0）と `_doctor_check_top_shape`（stdin=`cmux top --all --processes
--format tsv` 相当の TSV、同様の契約）は cmux 非依存の単体テスト対象として切り出してある
（`tests/test_doctor.sh`）。

**検出できないもの（既知の限界）**:

- フック契約セルフテスト（検査10）は「xrev 側の実装が契約どおりか」の検証であり、Claude Code 本体が
  `UserPromptSubmit` のフィールド名やイベント仕様そのものを変えた場合は検出できない。
- Codex TUI の「Pasted Content N chars」文言や cmux のエラー文言（`not a terminal` 等）がバージョン
  アップで変わった場合、doctor では検出できない（固定の `[info]` 行で注意喚起するのみ）。
  `_check_paste_intact` の `unknown` 警告が毎回出るようになったら、この文言変更を疑うこと。
4. `review`（最終フォールバック・最も安全）
