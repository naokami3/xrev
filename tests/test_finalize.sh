#!/usr/bin/env bash
# finalize.sh のテスト（到達点 stop_at の解決順と review/commit/pr 経路）。
# commit は一時 git リポジトリで実コミットまで検証。pr は gh を呼ぶ前のタイトル必須で経路を判定。

export XREV_CONFIG="$DEFAULT_CONFIG"
FN="$SCRIPTS/finalize.sh"

# review（既定）: メッセージを出し rc 0、リポジトリは書き換えない
out="$("$FN" review 2>&1)"; rc=$?
assert_rc "review は rc=0" 0 "$rc"
assert_contains "review はその旨を表示" "$out" "stop_at=review"

# 引数なし・env なし・config(review) → review に解決
out="$("$FN" 2>&1)"; rc=$?
assert_contains "既定解決は review" "$out" "stop_at=review"

# env で commit に解決（メッセージ未指定なので commit 経路でエラー＝経路に入った証拠）
out="$(XREV_STOP_AT=commit "$FN" 2>&1)"; rc=$?
assert_rc "XREV_STOP_AT=commit は commit 経路へ(rc1)" 1 "$rc"
assert_contains "commit 経路: メッセージ必須エラー" "$out" "コミットメッセージが必要"

# 引数が env より優先（arg=pr > env=commit）→ pr 経路（タイトル必須エラー）
out="$(XREV_STOP_AT=commit "$FN" pr 2>&1)"; rc=$?
assert_contains "引数 pr が env commit より優先" "$out" "PR タイトルが必要"

# config で pr に解決（一時 config）
tmpcfg="$(mktemp)"; python3 -c 'import json;d=json.load(open("'"$DEFAULT_CONFIG"'"));d["stop_at"]="pr";json.dump(d,open("'"$tmpcfg"'","w"))'
out="$(XREV_CONFIG="$tmpcfg" "$FN" 2>&1)"; rc=$?
assert_contains "config stop_at=pr は pr 経路へ" "$out" "PR タイトルが必要"
rm -f "$tmpcfg"

# commit: 一時 git リポジトリでステージ済み変更を実コミット
repo="$(mktemp -d)"
(
  cd "$repo"
  git init -q
  git config user.email t@example.com
  git config user.name tester
  echo "hello" > a.txt
  git add a.txt
  XREV_CONFIG="$DEFAULT_CONFIG" "$FN" commit "テスト: a.txt を追加" >/dev/null 2>&1
)
crc=$?
assert_rc "ステージ済みで commit は rc=0" 0 "$crc"
msg="$(cd "$repo" && git log -1 --pretty=%s 2>/dev/null)"
assert_eq "コミットメッセージが記録される" "テスト: a.txt を追加" "$msg"

# commit: ステージ無しはエラー
(cd "$repo" && XREV_CONFIG="$DEFAULT_CONFIG" "$FN" commit "空コミット" >/dev/null 2>&1); erc=$?
assert_rc "ステージ無しの commit はエラー(rc1)" 1 "$erc"
rm -rf "$repo"
