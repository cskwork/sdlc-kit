#!/usr/bin/env bash
# check-gate.sh <stage> <artifact-path> — run by the AGENT before starting the next stage.
# Passes only if the approval record exists AND the artifact hash still matches
# (an edit after approval invalidates the gate).
set -euo pipefail

usage() { echo "usage: check-gate.sh <stage> <artifact-path>"; exit 1; }
[ $# -eq 2 ] || usage
stage="$1"; artifact="$2"
rec=".sdlc/approvals/${stage}.approval"

[ -f "$rec" ] || { echo "GATE CLOSED: no approval for '$stage'. A human must run: gates/approve.sh $stage $artifact"; exit 1; }
[ -f "$artifact" ] || { echo "GATE CLOSED: approved artifact missing: $artifact"; exit 1; }

want=$(grep '^sha256: ' "$rec" | awk '{print $2}')
have=$(shasum -a 256 "$artifact" | awk '{print $1}')
if [ "$want" != "$have" ]; then
  echo "GATE CLOSED: $artifact was EDITED AFTER approval."
  echo "  approved: $want"
  echo "  current:  $have"
  echo "A human must re-review and re-run: gates/approve.sh $stage $artifact"
  exit 1
fi
echo "GATE OPEN: $stage ($(grep '^approved_by: ' "$rec" | awk '{print $2}') @ $(grep '^approved_at: ' "$rec" | awk '{print $2}'))"
