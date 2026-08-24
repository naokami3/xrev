#!/usr/bin/env bash
#
# test_render_spec.sh — tools/render-spec.sh（詳細仕様 HTML 生成器）の単体テスト。
#
# --render-stdin モードで構文ごとの変換（エスケープ・リンク再計算・アンカー生成）と
# fail closed 条件（未閉鎖フェンス・表セパレータ欠落・リンク閉じ括弧欠落・許可外スキーム・
# 不採用構文の混入）を検証し、実コーパスに対しては生成の成功と決定性を確認する。

RS="$XREV_ROOT/tools/render-spec.sh"

# ── コンテキスト別エスケープ ────────────────────────────────────────────────

out="$(printf '%s' 'a <b> & "q" のテキスト' | bash "$RS" --render-stdin)"
assert_contains "テキストの < > がエスケープされる" "$out" "&lt;b&gt;"
assert_contains "テキストの & がエスケープされる" "$out" "&amp;"

out="$(printf '%s' '`**not bold** <tag>`' | bash "$RS" --render-stdin)"
assert_contains "コードスパン内は記法を解釈せずエスケープのみ" "$out" "<code>**not bold** &lt;tag&gt;</code>"

out="$(printf '%s' '## 見出し <X> と `code`' | bash "$RS" --render-stdin)"
assert_contains "見出し内もテキストエスケープ" "$out" "&lt;X&gt;"

out="$(printf '%s' '[x](a"b.md)' | bash "$RS" --render-stdin)"
assert_contains "href 属性内の引用符がエスケープされる" "$out" "&quot;"
assert_not_contains "href 属性に生の引用符が残らない" "$out" 'href="../../references/protocol/a"b.md"'

out="$(printf '%s' '**強調と`code`の入れ子**' | bash "$RS" --render-stdin)"
assert_contains "強調内のコードスパン" "$out" "<strong>強調と<code>code</code>の入れ子</strong>"

# 二重エスケープが起きない（& を含むコード）
out="$(printf '%s' '`a && b`' | bash "$RS" --render-stdin)"
assert_contains "コード内の & は一重エスケープ" "$out" "<code>a &amp;&amp; b</code>"
assert_not_contains "二重エスケープしない" "$out" "&amp;amp;"

# ── リンク再計算 ────────────────────────────────────────────────────────────

out="$(printf '%s' '[終了コード](exit-codes.md)' | bash "$RS" --render-stdin)"
assert_contains "spec 内の .md リンクは .html へ" "$out" 'href="exit-codes.html"'

out="$(printf '%s' '[a](reference-mode.md#x)' | bash "$RS" --render-stdin)"
assert_contains "spec 内リンクのアンカーは維持" "$out" 'href="reference-mode.html#x"'

out="$(printf '%s' '[実測](../../docs/cmux-behavior.md)' | bash "$RS" --render-stdin)"
assert_contains "spec 外への相対リンクは docs/spec/ 基点へ再計算" "$out" 'href="../cmux-behavior.md"'

out="$(printf '%s' '[索引](../protocol.md)' | bash "$RS" --render-stdin)"
assert_contains "references 直下へのリンクの再計算" "$out" 'href="../../references/protocol.md"'

out="$(printf '%s' '[issue](https://example.com/a)' | bash "$RS" --render-stdin)"
assert_contains "https スキームは許可" "$out" 'href="https://example.com/a"'

printf '%s' '[x](javascript:alert(1))' | bash "$RS" --render-stdin >/dev/null 2>&1
assert_rc "javascript: スキームは拒否（非ゼロ）" 1 "$?"

printf '%s' '[x](http://example.com/)' | bash "$RS" --render-stdin >/dev/null 2>&1
assert_rc "http: スキームも拒否（https のみ許可）" 1 "$?"

printf '%s' '[x](//evil.example/x)' | bash "$RS" --render-stdin >/dev/null 2>&1
assert_rc "スキーム相対 URL（//）も拒否" 1 "$?"

printf '%s' '[x](/etc/passwd)' | bash "$RS" --render-stdin >/dev/null 2>&1
assert_rc "絶対パスの href は拒否" 1 "$?"

printf '%s' '[x](..\\..\\win)' | bash "$RS" --render-stdin >/dev/null 2>&1
assert_rc "バックスラッシュを含む href は拒否" 1 "$?"

