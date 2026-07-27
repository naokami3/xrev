# codex 主プレイブック — primary = Codex / reviewer = Claude

xrev の主従反転（primary=codex・reviewer=claude）向けの手順書。既定 config の `reviewer` は
`auto` であり、`XREV_PRIMARY=codex` を自己申告するだけでこの主従反転が導出される（2章参照）。
値を config ファイルへ明示的に固定しておきたい場合は主従反転プリセット
（`config/xrev.codex-primary.json`）を使ってもよい（挙動は等価）。既定構成（primary=Claude・
reviewer=Codex）の正典は [`../skills/xrev/SKILL.md`](../skills/xrev/SKILL.md) だが、その中身は
Claude Code のスキル機構（`allowed-tools` 等）に紐づくため、**codex がそのまま読んで実行できる形**
としてここに手順を複製する。スクリプト契約そのもの（センチネル・severity・終了コード・設定キー）は
[protocol.md](protocol.md) が正典であり、ここでは重複させず参照する。

**前提**: このリポジトリで xrev 自身を codex で開発する場合は `XREV_ROOT` はリポジトリルート。
利用者プロジェクトから使う場合は、`scripts/print-agents-snippet.sh --append-global` でこのマシン
上に一度だけ導入したグローバル `AGENTS.md`（`$CODEX_HOME/AGENTS.md`。既定 `~/.codex/AGENTS.md`）
のスニペットが `XREV_ROOT` を解決してくれる（プロジェクトごとの `AGENTS.md` への貼り付けは不要）。
以下の手順はすべて `XREV_ROOT` が解決済みであることを前提にする。

## 1. 発火条件

次のいずれかで発火する。それ以外（些細な変更・キーワード無し）では発火しない。

- ユーザーの依頼文を `$XREV_ROOT/scripts/keyword-match.sh` にかけて判定する（stdin=依頼文、
  exit 0=発火/exit 1=非発火）。keyword は config の `keyword`（既定 `@xrev`）を読むので、
  プレイブック側でキーワード文字列をハードコードしない。

  ```bash
  printf '%s' "$依頼文" | XREV_CONFIG="$XREV_ROOT/config/xrev.default.json" \
    bash "$XREV_ROOT/scripts/keyword-match.sh"
  ```

- 明示指示（「xrev で往復して」等）でも発火してよい。
- どちらも無ければ**完全に沈黙**する（暴発防止）。

## 2. まず一拍、人間に確認する（往復を即開始しない）

発火したら即座に往復を始めず、次を人間に確認する。

1. **完了アクション（`stop_at`）**: `review`（既定・最も安全）/ `commit` / `pr`（ドラフト）。
2. **ADR 生成**: する / しない（既定 `false`）。

あわせて reviewer ペインの用意を行う。**ユーザーに手動でペインを開かせない**（スクリプトの
手実行もさせない）。用意は自分（codex）が次の手順で行う:

1. `XREV_PRIMARY=codex` を設定した上で `"$XREV_ROOT/scripts/transport.sh" resolve --json` を実行し、
   同一ワークスペースに使える `Review Claude` ペインが**あるか**を確認する。
2. **無ければ（ok:false）**、一拍確認の中で「reviewer（claude・read-only 相当の plan モード）ペインを
   自動生成してよいか」を一度だけユーザーに確認し、了承を得たら
   `"$XREV_ROOT/scripts/transport.sh" ensure-reviewer` を**自分で実行**する（launch 引数
   `--permission-mode plan` の付与・起動確認・タイトル設定まで自動で行われる。冪等）。
3. **既にある場合**は、そのペインが**今回の作業用に履歴ゼロ**か（別作業の文脈を引き継いでいないか）を
   ユーザーに目視確認してもらう。作業を切り替えたときはペインを閉じて 2. で作り直す。

既存ペインが壊れ/曖昧/別物のときは ensure-reviewer が作り直さず該当 exit（14/16/17/27）で
止まるので、診断に従いユーザーへ相談する。

