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

# knowledge check: non-shipped closes must leave a lesson behind.
# lazymode >=3 (AGENTS.md rule 3) waives the separate lesson file — the
# mandatory reason line in CLOSED is the record.
if [ "$state" != "shipped" ] && [ "$state" != "handed-off" ]; then
  lm_raw=$(awk '/^lazymode: /{gsub(/\r/,""); print $2; exit}' .sdlc/config.md 2>/dev/null || true)
  lm="$lm_raw"
  case "$lm" in (''|*[!0-9]*) lm=0;; (*) [ "$lm" -le 4 ] || lm=0;; esac
  if [ "$lm" -lt 3 ] && ! ls .sdlc/memory/lessons/*"$slug"* >/dev/null 2>&1; then
    echo "BLOCKED: closing as '$state' requires a lesson first."
    echo "  Write .sdlc/memory/lessons/$(date +%Y-%m-%d)-$slug.md (what was tried,"
    echo "  why it failed, what would unblock it) + one INDEX.md line, then re-run."
    echo "  (lazymode >=3 in .sdlc/config.md waives this; the reason is the record)"
    exit 1
  fi
fi

{
  echo "state: $state"
  echo "reason: $reason"
  echo "closed_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [ -n "$delegated" ] && echo "mode: delegated-chat (agent-run on explicit human instruction)" || true
  [ -n "$delegated" ] && echo "runner: agent" || true
} > "$dir/CLOSED"
echo "CLOSED: $slug ($state) — $reason"

# promotion reminder: a lesson tag repeating 3+ times means the stage skill
# should absorb the fix, not the memory (see skills/6-maintain lesson format)
if [ -f .sdlc/memory/INDEX.md ]; then
  rep=$(awk '!/^#/ && match($0, /\[[^]]+\]/) {
      s = substr($0, RSTART+1, RLENGTH-2); n = split(s, t, /[, ]+/)
      for (i = 1; i <= n; i++) if (t[i] != "") c[t[i]]++
    } END { for (k in c) if (c[k] >= 3) print "  " k " (" c[k] "x)" }' .sdlc/memory/INDEX.md)
  if [ -n "$rep" ]; then
    echo "PROMOTE: these lesson tags repeat 3+ times — fold the fix into the stage skill:"
    echo "$rep"
  fi
fi

echo "Reminder: harvest durable facts into .sdlc/memory/DOMAIN.md, then commit"
echo "$dir, .sdlc/approvals/, and .sdlc/memory/ for the audit trail."
