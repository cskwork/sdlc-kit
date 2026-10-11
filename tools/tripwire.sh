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
# Two exact neutral phrases caused confirmed false positives. Mask the bounded
# word and standalone prohibition clause only, never a negated line or a quoted
# policy being changed: other risky words still count. Clean clears nothing.
scanfile=$(mktemp); trap 'rm -f "$scanfile"' EXIT
awk '
  BEGIN {
    prohibition = "(^[[:space:]]*([-*+][[:space:]]+)?|[.;][[:space:]]+)do not access credentials([[:space:]]*[.;]|[[:space:]]*$)"
  }
  function mask(pattern) {
    while (match(tolower($0), pattern))
      $0 = substr($0, 1, RSTART-1) sprintf("%*s", RLENGTH, "") substr($0, RSTART+RLENGTH)
  }
  # A later or earlier clause may remove the boundary without repeating its
  # security noun. Keep the noun when an override/access verb occurs anywhere
  # outside the exact exclusion, including another line. Conservative lexical
  # evidence only: an unrelated override may still require a real risk review.
  NR==FNR {
    mask(prohibition)
    if (tolower($0) ~ /(^|[^[:alnum:]_])(remov|delet|discard|revok|waiv|undo|disregard|drop|ignor|overrid|replac|lift|allow|enabl|access|disabl|bypass|permit|grant|relax|unrestrict)[[:alpha:]]*([^[:alnum:]_]|$)/)
      overriding = 1
    next
  }
  {
    mask("^- *scope authorization:")
    mask("(^|[^[:alnum:]_])authorized([^[:alnum:]_]|$)")
    if (!overriding) mask(prohibition)
    print
  }
' "$plan" "$plan" > "$scanfile"
hits=0
scan() { # <label> <extended-regex>
  local m
  # Report the original words and line numbers, not the masked scan copy.
  m=$(grep -inE "$2" "$scanfile" | head -3 |
    awk -F: 'NR==FNR { lines[NR]=$0; next } { print $1 ":" lines[$1] }' "$plan" - || true)
  if [ -n "$m" ]; then
    hits=1
    echo "TRIP-WIRE? $1"
    echo "$m" | sed 's/^/    /'
  fi
}
scan "migration/schema"   'migrat|schema change|ALTER TABLE|CREATE TABLE|DROP TABLE|[.]sql'
scan "data deletion"      'DELETE FROM|DROP |TRUNCATE|destructive|backfill|rm -rf'
scan "public API"         'public API|breaking change|API contract|openapi|swagger|/api/v[0-9]'
scan "public API/contract: refuses what callers send today" 'newly required|now required|no longer accept|now (rejects?|refuses?)|(rejects?|refuses?) (the )?(request|input)|new validation|tighten'
scan "security paths"     'auth|secret|credential|password|token|permission|session'
scan "infra/config"       'Dockerfile|docker-compose|[.]github/workflows|terraform|helm|kubernetes|k8s|nginx|systemd|deploy'
if [ "$hits" -eq 0 ]; then
  echo "no trip-wire candidates found"
  echo "  This is an English keyword scan of one file, not a risk verdict: it cannot"
  echo "  clear a change. Judge the risk by reading the affected code and behavior."
fi
