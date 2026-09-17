#!/usr/bin/env bash
# check-gate.sh <stage> <artifact-path> — run by the AGENT before starting the
# next stage, from the project root.
# Exit 0 = GATE OPEN. Any other outcome is closed, and always says why.
#
# The gate is open only when the approval record binds THIS path, the artifact
# is byte-identical to the approved one, and every upstream artifact the
# approval was granted on top of is unchanged too. A record written by an older
# kit (no digest) fails closed with the re-approval command.
set -euo pipefail
kit="$(cd "$(dirname "$0")/.." && pwd)"
. "$kit/gates/_common.sh"

usage() { echo "usage: check-gate.sh <intent|spec|plan|ship> <artifact-path>"; exit 1; }
[ $# -eq 2 ] || usage
stage="$1"; artifact="$2"
closed() { echo "GATE CLOSED: $1"; exit 1; }

sdlc_stage_artifact "$stage" >/dev/null 2>&1 || closed "'$stage' is not a gated stage (intent, spec, plan, ship)"
canon=$(sdlc_canon_artifact "$artifact" 2>/dev/null) || closed "artifact is not a gated artifact of this project: $artifact (it must be .sdlc/work/<slug>/<file> under the project root, no symlinks)"
slug=$(sdlc_slug_of "$canon")
rec=".sdlc/approvals/${slug}.${stage}.approval"

[ -f "$rec" ] || closed "no approval for '$stage' of '$slug'. Needed: gates/approve.sh $stage $canon (human decision, or --lazy when lazymode waives this gate — AGENTS.md rule 3)"

recorded_path=$(sdlc_field "$rec" artifact || true)
[ "$recorded_path" = "$canon" ] || closed "the '$stage' approval of '$slug' binds '${recorded_path:-?}', not '$canon'. Approve the artifact you are about to use."
[ -f "$canon" ] || closed "approved artifact missing: $canon"

recorded_digest=$(sdlc_field "$rec" artifact_sha256 || true)
[ -n "$recorded_digest" ] || closed "the '$stage' approval of '$slug' predates content binding (no artifact_sha256). Re-approve it: gates/approve.sh $stage $canon"

now=$(sdlc_sha256_file "$canon")
[ "$now" = "$recorded_digest" ] || closed "$canon changed after it was approved. Show the human what changed, then re-approve: gates/approve.sh $stage $canon"

for up in $(sdlc_upstream_stages "$stage"); do
  upart=".sdlc/work/$slug/$(sdlc_artifact_of "$up")"
  want=$(sdlc_field "$rec" "upstream_$up" || true)
  [ -n "$want" ] || continue
  [ -f "$upart" ] || closed "$upart was part of the approved '$stage' basis and is now missing. Re-approve $stage after restoring it."
  [ "$(sdlc_sha256_file "$upart")" = "$want" ] || closed "$upart changed after '$stage' was approved — the downstream gate no longer covers what the human approved. $(sdlc_regate_hint "$up" "$stage")."
done

# The ship approval binds the reviewed SOURCE as well as evidence.md, and
# close.sh refuses a 'shipped' close on anything but a clean binding. Report the
# same verdict here (_common.sh sdlc_source_state) so the gate, status.sh and
# close.sh never disagree about what the approval is worth.
if [ "$stage" = ship ]; then
  read -r src_state src_want src_now <<EOF
$(sdlc_source_state "$rec")
EOF
  case "$src_state" in
    (drift)  closed "the source changed after the ship review (reviewed ${src_want%"${src_want#????????}"}…, now ${src_now%"${src_now#????????}"}…). Staging or committing the reviewed bytes does not trip this; an edit, a new file, a deletion, a chmod or a symlink swap does. Re-run the ship review, then: gates/approve.sh ship $canon";;
    (legacy) closed "the '$slug' ship approval was written by an older kit: it bound only the files that were uncommitted at review time — nothing at all if the work was already committed. Re-run the ship review, then: gates/approve.sh ship $canon";;
    (nosnapshot) closed "the source snapshot recorded with this ship approval is missing (${rec%.approval}.source), so the binding cannot be checked. Re-approve: gates/approve.sh ship $canon";;
    (invalid) closed "the source has a path name this kit cannot bind (git quotes it: a tab, newline, double quote, or backslash in the name), so the ship binding cannot be checked. Rename or ignore that file, re-run the ship review, then: gates/approve.sh ship $canon";;
    (error)   closed "the current source snapshot could not be taken (a file or symlink could not be read or hashed), so the ship binding cannot be checked. Fix that, then re-check.";;
    (ok) ;;
    (unbound) echo "note: no git repository here — this ship approval binds no source identity";;
    (*) closed "the ship source binding is in an unknown state ('${src_state:-empty}') — closed by default.";;
  esac
fi

# An upstream artifact that exists but is bound by nothing (an older kit's record,
# or an artifact written after the approval) would let this gate outlive a rewrite
# nobody re-approved. Compact features have no spec.md/plan.md and are untouched.
unbound_up=$(sdlc_upstream_unbound "$rec" "$slug")
if [ -n "$unbound_up" ]; then
  closed "the '$stage' approval of '$slug' binds no digest for $(for u in $unbound_up; do printf '%s ' "$(sdlc_artifact_of "$u")"; done)— those artifacts exist but were never part of the approved basis (an older kit's record, or written after the approval). Re-approve: gates/approve.sh $stage $canon"
fi

echo "GATE OPEN: $stage (approved @ $(sdlc_field "$rec" approved_at))"
