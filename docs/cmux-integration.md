# cmux 統合マップ — xrev が cmux の何を使い、どう実現しているか

xrev の通信層が **cmux のどの機能・どの実挙動に依存し、それぞれへどう対処しているか**を
1 枚で見渡すための対応マップ。対象読者は xrev の内部を理解したい開発者。

本書は橋渡し役であり、事実の一次情報は持たない:

- 実測記録（生データ・再現手順） → [cmux-behavior.md](cmux-behavior.md)
- 対処の仕様（正典） → [`../references/protocol.md`](../references/protocol.md)（索引）配下の各ファイル
- 図による解説（人間向け HTML。エージェント×cmux の対比・プロンプトの一生） → [cmux.html](cmux.html)

## xrev が使う cmux の機能

すべて `scripts/transport.sh` だけが呼ぶ（cmux 依存の局所化。[architecture.md](architecture.md) 設計原則 1）。

| cmux 機能 | xrev での用途 |
|-----------|---------------|
| ペイン内シェルへの環境変数注入（`CMUX_SURFACE_ID` / `CMUX_SOCKET_*`） | ソケット認証と「呼び出し元ペイン」の特定。primary を cmux ペイン内で起動する必須要件の根拠（[protocol/config.md](../references/protocol/config.md) 実行コンテキスト） |
| `ping`（制御ソケット疎通） | preflight 接続確認（失敗は `exit 31` で明示停止） |
| `tree --all --json --id-format both` | reviewer ペインの宛先解決（呼び出し元と同一ワークスペース内でタイトル一致する surface を選ぶ。[protocol/delivery-gates.md](../references/protocol/delivery-gates.md)） |
| `top --all --processes --format tsv` | 送信前のプロセス証明（対象 surface の直下プロセス PID の取得。判定自体は `ps` に委ねる） |
| `read-screen` | 端末性プリフライト（読めるか）と応答検出（reviewer の JSON をポーリングで拾う） |
| `send` | レビュー依頼本文（1 物理行の wire）の送信 |
| `send-key` | Enter（プロンプト確定）・backspace（入力欄クリア） |
| `new-pane --type terminal` | reviewer ペインの自動生成（`ensure-reviewer`。[protocol/reviewer-lifecycle.md](../references/protocol/reviewer-lifecycle.md)） |
| `rename-tab` | 生成した reviewer ペインへの規約タイトル付与（宛先解決の前提を作る） |

## cmux の実挙動 → xrev の対処

「公式ドキュメントに無く実測でしか分からない挙動」が設計前提になっている。左列の根拠は
[cmux-behavior.md](cmux-behavior.md)（節番号を付記）、右列の仕様は references/protocol/ 配下。

### 送信（payload を届ける）

