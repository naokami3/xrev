# 終了コード設計

[`../protocol.md`](../protocol.md)（索引）から分割された正典の一部。

**この文書で分かること**:

- review-loop の decision 6 種と exit code の対応（分岐は stdout JSON の decision で行う）
- transport_reason の安定文字列一覧
- round_state 安全弁の契約（渡し忘れ・巻き戻しは escalate）
- parse-review（0/1）と transport（10〜31）の内部終了コードの意味

## 4. 終了コード設計

### `scripts/review-loop.sh`

**分岐は必ず stdout の JSON の `decision` で行う**（exit code ではない）。exit code は
「レビューを綺麗に完了できたか」だけを表す。これにより「`continue` は正常なのに非ゼロで
エラー扱いされる」誤判定（非ゼロを一律エラーとみなす Bash 呼び出し等）を避ける。

| decision          | exit | 意味 |
|-------------------|------|------|
| `converged`       | 0    | blocker 0 件。収束。 |
| `continue`        | 0    | blocker 残・上限未満。primary が修正して `ITER+1` で再実行（正常系）。 |
| `reference_unverified` | 0 | 参照モードで reviewer の diff_hash が期待値と不一致/未取得。レビューを採用せず、primary が同一 ITER で再試行（正常系）。**回復手段は reviewer 種別依存**（codex=inline へ切替 / claude=参照モードのまま再試行。状態機械自体は種別非依存。詳細は[参照モード](reference-mode.md)）。通算が `max_reference_fallbacks` 超で `escalate`。 |
| `escalate`        | 0    | 上限到達でも blocker 残。人間へエスカレーション（レビューは完了）。 |
| `invalid`         | 21   | reviewer 出力が契約違反（スキーマ不一致 / 壊れた JSON / transport `exit 24`）→ レビュー取得できず。 |
| `transport_error` | 22   | 送受信失敗（ペイン解決不可・タイムアウト等）→ レビュー取得できず。 |

`transport_error` の決定 JSON には `transport_exit_code`（transport の生終了コード）と `transport_reason`
（安定文字列）を含める。外部 exit は 22 のままだが、primary はこの reason で利用者向け修正案を機械的に選べる:
`cmux_unavailable`/`resolve_failed`/`send_failed`/`timeout`/`truncated`/`non_terminal`/`ws_mismatch`/
`ambiguous`/`process_mismatch`/`reviewer_policy_mismatch`/`autocreate_failed`/`reviewer_contention`/
`encode_failed`/`payload_too_large`/`submit_failed`/`cmux_not_found`/`not_in_pane`/`integrity_unverifiable`/
`reviewer_config_conflict`（D1。新設 `exit 29`）。

`transport_exit_code=24`（`invalid_response`。センチネルで完成した応答はあるが妥当な review JSON
を含まない契約違反。`timeout` と区別され primary は再出力を促す）は `transport_error` ではなく
`decision=invalid` に写像される特例。`transport_reason` は従来どおり `decision=transport_error`
のときだけ埋まる（`decision=invalid` では `null`）が、`transport_exit_code` 自体は透明性のため
`decision=invalid` でも決定 JSON に残る（`=24`）。

**ループ安全弁（round_state・Phase1b）**: review-loop は決定 JSON に `round_state`
（`{iter, transport_attempts, reference_fallbacks}`。`reference_fallbacks` は Phase2 で追加）
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
| 27   | reviewer が安全ポリシー（sandbox=read-only かつ承認=never）で起動していない（最終 argv の意味検証に不合格。reviewer_policy_mismatch）。`xrev_transport_review` では各送信ゲート（早期棄却・本文送信直前・Enter直前・Enter再送前）でプロセス証明と同じゲートで毎回再検証される（不具合Bへの対処。TOCTOU防止）。`XREV_ALLOW_UNVERIFIED_REVIEWER=1` で opt-out 可（[reviewer ペインのライフサイクル](reviewer-lifecycle.md)の「reviewer read-only 強制」参照） |
| 28   | reviewer 種別（semantic kind。D1: 解決済み `reviewer` 名。旧来は `reviewer_process` の basename だったが置き換わった）に応じた送信完全性の検証手段が確立できない（integrity_unverifiable）。codex/claude 以外の未知種別、または claude・inline（claude は参照モード専用のため inline は wire 長に関わらず無条件）。claude は参照モード（`XREV_REFERENCE_MODE=1`）を使うこと（参照モードはこの検査自体をスキップする）。いずれも cmux へは一切送信していない |
| 29   | reviewer 設定に矛盾がある（reviewer_config_conflict。D1）。`reviewer_process` の明示値の basename が `codex`/`claude` のどちらかで解決済み `reviewer` と異なる、または `reviewer=claude` で `reviewer_reads_workspace` が明示 `false`。`xrev_transport_review`（resolve すら試みず送信前に拒否）・`xrev_ensure_reviewer`（`_xrev_classify_reviewer` を呼ぶ前）・`start-reviewer.sh`（タイトル変更・exec の前）の3経路すべてで、副作用の前に共有ゲート `_xrev_guard_reviewer_conflicts` により一貫して返る（指摘3・2巡目）。詳細は[設定](config.md)の「reviewer の auto 解決と semantic kind」節 |
| 30   | cmux CLI が見つからない |
| 31   | cmux 接続不可（preflight 失敗・ペイン外実行） |
