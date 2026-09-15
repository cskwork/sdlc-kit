#!/usr/bin/env bash
# e2e.sh [kit-path] — end-to-end integration suite for sdlc-kit.
#
# Builds throwaway git projects in its OWN mktemp fixture, drives the loop with
# the kit's real scripts (init/approve/check-gate/status/close/refcheck), and
# asserts on observable results — the loop as a user meets it, not the internals
# (gates/selftest.sh covers those unit-level; this suite never runs it — CI and
# the release check run both, and one suite hiding inside the other only makes a
# failure report twice). Nothing outside the fixture is
# written and no network, remote, or `gh` call is ever made: `pr` and `deploy`
# deliveries are exercised through the local fixture, which is all close.sh
# inspects. Bash 3.2 compatible (no associative arrays, no mapfile, no [[ =~ ]]).
#
# The kit path defaults to this script's own kit, so the suite is relocatable.
# E2E_BASE=<dir> puts the fixture somewhere else; E2E_KEEP=1 keeps it.
#
# Exit 0 = every assertion held. Exit 1 = at least one FAIL (listed at the end).
set -u

KIT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
KIT=$(cd "$KIT" 2>/dev/null && pwd) || { echo "no such kit path: ${1:-}" >&2; exit 2; }
[ -f "$KIT/init.sh" ] || { echo "not a kit: $KIT" >&2; exit 2; }

BASE="${E2E_BASE:-${TMPDIR:-/tmp}}"
mkdir -p "$BASE" || exit 2
FIX=$(mktemp -d "${BASE%/}/sdlc-e2e.XXXXXX") || exit 2
case "$FIX" in */sdlc-e2e.*) ;; *) echo "refusing to use fixture $FIX" >&2; exit 2;; esac
cleanup() { case "$FIX" in */sdlc-e2e.*) rm -rf "$FIX";; esac; }
[ -n "${E2E_KEEP:-}" ] || trap cleanup EXIT
echo "fixture: $FIX"
echo "kit:     $KIT"
echo

PASSED=0; FAILED=0; FAILLIST=""
pass() { PASSED=$((PASSED + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); FAILLIST="$FAILLIST
  - $1"; printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '      output: %s\n' "$(printf '%s' "$2" | tr '\n' '|' | cut -c1-300)"; return 0; }

# assert_ok <desc> <cmd...>            — command must succeed
assert_ok() { local d="$1"; shift; local o rc; o=$("$@" 2>&1); rc=$?
  [ $rc -eq 0 ] && pass "$d" || fail "$d (exit $rc)" "$o"; }
# assert_ok_msg <desc> <needle> <cmd...> — must succeed AND print needle
assert_ok_msg() { local d="$1" n="$2"; shift 2; local o rc; o=$("$@" 2>&1); rc=$?
  if [ $rc -ne 0 ]; then fail "$d (exit $rc, expected 0)" "$o"
  else case "$o" in *"$n"*) pass "$d";; *) fail "$d (missing '$n')" "$o";; esac; fi; }
# assert_fail_msg <desc> <needle> <cmd...> — must fail AND explain with needle
assert_fail_msg() { local d="$1" n="$2"; shift 2; local o rc; o=$("$@" 2>&1); rc=$?
  if [ $rc -eq 0 ]; then fail "$d (succeeded, expected refusal)" "$o"
  else case "$o" in *"$n"*) pass "$d";; *) fail "$d (refused, but message lacks '$n')" "$o";; esac; fi; }
# assert_exit <desc> <expected-code> <cmd...>
assert_exit() { local d="$1" e="$2"; shift 2; local o rc; o=$("$@" 2>&1); rc=$?
  [ "$rc" = "$e" ] && pass "$d" || fail "$d (exit $rc, expected $e)" "$o"; }
assert_file()   { [ -f "$1" ] && pass "$2" || fail "$2 (missing file $1)"; }
assert_nofile() { [ -e "$1" ] && fail "$2 (unexpected $1)" || pass "$2"; }
assert_grep()   { grep -q "$2" "$1" 2>/dev/null && pass "$3" || fail "$3 (no /$2/ in $1)"; }
# mklink <target> <link> — a fixture that claims to be a symlink must BE one.
# Git Bash's default MSYS mode makes `ln -s` COPY instead of link, which would
# turn a symlink assertion into a false PASS; CI sets
# MSYS=winsymlinks:nativestrict. A link we cannot create stops the suite: it is
# a setup failure, not a soft assertion.
mklink() { ln -s "$1" "$2" 2>/dev/null
  [ -L "$2" ] || { fail "setup: $2 is not a real symlink (Windows: MSYS=winsymlinks:nativestrict)"; exit 1; }; }

# Every fixture repo is local, disposable, and deterministic: a fixed identity, a
# fixed initial branch name (older git defaults to master), no signing hook.
gitinit() {
  git init -q .
  git symbolic-ref HEAD refs/heads/main
  git config user.email e2e@fixture.local
  git config user.name "E2E Fixture"
  git config commit.gpgsign false
}
sdlc() { "$KIT/gates/$1" "${@:2}"; }   # bash 3.2 supports ${@:2}
sha256of() { # <file> — same tools the kit itself falls back through
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else openssl dgst -sha256 "$1" | awk '{print $NF}'; fi
}

# ---------------------------------------------------------------- fixture app
# A tiny runnable app + its own test runner, so "before/after" proof is real.
make_app() { # <dir>
  cat > "$1/app.sh" <<'APP'
#!/bin/sh
# search <query> — print matching lines of data.txt
search() {
  q="$1"
  if [ -z "$q" ]; then return 0; fi     # empty query matches nothing
  grep -F -- "$q" data.txt || true
}
case "${1:-}" in
  search) search "${2:-}";;
  *) echo "usage: app.sh search <query>" >&2; exit 2;;
esac
APP
  chmod +x "$1/app.sh"
  printf 'alpha one\nbeta two\nalpha three\n' > "$1/data.txt"
  cat > "$1/test_app.sh" <<'T'
#!/bin/sh
# test runner: every case prints PASS/FAIL; exit 1 on any failure
fails=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "PASS $1"; else
    echo "FAIL $1: expected [$2] got [$3]"; fails=$((fails+1)); fi
}
check search-alpha "alpha one
alpha three" "$(./app.sh search alpha)"
check search-none "" "$(./app.sh search zzz)"
[ "$fails" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILURE(S)"; exit 1; }
T
  chmod +x "$1/test_app.sh"
}

fill_config() { # <project dir> <lazymode>
  awk -v lm="$2" '
    /^lazymode:/ { print "lazymode: " lm; next }
    /^test:/     { print "test: ./test_app.sh"; next }
    /^lint:/     { print "lint: sh -n app.sh"; next }
    /^run:/      { print "run: ./app.sh search alpha"; next }
    { print }' "$1/.sdlc/config.md" > "$1/.sdlc/config.tmp"
  mv "$1/.sdlc/config.tmp" "$1/.sdlc/config.md"
}

echo "=============== A. compact route: a real feature, gates, delivery, close"
A="$FIX/proj-compact"; mkdir -p "$A"; cd "$A"
gitinit; make_app "$A"
git add -A; git commit -qm "init: search app with tests"
assert_ok_msg "A1 init.sh seeds .sdlc/" "Seeded .sdlc/" bash "$KIT/init.sh" .
fill_config "$A" 0
assert_ok "A2 baseline suite green before the feature" ./test_app.sh

