#!/usr/bin/env bash
# approve.sh <stage> <artifact-path> [flags] — records a gate approval.
#
# Stages and their one legal artifact: intent→intent.md, spec→spec.md,
# plan→plan.md, ship→evidence.md, all under .sdlc/work/<slug>/ in THIS project.
#
# Intent, spec, and ship approvals are HUMAN decisions: run directly, or
# --delegated after the human's explicit approval in chat. For the plan stage
# ONLY, --agent-adversary records the tiered auto-approval. --lazy records an
# auto-approval for a gate that `lazymode:` in .sdlc/config.md waives (AGENTS.md
# rule 3) and REQUIRES --review "<what was actually reviewed>": lazymode moves
# the human checkpoint, it never removes the review.
# --risk-authorized "<the human's words>" records prior authorization for risky
# work (data loss, public API, security, migrations, external delivery); an
# automated risk hit on the artifact makes it mandatory for --lazy.
#
# The record binds: the canonical artifact path, the artifact's sha256, and the
# digests of the upstream artifacts it was approved against — plus, at ship, the
# reviewed code identity. sha256 is CHANGE DETECTION, not authentication.
# The records are gitignored, so the trail is .sdlc/approvals/ in the working
# copy and does not survive a fresh clone.
set -euo pipefail
kit="$(cd "$(dirname "$0")/.." && pwd)"
. "$kit/gates/_common.sh"

usage() {
  cat >&2 <<'EOF'
usage: approve.sh <intent|spec|plan|ship> <artifact-path> [flags]   (run from the project root)
  --delegated                  human approved this artifact explicitly in chat
  --agent-adversary            plan stage only: adversary passed, no trip-wires
  --lazy                       lazymode waives this human gate (needs --review)
  --review "<text>"            what the review actually covered (code/behavior, not a keyword scan)
  --risk-authorized "<text>"   the human's prior authorization for risky work
EOF
  exit 1
}

mode=""; review=""; risk_auth=""
[ $# -ge 2 ] || usage
stage="$1"; artifact="$2"; shift 2
while [ $# -gt 0 ]; do
  case "$1" in
    --delegated) mode="delegated-chat (agent-run on explicit human instruction)";;
    --agent-adversary) mode="agent-adversary (auto-approved: adversary review passed, no trip-wires)";;
    --lazy) mode="lazy";;
    --review) [ $# -ge 2 ] || usage; review="$2"; shift;;
    --review=*) review="${1#--review=}";;
    --risk-authorized) [ $# -ge 2 ] || usage; risk_auth="$2"; shift;;
    --risk-authorized=*) risk_auth="${1#--risk-authorized=}";;
    *) usage;;
  esac
  shift
done

# mode policy lives in AGENTS.md hard rule 3 (single source of truth).
case "$mode" in (agent-adversary*)
  [ "$stage" = "plan" ] || { echo "FAIL: --agent-adversary is valid for the plan stage only (AGENTS.md rule 3)"; exit 1; };;
esac

expected=$(sdlc_stage_artifact "$stage") || {
  echo "FAIL: '$stage' is not a gated stage. Gated stages: intent, spec, plan, ship."; exit 1; }
[ -d .sdlc ] || { echo "FAIL: no .sdlc/ here. Run init.sh first, from the project root."; exit 1; }

canon=$(sdlc_canon_artifact "$artifact") || { echo "FAIL: $stage approval refused — see the reason above."; exit 1; }
[ "$(basename "$canon")" = "$expected" ] || {
  echo "FAIL: the '$stage' gate binds $expected, not $(basename "$canon"). Approve $(dirname "$canon")/$expected instead."; exit 1; }
slug=$(sdlc_slug_of "$canon")
# slugs are single-use: a reused archived slug would strand the new work at
# close time and cross-wire stats with the archived feature's records
[ -d ".sdlc/archive/$slug" ] && { echo "FAIL: slug '$slug' is already closed and archived (.sdlc/archive/$slug) — pick a new slug (skills/1-intent)"; exit 1; }

# --- track: compact vs full -------------------------------------------------
# The compact route (skills/1-intent) runs intent → build → ship on ONE work
# artifact. `micro` is the older spelling of the same verdict and still parses.
track=""; spelling=""
if [ "$stage" = "intent" ]; then
  if grep -qiE '^- *track: *(compact|micro)([^a-z]|$)' "$canon"; then
    track=compact
    grep -qiE '^- *track: *micro([^a-z]|$)' "$canon" && spelling=micro || true
  else
    track=full
  fi
