# ロードマップ

xrev のフェーズと進捗。詳細な設計は [architecture.md](architecture.md)、仕様は
[`../references/protocol.md`](../references/protocol.md) を参照。

## フェーズ 1: コアエンジン ✅ 完了

- [x] 通信層抽象 `transport.sh`（cmux 依存の局所化・宛先解決・送信・応答検出・preflight）
- [x] レビュー出力のパースと severity 集計 `parse-review.sh`（jq 非依存）
- [x] 状態機械 `review-loop.sh`（1 ラウンド実行＋終端の機械判定・decision 返却）
- [x] 完了アクション分岐 `finalize.sh`（review / commit / ドラフト PR）
- [x] ADR 生成 `make-adr.sh`（往復ログ → `docs/adr/ADR-NNN.md`）

## フェーズ 2: プラグイン統合 ✅ 完了

- [x] 中核プレイブック `skills/xrev/SKILL.md`
- [x] `@xrev` 検知フック `hooks/user-prompt-submit.sh`（キーワード無しでは沈黙）
- [x] フォールバックコマンド `commands/xrev.md`（`/xrev`）
- [x] プラグインメタ `plugin.json`
- [x] 完了アクション `stop_at` を 3 段階（引数 / env / config）で設定可能化
- [x] ADR の必要有無・出力ディレクトリを設定可能化

## フェーズ 3: 配布 ✅ 完了

- [x] マーケットプレイス配布対応（同一リポジトリ兼用 `marketplace.json`、`/plugin` で導入可能）
- [x] GitHub `naokami3/xrev` へ push 済み

## フェーズ 4: 実機検証 ✅ 完了

- [x] cmux ペイン内での通信層検証（接続 preflight）
- [x] 宛先解決（`tree --all`、スピナー等の装飾タイトルの正規化）
- [x] 送信（本文一括送信＋Enter 分離）
- [x] 応答検出（round_id 相関・全画面 de-wrap → raw_decode 走査）
- [x] `review-loop` の decision 分岐（approve → converged / request_changes(high) → continue）
- [x] 実機検証で判明した不具合の修正（list 範囲 → tree --all / タイトル装飾の正規化 /
      多バイト変数展開 / 空送信ガード / エコーの早期終了・古応答の誤検出 /
      TUI 折り返し＋ガター字下げの de-wrap）
- [x] ユニットテスト整備（`tests/`、純粋ロジックの回帰防止・cmux 不要）
- [x] **実際の Codex 対話セッションでの最終確認**
      - [x] Codex TUI が複数行プロンプトを受理する（送信成立）
      - [x] センチネル囲みのスキーマ準拠 JSON を返し、TUI 折り返しを de-wrap して安定取得できる
      - [x] 送信 → 検出 → parse → decision(continue) まで end-to-end 成立

## フェーズ 5: 主従反転プリセット（primary=codex / reviewer=claude）

コアの主従非依存（設計原則3）を実際に別プリセットとして具体化した。詳細設計・実測知見は
[cmux-behavior.md](cmux-behavior.md) の実測知見節、契約は
[`../references/protocol.md`](../references/protocol.md) を参照。

- [x] reviewer バイナリ解決の一般化（`_xrev_reviewer_bin`。`XREV_REVIEWER_BIN` 新設・
      `XREV_CODEX_BIN` は reviewer=codex 限定の後方互換エイリアス）
- [x] 送信完全性検証の reviewer 種別対応・fail closed（codex=ペースト文字数照合 /
      claude=実装フェーズは参照モード必須（inline の全文一致照合は実測上、実運用サイズで常に
      `exit 28` になるため）/ 未知種別は `exit 28`）
- [x] プリセット config `config/xrev.codex-primary.json`（primary=codex / reviewer=claude /
      reviewer_pane_title="Review Claude"）
- [x] keyword 判定の単一真実源化 `scripts/keyword-match.sh`（hook・プレイブック・スニペットが共有）
- [x] codex 主プレイブック `references/codex-primary-playbook.md` と `AGENTS.md` の整理
- [x] 導入スニペット出力 `scripts/print-agents-snippet.sh`（ファイル生成せず stdout 出力）
- [x] 実測 R1〜R6（claude reviewer の cmux ペイン内挙動: プロセス同定・ペースト畳み・
      composer クリア・タブタイトル・出力契約遵守・de-wrap 互換）

