# reviewer ペインのライフサイクル（自動生成・read-only 強制・グローバル導入）

[`../protocol.md`](../protocol.md)（索引）から分割された正典の一部。

**この文書で分かること**:

- ensure-reviewer（create-if-missing・冪等）の分類・生成・競合の直列化
- reviewer read-only 強制の正典（最終 argv の意味検証）と検証を通す 4 箇所
- サンドボックスと承認が別軸である理由（既定に両方を含める根拠）
- print-agents-snippet.sh --append-global の対象解決・排他ロック・終了コード

### reviewer ペインの自動生成（Phase1c: create-if-missing・冪等）

`transport.sh ensure-reviewer` は「同一WSに使える reviewer があれば採用、無ければ1枚だけ生成」する（冪等）。
マーケット導入ユーザーがスクリプトのパスを知らなくても、何も手実行せず reviewer が用意されることを狙う。
設計は 4 ラウンドのクロスレビューで収束。

- **矛盾検査が最優先（指摘3・2巡目）**: `_xrev_classify_reviewer`（分類・resolve＋probe）を呼ぶ**前**に
  `_xrev_guard_reviewer_conflicts` で reviewer 設定の矛盾を検査する（`exit 29`）。矛盾があるまま
  ペイン生成へ進み、生成後に別の理由（送信時の `exit 29` や起動確認の失敗）で気づく事故を避ける。
- **分類**: resolve＋probe で `present`/`absent`/`ambiguous`(16)/`non_terminal`(14)/`process_mismatch`(17) を判別。
  既存が**壊れ(14)/曖昧(16)/別物(17)**のときは**作り直さず人間へ**（誤って二重生成しない）。
- **生成は absent のときだけ**: caller の WS UUID を明示して `cmux new-pane --type terminal --workspace <WS>` で生成し、
  **new-pane が返した surface UUID を所有物に固定**（title は一意でないので生成判定に使わない）→
  `reviewer_launch_args`（read-only 強制。下記参照）を決定して各要素を shell-safe クォート →
  `send 'exec <quoted codex> <quoted launch args...>'` → read-screen probe 成功＋直下=codex で起動確認 →
  直下プロセスの実コマンドラインに launch 引数が含まれることを検証（`_verify_reviewer_launch_args`）→
  `rename-tab` で規約タイトル。launch 引数の決定失敗・起動未確認・実効未確認はいずれも `exit 19`。
- **競合の直列化**: WS UUID 鍵の `mkdir` ロック（${TMPDIR}/xrev-reviewer-<wsuuid>.lock・**リポジトリには作らない**）を
  原子取得。**ロックは回収しない**（stale 回収レースを構造的に排除）。取れない側は**奪わず** deadline まで
  read+codex 確認済みの present を待ち、期限切れは `exit 20`（残留ロックは案内に従い手動削除）。これで複数 primary
  同時実行でも「1枚だけ生成・他は採用」へ収束する。
- **モード**: `reviewer_autocreate` = `ask`(既定)/`auto`/`off`。`ask` はスキルが一拍確認で「作成しますか？」を確認して
  から `auto` 相当で呼ぶ（ペイン生成はレイアウトを変える副作用のため暴発させない）。`off` は生成せず案内のみ。
- 手動経路 `scripts/start-reviewer.sh`（既に開いた端末をその場で reviewer にする）とはタイトル・codex バイナリ解決を
  共有し、仕様の乖離を避ける。
- **タブ名は codex 起動の「後」に設定する（実機知見）**: codex は起動時にタブ名を cwd 由来の名前で上書きするため、
  起動前に rename しても定着しない。生成は「起動確認 → rename」の順にする。`rename-tab` も read/send 同様
  `--workspace <ws_uuid> --surface <surface_uuid>` 指定が要る（短縮 ref/uuid 単独は `Tab not found`）。これにより
  reviewer_pane_title が定着し、次回の title 解決が当たる（create-if-missing の冪等性を保つ）。

### reviewer read-only 強制（最終 argv の意味検証が正典）

SKILL.md は「reviewer = レビュー専用・read-only」と約束する。これを起動経路（`start-reviewer.sh` の
手動起動 / `_xrev_create_reviewer` の自動生成）と、既存ペインを「採用」する経路の**両方**で機械的に
強制する。設計はクロスレビューで収束。