fi
# A track upgrade revalidates the approvals it changes: a compact intent
# approval authorized a loop with NO spec and NO plan gate, so it cannot also
# authorize a spec or plan built on top of it.
irec=".sdlc/approvals/${slug}.intent.approval"
case "$stage" in (spec|plan)
  if [ -f "$irec" ] && [ "$(sdlc_field "$irec" track || true)" = "compact" ]; then
    echo "FAIL: '$slug' is on the compact track — its intent approval covers no $stage gate."
    echo "  Upgrading to the full track revalidates the intent approval:"
    echo "  rewrite intent.md's Track line to 'full — upgraded from compact (<reason>)',"
    echo "  re-approve intent, then approve $stage."
    exit 1
  fi;;
esac

# --- risk authority ----------------------------------------------------------
# The keyword scan is SUPPLEMENTAL: a hit can add a requirement, a clean scan
# can never remove one (it reads English keywords and misses everything else).
risk_hit=""; scan_ran=""
if [ -f "$kit/tools/tripwire.sh" ]; then
  scan_ran=1
  # captured, not piped into grep -q: an early-exiting grep SIGPIPEs the scan and
  # pipefail would read that as "clean" — failing OPEN on exactly the risky case
  scan=$(bash "$kit/tools/tripwire.sh" "$canon" 2>/dev/null || true)
  case "$scan" in (*"TRIP-WIRE?"*) risk_hit=1;; esac
fi
if [ "$stage" = plan ] && grep -qiE '^- *tier: *human' "$canon"; then risk_hit=1; fi

if [ "$mode" = "lazy" ]; then
  [ -n "$review" ] || {
    echo "FAIL: --lazy needs --review \"<what the review actually covered>\"."
    echo "  lazymode moves the human checkpoint; it does not remove the review of the"
    echo "  affected code and behavior (AGENTS.md rule 3)."
    exit 1; }
  if [ -n "$risk_hit" ] && [ -z "$risk_auth" ]; then
    echo "FAIL: this artifact shows risky work and no prior authorization is recorded."
    echo "  Re-run with --risk-authorized \"<the human's words authorizing it>\","
    echo "  or take the decision to the human (AGENTS.md rule 3, risky-action authority)."
    exit 1
  fi
fi

# lazymode policy (AGENTS.md rule 3): the level in .sdlc/config.md decides which
# human gates are waived — plan at >=1, spec at >=2, ship at >=3, intent at >=4.
if [ "$mode" = "lazy" ]; then
  # \r stripped: a CRLF-saved config must not silently disable lazymode
  lm_raw=$(awk '/^lazymode: /{gsub(/\r/,""); print $2; exit}' .sdlc/config.md 2>/dev/null || true)
  lm="$lm_raw"
  # anything outside 0-4 fails CLOSED — a typo must never grant a wider waiver
  case "$lm" in (''|*[!0-9]*) lm=0;; (*) [ "$lm" -le 4 ] || lm=0;; esac
  case "$stage" in plan) need=1;; spec) need=2;; ship) need=3;; intent) need=4;; esac
  if [ "$lm" -lt "$need" ]; then
    echo "FAIL: lazymode '${lm_raw:-unset}' keeps the '$stage' gate HUMAN (--lazy needs lazymode >= $need, valid range 0-4, in .sdlc/config.md). A human must approve."
    exit 1
  fi
  mode="lazy (auto-approved: lazymode $lm waives the $stage human gate; review recorded below)"
fi

mkdir -p .sdlc/approvals
rec=".sdlc/approvals/${slug}.${stage}.approval"
snap="${rec%.approval}.source"

