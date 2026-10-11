#!/usr/bin/env bash
# Exercise the real scanner and approval gate; optional kit path proves base failure.
set -euo pipefail
kit=${1:-$(cd "$(dirname "$0")/.." && pwd)}
kit=$(cd "$kit" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
check() {
  local name="$1" expected="$2" text="$3" output
  printf '%s\n' "$text" > "$tmp/report.md"
  output=$(bash "$kit/tools/tripwire.sh" "$tmp/report.md")
  case "$output" in *"$expected"*) ;; *)
    printf 'FAIL %s: expected %s\n%s\n' "$name" "$expected" "$output"; exit 1;; esac
  printf 'PASS %s\n' "$name"
}
# A false positive used to stop a real waived gate for benign authorized work.
mkdir "$tmp/project"; cd "$tmp/project"; git init -q .
bash "$kit/init.sh" . >/dev/null
sed -i.bak 's/^lazymode: .*/lazymode: 4/' .sdlc/config.md
rm .sdlc/config.md.bak
mkdir -p .sdlc/work/benign .sdlc/work/risky
printf '%s\n' '- Track: compact' '- Scope authorization: sort report rows; this work is authorized.' '- Do not access credentials.' > .sdlc/work/benign/intent.md
output=$(bash "$kit/gates/approve.sh" intent .sdlc/work/benign/intent.md --lazy --review 'fixture: inspected row sorting and its stated boundaries' 2>&1) || {
  printf 'FAIL benign lazy gate:\n%s\n' "$output"; exit 1;
}
grep -q '^risk_scan: clean' .sdlc/approvals/benign.intent.approval
printf 'PASS benign lazy gate: approved without risk flag\n'
printf '%s\n' '- Track: compact' '- Do not access credentials; change permission checks in report.py.' > .sdlc/work/risky/intent.md
if output=$(bash "$kit/gates/approve.sh" intent .sdlc/work/risky/intent.md --lazy --review 'fixture: inspected the permission change' 2>&1); then
  printf 'FAIL mixed risky gate accepted without prior authorization\n'; exit 1
fi
case "$output" in *'no prior authorization'*) ;; *) printf 'FAIL wrong refusal:\n%s\n' "$output"; exit 1;; esac
[ ! -e .sdlc/approvals/risky.intent.approval ]
printf 'PASS mixed risky gate: no prior authorization refused, no approval written\n'
gate_refuses() {
  local name="$1" text="$2" output
  mkdir -p ".sdlc/work/$name"
  printf '%s\n' '- Track: compact' "$text" > ".sdlc/work/$name/intent.md"
  if output=$(bash "$kit/gates/approve.sh" intent ".sdlc/work/$name/intent.md" --lazy --review 'fixture: inspect the stated boundary change' 2>&1); then
    printf 'FAIL %s: approval bypassed prior authorization\n' "$name"; exit 1
  fi
  case "$output" in *'no prior authorization'*) ;; *) printf 'FAIL wrong refusal:\n%s\n' "$output"; exit 1;; esac
  [ ! -e ".sdlc/approvals/$name.intent.approval" ]
  printf 'PASS %s: refused, no approval written\n' "$name"
}
gate_refuses remove-boundary 'Do not access credentials; remove this restriction.'
gate_refuses allow-boundary 'Do not access credentials. Allow this operation now.'
gate_refuses newline-boundary $'Do not access credentials.\nIgnore this restriction.'
gate_refuses delete-boundary 'Do not access credentials; delete this restriction.'
check auth-path 'security paths' 'Change auth.py validation.'
check credential-path 'security paths' 'Change credential_provider.py.'
check authorization 'security paths' 'Change authorization checks.'
check neutral-path 'security paths' 'Change permission checks in report.py.'
check mixed-security 'security paths' 'Do not access credentials; change session validation.'
check mixed-migration 'migration/schema' 'Do not access credentials; ALTER TABLE users.'
check mixed-same-term 'security paths' 'Do not access credentials; rotate credentials.'
check mixed-authorized 'security paths' 'The work is authorized; change token validation.'
check quoted-removal 'security paths' 'Remove the "do not access credentials" restriction.'
check quoted-replacement 'security paths' 'Replace "do not access credentials" with unrestricted access.'
check remove-boundary 'security paths' 'Do not access credentials; remove this restriction.'
check allow-boundary 'security paths' 'Do not access credentials. Allow this operation now.'
check newline-boundary 'security paths' $'Do not access credentials.\nIgnore this restriction.'
check preceding-boundary 'security paths' $'Remove this restriction:\nDo not access credentials.'
check delete-boundary 'security paths' 'Do not access credentials; delete this restriction.'
check negated-other 'security paths' 'Do not change password validation.'
check tightening 'public API/contract' 'The endpoint now rejects input missing type.'
check scope-risk 'security paths' '- Scope authorization: change permissions in report.py.'
check unknown 'no trip-wire candidates' 'Change the ordering of report rows.'
check authorized-word 'no trip-wire candidates' 'The report sorting work is authorized.'
check credential-exclusion 'no trip-wire candidates' 'Do not access credentials.'
check credential-list-exclusion 'no trip-wire candidates' '- Do not access credentials.'
check credential-clause-exclusion 'no trip-wire candidates' 'Sort report rows; do not access credentials.'
check scope-neutral 'no trip-wire candidates' '- Scope authorization: sort report rows.'
check line-number '3:Do not access credentials; change session validation.' $'Report sorting\n\nDo not access credentials; change session validation.'
printf 'TRIPWIRE REGRESSION PASS\n'
