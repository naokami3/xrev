#!/usr/bin/env bash
# プラグインメタデータ（plugin.json / marketplace.json / hooks.json / SKILL.md）の
# スキーマ厳格化耐性テスト。cmux 不要・純粋な静的検証。

PLUGIN_JSON="$XREV_ROOT/.claude-plugin/plugin.json"
MARKETPLACE_JSON="$XREV_ROOT/.claude-plugin/marketplace.json"
HOOKS_JSON="$XREV_ROOT/hooks/hooks.json"
SKILL_MD="$XREV_ROOT/skills/xrev/SKILL.md"

# ── 1) plugin.json と marketplace.json の version が一致すること（二重管理のドリフト検出） ──
plugin_version="$(python3 -c 'import json;print(json.load(open("'"$PLUGIN_JSON"'"))["version"])')"
marketplace_version="$(python3 -c '
import json
d = json.load(open("'"$MARKETPLACE_JSON"'"))
print(d["plugins"][0]["version"])')"
assert_eq "plugin.json と marketplace.json の version が一致する" "$plugin_version" "$marketplace_version"

# ── 2) hooks.json が JSON として妥当で、UserPromptSubmit に matcher キーが無いこと ──
python3 -m json.tool "$HOOKS_JSON" >/dev/null 2>&1
assert_rc "hooks.json は妥当な JSON" 0 "$?"

has_matcher="$(python3 -c '
import json
d = json.load(open("'"$HOOKS_JSON"'"))
entries = d.get("hooks", {}).get("UserPromptSubmit", [])
print("yes" if any("matcher" in e for e in entries) else "no")')"
assert_eq "UserPromptSubmit エントリに matcher キーが無い" "no" "$has_matcher"

# ── 3) SKILL.md の allowed-tools 行がカンマ区切り形式であること ──
allowed_line="$(grep '^allowed-tools:' "$SKILL_MD")"
if [[ "$allowed_line" =~ ^allowed-tools:\ [A-Za-z0-9_]+(,\ [A-Za-z0-9_]+)*$ ]]; then
  assert_eq "allowed-tools 行はカンマ区切り形式" "match" "match"
else
  assert_eq "allowed-tools 行はカンマ区切り形式" "match" "$allowed_line"
fi

# ── 4) hooks.json の command が ${CLAUDE_PLUGIN_ROOT} を参照していること（変数名タイポ検出） ──
commands="$(python3 -c '
import json
d = json.load(open("'"$HOOKS_JSON"'"))
out = []
for entries in d.get("hooks", {}).values():
    for e in entries:
        for h in e.get("hooks", []):
            out.append(h.get("command", ""))
print("\n".join(out))')"
all_ref_root="yes"
while IFS= read -r cmd; do
  [[ -z "$cmd" ]] && continue
  [[ "$cmd" == *'${CLAUDE_PLUGIN_ROOT}'* ]] || all_ref_root="no"
done <<< "$commands"
assert_eq "hooks.json の command は \${CLAUDE_PLUGIN_ROOT} を参照する" "yes" "$all_ref_root"
