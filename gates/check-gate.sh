#!/usr/bin/env bash
# check-gate.sh <stage> <artifact-path> — run by the AGENT before starting the next stage.
# Passes if the approval record and the artifact both exist.
set -euo pipefail

usage() { echo "usage: check-gate.sh <stage> <artifact-path>"; exit 1; }
[ $# -eq 2 ] || usage
stage="$1"; artifact="$2"
case "$stage" in (*[!a-zA-Z0-9_-]*|"") echo "GATE CLOSED: invalid stage name '$stage'"; exit 1;; esac
slug=$(basename "$(dirname "$artifact")")
rec=".sdlc/approvals/${slug}.${stage}.approval"

[ -f "$rec" ] || { echo "GATE CLOSED: no approval for '$stage' of '$slug'. Needed: gates/approve.sh $stage $artifact (human decision, or --lazy when lazymode waives this gate — AGENTS.md rule 3)"; exit 1; }
[ -f "$artifact" ] || { echo "GATE CLOSED: approved artifact missing: $artifact"; exit 1; }

echo "GATE OPEN: $stage (approved @ $(grep '^approved_at: ' "$rec" | awk '{print $2}'))"
