#!/usr/bin/env bash
# status.sh [--all[=<n>]] [slug] — cockpit: where is each OPEN feature in the
# loop, what is the next action. Closed features live in .sdlc/archive/
# (close.sh moves them); --all lists the newest 20, --all=<n> widens that.
# A slug argument finds archived features without --all. Run from the project
# root (needs .sdlc/).
set -euo pipefail
[ -d .sdlc ] || { echo "FAIL: no .sdlc/ here. Run init.sh first, from the project root."; exit 1; }
# --all is BOUNDED by default (newest 20) so an agent that runs it does not
# pull thousands of archive lines into its context; --all=<n> widens it.
all=""; cap=20
case "${1:-}" in
  --all) all=1; shift;;
  --all=*)
    all=1; cap="${1#--all=}"; shift
    case "$cap" in (''|*[!0-9]*) echo "FAIL: --all=<n> needs a number, got '$cap'"; exit 1;; esac;;
esac

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
  # micro track (skills/1-intent): no spec or plan; the intent gate opens
  # build. ([^a-z]|$) keeps "microservice-…" values from reading as micro.
  micro=""
  if [ -f "${dir}intent.md" ] && grep -qiE '^- track: micro([^a-z]|$)' "${dir}intent.md"; then
    micro=1
  fi
  # self-healing: a spec.md on disk means the feature went full track,
  # whatever the Track line says (micro→full upgrades can forget the edit)
  if [ -f "${dir}spec.md" ]; then micro=""; fi
  # the intent approval froze the Track verdict (approve.sh): a Track line
  # rewritten to micro AFTER approval does not skip spec/plan
  irec=".sdlc/approvals/${slug}.intent.approval"
  if [ -n "$micro" ] && [ -f "$irec" ] && ! grep -q '^track: micro' "$irec"; then
    micro=""
    echo "note: $slug intent.md says micro but the intent approval was granted full-track — re-approve intent or revert the Track line"
  fi
  echo "== $slug${micro:+   (micro)}"
  # incident evidence still outstanding? (see skills/6-maintain Evidence tracking)
  if [ -f "${dir}intent.md" ] && grep -q 'reproduction evidence: requested' "${dir}intent.md" \
     && ! grep -qE 'reproduction evidence: .*(received|waived-by)' "${dir}intent.md"; then
    echo "   EVIDENCE OUTSTANDING: reproduction still 'requested' in intent.md"
  fi
  next_action=""
  # a map-first feature (skills/1-intent "Chart a map first") is not ready
  # for intent.md — the next action is the map's top Unknown, not the artifact
  if [ -f "${dir}map.md" ] && [ ! -f "${dir}intent.md" ]; then
    next_action="resolve the top Unknown in ${dir}map.md (skills/1-intent 'Chart a map first')"
  fi
  loop_stages="$stages"
  if [ -n "$micro" ]; then loop_stages="intent ship"; fi
  for stage in $loop_stages; do
    art="$dir$(artifact_for "$stage")"
    rec=".sdlc/approvals/${slug}.${stage}.approval"
    if [ ! -f "$art" ]; then
      state="—  (no artifact)"
      [ -z "$next_action" ] && next_action="write $(artifact_for "$stage") (see $(skill_for "$stage"))"
    elif [ ! -f "$rec" ]; then
      state="PENDING approval"
      if [ -z "$next_action" ]; then
        if [ "$stage" = plan ] && [ "$lazy" -ge 1 ]; then
          next_action="plan gate (lazymode $lazy): gates/approve.sh plan $art --lazy after the adversary pass (AGENTS.md rule 3)"
        elif [ "$lazy" -ge "$(lazy_min "$stage")" ]; then
          if [ "$stage" = ship ]; then
            next_action="lazy gate (lazymode $lazy): gates/approve.sh ship $art --lazy after the adversary pass (AGENTS.md rule 3)"
          else
            next_action="lazy gate (lazymode $lazy): gates/approve.sh $stage $art --lazy after a clean tripwire scan or adversary pass (AGENTS.md rule 3)"
          fi
        elif [ "$stage" = plan ]; then
          next_action="plan gate (tiered): gates/approve.sh plan $art --agent-adversary after a clean adversary review, or human approval on any trip-wire (AGENTS.md rule 3)"
        else
          next_action="human gate: gates/approve.sh $stage $art"
        fi
      fi
    else
      at=$(grep '^approved_at: ' "$rec" | awk '{print $2}')
      mode=$(grep -q '^mode: delegated' "$rec" && echo " · delegated" || true)
      [ -z "$mode" ] && mode=$(grep -q '^mode: agent-adversary' "$rec" && echo " · agent-adversary" || true)
      [ -z "$mode" ] && mode=$(grep -q '^mode: lazy' "$rec" && echo " · lazy" || true)
      state="APPROVED (@ $at$mode)"
    fi
    printf "  %-8s %s\n" "$stage" "$state"
  done
  if [ -z "$next_action" ]; then next_action="loop complete — next: $(next_hint ship)"; fi
  echo "  next  →  $next_action"
done

# archived (closed) features: one line each with --all, or when named by slug
show_archived() { # <dir>
  local d="$1" slug cstate creason
  slug=$(basename "$d")
  # || true: a hand-migrated archive dir may lack CLOSED or a reason line;
  # under pipefail a non-matching grep would otherwise kill the whole run
  cstate=$(grep '^state: ' "$d/CLOSED" 2>/dev/null | cut -d' ' -f2 || true)
  creason=$(grep '^reason: ' "$d/CLOSED" 2>/dev/null | cut -d' ' -f2- || true)
  echo "== $slug   [CLOSED: ${cstate:-?}] ${creason:-} (archived)"
}
if [ -n "$all" ]; then
  total=0; shown=0
  # newest first: dir mtime ≈ close time (CLOSED is written just before the move)
  while IFS= read -r dir; do
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    [ $# -ge 1 ] && [ "$(basename "$dir")" != "$1" ] && continue
    total=$((total + 1))
    [ "$shown" -lt "$cap" ] || continue
    shown=$((shown + 1))
    found=1
    show_archived "$dir"
  done < <(ls -1td .sdlc/archive/*/ 2>/dev/null || true)
  if [ "$total" -gt "$shown" ]; then
    echo "(… $((total - shown)) more archived — status.sh --all=<n>, or ls .sdlc/archive/)"
  fi
elif [ $# -ge 1 ] && [ $found -eq 0 ] && [ -d ".sdlc/archive/$1" ]; then
  found=1
  show_archived ".sdlc/archive/$1"
fi

if [ $found -eq 0 ]; then
  echo "no open features under .sdlc/work/${1:+ matching '$1'}"
  if [ -z "$all" ] && ls -d .sdlc/archive/*/ >/dev/null 2>&1; then
    echo "(archived features exist — status.sh --all lists them)"
  fi
  exit 1
fi