mkdir -p .sdlc/work/add-count/scratch
cat > .sdlc/work/add-count/intent.md <<'EOF'
# Intent: add-count
- Goal: someone searching sees how many results came back.
- Date: 2026-09-15
- Type: brownfield
- Track: compact — one file and one existing test file, revert is one commit
- Requested by: QA fixture human

## Success criteria
- [ ] `./test_app.sh` passes with a case asserting the count line

## Compact route
- Files: app.sh (search), test_app.sh (new case)
- Proof: ./test_app.sh — "ALL PASS" means results and count both correct
- Risk: search output only; single revert; nothing else reads app.sh
- Delivery target: local

## Out of scope / must not change
- the matching behavior itself
EOF
assert_fail_msg "A3 build gate is CLOSED before the intent approval" "GATE CLOSED" \
  sdlc check-gate.sh intent .sdlc/work/add-count/intent.md
# fixture human authorization (chat): "approve add-count intent, local only"
assert_ok "A4 intent approved --delegated on the fixture human's explicit word" \
  sdlc approve.sh intent .sdlc/work/add-count/intent.md --delegated
assert_ok_msg "A5 intent gate OPEN after approval" "GATE OPEN" \
  sdlc check-gate.sh intent .sdlc/work/add-count/intent.md
assert_grep .sdlc/approvals/add-count.intent.approval '^track: compact' "A6 approval froze the compact verdict"
assert_grep .sdlc/approvals/add-count.intent.approval '^mode: delegated-chat' "A6b delegated identity recorded"
assert_grep .sdlc/approvals/add-count.intent.approval '^runner: agent' "A6c agent runner recorded"
out=$(sdlc status.sh add-count 2>&1)
case "$out" in *"(compact)"*) pass "A7 status marks the compact route";; *) fail "A7 compact marker" "$out";; esac
case "$out" in *"  spec "*) fail "A7b status still asks for spec on the compact route" "$out";; *) pass "A7b no spec stage demanded";; esac

# --- build: test BEFORE (must fail), then the fix, then test AFTER
cat > test_app.sh <<'T'
#!/bin/sh
fails=0
check() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: expected [$2] got [$3]"; fails=$((fails+1)); fi; }
check search-alpha "alpha one
alpha three
count: 2" "$(./app.sh search alpha)"
check search-none "count: 0" "$(./app.sh search zzz)"
check count-line "count: 2" "$(./app.sh search alpha | tail -n1)"
[ "$fails" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILURE(S)"; exit 1; }
T
chmod +x test_app.sh
./test_app.sh > .sdlc/work/add-count/scratch/before.log 2>&1
rc=$?
[ $rc -ne 0 ] && pass "A8 the new test FAILS against the old code (exit $rc) — real before-proof" \
  || fail "A8 the new test passed before the change; it cannot fail"
assert_grep .sdlc/work/add-count/scratch/before.log 'FAIL count-line' "A8b before.log holds the observed failure"

# implement
cat > app.sh <<'APP'
#!/bin/sh
# search <query> — print matching lines of data.txt, then the result count
search() {
  q="$1"
  if [ -z "$q" ]; then echo "count: 0"; return 0; fi
  out=$(grep -F -- "$q" data.txt || true)
  [ -n "$out" ] && printf '%s\n' "$out"
  if [ -z "$out" ]; then echo "count: 0"; else printf 'count: %s\n' "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"; fi
}
case "${1:-}" in
  search) search "${2:-}";;
  *) echo "usage: app.sh search <query>" >&2; exit 2;;
esac
APP
chmod +x app.sh
assert_ok "A9 full suite green AFTER the change (one full run at the end)" ./test_app.sh
./test_app.sh > .sdlc/work/add-count/scratch/after.log 2>&1
assert_grep .sdlc/work/add-count/scratch/after.log 'ALL PASS' "A9b after.log holds the passing output"

cat > .sdlc/work/add-count/evidence.md <<'EOF'
# Evidence: add-count
## Verification
- Command: ./test_app.sh → `ALL PASS` (full output: scratch/after.log)
- Before the change the new case failed: `FAIL count-line: expected [count: 2] got [alpha three]`
  (full output: scratch/before.log)
## Regression
- Baseline vs after: the two pre-existing cases were updated for the intended
  output change (count line) and pass; matching behavior unchanged.
EOF
assert_ok "A10 ship approved --delegated (fixture human: 'ship it locally')" \
  sdlc approve.sh ship .sdlc/work/add-count/evidence.md --delegated
assert_grep .sdlc/approvals/add-count.ship.source ' app.sh$' "A11 ship binds the reviewed app.sh"
assert_grep .sdlc/approvals/add-count.ship.source ' test_app.sh$' "A11b ship binds the reviewed test file"
assert_grep .sdlc/approvals/add-count.ship.approval '^code_files: [1-9]' "A11d the bound source set is not empty"
assert_grep .sdlc/approvals/add-count.ship.approval '^code_digest: [0-9a-f]' "A11c reviewed code digest recorded"
assert_grep .sdlc/approvals/add-count.ship.approval '^upstream_intent: [0-9a-f]' "A11e ship binds the upstream intent"
if grep -qE '^upstream_(spec|plan):' .sdlc/approvals/add-count.ship.approval; then
  fail "A11f compact ship approval invented a spec/plan binding"
else pass "A11f the compact route binds no spec/plan at ship — none is ever demanded of it"; fi
out=$(sdlc status.sh add-count 2>&1)
case "$out" in *"no delivery.md"*) pass "A12 status asks for the delivery record after the ship gate";;
  *) fail "A12 delivery row missing" "$out";; esac
assert_fail_msg "A13 close shipped BLOCKED with no delivery record" "requires a delivery record" \
  sdlc close.sh add-count shipped "count line delivered"

# staging + committing the reviewed content must NOT invalidate the approval
git add app.sh test_app.sh .sdlc/work/add-count .sdlc/config.md .gitignore
git commit -qm "feat(search): show the result count"
SHA=$(git rev-parse HEAD)
assert_ok_msg "A14 ship gate survives staging+commit of the reviewed content" "GATE OPEN" \
  sdlc check-gate.sh ship .sdlc/work/add-count/evidence.md
cat > .sdlc/work/add-count/delivery.md <<EOF
# Delivery: add-count
- Target: local
- Source: $SHA
- Verified-by: ./test_app.sh
- Evidence: ALL PASS
- Confirmed: yes
- Verified-at: 2026-09-15T00:00:00Z
EOF
assert_ok_msg "A15 close shipped accepted with a confirmed local delivery" "delivery: local" \
  sdlc close.sh add-count shipped "count line delivered locally, suite green"
