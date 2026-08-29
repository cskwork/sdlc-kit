#!/usr/bin/env bash
# refcheck.sh <deploy-ref> [path ...] — is the local checkout the code that is running?
# Run from the repo root BEFORE reading any source file during incident diagnosis.
# Exit 0: checkout matches the deploy ref (reads may use the working tree).
# Exit 1: checkout differs — read every file via `git show <deploy-ref>:<path>` instead.
# Exit 2: usage / not a git repo / unknown ref.
set -euo pipefail

[ $# -ge 1 ] || { echo "usage: refcheck.sh <deploy-ref> [suspected-path ...]"; exit 2; }
ref="$1"; shift || true

git rev-parse --git-dir >/dev/null 2>&1 || { echo "FAIL: not a git repo: $(pwd)"; exit 2; }

git fetch --quiet --all 2>/dev/null || echo "WARN: fetch failed; comparing against possibly stale refs"

git rev-parse --verify --quiet "$ref" >/dev/null || { echo "FAIL: unknown ref: $ref"; exit 2; }

head=$(git rev-parse HEAD)
target=$(git rev-parse "$ref")

if [ "$head" = "$target" ]; then
  echo "OK: HEAD == $ref ($head). Working-tree reads are valid."
  exit 0
fi

echo "DRIFT: HEAD ($head) != $ref ($target)"
behind=$(git rev-list --count "HEAD..$ref")
ahead=$(git rev-list --count "$ref..HEAD")
echo "  HEAD is $behind commit(s) behind and $ahead ahead of $ref."

if [ $# -ge 1 ]; then
  echo "  Commits on $ref not in HEAD touching the suspected paths:"
  git log --oneline "HEAD..$ref" -- "$@" | sed 's/^/    /' || true
  n=$(git log --oneline "HEAD..$ref" -- "$@" | wc -l | tr -d ' ')
  if [ "$n" = "0" ]; then
    echo "  (none — the suspected paths are identical; drift is elsewhere)"
  fi
fi

echo "RULE: read every suspected file via: git show $ref:<path>"
echo "      State in every report which ref each fact came from."
exit 1
