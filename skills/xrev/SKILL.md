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

宛先 Codex ペインは**タイトル名 `Review Codex` から動的に surface を解決**する（再起動で ID が変わっても
名前は不変、という前提）。解決に失敗したらスクリプトがエラーを返すので、その場合はペインの有無と
タイトルをユーザーに確認する（`XREV_REVIEWER_SURFACE` で明示指定も可能）。

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

出力 JSON の `decision` を見て上の分岐を行う。`findings[]` に修正対象の指摘（file/line/severity/
category/message/suggested_fix）が入る。**修正反映（コードやプランの編集）は primary である自分が行う**
— スクリプトはコードを書き換えない。

### 往復を無限に続けない（終端の機械判定）

- 終了条件は**機械が握る**: `critical` と `high` が 0 件になったら `converged`。
- `medium` 以下は blocker ではない。収束を妨げない。1〜2 周で対応できるものは反映し、
  それ以降は無視して収束扱い（追撃しない）。
- reviewer が `think`（熟考中）や `close`（議論終端）に相当する応答をしたら追撃・相槌を送らない。

## 4. 実装フェーズのレビュー往復（実装後）

設計が `converged` したら実装する。実装できたら**同じループを diff に対して**回す。

```
ITER=1
payload = 「git diff（実装差分）＋ 何を実装したかの要約」
loop: 設計フェーズと同じ分岐（converged / continue / escalate / invalid / transport_error）
```

`continue` のたびに、自分が指摘を反映してコードを編集し、`payload` は**前回からの差分だけ**にして
`ITER += 1` で再実行する（毎回全文を送らない。Codex 側が履歴を持っている）。

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
