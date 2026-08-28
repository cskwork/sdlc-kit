#!/usr/bin/env bash
# selftest.sh — proves the gate mechanism works: approve→open, tamper→closed.
set -euo pipefail
kit="$(cd "$(dirname "$0")/.." && pwd)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cd "$tmp"; mkdir -p .sdlc/work/feat-a

a=.sdlc/work/feat-a/intent.md
echo "goal: test" > "$a"

# 1. gate closed before approval
if "$kit/gates/check-gate.sh" intent "$a" >/dev/null 2>&1; then
  echo "FAIL: gate open without approval"; exit 1; fi
echo "ok: gate closed before approval"

# 2. approve → gate open
"$kit/gates/approve.sh" intent "$a" >/dev/null
"$kit/gates/check-gate.sh" intent "$a" >/dev/null
echo "ok: gate open after approval"

# 3. tamper → gate closed
echo "sneaky edit" >> "$a"
if "$kit/gates/check-gate.sh" intent "$a" >/dev/null 2>&1; then
  echo "FAIL: gate open after tamper"; exit 1; fi
echo "ok: tamper invalidates approval"

# 4. stage name injection rejected
if "$kit/gates/approve.sh" "../../etc/pwn" "$a" >/dev/null 2>&1; then
  echo "FAIL: path-traversal stage name accepted"; exit 1; fi
echo "ok: invalid stage name rejected"

# 5. artifact outside a feature dir rejected
echo x > bare.md
if "$kit/gates/approve.sh" intent bare.md >/dev/null 2>&1; then
  echo "FAIL: bare-path artifact accepted (slug '.')"; exit 1; fi
echo "ok: bare-path artifact rejected"

# 6. corrupt approval record → closed WITH a message (never silent)
"$kit/gates/approve.sh" intent "$a" >/dev/null   # re-approve tampered file
grep -v '^sha256: ' .sdlc/approvals/feat-a.intent.approval > t && mv t .sdlc/approvals/feat-a.intent.approval
out=$("$kit/gates/check-gate.sh" intent "$a" 2>&1) && { echo "FAIL: gate open on corrupt record"; exit 1; }
case "$out" in (*"GATE CLOSED"*) echo "ok: corrupt record closed with message";;
  (*) echo "FAIL: corrupt record closed SILENTLY"; exit 1;; esac

echo "SELFTEST PASS"
