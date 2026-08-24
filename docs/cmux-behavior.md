# cmux の実挙動メモ（実測ベース）

xrev は通信層に cmux を使う。cmux には**公式ドキュメントに記載が無く、実測でしか分からない挙動**が
いくつかあり、それらは xrev の設計前提そのものになっている。ここを失うと同じ地雷を再度踏むので記録する。

**すべて実測。推測は「未確認」と明示する。** 検証環境は cmux 0.64.20 (100) [14e3400b9] / macOS 15.5 / zsh。
バージョンで揺れる可能性がある項目には、その旨を書いてある。

関連: [architecture.md](architecture.md) / [`../references/protocol.md`](../references/protocol.md) /
[security-design.md](security-design.md)

## 1. surface 直下プロセスは複数件になる（観測した全ペインで3件）

`cmux top --all --processes --format tsv` で得られる「surface の直下プロセス」は、
**この環境で観測した限り**、アプリが動いているペインでは `[アプリ, sleep, ログインシェル]` の3件だった
（surface:1〜5 の全ペインで同じ形状。直下が1件のペインは1つも無かった）。
単一環境・単一バージョンでの観測なので「常にそうなる」とまでは言えないが、
**「直下が1件になる」ことを前提にしてはいけない**のは確実である。

```
surface:3   4728    codex       ← reviewer アプリ
surface:3   13900   sleep       ← PID が毎回変わる周期プロセス
surface:3   1489    zsh         ← ペインのログインシェル（常駐）
```

- `sleep` は nice 付きのサイドカー zsh が周期実行しており、PID が毎回変わる。
- `cmux top` は `sleep` を**実 PPID ではなく surface 直下**として報告する（再親付け）。
  一方 `codex` の実 PPID はログインシェル（1489）そのもので、再親付けされていない。
- ペインで `exec codex` してもログインシェルが置き換わるだけで、サイドカー zsh と `sleep` は残る。
  **直下1件は達成できない。**

**この前提が xrev を壊した実績がある。** 旧実装のプロセス証明は「直下が厳密に1件かつ `codex`」を
要求していたため、全ペインを `exit 17` で拒否し往復が1ラウンドも開始できなかった。
現在は件数ではなく**前景プロセスグループ**で判定する（次項）。

> **未確認**: この3件構成がいつから始まったか。docs/architecture.md には「検証時 cmux 0.64.15」とあり、
> 当時は実機で1往復が成功している（コミット f708cec、2026-06-23）。現在の 0.64.20 バイナリの更新日は
> その約1か月後。ただし**当時のプロセス構成を直接記録した資料は無い**ため、バージョン間の変化以外にも
> 起動方法・環境差・xrev 側の経路の違いなど複数の説明が残る。どれが正しいかは特定できていない。

## 2. `cmux top` の name 列は実行ファイル名ではない

Claude Code は `2.1.220` のような**バージョン文字列**で報告される。cmux 独自の命名であり、
プロセス同定には使えない。

TSV の列は `cpu, mem, count, kind, id, parent, name` で、**5列目が PID**。
同定が必要なら PID を `ps` に渡すこと。

## 3. 前景プロセスグループで「入力先が shell か」を判定する

surface の直下プロセスは同一 tty を共有する。`pgid == tpgid`（`ps` の `+` フラグ）を満たすものが
実際にキー入力を受け取るので、「入力先が shell ではないこと」を判定できる。

観測した全ペインでは該当が**1件**だったが、これは一般には保証されない。パイプラインなど
複数プロセスが同じフォアグラウンドプロセスグループに属する構成では複数件になりうる。
そのため xrev は「ちょうど1件でなければ拒否」する（fail closed）。codex が子プロセスへ端末を
譲渡している間は0件になり、これも拒否される（可用性より安全を優先した意図的な制約）。

| surface | PID | name | STAT | pgid | tpgid |
|---|---|---|---|---|---|
| surface:3 | 4728 | codex | **S+** | 4728 | 4728 |
| surface:3 | 13900 | sleep | SN | 4726 | 4728 |
| surface:3 | 1489 | zsh | S | 1489 | 4728 |
| surface:2 | 12028 | zsh | **S+** | 12028 | 12028 |

素のシェルペイン（surface:2）では shell が前景として検出されるので、正しく拒否できる。

### `ps` 側の落とし穴（cmux 非依存だが同じ経路で踏む）

