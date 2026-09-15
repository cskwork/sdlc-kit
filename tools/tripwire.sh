#!/usr/bin/env bash
# tripwire.sh <artifact> — SUPPLEMENTAL keyword scan for trip-wires
# (AGENTS.md rule 3). It reads English keywords in one Markdown file, so it
# misses risky work described in any other language, in a paraphrase, or only
# in the code the artifact points at.
# One-directional by design: a hit ADDS a requirement (risk authorization,
# adversary review); a clean scan REMOVES nothing and authorizes nothing. The
# risk review is a read of the affected code and behavior, never this output.
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
  echo "no trip-wire candidates found"
  echo "  This is an English keyword scan of one file, not a risk verdict: it cannot"
  echo "  clear a change. Judge the risk by reading the affected code and behavior."
fi
