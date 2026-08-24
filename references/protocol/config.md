# 設定（キー一覧・解決順・実行コンテキスト）

[`../protocol.md`](../protocol.md)（索引）から分割された正典の一部。

**この文書で分かること**:

- 設定キー一覧（既定値・範囲）と環境変数での上書き
- reviewer の auto 解決（D1）・semantic kind・設定矛盾の検査（exit 29）
- 数値設定の共通バリデータ `_xrev_uint` と bash 算術インジェクション対策
- 実行コンテキスト（primary を cmux ペイン内で起動する必要がある理由）
- ADR と完了アクション（stop_at）の解決順

## 5. 設定キー一覧（`config/xrev.default.json`）

| キー | 既定 | 説明 |
|------|------|------|
| `primary` | `claude` | 設計・生成・修正反映を担う側。`XREV_PRIMARY`（env）> config の `primary` > 既定 `claude` の順で解決する |
| `reviewer` | `auto`（D1） | レビュー専用（read-only）の側。解決順: 1) `XREV_REVIEWER`（env・明示最優先） 2) config の値が `auto` 以外ならその値 3) `auto`: 「primary の相手方」（`{claude→codex, codex→claude}`。primary が claude/codex のどちらでもなければ fail closed）。既定 config（primary=claude・reviewer=auto）は解決結果 `codex` で従来と完全同値（後方互換） |
| `reviewer_pane_title` | `auto`（D1） | 宛先解決に使う cmux ペインタイトル。明示値（`XREV_REVIEWER_PANE_TITLE` env、または config の値が `auto` 以外）があればそれを使う。`auto` は解決済み `reviewer` から導出（`codex`→`Review Codex` / `claude`→`Review Claude`）。誤 title の検査はしない（既存の process 証明 `exit 17` が送信前に止めるため。下記「reviewer 設定の矛盾検査」参照） |
| `keyword` | `@xrev` | 発火キーワード |
| `max_iterations` | `5` | 往復の安全弁（論理ラウンドの上限）。範囲 1..50 |
| `max_transport_attempts` | `12` | 通算 transport 試行の上限（論理ラウンドとは別の総量安全弁。超過で escalate）。範囲 1..100 |
| `reviewer_reads_workspace` | `auto`（D1） | 参照モード(Phase2)を許可するか。`true` かつ同一WS解決時のみ、diff 本文の代わりにファイル参照を送る。明示値（config の値が `auto` 以外。env 上書きは無い）があればそれを使う。`auto` は解決済み `reviewer` から導出（`claude`→`true` / `codex`→`false`）。**reviewer=claude で明示 `false` は設定エラー**（claude は参照モード専用のため。下記「reviewer 設定の矛盾検査」参照） |
| `max_reference_fallbacks` | `3` | 参照モード検証失敗時の再試行・フォールバック通算上限（超過で escalate。無限往復を防ぐ）。名称は「参照→inline フォールバック」由来だが、意味は reviewer 種別非依存に一般化されている（codex=inline へのフォールバック回数 / claude=参照モードのままの再試行回数）。範囲 0..10 |
| `stop_at` | `review` | 完了アクション（review / commit / pr） |
| `adr` | `false` | ADR 生成の既定（必要有無） |
| `adr_dir` | `docs/adr` | ADR の出力ディレクトリ（相対は対象リポジトリ基準 / 絶対パス可） |
| `transport` | `cmux` | 通信層実装の選択（将来の差し替え点） |
| `reviewer_process` | `auto`（D1） | 送信前プロセス証明で対象 surface の直下に在るべきプロセス名（前景 comm 名の照合専用。安全ポリシー種別・送信完全性方式等の semantic kind 判定には使わない。下記参照）。明示値（`XREV_REVIEWER_PROCESS` env、または config の値が `auto` 以外）があればそれを使う。`auto` は解決済み `reviewer` をそのまま使う。明示値の basename が `codex`/`claude` のどちらかで解決済み `reviewer` と異なる場合は設定エラー（それ以外の明示値＝ラッパ名等は前景照合にのみ使い種別判定に影響させない） |
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
| `response_timeout_seconds` | `600` | 応答待ちタイムアウト秒。範囲 1..3600。既定を 180 から 600 へ変更（実測: 拡張思考する claude reviewer や大きい diff の参照モードレビューで 180〜420 秒超過が頻発。応答は到着次第ポーリングが検出するため、長い既定のコストは「応答が永遠に来ないラウンドの見切りの遅さ」のみ） |
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

