# レビュー契約（severity・verdict・act ラベル）

[`../protocol.md`](../protocol.md)（索引）から分割された正典の一部。

**この文書で分かること**:

- どの severity が blocker で、収束をどう機械判定するか
- verdict の位置づけ（収束判定には使わない）
- act ラベルの語彙と会話終端の規則（think に追撃しない / close に返信しない）

## 2. severity と verdict

| severity   | blocker か | 往復での扱い |
|------------|-----------|--------------|
| `critical` | yes       | 0 件になるまで反映（収束条件） |
| `high`     | yes       | 同上 |
| `medium`   | no        | 1〜2 周のみ反映、以降は無視して収束扱い |
| `low`      | no        | 任意。収束を妨げない |
| `nit`      | no        | 任意 |

- blocker の集合は `config/xrev.default.json` の `severity_blockers` で定義（既定 `["critical","high"]`）。
- `verdict` は `approve` / `request_changes`。収束判定は verdict ではなく **blocker 件数**で機械的に行う
  （`blockers == 0` で収束）。verdict は人間向けの要約として保持する。

## 3. act ラベル（会話終端の思想）

`cmux-bridge` 等の知見に倣い、AI 同士の無限相槌を避けるため、各メッセージの意図をラベルで捉える。
xrev では severity/verdict による機械判定を主とするが、運用上の指針として次を踏襲する:

| act       | 意味             | 返信の扱い |
|-----------|------------------|------------|
| `propose` | 変更を提案        | レビュー対象 |
| `react`   | 指摘・反応        | 反映して次へ |
| `decide`  | 最終決定          | 確定（ADR の Decision に対応） |
| `think`   | 熟考中            | **追撃しない**（待つ） |
| `close`   | 議論終端          | **返信しない**（相槌も送らない） |

要点: **`think` には追撃しない / `close` には返信しない**。これが AI 同士の無限ループを防ぐ。