assert_file .sdlc/archive/add-count/CLOSED "A16 feature archived with a CLOSED record"
assert_nofile .sdlc/work/add-count "A16b feature left work/"
assert_file .sdlc/archive/add-count/approvals/add-count.ship.approval "A16c approvals archived with the feature"
assert_file .sdlc/archive/add-count/scratch/after.log "A17 referenced scratch log NOT deleted at close"
assert_file .sdlc/archive/add-count/scratch/before.log "A17b before-proof log survives close"
assert_fail_msg "A18 double close refused" "already closed" sdlc close.sh add-count shipped "again"
out=$(sdlc status.sh --all 2>&1)
case "$out" in *"add-count"*"[CLOSED: shipped]"*) pass "A19 status --all lists the archived feature";;
  *) fail "A19 archived feature not listed" "$out";; esac

# --- durability in a FRESH CLONE
git add -A .sdlc .gitignore 2>/dev/null
git commit -qm "close(add-count): archive the decision record" >/dev/null
git clone -q "$A" "$FIX/clone-compact"
C="$FIX/clone-compact"
assert_file "$C/.sdlc/archive/add-count/intent.md"   "A20 intent.md survives a fresh clone"
assert_file "$C/.sdlc/archive/add-count/evidence.md" "A21 evidence.md survives a fresh clone"
assert_file "$C/.sdlc/archive/add-count/delivery.md" "A22 delivery.md survives a fresh clone"
assert_file "$C/.sdlc/archive/add-count/CLOSED"      "A23 CLOSED survives a fresh clone"
assert_nofile "$C/.sdlc/archive/add-count/approvals"  "A24 approval records stay local (gitignored)"
if [ -f "$C/.sdlc/archive/add-count/scratch/after.log" ]; then
  pass "A25 referenced scratch log also present in the clone"
else
  echo "NOTE  A25 scratch/ is gitignored by design: evidence.md's 'scratch/after.log' citation does not resolve in a fresh clone"
fi

echo
echo "=============== B. full route: a reproduced bug fix, spec+plan gates"
B="$FIX/proj-full"; mkdir -p "$B"; cd "$B"
gitinit; make_app "$B"
# plant the bug: an empty query returns every line
cat > app.sh <<'APP'
#!/bin/sh
search() { grep -F -- "$1" data.txt || true; }   # BUG: empty query matches all
case "${1:-}" in
  search) search "${2:-}";;
  *) echo "usage: app.sh search <query>" >&2; exit 2;;
esac
APP
chmod +x app.sh
git add -A; git commit -qm "init: search app (with the empty-query bug)"
bash "$KIT/init.sh" . >/dev/null
fill_config "$B" 0
mkdir -p .sdlc/work/fix-empty-query/scratch
# reproduce FIRST, before writing anything else
./app.sh search "" > .sdlc/work/fix-empty-query/scratch/repro-before.log 2>&1
n=$(wc -l < .sdlc/work/fix-empty-query/scratch/repro-before.log | tr -d ' ')
[ "$n" = 3 ] && pass "B1 bug reproduced before any change (empty query returned $n lines)" \
  || fail "B1 bug did not reproduce (got $n lines, expected 3)"
cat > .sdlc/work/fix-empty-query/intent.md <<'EOF'
# Intent: fix-empty-query
- Goal: an empty search box no longer dumps every record.
- Date: 2026-09-15
- Type: brownfield
- Track: full — the blast radius of the matcher is not yet known
- Requested by: QA fixture human
## Success criteria
- [ ] `./app.sh search ""` prints nothing; `./test_app.sh` passes
EOF
assert_ok "B2 intent approved (fixture human)" sdlc approve.sh intent .sdlc/work/fix-empty-query/intent.md --delegated
assert_fail_msg "B3 spec gate closed before its own approval" "GATE CLOSED" \
  sdlc check-gate.sh spec .sdlc/work/fix-empty-query/spec.md
cat > .sdlc/work/fix-empty-query/spec.md <<'EOF'
# Spec: fix-empty-query
- AS-IS: search("") runs `grep -F ""`, which matches every line of data.txt (repro: scratch/repro-before.log).
- TO-BE: search("") returns no lines and exits 0.
- Stays untouched: non-empty queries keep their exact current output.
- Release procedure: local (commit on this branch, suite green).
EOF
assert_ok "B4 spec approved on top of the approved intent" sdlc approve.sh spec .sdlc/work/fix-empty-query/spec.md --delegated
assert_grep .sdlc/approvals/fix-empty-query.spec.approval '^upstream_intent: [0-9a-f]' "B4b spec binds the upstream intent digest"
cat > .sdlc/work/fix-empty-query/plan.md <<'EOF'
# Plan: fix-empty-query
- Gate tier: agent
1. app.sh search(): return early when the query is empty. Proof: ./app.sh search "" prints nothing.
2. test_app.sh: add the empty-query case. Proof: ./test_app.sh → ALL PASS.
EOF
assert_ok "B5 plan approved --agent-adversary (tiered, no trip-wire)" \
  sdlc approve.sh plan .sdlc/work/fix-empty-query/plan.md --agent-adversary
assert_ok_msg "B6 build gate open on the approved plan" "GATE OPEN" \
  sdlc check-gate.sh plan .sdlc/work/fix-empty-query/plan.md
out=$(sdlc status.sh fix-empty-query 2>&1)
case "$out" in *"intent "*"spec "*"plan "*) pass "B7 status resumes the full route with all four stages";;
  *) fail "B7 full-route status rows missing" "$out";; esac

# failing test first (test-before proof), then the fix
cat > test_app.sh <<'T'
#!/bin/sh
fails=0
check() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: expected [$2] got [$3]"; fails=$((fails+1)); fi; }
check search-alpha "alpha one
alpha three" "$(./app.sh search alpha)"
check empty-query "" "$(./app.sh search '')"
[ "$fails" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILURE(S)"; exit 1; }
T
chmod +x test_app.sh
./test_app.sh > .sdlc/work/fix-empty-query/scratch/test-before.log 2>&1
rc=$?; [ $rc -ne 0 ] && pass "B8 regression test fails against the unfixed code" || fail "B8 regression test passed before the fix"
assert_grep .sdlc/work/fix-empty-query/scratch/test-before.log 'FAIL empty-query' "B8b before-log names the failing case"
cat > app.sh <<'APP'
#!/bin/sh
search() {
  [ -z "$1" ] && return 0      # an empty query matches nothing
  grep -F -- "$1" data.txt || true
}
case "${1:-}" in
  search) search "${2:-}";;
  *) echo "usage: app.sh search <query>" >&2; exit 2;;
esac
APP
chmod +x app.sh
assert_ok "B9 same reproduction passes after the fix (full suite)" ./test_app.sh
./test_app.sh > .sdlc/work/fix-empty-query/scratch/test-after.log 2>&1
cat > .sdlc/work/fix-empty-query/evidence.md <<'EOF'
# Evidence: fix-empty-query
## Verification
- Command: ./test_app.sh → ALL PASS (scratch/test-after.log)
## Bug proof
- Before: `./app.sh search ""` → printed all 3 data lines (scratch/repro-before.log);
  `./test_app.sh` → `FAIL empty-query` (scratch/test-before.log)
- Mechanism: `grep -F ""` matches every line, so an empty query fell through to grep.
- After: the SAME commands → empty output, `ALL PASS` (scratch/test-after.log)
- Adjacent flows: non-empty query (search alpha) unchanged; unknown-word query still empty.
- Intermittent? no — deterministic.
## Regression
- Baseline vs after: clean, non-empty query output byte-identical.
EOF
assert_ok "B10 ship approved" sdlc approve.sh ship .sdlc/work/fix-empty-query/evidence.md --delegated
DIG=$(awk '/^code_digest: /{print $2}' .sdlc/approvals/fix-empty-query.ship.approval)