**正典は「拒否リスト」ではなく「最終 argv の意味検証」である。** 拒否リスト（前方一致でフラグを
弾く方式）は、型として不正な値（空配列・危険値）を持つ config/env や、`-s`（codex の sandbox 短縮形）
のような未収録の表現・結合形式（`-sdanger-full-access`）による後置上書きを原理的に漏らす。そこで
`transport.sh` の純粋関数 `_xrev_verify_effective_policy <reviewer 種別> <argv...>` を単一の判定基盤とし、
「最終的に reviewer へ渡る argv 列」に対して**実効値**を合成してから合否を判定する。

- **認識する引数形式（codex）**: sandbox = `--sandbox <値>` / `--sandbox=<値>` / `-s <値>` /
  `-s<値>`（結合形式）。承認 = `--ask-for-approval <値>` / `--ask-for-approval=<値>` / `-a <値>` /
  `-a<値>`（結合形式）。
- **複数指定は理由を問わず拒否する**: sandbox・承認それぞれの指定は argv 全体を左から走査して集め、
  **ちょうど1回**だけ現れることを要求する。0回（指定なし）はもちろん、2回以上（例: 安全な組の
  直後に `-s danger-full-access` を後置する攻撃）も、**たとえ最後の値が安全でも拒否**する。
  「後勝ちで良しとする」寛容さは意図的に採らない — 同じ軸への複数指定それ自体が「意図が曖昧な
  argv」であり、fail closed の対象にする。
- **合格条件**: sandbox の実効値が `read-only`、かつ承認の実効値が `never` であること。加えて
  `--dangerously-bypass-approvals-and-sandbox` / `--full-auto` / `--yolo`（完全一致。前方一致では
  なく、リストは関数内の1箇所にまとめる）のいずれも含まれていないこと。claude は
  `--permission-mode <値>` / `--permission-mode=<値>` の実効値が一意に `plan` であることを要求し、
  短縮形を持たないため他の形式は「該当なし」として扱われ結果的に拒否される（fail closed）。
  未知の reviewer 種別も fail closed。
- **`_xrev_verify_effective_policy` を通す4箇所**:
  1. **launch 引数の決定直後**（`_xrev_reviewer_launch_args` 内）。config/env の型検証を通っても
     「安全なポリシーか」は別問題（空配列や `["--sandbox","danger-full-access"]` も型としては正しい）
     なので、決定した引数列そのものを意味検証にかけ、不合格なら非ゼロ（fail closed）にする。
  2. **`start-reviewer.sh` の最終 argv**（launch 引数 + ユーザー追加引数を連結した後の列全体）。
     これにより `-s` の短縮形・結合形式によるあらゆる後置上書きを検出する。
  3. **起動後、実際に走っているプロセスの argv**（`_verify_reviewer_launch_args`）。従来の
     「launch 引数が部分文字列として含まれるか」という判定は、launch 引数の**後ろ**に危険な
     引数が付いていても部分一致さえ満たせば通ってしまう欠陥があったため置き換えた。
     **argv の取得は `sysctl(KERN_PROCARGS2)` 経由（`_xrev_procargs2_snapshot`。指摘2への対処）**:
     以前は `ps -o pid=,args=` が返す表示用文字列を空白区切りで argv へ再分解していたが、この
     表示用文字列はシェルが見せるための整形済みテキストにすぎず argv の要素境界を保持しない。
     cmux が claude へ自動注入する `--settings <JSON>`（値の内部に空白を含む単一 argv 要素。
     probe-report.md R1 で実測）のような引数があると、その値の**内部**に現れた
     `--permission-mode plan` のような文字列を独立した実フラグと誤認しうる（安全ポリシーの
     誤判定に直結する high 指摘）。`sysctl(KERN_PROCARGS2)` はカーネルが保持する実 argv を
     境界保持のまま（python3 の ctypes で直接呼び出して）返すため、この誤認は構造的に起きない。
     macOS 専用の機構であり、取得できない場合（非 macOS・権限不足・パース不能）は当該 PID を
     結果から省略する＝そのプロセスは意味検証に到達せず、他に合格する候補が無ければ
     fail closed（`_xrev_create_reviewer` 経路は `exit 19`、`_xrev_classify_reviewer`/
     `_xrev_verify_reviewer_policy` 経路は `exit 27`）。
  4. **既存ペインを「採用」する経路の実効検証**（`_xrev_verify_reviewer_policy`。下記参照）。
     `xrev_transport_review` では不具合Bの対処により、この検証を送信序盤の1回だけでなく
     `_xrev_gate_reviewer` を介して全ての送信ゲート（早期棄却・本文送信直前・Enter直前・
     Enter再送前）で毎回行う（詳細は[宛先解決と送信ゲート](delivery-gates.md)の「送信前ゲート」）。
