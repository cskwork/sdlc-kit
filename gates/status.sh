#!/usr/bin/env bash
# status.sh [slug] — cockpit: where is each feature in the loop, what is the next action.
# Run from the project root (needs .sdlc/).
set -euo pipefail
[ -d .sdlc ] || { echo "FAIL: no .sdlc/ here. Run init.sh first, from the project root."; exit 1; }

sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | awk '{print $1}'; }

# stage order and the artifact each gate locks
stages="intent spec plan ship"
artifact_for() { case "$1" in
  intent) echo "intent.md";; spec) echo "spec.md";; plan) echo "plan.md";; ship) echo "evidence.md";; esac; }
next_hint() { case "$1" in
  intent) echo "skills/2-spec";; spec) echo "skills/3-plan";; plan) echo "skills/4-build then 5-ship";; ship) echo "commit per skills/5-ship discipline";; esac; }

found=0
for dir in .sdlc/work/*/; do
  [ -d "$dir" ] || continue
  slug=$(basename "$dir")
  [ $# -ge 1 ] && [ "$slug" != "$1" ] && continue
  found=1
  if [ -f "${dir}CLOSED" ]; then
    cstate=$(grep '^state: ' "${dir}CLOSED" | cut -d' ' -f2)
    creason=$(grep '^reason: ' "${dir}CLOSED" | cut -d' ' -f2-)
    echo "== $slug   [CLOSED: $cstate] $creason"
    continue
  fi
  echo "== $slug"
  # incident evidence still outstanding? (see skills/6-maintain Evidence tracking)
  if [ -f "${dir}intent.md" ] && grep -q 'reproduction evidence: requested' "${dir}intent.md" \
     && ! grep -qE 'reproduction evidence: .*(received|waived-by-human)' "${dir}intent.md"; then
    echo "   EVIDENCE OUTSTANDING: reproduction still 'requested' in intent.md"
  fi
  next_action=""
  for stage in $stages; do
    art="$dir$(artifact_for "$stage")"
    rec=".sdlc/approvals/${slug}.${stage}.approval"
    if [ ! -f "$art" ]; then
      state="—  (no artifact)"
      [ -z "$next_action" ] && next_action="write $(artifact_for "$stage") (see $(case $stage in intent) echo skills/1-intent;; spec) echo skills/2-spec;; plan) echo skills/3-plan;; ship) echo skills/4-build+5-ship;; esac))"
    elif [ ! -f "$rec" ]; then
      state="PENDING approval"
      [ -z "$next_action" ] && next_action="human gate: gates/approve.sh $stage $art"
    else
      want=$(grep '^sha256: ' "$rec" | awk '{print $2}' || true)
      if [ -z "$want" ]; then
        state="CORRUPT record"
        [ -z "$next_action" ] && next_action="re-approve: gates/approve.sh $stage $art"
      elif [ "$want" != "$(sha "$art")" ]; then
        state="TAMPERED (edited after approval)"
        [ -z "$next_action" ] && next_action="re-review + re-approve: gates/approve.sh $stage $art"
      else
        by=$(grep '^approved_by: ' "$rec" | awk '{print $2}')
        at=$(grep '^approved_at: ' "$rec" | awk '{print $2}')
        mode=$(grep -q '^mode: delegated' "$rec" && echo " · delegated" || true)
        state="APPROVED ($by @ $at$mode)"
      fi
    fi
    printf "  %-8s %s\n" "$stage" "$state"
  done
  if [ -z "$next_action" ]; then next_action="loop complete — next: $(next_hint ship)"; fi
  echo "  next  →  $next_action"
done
[ $found -eq 1 ] || { echo "no features under .sdlc/work/${1:+ matching '$1'}"; exit 1; }