**前提検査（doctor / ping）が cmux 接続で失敗した場合**（exit 31）: reviewer の用意より先に、
**自分（codex）が cmux ペイン内で動いているか**を疑う。`env` に `CMUX_SURFACE_ID` 等が無ければ
cmux ペイン外で起動されており、この状態では何を準備しても往復できない。ユーザーには「ペインを
開いて」ではなく「**cmux 内のペインで対象プロジェクトのディレクトリから codex を起動し直して
ほしい**」と案内する（認証情報はペイン内シェルにのみ注入される。SKILL.md 2 章と同じ制約）。
`CMUX_*` はあるのに ping が失敗する場合は、その事実（env の有無・ping の exit code）を
そのままユーザーへ報告して判断を仰ぐ。

確認が取れたら往復に入る。**codex の実行モデルに合わせた 2 つの必須事項**（実運用の初回試行で確定）:

1. **環境変数は毎コマンド前置**: codex のシェルはコマンドごとに新規で `export` は持ち越されない。
   `XREV_PRIMARY=codex`（自己申告）等は、`transport.sh` / `review-loop.sh` を呼ぶ**各コマンドの先頭に
   毎回前置**する。
2. **transport 系はサンドボックス外実行（エスカレーション）**: cmux ソケットへの接続は codex の
   サンドボックス内では遮断される（実測: ペイン内・CMUX_* 注入済みでも ping が exit 31。
   サンドボックス外実行では成功）。`transport.sh`（ping/resolve/ensure-reviewer/diff-hash）と
   `review-loop.sh` の呼び出しはエスカレーション承認で実行する。毎回の承認が煩わしければ
   セッション単位の承認を使う。read-only の `keyword-match.sh` や playbook の読み取りは
   サンドボックス内のままでよい。

```bash
XREV_PRIMARY=codex "$XREV_ROOT/scripts/transport.sh" ping   # ← この形で毎回前置・要エスカレーション
```

**`XREV_CONFIG` に主従反転プリセット（`xrev.codex-primary.json`）を明示する必要は無くなった**:
既定 config の `reviewer` は `auto` であり、`XREV_PRIMARY=codex` の自己申告から
`transport.sh` が「primary の相手方」として `reviewer=claude`（`reviewer_pane_title=Review
Claude` / `reviewer_process=claude` / `reviewer_reads_workspace=true` も連動して導出）を機械的に
解決する。`xrev.codex-primary.json` は**この主従反転を明示的に固定したい場合にのみ**使うプリセットと
して残っている（例: auto 解決に頼らず値を config ファイルへ書き切っておきたい運用）。使う場合は
`XREV_CONFIG="$XREV_ROOT/config/xrev.codex-primary.json"` を各コマンドに前置する（挙動は
等価）。詳細・派生規則の正典は [protocol.md](protocol.md) の「設定キー一覧」を参照。

reviewer の有無確認・自動生成の契約詳細（`reviewer_autocreate` の ask/auto/off・競合ロック・
終了コード）は [`../skills/xrev/SKILL.md`](../skills/xrev/SKILL.md) の 2 章と同一
（手順そのものは上記 1〜3 のとおり。自動生成の存在を省略して「ペインを開いているか」だけを
ユーザーに尋ねる案内をしないこと — 実運用で codex が手動起動を依頼してしまった実例に基づく注意）。

## 3. 設計フェーズ → 実装フェーズの往復

**筋の悪いプランを実装前に潰すことが主目的。** まず設計・実装プランを固め、それを reviewer に回す。
実装フェーズは同じループを diff に対して回す。手順・呼び出し方は既定構成と同一
（`$XREV_ROOT/scripts/review-loop.sh` を介す。cmux は直接叩かない）:

```bash
# 毎コマンド前置 + サンドボックス外実行（2 章の必須事項）
ITER=1
printf '%s' "$payload" | XREV_PRIMARY=codex XREV_ROUND_STATE="$prev_round_state" \
  "$XREV_ROOT/scripts/review-loop.sh" "$ITER"
```

- `payload`（stdin）と `ITER`（引数）を渡し、返ってきた決定 JSON の `round_state` を次回の
  `XREV_ROUND_STATE` へそのまま引き継ぐ（ループ安全弁。渡し忘れる/巻き戻すと `escalate` になる）。
