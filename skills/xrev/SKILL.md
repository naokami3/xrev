---
name: xrev
description: >-
  依頼文に @xrev が含まれるとき、または「設計段階から Codex クロスレビューを回す」指示が
  コンテキストに注入されたときに発火する。primary(既定 Claude) が設計・実装を担い、
  reviewer(既定 Codex) が cmux 経由でクロスレビューを行う往復を、設計フェーズから自動運用する。
  critical/high が 0 件になるまでレビュー指摘を反映し、収束後に到達点（review/commit/pr）へ進める。
  キーワードや明示指示が無い些細な変更では発火しない。
allowed-tools: Bash Read Edit Write Grep Glob
---

# xrev — 設計段階からのクロスレビュー往復

AI コーディングエージェント同士に、**設計段階からクロスレビューの往復**を人間の操作なしで行わせる。
既定では **primary = Claude（設計・生成・修正反映）**、**reviewer = Codex（レビュー専用・read-only）**。
レビュー往復は cmux のペイン間通信を介して行い、収束後はオプションで ADR を生成し、到達点を選ぶ。
**最後の確認は必ず人間が行う。**

主従はキーワードではなく設定（`config/xrev.default.json` の `primary`/`reviewer`）が決める。
このスキルのロジックは主従非依存で書かれており、将来 Codex 主・Claude レビュー構成にも流用できる。

## 0. 発火条件

次のいずれかで発火する。それ以外（些細な変更・キーワード無し）では発火しない。

- ユーザーの依頼文に `@xrev`（設定の `keyword`）が含まれる
- UserPromptSubmit フックが「設計段階から Codex クロスレビューを回す」指示を注入した

## 1. まず一拍、人間に確認する（往復を即開始しない）

発火したら**即座に往復を始めず**、次の 2 点をユーザーに一度だけ確認する。自動化と人間の制御の両立点。

1. **到達点（stop_at）**: `review`（最も安全。コミットしない）/ `commit` / `pr`（ドラフト）。
   既定値は次の優先順で決まる: ユーザーの明示指定 → 環境変数 `XREV_STOP_AT` → `config` の `stop_at`
   → `review`。確認時は「現在の既定（config/環境変数の値）」を提示し、変えるか尋ねる。
2. **ADR 生成**: する / しない。既定は ユーザーの明示指定 → 環境変数 `XREV_ADR`（`true`/`false`）
   → `config` の `adr` → `false` の順で決まる。生成する場合の**出力ディレクトリ**も確認できる
   （既定は `XREV_ADR_DIR` → `config` の `adr_dir` → `docs/adr`）。

あわせて前提を確認・案内する:

- cmux 上に **reviewer 用 Codex ペインがタイトル `Review Codex`（設定 `reviewer_pane_title`）で 1 枚**開いているか。
- そのペインは**今回の作業用に履歴ゼロから**始まっているか（別作業の文脈を引き継いでいないか）。
  作業を切り替えるときは Codex を再起動して履歴を切る運用。セッション復元フックが前作業を
  復元していないか目視確認してもらう。

確認が取れたら、必要に応じて環境変数で設定を上書きして往復に入る:

```bash
export XREV_CONFIG="${CLAUDE_PLUGIN_ROOT}/config/xrev.default.json"   # 既定。プロジェクト固有設定があれば差し替え
# 任意の上書き例:
# export XREV_REVIEWER_PANE_TITLE="Review Codex"
# export XREV_MAX_ITERATIONS=5
```

## 2. 配管の前提（cmux）

reviewer との往復は配管抽象 `scripts/transport.sh` が担う。**cmux 依存はそこだけに閉じ込められている**。
このスキルから cmux コマンドを直接叩かない。往復は必ず `scripts/review-loop.sh` を介す。

**前提: primary（この Claude Code）が cmux ペイン内で動いていること。** cmux ソケットは認証が要り、
認証情報はペイン内シェルにのみ自動注入される。cmux の外（通常ターミナル）から起動していると配管は
ソケットに接続できない。最初に `"${CLAUDE_PLUGIN_ROOT}/scripts/transport.sh" ping` で接続を確認し、
失敗したら「cmux ペイン内で Claude Code を起動し直す」ようユーザーに案内する。

宛先 Codex ペインは**呼び出し元(primary)と同一ワークスペース内**で、タイトル名 `Review Codex` から
surface を解決する（別ワークスペースの同名 Codex へ誤配送しない）。さらに送信直前に「実ターミナルか」
「直下プロセスが codex か」を検証し、満たさなければ送らず止める（詳細・終了コードは
[references/protocol.md](../../references/protocol.md)）。解決・検証に失敗したらスクリプトがエラーを返すので、
ペインの有無・タイトル・**同一ワークスペースに居るか**をユーザーに確認する（`XREV_REVIEWER_SURFACE` で明示指定も可）。

