#!/usr/bin/env bash
# status.sh [--json] [--all[=<n>]] [slug] — cockpit: where is each OPEN feature in the
# loop, what is the next action. Closed features live in .sdlc/archive/
# (close.sh moves them); --all lists the newest 20, --all=<n> widens that.
# A slug argument finds archived features without --all. Run from the project
# root (needs .sdlc/).
set -euo pipefail
kit_self="$(cd "$(dirname "$0")/.." && pwd)"
. "$kit_self/gates/_common.sh"
. "$kit_self/gates/_auto.sh"
[ -d .sdlc ] || { echo "FAIL: no .sdlc/ here. Run init.sh first, from the project root."; exit 1; }
# --json is the MACHINE view of the same state (tools/auto.sh, schema
# sdlc-kit/auto-status@1): stage · status · next action · blockers · source
# identity, for a driver that must not parse the prose below. One
# implementation, shared through gates/_common.sh, so the two cannot disagree.
# It covers OPEN features only; --all is a prose-only flag, and a closed feature
# is answered by tools/auto.sh next <slug>.
if [ "${1:-}" = --json ]; then
  shift
  exec "$kit_self/tools/auto.sh" status --json "$@"
fi
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
    echo "      re-run $kitdir/init.sh for the current .gitignore set; it lists what to untrack"
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
  intent) echo "skills/2-spec";; spec) echo "skills/3-plan";; plan) echo "skills/4-build then 5-ship";;
  ship) echo "commit per skills/5-ship discipline, record delivery.md, then close.sh <slug> shipped";; esac; }
skill_for() { case "$1" in
  intent) echo "skills/1-intent";; spec) echo "skills/2-spec";; plan) echo "skills/3-plan";; ship) echo "skills/4-build+5-ship";; esac; }

