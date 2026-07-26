#!/usr/bin/env bash
#
# print-agents-snippet.sh — 導入スニペット出力・codex グローバル AGENTS.md への一度きり導入（D3）。
#
# 役割:
#   codex を primary にして xrev（主従反転プリセット）を使う利用者向けに、codex のグローバル指示
#   ファイル（$CODEX_HOME/AGENTS.md。CODEX_HOME 未設定なら既定 ~/.codex/AGENTS.md）へ導入する
#   スニペットを扱う。R7実測（実 codex exec で確認済み）: codex は起動時にこのファイルを読み込む。
#   プロジェクトごとの AGENTS.md への貼り付けは不要（グローバルに一度導入すればよい）。
#
#   既定（引数なし）: スニペット本文をマーカーで挟んで stdout に出力するだけ（**ファイルは一切
#     生成しない**。貼り付け・保存は人間が行う。手動で貼った場合もマーカーごとコピーしておけば、
#     以後 --append-global で冪等に更新できる）。
#   --append-global: グローバル AGENTS.md へスニペットを冪等に追記/更新する（下記「対象解決」
#     「排他ロック」「マーカー」参照）。
#
# 埋め込むパスは XREV_ROOT（このスクリプト自身の位置から `cd .. && pwd` で解決した絶対パス）の
# 1 点のみ。playbook・XREV_CONFIG・各スクリプトはスニペット内で $XREV_ROOT 相対に解決させる
# （単一ルート解決でバージョン不整合を構造的に防止する）。
#
# ── 対象解決（--append-global。lstat 基準・最初に該当した規則のみ）─────────────────
#   対象は $CODEX_HOME/AGENTS.md（CODEX_HOME 未設定なら ~/.codex/AGENTS.md）。
#     1) symlink（存否より先に判定）→ realpath 成功必須。失敗（リンク切れ等）は無変更で fail closed
#        （リンクは温存する。上書きしない）。
#     2) symlink でない既存通常ファイル → realpath 正規化。
#     3) 存在しない → 初回導入。CODEX_HOME ディレクトリ（存在必須。無ければ fail closed。mkdir は
#        しない）を realpath 正規化し basename "AGENTS.md" を結合。
#     4) その他（ディレクトリ・FIFO 等）→ 無変更で fail closed。
#   symlink 経由（対象がどこか別の場所を指す）でも、直接その realpath を対象にした別実行でも、
#   ロックは正規対象（realpath 後）の親ディレクトリに置くため同じロックへ収束する。
#
# 【指摘1（4巡目）: パスは一度も bash の command substitution を通らない】
#   --append-global の実処理（対象解決→ロック→マーカー検査→一時ファイル→mv直前再検証→mv）は
#   すべて単一の python プロセス内で完結する（_xrev_append_global）。旧実装は対象解決の結果
#   （kind・canonical path・home_dir）を JSON で一度 python→bash へ返し、bash 側が
#   `resolved="$(...)"` のようなコマンド置換で受けてから各フィールドを再抽出していた。
#   コマンド置換は末尾の改行を無条件に取り除くため、CODEX_HOME や symlink 解決先が改行で
#   終わる有効なパスだと、そのフィールドを再抽出した時点で末尾の改行が失われ canonical target が
#   別のパスに変化してしまう（誤配送防止が未達になる）。ここでは path を運ぶ唯一の経路を
#   「python プロセス内のローカル変数」に限定し、bash はオプション解釈・スニペット本文の stdin
#   渡し・python の終了コードの伝播だけを担う（診断メッセージも python が直接 stderr へ書く）。
#   `_xrev_resolve_agents_target`（bash 関数。stdout に JSON を返す）は主対象解決だけを単体で
#   確認したいテスト向けに残しているが、**本番の --append-global 経路はこれを経由しない**。
#
# ── 排他ロック（--append-global）─────────────────────────────────────────────
#   正規対象の親ディレクトリに固定名 `.<basename>.xrev-lock`（mkdir 原子取得。TMPDIR 等の環境依存値
#   はロックパスに含めない）。取得後に「再読取り→マーカー構造検査→一時ファイル生成→パーミッション
#   引き継ぎ(stat→chmod)→mv」を行う（すべて同一 python プロセス内。TOCTOU 窓を最小化する）。
#   ロック解放は python の try/finally で必ず行う（自己解放）。
#   競合時は待機せず無変更で拒否する（診断で再実行を案内）。
#   【契約差（重要）】ensure-reviewer（transport.sh）の WS ロックとは性質が異なる:
#     - ensure-reviewer のロックは「回収しない」（stale 回収レースを構造的に排除するため）。
#       競合側は deadline まで present を待つ。
#     - 本ロックは「このプロセスが必ず自己解放する」・「競合したら待機せず即座に拒否する」。
#       生成（副作用の大きいペイン生成）ではなく、既存ファイルへの短時間の書き込みという性質の
#       違いに由来する（詳細は references/protocol.md）。
#
#   mv 直前に、正規対象の状態（種別・識別情報・mode・内容 sha256）が「ロック内で読んだ時点」から
#   不変であることを確認する補助検査を行う（ロックの代替ではない。非協調プロセス＝エディタ等に
#   よる同時書き換え対策。詳細は _xrev_agents_write_py_src 内のコメント参照）。
#
# ── マーカー（冪等な追記/置換）───────────────────────────────────────────────
#   `<!-- xrev:snippet:BEGIN -->` / `<!-- xrev:snippet:END -->` の対で挟む。
#     0 対 = 末尾追記 / 正確に1対（BEGIN が END より前）= 範囲置換（マーカー内側のみ）/
#     それ以外（欠損・重複・入れ子・逆順）= 無変更で fail closed。
#
# 入出力仕様（既定・引数なし）:
#   stdin  … 使わない
#   stdout … AGENTS.md へ貼るスニペット本文（マーカーで挟む）
#   stderr … プラグインキャッシュ配下から実行された場合の補助警告のみ（出力自体は止めない）
#   exit   … 常に 0（スニペット生成自体は失敗し得ない）
#
# 入出力仕様（--append-global）:
#   stdin  … 使わない
#   stdout … 成功時: 書き込んだパスと動作（append/replace）を1行
#   stderr … fail closed の理由・診断
#   exit   … 0=成功 / 10=dangling symlink / 11=CODEX_HOMEディレクトリ不在 /
#            12=対象が想定外の種類 / 13=ロック競合 / 14=マーカー異常 / 15=mv直前の内容変化 /
#            16=対象解決中のI/Oエラー（権限拒否等） / 1=その他の内部エラー
#
set -uo pipefail