- **単一の生成関数（型検証）**: `transport.sh` の `_xrev_reviewer_launch_args <reviewer バイナリ名>` を
  両起動経路が共有する。優先順位は env `XREV_REVIEWER_LAUNCH_ARGS`（JSON 配列文字列）> config の
  `reviewer_launch_args[<basename>]`。型検証（object であること・キー存在・文字列のみの配列・
  印字可能ASCIIのみ・空文字列不可）に加えて上記の意味検証を通り、違反時・未知 reviewer 時は
  fail closed。出力は1行1要素（改行区切り）で、呼び出し側は `while read` で bash 配列へ集める
  （**eval は使わない**）。
- **拒否リストは早期棄却の best-effort（正典ではない）**: `_xrev_reject_unsafe_reviewer_args`
  （前方一致: `--sandbox` `-s` `--ask-for-approval` `--approval` `--full-auto` `--dangerously`
  `--permission-mode` `--yolo` `-a`）は分かりやすいエラーメッセージを即座に返すための早期ゲートに
  すぎない。`start-reviewer.sh` はユーザー追加引数をこれに通してから launch 引数の**後ろ**に連結する
  が、最終的な合否は必ず上記の意味検証（最終 argv 全体）で決まる。
- **起動後の実効検証**: 自動生成経路は起動確認（read-screen probe + プロセス証明）に加え、
  `_verify_reviewer_launch_args` で対象 surface の直下プロセスの実効ポリシーを確認してから採用する。
  確認できなければ `exit 19`（採用しない）。
- **既存ペインを「採用」する経路の実効検証（指摘3への対処）**: 従来は前景プロセス名が
  `reviewer_process`（既定 `codex`）と一致することしか見ておらず、手動起動・旧版の書き込み可能な
  ままの端末がそのまま present（採用）扱いになり得た。`_xrev_classify_reviewer` の present 判定
  （`_verify_reviewer_process` 成功後）と、`xrev_transport_review` の全送信ゲート（`_xrev_gate_reviewer`
  経由。不具合Bへの対処により1回だけでなく毎ゲート）の双方で `_xrev_verify_reviewer_policy` を通し、
  対象 surface の前景プロセスの argv を取得して意味検証にかける。不合格なら `_xrev_classify_reviewer`
  は `policy_mismatch` を返し `exit 27`、
  `xrev_ensure_reviewer` / `xrev_transport_review` の呼び出し側はこれを受けて「ペインを閉じて
  ensure-reviewer で作り直すか、start-reviewer.sh で起動し直してください」と案内して中止する。
  既定はこの検証を行う（fail closed）。`XREV_ALLOW_UNVERIFIED_REVIEWER=1`（明示 opt-in）のときだけ
  検証を省略し警告ログを出す — 手動で用意した reviewer を使う運用を完全に壊さないための後方互換。
- **サンドボックスと承認は別軸である（既定に両方を含める理由）**: codex の `--sandbox read-only` は
  「何ができるか」を縛るが、コマンド実行のたびに人間へ承認を求めるかどうかは `--ask-for-approval` が
  決める別の軸である。承認ポリシーを既定のままにすると、reviewer が `git diff` や `tests/run.sh` を
  実行しようとするたびに承認プロンプトで停止し、**人間の操作なしに往復させる**という xrev の目的が
  成立しない（応答が来ないまま `response_timeout_seconds` を使い切る）。とくに参照モードは reviewer 自身に
  diff 取得を行わせるため必ずこの経路を踏む。よって既定は `--sandbox read-only --ask-for-approval never`
  の**組**とする。`never` は「承認を求めず、実行失敗はモデルへ返す」の意味であり、サンドボックスは
  そのまま効いている（書き込み・ネットワークは read-only サンドボックスが禁じる）。承認プロンプトを
  外すことは権限の緩和ではなく、権限の強制を sandbox 側へ一本化することである。
  **片方だけを設定してはならない**: `--ask-for-approval never` を sandbox 指定なしで使うと、承認も
  サンドボックスも無い状態になる。この組を崩す変更は安全性の変更として扱うこと。
- **限界**: 同名の別バイナリへの差し替えや、codex/claude 自身の設定ファイル側での上書きまでは
  検出・保証しない（詳細は [`../../docs/security-design.md`](../../docs/security-design.md)）。

### print-agents-snippet.sh --append-global（D3・グローバル導入）

