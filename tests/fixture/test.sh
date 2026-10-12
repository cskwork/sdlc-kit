#!/usr/bin/env bash
set -eu
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export TODO_FILE="$tmp/todos"
bash "$here/todo.sh" add 'old task'
bash "$here/todo.sh" add 'another task'
[ "$(bash "$here/todo.sh" list)" = "$(printf 'old task\nanother task')" ]
if bash "$here/todo.sh" add '' > "$tmp/error" 2>&1; then
  echo 'empty task unexpectedly accepted' >&2; exit 1
fi
[ "$(wc -l < "$TODO_FILE" | tr -d ' ')" = 2 ]
echo 'existing add/list and invalid-input checks passed'
