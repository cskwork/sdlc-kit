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
    at=$(grep '^approved_at: ' "$rec" | awk '{print $2}')
    mode=$(grep -q '^mode: delegated' "$rec" && echo "delegated" || echo "direct")
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
echo "re-approvals per gate (>1 = gate rejected at least once), from git history:"
if git rev-parse --git-dir >/dev/null 2>&1; then
  # one `git log --follow` per record: bounded by open-feature count by
  # default; archived records join only under --all
  set -- .sdlc/approvals/*.approval
  [ -n "$all" ] && set -- "$@" .sdlc/archive/*/approvals/*.approval
  for rec in "$@"; do
    [ -f "$rec" ] || continue
    # --follow tracks the work→archive rename; the move itself is 1 commit, so
    # archived records read >2, not >1 (move + original approval).
    # || true: git log exits 128 on a repo with no commits yet — that must
    # read as "0 approvals in history", not kill the script under pipefail
    n=$(git log --oneline --follow -- "$rec" 2>/dev/null | wc -l | tr -d ' ' || true)
    case "$rec" in (.sdlc/archive/*) floor=2;; (*) floor=1;; esac
    [ "${n:-0}" -gt "$floor" ] && echo "  $(basename "$rec" .approval): $((n - floor + 1)) approvals"
  done
  echo "  (none listed = every gate passed first try, or records not yet committed)"
  if [ -z "$all" ] && [ "${narch:-0}" -gt 0 ]; then
    echo "  (archived features included only with --all)"
  fi
else
  echo "  (not a git repo — history unavailable)"
fi