- `ps -p <生存> -p <消滅>` は**残りを出して exit 0** を返す。要求 PID と結果 PID の
  過不足なき一致を検証しないと、欠落したスナップショットを完全な観測と誤認する。
- `ps -o comm=` は**絶対パス**を返す（`/Users/x/.local/bin/codex`）。素朴な完全一致は必ず外れる。
- ログインシェルの `comm` は `-/bin/zsh`。shell の `basename` は先頭ハイフンを
  `illegal option -- /` で拒否するので、python3 の `os.path.basename` を使う。

### 過渡プロセス（sleep サイドカー）の消滅による観測不一致（別環境で実測）

surface 直下の `sleep` サイドカーは周期的に生成・消滅する（1. 参照）。`cmux top` で直下 PID
集合を取得したあとに `ps` を取るまでの間（ミリ秒オーダー）に、その時点で存在していた `sleep`
が消滅すると、`ps` は残りの PID だけを返して exit 0 になる。上記の「`ps` は残りを出して exit 0」
特性と組み合わさり、`_decide_foreground_owner` は「ps の観測が直下プロセスと一致しません
（欠落=[PID]）」で拒否する。判定自体は誤っていない（欠落したスナップショットを完全な観測と
誤認しない、という設計どおりの fail closed）が、犯人はプロセスの異常ではなく top/ps 間の
時間差そのものなので、そのまま拒否し続けると可用性を大きく損なう。

別環境の実測では 20 回中 2 回（約10%）この不一致で失敗し、送信経路は1往復あたり3箇所で
検証するため約27%/ラウンドが `transport_error` になった。対処は `_verify_reviewer_process`
内で **top と ps を最初から取り直して最大3回まで再試行**すること（判定条件自体は一切緩めない。
部分一致や欠落の許容は採らない）。

検証環境（cmux 0.64.20 / macOS 25.5.0）では同条件を50回試行しても未再現だった。環境・
タイミングに強く依存する事象であり、「自分の環境で起きないから存在しない」と判断しないこと。

## 4. ソケット受信の UTF-8 チャンク欠陥（**未修正の cmux バグ**）

受信側 `ControlClientLineReader` は最大 4095 バイト（`buffer.count - 1`、既定バッファ 4096）ずつ
`read(2)` し、**各チャンクを独立に UTF-8 変換して、変換に失敗したチャンクを丸ごと捨てる**。

```swift
// Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Server/ControlClientLineReader.swift
// commit 14e3400b95daedd652d0b6f395d0777c41e39eef（インストール版のビルドハッシュ 14e3400b9 と一致）
// 該当箇所は L13-16（コメント）/ L56-64（バッファ長）/ L140-151（変換と破棄）
let chunk = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
pendingBytes.append(contentsOf: chunk.utf8)
```

`?? ""` で空文字になったものの UTF-8 を `pendingBytes` へ追加するため、元の生バイト列は失われる。
ソース自身のコメントにも「invalid UTF-8 のチャンクは丸ごと捨てる」と明記されている。

Unix domain socket の `read(2)` は write 境界を保存しないため、多バイト文字が読み取り境界で
分断されると最大 4095 バイトが消える。先頭チャンクが消えると残った断片が行頭になり、
V1 コマンドとして解釈されて `ERROR: Unknown command '<断片>'` になる。

### xrev を介さない最小再現（cmux 標準機能で再現する）

`cmux notify --body` は**文書化された標準機能**で、長さ制限も文字集合の制限も記載されていない。
これが同じエラーで失敗する。**xrev 固有の使い方の問題ではない。**

```bash
WS=<任意の workspace UUID>
cmux notify --workspace "$WS" --title t \
  --body "$(python3 -c 'import sys;sys.stdout.write("あ"*12000)')"   # 36000 バイト
```

実測: 日本語 12000文字（36000バイト）で 5回中3回失敗、
同じ 36000 バイトの ASCII では 2回中0回失敗。エラーは
`ERROR: Unknown command 'あああ…'` で `cmux send` のときと同一。

cmux 側で同じ経路を通る機能は他にもある（`browser eval` / `browser fill` /
`browser addscript` / `notify_target` / `hooks feed` など。いずれも任意長の本文を
同じ制御ソケットへ載せる）。一方 `cmux diff` はパッチ本文をローカルの
サイドカーファイルへ保存し、ソケットには viewer URL とメタデータしか送らないため該当しない。

### 再現手順（xrev の送信経路で再現する場合）