printf '%s' '[x](../../../etc/passwd)' | bash "$RS" --render-stdin >/dev/null 2>&1
assert_rc "正規化後にリポジトリ外へ出る href は拒否" 1 "$?"

# ── 見出しアンカー ──────────────────────────────────────────────────────────

out="$(printf '%s' '## わたしの 見出し' | bash "$RS" --render-stdin)"
assert_contains "GitHub 互換 id が付く" "$out" '<h2 id="わたしの-見出し">'

out="$(printf '%s' '### `transport.sh doctor`（外部ツール契約の一括診断）' | bash "$RS" --render-stdin)"
assert_contains "記号を除去した id 生成" "$out" 'id="transportsh-doctor外部ツール契約の一括診断"'

# ── ブロック構文 ────────────────────────────────────────────────────────────

out="$(printf '| a | b |\n|---|---|\n| c\\| d | e |\n' | bash "$RS" --render-stdin)"
assert_contains "表ヘッダは th になる" "$out" "<th>a</th>"
assert_contains "エスケープされたパイプはセル内に残る" "$out" "<td>c| d</td>"

out="$(printf '> 引用です\n' | bash "$RS" --render-stdin)"
assert_contains "引用は blockquote になる" "$out" "<blockquote><p>引用です</p></blockquote>"

out="$(printf -- '- 親\n  - 子\n- 親2\n' | bash "$RS" --render-stdin)"
assert_contains "ネストした箇条書き" "$out" "<ul><li>親<ul><li>子</li></ul></li><li>親2</li></ul>"

out="$(printf '1. 一\n2. 二\n' | bash "$RS" --render-stdin)"
assert_contains "番号付きリスト" "$out" "<ol><li>一</li><li>二</li></ol>"

out="$(printf -- '- 項目\n\n  \x60\x60\x60\n  code\n  \x60\x60\x60\n' | bash "$RS" --render-stdin)"
assert_contains "リスト項目内のインデント付きフェンス" "$out" "<pre><code>code</code></pre>"

out="$(printf -- '- 項目\n\n  続きの段落\n' | bash "$RS" --render-stdin)"
assert_contains "項目内の段落区切りは p になる" "$out" "<p>続きの段落</p>"

# ── fail closed 条件 ────────────────────────────────────────────────────────

printf '```\ncode\n' | bash "$RS" --render-stdin >/dev/null 2>&1
assert_rc "未閉鎖フェンスは非ゼロ" 1 "$?"

printf '| a | b |\n| c | d |\n' | bash "$RS" --render-stdin >/dev/null 2>&1
assert_rc "表セパレータ欠落は非ゼロ" 1 "$?"

printf '%s' '[label](exit-codes.md' | bash "$RS" --render-stdin >/dev/null 2>&1
assert_rc "リンクの閉じ括弧欠落は非ゼロ" 1 "$?"

printf '%s' '<div>x</div>' | bash "$RS" --render-stdin >/dev/null 2>&1
assert_rc "行頭の生 HTML は非ゼロ" 1 "$?"

printf '%s' '![x](http://example.com/a.png)' | bash "$RS" --render-stdin >/dev/null 2>&1
assert_rc "画像 src の許可外スキームは非ゼロ" 1 "$?"

printf '%s' '[ref]: https://example.com/' | bash "$RS" --render-stdin >/dev/null 2>&1
assert_rc "参照リンク定義は非ゼロ" 1 "$?"

# ── 画像（README の CI バッジを載せるために必要） ──────────────────────────

out="$(printf '%s' '![図](a.png)' | bash "$RS" --render-stdin)"
assert_contains "画像は img になり src はリンクと同じ規則で再計算される" "$out" \
  '<img src="../../references/protocol/a.png" alt="図">'

out="$(printf '%s' '[![CI](https://ex.test/b.svg)](https://ex.test/w)' | bash "$RS" --render-stdin)"
assert_contains "画像を label に持つリンク（バッジ）を入れ子のまま扱える" "$out" \
  '<a href="https://ex.test/w"><img src="https://ex.test/b.svg" alt="CI"></a>'

out="$(printf '%s' '![a"b<c](x.png)' | bash "$RS" --render-stdin)"
assert_contains "alt は属性値としてエスケープされる" "$out" 'alt="a&quot;b&lt;c"'