`scripts/print-agents-snippet.sh` は既定で stdout にスニペットを出すだけだが、`--append-global`
は codex のグローバル指示ファイル（`$CODEX_HOME/AGENTS.md`。`CODEX_HOME` 未設定なら既定
`~/.codex/AGENTS.md`）へスニペットを冪等に追記/更新する。R7 実測（`codex exec` を一時
`CODEX_HOME` で実行し確認済み）: codex は起動時にこのファイルを読み込む。

**対象解決**（lstat 基準・最初に該当した規則のみ）:

1. symlink（存否より先に判定）→ `realpath` 成功必須。失敗（リンク切れ）は無変更で fail closed
   （リンクを温存する。上書きしない）。
2. symlink でない既存通常ファイル → `realpath` 正規化。
3. 存在しない → 初回導入。`CODEX_HOME` ディレクトリ（存在必須。無ければ fail closed。`mkdir` は
   しない）を `realpath` 正規化し `basename "AGENTS.md"` を結合。
4. その他（ディレクトリ・FIFO 等）→ 無変更で fail closed。

**path は bash の command substitution を一度も通らない（指摘1・4巡目・正典）**: `--append-global`
の実処理（対象解決→ロック→マーカー検査→一時ファイル→mv直前再検証→mv）は**すべて単一の python
プロセス内**で行う。3巡目までの実装は対象解決の結果（kind・canonical path・`CODEX_HOME`）を JSON
で python→bash へ返し、bash 側が `resolved="$(...)"` のようなコマンド置換で受けてからフィールドを
再抽出していたが、コマンド置換は末尾の改行を無条件に取り除くため、`CODEX_HOME` や symlink 解決先が
**改行で終わる有効なパス**だと、そのフィールドを再抽出した時点で末尾の改行が失われ canonical
target が別パスに変化してしまい、誤配送防止が未達だった（タブや改行が"途中"にあるだけのケースは
JSON化で救えていたが、末尾の改行はどのみち再抽出の command substitution で失われるため検出でき
なかった）。ここでは path を運ぶ経路を「python プロセス内のローカル変数」に限定し、bash は
オプション解釈・スニペット本文の stdin 渡し・python の終了コードの伝播だけを担う。診断メッセージ・
成功メッセージも python が直接 stderr/stdout へ書く（bash での再組み立てをしない）。

対象解決 `_xrev_resolve_agents_target(home_dir)` と書き込み本体 `_xrev_write_agents_file(...)`
（下記）は transport.sh の `_xrev_*_py_src` 共有方式に倣い、python の関数定義だけを返す bash
関数（`_xrev_agents_resolve_py_src` / `_xrev_agents_write_py_src`）として実体を持つ。本番の結合
ドライバ（`_xrev_append_global`）はこの2つと専用の driver 片を1つの python プロセスへ結合して
実行し、テスト（下記）も同じ実体を共有する（判定ロジックの二重管理をしない）。単体で対象解決だけを
確認したいテスト向けに `_xrev_resolve_agents_target`（bash 関数。stdout に JSON を返す）を残して
いるが、**本番の `--append-global` 経路はこれを経由しない**。

**排他ロック**: 正規対象（realpath 後）の親ディレクトリに固定名 `.<basename>.xrev-lock`（`mkdir`
原子取得。`TMPDIR` 等の環境依存値はロックパスに含めない）。symlink 経由でも直接 realpath を指した
別実行でも、ロックは同じ正規対象の親ディレクトリに収束する。取得後に「再読取り→マーカー構造検査→
一時ファイル生成→パーミッション引き継ぎ(stat→chmod)→mv」を行う（すべて同一 python プロセス内。
TOCTOU 窓を最小化する）。ロック解放は python の `try`/`finally` で必ず行う（自己解放）。競合時は
**待機せず無変更で拒否**する（診断で再実行を案内）。

mv 直前に、正規対象の状態が「ロック内で読んだ時点（baseline）」から不変であることを確認する補助
検査を行う（ロックの代替ではない。非協調プロセス＝エディタ等による同時書き換え対策）。**比較対象は
種別（`lstat` による通常ファイルか否か）・識別情報（`st_dev`/`st_ino`）・パーミッション（mode）・
内容 sha256 のすべて**（指摘2・3巡目。旧実装は exists の真偽と内容 sha256 だけを比較しており、
非協調プロセスが対象を「同一バイト列の別ファイル」（通常ファイルを同内容の symlink に置換する、
またはエディタの atomic-save のように新しい inode の同内容ファイルへ差し替える）へ入れ替えても
見逃していた。`os.replace` は symlink を辿らずリンクそのものを置き換えるため、置換後にそこへ
書き込むのは意図しない対象の破壊になる。また mode だけの変更（内容は不変）も検出できず、
旧 baseline の mode で静かに上書きしていた）。上記いずれか1つでも変化していれば無変更で拒否する。