| cmux の実挙動 | xrev の対処 |
|---------------|-------------|
| `cmux send` は引数中の `\n`/`\t` を実改行・実タブへ自動展開する（7 節） | 本文を「画面上は 1 物理行・意味上は複数行」へエンコードして送る（1 物理行エンコード・ADR-001。[protocol/message-format.md](../references/protocol/message-format.md)） |
| エスケープ展開は `\n` `\r` `\t` のみで、他のバックスラッシュ列は素通しする（7 節） | 本文の `\` を `<XREV-BS>`、タブを `<XREV-TAB>` へ退避し、wire 上の `\` が必ず xrev 生成の `\uXXXX` になる不変条件を作る（復号の一意性） |
| ソケット受信側の UTF-8 チャンク欠陥: 読み取り境界で分断された多バイト文字を含むチャンクが丸ごと消える（**未修正の cmux バグ**・4 節） | wire を ASCII に閉じる `XREV-ASCII-V1`（非 ASCII を `\uXXXX` 化。上流修正後の削除判断のため版名を付与。[protocol/message-format.md](../references/protocol/message-format.md)） |
| 送信先 Codex がビジー・入力欄に残留があると `cmux send` が非ゼロで失敗する | 送信前に入力欄をクリアし、失敗時は待って再試行（既定 5 回。[protocol/delivery-gates.md](../references/protocol/delivery-gates.md) 送信の堅牢化） |
| 生成直後ペインへの初回送信は `rc=0` でも部分到達しやすい（9 節） | 切り詰め検出で確定を止め、`round_state` を引き継いだ同一 ITER 再試行で吸収（ペインは作り直さない） |
| Codex TUI は長いペーストを `[Pasted Content N chars]` チップに畳む（6 節） | 表示文字数 N と送信長の一致で切り詰めを検出（reviewer=codex の完全性検証） |
| Claude Code TUI はチップに文字数を表示しない（8-1 節） | 文字数照合が成立しないため claude reviewer は参照モード専用（inline は無条件 `exit 28`。[protocol/reference-mode.md](../references/protocol/reference-mode.md)） |
| composer の一括消去可否は表示形態依存: チップは backspace 数回で消えるが、インライン表示は実質消せない。`ctrl+u` 等は無効（6 節・8-3 節） | 種別別のクリア方式（codex=ctrl-u+backspace / claude=生 `0x08` 一括送信）。最終ゲートで中止したペインは自動復旧せず「汚染扱いで閉じて開き直す」運用（[security-design.md](security-design.md)） |

### 宛先解決と誤配送防止

| cmux の実挙動 | xrev の対処 |
|---------------|-------------|
| ペインをタイトル名で直接宛先指定する手段が無い | `tree` の JSON を辿り、**呼び出し元と同一ワークスペース内**でタイトル一致する surface を動的解決（複数一致は `exit 16` で fail closed。[protocol/delivery-gates.md](../references/protocol/delivery-gates.md)） |
| 短縮 ref（`surface:N`）や UUID 単独指定は、別ワークスペース文脈で `Surface is not a terminal` になる | `read-screen`/`send`/`send-key` を常に `--workspace <ws_uuid> --surface <surface_uuid>` の組で指定 |
| エージェント統合パネル（`--type agent-session`）は PTY を持たず `read-screen` 不可 | 端末性プリフライト（read-screen probe）で送信前に弾く（`exit 14`）。reviewer は「実ターミナル内の CLI」に限定 |
| surface 直下プロセスは常に複数件（アプリ + sleep サイドカー + ログインシェル。1 節） | 「直下 1 件」を前提にせず、**前景プロセスグループ**（`pgid == tpgid`）でキー入力の受け手を特定（3 節→[protocol/delivery-gates.md](../references/protocol/delivery-gates.md) プロセス証明） |
| `cmux top` の name 列は実行ファイル名ではない（Claude Code がバージョン文字列で報告される。2 節） | プロセス同定は top の PID を `ps` へ渡して行う（name 列は使わない） |
| top と ps の取得時間差でサイドカー `sleep` が消滅し観測不一致になる（3 節） | 判定条件は緩めず、top+ps の取り直しを最大 3 回再試行（fail closed のまま可用性を回復） |

### reviewer ペインのライフサイクル

| cmux の実挙動 | xrev の対処 |
|---------------|-------------|
| codex は起動時にタブタイトルを cwd 由来の名前で上書きする | 自動生成は「起動確認 → rename」の順（起動前に rename しても定着しない。[protocol/reviewer-lifecycle.md](../references/protocol/reviewer-lifecycle.md)） |
| セッション復元は codex を cmux 自前の統合引数で再起動し、こちらが与えた read-only 引数が消える（10 節） | 毎送信ゲートで安全ポリシー（sandbox=read-only・承認=never）の実効を argv で再検証（`exit 27` で送信中止。TOCTOU 対策） |
| cmux の Claude Code 統合は argv 先頭に `--session-id` / `--settings <JSON>` を自動注入する（8-5 節） | argv の検証は `ps` の文字列再分割ではなく `sysctl(KERN_PROCARGS2)` で境界保持のまま取得して行う |
| codex のサンドボックスは cmux ソケット接続を遮断する（11 節。primary=codex のとき） | transport 系コマンドはサンドボックス外実行が必須（[setup-codex.md](setup-codex.md)・[`../references/codex-primary-playbook.md`](../references/codex-primary-playbook.md)） |

## バージョン揺れと診断

cmux の CLI コマンド名・JSON 形状・プロセスツリーの報告形状はバージョンで揺れる
（検証済みバージョンは [cmux-behavior.md](cmux-behavior.md) 冒頭に記載）。バージョンアップ後に
挙動がおかしくなったら、まず `scripts/transport.sh doctor` で外部ツールへの契約仮定を一括診断する
（非破壊・再実行可能。検査項目と限界は [protocol/doctor.md](../references/protocol/doctor.md)）。

なお `XREV-ASCII-V1` の根拠となった UTF-8 チャンク欠陥は上流へ報告済みで、修正の main マージ状況と
削除判断の手順は [roadmap.md](roadmap.md) の「将来の検討事項」に記録している。