out="$(printf '%s' '感嘆符! は素通し' | bash "$RS" --render-stdin)"
assert_contains "画像でない ! はテキストのまま" "$out" "感嘆符! は素通し"

# ── 図フラグメント注入（allowlist 検証・fail closed） ───────────────────────

_frag_ok='<figure class="fig"><svg viewBox="0 0 100 50" role="img" aria-labelledby="tf1"><title id="tf1">テスト図</title><defs><marker id="m1" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" fill="var(--fg)"/></marker></defs><rect x="1" y="1" width="40" height="20" class="box"/><path class="arrow" d="M 45 10 H 90" marker-end="url(#m1)"/><text x="5" y="15" class="small">t</text></svg><figcaption>説明 <a href="../cmux-behavior.md">実測</a></figcaption></figure>'

_render_with_frag() {
  # $1=フラグメントファイル名 $2=フラグメント内容。生成の rc を返す。
  local fdir odir rc
  fdir="$(mktemp -d "${TMPDIR:-/tmp}/xrev-figs.XXXXXX")"
  odir="$(mktemp -d "${TMPDIR:-/tmp}/xrev-figout.XXXXXX")"
  printf '%s' "$2" > "$fdir/$1"
  bash "$RS" --out "$odir" --figures "$fdir" >/dev/null 2>&1
  rc=$?
  _frag_last_out="$odir"
  rm -rf "$fdir"
  return "$rc"
}

_render_with_frag "doctor--intro--01.html" "$_frag_ok"
assert_rc "正常なフラグメント（marker-end url(#) / 相対 href / class のみ）は受理" 0 "$?"
assert_contains "図が対象ページの H1 直後に注入される" "$(cat "$_frag_last_out/doctor.html")" 'title id="tf1"'
rm -rf "$_frag_last_out"

_render_with_frag "doctor--intro--01.html" '<figure class="fig"><svg role="img"><title>x</title><rect onclick="alert(1)"/></svg></figure>'
assert_rc "onclick 等のイベント属性は拒否" 1 "$?"; rm -rf "$_frag_last_out"

_render_with_frag "doctor--intro--01.html" '<figure class="fig"><svg role="img"><title>x</title><script>1</script></svg></figure>'
assert_rc "script 要素は拒否" 1 "$?"; rm -rf "$_frag_last_out"

_render_with_frag "doctor--intro--01.html" '<figure class="fig"><svg role="img"><title>x</title><foreignObject width="1" height="1"></foreignObject></svg></figure>'
assert_rc "foreignObject は拒否" 1 "$?"; rm -rf "$_frag_last_out"

_render_with_frag "doctor--intro--01.html" '<figure class="fig"><svg role="img"><title>x</title></svg><figcaption><a href="javascript:alert(1)">x</a></figcaption></figure>'
assert_rc "a の href=javascript: は拒否" 1 "$?"; rm -rf "$_frag_last_out"

_render_with_frag "doctor--intro--01.html" '<figure class="fig"><svg role="img"><title>x</title><rect fill="url(https://evil.example/x)"/></svg></figure>'
assert_rc "属性値の外部 url() は拒否" 1 "$?"; rm -rf "$_frag_last_out"

_render_with_frag "doctor--intro--01.html" '<figure class="fig"><svg role="img"><title>x</title><rect style="fill:red"/></svg></figure>'
assert_rc "style 属性は拒否" 1 "$?"; rm -rf "$_frag_last_out"

_render_with_frag "doctor--intro--01.html" '<figure class="fig"><svg role="img"><title>x</title></svg></figure><p>2つ目のルート</p>'
assert_rc "figure 以外のルート要素が並ぶと拒否" 1 "$?"; rm -rf "$_frag_last_out"

_render_with_frag "doctor--intro--01.html" '<span><svg role="img"><title>x</title></svg></span>'
assert_rc "ルートが figure でないと拒否" 1 "$?"; rm -rf "$_frag_last_out"

_render_with_frag "doctor--intro--01.html" '<figure class="fig"><svg viewBox="0 0 10 10"><title>x</title></svg></figure>'
assert_rc "svg に role=img が無いと拒否" 1 "$?"; rm -rf "$_frag_last_out"