- `decision` で分岐する（終了コードでは判断しない）:
  `converged`（収束・次工程へ）/ `continue`（primary が指摘を反映し `ITER+1` で再実行）/
  `escalate`（上限到達・人間へ）/ `invalid`（reviewer 出力が契約違反・再送を検討）/
  `transport_error`（送受信失敗・ペイン/タイトルを確認。**`truncated`/`send_failed` は生成直後
  ペインへの初回送信で高頻度に発生する実測パターン**であり異常ではない — `round_state` を
  引き継いで同一 ITER をそのまま再試行する。ペインの作り直しに走らない。実測は
  [../docs/cmux-behavior.md](../docs/cmux-behavior.md) 9節）/ `reference_unverified`
  （参照モード時のみ。回復手順は reviewer 種別依存— 6章「claude reviewer 固有の注意」参照）。
- 各分岐の詳細な扱い・終端判定・参照モードの手順は
  [`../skills/xrev/SKILL.md`](../skills/xrev/SKILL.md) の 3〜5 章、終了コードと `decision` の
  対応は [protocol.md](protocol.md) の「終了コード設計」節を正典として参照する（ここでは複製しない）。

## 4. 収束後

`converged` したら:

1. **ADR 生成**（一拍確認で「する」を選んだ場合のみ）: 往復ログを素材 JSON にまとめ
   `$XREV_ROOT/scripts/make-adr.sh` に渡す。出力先の解決順・素材 JSON の形は
   [`../skills/xrev/SKILL.md`](../skills/xrev/SKILL.md) 6 章と同一。
2. **完了アクション分岐**: 確認済みの完了アクションに従って `$XREV_ROOT/scripts/finalize.sh` を呼ぶ。
   **PR は必ずドラフト固定**（`--draft`）。既定は `review`（何も書き換えない）。

```bash
"$XREV_ROOT/scripts/finalize.sh" review                              # 既定
"$XREV_ROOT/scripts/finalize.sh" commit "<日本語のコミットメッセージ>" # 1コミット=1論理変更
"$XREV_ROOT/scripts/finalize.sh" pr "<PRタイトル>" "<PR本文>"          # ドラフトPR
```

## 5. やってはいけないこと

[`../skills/xrev/SKILL.md`](../skills/xrev/SKILL.md) 8 章と同一 + primary が cmux ペイン内で
動く前提を明記する。

- 中間ファイルをリポジトリに生成する（ADR 以外）。
- cmux コマンドをこのプレイブックから直接叩く（必ず `scripts/transport.sh` 経由）。
- キーワードや明示指示が無いのに発火する。
- 既定で commit / pr へ進む（既定は review）。
- 非ドラフト PR を作る / 人間の確認なしにマージ・確定する。
- 上限到達やエスカレーション時に、人間を飛ばして勝手に完了アクションへ進める。
- **primary（この codex）を cmux ペインの外で動かす**: cmux ソケットは認証が要り、認証情報は
  cmux ペイン内シェルにのみ自動注入される。`$XREV_ROOT/scripts/transport.sh ping` で接続を
  確認してから往復に入ること。

## 6. claude reviewer 固有の注意（実装フェーズは参照モード必須）

この主従反転プリセットでは reviewer が Claude Code（`--permission-mode plan`）になる。codex を
reviewer にする既定構成とは送信完全性検証・復号契約が異なるので、payload を組む際に次を守る。

- **claude reviewer は参照モード専用**: claude はペーストチップに文字数を表示しない（実測。
  `../docs/cmux-behavior.md` 参照）ため codex 向けの文字数照合が成立しない。全文一致照合（wire
  文字列そのものが composer に完全一致部分文字列として存在するかの空白非依存比較）を使う案も
  検討したが、空白の位置がずれる改変を比較・decoder のどちらも検出できず完全性証明にならないため
  不採用となった（2巡目クロスレビューで棄却。詳細は [protocol.md](protocol.md) 参照）。よって
  **claude reviewer への inline 送信（本文を wire にそのまま載せる方式）は wire 長に関わらず
  無条件で `exit 28`（`integrity_unverifiable`）になり送信前に拒否される**。
  `XREV_PRIMARY=codex`（既定 config・auto 解決）でも `config/xrev.codex-primary.json`（明示プリセット）
  でも、reviewer=claude のときは `reviewer_reads_workspace=true` になる（D1: reviewer=claude での
  明示 false は設定エラーとして拒否される）。**実装フェーズは必ず下記の参照モード手順を使うこと**。
  詳細・根拠は [protocol.md](protocol.md)「参照モード」節を参照。