found=0
for dir in .sdlc/work/*/; do
  [ -d "$dir" ] || continue
  slug=$(basename "$dir")
  # a directory name that is not a usable slug is reported as itself: it names
  # no feature, and nothing here should paste it into a command
  if ! sdlc_auto_valid_slug "$slug"; then
    found=1
    echo "== $slug"
    echo "   UNUSABLE NAME: a feature directory must be [a-zA-Z0-9._-]+ — rename it; no gate is evaluated for this directory"
    continue
  fi
  [ $# -ge 1 ] && [ "$slug" != "$1" ] && continue
  found=1
  if [ -f "${dir}CLOSED" ]; then
    cstate=$(grep '^state: ' "${dir}CLOSED" | cut -d' ' -f2)
    creason=$(grep '^reason: ' "${dir}CLOSED" | cut -d' ' -f2-)
    echo "== $slug   [CLOSED: $cstate] $creason"
    continue
  fi
  # compact route (skills/1-intent): no spec, no plan — one work artifact
  # (intent.md), the intent gate opens build. `micro` is the older spelling of
  # the same verdict. ([^a-z]|$) keeps "microservice-…" from reading as compact.
  micro=""
  if [ -f "${dir}intent.md" ] && grep -qiE '^- *track: *(compact|micro)([^a-z]|$)' "${dir}intent.md"; then
    micro=1
  fi
  # self-healing: a spec.md on disk means the feature went full track,
  # whatever the Track line says (compact→full upgrades can forget the edit)
  if [ -f "${dir}spec.md" ]; then micro=""; fi
  # the intent approval froze the Track verdict (approve.sh): a Track line
  # rewritten to compact AFTER approval does not skip spec/plan
  irec=".sdlc/approvals/${slug}.intent.approval"
  if [ -n "$micro" ] && [ -f "$irec" ] && [ "$(sdlc_field "$irec" track || true)" != "compact" ]; then
    micro=""
    echo "note: $slug intent.md says compact but the intent approval was granted full-track — re-approve intent or revert the Track line"
  fi
  echo "== $slug${micro:+   (compact)}"
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
  # A feature started under the OLD compressed maintain loop has a plan.md (and
  # maybe its approval) but no intent.md. It is not lost and its gates are not
  # waived: name the continuation path instead of demanding an artifact nobody
  # wrote (skills/6-maintain "Continuing older compressed work").
  if [ ! -f "${dir}intent.md" ] && [ -f "${dir}plan.md" ]; then
    echo "   LEGACY COMPRESSED: plan.md without intent.md (pre-compact-route feature)"
    echo "   continue → write intent.md (Track: compact) and pass the intent gate; the existing plan approval stays on record but does not open build"
    [ -z "$next_action" ] && next_action="write intent.md for $slug (skills/6-maintain 'Continuing older compressed work')"
  fi
  loop_stages="$stages"
  if [ -n "$micro" ]; then loop_stages="intent ship"; fi
  src_state=""; src_want=""; src_now=""   # per feature: never leak the previous one
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
          next_action="plan gate (lazymode $lazy): gates/approve.sh plan $art --lazy --review \"<what the adversary checked>\" (AGENTS.md rule 3)"
        elif [ "$lazy" -ge "$(lazy_min "$stage")" ]; then
          if [ "$stage" = ship ]; then
            next_action="lazy gate (lazymode $lazy): gates/approve.sh ship $art --lazy --review \"<the diff review>\" (AGENTS.md rule 3)"
          else
            next_action="lazy gate (lazymode $lazy): gates/approve.sh $stage $art --lazy --review \"<the review you ran over the affected code/behavior>\" (AGENTS.md rule 3)"
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
      # the record binds a path and a content digest (approve.sh). Report a
      # stale binding here, in the same words check-gate.sh uses.
      want=$(sdlc_field "$rec" artifact_sha256 || true)
      if [ -z "$want" ]; then
        state="$state — STALE: record predates content binding, re-approve"
        [ -z "$next_action" ] && next_action="re-approve $stage: gates/approve.sh $stage $art (old record, no content binding)"
      elif [ "$(sdlc_sha256_file "$art")" != "$want" ]; then
        state="$state — STALE: artifact changed since approval"
        [ -z "$next_action" ] && next_action="$art changed after approval — show the human the change, then gates/approve.sh $stage $art"
      else
        for up in $(sdlc_upstream_stages "$stage"); do
          upw=$(sdlc_field "$rec" "upstream_$up" || true)
          upart="$dir$(artifact_for "$up")"
          [ -n "$upw" ] || continue
          if [ ! -f "$upart" ] || [ "$(sdlc_sha256_file "$upart" 2>/dev/null || true)" != "$upw" ]; then
            state="$state — STALE: $(artifact_for "$up") changed since approval"
            [ -z "$next_action" ] && next_action="upstream $(artifact_for "$up") changed — re-approve $up, then $stage"
          fi
        done
        # an upstream artifact on disk that this record binds with nothing (older
        # kit's record, or written after the approval). Absent ones are the
        # compact route and are never demanded here.
        for up in $(sdlc_upstream_unbound "$rec" "$slug"); do
          state="$state — STALE: $(artifact_for "$up") not bound by this approval"
          [ -z "$next_action" ] && next_action="$(artifact_for "$up") is not part of the approved $stage basis — re-approve: gates/approve.sh $stage $art"
        done
      fi
    fi
    # the ship approval also binds the reviewed source (_common.sh): report the
    # SAME verdict close.sh will enforce, so nothing looks closeable here and is
    # refused there for a reason status never showed.
    if [ "$stage" = ship ] && [ -f "$rec" ]; then
      src_state=""; src_want=""; src_now=""
      read -r src_state src_want src_now <<EOF
$(sdlc_source_state "$rec")
EOF
      case "$src_state" in
        drift)
          state="$state — SOURCE DRIFT: source changed since the ship review"
          [ -z "$next_action" ] && next_action="source changed after the ship review — re-run the ship review over the new diff, then gates/approve.sh ship $art";;
        legacy)
          state="$state — STALE: record predates source binding, re-approve"
          [ -z "$next_action" ] && next_action="re-approve ship: gates/approve.sh ship $art (old record, its source binding covered only the uncommitted diff)";;
        nosnapshot)
          state="$state — STALE: the recorded source snapshot is missing, re-approve"
          [ -z "$next_action" ] && next_action="re-approve ship: gates/approve.sh ship $art (source snapshot gone)";;
        invalid)
          state="$state — INVALID SOURCE: a path name the kit cannot bind (git quotes it)"
          [ -z "$next_action" ] && next_action="rename or ignore the file whose name git quotes (tab, newline, double quote, or backslash), re-run the ship review, then gates/approve.sh ship $art";;
        error)
          state="$state — SOURCE UNREADABLE: the current snapshot could not be taken"
          [ -z "$next_action" ] && next_action="a source file or symlink could not be read or hashed — fix it, then re-check (gates/check-gate.sh ship $art)";;
        ok) ;;
        unbound)
          state="$state — source NOT BOUND (no git repository)";;
        *)
          state="$state — source binding in an unknown state ('${src_state:-empty}'): NOT closeable"
          [ -z "$next_action" ] && next_action="re-approve ship: gates/approve.sh ship $art";;
      esac
    fi
    printf "  %-8s %s\n" "$stage" "$state"
  done
  # The full-auto intent contract (gates/_auto.sh), in the SAME words the
  # machine view uses. This is the screen an agent actually reads: if it showed
  # "record the intent approval" while tools/auto.sh said "a human owes an
  # answer", the cockpit would walk the loop straight over an open material
  # question. It overrides the next action rather than queueing behind it.
  if [ -f "${dir}intent.md" ] && [ ! -f ".sdlc/approvals/${slug}.intent.approval" ]; then
    ist=$(sdlc_auto_intent_contract "$slug")
    case "${ist%%|*}" in
      material)
        printf "  %-8s %s — %s\n" "intent" "MATERIAL QUESTION OPEN" "${ist#*|}"
        # at lazymode 4 the intent gate is the agent's to record, so this is the
        # only thing standing between an open question and an approval
        if [ "$lazy" -ge 4 ]; then
          next_action="a MATERIAL question in ${dir}intent.md is unanswered: take it to the human. The intent gate is NOT recorded until it is answered, lazymode 4 included (AGENTS.md rule 3a)"
        fi;;
      incomplete)
        printf "  %-8s %s — %s\n" "intent" "CONTRACT INCOMPLETE" "${ist#*|}"
        if [ "$lazy" -ge 4 ]; then
          next_action="complete ${dir}intent.md before the intent gate: ${ist#*|}"
        fi;;
    esac
  fi
  # shipped means delivered (AGENTS.md rule 6): after the ship gate the feature
  # still owes a delivery record before close.sh will accept 'shipped'.
  if [ -f ".sdlc/approvals/${slug}.ship.approval" ]; then
    if [ -f "${dir}delivery.md" ]; then
      if [ -z "$src_state" ]; then   # evidence.md gone: read the record anyway
        read -r src_state src_want src_now <<EOF
$(sdlc_source_state ".sdlc/approvals/${slug}.ship.approval")
EOF
      fi
      dtarget=$(sdlc_delivery_field "${dir}delivery.md" Target | awk '{print $1}')
      # same verdict function close.sh blocks on (_common.sh)
      issue=$(sdlc_delivery_issue "${dir}delivery.md" "$src_state" "$src_want" "$src_now")
      dtoken=${issue%% *}; ddetail=${issue#* }
      case "$dtoken" in
        ok)      printf "  %-8s %s\n" "delivery" "recorded (${dtarget:-?}) — confirmed";;
        unbound) printf "  %-8s %s\n" "delivery" "recorded (${dtarget:-?}) — NOT VERIFIED: $ddetail";;
        *)
          printf "  %-8s %s\n" "delivery" "recorded (${dtarget:-?}) — NOT CLOSEABLE: $ddetail"
          [ -z "$next_action" ] && next_action="fix the delivery record (${dir}delivery.md): $ddetail";;
      esac
      # A delivery.md that CLAIMS the automation's exit condition is checked
      # against the remote by close.sh and by tools/auto.sh. This view does not
      # touch the network, so it reports the claim as a claim — never as a
      # delivery that has been confirmed to be where a reviewer can read it.
      dhandoff=$(sdlc_delivery_field "${dir}delivery.md" Handoff | awk '{print tolower($1)}')
      case "$dhandoff" in
        review-ready|merged|deployed)
          dremote=$(sdlc_delivery_field "${dir}delivery.md" Remote)
          dbranch=$(sdlc_delivery_field "${dir}delivery.md" Branch)
          if [ -z "$dremote" ] || [ -z "$dbranch" ]; then
            printf "  %-8s %s\n" "handoff" "claims '$dhandoff' but names no Remote/Branch — NOT CLOSEABLE"
            [ -z "$next_action" ] && next_action="add '- Remote:' and '- Branch:' to ${dir}delivery.md, or drop the Handoff line"
          else
            printf "  %-8s %s\n" "handoff" "claims '$dhandoff' on ${dremote}/${dbranch} — NOT CHECKED HERE (no network): tools/handoff.sh check $slug"
          fi;;
      esac
    else
      printf "  %-8s %s\n" "delivery" "—  (no delivery.md)"
      [ -z "$next_action" ] && next_action="deliver, then record it in ${dir}delivery.md (templates/delivery.md) before close.sh <slug> shipped"
    fi
  fi
  # verification receipt (tools/verify.sh): the same verdict the machine view
  # reports, so a feature never looks review-ready here and blocked there.
  if [ -f .sdlc/verify.md ]; then
    vst=$(sdlc_verify_state "$slug")
    printf "  %-8s %s — %s\n" "verify" "${vst%%|*}" "${vst#*|}"
    case "${vst%%|*}" in
      fail|stale|missing|blocked)
        [ -z "$next_action" ] && next_action="verification: ${vst#*|}";;
    esac
  fi
  # heartbeat (AGENTS.md rule 9): the live one-liner plus its age, so silence
  # and a dead loop look different. BSD stat first (macOS), then GNU.
  if [ -s "${dir}progress.md" ]; then
    hb=$(head -n1 "${dir}progress.md" | tr -d '\r')
    mt=$(stat -f %m "${dir}progress.md" 2>/dev/null || stat -c %Y "${dir}progress.md" 2>/dev/null || true)
    age=""
    case "$mt" in (*[!0-9]*|'') mt="";; esac
    if [ -n "$mt" ]; then
      s=$(( $(date +%s) - mt )); [ "$s" -lt 0 ] && s=0
      if [ "$s" -lt 60 ]; then age="${s}s ago"
      elif [ "$s" -lt 3600 ]; then age="$((s / 60))m ago"
      else age="$((s / 3600))h ago"; fi
      [ "$s" -gt 1800 ] && age="$age — STALE"
    fi
    echo "  now   →  $hb${age:+  ($age)}"
  fi
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
