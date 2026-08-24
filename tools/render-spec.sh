#!/usr/bin/env bash
#
# render-spec.sh — 人間向け HTML の生成器。
#
#   references/protocol/*.md（エージェント向け正典）から docs/spec/*.html（人間向け）を生成する。
#   正典は md 側であり、HTML は常に本スクリプトで再生成する（手書き二重管理をしない）。
#   生成物の最新性は tools/verify.sh が「一時ディレクトリへ生成して cmp 照合」で検査する（非変更型）。
#
#   加えて --site モードでは GitHub Pages 用のサイト一式を組み立てる。リポジトリ内の全 md を
#   HTML 化し、手書き HTML（docs/*.html）と詳細仕様ページを同じディレクトリ構造で並べるため、
#   既存の相対リンク（`../README.md` 等）がサイト内でそのまま解決する。リポジトリ側の
#   md・HTML には一切手を入れない（リンク書き換えはビルド時のみ）。
#
#   使い方:
#     tools/render-spec.sh                  # docs/spec/ へ生成
#     tools/render-spec.sh --out <DIR>      # 指定ディレクトリへ生成（verify の照合用）
#     tools/render-spec.sh --render-stdin   # stdin の md を本文 HTML に変換して stdout へ（テスト用）
#     tools/render-spec.sh --site <DIR>     # GitHub Pages 用サイトを <DIR> へ組み立て
#
#   設計（クロスレビュー収束済み）:
#   - 依存は python3 標準ライブラリのみ。出力は決定的（タイムスタンプ等を含まない）。
#   - エスケープはコンテキスト別: テキストノード = &<> / 属性値 = 加えて引用符 /
#     コードはテキストと同規則でインライン記法を解釈しない。トークナイズしてから各片を
#     エスケープするため、エスケープ済み文字列へ再度置換がかかることはない。
#   - href はスキームなしの相対パスと https:// のみ許可（それ以外は fail closed）。
#   - 処理できない入力は黙って通さない: 未閉鎖フェンス / 表セパレータ欠落 / リンク閉じ括弧
#     欠落 / 許可外スキーム / 不採用構文（生 HTML・参照リンク定義）を検出したら
#     エラーを列挙して非ゼロ終了する。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
OUT="$ROOT/docs/spec"
FIGDIR="$ROOT/tools/spec-figures"
MODE="files"
# サイトモードで「サイトに載せないリポジトリ内ファイル」へのリンクを向ける先。
# fork でも正しい URL になるよう CI から実際の値を渡せるようにしておく。
REPO_URL="https://github.com/naokami3/xrev"
REPO_REF="main"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --render-stdin) MODE="stdin"; shift ;;
    --out) OUT="${2:?--out にはディレクトリを指定してください}"; shift 2 ;;
    --site) MODE="site"; OUT="${2:?--site にはディレクトリを指定してください}"; shift 2 ;;
    --figures) FIGDIR="${2:?--figures にはディレクトリを指定してください}"; shift 2 ;;
    --repo-url) REPO_URL="${2:?--repo-url には URL を指定してください}"; shift 2 ;;
    --ref) REPO_REF="${2:?--ref にはブランチ名を指定してください}"; shift 2 ;;
    *)
      echo "使い方: tools/render-spec.sh [--out DIR | --site DIR] [--figures DIR]" \
           "[--repo-url URL] [--ref REF] [--render-stdin]" >&2
      exit 2 ;;
  esac
done

# python3 はプログラム本文をヒアドキュメント（stdin）から読むため、--render-stdin の
# md 本文は stdin では渡せない。一時ファイルへ受けてパスで渡す。
TMPMD=""
if [[ "$MODE" == "stdin" ]]; then
  TMPMD="$(mktemp "${TMPDIR:-/tmp}/xrev-render-stdin.XXXXXX")"
  cat > "$TMPMD"
fi

python3 - "$ROOT" "$OUT" "$MODE" "$TMPMD" "$FIGDIR" "$REPO_URL" "$REPO_REF" <<'PY'
import html
import os
import re
import sys
from html.parser import HTMLParser

ROOT, OUT, MODE, STDIN_MD, FIGDIR, REPO_URL, REPO_REF = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5],
    sys.argv[6], sys.argv[7])
SRC_DIR = "references/protocol"   # リポジトリ相対の入力ディレクトリ
DST_DIR = "docs/spec"             # リポジトリ相対の出力ディレクトリ（リンク再計算の基点）

# ページの順序と index 用の 1 行説明（protocol.md 索引と同内容）
PAGES = [
    ("message-format", "メッセージ書式・センチネル・1物理行エンコード・XREV-ASCII-V1・切り詰め検出"),
    ("review-contract", "severity と verdict・act ラベル（会話終端の思想）"),
    ("exit-codes", "review-loop / parse-review / transport の終了コード設計"),
    ("config", "設定キー一覧・reviewer の auto 解決（D1）・実行コンテキスト・解決順"),
    ("delivery-gates", "宛先解決と送信ゲート（Phase1）・送信の堅牢化"),
    ("reviewer-lifecycle", "reviewer ペインの自動生成（Phase1c）・read-only 強制・グローバル導入（D3）"),
    ("reference-mode", "参照モード（Phase2: diff 本文を送らないコンテキスト削減）"),
    ("doctor", "transport.sh doctor（外部ツール契約の一括診断）"),
]
SLUGS = {slug for slug, _ in PAGES}

SITE_MODE = (MODE == "site")


def blob_url(repo_rel, is_dir=False):
    """サイトに載せないリポジトリ内ファイルへのリンク（GitHub 上のソースを見せる）。"""
    return "%s/%s/%s/%s" % (REPO_URL.rstrip("/"), "tree" if is_dir else "blob",
                            REPO_REF, repo_rel)


