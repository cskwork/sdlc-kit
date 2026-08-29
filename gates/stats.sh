#!/usr/bin/env bash
# stats.sh — measurement: time per stage and approval counts, from approval
# records + git history. Leading indicators per the AI-native SDLC playbook.
# Run from the project root (needs .sdlc/).
set -euo pipefail
[ -d .sdlc/approvals ] || { echo "FAIL: no .sdlc/approvals here."; exit 1; }

to_epoch() {  # ISO8601 UTC → epoch (macOS + Linux)
  if date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null; then :; else date -u -d "$1" +%s; fi
}

echo "feature            stage    approved_at            +hours_since_prev  mode"
for dir in .sdlc/work/*/; do
  [ -d "$dir" ] || continue
  slug=$(basename "$dir")
  prev=""
  for stage in intent spec plan ship; do
    rec=".sdlc/approvals/${slug}.${stage}.approval"
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
done

echo
echo "re-approvals per gate (>1 = gate rejected at least once), from git history:"
if git rev-parse --git-dir >/dev/null 2>&1; then
  for rec in .sdlc/approvals/*.approval; do
    [ -f "$rec" ] || continue
    n=$(git log --oneline --follow -- "$rec" 2>/dev/null | wc -l | tr -d ' ')
    [ "${n:-0}" -gt 1 ] && echo "  $(basename "$rec" .approval): $n approvals"
  done
  echo "  (none listed = every gate passed first try, or records not yet committed)"
else
  echo "  (not a git repo — history unavailable)"
fi
