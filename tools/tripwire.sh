#!/usr/bin/env bash
# tripwire.sh <artifact> — heuristic scan for trip-wires (AGENTS.md rule 3).
# Input to the adversary's tier re-check, and the pre-scan for lazymode-waived
# intent/spec gates (plan and ship always get the adversary). It does not
# replace judgment: a hit is a question, not a conviction.
set -euo pipefail
{ [ $# -eq 1 ] && [ -f "$1" ]; } || { echo "usage: tripwire.sh <plan.md>"; exit 1; }
plan="$1"
hits=0
scan() { # <label> <extended-regex>
  local m
  m=$(grep -inE "$2" "$plan" | head -3 || true)
  if [ -n "$m" ]; then
    hits=1
    echo "TRIP-WIRE? $1"
    echo "$m" | sed 's/^/    /'
  fi
}
scan "migration/schema"   'migrat|schema change|ALTER TABLE|CREATE TABLE|DROP TABLE|[.]sql'
scan "data deletion"      'DELETE FROM|DROP |TRUNCATE|destructive|backfill|rm -rf'
scan "public API"         'public API|breaking change|API contract|openapi|swagger|/api/v[0-9]'
scan "security paths"     'auth|secret|credential|password|token|permission|session'
scan "infra/config"       'Dockerfile|docker-compose|[.]github/workflows|terraform|helm|kubernetes|k8s|nginx|systemd|deploy'
if [ "$hits" -eq 0 ]; then
  echo "no trip-wire candidates found (heuristic only; the adversary must still judge)"
fi
