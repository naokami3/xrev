# doctor（外部ツール契約の一括診断）

[`../protocol.md`](../protocol.md)（索引）から分割された正典の一部。

**この文書で分かること**:

- doctor の検査項目と ok/warn/fail の基準・exit 契約
- 検出できない既知の限界（フック仕様変更・TUI 文言変更）

### `transport.sh doctor`（外部ツール契約の一括診断）

cmux / Codex / Claude Code のバージョンアップで xrev は壊れるが、壊れ方が「全拒否」「タイムアウト」
「無言沈黙」に化けて原因が読めない。`transport.sh doctor` は外部ツールへの契約仮定を一括検査し、
人間可読な診断を返す。**検査はすべて非変更・再実行可能**（ペイン生成・送信・タイトル変更などの
副作用を持つ検査は含まない）。各検査は独立に実行され、1つの失敗で後続を止めない。

**出力契約**: 1検査1行 `[ok|warn|fail] 検査名: 詳細`（stdout。機械処理より人間可読を優先する）。
最後に `ok=N warn=N fail=N` のサマリ行を出す。

**exit 契約**: `fail` が1件でもあれば `exit 1`。`fail=0`（`warn` のみ含む場合を含む）なら `exit 0`。
`warn` は exit に影響しない。

**検査項目**:

| # | 検査 | ok/warn/fail の基準 |
|---|------|----------------------|
| 1 | python3 | 存在＋バージョン表示=ok / 不在=fail |
| 2 | cmux バイナリ | 存在＋実測検証済み(`0.64.20`)と一致=ok / 存在するがバージョン相違=warn / 不在=fail |
| 3 | cmux 接続 | `_cmux_preflight`（ping）成功=ok / 失敗=fail |
| 4 | env 注入 | `CMUX_SURFACE_ID` 有=ok・無=fail（同一WS解決不可） / `CMUX_WORKSPACE_ID` 有=ok・無=warn |
| 5 | tree 形状 | `_doctor_check_tree_shape` が0=ok / 非0=fail |
| 6 | top 形状 | `_doctor_check_top_shape` が0=ok / 非0=fail |
| 7 | ps 契約 | `printf '%s\n' "$$" \| _ps_snapshot` が `pid pgid tpgid comm` の4フィールドを返す=ok / 崩れ=fail |
| 8 | reviewer 解決 | `_cmux_resolve_surface` が present=ok / absent=warn / それ以外(曖昧・ws不整合・一時障害等)=warn（環境状態の情報であり契約違反ではないため fail にしない） |
| 9 | reviewer バイナリ・launch 引数 | バイナリ存在=ok・不在=warn（`ensure-reviewer` は失敗するが送信検証は前景プロセス名しか見ないため致命ではない） / `_xrev_reviewer_launch_args` 成功=ok・失敗=fail |
| 10 | フック契約セルフテスト | `hooks/user-prompt-submit.sh` に `@xrev` 入り prompt→`additionalContext` を含む出力・無関係 prompt→無出力、の両方を確認=ok / いずれか崩れ=fail |
| - | info | 検出不能な既知の縮退の注意書き。検査ではなく固定の `[info]` 行 |

純粋関数 `_doctor_check_tree_shape`（stdin=`cmux tree --all --json --id-format both` 相当の JSON、
1行診断をstdoutに・exit 0/非0）と `_doctor_check_top_shape`（stdin=`cmux top --all --processes
--format tsv` 相当の TSV、同様の契約）は cmux 非依存の単体テスト対象として切り出してある
（`tests/test_doctor.sh`）。

**検出できないもの（既知の限界）**:

- フック契約セルフテスト（検査10）は「xrev 側の実装が契約どおりか」の検証であり、Claude Code 本体が
  `UserPromptSubmit` のフィールド名やイベント仕様そのものを変えた場合は検出できない。
- Codex TUI の「Pasted Content N chars」文言や cmux のエラー文言（`not a terminal` 等）がバージョン
  アップで変わった場合、doctor では検出できない（固定の `[info]` 行で注意喚起するのみ）。
  `_check_paste_intact` の `unknown` 警告が毎回出るようになったら、この文言変更を疑うこと。
