#!/usr/bin/env bash
# approve.sh <stage> <artifact-path> — records a gate approval.
# Intent, spec, and ship approvals are HUMAN decisions: run directly, or
# --delegated after the human's explicit approval in chat. For the plan stage
# ONLY, --agent-adversary records the tiered auto-approval: adversary review
# passed and no trip-wires (policy: AGENTS.md hard rule 3).
# Records a tamper-evident approval: sha256 of the artifact + who + when.
# Threat model: catches post-approval edits and mistakes, NOT a malicious agent
# forging records — that line is held by rule 3 plus
# git history of .sdlc/approvals/, which is the real audit trail.
set -euo pipefail

usage() { echo "usage: approve.sh <stage> <artifact-path> [--delegated | --agent-adversary]   (run from the project root)"; exit 1; }
mode=""
if [ $# -eq 3 ]; then
  case "$3" in
    --delegated) mode="delegated-chat (agent-run on explicit human instruction)";;
    --agent-adversary) mode="agent-adversary (auto-approved: adversary review passed, no trip-wires)";;
    *) usage;;
  esac
  set -- "$1" "$2"
fi
[ $# -eq 2 ] || usage
stage="$1"; artifact="$2"
# mode policy lives in AGENTS.md hard rule 3 (single source of truth).
case "$mode" in (agent-adversary*)
  [ "$stage" = "plan" ] || { echo "FAIL: --agent-adversary is valid for the plan stage only (AGENTS.md rule 3)"; exit 1; };;
esac
case "$stage" in (*[!a-zA-Z0-9_-]*|"") echo "FAIL: stage must be [a-zA-Z0-9_-]+: '$stage'"; exit 1;; esac
[ -f "$artifact" ] || { echo "FAIL: artifact not found: $artifact"; exit 1; }
[ -d .sdlc ] || { echo "FAIL: no .sdlc/ here. Run init.sh first, from the project root."; exit 1; }

# slug = artifact's parent dir name; keys approvals per feature
slug=$(basename "$(dirname "$artifact")")
case "$slug" in (.|/|"") echo "FAIL: artifact must live in a feature dir (.sdlc/work/<slug>/)"; exit 1;; esac

mkdir -p .sdlc/approvals
sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | awk '{print $1}'; }
hash=$(sha "$artifact")
{
  echo "stage: $stage"
  echo "artifact: $artifact"
  echo "sha256: $hash"
  echo "approved_by: $(whoami)"
  echo "approved_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [ -n "$mode" ] && echo "mode: $mode" || true
} > ".sdlc/approvals/${slug}.${stage}.approval"
echo "APPROVED: $stage of $slug ($artifact @ ${hash:0:12}…)"
echo "Commit .sdlc/approvals/${slug}.${stage}.approval with the artifact for the audit trail."