# B10a-B10h the full-route ship approval binds the WHOLE upstream chain. spec.md
# and plan.md live under .sdlc/, which the source snapshot excludes, so nothing
# else in the kit would notice a rewrite of the decision the ship was granted on.
assert_grep .sdlc/approvals/fix-empty-query.ship.approval '^upstream_spec: [0-9a-f]' \
  "B10a the full-route ship approval binds the upstream spec"
assert_grep .sdlc/approvals/fix-empty-query.ship.approval '^upstream_plan: [0-9a-f]' \
  "B10b the full-route ship approval binds the upstream plan"
cp .sdlc/work/fix-empty-query/spec.md "$FIX/spec.keep"
cp .sdlc/work/fix-empty-query/plan.md "$FIX/plan.keep"
cat > .sdlc/work/fix-empty-query/delivery.md <<EOF
# Delivery: fix-empty-query
- Target: local
- Source: worktree:$DIG
- Verified-by: ./test_app.sh
- Evidence: ALL PASS
- Confirmed: yes
- Verified-at: 2026-09-15T00:00:00Z
EOF
echo "- TO-BE: also rewrite every stored query (added after the ship review)" >> .sdlc/work/fix-empty-query/spec.md
assert_fail_msg "B10c a spec.md edited after the ship review blocks 'shipped'" \
  "spec.md changed after the ship review" sdlc close.sh fix-empty-query shipped "delivered"
assert_fail_msg "B10d the ship gate itself closes over the rewritten spec" "GATE CLOSED" \
  sdlc check-gate.sh ship .sdlc/work/fix-empty-query/evidence.md
out=$(sdlc status.sh fix-empty-query 2>&1)
case "$out" in *"spec.md changed since approval"*) pass "B10e status says the same thing on the ship row";;
  *) fail "B10e status hides the upstream spec rewrite" "$out";; esac
cp "$FIX/spec.keep" .sdlc/work/fix-empty-query/spec.md
assert_ok_msg "B10f the restored spec.md reopens the ship gate" "GATE OPEN" \
  sdlc check-gate.sh ship .sdlc/work/fix-empty-query/evidence.md
rm -f .sdlc/work/fix-empty-query/plan.md
assert_fail_msg "B10g a plan.md deleted after the ship review blocks 'shipped'" \
  "part of the approved ship basis and is now missing" sdlc close.sh fix-empty-query shipped "delivered"
cp "$FIX/plan.keep" .sdlc/work/fix-empty-query/plan.md
assert_ok_msg "B10h the restored upstream chain reopens the ship gate" "GATE OPEN" \
  sdlc check-gate.sh ship .sdlc/work/fix-empty-query/evidence.md
cat > .sdlc/work/fix-empty-query/delivery.md <<EOF
# Delivery: fix-empty-query
- Target: local
- Source: worktree:$DIG
- Verified-by: ./test_app.sh
- Evidence: ALL PASS
- Confirmed: yes
- Verified-at: 2026-09-15T00:00:00Z
EOF
assert_ok_msg "B11 close shipped accepts a worktree-identity local delivery" "delivery: local" \
  sdlc close.sh fix-empty-query shipped "empty-query bug fixed; regression test added"
assert_file .sdlc/archive/fix-empty-query/spec.md "B12 spec.md archived (durable)"
git add -A; git commit -qm "fix(search): empty query matches nothing" >/dev/null
git clone -q "$B" "$FIX/clone-full"
assert_file "$FIX/clone-full/.sdlc/archive/fix-empty-query/spec.md" "B13 spec.md survives a fresh clone"
assert_file "$FIX/clone-full/.sdlc/archive/fix-empty-query/evidence.md" "B13b evidence.md survives a fresh clone"

echo
echo "=============== C. negative scenarios: none may pass or ship"
C2="$FIX/proj-neg"; mkdir -p "$C2"; cd "$C2"
gitinit; make_app "$C2"; git add -A; git commit -qm init
bash "$KIT/init.sh" . >/dev/null; fill_config "$C2" 0

# C1 approved artifact edited after approval
mkdir -p .sdlc/work/neg-one
printf -- '- Track: full\ngoal: neg one\n' > .sdlc/work/neg-one/intent.md
sdlc approve.sh intent .sdlc/work/neg-one/intent.md --delegated >/dev/null
echo "scope creep added after the human approved" >> .sdlc/work/neg-one/intent.md
assert_fail_msg "C1 edited-after-approval artifact closes its gate" "changed after it was approved" \
  sdlc check-gate.sh intent .sdlc/work/neg-one/intent.md
out=$(sdlc status.sh neg-one 2>&1)
case "$out" in *STALE*) pass "C1b status reports the stale binding in the same words";; *) fail "C1b status hides the stale binding" "$out";; esac

# C2 upstream edit invalidates a downstream gate
mkdir -p .sdlc/work/neg-two
printf -- '- Track: full\ngoal: neg two\n' > .sdlc/work/neg-two/intent.md
echo "spec" > .sdlc/work/neg-two/spec.md
sdlc approve.sh intent .sdlc/work/neg-two/intent.md --delegated >/dev/null
sdlc approve.sh spec .sdlc/work/neg-two/spec.md --delegated >/dev/null
echo "requirement changed" >> .sdlc/work/neg-two/intent.md
assert_fail_msg "C2 upstream intent edit closes the spec gate" "changed after 'spec' was approved" \
  sdlc check-gate.sh spec .sdlc/work/neg-two/spec.md

# C3 wrong artifact path / stage-artifact mismatch / outside the project / symlink
mkdir -p .sdlc/work/neg-three
echo goal > .sdlc/work/neg-three/intent.md
echo ev > .sdlc/work/neg-three/evidence.md
assert_fail_msg "C3 ship gate refuses intent.md as its artifact" "gate binds evidence.md" \
  sdlc approve.sh ship .sdlc/work/neg-three/intent.md --delegated
mkdir -p "$FIX/outside/neg-three"; cp .sdlc/work/neg-three/intent.md "$FIX/outside/neg-three/intent.md"
assert_fail_msg "C3b artifact outside .sdlc/work refused" "must live in" \
  sdlc approve.sh intent "$FIX/outside/neg-three/intent.md" --delegated
assert_fail_msg "C3c traversal to an existing file outside the project refused" "must live in" \
  sdlc approve.sh intent .sdlc/work/../../../outside/neg-three/intent.md --delegated
mklink "$FIX/outside/neg-three" .sdlc/work/neg-link
assert_fail_msg "C3d symlinked feature dir refused (resolved physically)" "must live in" \
  sdlc approve.sh intent .sdlc/work/neg-link/intent.md --delegated
mklink ../neg-three/intent.md .sdlc/work/neg-three/link.md
assert_fail_msg "C3e symlinked artifact refused" "symlink" \
  sdlc approve.sh intent .sdlc/work/neg-three/link.md --delegated
