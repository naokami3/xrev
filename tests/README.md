# tests

xrev のユニットテスト。**cmux 不要**で、配管の純粋ロジック部分を検証する
（依存は bash + python3 のみ。bats 等の外部フレームワークは使わない）。

## 実行

```bash
bash tests/run.sh            # 全テスト
bash tests/run.sh parse scan # 名前に parse / scan を含むテストだけ
```

失敗が 1 件でもあれば非ゼロ終了する（CI で利用可）。

## 構成

| ファイル | 対象 |
|---------|------|
| `lib.sh` | アサートヘルパ（`assert_eq` / `assert_rc` / `assert_contains` / `json_get` 等） |
| `run.sh` | ランナー（`test_*.sh` を集約実行・集計） |
| `test_parse_review.sh` | `parse-review.sh`: 妥当性検証・severity 集計・blocker 算出・型/enum 検証（config 依存） |
| `test_scan_blocks.sh` | `transport.sh::_scan_review_blocks`: de-wrap・raw_decode 走査・round_id 相関・未完成JSON除外 |
| `test_encode.sh` | `transport.sh::_build_framed_line`/`_detect_content_type`/`_compute_submit_settle`: 1物理行エンコード・トークン衝突回避・content_type 判定 |
| `test_resolve_surface.sh` | `transport.sh::_resolve_surface_from_json`: スピナー正規化・完全/部分/複数一致・surface 限定 |
| `test_review_loop.sh` | `review-loop.sh::_xrev_decide`/`_format_decision`＋ transport スタブ注入による統合 |
| `test_make_adr.sh` | `make-adr.sh`: ADR 連番・出力先解決（引数/env/config/絶対/相対） |
| `test_finalize.sh` | `finalize.sh`: stop_at 解決順・review/commit（一時 git）/pr 経路（fake gh で --draft 検証） |
| `test_hook.sh` | `hooks/user-prompt-submit.sh`: `@xrev` 検知時のみ注入・無ければ沈黙 |
| `test_dev_hooks.sh` | `tools/claude-posttooluse.sh`/`claude-stop.sh`: 構文/JSON チェック・変更検知・ループ防止 |

## テスト容易化のためのリファクタ

cmux/外部副作用と純粋ロジックを分離してある:

- `transport.sh`: 宛先解決の JSON 解析を純粋関数 `_resolve_surface_from_json`（cmux 取得部と分離）に。
- `review-loop.sh`: 終端判定を純粋関数 `_xrev_decide` に抽出。`source` 時は main を実行しない
  （`BASH_SOURCE` ガード）。transport 呼び出しは `XREV_REVIEW_FN` でスタブ注入可能。

cmux 実機を要する送受信の通し確認は別途（`scripts/transport.sh ping` / `resolve` / `review`）。
