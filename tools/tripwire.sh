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
# The kit's own `- Scope authorization:` line (templates/intent.md) names WHO
# authorized the work; the label itself is not evidence of security-sensitive
# work, and matching "auth" in it would make every intent.md trip the security
# wire. Only the LABEL is neutralized — the human's words after the colon are
# scanned like any other text, and line numbers stay the file's own.
scanfile="$plan"
tmpscan=""
if grep -qiE '^- *scope authorization:' "$plan" 2>/dev/null; then
  tmpscan=$(mktemp) && trap 'rm -f "$tmpscan"' EXIT
  sed 's/^\(- *[Ss]cope \)[Aa]uthorization:/\1mandate:/' "$plan" > "$tmpscan"
  scanfile="$tmpscan"
fi
hits=0
scan() { # <label> <extended-regex>
  local m
  m=$(grep -inE "$2" "$scanfile" | head -3 || true)
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