rm -f .sdlc/work/neg-link .sdlc/work/neg-three/link.md
sdlc approve.sh intent .sdlc/work/neg-three/intent.md --delegated >/dev/null
assert_ok_msg "C3f same file reached through .. still opens the gate" "GATE OPEN" \
  sdlc check-gate.sh intent .sdlc/work/../work/neg-three/intent.md

# C4 post-review source edit blocks the close
mkdir -p .sdlc/work/neg-four
echo goal > .sdlc/work/neg-four/intent.md
printf 'echo one\n' > feature.sh
cat > .sdlc/work/neg-four/evidence.md <<'EOF'
# Evidence: neg-four
- Command: sh feature.sh → one
EOF
sdlc approve.sh ship .sdlc/work/neg-four/evidence.md --delegated >/dev/null
D4=$(awk '/^code_digest: /{print $2}' .sdlc/approvals/neg-four.ship.approval)
printf 'echo one\nrm -rf /tmp/whatever   # sneaked in after the review\n' > feature.sh
cat > .sdlc/work/neg-four/delivery.md <<EOF
# Delivery: neg-four
- Target: local
- Source: worktree:$D4
- Verified-by: sh feature.sh
- Evidence: one
- Confirmed: yes
EOF
assert_fail_msg "C4 code edited after the ship review blocks 'shipped'" "the source changed after the ship review" \
  sdlc close.sh neg-four shipped "done"
out=$(sdlc close.sh neg-four shipped "done" 2>&1)
case "$out" in *"~ feature.sh"*) pass "C4a the block names the file that changed";;
  *) fail "C4a drift report does not name feature.sh" "$out";; esac
# restoring the reviewed bytes and STAGING them keeps the binding valid
printf 'echo one\n' > feature.sh
git add feature.sh
assert_ok_msg "C4b restored + staged (uncommitted) reviewed content closes as shipped" "delivery: local" \
  sdlc close.sh neg-four shipped "local delivery, staged"
# a reviewed file deleted after the review is drift, not a silent match
mkdir -p .sdlc/work/neg-del
echo goal > .sdlc/work/neg-del/intent.md
printf 'echo two\n' > gone.sh
echo ev > .sdlc/work/neg-del/evidence.md
sdlc approve.sh ship .sdlc/work/neg-del/evidence.md --delegated >/dev/null
DD=$(awk '/^code_digest: /{print $2}' .sdlc/approvals/neg-del.ship.approval)
cat > .sdlc/work/neg-del/delivery.md <<EOF
# Delivery: neg-del
- Target: local
- Source: worktree:$DD
- Verified-by: sh gone.sh
- Evidence: two
- Confirmed: yes
EOF
rm -f gone.sh
assert_fail_msg "C4c a reviewed file deleted after the review blocks 'shipped'" "the source changed after the ship review" \
  sdlc close.sh neg-del shipped "done"
printf 'echo two\n' > gone.sh    # restore the reviewed bytes for the cases below

# C4d a file ADDED after the review is drift too — a source change nobody
# reviewed must not ride along with the close
mkdir -p .sdlc/work/neg-add
echo goal > .sdlc/work/neg-add/intent.md
echo ev > .sdlc/work/neg-add/evidence.md
sdlc approve.sh ship .sdlc/work/neg-add/evidence.md --delegated >/dev/null
DA=$(awk '/^code_digest: /{print $2}' .sdlc/approvals/neg-add.ship.approval)
cat > .sdlc/work/neg-add/delivery.md <<EOF
# Delivery: neg-add
- Target: local
- Source: worktree:$DA
- Verified-by: sh gone.sh
- Evidence: two
- Confirmed: yes
EOF
printf 'echo sneaked\n' > extra.sh          # brand new, never reviewed
out=$(sdlc close.sh neg-add shipped "done" 2>&1); rc=$?
if [ $rc -eq 0 ]; then fail "C4d a file added after the review closed as shipped" "$out"
else case "$out" in *"+ extra.sh"*) pass "C4d a file added after the review blocks the close and is named";;
  *) fail "C4d added file not reported" "$out";; esac; fi
rm -f extra.sh
# C4e an executable-bit flip is drift (same bytes, different program)
chmod +x gone.sh
assert_fail_msg "C4e a chmod after the review blocks 'shipped'" "the source changed after the ship review" \
  sdlc close.sh neg-add shipped "done"
chmod -x gone.sh
# C4f replacing a file with a symlink is drift (same content through the link)
mv gone.sh gone.real
mklink gone.real gone.sh
assert_fail_msg "C4f a file replaced by a symlink blocks 'shipped'" "the source changed after the ship review" \
  sdlc close.sh neg-add shipped "done"
rm -f gone.sh gone.real
printf 'echo two\n' > gone.sh
assert_ok_msg "C4g the restored reviewed source closes normally" "delivery: local" \
  sdlc close.sh neg-add shipped "local delivery"

# C5 failed / unconfirmed / mismatched delivery
mkdir -p .sdlc/work/neg-five
echo goal > .sdlc/work/neg-five/intent.md
echo ev > .sdlc/work/neg-five/evidence.md
sdlc approve.sh ship .sdlc/work/neg-five/evidence.md --delegated >/dev/null
D5=$(awk '/^code_digest: /{print $2}' .sdlc/approvals/neg-five.ship.approval)
cat > .sdlc/work/neg-five/delivery.md <<EOF
# Delivery: neg-five
- Target: deploy
- Source: worktree:$D5
- Verified-by: ./deploy.sh
- Evidence: deploy failed: connection refused
- Confirmed: no
EOF
assert_fail_msg "C5 a failed (Confirmed: no) delivery cannot close as shipped" "Confirmed" \
  sdlc close.sh neg-five shipped "deployed"
sed 's/^- Confirmed: no/- Confirmed: yes/' .sdlc/work/neg-five/delivery.md > d.tmp && mv d.tmp .sdlc/work/neg-five/delivery.md
assert_fail_msg "C5b a deploy delivery from an uncommitted worktree is refused" "uncommitted worktree" \
  sdlc close.sh neg-five shipped "deployed"
sed 's|^- Source: .*|- Source: 0123456789012345678901234567890123456789|' .sdlc/work/neg-five/delivery.md > d.tmp && mv d.tmp .sdlc/work/neg-five/delivery.md
assert_fail_msg "C5c a deploy 'delivered sha' that is not a commit here is refused" "not a commit in this repository" \
  sdlc close.sh neg-five shipped "deployed"
sed 's|^- Target: deploy|- Target: local|; s|^- Evidence: .*|- Evidence: <the deciding output line>|' .sdlc/work/neg-five/delivery.md > d.tmp && mv d.tmp .sdlc/work/neg-five/delivery.md
sed "s|^- Source: .*|- Source: worktree:$D5|" .sdlc/work/neg-five/delivery.md > d.tmp && mv d.tmp .sdlc/work/neg-five/delivery.md
assert_fail_msg "C5d template placeholder evidence is refused" "placeholder" \
  sdlc close.sh neg-five shipped "delivered"
# a ship approval with NO delivery record at all
mkdir -p .sdlc/work/neg-six; echo goal > .sdlc/work/neg-six/intent.md; echo ev > .sdlc/work/neg-six/evidence.md
assert_fail_msg "C5e 'shipped' without any ship approval is refused" "requires a ship approval" \
  sdlc close.sh neg-six shipped "done"

