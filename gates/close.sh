#!/usr/bin/env bash
# close.sh <slug> <shipped|abandoned|dead-end|handed-off> "<reason>" [--delegated]
# handed-off: the work continues outside this loop (another team's tracker).
#   The reason MUST contain the external ticket/PR reference (e.g. A20-1240).
# Terminal state for a feature. Human decision; --delegated per AGENTS.md rule 3.
# A dead-ended feature must leave MORE knowledge behind than it consumed:
# closing requires a lesson (dead-end/abandoned) and a DOMAIN.md harvest check.
# `shipped` requires a DELIVERY: the ship approval must still bind the reviewed
# evidence AND the reviewed source snapshot, and delivery.md must record a
# confirmed result whose Source is that source — a commit that contains it, or
# the current worktree identity for a local target.
set -euo pipefail
kit="$(cd "$(dirname "$0")/.." && pwd)"
. "$kit/gates/_common.sh"

usage() {
  cat >&2 <<'EOF'
usage: close.sh <slug> <shipped|abandoned|dead-end|handed-off> "<reason>" [--delegated]
  shipped     needs the ship approval (still matching its evidence and the
              reviewed source) AND .sdlc/work/<slug>/delivery.md with a confirmed
              result whose Source contains that reviewed source
  abandoned   needs a lesson (lazymode >=3: the reason line is the record)
  dead-end    same as abandoned
  handed-off  the reason must name the external ticket key or URL
Closing archives the feature and its approvals to .sdlc/archive/<slug>/, and is
where scratch/ is pruned — keep whatever evidence.md, delivery.md, or a lesson cites.
EOF
  exit 1
}
delegated=""
if [ $# -eq 4 ] && [ "$4" = "--delegated" ]; then delegated=1; set -- "$1" "$2" "$3"; fi
[ $# -eq 3 ] || usage
slug="$1"; state="$2"; reason="$3"
case "$state" in (shipped|abandoned|dead-end|handed-off) ;; (*) echo "FAIL: state must be shipped|abandoned|dead-end|handed-off"; usage;; esac
dir=".sdlc/work/$slug"
archive=".sdlc/archive/$slug"
if [ -d "$archive" ]; then
  # sweep approvals stranded by an interruption between the two archive mvs
  if ls .sdlc/approvals/"$slug".* >/dev/null 2>&1; then
    mkdir -p "$archive/approvals"
    mv .sdlc/approvals/"$slug".* "$archive/approvals/"
    echo "note: swept stranded approval records into $archive/approvals/"
  fi
  echo "FAIL: already closed and archived: $(head -1 "$archive/CLOSED" 2>/dev/null || echo "$archive")"
  exit 1
fi
[ -d "$dir" ] || { echo "FAIL: no feature dir: $dir"; exit 1; }
[ -n "$reason" ] || { echo "FAIL: reason must not be empty"; exit 1; }

# A CLOSED record with no archive dir is an interrupted close (the mv or a
# check between failed). Resume the archive step instead of failing forever —
# but re-run every check below: CLOSED is an agent-writable file, so skipping
# them on its mere presence would let a hand-written CLOSED bypass the lot.
# A legitimate interrupted close passed them once and passes them again.
resume=""
if [ -f "$dir/CLOSED" ]; then
  recorded=$(grep '^state: ' "$dir/CLOSED" | cut -d' ' -f2 || true)
  if [ "$recorded" != "$state" ]; then
    echo "FAIL: CLOSED records '$recorded' but you invoked '$state'."
    echo "  Delete $dir/CLOSED and re-run if the record is wrong."
    exit 1
  fi
  echo "note: $slug already has a CLOSED record — resuming the interrupted archive step"
  resume=1
fi

# shipped is the state the gates exist for: it requires the ship approval AND a
# delivery that actually happened. Anything less closes as abandoned, dead-end,
# or handed-off.
if [ "$state" = "shipped" ]; then
  srec=".sdlc/approvals/${slug}.ship.approval"
  del="$dir/delivery.md"
  ev="$dir/evidence.md"
  if [ ! -f "$srec" ]; then
    echo "BLOCKED: 'shipped' requires a ship approval record."
    echo "  Pass the ship gate (gates/approve.sh ship .sdlc/work/$slug/evidence.md),"
    echo "  or close as abandoned|dead-end|handed-off."
    exit 1
  fi
  # re-check the ship gate here: the approval may predate content binding, and
  # evidence.md may have been rewritten after the human approved it
  want_ev=$(sdlc_field "$srec" artifact_sha256 || true)
  if [ -z "$want_ev" ]; then
    echo "BLOCKED: the ship approval for '$slug' predates content binding (no artifact_sha256)."
    echo "  Re-approve it: gates/approve.sh ship .sdlc/work/$slug/evidence.md"
    exit 1
  fi
  [ -f "$ev" ] || { echo "BLOCKED: approved evidence.md is missing: $ev"; exit 1; }
  if [ "$(sdlc_sha256_file "$ev")" != "$want_ev" ]; then
    echo "BLOCKED: $ev changed after the ship approval — the approved evidence is not the evidence on disk."
    echo "  Show the human what changed, then: gates/approve.sh ship $ev"
    exit 1
  fi
  # --- the reviewed source (_common.sh sdlc_source_state: one shared verdict
  # for status.sh, check-gate.sh and here) ------------------------------------
  snap="${srec%.approval}.source"
  src_state=""; want_code=""; now_code=""
  read -r src_state want_code now_code <<EOF
$(sdlc_source_state "$srec")
EOF
  case "$src_state" in
    legacy)
      echo "BLOCKED: the ship approval for '$slug' was written by an older kit."
      echo "  It bound only the files that were uncommitted at review time — nothing at all"
      echo "  when the work was already committed — so it cannot prove the source is unchanged."
      echo "  Re-run the ship review over the current source, then: gates/approve.sh ship $ev"
      exit 1;;
    nosnapshot)
      echo "BLOCKED: the source snapshot of the ship approval is missing ($snap)."
      echo "  Without it the recorded digest cannot be checked against the source on disk."
      echo "  Re-approve after a fresh ship review: gates/approve.sh ship $ev"
      exit 1;;
    drift)
      echo "BLOCKED: the source changed after the ship review (reviewed ${want_code%"${want_code#????????}"}…, now ${now_code%"${now_code#????????}"}…)."
      echo "  Staging or committing the reviewed bytes does NOT trip this; an edit, a new"
      echo "  file, a deletion, a chmod, or a symlink swap does."
      echo "  Changed since the review:"
      cur=$(mktemp "${TMPDIR:-/tmp}/sdlc-src.XXXXXX")
      sdlc_source_snapshot > "$cur" 2>/dev/null || true   # listing only: the verdict above already stands
      diffs=$(sdlc_source_drift_list "$snap" "$cur")
      rm -f "$cur"
      printf '%s\n' "$diffs" | head -n 20
      n=$(printf '%s\n' "$diffs" | awk 'NF' | wc -l | tr -d ' ')
      if [ "$n" -gt 20 ]; then echo "    … and $((n - 20)) more"; fi
      echo "  Re-run the ship review over the new diff, then: gates/approve.sh ship $ev"
      exit 1;;
    invalid)
      echo "BLOCKED: the source has a path name this kit cannot bind (git quotes it: a tab,"
      echo "  newline, double quote, or backslash in the name), so the ship binding cannot be checked:"
      { sdlc_source_snapshot 2>/dev/null || true; cat "$snap"; } | sdlc_source_unsupported_list | LC_ALL=C sort -u | awk 'NR <= 20'
      echo "  Rename or ignore that file, re-run the ship review, then: gates/approve.sh ship $ev"
      exit 1;;
    error)
      echo "BLOCKED: the current source snapshot could not be taken (a file or symlink could"
      echo "  not be read or hashed), so the ship binding cannot be checked:"
      { sdlc_source_snapshot 2>&1 >/dev/null || true; } | awk 'NR <= 20 { print "    " $0 }'
      echo "  Fix that, then close again."
      exit 1;;
    ok) ;;
    unbound)
      echo "note: no git repository here — the ship approval bound no source identity."
      echo "      The delivery below is recorded as NOT VERIFIED for its source.";;
    *)
      echo "BLOCKED: the ship source binding is in an unknown state ('${src_state:-empty}') — closed by default."
      exit 1;;
  esac
  # --- the upstream artifacts the ship review was granted on top of ------------
  # On the full route the ship approval binds intent.md, spec.md and plan.md as
  # they stood at review time (_common.sh sdlc_upstream_stages). They live under
  # .sdlc/, which the source snapshot excludes, so this is the only check that
  # sees them. Compact features have no spec.md or plan.md: nothing is demanded.
  for up in $(sdlc_upstream_stages ship); do
    upart="$dir/$(sdlc_artifact_of "$up")"
    upw=$(sdlc_field "$srec" "upstream_$up" || true)
    [ -n "$upw" ] || continue
    if [ ! -f "$upart" ]; then
      echo "BLOCKED: $upart was part of the approved ship basis and is now missing."
      echo "  Restore it, or re-run the ship review over what is actually there:"
      echo "  gates/approve.sh ship $ev"
      exit 1
    fi
    if [ "$(sdlc_sha256_file "$upart")" != "$upw" ]; then
      echo "BLOCKED: $upart changed after the ship review — the approval no longer covers what the human approved."
      echo "  Show the human what changed, re-approve $(sdlc_regate_of "$up"), then: gates/approve.sh ship $ev"
      exit 1
    fi
  done
  unbound_up=$(sdlc_upstream_unbound "$srec" "$slug")
  if [ -n "$unbound_up" ]; then
    echo "BLOCKED: the ship approval for '$slug' binds no digest for$(for u in $unbound_up; do printf ' %s' "$(sdlc_artifact_of "$u")"; done)."
    echo "  Those artifacts exist but were never part of the approved basis (an older"
    echo "  kit's record, or written after the approval), so a rewrite would ride along."
    echo "  Re-run the ship review, then: gates/approve.sh ship $ev"
    exit 1
  fi
  # --- the delivery record (templates/delivery.md) -----------------------------
  if [ ! -f "$del" ]; then
    echo "BLOCKED: 'shipped' requires a delivery record: $del"
    echo "  Copy $kit/templates/delivery.md and fill in what was actually delivered"
    echo "  (target, source, the command you verified it with, its output)."
    echo "  Not delivered yet? Close as handed-off|abandoned|dead-end instead."
    exit 1
  fi
  issue=$(sdlc_delivery_issue "$del" "$src_state" "$want_code" "$now_code")
  token=${issue%% *}; detail=${issue#* }
  d_target=$(sdlc_delivery_field "$del" Target | awk '{print tolower($1)}')
  d_by=$(sdlc_delivery_field "$del" Verified-by)
  case "$token" in
    ok) ;;
    unbound) echo "NOT VERIFIED: $detail";;
    *)
      echo "BLOCKED: delivery.md $detail."
      case "$token" in
        unconfirmed)      echo "  Verify the result with a real command and record it, or close as handed-off.";;
        worktree-remote)  echo "  Record the delivered commit sha in delivery.md's Source line.";;
        source-mismatch)  echo "  Re-verify the delivery and record the current source identity.";;
        source-not-commit) echo "  Record the sha you actually delivered (git rev-parse HEAD after the push).";;
        source-content)
          echo "  The commit exists, but its tree is not the source the ship review saw."
          echo "  Commit the reviewed source (or deliver the commit that has it) and record THAT sha.";;
        source-unsupported)
          echo "  That commit has a path name git quotes (tab, newline, double quote, or backslash);"
          echo "  the kit cannot bind it. Rename the file, re-review, re-approve, and deliver again.";;
        source-error)     echo "  Check that the commit's objects are readable (git fsck) and try again.";;
        target|placeholder) echo "  Fill the record in from $kit/templates/delivery.md.";;
        source)           echo "  Re-approve ship over the current source, then re-record the delivery.";;
      esac
      exit 1;;
  esac
  # --- the automated review handoff (v0.10 fields), OPT-IN ---------------------
  # A pre-0.10 delivery.md has no Handoff line and closes exactly as it always
  # did: `Verified-by` is the human's record of a check a human ran. But a record
  # that CLAIMS the automation's exit condition ("Handoff: review-ready") must
  # survive the automation's own check — otherwise a line an agent wrote would
  # be the only evidence that a reviewer has anything to read (AGENTS.md rule 6:
  # facts are established, never asserted in prose).
  d_handoff=$(sdlc_delivery_field "$del" Handoff | awk '{print tolower($1)}')
  case "$d_handoff" in
    review-ready|merged|deployed)
      d_remote=$(sdlc_delivery_field "$del" Remote)
      d_branch=$(sdlc_delivery_field "$del" Branch)
      d_source=$(sdlc_delivery_field "$del" Source)
      if [ -z "$d_remote" ] || [ -z "$d_branch" ]; then
        echo "BLOCKED: delivery.md says 'Handoff: $d_handoff' but names no Remote/Branch,"
        echo "  so the branch a reviewer would read cannot be identified, let alone checked."
        echo "  Add '- Remote: <remote>' and '- Branch: <feature branch>', or drop the Handoff"
        echo "  line and close this as the ordinary delivery it is."
        exit 1
      fi
      d_remote_sha=$(git ls-remote "$d_remote" "refs/heads/$d_branch" 2>/dev/null | awk 'NR==1{print $1}')
      d_local_sha=$(git rev-parse --verify --quiet "${d_source}^{commit}" 2>/dev/null || echo none)
      if [ -z "$d_remote_sha" ]; then
        echo "BLOCKED: $d_remote/$d_branch does not exist on the remote."
        echo "  'Handoff: $d_handoff' claims a reviewer has something to read; they have not."
        echo "  Push it (tools/handoff.sh push $slug --authorized \"<the human's words>\"), or"
        echo "  correct delivery.md."
        exit 1
      fi
      if [ "$d_remote_sha" != "$d_local_sha" ]; then
        echo "BLOCKED: $d_remote/$d_branch is at $d_remote_sha, the delivered Source is $d_local_sha."
        echo "  The reviewer would read other code than this feature delivered."
        exit 1
      fi
      echo "handoff: $d_handoff — $d_remote/$d_branch @ $d_remote_sha (checked with git ls-remote)"
      case "$d_handoff" in
        merged|deployed)
          echo "  NOTE: that the branch was $d_handoff is NOT verified here — a feature ref on a"
          echo "  remote is not a merge commit and not a deployment. delivery.md's Verified-by"
          echo "  ('$d_by') is the human's record of that step, not a check this kit ran.";;
      esac;;
  esac
  echo "delivery: $d_target — verified by '$d_by'"
