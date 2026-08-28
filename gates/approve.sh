#!/usr/bin/env bash
# approve.sh <stage> <artifact-path> — HUMAN ONLY. Agents must never run this.
# Records a tamper-evident approval: sha256 of the artifact + who + when.
set -euo pipefail

usage() { echo "usage: approve.sh <stage> <artifact-path>   (run from the project root)"; exit 1; }
[ $# -eq 2 ] || usage
stage="$1"; artifact="$2"
[ -f "$artifact" ] || { echo "FAIL: artifact not found: $artifact"; exit 1; }
[ -d .sdlc ] || { echo "FAIL: no .sdlc/ here. Run init.sh first, from the project root."; exit 1; }

mkdir -p .sdlc/approvals
# ponytail: slug = artifact's parent dir name; keys approvals per feature so parallel features don't clobber
slug=$(basename "$(dirname "$artifact")")
hash=$(shasum -a 256 "$artifact" | awk '{print $1}')
{
  echo "stage: $stage"
  echo "artifact: $artifact"
  echo "sha256: $hash"
  echo "approved_by: $(whoami)"
  echo "approved_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > ".sdlc/approvals/${slug}.${stage}.approval"
echo "APPROVED: $stage of $slug ($artifact @ ${hash:0:12}…)"
echo "Commit .sdlc/approvals/${slug}.${stage}.approval with the artifact for the audit trail."
