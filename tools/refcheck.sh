#!/usr/bin/env bash
# refcheck.sh <deploy-ref> [suspected-path ...] — is this checkout the code that
# is actually running? Run from the repo root BEFORE reading any source file
# during incident diagnosis.
#
# Exit 0: every checked path in the WORKING TREE is byte-identical to <deploy-ref>
#         (worktree reads are valid for those paths).
# Exit 1: drift — read the drifted files via `git show <deploy-ref>:<path>`.
# Exit 2: unknown — usage error, not a git repo, unknown ref, or a fetch that
#         failed. Nothing may be claimed about the running code in this state.
#
# What a ref is and is not: a git ref is a pointer in THIS clone. It is not
# evidence of what is deployed. Pass the deployment SHA your release system or
# runtime reports (`--deployed-sha <sha>`) when you have it; without it the
# deployed revision is reported as unknown and the ref is treated as a
# best-available stand-in, never as proof.
set -euo pipefail

usage() {
  echo "usage: refcheck.sh <deploy-ref> [--deployed-sha <sha>] [--no-fetch] [suspected-path ...]"
  exit 2
}

[ $# -ge 1 ] || usage
ref=""; deployed=""; fetch=1; paths=()   # array: a path with spaces must survive
while [ $# -gt 0 ]; do
  case "$1" in
    --deployed-sha) [ $# -ge 2 ] || usage; deployed="$2"; shift;;
    --deployed-sha=*) deployed="${1#--deployed-sha=}";;
    --no-fetch) fetch="";;
    -*) usage;;
    *) if [ -z "$ref" ]; then ref="$1"; else paths+=("$1"); fi;;
  esac
  shift
done
[ -n "$ref" ] || usage

git rev-parse --git-dir >/dev/null 2>&1 || { echo "UNKNOWN: not a git repo: $(pwd)"; exit 2; }

# Fetch only what this check needs. A failed fetch means the local ref may be
# stale, and a stale ref cannot support ANY claim about the running code.
if [ -n "$fetch" ]; then
  remote=""
  case "$ref" in (*/*) remote="${ref%%/*}";; esac
  if [ -n "$remote" ] && git remote get-url "$remote" >/dev/null 2>&1; then
    if ! git fetch --quiet "$remote" 2>/dev/null; then
      echo "UNKNOWN: fetch of '$remote' failed — '$ref' here may be stale."
      echo "  Fix the fetch or pass --no-fetch AND state in the report that the ref is unverified."
      exit 2
    fi
  fi
fi

git rev-parse --verify --quiet "$ref^{commit}" >/dev/null || {
  echo "UNKNOWN: unknown ref: $ref"
  echo "  No conclusion about the deployed code is available. Do not read the worktree as if it were live code."
  exit 2; }

target=$(git rev-parse "$ref^{commit}")
head=$(git rev-parse HEAD)

if [ -n "$deployed" ]; then
  if ! git rev-parse --verify --quiet "$deployed^{commit}" >/dev/null; then
    echo "UNKNOWN: deployed sha '$deployed' is not a commit in this clone (fetch it first)."
    exit 2
  fi
  deployed=$(git rev-parse "$deployed^{commit}")
  echo "deployed revision: $deployed (supplied by the release/runtime source)"
  if [ "$deployed" != "$target" ]; then
    echo "note: $ref is $target — the ref is NOT what is deployed; comparing against the deployed sha."
  fi
  target="$deployed"
else
  echo "deployed revision: UNKNOWN (no --deployed-sha given; '$ref' = $target is a stand-in, not deployment evidence)"
fi

# Which paths to compare. With no arguments, compare everything that differs
# between the working tree and the target: staged, unstaged, and untracked
# files all count — HEAD == target proves nothing about the files on disk.
set -- ${paths+"${paths[@]}"}
if [ $# -ge 1 ]; then
  files=$(git diff --name-only "$target" -- "$@"; git ls-files -o --exclude-standard -- "$@")
else
  files=$(git diff --name-only "$target"; git ls-files -o --exclude-standard)
fi
files=$(printf '%s\n' "$files" | awk 'NF' | LC_ALL=C sort -u)

if [ -z "$files" ]; then
  if [ $# -ge 1 ]; then
    echo "OK: the working tree matches $target for: $*"
  else
    echo "OK: the whole working tree matches $target (no staged, unstaged, or untracked differences)."
  fi
  echo "     Worktree reads are valid for those paths. Name the revision in every report."
  exit 0
fi

echo "DRIFT: the working tree is NOT $target. HEAD is $head."
printf '%s\n' "$files" | while IFS= read -r f; do
  [ -n "$f" ] || continue
  if ! git cat-file -e "$target:$f" 2>/dev/null; then
    echo "  + $f (untracked/new here; absent from $target)"
  elif [ ! -e "$f" ]; then
    echo "  - $f (present in $target; missing from the working tree)"
  else
    echo "  ~ $f (content differs from $target)"
  fi
done
echo "RULE: read every file above via: git show $target:<path>"
echo "      Facts from the working tree describe code nobody is running. State the revision behind each fact."
exit 1