def canon_href(repo_rel):
    """正典 md へのリンク。spec 生成では相対パス、サイトでは GitHub 上のソースへ。

    サイトでは md 自体をページ化するため相対リンクは HTML 側を指してしまい、
    「正典（md）そのものを見る」導線にならない。GitHub の blob 表示へ送る。
    """
    return blob_url(repo_rel) if SITE_MODE else os.path.relpath(repo_rel, DST_DIR)


def esc(text):
    """テキストノード用エスケープ（& < >）"""
    return html.escape(text, quote=False)


def esc_attr(text):
    """属性値用エスケープ（& < > " '。html.escape の quote=True は ' も置換する）"""
    return html.escape(text, quote=True)


def gh_anchor(heading):
    """GitHub 方式の見出し→アンカー変換（近似。unicode 文字は保持）"""
    s = heading.strip().lower()
    s = re.sub(r"[`*]", "", s)
    s = "".join(c for c in s if c.isalnum() or c in " -_")
    return s.replace(" ", "-")


def split_href(href, errors, ctx):
    """href の共通検査。(target, frag) を返す。相対パスでなければ (None, 置換後 href)。"""
    if href.startswith("#"):
        return None, href
    if href.startswith("//"):
        # スキーム相対 URL はスキーム検査をすり抜けるため明示的に拒否する
        errors.append(f"{ctx}: スキーム相対 URL は非対応: {href}")
        return None, href
    m = re.match(r"^([A-Za-z][A-Za-z0-9+.-]*):", href)
    if m:
        if m.group(1).lower() == "https":
            return None, href
        errors.append(f"{ctx}: 許可外の URL スキーム: {href}")
        return None, href
    # 「スキームなしの相対パス」の契約を厳密にする: 絶対パス・バックスラッシュを認めず、
    # 正規化後にリポジトリ外へ出るパスも拒否する（意図しないローカルパスへの誘導を閉じる）
    if href.startswith("/") or "\\" in href:
        errors.append(f"{ctx}: 絶対パス・バックスラッシュを含む href は非対応: {href}")
        return None, href
    return (href.split("#", 1) if "#" in href else (href, None)), None


def spec_rewrite_href(href, errors, ctx):
    """リンク先の再計算。spec 内 .md → .html、spec 外は docs/spec/ 基点の相対へ。"""
    parts, done = split_href(href, errors, ctx)
    if parts is None:
        return done
    target, frag = parts
    repo_rel = os.path.normpath(os.path.join(SRC_DIR, target))
    if repo_rel == ".." or repo_rel.startswith(".." + os.sep):
        errors.append(f"{ctx}: リポジトリ外を指す href は非対応: {href}")
        return href
    base = os.path.basename(repo_rel)
    if os.path.dirname(repo_rel) == SRC_DIR and base.endswith(".md") and base[:-3] in SLUGS:
        new = base[:-3] + ".html"
    else:
        new = os.path.relpath(repo_rel, DST_DIR)
    if frag is not None:
        new += "#" + frag
    return new


def site_html_for_md(repo_rel):
    """md の repo 相対パス → サイト内での出力パス（repo 相対）。

    protocol の md は詳細仕様ページ（docs/spec/）が既に人間向けの表現なので、
    そこへ寄せて二重のページを作らない。
    """
    if repo_rel == "references/protocol.md":
        return DST_DIR + "/index.html"
    d, b = os.path.split(repo_rel)
    if d == SRC_DIR and b[:-3] in SLUGS:
        return "%s/%s.html" % (DST_DIR, b[:-3])
    return repo_rel[:-3] + ".html"


def make_site_resolver(base_dir, out_dir):
    """サイト用のリンク解決器を作る。

    base_dir = リンクを解決する基点（元ファイルのあるディレクトリ・repo 相対）
    out_dir  = 生成物の置き場（repo 相対）。相対リンクはここを基点に計算し直す。

    md → サイト内の html、リポジトリ内のその他ファイル → GitHub 上のソース、
    存在しないリンク先 → エラー（fail closed。壊れたリンクのまま公開しない）。
    """
    def resolve(href, errors, ctx):
        parts, done = split_href(href, errors, ctx)
        if parts is None:
            return done
        target, frag = parts
        if not target:
            return href
        repo_rel = os.path.normpath(os.path.join(base_dir, target))
        if repo_rel == ".." or repo_rel.startswith(".." + os.sep):
            errors.append(f"{ctx}: リポジトリ外を指す href は非対応: {href}")
            return href
        abspath = os.path.join(ROOT, repo_rel)
        if not os.path.exists(abspath):
            errors.append(f"{ctx}: リンク先がリポジトリに存在しない: {href}")
            return href
        if os.path.isdir(abspath):
            new = blob_url(repo_rel, is_dir=True)
        elif repo_rel.endswith(".md"):
            new = os.path.relpath(site_html_for_md(repo_rel), out_dir)
        elif repo_rel.endswith(".html"):
            new = os.path.relpath(repo_rel, out_dir)
        else:
            new = blob_url(repo_rel)
        if frag is not None:
            new += "#" + frag
        return new
    return resolve


# リンク解決器。既定は spec モード。サイトモードではページごとに差し替える
# （parse_inline から解決規則へ引数を通さずに切り替えるための単一の間接参照）。
RESOLVE = spec_rewrite_href


def rewrite_href(href, errors, ctx):
    return RESOLVE(href, errors, ctx)


HREF_ATTR_RE = re.compile(r'\b(href|src)="([^"]*)"')


