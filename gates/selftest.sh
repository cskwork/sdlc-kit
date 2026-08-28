#!/usr/bin/env bash
# selftest.sh — proves the gate mechanism works: approve→open, tamper→closed.
set -euo pipefail
kit="$(cd "$(dirname "$0")/.." && pwd)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cd "$tmp"; mkdir -p .sdlc

echo "goal: test" > intent.md

# 1. gate closed before approval
if "$kit/gates/check-gate.sh" intent intent.md >/dev/null 2>&1; then
  echo "FAIL: gate open without approval"; exit 1; fi
echo "ok: gate closed before approval"

# 2. approve → gate open
"$kit/gates/approve.sh" intent intent.md >/dev/null
"$kit/gates/check-gate.sh" intent intent.md >/dev/null
echo "ok: gate open after approval"

# 3. tamper → gate closed
echo "sneaky edit" >> intent.md
if "$kit/gates/check-gate.sh" intent intent.md >/dev/null 2>&1; then
  echo "FAIL: gate open after tamper"; exit 1; fi
echo "ok: tamper invalidates approval"

echo "SELFTEST PASS"