**書き込み本体はテスト用の hook を持つ純粋関数（指摘2・4巡目）**: `_xrev_write_agents_file(target,
begin, end, snippet, hook=None)` は一時ファイル書き出し・パーミッション引き継ぎの直後、mv 直前の
再検証の直前で `hook`（引数なしの callable。既定 `None`）を呼ぶ。**本番のドライバは常に
`hook=None` で呼び出し、この引数は一切使わない**。3巡目までの実装は
`XREV_TEST_AGENTS_WRITE_SYNC_DIR` という環境変数でテスト専用の同期（baseline 取得後に一時停止し、
外部から `chmod` を注入できるようにする）を行っていたが、**本番コードが無条件に信頼する env
フックは、利用者環境や上位エージェントから継承されるだけで「任意ディレクトリに `ready` ファイルを
作成・最大10秒停止」できる外部書込み能力になり、「未設定なら no-op」は安全境界にならない**と判定
され撤回した。代わりに、書き込みロジックを hook 引数を持つ python 関数として定義し、テストは
`_xrev_agents_write_py_src`（本番と共有する実体）にテスト専用の小さな driver を結合した自前の
python プロセスから `hook` へ直接 `chmod` を注入して駆動する（env 経由の到達経路を一切作らない。
transport.sh の `_xrev_*_py_src` 共有方式と同じ流儀）。symlink 置換・inode 差し替えは「毎回
新規 inode」という単調に一意な性質を利用した継続レースのままで確実に検出できる（決定論的な
hook 注入が要るのは mode のような小さな値集合の変化だけ）。

**マーカー**: `<!-- xrev:snippet:BEGIN -->` / `<!-- xrev:snippet:END -->` の対で挟む。0 対=末尾
追記 / 正確に1対（BEGIN が END より前）=範囲置換（マーカー内側のみ）/ それ以外（欠損・重複・
入れ子・逆順）=無変更で fail closed。BEGIN/END は常に独立行にする（**指摘2・2巡目**: 呼び出し側は
`body="$(_xrev_snippet_body)"` という command substitution でスニペット本文を受け取るため、bash が
本文末尾の改行を無条件に取り除く。writer 側でスニペット本文を必ず1個の末尾改行で終わるよう正規化
してから END マーカーを続けることで、生成ファイルでも本文最終行の直後に END が連結されず、
stdout モードと同じ「独立行のマーカーブロック」形式を保つ）。

**契約差（ensure-reviewer の WS ロックとの違い。重要）**: `transport.sh ensure-reviewer` の WS
ロックは「回収しない」（stale 回収レースを構造的に排除するため）ため競合側は deadline まで present
を待つ。本ロックは性質が異なる: 生成（cmux ペインという副作用の大きい対象）ではなく既存ファイルへの
短時間の書き込みであるため、**このプロセスが必ず自己解放し**、**競合したら待機せず即座に拒否する**
（待つ意味が薄く、待つより早く失敗させて再実行を促す方が診断しやすいため）。

**対象解決の I/O エラー（指摘1・2巡目）**: 対象パスの `lstat`／symlink 先の `stat`／`CODEX_HOME`
の存在確認は、`FileNotFoundError` だけを「未作成」として受理する。権限拒否や親経路が非ディレクトリ
であるといった、それ以外の `OSError` を「存在しない」と誤分類して初回導入(new)扱いにはしない
（fail-open の欠陥だった）。専用の `error` kind として無変更で拒否する（`exit 16`）。また symlink は
リンク先を実際に `stat`（シンボリックリンクを辿る）して通常ファイルであることまで確認し、
ディレクトリ等を指す symlink は canonical target にしない（`other` 扱いで拒否）。

**終了コード**（`print-agents-snippet.sh` 独自の名前空間。`transport.sh` の終了コードとは無関係）:
0=成功 / 10=dangling symlink（リンク温存） / 11=`CODEX_HOME` ディレクトリ不在（`mkdir` しない） /
12=対象が想定外の種類（symlink のリンク先がディレクトリ等の場合を含む） /
13=ロック競合（待機せず拒否） / 14=マーカー構造異常（欠損・重複・逆順） /
15=mv 直前の内容変化（無変更で拒否） / 16=対象解決中の I/O エラー（権限拒否等。指摘1・2巡目） /
1=その他の内部エラー。