def rewrite_html_links(content, base_dir, out_dir, errors, ctx):
    """手書き HTML / 図フラグメントの href・src をサイト用に解決し直す。

    リポジトリ内のファイルは書き換えない（書き換えはビルド時のみ）。
    """
    resolve = make_site_resolver(base_dir, out_dir)

    def sub(m):
        return '%s="%s"' % (m.group(1),
                            esc_attr(resolve(html.unescape(m.group(2)), errors, ctx)))
    return HREF_ATTR_RE.sub(sub, content)


LINK_RE = re.compile(r"\[([^\]]*)\]\(([^)\s]+)\)")


def match_link(text, i):
    """text[i] == '[' を前提に (ラベル, href, 終端) を返す。成立しなければ None。

    ラベル内の [] の対応を数えるため、画像を含むリンク（[![alt](img)](url)）も扱える。
    href の契約（空でない・空白と ) を含まない）は LINK_RE と同じ。
    """
    depth, j, n = 0, i, len(text)
    while j < n:
        if text[j] == "[":
            depth += 1
        elif text[j] == "]":
            depth -= 1
            if depth == 0:
                break
        j += 1
    if j >= n or j + 1 >= n or text[j + 1] != "(":
        return None
    k = text.find(")", j + 2)
    if k == -1:
        return None
    href = text[j + 2:k]
    if not href or re.search(r"\s", href):
        return None
    return text[i + 1:j], href, k + 1


def parse_inline(text, errors, ctx, allow_bold=True):
    """インライン変換。優先順: コードスパン → 画像 → リンク → 強調。各片を個別にエスケープ。"""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "`":
            j = text.find("`", i + 1)
            if j == -1:
                out.append(esc(c))
                i += 1
                continue
            out.append("<code>" + esc(text[i + 1:j]) + "</code>")
            i = j + 1
        elif c == "!" and text.startswith("![", i):
            m = match_link(text, i + 1)
            if m:
                alt, src, end = m
                src2 = rewrite_href(src, errors, ctx)
                # alt は属性値なのでインライン記法を解釈せず、そのままエスケープして入れる
                out.append('<img src="%s" alt="%s">' % (esc_attr(src2), esc_attr(alt)))
                i = end
            else:
                out.append(esc(c))
                i += 1
        elif c == "[":
            m = match_link(text, i)
            if m:
                label, href, end = m
                href2 = rewrite_href(href, errors, ctx)
                out.append('<a href="%s">%s</a>'
                           % (esc_attr(href2), parse_inline(label, errors, ctx, allow_bold)))
                i = end
            else:
                if re.match(r"\[[^\]]*\]\(", text[i:]):
                    errors.append(f"{ctx}: リンクの閉じ括弧が見つからない: {text[i:i + 40]!r}")
                out.append(esc(c))
                i += 1
        elif allow_bold and text.startswith("**", i):
            j = text.find("**", i + 2)
            if j == -1:
                out.append(esc("**"))
                i += 2
            else:
                out.append("<strong>"
                           + parse_inline(text[i + 2:j], errors, ctx, allow_bold=False)
                           + "</strong>")
                i = j + 2
        else:
            j = i
            while j < n and text[j] not in "`[!" and not (allow_bold and text.startswith("**", j)):
                j += 1
            if j == i:
                j = i + 1
            out.append(esc(text[i:j]))
            i = j
    return "".join(out)


# ── 図フラグメント（tools/spec-figures/<slug>--<アンカー>--NN.html）────────────
#
# 人間向けレンダリングにのみ図を載せるための入力。md（エージェント向け正典）は変更しない。
# フラグメントは生 HTML として挿入されるため、要素・属性の明示 allowlist で検証する
# （設計クロスレビュー済み。allowlist に無いものは 1 件でもあれば非ゼロ終了 = fail closed）。

FIG_DIR_REL = os.path.join("tools", "spec-figures")

FRAG_ALLOWED_ELEMENTS = {
    "figure", "figcaption", "svg", "title", "defs", "marker", "g", "path", "rect",
    "line", "circle", "ellipse", "polyline", "polygon", "text", "tspan", "a",
    "code", "span", "br",
}
# 属性名は html.parser が小文字化した形で照合する（viewBox → viewbox 等）
FRAG_ALLOWED_ATTRS = {
    "class", "id", "x", "y", "x1", "y1", "x2", "y2", "width", "height", "rx", "ry",
    "cx", "cy", "r", "d", "points", "viewbox", "transform", "text-anchor",
    "fill", "stroke", "stroke-width", "stroke-dasharray", "marker-start", "marker-end",
    "orient", "refx", "refy", "markerwidth", "markerheight",
    "role", "aria-labelledby", "aria-label", "xmlns", "href",
}
FRAG_URL_VALUE_RE = re.compile(r"^url\(#[A-Za-z0-9_-]+\)$")


