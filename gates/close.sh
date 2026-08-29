#!/usr/bin/env bash
# close.sh <slug> <shipped|abandoned|dead-end|handed-off> "<reason>" [--delegated]
# handed-off: the work continues outside this loop (another team's tracker).
#   The reason MUST contain the external ticket/PR reference (e.g. A20-1240).
# Terminal state for a feature. Human decision; --delegated per AGENTS.md rule 3.
# A dead-ended feature must leave MORE knowledge behind than it consumed:
# closing requires a lesson (dead-end/abandoned) and a DOMAIN.md harvest check.
set -euo pipefail

usage() { echo "usage: close.sh <slug> <shipped|abandoned|dead-end|handed-off> \"<reason>\" [--delegated]"; exit 1; }
delegated=""
if [ $# -eq 4 ] && [ "$4" = "--delegated" ]; then delegated=1; set -- "$1" "$2" "$3"; fi
[ $# -eq 3 ] || usage
slug="$1"; state="$2"; reason="$3"
case "$state" in (shipped|abandoned|dead-end|handed-off) ;; (*) echo "FAIL: state must be shipped|abandoned|dead-end|handed-off"; usage;; esac
dir=".sdlc/work/$slug"
[ -d "$dir" ] || { echo "FAIL: no feature dir: $dir"; exit 1; }
[ -f "$dir/CLOSED" ] && { echo "FAIL: already closed: $(head -1 "$dir/CLOSED")"; exit 1; }
[ -n "$reason" ] || { echo "FAIL: reason must not be empty"; exit 1; }

# handed-off closes must name the external reference in the reason
if [ "$state" = "handed-off" ]; then
  if ! echo "$reason" | grep -qE '[A-Z][A-Z0-9]+-[0-9]+|https?://'; then
    echo "BLOCKED: handed-off requires the external ticket/PR reference in the reason"
    echo "  (a key like A20-1240 or a URL), so the trail does not dead-end here."
    exit 1
  fi
fi

# knowledge check: non-shipped closes must leave a lesson behind
if [ "$state" != "shipped" ] && [ "$state" != "handed-off" ]; then
  if ! ls .sdlc/memory/lessons/*"$slug"* >/dev/null 2>&1; then
    echo "BLOCKED: closing as '$state' requires a lesson first."
    echo "  Write .sdlc/memory/lessons/$(date +%Y-%m-%d)-$slug.md (what was tried,"
    echo "  why it failed, what would unblock it) + one INDEX.md line, then re-run."
    exit 1
  fi
fi

{
  echo "state: $state"
  echo "reason: $reason"
  echo "closed_by: $(whoami)"
  echo "closed_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [ -n "$delegated" ] && echo "mode: delegated-chat (agent-run on explicit human instruction)" || true
  [ -n "$delegated" ] && echo "runner: agent" || true
} > "$dir/CLOSED"
echo "CLOSED: $slug ($state) — $reason"
echo "Reminder: harvest durable facts into .sdlc/memory/DOMAIN.md, then commit"
echo "$dir and .sdlc/memory/ for the audit trail."
