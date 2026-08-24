# 参照モード（Phase2）

[`../protocol.md`](../protocol.md)（索引）から分割された正典の一部。

**この文書で分かること**:

- 参照モードが使える条件（reviewer_reads_workspace かつ同一 WS 解決）と目的
- diff 内容ハッシュ + 基底 HEAD OID による同一性照合の仕組み（diff-hash が単一の真実源）
- reference_unverified 時の回復手順（codex=inline 再試行 / claude=参照モードのまま再試行）
- 同一性検証が保証しないこと（レビュー品質は含まない）

### 参照モード（Phase2: コンテキスト削減・diff 本文を送らない）

`reviewer_reads_workspace=true` かつ**同一WS解決(resolve_path=same_ws)**のときのみ使える。diff 本文を
cmux に流さず、reviewer に「自分で diff を取得してレビュー」させて送受信・reviewer 双方のコンテキストを削減する。
別WS/別worktreeの誤レビューは **diff 内容ハッシュの不一致**で自動的に弾き、`reference_unverified` として
再試行させる（再試行の手段は下記のとおり reviewer 種別依存）。設計は 7 ラウンドのクロスレビューで収束。

- **適用は実装フェーズのみ**（設計フェーズはコードが無く常に inline）。
- **claude reviewer はこの参照モードが必須（専用）**: claude・inline は wire 長に関わらず常に
  `exit 28` になる（[メッセージ書式](message-format.md)の「切り詰め検出」参照。全文一致照合による inline 受理経路はクロスレビュー
  2巡目で完全性証明にならないと指摘され撤去済み）。したがって主従反転プリセット
  （`config/xrev.codex-primary.json`）は `reviewer_reads_workspace=true` を既定にし、実装フェーズは
  必ずこの参照モードを使う。**設計フェーズのクロスレビューは claude reviewer では現状非対応**
  （設計フェーズはコードが無く常に inline になるため、上記の理由で送信自体が成立しない）。設計段階の
  レビューが必要な場合は人間レビューに切り替えるか、reviewer=codex の既定構成を使うこと。
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
  primary は同一 ITER で再試行する。**再試行の手段は reviewer 種別依存**（review-loop.sh 自身は
  reviewer 種別を判別しない状態機械であり、分岐は primary 側の責務）: codex reviewer は従来どおり
  同一 ITER を inline で再試行してよいが、claude reviewer は inline が常に `exit 28` になるため
  **同一 ITER・参照モードのまま再試行する**（inline へは切り替えない。詳細は
  [`../codex-primary-playbook.md`](../codex-primary-playbook.md) 6章）。フォールバック通算 `reference_fallbacks` が
  `max_reference_fallbacks` を超えたら `escalate`（無限往復防止）。`reference_fallbacks` は
  round_state に載り次回へ引き継ぐ（名称は「参照→inlineフォールバック」由来だが、意味は
  「参照検証失敗時の再試行回数」に一般化されている）。
- **意味の限定**: `reference_context` は「primary と reviewer が同一 diff を取得した」ことの同一性検証であり、
  reviewer がその diff を実際にレビューしたこと・品質を保証しない（信頼済み reviewer 前提）。
- **read-only 不変・安定窓**: reviewer は読むだけ。primary は参照 payload 送信〜応答受領まで作業ツリーを編集しない。
- クロスホスト/別FSは参照モード非対応（inline 固定）。同一WSは必要条件、最終判定は diff ハッシュ一致。