class FragmentValidator(HTMLParser):
    """図フラグメントの構造・allowlist 検証。"""

    def __init__(self, ctx, errors):
        super().__init__()
        self.ctx = ctx
        self.errors = errors
        self.stack = []
        self.roots = []
        self.svg_count = 0
        self.svg_states = []  # SVG ごとの検証状態（入れ子・複数 SVG で状態を混ぜない）

    def _close_svg(self):
        state = self.svg_states.pop()
        self.svg_count += 1
        if not (state["role"] and state["title"]):
            self.errors.append(f"{self.ctx}: 各 svg に role=\"img\" と <title> が必要")

    def handle_starttag(self, tag, attrs):
        if tag not in FRAG_ALLOWED_ELEMENTS:
            self.errors.append(f"{self.ctx}: 許可外の要素 <{tag}>")
        if not self.stack:
            self.roots.append(tag)
        for name, value in attrs:
            value = value or ""
            if name.startswith("on"):
                self.errors.append(f"{self.ctx}: イベントハンドラ属性は禁止: {name}")
                continue
            if name == "style":
                self.errors.append(f"{self.ctx}: style 属性は禁止（class + 共通 CSS を使う）")
                continue
            if name not in FRAG_ALLOWED_ATTRS:
                self.errors.append(f"{self.ctx}: 許可外の属性 {name}（<{tag}>）")
                continue
            if name == "href":
                if tag != "a":
                    self.errors.append(f"{self.ctx}: href は <a> でのみ許可（<{tag}>）")
                elif value.startswith("#") or value.startswith("https://"):
                    pass
                elif (re.match(r"^([A-Za-z][A-Za-z0-9+.-]*:|//|/)", value)
                      or "\\" in value):
                    self.errors.append(f"{self.ctx}: 許可外の href: {value}")
                else:
                    # 相対 href: フラグメントは docs/spec/ に注入されるため DST_DIR 基点で
                    # 正規化し、リポジトリ外へ脱出するパスを拒否する（本文リンクと同じ規則）
                    target = value.split("#", 1)[0]
                    repo_rel = os.path.normpath(os.path.join(DST_DIR, target))
                    if repo_rel == ".." or repo_rel.startswith(".." + os.sep):
                        self.errors.append(f"{self.ctx}: リポジトリ外を指す href は非対応: {value}")
            if "url(" in value and not FRAG_URL_VALUE_RE.match(value):
                self.errors.append(f"{self.ctx}: url() は同一文書内参照のみ許可: {name}={value}")
        if tag == "svg":
            role_ok = any(n == "role" and v == "img" for n, v in attrs)
            self.svg_states.append({"role": role_ok, "title": False})
        if tag == "title" and self.svg_states:
            self.svg_states[-1]["title"] = True
        if tag != "br":
            self.stack.append(tag)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag != "br" and self.stack and self.stack[-1] == tag:
            self.stack.pop()
            if tag == "svg":
                self._close_svg()

    def handle_endtag(self, tag):
        if tag == "br":
            return
        if not self.stack or self.stack[-1] != tag:
            self.errors.append(f"{self.ctx}: タグ不整合 </{tag}>")
            return
        self.stack.pop()
        if tag == "svg":
            self._close_svg()


def validate_fragment(content, ctx, errors):
    v = FragmentValidator(ctx, errors)
    v.feed(content)
    if v.stack:
        errors.append(f"{ctx}: 未閉鎖のタグ: {v.stack}")
    if v.roots != ["figure"]:
        errors.append(f"{ctx}: 単一の <figure> ルートでない（roots={v.roots}）")
    if v.svg_count == 0:
        errors.append(f"{ctx}: svg が 1 つも無い（図フラグメントには必須）")


def load_figures(errors):
    """{slug: {anchor: [(NN, フラグメント)]}} を返す（検証込み・NN 昇順は呼び出し側で sort）。"""
    figs = {}
    fig_dir = FIGDIR
    if not os.path.isdir(fig_dir):
        return figs
    slugs_sorted = sorted(SLUGS, key=len, reverse=True)
    for name in sorted(os.listdir(fig_dir)):
        if name.startswith("."):
            continue
        ctx = FIG_DIR_REL + "/" + name
        m = re.match(r"^(.+)--(\d{2})\.html$", name)
        if not m:
            errors.append(f"{ctx}: ファイル名が規約 <slug>--<アンカー>--NN.html に一致しない")
            continue
        stem, nn = m.group(1), m.group(2)
        slug = next((s for s in slugs_sorted if stem.startswith(s + "--")), None)
        if slug is None:
            errors.append(f"{ctx}: 既知の slug（{'/'.join(sorted(SLUGS))}）で始まっていない")
            continue
        anchor = stem[len(slug) + 2:]
        if not anchor:
            errors.append(f"{ctx}: アンカー部が空")
            continue
        with open(os.path.join(fig_dir, name), encoding="utf-8") as f:
            content = f.read()
        validate_fragment(content, ctx, errors)
        if SITE_MODE:
            # 図内の相対リンク（例: ../cmux-behavior.md）もサイト内で解決させる。
            # 注入先は常に docs/spec/ なので基点・出力先とも DST_DIR。
            content = rewrite_html_links(content, DST_DIR, DST_DIR, errors, ctx)
        figs.setdefault(slug, {}).setdefault(anchor, []).append((nn, content))
    return figs


def inject_figures(blocks, slug, figs, errors):
    """blocks = [(anchor|None, html)]。見出し（id=anchor）の直後・intro は H1 直後に挿入する。"""
    page_figs = figs.get(slug, {})
    used = set()
    res = []
    h1_done = False
    for anchor, html_block in blocks:
        res.append(html_block)
        if not h1_done and html_block.startswith("<h1"):
            h1_done = True
            if "intro" in page_figs:
                for _, frag in sorted(page_figs["intro"]):
                    res.append(frag)
                used.add("intro")
        if anchor is not None and anchor != "intro" and anchor in page_figs:
            for _, frag in sorted(page_figs[anchor]):
                res.append(frag)
            used.add(anchor)
    for anchor in page_figs:
        if anchor not in used:
            errors.append(f"{FIG_DIR_REL}/{slug}--{anchor}--NN.html: "
                          f"対応する見出し（id={anchor}）がページに無い")
    return res


HEADING_RE = re.compile(r"^(#{1,6}) (.+)$")
FENCE_RE = re.compile(r"^(\s*)```(\S*)\s*$")
ITEM_RE = re.compile(r"^(\s*)(-|\d+\.) (.*)$")
TABLE_SEP_RE = re.compile(r"^\|?[\s:\-|]+\|?$")
REFDEF_RE = re.compile(r"^\[[^\]]+\]:")
RAWHTML_RE = re.compile(r"^<[A-Za-z!/]")