実機 e2e（2026-07-27 実施）:

- [x] `--append-global` を実 `~/.codex/AGENTS.md` へ導入（未作成の初回導入経路・マーカー 2 個・
      冪等性・ロック解放を実地確認）
- [x] 別プロジェクトの codex がグローバル AGENTS.md 経由で xrev を認識する（`codex exec` で
      発火スクリプト・手順書・XREV_PRIMARY の 3 点を正答）
- [x] codex 自身が primary として反復レビューを完走する（2026-07-27 実運用で確認。あわせて
      「サンドボックスのソケット遮断」「export 非持続」「reviewer 応答の 180 秒タイムアウト不足」
      が判明し、それぞれ playbook/スニペット修正と既定 600 秒への変更で対処済み）
- [x] xrev の checkout 消滅時、スニペットの前提検査が明確な診断で失敗する
- [x] claude reviewer との実機往復 e2e（`XREV_PRIMARY=codex` の auto 解決で `Review Claude` を
      ensure-reviewer 生成 → 参照モードで 1 往復 converged/approve。reviewer は diff_hash/HEAD を
      正しく返し、実 diff への適切な指摘も返した）
- [x] 新コードの実機動作確認（auto 解決の双方向・矛盾ゲート exit 29 の副作用前拒否・
      送信ゲート一式のスモーク往復。この過程でセッション復元による read-only 喪失を
      exit 27 が捕捉する実例を確認 → [cmux-behavior.md](cmux-behavior.md) 10節）

## フェーズ 6: reviewer の auto 解決・グローバル一度きり導入 ✅ 完了

主従反転の入口を「プリセット config を明示指定する」方式から「入口で primary を自己申告するだけで
reviewer が自動解決される」方式へ簡素化した。プリセット config は値を明示的に固定したい場合の任意
選択肢として残る。詳細設計は本ドキュメントと [protocol.md](../references/protocol.md) を参照。

- [x] **D1: reviewer の auto 解決**（`_xrev_resolve_reviewer`。優先順 `XREV_REVIEWER` > config の
      明示値 > auto=primary の相手方）。**semantic kind**（解決済み reviewer 名）を安全ポリシー
      検証・送信完全性方式・launch 引数選択・composer クリア方式の唯一の種別判定源にする
      （旧来の「kind = 前景プロセス名の basename」定義を置き換え）。派生3キー
      （`reviewer_pane_title`/`reviewer_process`/`reviewer_reads_workspace`）の既定を `auto` 化。
      明示値との種別矛盾は送信前に `exit 29`（`reviewer_config_conflict`）で fail closed。
      既定 config での後方互換同値・主従反転プリセットとの等価性をテストで固定。
- [x] **D2: 入口の自己申告と質問規則**（`XREV_PRIMARY`/`XREV_REVIEWER` を SKILL.md / codex 主
      プレイブックへ追記。reviewer の明示指定は質問せず正規の上書きとして扱い、意図が一意に
      読めない場合のみ一拍確認で質問する）。
- [x] **D3: print-agents-snippet.sh のグローバル導入化**（`--append-global`。対象は
      `$CODEX_HOME/AGENTS.md`。R7 実測で codex がこれを読み込むことを確認済み。symlink/既存
      ファイル/初回導入の3経路収束・排他ロック（自己解放・待機なしという ensure-reviewer との
      契約差）・マーカー `<!-- xrev:snippet:BEGIN/END -->` による冪等な追記/置換・mv 直前の
      内容再検証。per-project 貼り付け前提の記述は README/playbook から撤去）。
- [x] R7: codex のグローバル AGENTS.md 読込を実測で確認（一時 `CODEX_HOME` + `codex exec`。
      マーカー有無での正例・対照例の両方で裏取り）。

## 将来の検討事項

- `transport` 実装の差し替え（`codex exec` 方式・別エージェント等）
- 生成直後ペインへの初回送信失敗（[cmux-behavior.md](cmux-behavior.md) 9節）の恒久対策:
  ensure-reviewer の起動確認直後に捨て送信を 1 回挟む / 初回のみ settle 延長。
  **実装前に実機で複数回の裏取りが必要**（現状は round_state 引き継ぎの再試行で運用対処）。
- claude composer クリアの 0x08 一括送信量（現在固定 4000）の実機妥当性検証。