環境変数で個別上書き可: `XREV_CONFIG`, `XREV_PRIMARY`（primary の明示指定。D1。入口の自己申告に使う。
config の `primary` より優先）, `XREV_REVIEWER`（reviewer の明示指定。D1。新設・最優先。config の
`reviewer` 固定値との差も含め、明示指定は常に優先し質問しない）, `XREV_REVIEWER_PANE_TITLE`,
`XREV_REVIEWER_SURFACE`,
`XREV_CMUX_BIN`, `XREV_MAX_ITERATIONS`, `XREV_STOP_AT`, `XREV_ADR`, `XREV_ADR_DIR`,
`XREV_READ_SCREEN_LINES`, `XREV_SEND_SETTLE_SECONDS`, `XREV_SUBMIT_SETTLE_SECONDS`,
`XREV_CHUNK_SIZE`, `XREV_CONTENT_TYPE`, `XREV_ROUND_ID`, `XREV_SEND_RETRIES`,
`XREV_RESPONSE_TIMEOUT_SECONDS`, `XREV_RESPONSE_POLL_SECONDS`,
`XREV_REVIEWER_PROCESS`, `XREV_ALLOW_GLOBAL_RESOLVE`, `XREV_ALLOW_CROSS_WS`,
`XREV_MAX_TRANSPORT_ATTEMPTS`, `XREV_ROUND_STATE`,
`XREV_REVIEWER_BIN`（reviewer バイナリ名の明示指定。最優先。C1）,
`XREV_CODEX_BIN`（reviewer バイナリ名の後方互換エイリアス。config の `reviewer` が `codex` の
ときのみ有効。それ以外の reviewer で指定されていたら警告のうえ無視する）,
`XREV_REFERENCE_MODE`, `XREV_EXPECT_DIFF_HASH`, `XREV_EXPECT_HEAD`, `XREV_MAX_REFERENCE_FALLBACKS`,
`XREV_REVIEWER_AUTOCREATE`, `XREV_REVIEWER_CREATE_TIMEOUT_SECONDS`, `XREV_WIRE_MAX_CHARS`,
`XREV_REVIEWER_LAUNCH_ARGS`（JSON 配列文字列。`reviewer_launch_args` の該当 reviewer 分を上書きする。
文字列のみの配列・印字可能ASCIIのみという型検証は config 由来の値と同じ。さらに決定した引数列
そのものを安全ポリシーの意味検証に通すため、安全ポリシーを満たさない上書きは fail closed で拒否される
—詳細は[reviewer ペインのライフサイクル](reviewer-lifecycle.md)の「reviewer read-only 強制」参照）、
`XREV_ALLOW_UNVERIFIED_REVIEWER`（`1` で「既存 reviewer 採用時の安全ポリシー実効検証」を明示 opt-out
する。手動で用意した reviewer を使う運用を壊さないための後方互換フラグ。既定は検証する
=fail closed。詳細は[reviewer ペインのライフサイクル](reviewer-lifecycle.md)の「reviewer read-only 強制」参照）。
`XREV_CONTENT_TYPE`/`XREV_ROUND_ID` は通常自動決定で、テスト・デバッグ時のみ明示する。

### reviewer の auto 解決と semantic kind（D1）