def is_block_start(line):
    return bool(HEADING_RE.match(line) or FENCE_RE.match(line)
                or line.startswith("|") or line.startswith(">")
                or ITEM_RE.match(line))


def split_row(line):
    """表の行をセルに分割（\\| はリテラルのパイプとして退避）"""
    s = line.strip()
    s = s.replace("\\|", "\x00")
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|"):
        s = s[:-1]
    return [c.replace("\x00", "|").strip() for c in s.split("|")]


def parse_table(lines, i, out, errors, ctx):
    header = split_row(lines[i])
    if i + 1 >= len(lines) or not (lines[i + 1].startswith("|")
                                   and TABLE_SEP_RE.match(lines[i + 1].strip())
                                   and "-" in lines[i + 1]):
        errors.append(f"{ctx}:{i + 1}: 表の先頭行直後にセパレータ行（|---|）が無い")
        return i + 1
    rows = []
    j = i + 2
    while j < len(lines) and lines[j].startswith("|"):
        rows.append(split_row(lines[j]))
        j += 1
    cells = "".join("<th>%s</th>" % parse_inline(c, errors, ctx) for c in header)
    body = "".join(
        "<tr>%s</tr>" % "".join("<td>%s</td>" % parse_inline(c, errors, ctx) for c in row)
        for row in rows)
    out.append('<div class="tablewrap"><table><thead><tr>%s</tr></thead>'
               "<tbody>%s</tbody></table></div>" % (cells, body))
    return j


def parse_quote(lines, i, out, errors, ctx):
    buf = []
    while i < len(lines) and lines[i].startswith(">"):
        buf.append(lines[i][1:].lstrip())
        i += 1
    paras, cur = [], []
    for l in buf:
        if not l.strip():
            if cur:
                paras.append(cur)
                cur = []
        else:
            cur.append(l)
    if cur:
        paras.append(cur)
    inner = "".join("<p>%s</p>" % parse_inline("\n".join(p), errors, ctx) for p in paras)
    out.append("<blockquote>%s</blockquote>" % inner)
    return i


def parse_fence(lines, i, errors, ctx):
    """フェンスコードを読み、(html, 次の行番号) を返す。未閉鎖は None を返しエラー。"""
    indent = len(FENCE_RE.match(lines[i]).group(1))
    buf = []
    j = i + 1
    while j < len(lines) and not re.match(r"^\s*```\s*$", lines[j]):
        line = lines[j]
        if line[:indent].strip() == "":
            line = line[indent:]
        buf.append(line)
        j += 1
    if j >= len(lines):
        errors.append(f"{ctx}:{i + 1}: 未閉鎖のコードフェンス")
        return None, len(lines)
    return "<pre><code>%s</code></pre>" % esc("\n".join(buf)), j + 1


def parse_list(lines, i, out, errors, ctx):
    """リストブロック。項目 = (indent, ordered, segments)。segment = ('text', 行結合) / ('html', 生成済み)"""
    items = []
    n = len(lines)
    while i < n:
        line = lines[i]
        m = ITEM_RE.match(line)
        if m:
            indent = len(m.group(1))
            ordered = m.group(2) != "-"
            items.append([indent, ordered, [["text", m.group(3)]]])
            i += 1
            continue
        if not items:
            break
        cur = items[-1]
        if not line.strip():
            # 空行: 次の行が項目 or 継続ならリスト続行（段落区切り）、そうでなければ終了
            k = i + 1
            if k < n and (ITEM_RE.match(lines[k])
                          or (lines[k].strip() and len(lines[k]) - len(lines[k].lstrip()) > cur[0])):
                cur[2].append(["break", ""])
                i += 1
                continue
            break
        line_indent = len(line) - len(line.lstrip())
        if line_indent > cur[0]:
            fm = FENCE_RE.match(line)
            if fm:
                rendered, i = parse_fence(lines, i, errors, ctx)
                if rendered is not None:
                    cur[2].append(["html", rendered])
                continue
            if cur[2][-1][0] == "text":
                cur[2][-1][1] += "\n" + line.strip()
            else:
                cur[2].append(["text", line.strip()])
            i += 1
            continue
        break

    res = []
    stack = []  # (indent, tag)
    for indent, ordered, segs in items:
        tag = "ol" if ordered else "ul"
        while stack and stack[-1][0] > indent:
            res.append("</li></%s>" % stack.pop()[1])
        if stack and stack[-1][0] == indent and stack[-1][1] != tag:
            res.append("</li></%s>" % stack.pop()[1])
        if stack and stack[-1][0] == indent:
            res.append("</li><li>")
        else:
            res.append("<%s><li>" % tag)
            stack.append((indent, tag))
        first = True
        for kind, content in segs:
            if kind == "text":
                rendered = parse_inline(content, errors, ctx)
                res.append(rendered if first else "<p>%s</p>" % rendered)
                first = False
            elif kind == "html":
                res.append(content)
                first = False
            # break は段落区切りの印。次の text が <p> になることで表現される
    while stack:
        res.append("</li></%s>" % stack.pop()[1])
    out.append("".join(res))
    return i