# --- reviewed source identity (ship only) ------------------------------------
# Bound BEFORE the record is written, so an empty binding can refuse instead of
# looking like a binding. The snapshot is the whole project source (_common.sh),
# which is what makes the binding hold for work that was committed before the
# review — the case an uncommitted-diff binding covered with nothing.
code_scope=""; code_digest=""; code_count=0; entries=""
if [ "$stage" = ship ]; then
  if git rev-parse --git-dir >/dev/null 2>&1; then
    # every failure here is checked explicitly: a snapshot that could not be
    # taken, or that names a path this kit cannot bind, refuses BEFORE any
    # record is written — never an empty digest, never a placeholder entry
    entries=$(sdlc_source_snapshot) || {
      echo "FAIL: the source snapshot could not be taken (see the reason above)."
      echo "  A ship approval whose snapshot is incomplete would bind less than the review saw."
      exit 1; }
    if [ -z "$entries" ]; then
      echo "FAIL: no source files found to bind (tracked + unignored untracked, excluding .sdlc/)."
      echo "  A ship approval that binds nothing cannot detect a post-review change."
      echo "  Add the source to this repository (or un-ignore it) and re-run."
      exit 1
    fi
    n_unsup=$(printf '%s\n' "$entries" | sdlc_entries_unsupported)
    if [ "$n_unsup" != 0 ]; then
      echo "FAIL: unsupported path name(s) — git quotes them (a tab, newline, double quote, or backslash in the name):"
      printf '%s\n' "$entries" | sdlc_source_unsupported_list
      echo "  The kit cannot hash or watch such a path, so it cannot bind the source. Rename"
      echo "  (or ignore) those files and re-run. Unicode and spaces in names are fine."
      exit 1
    fi
    code_scope="project (tracked + unignored untracked, excluding .sdlc/)"
    code_digest=$(printf '%s\n' "$entries" | sdlc_entries_digest) || code_digest=""
    [ -n "$code_digest" ] || { echo "FAIL: could not hash the source snapshot (no sha256 tool?)."; exit 1; }
    code_count=$(printf '%s\n' "$entries" | awk 'NF' | wc -l | tr -d ' ')
  else
    code_scope="none"
    code_digest="none"
    echo "note: not a git repository — no source identity can be bound (delivery will say NOT VERIFIED)."
  fi
fi

# Re-approvals must leave a trail: approval records are gitignored (init.sh),
# so git history holds no approvals at all and the re-gate cap (AGENTS.md
# rule 3) is counted from disk — this .history file is the only trail there is.
if [ -f "$rec" ]; then
  { echo "--- superseded at $(date -u +%Y-%m-%dT%H:%M:%SZ)"; cat "$rec"; } >> "${rec}.history"
fi

digest=$(sdlc_sha256_file "$canon")
{
  echo "stage: $stage"
  echo "artifact: $canon"
  echo "artifact_sha256: $digest"
  echo "approved_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [ -n "$track" ] && echo "track: $track" || true
  [ -n "$spelling" ] && echo "track_spelling: $spelling" || true
  # upstream binding: whatever this gate was approved ON TOP of
  for up in $(sdlc_upstream_stages "$stage"); do
    upart=".sdlc/work/$slug/$(sdlc_artifact_of "$up")"
    if [ -f "$upart" ]; then echo "upstream_$up: $(sdlc_sha256_file "$upart")"; fi
  done
  if [ "$stage" = ship ]; then
    # the reviewed SOURCE state, so close.sh can prove the delivered source is
    # the source the ship review looked at (paths + content + mode, never index
    # or commit identity). The entry list itself goes to <slug>.ship.source.
    echo "code_head: $(git rev-parse HEAD 2>/dev/null || echo none)"
    echo "code_scope: $code_scope"
    echo "code_digest: $code_digest"
    echo "code_files: $code_count"
  fi
  [ -n "$review" ] && echo "review: $review" || true
  [ -n "$risk_auth" ] && echo "risk_authority: $risk_auth" || true
  # the scan leaves a trace either way: a record with no risk_scan line would be
  # indistinguishable from one where risk was never considered
  if [ -n "$risk_hit" ]; then echo "risk_scan: hit (supplemental heuristic — not a verdict)"
  elif [ -n "$scan_ran" ]; then echo "risk_scan: clean (English keyword scan only — clears nothing, authorizes nothing)"
  fi
  [ -n "$mode" ] && echo "mode: $mode" || true
  [ -n "$mode" ] && echo "runner: agent" || true
} > "$rec"
echo "APPROVED: $stage of $slug ($canon)"
if [ "$stage" = ship ]; then
  # the entry list lives beside the record (gitignored with it) so close.sh and
  # status.sh can name exactly WHAT changed, not just that something did
  rm -f "$snap"
  if [ "$code_scope" != none ]; then printf '%s\n' "$entries" > "$snap"; else : > "$snap"; fi
  echo "Reviewed source identity: $code_digest ($code_count files, scope: $code_scope)"
  if [ "$code_scope" = none ]; then
    echo "  NOT BOUND: no git repository — close.sh will record the delivery as NOT VERIFIED."
  else
    echo "  delivery.md Source: the delivered commit sha (it must CONTAIN this source)"
    echo "                      — or, for a local target, worktree:$code_digest"
  fi
fi
echo "Bound to that path and its current content (sha256 ${digest%"${digest#????????}"}…)."
echo "Recorded on disk. Approval records are gitignored — the trail is .sdlc/approvals/, not git history."
