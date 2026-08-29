#!/usr/bin/env bash
# check-gate.sh <stage> <artifact-path> — run by the AGENT before starting the next stage.
# Passes only if the approval record exists AND the artifact hash still matches
# (an edit after approval invalidates the gate).
set -euo pipefail

usage() { echo "usage: check-gate.sh <stage> <artifact-path>"; exit 1; }
[ $# -eq 2 ] || usage
stage="$1"; artifact="$2"
case "$stage" in (*[!a-zA-Z0-9_-]*|"") echo "GATE CLOSED: invalid stage name '$stage'"; exit 1;; esac
slug=$(basename "$(dirname "$artifact")")
rec=".sdlc/approvals/${slug}.${stage}.approval"

[ -f "$rec" ] || { echo "GATE CLOSED: no approval for '$stage' of '$slug'. Needed: gates/approve.sh $stage $artifact (human decision, or --lazy when lazymode waives this gate — AGENTS.md rule 3)"; exit 1; }
[ -f "$artifact" ] || { echo "GATE CLOSED: approved artifact missing: $artifact"; exit 1; }

want=$(grep '^sha256: ' "$rec" | awk '{print $2}' || true)
[ -n "$want" ] || { echo "GATE CLOSED: corrupt approval record (no sha256 line): $rec. A human must re-approve."; exit 1; }

sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | awk '{print $1}'; }
have=$(sha "$artifact")
if [ "$want" != "$have" ]; then
  echo "GATE CLOSED: $artifact was EDITED AFTER approval."
  echo "  approved: $want"
  echo "  current:  $have"
  echo "A human must re-review and re-run: gates/approve.sh $stage $artifact"
  exit 1
fi

# upstream chain: the approval also bound the upstream bytes it was derived from
up_art=$(awk '/^upstream: /{sub(/^upstream: /,""); print; exit}' "$rec")
up_want=$(awk '/^upstream_sha256: /{print $2; exit}' "$rec")
if [ -n "$up_want" ]; then
  [ -f "$up_art" ] || { echo "GATE CLOSED: upstream artifact missing: $up_art"; exit 1; }
  up_have=$(sha "$up_art")
  if [ "$up_want" != "$up_have" ]; then
    echo "GATE CLOSED: upstream $up_art changed AFTER '$stage' was approved."
    echo "  bound:   $up_want"
    echo "  current: $up_have"
    echo "The approved $stage was derived from different upstream bytes."
    echo "A human must re-review and re-run: gates/approve.sh $stage $artifact"
    exit 1
  fi
fi
echo "GATE OPEN: $stage ($(grep '^approved_by: ' "$rec" | awk '{print $2}') @ $(grep '^approved_at: ' "$rec" | awk '{print $2}'))"