def parse_blocks(lines, errors, ctx):
    """[(アンカー|None, ブロック HTML)] を返す。アンカーは見出しブロックのみ持つ（図注入に使う）。"""
    out = []
    i, n = 0, len(lines)
    while i < n:
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        m = HEADING_RE.match(line)
        if m:
            lvl, txt = len(m.group(1)), m.group(2)
            aid = gh_anchor(txt)
            out.append((aid, '<h%d id="%s">%s</h%d>'
                        % (lvl, esc_attr(aid), parse_inline(txt, errors, ctx), lvl)))
            i += 1
            continue
        if FENCE_RE.match(line):
            rendered, i = parse_fence(lines, i, errors, ctx)
            if rendered is not None:
                out.append((None, rendered))
            continue
        if line.startswith("|"):
            tmp = []
            i = parse_table(lines, i, tmp, errors, ctx)
            out.extend((None, s) for s in tmp)
            continue
        if line.startswith(">"):
            tmp = []
            i = parse_quote(lines, i, tmp, errors, ctx)
            out.extend((None, s) for s in tmp)
            continue
        if ITEM_RE.match(line):
            tmp = []
            i = parse_list(lines, i, tmp, errors, ctx)
            out.extend((None, s) for s in tmp)
            continue
        # 不採用構文の混入検知（fail closed）
        if RAWHTML_RE.match(line):
            errors.append(f"{ctx}:{i + 1}: 行頭の生 HTML タグは非対応: {line[:40]!r}")
        if REFDEF_RE.match(line):
            errors.append(f"{ctx}:{i + 1}: 参照リンク定義は非対応: {line[:40]!r}")
        buf = [line]
        j = i + 1
        while j < n and lines[j].strip() and not is_block_start(lines[j]):
            buf.append(lines[j])
            j += 1
        out.append((None, "<p>%s</p>" % parse_inline("\n".join(buf), errors, ctx)))
        i = j
    return out


CSS = """
  :root {
    --bg: #faf9f7; --fg: #24292e; --muted: #6a737d; --card: #ffffff;
    --line: #d4d0c8; --accent: #3b5bdb; --accent-soft: #e7ecfb;
    --ok: #2f7d32; --ok-soft: #e5f2e6; --warn: #b26a00; --warn-soft: #f8edda;
    --err: #c02f2f; --err-soft: #f9e5e5; --ref: #7048a8; --ref-soft: #efe7f8;
    --box: #f2f0ec; --code: #eceae5;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #14161a; --fg: #d8dde3; --muted: #8b949e; --card: #1c2026;
      --line: #3a4048; --accent: #7c96f0; --accent-soft: #232c45;
      --ok: #6dbb71; --ok-soft: #1d2f1e; --warn: #d9a04f; --warn-soft: #33281a;
      --err: #e07575; --err-soft: #382020; --ref: #b394e8; --ref-soft: #2a2138;
      --box: #232830; --code: #262b33;
    }
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--fg);
    font-family: "Hiragino Sans", "Noto Sans JP", "Yu Gothic UI", system-ui, sans-serif;
    line-height: 1.8; font-size: 16px; }
  main { max-width: 900px; margin: 0 auto; padding: 0 20px 80px; }
  header.top { border-bottom: 1px solid var(--line); padding: 22px 0 14px; margin-bottom: 8px;
    display: flex; flex-wrap: wrap; gap: 10px; align-items: center; justify-content: space-between; }
  header.top .crumbs { font-size: 0.9rem; }
  header.top .crumbs a { color: var(--accent); text-decoration: none; }
  header.top .src { font-size: 0.8rem; color: var(--muted); }
  header.top .src a { color: var(--accent); }
  .gen-note { background: var(--accent-soft); border-radius: 8px; padding: 8px 14px;
    font-size: 0.82rem; margin: 14px 0; color: var(--fg); }
  h1 { font-size: 1.55rem; line-height: 1.4; margin: 20px 0 12px; }
  h2 { font-size: 1.25rem; margin: 44px 0 10px; padding-top: 8px; border-top: 1px solid var(--line); }
  h3 { font-size: 1.05rem; margin: 32px 0 8px; }
  p { margin: 10px 0; }
  a { color: var(--accent); }
  code { background: var(--code); padding: 1px 6px; border-radius: 4px;
    font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.85em;
    overflow-wrap: anywhere; }
  pre { background: var(--code); border: 1px solid var(--line); border-radius: 8px;
    padding: 12px 14px; overflow-x: auto; line-height: 1.55; }
  pre code { background: none; padding: 0; font-size: 0.82rem; }
  .tablewrap { overflow-x: auto; margin: 14px 0; }
  table { border-collapse: collapse; width: 100%; font-size: 0.88rem; }
  th, td { border: 1px solid var(--line); padding: 7px 11px; text-align: left; vertical-align: top; }
  th { background: var(--box); white-space: nowrap; }
  td:first-child code { overflow-wrap: normal; }
  blockquote { margin: 14px 0; padding: 4px 16px; border-left: 3px solid var(--accent);
    background: var(--box); border-radius: 0 8px 8px 0; color: var(--muted); }
  ul, ol { margin: 10px 0; padding-left: 26px; }
  li { margin: 5px 0; }
  li p { margin: 8px 0; }
  nav.pager { display: flex; justify-content: space-between; gap: 12px; margin-top: 48px;
    border-top: 1px solid var(--line); padding-top: 14px; font-size: 0.9rem; }
  nav.pager a { color: var(--accent); text-decoration: none; }
  .cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
    gap: 12px; margin: 18px 0; padding: 0; list-style: none; }
  .cards li { background: var(--card); border: 1px solid var(--line); border-radius: 10px;
    padding: 14px 16px; margin: 0; }
  .cards a { font-weight: 600; text-decoration: none; }
  .cards p { color: var(--muted); font-size: 0.85rem; margin: 6px 0 0; }
  img { max-width: 100%; vertical-align: middle; }

  /* 図（tools/spec-figures/ からの注入フラグメント用） */
  .fig { background: var(--card); border: 1px solid var(--line); border-radius: 10px;
    padding: 14px; margin: 18px 0; overflow-x: auto; }
  .fig svg { display: block; min-width: 820px; width: 100%; height: auto; }
  .fig figcaption { color: var(--muted); font-size: 0.85rem; margin-top: 8px; }
  figure { margin: 0; }
  svg text { font-family: "Hiragino Sans", "Noto Sans JP", system-ui, sans-serif; fill: var(--fg); }
  svg .small { font-size: 11px; fill: var(--muted); }
  svg .label { font-size: 13px; }
  svg .strong { font-size: 13px; font-weight: 600; }
  svg .boxtitle { font-size: 14px; font-weight: 700; }
  svg .mono { font-family: ui-monospace, Menlo, monospace; font-size: 11.5px; }
  svg .mono-strong { font-family: ui-monospace, Menlo, monospace; font-size: 12px; font-weight: 700; }
  svg .frame { fill: none; stroke: var(--line); stroke-width: 1.5; rx: 10; }
  svg .box { fill: var(--box); stroke: var(--line); stroke-width: 1; rx: 8; }
  svg .box-accent { fill: var(--accent-soft); stroke: var(--accent); stroke-width: 1.2; rx: 8; }
  svg .box-ok { fill: var(--ok-soft); stroke: var(--ok); stroke-width: 1.2; rx: 8; }
  svg .box-warn { fill: var(--warn-soft); stroke: var(--warn); stroke-width: 1.2; rx: 8; }
  svg .box-err { fill: var(--err-soft); stroke: var(--err); stroke-width: 1.2; rx: 8; }
  svg .box-ref { fill: var(--ref-soft); stroke: var(--ref); stroke-width: 1.2; rx: 8; }
  svg .arrow { stroke: var(--fg); stroke-width: 1.4; fill: none; }
  svg .arrow-dash { stroke: var(--muted); stroke-width: 1.2; stroke-dasharray: 5 4; fill: none; }
"""