fi

# handed-off closes must name the external reference in the reason
if [ "$state" = "handed-off" ]; then
  if ! echo "$reason" | grep -qE '[A-Z][A-Z0-9]+-[0-9]+|https?://'; then
    echo "BLOCKED: handed-off requires the external ticket/PR reference in the reason"
    echo "  (a key like A20-1240 or a URL), so the trail does not dead-end here."
    exit 1
  fi
fi

# shared memory has ONE writer — the close step (AGENTS.md rule 4). A leftover
# harvest.md means lesson/domain candidates were never merged into memory/.
if [ -f "$dir/harvest.md" ]; then
  echo "BLOCKED: unmerged harvest: $dir/harvest.md"
  echo "  Merge it into .sdlc/memory/ (lesson files + INDEX.md lines + DOMAIN.md"
  echo "  facts), delete the file, then re-run. Close is the single-writer moment."
  exit 1
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
# Everything ignored under work/ must be ignored under archive/ too: the mv
# below moves the dir verbatim, so an unlisted pattern (a leftover scratch dir
# from an abandoned close) would be committed with the archive. spec.md,
# evidence.md, and delivery.md are NOT here: the decision record and the final
# proof are durable (AGENTS.md rule 7). Read via tr -d '\r' (a CRLF
# .gitignore would never match) and match with case, not grep -q (init.sh
# ensure_line explains the pipefail/SIGPIPE trap).
if [ -n "$in_git" ]; then
  for line in '.sdlc/archive/*/scratch/' '.sdlc/archive/*/progress.md' \
              '.sdlc/archive/*/approvals/' '.sdlc/archive/*/baseline.txt' \
              '.sdlc/archive/*/deviations.md' '.sdlc/archive/*/harvest.md'; do
    have=""
    if [ -f .gitignore ]; then have=$(tr -d '\r' < .gitignore); fi
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
  done
