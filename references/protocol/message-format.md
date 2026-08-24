# メッセージ書式と送信プロトコル

[`../protocol.md`](../protocol.md)（索引）から分割された正典の一部。

**この文書で分かること**:

- reviewer への依頼と応答の書式（センチネル・1 行コンパクト JSON・de-wrap）
- 複数行 payload を 1 物理行で送る理由と方式（ADR-001・content_type 二段構え）
- wire encoding `XREV-ASCII-V1` の形式・escape 規則・復号手順（正典）
- wire 長の上限と、巨大データを stdin で受け渡す理由
- 切り詰め検出の reviewer 種別ごとの手段（codex=文字数照合 / claude=参照モード専用）

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
  観測されている（`_scan_broken_blocks` が検出し `exit 24` に区別する。[終了コード設計](exit-codes.md) 参照）。

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
（`_build_framed_line`）。背景・決定は [ADR-001](../../docs/adr/ADR-001.md)。

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
- **切り詰め検出（reviewer 種別対応・C2）**: 照合手段は `reviewer_process` の basename で分岐する。
  - `codex`: TUI が長いペーストを `[Pasted Content N chars]` に畳むため、その文字数 N が送信長と
    一致するかで欠落を検出する（不一致=`exit 13`、確認不能=警告して続行という縮退は codex に限定）。
    スクロールバックには過去ラウンドの表示も残るため、**最後の一致**を今回の分とみなす。
  - `claude`（**参照モード専用**）: ペーストチップに文字数が表示されないため（実測。
    docs/cmux-behavior.md 参照）codex と同じ照合は成立しない。inline（本文を wire に直接載せる
    方式）向けに、composer 上で wire 文字列と de-wrap 後の画面テキストを空白非依存で全文一致
    照合する方式を実装したことがあったが、空白の位置がずれる改変を比較・decoder のどちらも
    検出できず完全性証明にならないと 2 巡目のクロスレビューで指摘され、不採用として撤去した
    （経緯は下記コラム参照）。現在は **inline は wire 長に関わらず無条件で `exit 28`
    （`integrity_unverifiable`）で送信前拒否になる**。**このため claude reviewer は参照モード
    （`XREV_REFERENCE_MODE=1`）が必須**であり、参照モードは本節の切り詰め検出自体を行わない。
    根拠: レビュー対象の完全性は diff_hash + 基底 HEAD の端到端照合（[参照モード](reference-mode.md)参照）が
    機械保証する。reviewer が実際にハッシュした range と返却 hash/head が一致した応答しか
    採用されないため、見ていない対象への approve は成立しない。指示部が壊れた場合も
    decode_error / hash 不一致 / timeout のいずれかの失敗系に落ちる（fail closed 維持）。
  - それ以外の未知種別: 検証手段が確立していないため、送信前に `exit 28` で拒否する（fail closed）。

> **経緯（不採用になった全文一致照合方式）**: claude inline 向けに、wire と de-wrap 後の画面
> テキストの両辺から ASCII スペースと改行を**すべて**除去してから部分文字列一致を見る比較
> （`_xrev_check_full_match`。行単位 strip では TUI の折り返し位置が wire 内の意味のある空白と
> 重なると誤判定する問題への対処として空白非依存化していた）を、wire 長が一定の上限
> （`integrity_full_match_max_chars`）以下のときだけ試みる設計を採用していた。しかし
> 「LEN_\* はフィールド全体長であり、空白の削除と挿入が相殺すれば比較・canonical frame
> 構文の検証のどちらもすり抜ける」という指摘（2巡目クロスレビュー・medium）を受け、完全性の
> 証明にはならない可用性ヒューリスティックにすぎないと判断し撤去した。claude reviewer は
> 参照モードの diff_hash + 基底 HEAD 端到端照合のみを完全性の根拠とする。

### wire encoding `XREV-ASCII-V1`（ASCII-only・暫定措置）

**これは cmux 側の不具合に対する暫定回避策**である。上流が修正され普及したら削除可否を判断できるよう、
encoding にバージョンを付けている。上流の状況: 報告 issue
[manaflow-ai/cmux#8924](https://github.com/manaflow-ai/cmux/issues/8924) は PR #8962 として
2026-07-26 に main へマージ済み（安定版 v0.64.20 には未収載）。削除判断の具体的な手順は
[../../docs/roadmap.md](../../docs/roadmap.md) の「将来の検討事項」を参照。

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

根拠: [docs/cmux-behavior.md](../../docs/cmux-behavior.md) の実測で ASCII 100KB の送信が 5/5
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
