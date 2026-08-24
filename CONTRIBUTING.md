# コントリビューションガイド

xrev への貢献を歓迎します。以下は設計上の不変条件です。**変更する場合は必ず議論してから**にしてください。

## 守るべき設計原則

1. **cmux 依存は `scripts/transport.sh` だけに閉じ込める。** 他のスクリプト・スキル・フックから
   cmux コマンドを直接叩かない。通信層の差し替え可能性を壊さないこと。
2. **中間ファイルを生成しない。** エージェント間のやり取りはファイルを介さない。意図して残す
   成果物だけが例外: ADR（`docs/adr/`）と、docs/spec/ の生成 HTML（`tools/render-spec.sh` が
   正典 md から生成。最新性は `tools/verify.sh` が検査）。
3. **コアは主従非依存に保つ。** 特定エージェント名（`cc-` 等）をコアやリポジトリ名に固定しない。
   主従は `config` のプリセットで表現する。
4. **暴発させない。** `@xrev`（設定の `keyword`）や明示指示が無いときは完全に沈黙する。
5. **人間の最終チェックを物理的に保証する。** PR は必ずドラフト。非ドラフト PR を作る経路を追加しない。
6. **既定は最も安全な `review`。** 既定で commit / pr へ進めない。
7. **終端は機械的に判定する。** 収束条件（blocker 0 件）と最大反復はスクリプトが決定論的に握る。

## 開発メモ

- スクリプトは bash + python3 のみに依存（`jq` は使わない）。
- 変更後は `bash tests/run.sh`（ユニットテスト・cmux 不要）と `bash -n scripts/*.sh` を実行する。
  純粋ロジックを変えたらテストも追加・更新する（詳細は [`tests/README.md`](tests/README.md)）。
- cmux を要する通信層の通し確認は実機（cmux 上の `Review Codex` ペイン）が必要。
- コメント・コミットメッセージは日本語で記述する。

## テストの強制（多層）

コードの追加・修正時にテストを必ず通すよう、3 層で強制している。共通ゲートは
`tools/verify.sh`（構文チェック + JSON 妥当性 + `tests/run.sh`）。

1. **git pre-commit フック** — `scripts/ hooks/ tools/ config/ tests/` をステージしてコミットすると
   `tools/verify.sh` が走り、失敗ならコミット中止。コードを変えたのにテスト未更新なら注意喚起する。
   - 有効化（クローン後に一度）: `bash tools/install-hooks.sh`（`core.hooksPath=.githooks` を設定）。
   - 緊急回避: `git commit --no-verify`（CI は回避できない）。
2. **CI（GitHub Actions）** — `.github/workflows/ci.yml` が push / PR で `tools/verify.sh` を実行する
   越えられないゲート。
3. **Claude Code フック** — `.claude/settings.json`:
   - PostToolUse（Edit/Write）で編集した `.sh` の構文・`.json` の妥当性を即時チェック。
   - Stop で、監視対象に変更があるとき `tools/verify.sh` を実行し、失敗なら終了前に差し戻す
     （`stop_hook_active` で無限ループを防止）。

## コミット境界

- 1 コミット = 1 つの論理的変更。レビュー指摘の修正は元の変更にまとめ、別コミットにしない。

## 実装パターン雛形（サブエージェントへの作業指示に同梱する）

このリポジトリ特有の落とし穴と、その canonical な回避パターン。エージェントに実装を委譲する
ときは「参照せよ」ではなく**この雛形ごと指示書に貼る**こと（参照指示は読解と試行錯誤のコストを
実装側に転嫁し、実測で修正ラウンドを大きく膨らませた）。

### bash 3.2（macOS 既定）で python プログラムを変数化する

`prog="$(cat <<'PY' ... PY)"` は**使わない**。bash 3.2 は `$(...)` の閉じ括弧探索がヒアドキュメント
本文中の不均衡な括弧・引用符で誤爆する。必ず次の形にする:

```bash
local prog
read -r -d '' prog <<'PY' || true
import sys
# ...本文（括弧・引用符が不均衡でも安全）...
PY
python3 -c "$prog" "$arg1"
```

### 巨大データは stdin で渡す（env/argv 禁止）

env/argv には 1 本あたり約 128KiB（Linux の MAX_ARG_STRLEN）の上限がある。payload・diff・
依頼文など大きくなり得るデータは必ず stdin で渡す。`python3 - <<'PY'` はプログラム本文が
stdin を占有するため、データも stdin で受けたい場合は上記の `read -r -d ''` + `python3 -c` を使う
（実例: `_build_framed_line` / `scripts/keyword-match.sh`）。

### 数値 env/config は `_xrev_uint` を通してから算術式へ

bash 算術 `(( ))` は `x[$(コマンド)]` 形式の値でコマンド実行を許す。env/config 由来の数値は
必ず `_xrev_uint <値> <最小> <最大> <既定> <名前>`（transport.sh）で検証してから使う。

### テストの流儀

- cmux を叩かない（`tests/` は cmux 不要が規約）。cmux 呼び出しはスタブ関数で置き換える
  （既存の `tests/test_send*.sh` の流儀に合わせる）。
- スタブに置き換えた統合テストには、**実物コンポーネントを使う最小ケースを必ず 1 本併設**する
  （実測: スタブ化した `_build_framed_line` の実出力長がテスト値の約 5 倍で、本番経路が全拒否になる
  欠陥をレビューまで検出できなかった）。
- スタブは stdin を読み切ってから応答する（読まないと SIGPIPE で flake する）。mktemp は
  `-t` の明示テンプレート形式で GNU/BSD 両対応にする。PATH を絞るテストは `/bin` 依存を避ける。