**reviewer は「実ターミナル内の codex CLI」であること**（cmux のエージェント統合パネルは read-screen 不可で使えない）。
手早く用意するには、reviewer 用に開いた cmux の実ターミナルで次のヘルパを実行してもらう。規約タイトルを設定して
codex を起動するので、宛先解決とゲートが確実に通る:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/start-reviewer.sh"   # 自タブを Review Codex に設定して codex を exec
```

## 3. 設計フェーズのレビュー往復（実装前）

**筋の悪いプランを実装前に潰すことが主目的。** まず設計・実装プランを文章で固め、それを reviewer に回す。

```
ITER=1
payload = 「設計・実装プラン全文 ＋ 元課題の背景」    # 初回は文脈を十分に含める
loop:
  decision = review-loop.sh の出力（payload を stdin、ITER を引数）
  case decision.decision in
    converged   → プラン確定。実装フェーズへ。
    continue    → decision.findings の critical/high を反映してプランを修正。
                  payload = 「前回からの差分（何をどう直したか）」だけにする（Codex は履歴を保持）。
                  ITER += 1 で再実行。
    escalate    → 上限到達。人間にエスカレーションして停止（5章）。
    invalid     → reviewer が契約違反の出力。スキーマ準拠の再出力を促してリトライ（5章）。
    transport_error → 配管失敗。ペイン/タイトルを確認して再試行（5章）。
```

呼び出し例:

```bash
printf '%s' "$payload" | "${CLAUDE_PLUGIN_ROOT}/scripts/review-loop.sh" "$ITER"
```

**分岐は必ず stdout の JSON の `decision` フィールドで行う（終了コードでは判断しない）。**
review-loop.sh の終了コードは「レビューが完了したか」だけを表し、`continue`/`escalate` も含む
完了系は **exit 0**。`invalid`=21 / `transport_error`=22 のみ非ゼロ。Bash ツール経由だと非ゼロが
「Error」表示になるが、`continue`(正常系)は exit 0 なので誤判定しない。`findings[]` に修正対象の指摘
（file/line/severity/category/message/suggested_fix）が入る。**修正反映（コードやプランの編集）は
primary である自分が行う** — スクリプトはコードを書き換えない。

### 往復を無限に続けない（終端の機械判定）

- 終了条件は**機械が握る**: `critical` と `high` が 0 件になったら `converged`。
- `medium` 以下は blocker ではない。収束を妨げない。1〜2 周で対応できるものは反映し、
  それ以降は無視して収束扱い（追撃しない）。
- reviewer が `think`（熟考中）や `close`（議論終端）に相当する応答をしたら追撃・相槌を送らない。
- **round_state を必ず引き継ぐ（ループ安全弁）**: review-loop の決定 JSON に `round_state` が入る。次のラウンドでは
  これを `XREV_ROUND_STATE`（JSON）に渡して呼ぶ。通算 transport 試行が `max_transport_attempts` を超える、または
  `iter` を巻き戻すと `decision=escalate`（`state_violation` 付き）になり人間へエスカレーションする。状態を渡し
  忘れる/巻き戻すと安全弁が効かなくなるため、返ってきた `round_state` をそのまま次回へ渡すこと。

```bash
# 2 ラウンド目以降は前回の round_state を渡す（安全弁を効かせる）
printf '%s' "$payload" | XREV_ROUND_STATE="$prev_round_state" "${CLAUDE_PLUGIN_ROOT}/scripts/review-loop.sh" "$ITER"
```

## 4. 実装フェーズのレビュー往復（実装後）

設計が `converged` したら実装する。実装できたら**同じループを diff に対して**回す。

```
ITER=1
payload = 「git diff（実装差分）＋ 何を実装したかの要約」
loop: 設計フェーズと同じ分岐（converged / continue / escalate / invalid / transport_error）
```

`continue` のたびに、自分が指摘を反映してコードを編集し、`payload` は**前回からの差分だけ**にして
`ITER += 1` で再実行する（毎回全文を送らない。Codex 側が履歴を持っている）。

各ラウンドの決定 JSON の `round_state` を**次回の `XREV_ROUND_STATE` にそのまま渡す**（ループ安全弁。3章参照）。

### コンテキスト削減：参照モード（Phase2・reviewer が同一作業ディレクトリを読めるとき）

`reviewer_reads_workspace=true` かつ宛先が**同一WS解決(resolve_path=same_ws)**のときだけ使える。実装フェーズで
diff 本文を送らず、reviewer に自分で diff を取得させてコンテキストを削減する。設計フェーズは常に inline。

手順（往復の前に。**primary と reviewer は同一コード `transport.sh diff-hash` を使う**＝単一の真実源）:

```bash
T="${CLAUDE_PLUGIN_ROOT}/scripts/transport.sh"
RANGE="HEAD"                                  # 未コミット全変更。ブランチは <baseOID>...<headOID>（解決済みOID）
EXPECT_HASH="$("$T" diff-hash "$RANGE")"      # 期待 diff ハッシュ（単一の真実源）
EXPECT_HEAD="$(git rev-parse HEAD)"           # 期待 基底 HEAD OID（diff 一致だけでは基底相違を防げないため必須）
# 参照 payload を組む（diff 本文は入れない）: 実装要約 + 変更ファイル一覧(git diff --name-only) +
#   reviewer への指示:「自分の作業ツリーで `<Tの絶対パス> diff-hash <RANGE>` を実行し、その出力を
#   reference_context.diff_hash に、`git rev-parse HEAD` を reference_context.head に、mode:"reference"・
#   status:"verified" を入れて返す。ファイルは変更しないこと」。
printf '%s' "$payload" | \
  XREV_REFERENCE_MODE=1 XREV_EXPECT_DIFF_HASH="$EXPECT_HASH" XREV_EXPECT_HEAD="$EXPECT_HEAD" \
  XREV_ROUND_STATE="$prev_round_state" "${CLAUDE_PLUGIN_ROOT}/scripts/review-loop.sh" "$ITER"
