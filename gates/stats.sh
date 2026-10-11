#!/usr/bin/env bash
# stats.sh [--all] — measurement: time per stage and approval counts, read
# entirely from the on-disk records — approvals, the last verify receipt and
# CLOSED (this script calls no git; the records are gitignored and git could
# not see them anyway). Rows run in time order, so a re-approval shows where
# it happened instead of as a negative interval. Leading
# indicators per the AI-native SDLC playbook. Default output is BOUNDED:
# open features + the 20 most recently closed. --all reads every archived
# feature, so output grows with the archive — run it deliberately, not from
# an agent loop that only needs current timings. Run from the project root
# (needs .sdlc/).
set -euo pipefail
[ -d .sdlc ] || { echo "FAIL: no .sdlc/ here. Run from the project root."; exit 1; }
all=""
[ "${1:-}" = "--all" ] && all=1
recent=20

to_epoch() {  # ISO8601 UTC → epoch (macOS + Linux)
  if date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null; then :; else date -u -d "$1" +%s; fi
}

# open features, then archived newest-first (dir mtime ≈ close time: CLOSED is
# written into the dir right before the move)
list_dirs() {
  ls -1d .sdlc/work/*/ 2>/dev/null || true
  if [ -n "$all" ]; then
    ls -1td .sdlc/archive/*/ 2>/dev/null || true
  else
    ls -1td .sdlc/archive/*/ 2>/dev/null | head -n "$recent" || true
  fi
}

# field <file> <key> → the first "<key>: " value's first word, or nothing
field() { awk -v k="$2: " 'index($0, k) == 1 { split(substr($0, length(k) + 1), w, " "); print w[1]; exit }' "$1"; }

echo "feature            stage    at                     +hours_since_prev  mode"
while IFS= read -r dir; do
  [ -n "$dir" ] && [ -d "$dir" ] || continue
  slug=$(basename "$dir")
  rows=""
  # row <stage> <at> <mode>: a malformed or missing timestamp is skipped, never
  # fatal — one bad record must not kill the whole report under pipefail
  row() {
    local ep
    [ -n "$2" ] || return 0
    ep=$(to_epoch "$2" 2>/dev/null) || return 0
    rows="${rows}${ep} $1 $2 $3
"
  }
  for stage in intent spec plan ship; do
    rec=".sdlc/approvals/${slug}.${stage}.approval"
    [ -f "$rec" ] || rec="${dir}approvals/${slug}.${stage}.approval"
    [ -f "$rec" ] || continue
    # every agent-run mode must read as itself — a lazy approval reported as
    # "direct" would disguise an autonomous loop as four human decisions
    mode=$(field "$rec" mode)
    row "$stage" "$(field "$rec" approved_at)" "${mode:-direct}"
  done
  # the last verify run splits plan→ship into building and reviewing; the
  # receipt is rewritten on every run, so this is the final proof, not the first
  rec="${dir}verify-receipt.md"
  [ -f "$rec" ] && row proof "$(field "$rec" recorded_at)" "$(field "$rec" result)"
  rec="${dir}CLOSED"
  if [ -f "$rec" ]; then
    mode=$(field "$rec" mode)
    row close "$(field "$rec" closed_at)" "${mode:-direct}"
  fi
  prev=""
  # time order; a tie keeps stage order (sort -s)
  while read -r ep stage at mode; do
    delta="—"
    [ -n "$prev" ] && delta=$(awk "BEGIN{printf \"%.1f\", ($ep - $prev)/3600}")
    printf "%-18s %-8s %-22s %-18s %s\n" "$slug" "$stage" "$at" "$delta" "$mode"
    prev=$ep
  done < <(printf '%s' "$rows" | sort -s -n -k1,1)
done < <(list_dirs)

# || true: a store with nothing archived yet has no archive dir, and ls's
# failure must not end the report under pipefail
narch=$( (ls -1d .sdlc/archive/*/ 2>/dev/null || true) | wc -l | tr -d ' ')
if [ -z "$all" ] && [ "${narch:-0}" -gt "$recent" ]; then
  echo "(… showing the $recent most recently closed of $narch archived — stats.sh --all for everything)"
fi

echo
echo "re-approvals per gate (>1 = gate rejected at least once):"
# counted from .approval.history files (approve.sh appends the superseded
# record on every re-approval) — disk truth, and the only truth: approval
# records are gitignored (init.sh), so git sees no re-gates at all
set -- .sdlc/approvals/*.approval
[ -n "$all" ] && set -- "$@" .sdlc/archive/*/approvals/*.approval
for rec in "$@"; do
  [ -f "$rec" ] || continue
  n=1
  if [ -f "${rec}.history" ]; then
    n=$(( $(grep -c '^approved_at: ' "${rec}.history" || true) + 1 ))
  fi
  [ "$n" -gt 1 ] && echo "  $(basename "$rec" .approval): $n approvals"
done
echo "  (none listed = every gate passed first try)"
if [ -z "$all" ] && [ "${narch:-0}" -gt 0 ]; then
  echo "  (archived features included only with --all)"
fi