# C6 legacy approval record (written by an older kit: no content binding)
mkdir -p .sdlc/work/neg-legacy
echo goal > .sdlc/work/neg-legacy/intent.md
echo ev > .sdlc/work/neg-legacy/evidence.md
printf 'stage: intent\nartifact: .sdlc/work/neg-legacy/intent.md\napproved_at: 2024-01-01T00:00:00Z\n' \
  > .sdlc/approvals/neg-legacy.intent.approval
printf 'stage: ship\nartifact: .sdlc/work/neg-legacy/evidence.md\napproved_at: 2024-01-01T00:00:00Z\n' \
  > .sdlc/approvals/neg-legacy.ship.approval
assert_fail_msg "C6 legacy (digest-less) approval fails CLOSED with the re-approval command" \
  "predates content binding" sdlc check-gate.sh intent .sdlc/work/neg-legacy/intent.md
cat > .sdlc/work/neg-legacy/delivery.md <<'EOF'
# Delivery: neg-legacy
- Target: local
- Source: worktree:deadbeef
- Verified-by: true
- Evidence: ok
- Confirmed: yes
EOF
assert_fail_msg "C6b legacy ship record cannot close a feature as shipped" "predates content binding" \
  sdlc close.sh neg-legacy shipped "old approval"
assert_ok "C6c re-approval repairs the legacy record" sdlc approve.sh intent .sdlc/work/neg-legacy/intent.md --delegated
assert_ok_msg "C6d gate open again after re-approval" "GATE OPEN" sdlc check-gate.sh intent .sdlc/work/neg-legacy/intent.md

# C7 compact slug has no spec/plan gate until the track is upgraded
mkdir -p .sdlc/work/neg-compact
printf -- '- Track: compact — one file\ngoal\n' > .sdlc/work/neg-compact/intent.md
sdlc approve.sh intent .sdlc/work/neg-compact/intent.md --delegated >/dev/null
echo spec > .sdlc/work/neg-compact/spec.md
assert_fail_msg "C7 spec approval refused on a compact-track slug" "upgraded from compact" \
  sdlc approve.sh spec .sdlc/work/neg-compact/spec.md --delegated
printf -- '- Track: full — upgraded from compact (scope grew)\ngoal\n' > .sdlc/work/neg-compact/intent.md
sdlc approve.sh intent .sdlc/work/neg-compact/intent.md --delegated >/dev/null
assert_ok "C7b spec approval available after the intent re-approval" \
  sdlc approve.sh spec .sdlc/work/neg-compact/spec.md --delegated

# C8 lazymode/authority: a clean English keyword scan clears nothing
fill_config "$C2" 4
mkdir -p .sdlc/work/neg-risk
printf 'goal: remove the admin password check for all sessions\n' > .sdlc/work/neg-risk/intent.md
assert_fail_msg "C8 risky work cannot be lazily approved without recorded authorization" \
  "no prior authorization" sdlc approve.sh intent .sdlc/work/neg-risk/intent.md --lazy --review "read session code"
mkdir -p .sdlc/work/neg-ko
printf '목표: 로그인 검증을 제거하고 모든 사용자에게 관리자 권한을 부여한다\n' > .sdlc/work/neg-ko/intent.md
assert_ok_msg "C8b the keyword scan finds nothing in Korean AND says it clears nothing" \
  "not a risk verdict" bash "$KIT/tools/tripwire.sh" .sdlc/work/neg-ko/intent.md
assert_fail_msg "C8c --lazy still refuses without a recorded review" "needs --review" \
  sdlc approve.sh intent .sdlc/work/neg-ko/intent.md --lazy
fill_config "$C2" 0
assert_fail_msg "C8d --lazy refused for a gate this lazymode keeps human" "keeps the 'intent' gate HUMAN" \
  sdlc approve.sh intent .sdlc/work/neg-ko/intent.md --lazy --review "read the auth middleware"

# C9 unknown deployed version / drift
assert_exit "C9 unknown ref is UNKNOWN (exit 2), never a claim" 2 \
  bash "$KIT/tools/refcheck.sh" no-such-ref --no-fetch
assert_exit "C9b an unknown deployed sha is UNKNOWN (exit 2)" 2 \
  bash "$KIT/tools/refcheck.sh" HEAD --no-fetch --deployed-sha 0123456789012345678901234567890123456789
out=$(bash "$KIT/tools/refcheck.sh" HEAD --no-fetch app.sh 2>&1); rc=$?
if [ $rc -eq 0 ]; then
  case "$out" in *"deployed revision: UNKNOWN"*) pass "C9c a clean path match still reports the deployed revision as UNKNOWN";;
    *) fail "C9c refcheck claims a deployed revision it cannot know" "$out";; esac
else fail "C9c clean path reported as drift (exit $rc)" "$out"; fi
echo "local edit" >> app.sh
assert_exit "C9d an uncommitted edit is DRIFT even though HEAD matches" 1 \
  bash "$KIT/tools/refcheck.sh" HEAD --no-fetch
git checkout -- app.sh

# C10 archived slug cannot be reused
mkdir -p .sdlc/memory/lessons; echo lesson > .sdlc/memory/lessons/2026-09-15-neg-two.md
sdlc close.sh neg-two dead-end "spike abandoned" >/dev/null
mkdir -p .sdlc/work/neg-two; echo goal > .sdlc/work/neg-two/intent.md
assert_fail_msg "C10 an archived slug cannot be approved again" "already closed and archived" \
  sdlc approve.sh intent .sdlc/work/neg-two/intent.md --delegated

# C11 REGRESSION (B1): the work is COMMITTED BEFORE the ship review — the case
# where a diff-vs-HEAD binding covered nothing at all. skills/5-ship reviews the
# diff against the base branch, so this is the ordinary team flow, not an edge.
BASE_BRANCH=$(git rev-parse --abbrev-ref HEAD)
git checkout -q -b feature-branch || fail "C11 setup: could not create the feature branch"
mkdir -p .sdlc/work/neg-committed
echo goal > .sdlc/work/neg-committed/intent.md
printf 'echo v1\n' > late.sh
cat > .sdlc/work/neg-committed/evidence.md <<'EOF'
# Evidence: neg-committed
- Command: sh late.sh -> v1
EOF
git add late.sh .sdlc/work/neg-committed
git commit -qm "feat: late.sh (committed before the ship review, as many teams do)"
sdlc approve.sh ship .sdlc/work/neg-committed/evidence.md --delegated >/dev/null
nbound=$(awk '/^code_files: /{print $2}' .sdlc/approvals/neg-committed.ship.approval)
[ "${nbound:-0}" -ge 1 ] && pass "C11a the ship approval binds a non-empty source set ($nbound files) although the work was committed" \
  || fail "C11a ship approval bound an empty source set after a commit"
assert_grep .sdlc/approvals/neg-committed.ship.approval '^code_scope: project' "C11b the bound scope is recorded, not implied"
assert_file .sdlc/approvals/neg-committed.ship.source "C11c the reviewed source snapshot is kept beside the record"
SHA11=$(git rev-parse HEAD)
printf 'echo v2   # edited AFTER the ship review, never reviewed\n' > late.sh
cat > .sdlc/work/neg-committed/delivery.md <<EOF
# Delivery: neg-committed
- Target: local
- Source: $SHA11
- Verified-by: sh late.sh
- Evidence: v1
- Confirmed: yes
EOF
assert_fail_msg "C11 post-review edit is caught even when the work was committed before the review" \
  "the source changed after the ship review" sdlc close.sh neg-committed shipped "delivered"