_render_with_frag "doctor--intro--01.html" '<figure class="fig"><svg role="img"><rect x="1"/></svg></figure>'
assert_rc "svg に title が無いと拒否" 1 "$?"; rm -rf "$_frag_last_out"

_render_with_frag "doctor--intro--01.html" '<figure class="fig"><svg role="img"><title>x</title></svg><svg viewBox="0 0 1 1"><rect x="1"/></svg></figure>'
assert_rc "複数 svg のうち 1 つでも role/title を欠くと拒否（状態を混ぜない）" 1 "$?"; rm -rf "$_frag_last_out"

_render_with_frag "doctor--intro--01.html" '<figure class="fig"><svg role="img"><title>x</title></svg><figcaption><a href="../../../etc/passwd">x</a></figcaption></figure>'
assert_rc "フラグメント href のリポジトリ外脱出は拒否" 1 "$?"; rm -rf "$_frag_last_out"

_render_with_frag "doctor--intro.html" "$_frag_ok"
assert_rc "連番 NN の無いファイル名は拒否" 1 "$?"; rm -rf "$_frag_last_out"

_render_with_frag "unknown-page--intro--01.html" "$_frag_ok"
assert_rc "未知 slug のファイル名は拒否" 1 "$?"; rm -rf "$_frag_last_out"

_render_with_frag "doctor--そんな見出しは無い--01.html" "$_frag_ok"
assert_rc "実在しないアンカー指定は拒否" 1 "$?"; rm -rf "$_frag_last_out"

# ── 実コーパスの生成と決定性 ────────────────────────────────────────────────

d1="$(mktemp -d "${TMPDIR:-/tmp}/xrev-render-a.XXXXXX")"
d2="$(mktemp -d "${TMPDIR:-/tmp}/xrev-render-b.XXXXXX")"
bash "$RS" --out "$d1" >/dev/null 2>&1
assert_rc "実コーパス（references/protocol/*.md）の生成が成功する" 0 "$?"
n="$(ls "$d1"/*.html 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "index + 8 ページ = 9 ファイル生成される" 9 "$n"
assert_contains "各ページに正典への注記が入る" "$(cat "$d1/message-format.html")" "自動生成"
bash "$RS" --out "$d2" >/dev/null 2>&1
diff -r "$d1" "$d2" >/dev/null 2>&1
assert_rc "生成は決定的（2 回の出力が一致）" 0 "$?"
rm -rf "$d1" "$d2"

# ── GitHub Pages 用サイトの組み立て（--site） ───────────────────────────────

sdir="$(mktemp -d "${TMPDIR:-/tmp}/xrev-site.XXXXXX")"
bash "$RS" --site "$sdir" --repo-url "https://ex.test/o/r" --ref v9 >/dev/null 2>&1
assert_rc "サイトの組み立てが成功する（リンク切れがあれば非ゼロ）" 0 "$?"

assert_contains "サイト先頭は技術概観へ送る" "$(cat "$sdir/index.html")" \
  'url=docs/overview.html'

# リポジトリと同じ構造で並べることで、手書き HTML の既存の相対リンクがそのまま解決する
ov="$(cat "$sdir/docs/overview.html")"
assert_contains "手書き HTML の md リンクはサイト内の html を指す" "$ov" 'href="../README.html"'
assert_contains "protocol の md リンクは詳細仕様ページへ寄せる" "$ov" 'href="spec/config.html"'
assert_not_contains "手書き HTML に .md リンクが残らない" "$ov" '.md"'

[[ -e "$sdir/references/protocol/config.html" ]]
assert_rc "protocol の md は二重にページ化しない（詳細仕様ページが担当）" 1 "$?"

rd="$(cat "$sdir/README.html")"
assert_contains "md はページ化され docs 配下へのリンクも html になる" "$rd" \
  'href="docs/cmux-integration.html"'
assert_contains "サイトに載せないファイルは GitHub のソースへ送る" "$rd" \
  'href="https://ex.test/o/r/blob/v9/llms.txt"'
assert_contains "README の CI バッジ画像が入る" "$rd" '<img src="https://github.com/'

assert_contains "詳細仕様の「正典（md）を見る」は GitHub のソースへ" \
  "$(cat "$sdir/docs/spec/doctor.html")" \
  'href="https://ex.test/o/r/blob/v9/references/protocol/doctor.md"'
rm -rf "$sdir"