- **設計フェーズのクロスレビューは claude reviewer では現状非対応**: 設計フェーズはコードが無く
  diff を持たないため常に inline になり、上記の理由で送信自体が成立しない。設計段階のレビューが
  必要な場合は、人間レビューに切り替えるか、既定構成（primary=Claude・reviewer=Codex）を使うこと。
- **参照モードの手順**（実装フェーズ限定。`../skills/xrev/SKILL.md` 4章「コンテキスト削減：参照
  モード」と同一の契約。`reviewer_reads_workspace=true` かつ同一WS解決時のみ使える）:

  ```bash
  T="$XREV_ROOT/scripts/transport.sh"
  RANGE="HEAD"                                  # 未コミット全変更。ブランチは <baseOID>...<headOID>（解決済みOID）
  EXPECT_HASH="$("$T" diff-hash "$RANGE")"      # 期待 diff ハッシュ（primary と reviewer の単一の真実源）
  EXPECT_HEAD="$(git rev-parse HEAD)"           # 期待 基底 HEAD OID（diff 一致だけでは基底相違を防げないため必須）
  # 参照 payload を組む（diff 本文は入れない）: 実装要約 + 変更ファイル一覧(git diff --name-only) +
  #   reviewer への指示:「自分の作業ツリーで `<Tの絶対パス> diff-hash <RANGE>` を実行し、その出力を
  #   reference_context.diff_hash に、`git rev-parse HEAD` を reference_context.head に、mode:"reference"・
  #   status:"verified" を入れて返す。ファイルは変更しないこと」。
  printf '%s' "$payload" | \
    XREV_REFERENCE_MODE=1 XREV_EXPECT_DIFF_HASH="$EXPECT_HASH" XREV_EXPECT_HEAD="$EXPECT_HEAD" \
    XREV_ROUND_STATE="$prev_round_state" "$XREV_ROOT/scripts/review-loop.sh" "$ITER"
  ```

  `reviewer` の `reference_context`（mode/status/head/diff_hash）が期待と不一致・未取得・同一WS外
  なら `decision=reference_unverified`（exit0）になる。**claude reviewer は参照モード専用（inline
  は無条件 exit28）なので、この回復は inline へのフォールバックではなく「同一 ITER・参照モードの
  まま再試行」とする**（`reference_unverified` が起きたら、まず同一WS・同一worktreeの前提が
  崩れていないかを疑い、崩れていなければ同じ `XREV_REFERENCE_MODE=1` のまま同一 `ITER` で
  `review-loop.sh` を再度呼び出す）。総量規制は既存の `max_reference_fallbacks` / round_state の
  `reference_fallbacks` カウンタをそのまま使う（名称は変えないが、意味は「参照検証失敗時の
  再試行回数」に一般化されている。codex reviewer では従来どおり同一 ITER を inline で再試行して
  よい）。フォールバック通算 `reference_fallbacks` が `max_reference_fallbacks` を超えると
  `escalate`（人間へ）。状態機械（review-loop.sh）自体は reviewer 種別を判別しないため、回復手順の
  分岐（inline 再試行 or 参照モード再試行）は primary（このプレイブック）側の責務である。
- **reviewer 側復号契約**: wire の `LEN_*` 各フィールド長が不一致、または末尾 `END_ROUND_<id>`
  マーカーが欠落している場合、reviewer はレビューを行わず `decode_error` の finding を 1 件だけ
  返す契約になっている。この finding は severity や `severity_blockers` の設定に関わらず**常に
  blocker として集計される**（誤収束防止）。
- **注意（実測 R6 の知見）**: プレイブック本文や payload の中に、**センチネル（`===XREV-JSON-BEGIN===`
  等）で挟んだ体裁の例示 JSON を書かない**こと。`_scan_review_blocks` は画面全体を de-wrap して
  JSON を走査する実装のため、指示文中の例示 JSON がセンチネルの外にあっても妥当なブロックとして
  誤検出されうる（実測で確認済みの既存挙動）。JSON の具体例を書く必要がある場合は、完結した JSON
  として書かず断片表記（例: `{"round_id": "...", ...}` のように途中で区切る）に留める。