def page_shell(title, body):
    return ("<!DOCTYPE html>\n"
            '<html lang="ja">\n<head>\n<meta charset="utf-8">\n'
            '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
            "<title>%s</title>\n<style>%s</style>\n</head>\n<body>\n<main>\n%s\n</main>\n</body>\n</html>\n"
            % (esc(title), CSS, body))


def render_page(idx, slug, desc, errors, figures):
    src = os.path.join(ROOT, SRC_DIR, slug + ".md")
    with open(src, encoding="utf-8") as f:
        lines = f.read().split("\n")
    m = HEADING_RE.match(lines[0]) if lines else None
    title = m.group(2) if m and m.group(1) == "#" else slug
    blocks = parse_blocks(lines, errors, f"{SRC_DIR}/{slug}.md")
    body_md = "".join(inject_figures(blocks, slug, figures, errors))

    prev_a = next_a = ""
    if idx > 0:
        p_slug, _ = PAGES[idx - 1]
        prev_a = '<a href="%s.html">&larr; %s</a>' % (p_slug, esc(p_slug))
    if idx < len(PAGES) - 1:
        n_slug, _ = PAGES[idx + 1]
        next_a = '<a href="%s.html">%s &rarr;</a>' % (n_slug, esc(n_slug))

    header = ('<header class="top">'
              '<span class="crumbs"><a href="../overview.html">技術概観</a> / '
              '<a href="index.html">詳細仕様</a> / %s</span>'
              '<span class="src"><a href="%s">正典（md）を見る</a></span>'
              "</header>" % (esc(slug), esc_attr(canon_href(f"{SRC_DIR}/{slug}.md"))))
    note = ('<p class="gen-note">本ページは <code>%s/%s.md</code>（正典・エージェント向け）から '
            "<code>tools/render-spec.sh</code> で自動生成されている。内容の修正は md 側で行い、"
            "再生成すること。</p>" % (SRC_DIR, slug))
    pager = '<nav class="pager"><span>%s</span><span>%s</span></nav>' % (prev_a, next_a)
    return page_shell("xrev 詳細仕様 — " + title, header + note + body_md + pager)


def render_index():
    cards = "".join(
        '<li><a href="%s.html">%s</a><p>%s</p></li>' % (slug, esc(slug), esc(desc))
        for slug, desc in PAGES)
    body = (
        '<header class="top"><span class="crumbs"><a href="../overview.html">技術概観</a> / 詳細仕様</span>'
        '<span class="src"><a href="%s">正典の索引（md）</a></span></header>'
        % esc_attr(canon_href("references/protocol.md")) +
        "<h1>xrev 詳細仕様（人間向け）</h1>"
        "<p>xrev プロトコルの詳細仕様を人間向けに読みやすく整形したもの。"
        "正典はエージェント向けの <code>references/protocol/</code> 配下の md であり、"
        "本 HTML はそこから <code>tools/render-spec.sh</code> で自動生成される（内容は同一）。</p>"
        '<p>初めて読む場合は、<a href="../overview.html">技術概観（図）</a>で全体を掴んでから '
        '<a href="message-format.html">message-format</a>（送信の仕組み）→ '
        '<a href="delivery-gates.html">delivery-gates</a>（誤配送防止）→ '
        '<a href="exit-codes.html">exit-codes</a>（decision と終了コード）の順が読みやすい。</p>'
        '<ul class="cards">%s</ul>' % cards)
    return page_shell("xrev 詳細仕様（人間向け）", body)


# ── GitHub Pages 用サイトの組み立て（--site）────────────────────────────────
#
# サイトはリポジトリと同じディレクトリ構造で作る（docs/overview.html は
# <サイト>/docs/overview.html）。こうすると手書き HTML と md の既存の相対リンクが
# そのまま解決し、リポジトリ側のファイルを書き換えずに済む。

