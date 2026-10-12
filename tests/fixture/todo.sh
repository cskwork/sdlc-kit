#!/usr/bin/env bash
set -eu
file=${TODO_FILE:-todo.txt}
case ${1:-} in
  add)
    [ "$#" -eq 2 ] && [ -n "$2" ] || { echo 'todo: add needs text' >&2; exit 2; }
    printf '%s\n' "$2" >> "$file"
    ;;
  list)
    [ ! -f "$file" ] || cat "$file"
    ;;
  *) echo 'todo: use add TEXT or list' >&2; exit 2 ;;
esac