**宛先は使い捨てペインにすること。** 成功すると composer に残骸が残り、インライン表示だと
実質消せない（項目6）。`scripts/transport.sh resolve` は運用中の reviewer を返すので**使わない**。
`cmux tree --all --id-format both` で使い捨てペインの workspace/surface UUID を確認するか、
`cmux new-pane --type terminal --workspace <ws>` で作って、実験後に閉じる。

```bash
WS=<使い捨てペインの workspace UUID>
SF=<使い捨てペインの surface UUID>

# 入力生成（日本語 12000 文字 = 36000 バイト）。対照は "x"*N の ASCII
python3 -c 'import sys;sys.stdout.write("あ"*12000)' > /tmp/repro.txt

# 送信。判定は cmux send の終了コード（0=成功 / 非0=失敗）
cmux send --workspace "$WS" --surface "$SF" "$(cat /tmp/repro.txt)"; echo "rc=$?"
```

失敗時の stderr は `ERROR: Unknown command '<断片>'` か `Error: Command timed out` のいずれか。
試行間隔は 1 秒。**成功した試行の後は** `cmux send-key --workspace "$WS" --surface "$SF" backspace`
を数回送って composer を空にしてから次へ進む（残骸があると次の試行の観測が汚れる）。
使い捨てペインは実験終了後に閉じる。

実測（各条件5回・同一セッション内で順に実行）:

| 条件 | UTF-8 バイト | 失敗 |
|---|---|---|
| ASCII 100000文字 | 100000 | 0/5 |
| ASCII 30000文字 | 30000 | 0/5 |
| 日本語 10000文字 | 30000 | 3/5 |
| 日本語 12000文字 | 36000 | 5/5 |
| 実 payload そのまま | 43149 | 3/5 |
| 実 payload を `\uXXXX` で ASCII 化 | **62466** | **0/5** |

**ASCII 化した方が 1.45 倍大きいのに 5/5 成功した。単純な長さ（文字数・バイト数）上限という説明は
これで否定される。**観測した範囲では非ASCIIの有無が成否を分けたが、他のサイズ依存要因が
一切無いことまでは示していない。
同一入力でも成否が変わる（read 境界がスケジューリング依存のため）ので、
**1回の試行で成否を判定してはいけない**。

- v1 `send` と v2 `rpc surface.send_text` は**同一のエラーで失敗する**。共通の受信層の問題なので、
  RPC への切り替えでは回避できない。
- 失敗した送信は composer に残骸を残さない（コマンド全体が拒否される）。
- 小さい送信（数文字）は観測した範囲では失敗しなかった。大きい送信が失敗しても後続を汚染しない
  （失敗直後の小送信が成功することを確認済み）。

xrev 側の回避策は wire を ASCII に閉じること（`XREV-ASCII-V1`）。仕様は
[`../references/protocol/message-format.md`](../references/protocol/message-format.md)。**上流が修正されたら削除可否を判断する。**

> **提案（実測ではない）**: 上流の修正方向は「各チャンクを独立に decode せず、raw bytes のまま
> 行終端まで蓄積し、完成した1行を一度だけ UTF-8 decode する」。完成行自体が不正 UTF-8 なら
> 空行化ではなく明示的に拒否する方が安全。未報告。

## 5. ソケットのコマンドプロトコル

v1 は**空白区切りの1行テキストコマンド**。バイナリに Usage が残っている。

```
ERROR: Usage: notify_target_async <workspace_uuid> <surface_uuid> <title>|<subtitle>|<body>
```

v1 の語彙: `ping send send_key send_surface send_workspace list_windows current_window
list_workspaces list_surfaces read_screen notify notify_surface notify_target set_status …`
v2 はドット区切りのメソッド（`surface.send_text` 等）で、`cmux rpc <method> [json-params]` から直接叩ける。
`cmux capabilities` でメソッド一覧が取れる。

`ERROR: Unknown command '<x>'. Use 'help' for available commands.` は**アプリ側（サーバ）**が
生成する。CLI 側の未知コマンドは別の文言で `Run 'cmux --help'` を付ける。
CLI の応答タイムアウトは既定15秒（`CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC` で変更可）。

## 6. Codex composer の入力制御

| キー | 効果 |
|---|---|
| `ctrl+u` / `ctrl+a` / `ctrl+k` / `ctrl+w` | **効かない**（0文字） |
| `escape` | 1文字だけ減る |
| `backspace` | 効く（1回1文字） |

