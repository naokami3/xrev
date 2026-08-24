# 宛先解決と送信ゲート

[`../protocol.md`](../protocol.md)（索引）から分割された正典の一部。

**この文書で分かること**:

- 宛先解決の順序（明示指定 → 同一 WS スコープ → グローバル opt-in）と曖昧時の fail closed
- 送信前ゲート 3 点検査（UUID 再検証・端末性・プロセス証明＋安全ポリシー）と TOCTOU の残余
- read-screen/send/send-key を workspace+surface UUID の組で指定する理由
- 送信の堅牢化（入力欄クリア + 再試行）と reviewer 種別ごとのクリア方式

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
   [`../../docs/security-design.md`](../../docs/security-design.md) を参照。

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

> **参照モード（diff 本文を送らずファイル参照を渡す方式）は[参照モード（Phase2）](reference-mode.md)**を参照。
> Phase1 の宛先解決＋送信ゲートが前提（同一WS解決時のみ参照モードを許可）。

### 送信の堅牢化（実機知見）

送信先が Codex のとき、**ビジー（前応答の処理中）や入力欄の残留（テキスト/ペーストチップ）**が
あると `cmux send` が非ゼロで失敗する（`cmux send` 自体の長さ上限ではない。プレーンシェルへは
長文も成功する）。そのため `_cmux_send_line` は **送信前に入力欄をクリアし、失敗時は待って再試行**
する（既定 5 回・`XREV_SEND_RETRIES`）。残留が混入したまま送ると prompt が壊れるため、クリアと、
応答検出側の切り詰め検出で二重に守る。

**入力欄クリアも reviewer 種別で分岐する（C2）**: codex は ctrl-u（行クリア）と backspace（ペースト
チップ削除）が有効。claude は ctrl-u/ctrl-a/ctrl-k/ctrl-w/escape がいずれも無効（実測）なため、
生の `0x08`（バックスペース）バイトを1回の `cmux send` へまとめて送る方式を使う。