fi
if [ -d "$dir/scratch" ] && [ -n "$(ls -A "$dir/scratch" 2>/dev/null)" ]; then
  echo "note: scratch/ still has files — archived with the feature but gitignored."
  echo "      Scratch lifecycle (AGENTS.md rule 5): it survives the push and is pruned HERE."
  echo "      Delete what nothing cites; KEEP anything evidence.md, delivery.md, or a lesson"
  echo "      points at, and say so in the lesson so the next reader knows it is load-bearing."
fi
mv "$dir" "$archive"
# "$slug".* also catches .approval.history files (re-gate trail, approve.sh)
if ls .sdlc/approvals/"$slug".* >/dev/null 2>&1; then
  mkdir -p "$archive/approvals"
  mv .sdlc/approvals/"$slug".* "$archive/approvals/"
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
  # approvals are gitignored now, but a project seeded by an older kit still
  # tracks them and the mv above deleted those paths — stage the deletion or
  # it lingers in HEAD forever
  [ -n "$(git ls-files .sdlc/approvals 2>/dev/null)" ] && paths="$paths.sdlc/approvals "
  echo "Then commit the close (decisions, evidence, delivery, lessons; scratch stays local):"
  echo "  git add $paths\"$archive\" .sdlc/memory .sdlc/config.md .gitignore"
  echo "(git records the work/→archive/ move as a rename; history follows it)."
fi
