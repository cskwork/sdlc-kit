#!/usr/bin/env bash
# Fails when any tracked file matches tests/public-trace.patterns (changelogs included).
# An optional argument names another pattern file (the selftest checks the exit codes with it).
# Exit 0: no match. 1: a match, listed above. 2: no patterns, or git grep failed (a bad pattern).
set -e
cd "$(dirname "$0")/.."
own=tests/public-trace.patterns
list=${1:-$own}
patterns=$(grep -vE '^[[:space:]]*(#|$)' "$list") || :
[ -n "$patterns" ] || { printf 'public-trace: no patterns in %s\n' "$list" >&2; exit 2; }
args=()
while IFS= read -r pattern; do args+=(-e "$pattern"); done < <(printf '%s\n' "$patterns")
rc=0
git grep -n -I -i -E "${args[@]}" -- . ":!$own" || rc=$?
case "$rc" in
  0) printf 'public-trace: the lines above match %s; use placeholders such as example.atlassian.net or PROJ-123\n' "$list" >&2; exit 1;;
  1) printf 'public-trace: no matches\n';;
  *) printf 'public-trace: git grep failed (exit %s): check the patterns in %s\n' "$rc" "$list" >&2; exit 2;;
esac