# N3: status must say the same thing close.sh refuses on — no silent disagreement
out=$(sdlc status.sh neg-committed 2>&1)
case "$out" in *"SOURCE DRIFT"*) pass "C11d status flags the drifted source on the ship row";;
  *) fail "C11d status hides the source drift" "$out";; esac
case "$out" in *"NOT CLOSEABLE"*) pass "C11e status marks the delivery record as not closeable";;
  *) fail "C11e status calls an uncloseable delivery 'recorded'" "$out";; esac
assert_fail_msg "C11f the ship gate itself closes over drifted source" "GATE CLOSED" \
  sdlc check-gate.sh ship .sdlc/work/neg-committed/evidence.md
# restore the reviewed bytes: the binding is content, so the close works again
printf 'echo v1\n' > late.sh
out=$(sdlc status.sh neg-committed 2>&1)
case "$out" in *"SOURCE DRIFT"*) fail "C11g status still reports drift after the source was restored" "$out";;
  *) pass "C11g restoring the reviewed bytes clears the drift in status";; esac

# C12 REGRESSION (N1): a pr/deploy Source commit must CONTAIN the reviewed
# source, not merely exist in this repository.
mkdir -p .sdlc/work/neg-source
echo goal > .sdlc/work/neg-source/intent.md
printf 'echo shipped-thing\n' > shipped.sh
echo "- Command: sh shipped.sh" > .sdlc/work/neg-source/evidence.md
sdlc approve.sh ship .sdlc/work/neg-source/evidence.md --delegated >/dev/null
OLD=$(git rev-parse HEAD)      # predates shipped.sh entirely
cat > .sdlc/work/neg-source/delivery.md <<EOF
# Delivery: neg-source
- Target: pr
- Source: $OLD
- Verified-by: sh shipped.sh
- Evidence: shipped-thing
- Confirmed: yes
EOF
assert_fail_msg "C12 an old unrelated commit cannot be the Source of a pr delivery" \
  "does not CONTAIN the reviewed source" sdlc close.sh neg-source shipped "PR merged"
out=$(sdlc status.sh neg-source 2>&1)
case "$out" in *"NOT CLOSEABLE"*) pass "C12b status reports the unverifiable Source commit too";;
  *) fail "C12b status reports the bad Source as a normal delivery" "$out";; esac
git add -A .; git commit -qm "feat: shipped.sh (the source the review saw)"
NEW=$(git rev-parse HEAD)
sed "s|^- Source: .*|- Source: $NEW|" .sdlc/work/neg-source/delivery.md > d.tmp
mv d.tmp .sdlc/work/neg-source/delivery.md
assert_ok_msg "C12c the commit that contains the reviewed source closes as shipped" "delivery: pr" \
  sdlc close.sh neg-source shipped "PR merged"
# C13 a legacy ship binding (older kit: no code_scope) is diagnosed, not trusted
mkdir -p .sdlc/work/neg-oldbind
echo goal > .sdlc/work/neg-oldbind/intent.md
echo ev > .sdlc/work/neg-oldbind/evidence.md
{ echo "stage: ship"
  echo "artifact: .sdlc/work/neg-oldbind/evidence.md"
  echo "artifact_sha256: $(sha256of .sdlc/work/neg-oldbind/evidence.md)"
  echo "approved_at: 2025-01-01T00:00:00Z"
  echo "code_head: $(git rev-parse HEAD)"
  echo "code_digest: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
} > .sdlc/approvals/neg-oldbind.ship.approval
cat > .sdlc/work/neg-oldbind/delivery.md <<EOF
# Delivery: neg-oldbind
- Target: local
- Source: worktree:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
- Verified-by: true
- Evidence: ok
- Confirmed: yes
EOF
assert_fail_msg "C13 a legacy (diff-only) ship binding cannot close a feature as shipped" \
  "written by an older kit" sdlc close.sh neg-oldbind shipped "done"
out=$(sdlc status.sh neg-oldbind 2>&1)
case "$out" in *"predates source binding"*) pass "C13b status diagnoses the legacy ship binding";;
  *) fail "C13b status does not diagnose the legacy ship binding" "$out";; esac
# C15 a ship record that binds NO upstream digest while spec.md and plan.md exist
# (an older kit's record): the gate would otherwise outlive a rewrite of either
# decision, because .sdlc/ is outside the source snapshot. Fail closed instead.
mkdir -p .sdlc/work/neg-upstream
echo goal > .sdlc/work/neg-upstream/intent.md
echo spec > .sdlc/work/neg-upstream/spec.md
echo plan > .sdlc/work/neg-upstream/plan.md
echo ev > .sdlc/work/neg-upstream/evidence.md
sdlc approve.sh ship .sdlc/work/neg-upstream/evidence.md --delegated >/dev/null
DU=$(awk '/^code_digest: /{print $2}' .sdlc/approvals/neg-upstream.ship.approval)
cat > .sdlc/work/neg-upstream/delivery.md <<EOF
# Delivery: neg-upstream
- Target: local
- Source: worktree:$DU
- Verified-by: true
- Evidence: ok
- Confirmed: yes
EOF
# strip the upstream lines OUTSIDE the project: a temp file in the worktree would
# itself be source drift and mask what this case is about
grep -v '^upstream_' .sdlc/approvals/neg-upstream.ship.approval > "$FIX/rec.tmp"
cp "$FIX/rec.tmp" .sdlc/approvals/neg-upstream.ship.approval
assert_fail_msg "C15 a ship record binding no upstream digest cannot close while spec.md/plan.md exist" \
  "binds no digest for" sdlc close.sh neg-upstream shipped "delivered"
assert_fail_msg "C15b the ship gate refuses the same record" "GATE CLOSED" \
  sdlc check-gate.sh ship .sdlc/work/neg-upstream/evidence.md
out=$(sdlc status.sh neg-upstream 2>&1)
case "$out" in *"not bound by this approval"*) pass "C15c status names the unbound upstream artifact";;
  *) fail "C15c status hides the unbound upstream artifact" "$out";; esac
sdlc approve.sh ship .sdlc/work/neg-upstream/evidence.md --delegated >/dev/null
assert_ok_msg "C15d re-approval binds the upstream chain and the close goes through" "delivery: local" \
  sdlc close.sh neg-upstream shipped "delivered locally"