`cmux send-key` は `OK surface:N workspace:M` を返すのでキー自体は届いている（backspace が効くことで実証）。
キー名は `ctrl-u` / `ctrl+u` のどちらの表記でも受理される。

**消去の可否は表示形態に依存する。**

- **ペーストチップ**（`[Pasted Content N chars]`）→ `backspace` 1〜2回で消える。
  96万文字の残骸も即座に消えた。
- **インライン表示の生テキスト** → 1文字ずつしか消せず、数万文字の残骸は実質消せない。

このため xrev は「送信済み本文が入力行に残った状態」を自動復旧できない。
最終ゲートで中止したペインは汚染扱いとし、閉じて開き直す運用にしている
（[security-design.md](security-design.md)）。

## 7. `cmux send` のエスケープ仕様

展開されるのは **`\n` / `\r` → Enter、`\t` → Tab** のみ。
それ以外のバックスラッシュ列はそのまま届く（`AあB\x41C` を送ると `AあB\x41C` が表示される）。

xrev の `_build_framed_line` が `\` を `<XREV-BS>`、TAB を `<XREV-TAB>` へトークン化しているのはこのため。
この退避によって「ASCII 化の直前にバックスラッシュが 0 個」という不変条件が成立し、
wire 上の `\` が必ず xrev 由来の `\uXXXX` になるので復号が一意に定まる。

## 8. Claude Code（claude reviewer）の実挙動（主従反転プリセット向け実測）

xrev の主従反転プリセット（primary=codex / reviewer=claude）では、reviewer ペインで
`claude --permission-mode plan` が動く。cmux は Codex 向けだけでなく Claude Code 向けにも
固有の挙動を持ち、上記 1〜7 と同様に実測でしか分からない。**実測日 2026-07-27。
検証環境 cmux 0.64.20 (100) [14e3400b9] / macOS 25.5.0 / zsh**（詳細な手順・生の観測値は
実測レポートに基づく。以下は要点の転記）。

### 8-1. ペーストチップは連番表示のみで文字数を持たない

Codex の `[Pasted Content N chars]` と異なり、Claude Code は長い貼り付けを
**`[Pasted text #N]`**（N はセッション内の貼り付けイベント連番。貼り付け文字数とは無関係）に
畳む。「paste again to expand」という展開ヒントが付くのみで、**文字数は一切表示されない**。
このため Codex と同じ「表示文字数と送信長の一致」による切り詰め検出は claude では成立しない
（`references/protocol/message-format.md` の C2 が inline 向けの全文一致照合を検討した根拠。ただし全文一致照合は
「空白の削除と挿入が相殺すれば比較・frame 検証のどちらもすり抜ける」という2巡目クロスレビューの
指摘で完全性証明にならないと判断され撤去済み。詳細・経緯は `references/protocol/message-format.md` の
「切り詰め検出」。claude reviewer は現在、参照モード専用— inline は無条件で送信前拒否）。

### 8-2. チップ化は文字数に対して非単調に畳まる

900/950 文字ではチップが出現するが、10,000/60,000 文字ではチップが出ない（60,000 文字は
チップ0個・末尾のみ可視）という**非単調な挙動**を実測した（500/800 文字は全文可視・チップなし）。
「文字数の単純な閾値」では説明できず、cmux 側のペイン書き込みチャンクサイズと Claude Code 側の
ペースト検出ヒューリスティックの組み合わせで決まると推測されるが、確定的な閾値は特定できていない
（本ファイルの「調査するときの注意」1 と同じ教訓 — 二分探索的な閾値特定は誤った境界を返す）。

### 8-3. composer クリア: ctrl-u 系は無効、生の 0x08 バイト一括送信が実用的

`ctrl+u` / `ctrl+a` / `ctrl+k` / `ctrl+w` / `escape` はいずれも効かない（実測 0 文字。Codex の
`escape` は1文字減るが claude の plan mode では反応しなかった）。`backspace` は1回1文字で効くが、
`send-key` のループでのクリアは低速（1回 ~200ms のラウンドトリップがあり、数千回のループは
現実的な時間で終わらない）。**生の `0x08`（バックスペース）バイトを1回の `cmux send` にまとめて
送る方式**が実用的な代替になる（60,000 文字級の残骸を数回の一括送信でクリアできた）。`ctrl+c` の
2連続送信は小さい残骸には有効だが、チップを含む大きい残骸には非決定的に失敗する。

### 8-4. タブタイトルは起動時に上書きされない（Codex と逆）

Codex は起動時に cwd 由来の名前でタブタイトルを上書きするため `_xrev_create_reviewer` は
「起動確認 → rename」の順にしているが、Claude Code は**起動後 15 秒観測してもタイトルを
上書きしない**（Codex と逆の挙動）。ただし cmux の Claude Code 統合には非同期フック
（`cmux hooks claude auto-name`。`args` に `"timeout":120,"async":true` が見える）が仕込まれており、
**長時間経過後に会話内容から自動でタブ名が変わる可能性は未検証**（15 秒では発火していない）。

### 8-5. cmux は `--session-id` / `--settings <JSON>` を自動注入する

cmux の Claude Code 統合は、reviewer 起動時の argv 先頭に `--session-id <uuid>` と
`--settings <JSON>`（cmux のフック設定を埋め込んだ JSON 文字列。1個の argv 要素として渡る）を
自動的に注入する。`--permission-mode plan` はその後ろに付くが、argv 全体を走査して
`--permission-mode` トークンを探す既存の検証ロジックはこれに影響されず成立する。**ただし
`--settings` の JSON 値自体に空白を含む語が来るため、argv を素朴に空白区切りで再分割する実装は
誤動作する**（`ps -o args=` の生文字列に対する部分一致検索であれば影響を受けない）。

【実装への反映（後日の指摘対応）】この実測知見は当初「`ps -o args=` の生文字列に対する部分一致
検索なら影響を受けない」という留保付きで採用されたが、後のクロスレビューで「値の内部に
`--permission-mode plan` という文字列が来ると、部分一致検索でも独立フラグと誤認しうる」という
high 指摘を受けた。最終的な実装は部分一致検索ではなく、`sysctl(KERN_PROCARGS2)` でカーネルが
保持する実 argv を境界保持のまま取得する方式（`_xrev_procargs2_snapshot`）を採用している。

【2巡目の指摘（境界の再喪失）】上記で argv 自体は境界保持のまま取得できるようになったが、
取得した argv を「PID受領 → argv取得 → 安全ポリシー判定」の間で改行区切りの文字列へ変換して
bash へ戻す実装が残っていたため、argv 要素自体に生の改行を含む場合（値の内部に
`--permission-mode\nplan` のような文字列が来た場合）に、bash 側の `while read` がこれを2要素へ
再分割し、実在しない安全フラグとして誤認しうる同種の high 指摘を再び受けた。最終的には
「PID受領 → KERN_PROCARGS2 での argv 取得 → 安全ポリシー判定」までを単一の python プロセス内で
完結させ、argv を区切り文字ベースの形で bash に戻さない構成（`_xrev_verify_foreground_policy` /
`_verify_reviewer_launch_args`）へ変更した。
詳細は [`../references/protocol/reviewer-lifecycle.md`](../references/protocol/reviewer-lifecycle.md) の「reviewer read-only 強制」節。

### 8-6. 応答画面の de-wrap 互換性

Claude Code の応答表示（2 スペースの字下げガター、応答冒頭の `⏺ ` インジケータ、折り返し）は
`_scan_review_blocks` の de-wrap ロジックでそのまま復元できた（追加のパーサ変更は不要）。ただし
`_scan_review_blocks` はセンチネル内外を問わず画面上の妥当 JSON を数える実装のため、reviewer への
依頼文中にセンチネルで挟んだ体裁の**例示 JSON をそのまま書くと誤検出されうる**（実測で1回
再現。`references/codex-primary-playbook.md` の注意はこの実測が根拠）。

## 9. 生成直後ペインへの初回送信は部分到達しやすい（`cmux send` rc=0 でも欠落）

`ensure-reviewer` で**生成した直後のペインへの初回送信**は、`cmux send` が rc=0 を返しても本文が
部分的にしか composer に届かない・または送信自体が失敗する事象が高頻度で起きる。既知の UTF-8
チャンク欠陥（4節）とは別の事象（wire は ASCII のみでも発生）。原因は未特定（cmux 側の欠落か
TUI 起動直後の取りこぼしかは切り分けていない）。

実測（いずれも cmux 0.64.20）:

- 2026-07-26: 5 往復中、初回送信の部分到達が 4 回（例: 9693 文字送信 → 画面は
  `[Pasted Content 4317 chars]`）。同じ payload の再試行では 4 回とも成功。
- 2026-07-27: 生成直後ペインへの初回送信が `truncated`(exit 13) → 再試行が `send_failed`(exit 11)
  → 3 回目で成功。別ラウンドでも初回 `send_failed` → 再試行で成功。

**運用**: 切り詰め検出が欠けた依頼の確定を正しく防いでいるので、`transport_error`
（`truncated`/`send_failed`）が出たら `round_state` を引き継いで**同一 ITER をそのまま再試行**する
（SKILL.md 5章）。ペインの作り直しや設定変更はしない。

**改善候補（未実装・実装前に要実測）**: ensure-reviewer の起動確認直後に短い捨て送信を 1 回挟んで
初回失敗を吸収する / 初回送信のみ settle を延長する。roadmap の将来の検討事項に記載。

## 10. セッション復元は codex を cmux 自前の引数で再起動する（read-only 引数が消える）

2026-07-27 実測（cmux 0.64.20）。ensure-reviewer が `exec codex --sandbox read-only
--ask-for-approval never` で起動した reviewer ペインが、cmux のセッション復元（ペインの
ログインシェルごと再生成。surface UUID は維持される）を経ると、**cmux が自前の統合引数で codex を
再起動し、こちらが与えた launch 引数は引き継がれない**。KERN_PROCARGS2 で採取した再起動後の実 argv:

```
/Users/naokami/.local/bin/codex --enable hooks --dangerously-bypass-hook-trust
  -c hooks.SessionStart=[{...cmux-codex-hook-session-start.sh...}] （以下 cmux の hook 注入が続く）
```

`--sandbox` / `--ask-for-approval` は**一切含まれない** = 復元後の reviewer は read-only の保証を
失っている。このとき送信ゲートの安全ポリシー実効検証が `exit 27`（sandbox 指定 0 件）で送信を
中止することを実機で確認した（毎送信ゲートで再検証する TOCTOU 対策が、まさにこの「静かな挿げ替え」を
捕捉した実例。タイトル・surface UUID・前景プロセス名 codex はすべて一致したまま安全性だけが落ちる）。

**運用**: cmux の再起動・セッション復元後は reviewer ペインをそのまま使わない。exit 27 が出たら
ペインを閉じて `transport.sh ensure-reviewer` で作り直す（ゲートの診断もこの復旧手順を案内する）。
CLAUDE.md の「セッション復元が前作業を復元しないよう注意」は、履歴の混入だけでなく
**安全ポリシーの喪失**も含む実害として裏付けられた。

## 11. codex のサンドボックスは cmux ソケット接続を遮断する（primary=codex の必須知見）

2026-07-27 実測（codex 主の実運用初回試行）。codex は自分が実行するシェルコマンドを macOS の
サンドボックス（seatbelt）内で走らせるため、**cmux ペイン内で CMUX_* が 29 件注入されている状態
でも、サンドボックス内からの `transport.sh ping` は接続失敗（exit 31）になる**。同じコマンドを
サンドボックス外実行（エスカレーション承認）すると成功する（同一ペイン・同一 env で確認）。

- claude 主で問題が出ないのは、Claude Code が Bash コマンドをこの種のサンドボックスなしで実行するため。
- 「primary は cmux ペイン内で起動」という従来の必須前提は codex 主には**不十分**で、
  「transport 系コマンドはサンドボックス外実行」が追加で必要になる。
- あわせて codex の実行モデルの差: シェルがコマンドごとに新規のため `export` が持ち越されない
  （環境変数は毎コマンド前置が必要）。
- 運用は codex-primary-playbook.md 2 章とグローバル導入スニペットに反映済み。

## 調査するときの注意

1. **1回の試行で成否を判定しない。** 4 の欠陥は非決定的で、単調性を仮定した二分探索は誤った境界を返す。
   実際にこの調査では「32KiB のバイト数上限」「境界は3882文字目」という誤った結論を2度出している。
   各条件20回、確認は30回以上、失敗率と信頼区間で比較すること。
   **上表は各5回しかない**ので、傾向を示すには足りるが失敗率の推定としては粗い。
   再検証するならこの回数から増やすこと。0/5 は「失敗率0」ではなく「未観測」と読む。
2. **成功する送信は残骸を残す。** 実験は失敗が予想される側から攻めるか、使い捨てペインを使い、
   成功したペインは即座に閉じて再利用しない。
3. **静的調査を先にやる。** バイナリの文字列（`strings`）、`cmux capabilities`、`cmux docs api`、
   公開ソース（<https://github.com/manaflow-ai/cmux>）で機構を絞れれば、実機実験の回数を減らせる。