```

分岐に `reference_unverified` が増える: reviewer の reference_context（mode/status/head/diff_hash）が期待と不一致＝別対象を
見た or 同一WS外、とみなし、**同一 ITER を inline（diff 本文を送る通常方式）で再試行**する（`XREV_REFERENCE_MODE` を
付けずに再呼び出し）。フォールバックが `max_reference_fallbacks` を超えると `escalate` になるので人間へ。**安定窓**:
参照 payload 送信〜応答まで作業ツリーを編集しないこと。前提（同一WS・同一worktree）が崩れていれば素直に inline に倒す。

## 5. 例外時の扱い

- `escalate`（最大反復に到達しても blocker が残る）: **強制的に人間へエスカレーション**。
  残った critical/high と往復経緯を要約して提示し、判断を仰ぐ。勝手に到達点へ進めない。
- `invalid`（reviewer が自由作文や壊れた JSON を返す）: スキーマ
  （`references/review-schema.json`）への準拠を促して同じ payload を 1 回だけ再送。
  なお改善しなければ人間に報告。
- `transport_error`（送受信失敗）: `Review Codex` ペインの存在・タイトル・常駐を確認。
  `XREV_REVIEWER_SURFACE` 明示指定も検討。

## 6. ADR 生成（必要有無の確認で「する」を選んだ場合のみ）

`off` が既定。生成有無は `XREV_ADR` → `config` の `adr` → `false` で既定が決まり、一拍確認で上書きできる。
生成する場合のみ、往復ログ（誰が何を propose し、どう react し、最終的に何を decide したか）を
素材 JSON にまとめて `scripts/make-adr.sh` に渡す。

```bash
# 出力先は XREV_ADR_DIR → config の adr_dir → docs/adr の順で解決
printf '%s' "$adr_material_json" | "${CLAUDE_PLUGIN_ROOT}/scripts/make-adr.sh"

# 出力ディレクトリをその場指定する場合（相対は対象リポジトリ基準 / 絶対パスも可）
printf '%s' "$adr_material_json" | "${CLAUDE_PLUGIN_ROOT}/scripts/make-adr.sh" docs/decisions
```

出力ファイルは解決したディレクトリ配下の `ADR-NNN.md`（連番）。生成したパスが stdout に返る。

ADR は **xrev が許容する唯一のファイル生成物**（「中間ファイル」ではなく「意図して残す成果物」）。
素材 JSON の形は `scripts/make-adr.sh` 冒頭コメント参照（title/context/decision/consequences/discussion[]）。

## 7. 到達点分岐（収束後）

確認した `stop_at` に従って `scripts/finalize.sh` を呼ぶ。引数を渡せばその場指定が最優先。引数を省くと
finalize.sh が `XREV_STOP_AT` → `config` の `stop_at` → `review` の順で既定を解決する。**最終フォールバックは
`review`。明示指定が無ければ書き換えない。**

### コミット境界ルール（commit / pr のとき厳守）

- **1 コミット = 1 つの論理的変更**（1 機能 / 1 修正）。
- **レビュー指摘の修正は元の変更にまとめる**。指摘対応を別コミットに分けない
  （往復で生じた手直しは、それが直している元コミットに統合する）。
- ステージング（`git add`）はこの境界ルールに従って自分で行ってから finalize を呼ぶ。

```bash
# review（既定）: 何も書き換えない
"${CLAUDE_PLUGIN_ROOT}/scripts/finalize.sh" review

# commit: 境界ルールに従って git add 済みの変更を 1 論理単位でコミット
"${CLAUDE_PLUGIN_ROOT}/scripts/finalize.sh" commit "<日本語のコミットメッセージ>"

# pr: コミット後、ドラフト PR を作成（--draft 固定。base は既定ブランチ）
"${CLAUDE_PLUGIN_ROOT}/scripts/finalize.sh" pr "<PRタイトル>" "<PR本文>"
```

**PR は必ずドラフト。マージ・Ready 化・確定の最終トリガは人間が引く。** これが「人間の最終チェックは
必要」要件の物理的保証であり、スキルから非ドラフト PR を作る経路は持たない。

## 8. やってはいけないこと

- 中間ファイルをリポジトリに生成する（ADR 以外）。
- cmux コマンドをこのスキルから直接叩く（必ず scripts 経由）。
- `@xrev` や明示指示が無いのに発火する。
- 既定で commit / pr へ進む（既定は review）。
- 非ドラフト PR を作る / 人間の確認なしにマージ・確定する。
- 上限到達やエスカレーション時に、人間を飛ばして勝手に到達点へ進める。