# C16 REGRESSION (B-QP): a path name git C-quotes (tab, newline, double quote,
# backslash) cannot be hashed or watched. The kit must REFUSE to bind it, never
# record a stable placeholder that lets a later edit pass. Unicode and spaces
# stay ordinary.
QT=$(printf 'tab\tname.txt'); QN=$(printf 'new\nline.txt'); QQ='we"ird.txt'; QB='back\slash.txt'
mkdir -p .sdlc/work/neg-quoted
echo goal > .sdlc/work/neg-quoted/intent.md
echo ev > .sdlc/work/neg-quoted/evidence.md
printf 'v1\n' > "$QT"; printf 'v1\n' > "$QN"; printf 'v1\n' > "$QQ"; printf 'v1\n' > "$QB"
printf 'plain\n' > '한글 and space.txt'
out=$(sdlc approve.sh ship .sdlc/work/neg-quoted/evidence.md --delegated 2>&1); rc=$?
if [ $rc -eq 0 ]; then fail "C16 ship approval bound a snapshot with git-quoted path names" "$out"
else
  case "$out" in *"unsupported path name"*) pass "C16 ship approval refuses git-quoted path names before binding";;
    *) fail "C16 refusal does not say the names are unsupported" "$out";; esac
  n=0; for needle in '"tab\tname.txt"' '"new\nline.txt"' '"we\"ird.txt"' '"back\\slash.txt"'; do
    case "$out" in *"$needle"*) n=$((n + 1));; esac; done
  [ "$n" -eq 4 ] && pass "C16b all four unsupported names are listed (tab, newline, quote, backslash)" \
    || fail "C16b only $n of 4 unsupported names listed" "$out"
fi
assert_nofile .sdlc/approvals/neg-quoted.ship.approval "C16c no ship record is written when the snapshot is refused"
assert_nofile .sdlc/approvals/neg-quoted.ship.source "C16d no partial source snapshot is left behind"
rm -f "$QT" "$QN" "$QQ" "$QB"
assert_ok_msg "C16e with those names gone the same source binds (Unicode + space path kept)" "APPROVED" \
  sdlc approve.sh ship .sdlc/work/neg-quoted/evidence.md --delegated
assert_grep .sdlc/approvals/neg-quoted.ship.source '^f - [0-9a-f]* 한글 and space.txt$' "C16f the Unicode/space path is bound by content, not quoted"
DQ=$(awk '/^code_digest: /{print $2}' .sdlc/approvals/neg-quoted.ship.approval)
cat > .sdlc/work/neg-quoted/delivery.md <<EOF
# Delivery: neg-quoted
- Target: local
- Source: worktree:$DQ
- Verified-by: true
- Evidence: ok
- Confirmed: yes
EOF
printf 'v2 EVIL\n' > "$QQ"     # an unsupported name ADDED after the review
assert_fail_msg "C16g a git-quoted file added after the review closes the ship gate as invalid source" \
  "cannot bind" sdlc check-gate.sh ship .sdlc/work/neg-quoted/evidence.md
out=$(sdlc status.sh neg-quoted 2>&1)
case "$out" in *"INVALID SOURCE"*) pass "C16h status reports the invalid source on the ship row";;
  *) fail "C16h status hides the unsupported path" "$out";; esac
case "$out" in *"NOT CLOSEABLE"*) pass "C16i status marks the delivery as not closeable";;
  *) fail "C16i status calls the delivery closeable over an invalid source" "$out";; esac
out=$(sdlc close.sh neg-quoted shipped "done" 2>&1); rc=$?
if [ $rc -eq 0 ]; then fail "C16j close accepted 'shipped' with an unbindable path on disk" "$out"
else case "$out" in *"cannot bind"*'"we\"ird.txt"'*) pass "C16j close blocks and names the unsupported path";;
  *) fail "C16j close blocked, but did not name the unsupported path" "$out";; esac; fi
rm -f "$QQ"
# C16k a pr Source commit whose TREE has a git-quoted path is refused with its
# own reason (not compared against a shorter list, not called 'does not CONTAIN')
printf 'v1\n' > "$QQ"; git add -A .; git commit -qm "feat: a quoted name lands in a commit"
QCOMMIT=$(git rev-parse HEAD)
git rm -q --cached "$QQ"; rm -f "$QQ"; git commit -qm "chore: and is removed again"
sed "s|^- Target: .*|- Target: pr|; s|^- Source: .*|- Source: $QCOMMIT|" .sdlc/work/neg-quoted/delivery.md > d.tmp
mv d.tmp .sdlc/work/neg-quoted/delivery.md
assert_fail_msg "C16k a delivered commit containing a git-quoted path is refused explicitly" \
  "contains a path name this kit cannot bind" sdlc close.sh neg-quoted shipped "PR merged"
# the worktree binding itself is still intact after all that (the added
# commits carried .sdlc/ and the quoted file only): local delivery closes
sed "s|^- Target: .*|- Target: local|; s|^- Source: .*|- Source: worktree:$DQ|" .sdlc/work/neg-quoted/delivery.md > d.tmp
mv d.tmp .sdlc/work/neg-quoted/delivery.md
assert_ok_msg "C16l the unchanged reviewed worktree still closes locally" "delivery: local" \
  sdlc close.sh neg-quoted shipped "delivered locally"

# C17 a symlink whose name starts with '-' at the project root: readlink must not
# read it as an option, or its target would hash as a stable error and a retarget
# would never be drift. Then the true commit containing it delivers as pr.
mkdir -p .sdlc/work/neg-dash
echo goal > .sdlc/work/neg-dash/intent.md
echo ev > .sdlc/work/neg-dash/evidence.md
mklink app.sh ./-link
git add -A .; git commit -qm "feat: -link -> app.sh"
DASH_SHA=$(git rev-parse HEAD)
assert_ok "C17 ship approval with a root '-link' symlink" sdlc approve.sh ship .sdlc/work/neg-dash/evidence.md --delegated
printf '%s' app.sh > "$FIX/target.txt"
assert_grep .sdlc/approvals/neg-dash.ship.source "^l - $(sha256of "$FIX/target.txt") -link\$" \
  "C17b the '-link' entry hashes its real target string (app.sh), not a readlink error"
rm -f ./-link; mklink gone.sh ./-link        # retarget: same name, different target
assert_fail_msg "C17c retargeting '-link' after the review is drift" "the source changed after the ship review" \
  sdlc check-gate.sh ship .sdlc/work/neg-dash/evidence.md
rm -f ./-link; mklink app.sh ./-link         # back to the reviewed target
assert_ok_msg "C17d the restored target reopens the ship gate" "GATE OPEN" \
  sdlc check-gate.sh ship .sdlc/work/neg-dash/evidence.md
cat > .sdlc/work/neg-dash/delivery.md <<EOF
# Delivery: neg-dash
- Target: pr
- Source: $DASH_SHA
- Verified-by: git show --stat $DASH_SHA
- Evidence: -link
- Confirmed: yes
EOF
assert_ok_msg "C17e the commit that contains the reviewed '-link' delivers as pr" "delivery: pr" \
  sdlc close.sh neg-dash shipped "PR merged"
rm -f ./-link '한글 and space.txt'

# fixture cleanup, explicit and checked (this repo is ours; the close steps above
# edited .gitignore, which would otherwise make the checkout fail silently)
if git reset -q --hard HEAD && git checkout -q "$BASE_BRANCH"; then
  pass "C14 fixture returns to $BASE_BRANCH cleanly"
else
  fail "C14 fixture could not return to $BASE_BRANCH"
fi

echo
echo "================================================================"
echo "PASSED: $PASSED   FAILED: $FAILED"
if [ "$FAILED" -gt 0 ]; then printf 'failures:%s\n' "$FAILLIST"; exit 1; fi
echo "E2E PASS"
