#!/usr/bin/env bash
# approve.sh <stage> <artifact-path> — records a gate approval.
# Intent, spec, and ship approvals are HUMAN decisions: run directly, or
# --delegated after the human's explicit approval in chat. For the plan stage
# ONLY, --agent-adversary records the tiered auto-approval: adversary review
# passed and no trip-wires (policy: AGENTS.md hard rule 3). --lazy records an
# auto-approval for a gate that `lazymode:` in .sdlc/config.md waives (rule 3);
# it is refused for any gate the configured level keeps human.
# Records a tamper-evident approval: sha256 of the artifact + who + when.
# Threat model: catches post-approval edits and mistakes, NOT a malicious agent
# forging records — that line is held by rule 3 plus
# git history of .sdlc/approvals/, which is the real audit trail.
set -euo pipefail

usage() { echo "usage: approve.sh <stage> <artifact-path> [--delegated | --agent-adversary | --lazy]   (run from the project root)"; exit 1; }
mode=""
if [ $# -eq 3 ]; then
  case "$3" in
    --delegated) mode="delegated-chat (agent-run on explicit human instruction)";;
    --agent-adversary) mode="agent-adversary (auto-approved: adversary review passed, no trip-wires)";;
    --lazy) mode="lazy";;
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

# lazymode policy (AGENTS.md rule 3): the level in .sdlc/config.md decides which
# human gates are waived — plan at >=1, spec at >=2, ship at >=3, intent at >=4.
if [ "$mode" = "lazy" ]; then
  lm=$(awk '/^lazymode: /{print $2; exit}' .sdlc/config.md 2>/dev/null || true)
  case "$lm" in (''|*[!0-9]*) lm=0;; esac
  case "$stage" in plan) need=1;; spec) need=2;; ship) need=3;; intent) need=4;;
    *) echo "FAIL: --lazy applies only to intent, spec, plan, or ship"; exit 1;; esac
  if [ "$lm" -lt "$need" ]; then
    echo "FAIL: lazymode $lm keeps the '$stage' gate HUMAN (--lazy needs lazymode >= $need in .sdlc/config.md). A human must approve."
    exit 1
  fi
  mode="lazy (auto-approved: lazymode $lm waives the $stage human gate; adversary review passed)"
fi

# slug = artifact's parent dir name; keys approvals per feature
slug=$(basename "$(dirname "$artifact")")
case "$slug" in (.|/|"") echo "FAIL: artifact must live in a feature dir (.sdlc/work/<slug>/)"; exit 1;; esac

mkdir -p .sdlc/approvals
sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | awk '{print $1}'; }
hash=$(sha "$artifact")

# upstream chaining: bind this approval to the artifact it was derived from,
# so an edit to an approved upstream closes every downstream gate (check-gate.sh).
upstream_for() { case "$1" in spec) echo "intent.md";; plan) echo "spec.md";; ship) echo "plan.md";; *) echo "";; esac; }
up_art=""; up_hash=""
up_name=$(upstream_for "$stage")
if [ -n "$up_name" ] && [ -f "$(dirname "$artifact")/$up_name" ]; then
  up_art="$(dirname "$artifact")/$up_name"
  up_hash=$(sha "$up_art")
fi

{
  echo "stage: $stage"
  echo "artifact: $artifact"
  echo "sha256: $hash"
  echo "approved_by: $(whoami)"
  echo "approved_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [ -n "$up_hash" ] && { echo "upstream: $up_art"; echo "upstream_sha256: $up_hash"; } || true
  [ -n "$mode" ] && echo "mode: $mode" || true
  [ -n "$mode" ] && echo "runner: agent" || true
} > ".sdlc/approvals/${slug}.${stage}.approval"
echo "APPROVED: $stage of $slug ($artifact @ ${hash:0:12}…)"
echo "Commit .sdlc/approvals/${slug}.${stage}.approval with the artifact for the audit trail."