_dir() { cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd; }
XREV_ROOT="$(cd "$(_dir)/.." && pwd)"

_log() { printf '[print-agents-snippet] %s\n' "$*" >&2; }

# 補助警告: プラグインキャッシュ配下からの実行を検出する（安定 checkout からの実行が前提。
# README で利用者責任として明示する運用のため、ここでは警告に留め出力自体は止めない）。
case "$XREV_ROOT" in
  */plugins/cache/*)
    echo "[print-agents-snippet] 警告: プラグインキャッシュ配下（${XREV_ROOT}）から実行されています。" \
         "キャッシュはアップデートで再配置されるため、このスニペットに埋め込む XREV_ROOT が" \
         "無効になるおそれがあります。安定した checkout（git clone 済みのディレクトリ等）から" \
         "実行し直すことを推奨します。" >&2
    ;;
esac

XREV_SNIPPET_MARKER_BEGIN='<!-- xrev:snippet:BEGIN -->'
XREV_SNIPPET_MARKER_END='<!-- xrev:snippet:END -->'

# スニペット本文（マーカーは含まない。呼び出し側がマーカーで挟む）は python3 の文字列フォーマット
# で組み立てる（シェルのクォート地獄を避ける）。python コードはクォート済みヒアドキュメント
# (<<'PY') で渡すのでシェル展開は起きない。埋め込む実値は XREV_ROOT の絶対パス 1 点のみで、
# それ以外はすべて $XREV_ROOT のリテラル参照（貼り付け先で実行されるときに解決される）。
# 本文中に bash の `{ ... }` が多数出てくるため str.format は使わず、単純な置換にする
# （プレースホルダ __XREV_ROOT_ABS__ を実パスへ置換。中括弧の二重エスケープを避ける）。
_xrev_snippet_body() {
  XREV_ROOT_ABS="$XREV_ROOT" python3 <<'PY'
import os

root = os.environ["XREV_ROOT_ABS"]

print("""## xrev（codex 主プレイブック・主従反転プリセット）

xrev の主従反転（primary=codex / reviewer=claude）を、このマシン上のすべての codex プロジェクトで
使えるようにするグローバル一度きりの導入スニペット。$CODEX_HOME/AGENTS.md（CODEX_HOME 未設定なら
既定 ~/.codex/AGENTS.md）に追加する（プロジェクトごとの AGENTS.md への貼り付けは不要）。

### XREV_ROOT（このマシンの xrev の場所）

XREV_ROOT = __XREV_ROOT_ABS__

**実行モデルの注意（codex）**: シェルはコマンドごとに新規なので `export` は次のコマンドへ
持ち越されない。以下のコマンドはすべて **1 回の呼び出しの中で環境変数を前置**して実行すること
（例: `XREV_ROOT=__XREV_ROOT_ABS__ "$XREV_ROOT/..."` の形ではなく、値を直接埋めた
`__XREV_ROOT_ABS__/scripts/...` で呼んでよい）。

**サンドボックスの注意（必須）**: cmux ソケットへの接続はサンドボックス内では遮断される
（実測: ペイン内でも ping が exit 31）。`transport.sh` / `review-loop.sh` の呼び出しは
**サンドボックス外実行（エスカレーション承認）で行うこと**。毎回の承認が煩わしい場合は
セッション単位の承認を使う。read-only 系（keyword-match.sh・前提検査の test）は
サンドボックス内のままでよい。

### 前提検査（使う前に毎回確認する）

```bash
test -d "__XREV_ROOT_ABS__" || { echo "XREV_ROOT (__XREV_ROOT_ABS__) が見つかりません"; exit 1; }
for f in scripts/transport.sh scripts/review-loop.sh \\
         references/codex-primary-playbook.md config/xrev.default.json; do
  test -e "__XREV_ROOT_ABS__/$f" || { echo "期待するファイルがありません: $f"; exit 1; }
done
# doctor はソケット接続検査を含むため、サンドボックス外実行が必要
"__XREV_ROOT_ABS__/scripts/transport.sh" doctor
```

### 発火判定

依頼文を $XREV_ROOT/scripts/keyword-match.sh にかけて判定する（config の keyword を
ハードコードしない。既定は @xrev）。

```bash
printf '%s' "$依頼文" | XREV_CONFIG="__XREV_ROOT_ABS__/config/xrev.default.json" \\
  bash "__XREV_ROOT_ABS__/scripts/keyword-match.sh"
```

### 手順

発火したら __XREV_ROOT_ABS__/references/codex-primary-playbook.md を読み、その手順に従うこと。
自分（codex）が primary であることは、**transport.sh / review-loop.sh を呼ぶ各コマンドに
`XREV_PRIMARY=codex` を前置**して自己申告する（export は持ち越されないため毎回前置する。
既定 config の reviewer は auto であり、この自己申告だけで primary=codex・reviewer=claude が
導出される。config ファイルを明示的に固定したい場合のみ
XREV_CONFIG=__XREV_ROOT_ABS__/config/xrev.codex-primary.json を同様に前置する）。
""".replace("__XREV_ROOT_ABS__", root))
PY
}

# ══════════════════════════════════════════════════════════════════════════
# --append-global の実体。transport.sh の `_xrev_*_py_src` 共有方式（純粋関数の定義だけを
# stdout に返す・実行はしない）に倣い、python の関数定義片を bash 関数として分割し、
# 用途ごとに必要な組み合わせだけを結合して1つの python プロセスへ渡す。
#   - _xrev_agents_resolve_py_src: 対象解決 _xrev_resolve_agents_target(home_dir) の定義。
#   - _xrev_agents_write_py_src : 書き込み本体 _xrev_write_agents_file(...) とその依存
#     （_xrev_read_state / _xrev_identity）の定義。
# いずれも「定義するだけ」で副作用や sys.exit を持たない（呼び出し側のドライバが実行・分岐する）。
# こうすることで、本番の結合ドライバ（_xrev_append_global）とテスト側の自前ドライバの両方が
# 同じ実体を共有し、判定ロジックを二重管理しない。
# ══════════════════════════════════════════════════════════════════════════

# 純粋関数定義: _xrev_resolve_agents_target(home_dir) -> dict。
#   戻り値: {"kind": ..., "detail": ..., "home_dir": home_dir}
#   kind: symlink|file|new （detail に canonical_path が入る） / dangling|nohome|other （detail は
#         空文字） / error（lstat/stat/home確認のいずれかで FileNotFoundError 以外の OSError。
#         権限拒否・親経路が非ディレクトリ等。detail に詳細メッセージが入る）
#
# 【背景】旧実装は lstat の全 OSError を「存在しない」として扱っており、権限拒否や I/O エラー
# まで初回導入(new)扱いに誤分類しうる fail-open な欠陥があった。ここでは FileNotFoundError だけを
# 「未作成」として受理し、それ以外の OSError は専用の error kind で無変更拒否する。symlink 側も
# os.path.exists の真偽だけで判定せず、os.stat（シンボリックリンクを辿る）で例外を捕捉し、
# リンク先が通常ファイルであることまで確認する（ディレクトリ等を canonical target として返さない）。
_xrev_agents_resolve_py_src() {
  cat <<'PY'
import os, stat


def _xrev_resolve_agents_target(home_dir):
    agents_path = os.path.join(home_dir, "AGENTS.md")

    def result(kind, detail=""):
        return {"kind": kind, "detail": detail, "home_dir": home_dir}

    def errmsg(e):
        return e.strerror or str(e)

    # 対象パス自体の lstat。FileNotFoundError（存在しない）だけを「未作成」として受理し、
    # それ以外の OSError（権限拒否・親経路が非ディレクトリ等の I/O エラー）は専用結果(error)にする。
    try:
        lst = os.lstat(agents_path)
    except FileNotFoundError:
        lst = None
    except OSError as e:
        return result("error", "lstat: %s" % errmsg(e))

    # 1) symlink（存否より先に判定）。リンク先を os.stat（シンボリックリンクを辿る）で確認し、
    #    実在すること・通常ファイルであることの両方を検証する。
    if lst is not None and stat.S_ISLNK(lst.st_mode):
        try:
            target_st = os.stat(agents_path)
        except FileNotFoundError:
            return result("dangling")
        except OSError as e:
            return result("error", "symlink stat: %s" % errmsg(e))
        if not stat.S_ISREG(target_st.st_mode):
            # リンク先がディレクトリ・FIFO 等（通常ファイルでない）→ canonical target にしない。
            return result("other")
        # ここまでで解決成立が確定済み。realpath は正規化専用として使う（realpath 自体は
        # 内部の解決エラーを無視して best-effort なパスを返す実装のため、成否判定には使わない）。
        return result("symlink", os.path.realpath(agents_path))

    # 2) symlink でない既存通常ファイル。
    if lst is not None and stat.S_ISREG(lst.st_mode):
        return result("file", os.path.realpath(agents_path))

    # 3) 存在しない → 初回導入。CODEX_HOME ディレクトリの存在・種別を明示的に確認する
    #    （os.path.isdir は内部で OSError を握りつぶし False を返すため、権限エラー等を
    #    「無い」と誤認しないよう os.stat を直接使う）。
    if lst is None:
        try:
            home_st = os.stat(home_dir)
        except FileNotFoundError:
            return result("nohome")
        except OSError as e:
            return result("error", "home stat: %s" % errmsg(e))
        if not stat.S_ISDIR(home_st.st_mode):
            return result("nohome")
        return result("new", os.path.join(os.path.realpath(home_dir), "AGENTS.md"))

    # 4) その他（ディレクトリ・FIFO 等。lstat 自体は成功したが symlink でも通常ファイルでもない）。
    return result("other")
PY
}

# 純粋関数定義: _xrev_read_state(target) / _xrev_identity(state) / 書き込み本体
# _xrev_write_agents_file(target, begin, end, snippet, hook=None) -> dict。
# 「再読取り（ベースライン取得）→マーカー構造検査→新内容組み立て→一時ファイル書き出し→
#  パーミッション引き継ぎ(stat→chmod)→（任意のhook）→直前の再検証→mv(os.replace)」を行う。
# 副作用はファイルシステムへの書き込みのみで、stdout/stderr へは書かず sys.exit もしない
# （戻り値の dict で成否を表す。呼び出し側ドライバが診断出力と終了コードを決める）。
#
#   戻り値: {"ok": True, "action": "append"|"replace", "path": target} /
#           {"ok": False, "reason": "marker_malformed"|"marker_reversed"|"changed"|"io_error", ...}
#
#   hook（引数なしの callable。既定 None）: 一時ファイル書き出し・パーミッション引き継ぎの直後、
#     mv 直前の再検証の直前に呼ばれる。**本番のドライバは常に hook=None で呼び出し、この引数は
#     一切使わない**。テストだけがこの関数を直接呼び出して、baseline 取得後・最終確認前という
#     タイミングを運に頼らず注入するために使う（例: chmod を1回だけ行う）。env 変数など本番の
#     実行環境から到達可能な経路は一切持たない — 呼び出し側（テストの自前ドライバ）が明示的に
#     関数引数として渡したときだけ発火する。
#
# 【mv直前の再検証で比較する項目】旧実装は baseline/current の比較を exists の真偽と内容 digest
# だけで行っていた。非協調プロセスが対象を「同内容の別ファイル」（例: 通常ファイルを同じバイト列の
# symlink に置換する、あるいはエディタの atomic-save のように新しい inode の同内容ファイルへ
# 差し替える）へ入れ替えても、この2値だけでは変化なしと誤認しうる。os.replace は symlink を
# 辿らずリンクそのものを置き換えてしまうため、置換後にそこへ書き込むのは意図しない対象の破壊になる。
# また chmod のみの変更（内容は不変）も検出できず、旧 baseline の mode で静かに上書きしていた。
# ここでは lstat（symlink を辿らない）でファイル種別・識別情報(st_dev/st_ino)・mode を取得し、
# いずれか1つでも異なれば changed として扱う（種別・inode・mode・内容のすべてが一致した場合のみ
# 「不変」と判定する）。
_xrev_agents_write_py_src() {
  cat <<'PY'
import hashlib, os, stat, tempfile


def _xrev_read_state(target):
    try:
        lst = os.lstat(target)
    except FileNotFoundError:
        return {"exists": False, "is_regular": None, "dev": None, "ino": None,
                "mode": None, "digest": hashlib.sha256(b"").hexdigest(), "content": ""}
    except OSError:
        # lstat 自体の失敗（権限等）は識別不能として扱い、比較で必ず不一致(changed)になるように
        # する（fail closed。同一の失敗が baseline/current の両方で起きても“偶然同じ失敗”を
        # 「不変」と誤認しないよう digest を None にして常に不一致にする）。
        return {"exists": True, "is_regular": None, "dev": None, "ino": None,
                "mode": None, "digest": None, "content": None}
    is_regular = stat.S_ISREG(lst.st_mode)
    if not is_regular:
        # 通常ファイル以外（symlink・ディレクトリ等に置換されていた）。中身は読まない
        # （symlink を辿って別ファイルの内容を読み込み、それを比較対象にしない）。
        return {"exists": True, "is_regular": False, "dev": lst.st_dev, "ino": lst.st_ino,
                "mode": stat.S_IMODE(lst.st_mode), "digest": None, "content": None}
    with open(target, "rb") as f:
        raw = f.read()
    return {
        "exists": True,
        "is_regular": True,
        "dev": lst.st_dev,
        "ino": lst.st_ino,
        "mode": stat.S_IMODE(lst.st_mode),
        "digest": hashlib.sha256(raw).hexdigest(),
        "content": raw.decode("utf-8", errors="surrogateescape"),
    }


def _xrev_identity(s):
    # 比較に使うタプル。content(本文)は意図的に含めない（digest が内容の代表値であり、
    # 巨大本文をタプル比較のためだけに二重に持たないため）。
    return (s["exists"], s["is_regular"], s["dev"], s["ino"], s["mode"], s["digest"])


def _xrev_write_agents_file(target, begin, end, snippet, hook=None):
    # 呼び出し側（body="$(_xrev_snippet_body)"）は command substitution 経由で本文を受け取るため
    # bash がスニペット本文の末尾改行を無条件に取り除く。ここで正規化せずに
    # begin + "\n" + snippet + end という組み立てをすると、本文最終行の直後に END マーカーが
    # 改行無しで連結され、独立行のマーカーブロックという契約（stdout モードの出力形式と同じ）が
    # 崩れる。BEGIN 直後は既に "\n" を明示的に挟んでいるので対称に、snippet 側は必ず1個の
    # 末尾改行で終わるよう正規化してから END の直前に置く。
    if not snippet.endswith("\n"):
        snippet += "\n"

    baseline = _xrev_read_state(target)
    if baseline["exists"] and not baseline["is_regular"]:
        # ロック取得後の最初の読み取り時点で既に通常ファイルでない（symlink 化・識別不能等）。
        # 対象解決(_xrev_resolve_agents_target)は通常ファイル/未作成のみを正規対象として渡す
        # 契約なので、ここに来る場合は解決からロック取得までの間に何かが変化している。
        # 安全側に倒し無変更で拒否する。
        return {"ok": False, "reason": "changed"}
    content = baseline["content"] or ""
    bc, ec = content.count(begin), content.count(end)

    if bc == 0 and ec == 0:
        action = "append"
        prefix = content if (not content or content.endswith("\n")) else content + "\n"
        new_content = prefix + begin + "\n" + snippet + end + "\n"
    elif bc == 1 and ec == 1:
        bi, ei = content.find(begin), content.find(end)
        if bi >= ei:
            return {"ok": False, "reason": "marker_reversed"}
        action = "replace"
        new_content = content[:bi] + begin + "\n" + snippet + end + content[ei + len(end):]
    else:
        return {"ok": False, "reason": "marker_malformed", "begin_count": bc, "end_count": ec}

    target_dir = os.path.dirname(target) or "."
    fd, tmp_path = tempfile.mkstemp(prefix=".xrev-agents-", dir=target_dir)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(new_content.encode("utf-8", errors="surrogateescape"))
        # パーミッション引き継ぎ（stat→chmod）。新規作成時（既存ファイル無し）は 0644 を既定にする。
        os.chmod(tmp_path, baseline["mode"] if baseline["mode"] is not None else 0o644)

        if hook is not None:
            hook()

        # mv 直前の再検証（ロックの代替ではない補助検査。非協調プロセスによる同時書き換え対策）。
        # 種別(is_regular)・識別情報(dev/ino)・mode・内容(digest) のいずれか1つでも baseline と
        # 異なれば changed として拒否する（内容が同一でも symlink への置換や inode の差し替え、
        # chmod だけの変更を見逃さない）。
        current = _xrev_read_state(target)
        if _xrev_identity(current) != _xrev_identity(baseline):
            os.unlink(tmp_path)
            return {"ok": False, "reason": "changed"}

        os.replace(tmp_path, target)
    except Exception as e:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        return {"ok": False, "reason": "io_error", "detail": str(e)}

    return {"ok": True, "action": action, "path": target}
PY
}

# ── 対象解決の単体テスト用ラッパ（bash 呼び出し可能・JSON を stdout に返す）────────────
# 主対象解決だけを単体で確認したいテスト向け。**本番の --append-global 経路はこれを経由しない**
# （指摘1・4巡目。パスを bash の command substitution へ通さないため）。
_xrev_resolve_agents_target() {
  local home_dir; home_dir="${CODEX_HOME:-$HOME/.codex}"
  local prog
  prog="$(_xrev_agents_resolve_py_src)"$'\n''import json, os
print(json.dumps(_xrev_resolve_agents_target(os.environ["XREV_HOME_DIR"]), ensure_ascii=False))
'
  XREV_HOME_DIR="$home_dir" python3 -c "$prog"
}

# 純粋関数: JSON 1行（stdin）からトップレベルの文字列フィールドを取り出す。
# cut/awk 等の区切り文字ベースの分割を一切使わない。フィールド値にタブ・改行が含まれていても
# json.loads の単一回のパースにより正しく復元する（`_xrev_resolve_agents_target` の単体テスト用。
# タブ・改行を含まない値の抽出にのみ使うこと — 末尾改行を含む値の抽出はコマンド置換で失われる
# ため、そのようなケースはファイルシステムの状態を直接確認するテストにすること）。
#   入力: $1=キー名, stdin=JSON文字列
#   出力: 該当フィールドの値（文字列以外・欠落・パース失敗は空文字）
_xrev_json_field() {
  local key="$1"
  python3 -c '
import json, sys
key = sys.argv[1]
try:
    v = json.loads(sys.stdin.read()).get(key, "")
except Exception:
    v = ""
sys.stdout.write(v if isinstance(v, str) else "")
' "$key"
}

# ── 書き込み本体の単体テスト用ラッパ（bash 呼び出し可能・JSON を stdout に返す）─────────
# hook は常に None（本番と同じ）。hook を注入したいテストは _xrev_agents_write_py_src を
# 直接使って自前のドライバを組み立てること（下記テストの流儀を参照）。
_xrev_agents_write() {
  local target="$1" begin="$2" end="$3"
  local prog
  prog="$(_xrev_agents_write_py_src)"$'\n''import json, sys
target, begin, end = sys.argv[1], sys.argv[2], sys.argv[3]
snippet = sys.stdin.read()
print(json.dumps(_xrev_write_agents_file(target, begin, end, snippet), ensure_ascii=False))
'
  python3 -c "$prog" "$target" "$begin" "$end"
}

# ── --append-global: 結合ドライバ（対象解決→ロック→書き込み→解放を単一プロセスで実行）─────
# 【指摘1（4巡目）への対処が反映された箇所】home_dir 以外のすべての path 値（canonical target・
# lock path）はこの python プロセスのローカル変数としてのみ存在し、bash へ一度も戻らない。
# 診断メッセージ・成功メッセージも python が直接 stderr/stdout へ書き、bash 側は python の
# 終了コードをそのまま伝播するだけ（bash での再組み立てをしない）。
_xrev_append_global_driver_py_src() {
  cat <<'PY'
import os, sys


def _fail(msg, code):
    sys.stderr.write("[print-agents-snippet] %s\n" % msg)
    sys.exit(code)


home_dir = os.environ["XREV_HOME_DIR"]
begin = sys.argv[1]
end = sys.argv[2]
snippet = sys.stdin.read()

resolved = _xrev_resolve_agents_target(home_dir)
kind = resolved["kind"]

if kind == "dangling":
    _fail("対象(%s/AGENTS.md)はリンク切れの symlink です。リンクを温存し無変更で中止します"
          "（fail closed）。リンク先を修復するか、リンク自体を削除してから再実行してください。"
          % home_dir, 10)
if kind == "nohome":
    _fail("CODEX_HOME ディレクトリ(%s)が存在しません（mkdir はしません）。"
          "ディレクトリを用意してから再実行してください。" % home_dir, 11)
if kind == "other":
    _fail("対象(%s/AGENTS.md)がディレクトリ等の想定外の種類です。無変更で中止します（fail closed）。"
          % home_dir, 12)
if kind == "error":
    _fail("対象(%s/AGENTS.md)の解決中にエラーが発生しました（%s）。無変更で中止します（fail closed）。"
          % (home_dir, resolved["detail"]), 16)
if kind not in ("symlink", "file", "new"):
    _fail("対象解決に失敗しました（内部エラー: kind='%s'）。" % kind, 1)

# ここに到達した時点で resolved["detail"] が正規対象パス（symlink/file/new のいずれか）。
# 以降このプロセス内のローカル変数としてのみ扱い、bash へは一切戻さない。
target = resolved["detail"]
lock_dir = os.path.dirname(target) or "."
lock_path = os.path.join(lock_dir, "." + os.path.basename(target) + ".xrev-lock")

try:
    os.mkdir(lock_path)
except FileExistsError:
    _fail("他の実行と競合しています（ロック: %s）。待機せず無変更で中止します。"
          "ロックが残留している場合は中身を確認のうえ 'rmdir %s' で解除し、再実行してください。"
          % (lock_path, lock_path), 13)
except OSError as e:
    _fail("ロック取得に失敗しました（%s）: %s" % (lock_path, e.strerror or str(e)), 13)

try:
    # 本番は常に hook=None（テスト専用の注入経路は _xrev_agents_write_py_src のドキュメント参照）。
    result = _xrev_write_agents_file(target, begin, end, snippet, hook=None)
finally:
    # 自己解放（ensure-reviewer の WS ロックとの契約差: 待機しない・このプロセスが必ず解放する）。
    try:
        os.rmdir(lock_path)
    except OSError:
        pass

if not result.get("ok"):
    reason = result.get("reason", "")
    if reason == "marker_malformed":
        _fail("マーカー構造が不正です（欠損・重複のいずれか）。無変更で中止します。対象: %s" % target, 14)
    if reason == "marker_reversed":
        _fail("マーカーの順序が逆転しています（END が BEGIN より先）。無変更で中止します。対象: %s"
              % target, 14)
    if reason == "changed":
        _fail("書き込み直前に対象の内容が変化しました。無変更で中止します。再実行してください。対象: %s"
              % target, 15)
    _fail("書き込みに失敗しました（reason=%s）。対象: %s" % (reason or "unknown", target), 1)

sys.stdout.write("AGENTS.md (%s): %s\n" % (result["action"], result["path"]))
sys.exit(0)
PY
}

_xrev_append_global() {
  local home_dir; home_dir="${CODEX_HOME:-$HOME/.codex}"
  local body prog
  body="$(_xrev_snippet_body)"
  prog="$(_xrev_agents_resolve_py_src)"$'\n'"$(_xrev_agents_write_py_src)"$'\n'"$(_xrev_append_global_driver_py_src)"
  printf '%s' "$body" \
    | XREV_HOME_DIR="$home_dir" python3 -c "$prog" "$XREV_SNIPPET_MARKER_BEGIN" "$XREV_SNIPPET_MARKER_END"
  return $?
}

# ── エントリポイント ─────────────────────────────────────────────────────────
# 直接実行されたときだけ CLI を走らせる（transport.sh / review-loop.sh と同じ流儀）。source 時
# （テスト）は関数定義のみで、意図せず exit してテストランナーごと終了させることを防ぐ。
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  case "${1:-}" in
    --append-global)
      _xrev_append_global
      exit $? ;;
    "")
      printf '%s\n' "$XREV_SNIPPET_MARKER_BEGIN"
      _xrev_snippet_body
      printf '%s\n' "$XREV_SNIPPET_MARKER_END"
      exit 0 ;;
    *)
      _log "usage: print-agents-snippet.sh [--append-global]"
      exit 64 ;;
  esac
fi