**semantic kind = 解決済み reviewer 名（`codex`/`claude`）を唯一の種別判定源とする。** 安全ポリシー
検証（`_xrev_check_policy` の kind）・送信完全性方式（`_xrev_integrity_kind`）・launch 引数選択
（`_xrev_reviewer_launch_args`）・composer クリア方式（`_cmux_clear_input`）はすべてこの semantic
kind（`transport.sh` の `REVIEWER` 変数。`_xrev_resolve_reviewer` が解決）で決まる。旧来の
「kind = 前景プロセス名（`reviewer_process`）の basename」という定義は D1 で置き換わった。
`reviewer_process` はバイナリがラッパ（例 `my-codex-wrapper`）であっても前景 comm 名の照合専用
であり続け、種別判定には一切影響しない。

**reviewer 設定の矛盾検査（副作用の前・fail closed。`_xrev_check_reviewer_conflicts`）**:

- `reviewer_process` の明示値（`auto` 由来でない値）の basename が `codex`/`claude` のどちらかで、
  解決済み `reviewer` と異なる場合 → 設定エラー（新設 `exit 29`＝`reviewer_config_conflict` で
  拒否する）。それ以外の明示値（ラッパ名等）は前景照合にのみ使われ、矛盾として扱わない。
- `reviewer=claude` で `reviewer_reads_workspace` が明示 `false` の場合 → 設定エラー（同じく
  `exit 29`）。claude reviewer は参照モード専用のため、参照モードを禁止する組み合わせは矛盾。
- `reviewer_pane_title` は検査しない（誤 title のまま送信しても、既存の process 証明
  （`exit 17`）が送信前に止めるため。宛先解決自体は解決済み `reviewer` のタイトルだけを
  resolve し、両タイトルのペインが共存していても曖昧判定はしない）。

**共有ゲート（`_xrev_guard_reviewer_conflicts`。指摘3・2巡目）**: この矛盾検査は
`xrev_transport_review`（送信直前）だけでなく、`xrev_ensure_reviewer`（reviewer ペインの自動生成。
`_xrev_classify_reviewer` を呼ぶ**前**）と `start-reviewer.sh`（タイトル変更・codex の exec 起動の
**前**）でも同じ1関数を通す。従来は `xrev_transport_review` にしか組み込まれておらず、
`ensure-reviewer`／`start-reviewer.sh` は矛盾があってもペイン生成・タイトル変更まで進んでから
（reviewer=claude + reads_workspace 明示 false では使用不能なペインを生成後の送信時に、
reviewer_process 矛盾では生成後の起動確認が別理由で失敗する形で）気づいていた。既知の矛盾を
検出できるのに副作用の大きい操作（ペイン生成・exec）へ進めてしまう事故を避けるため、3経路すべてが
副作用の直前にこの1関数を呼び、判定リストを二重管理しない。

**後方互換**: `XREV_PRIMARY` 未設定・既定 config（`reviewer=auto`）のとき、`primary`（既定
`claude`）から `reviewer=codex` に解決され、派生3キーも旧来の既定値（`Review Codex`/`codex`/
`false`）と完全同値になる。**主従反転プリセット（`config/xrev.codex-primary.json`）と等価な状態**
は、既定 config のまま `XREV_PRIMARY=codex` を自己申告するだけで得られる（`reviewer=claude`・
`reviewer_pane_title=Review Claude`・`reviewer_process=claude`・`reviewer_reads_workspace=true`
が auto 解決される）。プリセットファイルは値を config へ明示的に固定しておきたい場合にのみ使う
（挙動は等価）。

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

### 完了アクション（stop_at）の解決順

`scripts/finalize.sh` は完了アクションを次の優先順で決める（高 → 低）:

1. 引数（その場指定。依頼文 / `/xrev` 引数 / 一拍確認の回答を Claude が渡す）
2. 環境変数 `XREV_STOP_AT`（シェル / プロジェクト単位の既定上書き）
3. `config` の `stop_at`（プロジェクト全体の既定）
4. `review`（最終フォールバック・最も安全）