SITE_SKIP_DIR_NAMES = {"node_modules"}


def site_list_md():
    """サイトに載せる md を repo 相対パスで列挙する（隠しディレクトリと出力先は除く）。"""
    out_abs = os.path.abspath(OUT)
    found = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = sorted(d for d in dirnames
                             if not d.startswith(".")
                             and d not in SITE_SKIP_DIR_NAMES
                             and os.path.abspath(os.path.join(dirpath, d)) != out_abs)
        for name in sorted(filenames):
            if name.endswith(".md"):
                found.append(os.path.relpath(os.path.join(dirpath, name), ROOT))
    return sorted(found)


def render_doc_page(repo_rel, errors):
    """任意の md を 1 ページの HTML にする（サイトモード専用）。"""
    global RESOLVE
    out_rel = site_html_for_md(repo_rel)
    out_dir = os.path.dirname(out_rel)
    RESOLVE = make_site_resolver(os.path.dirname(repo_rel), out_dir)
    with open(os.path.join(ROOT, repo_rel), encoding="utf-8") as f:
        lines = f.read().split("\n")
    m = HEADING_RE.match(lines[0]) if lines else None
    title = m.group(2) if m and m.group(1) == "#" else repo_rel
    body = "".join(h for _, h in parse_blocks(lines, errors, repo_rel))
    header = ('<header class="top">'
              '<span class="crumbs"><a href="%s">技術概観</a> / %s</span>'
              '<span class="src"><a href="%s">GitHub で md を見る</a></span></header>'
              % (esc_attr(os.path.relpath("docs/overview.html", out_dir)),
                 esc(repo_rel), esc_attr(blob_url(repo_rel))))
    return out_rel, page_shell("xrev — " + title, header + body)


def render_site_root():
    """サイト先頭。技術概観へ送るだけの薄いページ（入口の URL を 1 つに保つ）。"""
    return ('<!DOCTYPE html>\n<html lang="ja">\n<head>\n<meta charset="utf-8">\n'
            '<meta http-equiv="refresh" content="0; url=docs/overview.html">\n'
            "<title>xrev</title>\n</head>\n<body>\n"
            '<p><a href="docs/overview.html">xrev 技術概観へ</a></p>\n'
            "</body>\n</html>\n")


def build_site():
    global RESOLVE
    errors = []
    outputs = {"index.html": render_site_root()}

    # 1) 詳細仕様ページ（図つき）。本文リンクはサイト用に解決し直す
    figures = load_figures(errors)
    RESOLVE = make_site_resolver(SRC_DIR, DST_DIR)
    outputs[DST_DIR + "/index.html"] = render_index()
    for idx, (slug, desc) in enumerate(PAGES):
        outputs["%s/%s.html" % (DST_DIR, slug)] = render_page(idx, slug, desc, errors, figures)

    # 2) 手書き HTML（docs/*.html）はリンクだけ書き換えてそのまま載せる
    for dirpath, dirnames, filenames in os.walk(os.path.join(ROOT, "docs")):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        for name in sorted(filenames):
            if not name.endswith(".html"):
                continue
            repo_rel = os.path.relpath(os.path.join(dirpath, name), ROOT)
            if repo_rel.startswith(DST_DIR + "/"):
                continue          # 詳細仕様ページは 1) で生成済み
            with open(os.path.join(ROOT, repo_rel), encoding="utf-8") as f:
                content = f.read()
            outputs[repo_rel] = rewrite_html_links(
                content, os.path.dirname(repo_rel), os.path.dirname(repo_rel),
                errors, repo_rel)

    # 3) 残りの md を 1 ファイル 1 ページで HTML 化
    for repo_rel in site_list_md():
        if site_html_for_md(repo_rel) in outputs:
            continue              # protocol の md は詳細仕様ページが担当
        out_rel, content = render_doc_page(repo_rel, errors)
        outputs[out_rel] = content

    if errors:
        for e in errors:
            print("[render-spec] " + e, file=sys.stderr)
        print("[render-spec] %d 件のエラー。生成を中止します。" % len(errors), file=sys.stderr)
        sys.exit(1)
    for rel, content in sorted(outputs.items()):
        path = os.path.join(OUT, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
    print("[render-spec] サイト %d ページを %s へ生成しました。" % (len(outputs), OUT))


def main():
    if MODE == "site":
        build_site()
        return
    if MODE == "stdin":
        # テスト用: 一時ファイル経由で受けた md を本文 HTML へ変換して stdout に出す（ページ枠なし）
        errors = []
        with open(STDIN_MD, encoding="utf-8") as f:
            blocks = parse_blocks(f.read().split("\n"), errors, "<stdin>")
        if errors:
            for e in errors:
                print("[render-spec] " + e, file=sys.stderr)
            sys.exit(1)
        sys.stdout.write("".join(h for _, h in blocks))
        return
    errors = []
    figures = load_figures(errors)
    outputs = {"index.html": render_index()}
    for idx, (slug, desc) in enumerate(PAGES):
        outputs[slug + ".html"] = render_page(idx, slug, desc, errors, figures)
    if errors:
        for e in errors:
            print("[render-spec] " + e, file=sys.stderr)
        print("[render-spec] %d 件のエラー。生成を中止します。" % len(errors), file=sys.stderr)
        sys.exit(1)
    os.makedirs(OUT, exist_ok=True)
    for name, content in sorted(outputs.items()):
        with open(os.path.join(OUT, name), "w", encoding="utf-8") as f:
            f.write(content)
    print("[render-spec] %d ページを %s へ生成しました。" % (len(outputs), OUT))


main()
PY
rc=$?
[[ -n "$TMPMD" ]] && rm -f "$TMPMD"
exit "$rc"
