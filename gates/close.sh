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
archive=".sdlc/archive/$slug"
if [ -d "$archive" ]; then
  # sweep approvals stranded by an interruption between the two archive mvs
  if ls .sdlc/approvals/"$slug".*.approval >/dev/null 2>&1; then
    mkdir -p "$archive/approvals"
    mv .sdlc/approvals/"$slug".*.approval "$archive/approvals/"
    echo "note: swept stranded approval records into $archive/approvals/"
  fi
  echo "FAIL: already closed and archived: $(head -1 "$archive/CLOSED" 2>/dev/null || echo "$archive")"
  exit 1
fi
[ -d "$dir" ] || { echo "FAIL: no feature dir: $dir"; exit 1; }
[ -n "$reason" ] || { echo "FAIL: reason must not be empty"; exit 1; }

# A CLOSED record with no archive dir is an interrupted close (the mv or a
# check between failed). The decision is already recorded — resume the archive
# step instead of failing forever on "already closed".
resume=""
if [ -f "$dir/CLOSED" ]; then
  echo "note: $slug already has a CLOSED record — resuming the interrupted archive step"
  resume=1
  if [ -f "$dir/harvest.md" ]; then
    echo "note: unmerged harvest.md is being archived — merge it into .sdlc/memory/ from $archive"
  fi
fi

# handed-off closes must name the external reference in the reason
if [ -z "$resume" ] && [ "$state" = "handed-off" ]; then
  if ! echo "$reason" | grep -qE '[A-Z][A-Z0-9]+-[0-9]+|https?://'; then
    echo "BLOCKED: handed-off requires the external ticket/PR reference in the reason"
    echo "  (a key like A20-1240 or a URL), so the trail does not dead-end here."
    exit 1
  fi
fi

# shared memory has ONE writer — the close step (AGENTS.md rule 4). A leftover
# harvest.md means lesson/domain candidates were never merged into memory/.
if [ -z "$resume" ] && [ -f "$dir/harvest.md" ]; then
  echo "BLOCKED: unmerged harvest: $dir/harvest.md"
  echo "  Merge it into .sdlc/memory/ (lesson files + INDEX.md lines + DOMAIN.md"
  echo "  facts), delete the file, then re-run. Close is the single-writer moment."
  exit 1
fi

# knowledge check: non-shipped closes must leave a lesson behind.
# lazymode >=3 (AGENTS.md rule 3) waives the separate lesson file — the
# mandatory reason line in CLOSED is the record.
if [ -z "$resume" ] && [ "$state" != "shipped" ] && [ "$state" != "handed-off" ]; then
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

if [ -z "$resume" ]; then
  {
    echo "state: $state"
    echo "reason: $reason"
    echo "closed_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [ -n "$delegated" ] && echo "mode: delegated-chat (agent-run on explicit human instruction)" || true
    [ -n "$delegated" ] && echo "runner: agent" || true
  } > "$dir/CLOSED"
  echo "CLOSED: $slug ($state) — $reason"
fi

# Archive: closed features leave .sdlc/work/ so status.sh stays scoped to open
# work. Approval records move WITH the feature — the audit trail stays in one
# place. Plain mv, not git mv: git detects the rename at commit time, and the
# script must work in a dirty tree or before the first commit.
mkdir -p .sdlc/archive
in_git=""
git rev-parse --git-dir >/dev/null 2>&1 && in_git=1
# scratch/ is gitignored under work/ but NOT under archive/ — without this
# line a leftover scratch dir (abandoned/dead-end closes skip ship cleanup)
# would be committed with the archive. Read via tr -d '\r' (a CRLF .gitignore
# would never match) and match with case, not grep -q (init.sh ensure_line
# explains the pipefail/SIGPIPE trap).
if [ -n "$in_git" ]; then
  line='.sdlc/archive/*/scratch/'
  have=""
  [ -f .gitignore ] && have=$(tr -d '\r' < .gitignore)
  case "
$have
" in
    *"
$line
"*) ;;
    *)
      if [ -s .gitignore ] && [ -n "$(tail -c 1 .gitignore)" ]; then echo >> .gitignore; fi
      printf '%s\n' "$line" >> .gitignore ;;
  esac
fi
if [ -d "$dir/scratch" ] && [ -n "$(ls -A "$dir/scratch" 2>/dev/null)" ]; then
  echo "note: scratch/ still has files — archived but gitignored; delete what the lesson does not cite"
fi
mv "$dir" "$archive"
if ls .sdlc/approvals/"$slug".*.approval >/dev/null 2>&1; then
  mkdir -p "$archive/approvals"
  mv .sdlc/approvals/"$slug".*.approval "$archive/approvals/"
fi
echo "ARCHIVED: $dir → $archive (approvals included)"

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

echo "Reminder: harvest durable facts into .sdlc/memory/DOMAIN.md."
if [ -n "$in_git" ]; then
  # $dir must be staged too: `git add` on a deleted tracked path stages the
  # deletion. Omitting it leaves the old work/ files in HEAD, and a fresh
  # clone would resurrect the feature as OPEN (dir without its CLOSED).
  paths=""
  [ -n "$(git ls-files "$dir" 2>/dev/null)" ] && paths="\"$dir\" "
  echo "Then commit the close for the audit trail:"
  echo "  git add $paths\"$archive\" .sdlc/approvals .sdlc/memory .gitignore"
  echo "(git records the work/→archive/ move as a rename; history follows it)."
fi
