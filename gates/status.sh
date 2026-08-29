#!/usr/bin/env bash
# status.sh [slug] — cockpit: where is each feature in the loop, what is the next action.
# Run from the project root (needs .sdlc/).
set -euo pipefail
[ -d .sdlc ] || { echo "FAIL: no .sdlc/ here. Run init.sh first, from the project root."; exit 1; }

# warn when the kit moved on since this project was seeded (see init.sh)
kitdir="$(cd "$(dirname "$0")/.." && pwd)"
seeded=$(awk '/^kit_version: /{print $2; exit}' .sdlc/config.md 2>/dev/null || true)
if [ -n "$seeded" ]; then
  curver=""
  if [ "$(git -C "$kitdir" rev-parse --show-toplevel 2>/dev/null)" = "$kitdir" ]; then
    curver=$(git -C "$kitdir" describe --tags --always 2>/dev/null || true)
  fi
  [ -n "$curver" ] || curver=$(cat "$kitdir/VERSION" 2>/dev/null || true)
  if [ -n "$curver" ] && [ "$curver" != "$seeded" ]; then
    echo "note: kit is $curver; this project was seeded with $seeded — gates may behave differently mid-feature"
  fi
fi

# lazymode (AGENTS.md rule 3): which human gates this project waives.
# \r stripped for CRLF configs; anything outside 0-4 fails CLOSED to 0.
lazy_raw=$(awk '/^lazymode: /{gsub(/\r/,""); print $2; exit}' .sdlc/config.md 2>/dev/null || true)
lazy="$lazy_raw"
case "$lazy" in (''|*[!0-9]*) lazy=0;; (*) [ "$lazy" -le 4 ] || lazy=0;; esac
if [ "$lazy" = 0 ] && [ -n "$lazy_raw" ] && [ "$lazy_raw" != 0 ]; then
  echo "note: lazymode '$lazy_raw' is invalid (range 0-4) — treated as 0, all gates human"
fi
lazy_min() { case "$1" in plan) echo 1;; spec) echo 2;; ship) echo 3;; intent) echo 4;; esac; }
if [ "$lazy" -gt 0 ]; then
  case "$lazy" in
    1) keep="intent, spec, ship";; 2) keep="intent, ship";; 3) keep="intent";; *) keep="none";;
  esac
  echo "lazymode: $lazy (human gates kept: $keep)"
fi

sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | awk '{print $1}'; }

# stage order and the artifact each gate locks
stages="intent spec plan ship"
artifact_for() { case "$1" in
  intent) echo "intent.md";; spec) echo "spec.md";; plan) echo "plan.md";; ship) echo "evidence.md";; esac; }
next_hint() { case "$1" in
  intent) echo "skills/2-spec";; spec) echo "skills/3-plan";; plan) echo "skills/4-build then 5-ship";; ship) echo "commit per skills/5-ship discipline";; esac; }
skill_for() { case "$1" in
  intent) echo "skills/1-intent";; spec) echo "skills/2-spec";; plan) echo "skills/3-plan";; ship) echo "skills/4-build+5-ship";; esac; }

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
      [ -z "$next_action" ] && next_action="write $(artifact_for "$stage") (see $(skill_for "$stage"))"
    elif [ ! -f "$rec" ]; then
      state="PENDING approval"
      if [ -z "$next_action" ]; then
        if [ "$stage" = plan ] && [ "$lazy" -ge 1 ]; then
          next_action="plan gate (lazymode $lazy): gates/approve.sh plan $art --agent-adversary after a clean adversary review, or --lazy on trip-wires (AGENTS.md rule 3)"
        elif [ "$lazy" -ge "$(lazy_min "$stage")" ]; then
          next_action="lazy gate (lazymode $lazy): gates/approve.sh $stage $art --lazy after a clean adversary review (AGENTS.md rule 3)"
        elif [ "$stage" = plan ]; then
          next_action="plan gate (tiered): gates/approve.sh plan $art --agent-adversary after a clean adversary review, or human approval on any trip-wire (AGENTS.md rule 3)"
        else
          next_action="human gate: gates/approve.sh $stage $art"
        fi
      fi
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
        [ -z "$mode" ] && mode=$(grep -q '^mode: agent-adversary' "$rec" && echo " · agent-adversary" || true)
        [ -z "$mode" ] && mode=$(grep -q '^mode: lazy' "$rec" && echo " · lazy" || true)
        state="APPROVED ($by @ $at$mode)"
      fi
    fi
    printf "  %-8s %s\n" "$stage" "$state"
  done
  if [ -z "$next_action" ]; then next_action="loop complete — next: $(next_hint ship)"; fi
  echo "  next  →  $next_action"
done
[ $found -eq 1 ] || { echo "no features under .sdlc/work/${1:+ matching '$1'}"; exit 1; }
