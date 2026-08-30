#!/usr/bin/env bash
# stats.sh [--all] — measurement: time per stage and approval counts, from
# approval records + git history. Leading indicators per the AI-native SDLC
# playbook. Default output is BOUNDED: open features + the 20 most recently
# closed, and re-approval git history for open features only. --all reads every
# archived feature and its git history — output and git calls grow with the
# archive, so run it deliberately, not from an agent loop that only needs
# current timings. Run from the project root (needs .sdlc/).
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

echo "feature            stage    approved_at            +hours_since_prev  mode"
while IFS= read -r dir; do
  [ -n "$dir" ] && [ -d "$dir" ] || continue
  slug=$(basename "$dir")
  prev=""
  for stage in intent spec plan ship; do
    rec=".sdlc/approvals/${slug}.${stage}.approval"
    [ -f "$rec" ] || rec="${dir}approvals/${slug}.${stage}.approval"
    [ -f "$rec" ] || continue
    # || true + skip: a malformed record (no approved_at) must not kill the
    # whole report under pipefail
    at=$(grep '^approved_at: ' "$rec" | awk '{print $2}' || true)
    [ -n "$at" ] || continue
    # every agent-run mode must read as itself — a lazy approval reported as
    # "direct" would disguise an autonomous loop as four human decisions
    mode=$(awk -F': ' '/^mode: /{print $2; exit}' "$rec" | awk '{print $1}')
    [ -n "$mode" ] || mode="direct"
    delta="—"
    if [ -n "$prev" ]; then
      delta=$(awk "BEGIN{printf \"%.1f\", ($(to_epoch "$at") - $prev)/3600}")
    fi
    printf "%-18s %-8s %-22s %-18s %s\n" "$slug" "$stage" "$at" "$delta" "$mode"
    prev=$(to_epoch "$at")
  done
done < <(list_dirs)

narch=$(ls -1d .sdlc/archive/*/ 2>/dev/null | wc -l | tr -d ' ')
if [ -z "$all" ] && [ "${narch:-0}" -gt "$recent" ]; then
  echo "(… showing the $recent most recently closed of $narch archived — stats.sh --all for everything)"
fi

echo
echo "re-approvals per gate (>1 = gate rejected at least once):"
# counted from .approval.history files (approve.sh appends the superseded
# record on every re-approval) — disk truth; git cannot see intra-feature
# re-gates because approvals commit once, at ship
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
