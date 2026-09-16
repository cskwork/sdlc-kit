#!/usr/bin/env bash
# autotest.sh [kit-path] — regression suite for the AUTOMATION layer
# (tools/auto.sh, tools/verify.sh, tools/handoff.sh, gates/_auto.sh).
#
# Same shape as gates/e2e.sh: throwaway git projects in its own mktemp fixture,
# the real scripts, assertions on observable results. Every "push" goes to a
# LOCAL bare repository in the same fixture — no network, no remote host, no
# `gh` call. Nothing outside the fixture is written.
#
# It asserts behavior, never prose: each case drives real commands in a real
# repository and reads what the tools actually answer.
#
# Exit 0 = every assertion held. Exit 1 = at least one FAIL (listed at the end).
set -u

KIT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
KIT=$(cd "$KIT" 2>/dev/null && pwd) || { echo "no such kit path: ${1:-}" >&2; exit 2; }
[ -f "$KIT/tools/auto.sh" ] || { echo "not a kit with the automation layer: $KIT" >&2; exit 2; }

BASE="${AUTOTEST_BASE:-${TMPDIR:-/tmp}}"
mkdir -p "$BASE" || exit 2
FIX=$(mktemp -d "${BASE%/}/sdlc-auto.XXXXXX") || exit 2
case "$FIX" in */sdlc-auto.*) ;; *) echo "refusing to use fixture $FIX" >&2; exit 2;; esac
cleanup() { case "$FIX" in */sdlc-auto.*) rm -rf "$FIX";; esac; }
[ -n "${AUTOTEST_KEEP:-}" ] || trap cleanup EXIT
echo "fixture: $FIX"
echo "kit:     $KIT"
# Which sha256 tool this platform actually resolved. A fixture that hardcodes
# one the platform does not have writes a digest the kit never would, and the
# case then fails for a reason that has nothing to do with what it asserts.
echo "sha256:  $(command -v shasum || command -v sha256sum || command -v openssl || echo NONE)"
echo

PASSED=0; FAILED=0; FAILLIST=""
pass() { PASSED=$((PASSED + 1)); printf 'PASS  %s\n' "$1"; }
# The whole output of a failing case is printed, line by line and unmangled. It
# used to be squashed onto one 300-character line, which on Windows cut every
# python traceback off at its first frame and hid the exception that caused the
# failure. A runaway log is bounded by lines, not by bytes, so the message that
# matters is never the part that is dropped.
fail() { FAILED=$((FAILED + 1)); FAILLIST="$FAILLIST
  - $1"; printf 'FAIL  %s\n' "$1"
  if [ -n "${2:-}" ]; then
    printf '      output:\n'
    printf '%s\n' "$2" | head -n 200 | sed 's/^/      | /'
    [ "$(printf '%s\n' "$2" | wc -l)" -gt 200 ] && printf '      | … (output truncated at 200 lines)\n'
  fi; return 0; }
assert_exit() { local d="$1" e="$2"; shift 2; local o rc; o=$("$@" 2>&1); rc=$?
  [ "$rc" = "$e" ] && pass "$d" || fail "$d (exit $rc, expected $e)" "$o"; }
assert_msg() { local d="$1" n="$2"; shift 2; local o; o=$("$@" 2>&1)
  case "$o" in *"$n"*) pass "$d";; *) fail "$d (missing '$n')" "$o";; esac; }
assert_exit_msg() { local d="$1" e="$2" n="$3"; shift 3; local o rc; o=$("$@" 2>&1); rc=$?
  if [ "$rc" != "$e" ]; then fail "$d (exit $rc, expected $e)" "$o"
  else case "$o" in *"$n"*) pass "$d";; *) fail "$d (exit ok, message lacks '$n')" "$o";; esac; fi; }
assert_grep() { grep -q "$2" "$1" 2>/dev/null && pass "$3" || fail "$3 (no /$2/ in $1)"; }
assert_nogrep() { grep -q "$2" "$1" 2>/dev/null && fail "$3 (unexpected /$2/ in $1)" || pass "$3"; }

auto()    { "$KIT/tools/auto.sh" "$@"; }
verify()  { "$KIT/tools/verify.sh" "$@"; }
handoff() { "$KIT/tools/handoff.sh" "$@"; }
gate()    { "$KIT/gates/$1" "${@:2}"; }

# ---------------------------------------------------------------- fixtures
gitinit() {
  git init -q .
  git symbolic-ref HEAD refs/heads/main
  git config user.email auto@fixture.local
  git config user.name "Autotest Fixture"
  git config commit.gpgsign false
}

# mkproj <dir> <lazymode> — a seeded project with a tiny runnable app
mkproj() {
  local d="$1" lm="$2"
  mkdir -p "$d"; ( cd "$d" && gitinit )
  ( cd "$d" && bash "$KIT/init.sh" >/dev/null )
  printf '#!/bin/sh\necho hello\n' > "$d/app.sh"; chmod +x "$d/app.sh"
  awk -v lm="$lm" '/^lazymode:/{print "lazymode: " lm; next}
                   /^test:/{print "test: sh app.sh"; next}
                   /^run:/{print "run: sh app.sh"; next}
                   {print}' "$d/.sdlc/config.md" > "$d/.sdlc/c.tmp"
  mv "$d/.sdlc/c.tmp" "$d/.sdlc/config.md"
}

# write_intent <dir> <slug> <material-question-line> — a compact, full-auto-ready
# intent unless a material question is passed in
write_intent() {
  local d="$1" s="$2" mat="${3:-}"
  mkdir -p "$d/.sdlc/work/$s"
  cat > "$d/.sdlc/work/$s/intent.md" <<EOF
# Intent: $s
- Goal: a caller running the app sees a greeting.
- Date: 2026-09-17
- Type: brownfield
- Track: compact — one file, one existing command proves it
- Scope authorization: "fix $s and push a review branch"

## Evidence
- app.sh prints hello today [verified: sh app.sh]

## Success criteria
- [ ] \`sh app.sh\` prints the greeting

## Compact route
- Files: app.sh
- Proof: sh app.sh
- Risk: app.sh only; revert the single commit
- Delivery target: pr

## Material questions
$mat

## Out of scope / must not change
- packaging stays as it is
EOF
}

write_recipe() { # <dir> <profile> <extra check lines…>
  local d="$1" p="$2"; shift 2
  { echo "profile: $p"
    echo "environment: local shell fixture"
    echo "check: unit | unit | sh app.sh"
    for l in "$@"; do echo "$l"; done
  } > "$d/.sdlc/verify.md"
}

# =====================================================================
# A1 full-auto (lazymode 4) walks intent → build → ship → delivery without a
#    single human ask, as long as the intent contract holds and the checks pass
# =====================================================================
P="$FIX/a1"; mkproj "$P" 4; cd "$P"
write_intent "$P" feat-a1
assert_exit_msg "A1a a clear intent satisfies the full-auto contract" 0 "INTENT ok" auto intent-check feat-a1
assert_exit_msg "A1b lazymode 4: the intent gate is the agent's to record" 0 "ready intent" auto next feat-a1
gate approve.sh intent .sdlc/work/feat-a1/intent.md --lazy --review "read app.sh and its caller" >/dev/null
assert_exit_msg "A1c after the intent gate the next action is build, not a human ask" 0 "ready build" auto next feat-a1
write_recipe "$P" advisory "check: R1 | e2e | sh -c './app.sh | grep -q hello'"
assert_exit_msg "A1d the recipe's real commands run and the receipt is written" 0 "VERIFY ok" verify run feat-a1
assert_grep .sdlc/work/feat-a1/verify-receipt.md '^runtime_evidence: yes' "A1e the receipt records that a real e2e check ran"
assert_grep .sdlc/work/feat-a1/scratch/verify/R1.log '\$ sh -c' "A1f the e2e log holds the command that was executed"
printf '# Evidence: feat-a1\n- R1: sh app.sh → hello\n' > .sdlc/work/feat-a1/evidence.md
assert_exit_msg "A1g with a passing receipt the ship gate is the agent's" 0 "ready ship" auto next feat-a1
gate approve.sh ship .sdlc/work/feat-a1/evidence.md --lazy --review "read the diff" >/dev/null
assert_exit_msg "A1h delivery to a pr target stays inside the authorized scope" 0 "ready delivery" auto next feat-a1
out=$(auto status --json)
case "$out" in *'"status": "ready"'*) pass "A1i the machine view agrees with next";; *) fail "A1i machine view" "$out";; esac
if command -v python3 >/dev/null 2>&1; then
  printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["schema"]=="sdlc-kit/auto-status@1"; f=d["features"][0];
assert set(["slug","stage","status","next_action","blockers","source","delivery","handoff","verification","checkpoint","exit_condition"]) <= set(f)' \
    && pass "A1j status --json is valid JSON with the documented keys" || fail "A1j status --json schema"
  gate status.sh --json > "$FIX/via-status.json" 2>&1
  python3 - "$FIX/via-status.json" <<'PY' && pass "A1k gates/status.sh --json is the same machine view" || fail "A1k status.sh --json"
import json,sys
d=json.load(open(sys.argv[1]))
assert d["schema"]=="sdlc-kit/auto-status@1" and d["features"][0]["slug"]=="feat-a1"
PY
else
  pass "A1j/A1k skipped: no python3 to parse JSON with"
fi

# =====================================================================
# A2 an unresolved MATERIAL question stops the loop at every lazymode — the
#    agent never guesses one away to make progress
# =====================================================================
P="$FIX/a2"; mkproj "$P" 4; cd "$P"
write_intent "$P" feat-a2 "- which of the two greetings is the correct one?"
assert_exit_msg "A2a a material question fails the intent contract" 10 "unresolved MATERIAL" auto intent-check feat-a2
assert_exit_msg "A2b full-auto stops for it instead of approving the gate" 10 "needs-human" auto next feat-a2
assert_msg "A2c the blocker names the intent, not a generic stall" "intent.material" auto next feat-a2
# resolving it in place (the trail survives) releases the loop
sed 's/- which of the two greetings is the correct one?/- which greeting? — resolved: the human chose "hello" (chat, 2026-09-17)/' \
  .sdlc/work/feat-a2/intent.md > i.tmp && mv i.tmp .sdlc/work/feat-a2/intent.md
assert_exit_msg "A2d a resolved question releases the loop" 0 "ready intent" auto next feat-a2
# an intent without acceptance criteria / non-goals is not full-auto ready
grep -v '^- \[ \]' .sdlc/work/feat-a2/intent.md > i.tmp && mv i.tmp .sdlc/work/feat-a2/intent.md
assert_exit_msg "A2e missing acceptance criteria blocks (never a guess)" 20 "Success-criteria" auto intent-check feat-a2
assert_exit_msg "A2f the loop reports it as blocked, with the repair" 20 "blocked" auto next feat-a2

# =====================================================================
# A3 verification: a failing check, a missing receipt, and a strict profile with
#    no runtime evidence each block review-ready. No pass from prose.
# =====================================================================
P="$FIX/a3"; mkproj "$P" 4; cd "$P"
write_intent "$P" feat-a3
gate approve.sh intent .sdlc/work/feat-a3/intent.md --lazy --review "read app.sh" >/dev/null
printf '# Evidence: feat-a3\n- R1: sh app.sh → hello (claimed)\n' > .sdlc/work/feat-a3/evidence.md
write_recipe "$P" strict
assert_exit_msg "A3a no receipt yet: the ship gate is blocked, not waived" 20 "verify.stale" auto next feat-a3
assert_exit_msg "A3b strict without a runtime/e2e check refuses review-ready" 1 "VERIFY blocked" verify run feat-a3
assert_exit_msg "A3c and the loop stays blocked on it" 20 "blocked" auto next feat-a3
# a failing real check blocks too
write_recipe "$P" strict "check: R1 | e2e | sh -c './app.sh | grep -q goodbye'"
assert_exit_msg "A3d a failing e2e check fails the run" 1 "VERIFY fail" verify run feat-a3
assert_grep .sdlc/work/feat-a3/verify-receipt.md '^result: fail' "A3e the receipt records the failure"
assert_exit_msg "A3f a failed check blocks the loop" 20 "verify.fail" auto next feat-a3
# fixing the code makes the SAME check pass, and only then is the gate the agent's
printf '#!/bin/sh\necho goodbye\n' > app.sh
assert_exit_msg "A3g a source edit invalidates the old receipt" 1 "VERIFY stale" verify check feat-a3
assert_exit_msg "A3h the same check now passes" 0 "VERIFY ok" verify run feat-a3
assert_exit_msg "A3i with runtime evidence the ship gate is the agent's" 0 "ready ship" auto next feat-a3
# a hand-written receipt proves nothing: the source digest is part of it
sed 's/^source_digest: .*/source_digest: 0000000000000000000000000000000000000000000000000000000000000000/' \
  .sdlc/work/feat-a3/verify-receipt.md > r.tmp && mv r.tmp .sdlc/work/feat-a3/verify-receipt.md
assert_exit_msg "A3j a receipt whose digests disagree with each other is invalid" 1 "VERIFY invalid" verify check feat-a3
verify run feat-a3 >/dev/null 2>&1
# changing the COMMANDS invalidates it as well
write_recipe "$P" strict "check: R1 | e2e | sh -c './app.sh | grep -q bye'"
assert_exit_msg "A3k a changed recipe invalidates the receipt" 1 "VERIFY stale" verify check feat-a3
# a project with no recipe at all keeps working: the gap is reported, not faked
P="$FIX/a3b"; mkproj "$P" 4; cd "$P"
write_intent "$P" feat-a3b
gate approve.sh intent .sdlc/work/feat-a3b/intent.md --lazy --review "read app.sh" >/dev/null
assert_exit_msg "A3l no recipe: the loop runs, the unproven runtime is a named gap" 0 "ready build" auto next feat-a3b
assert_msg "A3m and the gap is visible in the machine view" "verify.unconfigured" auto status --json feat-a3b
assert_exit_msg "A3n verify check says so instead of passing" 2 "VERIFY unconfigured" verify check feat-a3b

# =====================================================================
# A4 the review handoff: a pushed feature branch is the exit condition, and the
#    remote SHA is checked, never asserted
# =====================================================================
P="$FIX/a4"; mkproj "$P" 4; cd "$P"
REMOTE="$FIX/a4-remote.git"; git init -q --bare "$REMOTE"; git remote add origin "$REMOTE"
write_intent "$P" feat-a4
gate approve.sh intent .sdlc/work/feat-a4/intent.md --lazy --review "read app.sh" >/dev/null
write_recipe "$P" strict "check: R1 | e2e | sh -c './app.sh | grep -q hello'"
verify run feat-a4 >/dev/null
printf '# Evidence: feat-a4\n- R1: sh app.sh → hello\n' > .sdlc/work/feat-a4/evidence.md
gate approve.sh ship .sdlc/work/feat-a4/evidence.md --lazy --review "read the diff" >/dev/null
git checkout -q -b feat-a4
assert_exit_msg "A4a a push without the human's authorization is refused" 1 "--authorized" handoff push feat-a4
assert_exit_msg "A4b a force flag is refused outright" 2 "never force-pushes" handoff push feat-a4 --authorized ok --force
assert_exit_msg "A4c a protected/shared branch is never a handoff target" 1 "protected/shared branch" \
  handoff push feat-a4 --branch main --authorized "ship it"
assert_exit_msg "A4d an unborn HEAD is refused with the reason" 1 "no commit yet" \
  handoff push feat-a4 --authorized "ship it"
git add .gitignore >/dev/null; git commit -qm "chore: ignores"
assert_exit_msg "A4d2 a commit that does not contain the reviewed source is refused" 1 "does not CONTAIN" \
  handoff push feat-a4 --authorized "ship it"
git add -A >/dev/null; git commit -qm "feat: greeting"
assert_exit_msg "A4e the reviewed source is pushed to the feature branch" 0 "HANDOFF review-ready" \
  handoff push feat-a4 --authorized "push the review branch"
assert_exit_msg "A4f a second push repeats no external effect" 0 "already pushed" \
  handoff push feat-a4 --authorized "push the review branch"
assert_grep .sdlc/work/feat-a4/checkpoint.md '^effect: push|' "A4g the completed push is recorded once"
n=$(grep -c '^effect: push|' .sdlc/work/feat-a4/checkpoint.md)
[ "$n" = 1 ] && pass "A4h exactly one push effect is on record" || fail "A4h push effect recorded $n times"
SHA=$(git rev-parse HEAD)
cat > .sdlc/work/feat-a4/delivery.md <<EOF
# Delivery: feat-a4
- Target: pr
- Source: $SHA
- Verified-by: git ls-remote origin refs/heads/feat-a4
- Evidence: $SHA refs/heads/feat-a4
- Confirmed: yes
- Remote: origin
- Branch: feat-a4
- Handoff: review-ready
EOF
assert_exit_msg "A4i the handoff is verified against the remote, not asserted" 0 "review-ready" handoff check feat-a4
assert_msg "A4j the machine exit condition is review-ready, not deployed" "review-ready" auto next feat-a4 --remote-check
# the remote moving on blocks review-ready: the reviewer would read other code
git commit -q --allow-empty -m "unrelated later commit"
git push -q origin HEAD:refs/heads/feat-a4
assert_exit_msg "A4k a remote branch at another commit blocks the handoff" 1 "mismatch" handoff check feat-a4
assert_exit_msg "A4l and the machine view blocks with it" 20 "handoff.remote-mismatch" auto next feat-a4 --remote-check
git push -q origin +"$SHA":refs/heads/feat-a4
assert_exit_msg "A4m restoring the delivered commit clears it" 0 "review-ready" handoff check feat-a4
# merge and deploy are a separate human decision, at lazymode 4 too
sed 's/^- Handoff: review-ready/- Handoff: merged/' .sdlc/work/feat-a4/delivery.md > d.tmp && mv d.tmp .sdlc/work/feat-a4/delivery.md
assert_exit_msg "A4n merged without the human's authorization is refused" 1 "Authorized-by" handoff check feat-a4
assert_exit_msg "A4o the loop asks the human for it, at lazymode 4" 10 "handoff.unauthorized" auto next feat-a4
printf -- '- Authorized-by: "merge it after review" — human, 2026-09-17\n' >> .sdlc/work/feat-a4/delivery.md
assert_exit_msg "A4p with the authorization recorded the handoff stands" 0 "HANDOFF" handoff check feat-a4
# a deploy target that was never delivered is a human decision, never an auto-push
P="$FIX/a4b"; mkproj "$P" 4; cd "$P"
write_intent "$P" feat-a4b
sed 's/^- Delivery target: pr/- Delivery target: deploy/' .sdlc/work/feat-a4b/intent.md > i.tmp && mv i.tmp .sdlc/work/feat-a4b/intent.md
# a deploy target trips the risk scan: --lazy needs the human's prior words
gate approve.sh intent .sdlc/work/feat-a4b/intent.md --lazy --review "read app.sh" \
  --risk-authorized "deploy feat-a4b after review" >/dev/null
printf '# Evidence: feat-a4b\n- R1: sh app.sh → hello\n' > .sdlc/work/feat-a4b/evidence.md
gate approve.sh ship .sdlc/work/feat-a4b/evidence.md --lazy --review "read the diff" >/dev/null
assert_exit_msg "A4q a deploy delivery needs its own human authorization" 10 "handoff.human" auto next feat-a4b

# =====================================================================
# A5 checkpoint and resume: bounded retries, reset on a source change, and the
#    artifacts stay the authority
# =====================================================================
P="$FIX/a5"; mkproj "$P" 4; cd "$P"
write_intent "$P" feat-a5
auto checkpoint feat-a5 --set-step build.step-2 >/dev/null
assert_grep .sdlc/work/feat-a5/checkpoint.md '^step: build.step-2' "A5a the pending step is recorded"
auto checkpoint feat-a5 --attempt build.step-2 --class transient >/dev/null
auto checkpoint feat-a5 --attempt build.step-2 --class transient >/dev/null
assert_exit_msg "A5b a transient failure gets three attempts" 0 "attempt 3/3" auto checkpoint feat-a5 --attempt build.step-2 --class transient
assert_exit_msg "A5c the fourth escalates instead of looping" 20 "RETRY CAP" auto checkpoint feat-a5 --attempt build.step-2 --class transient
assert_exit_msg "A5d a deterministic failure escalates at once" 0 "attempt 1/1" auto checkpoint feat-a5 --attempt build.env --class deterministic
assert_exit_msg "A5e repeating it is capped" 20 "RETRY CAP" auto checkpoint feat-a5 --attempt build.env --class deterministic
assert_exit_msg "A5f an effect is recorded once and not repeated" 0 "effect recorded" auto checkpoint feat-a5 --effect "push|origin|feat-a5|abc123"
assert_exit_msg "A5g a resume sees it as already done" 0 "already recorded" auto checkpoint feat-a5 --effect "push|origin|feat-a5|abc123"
# a code change invalidates the attempt counters: those failures were another code's
printf '#!/bin/sh\necho changed\n' > app.sh
assert_msg "A5h a source change marks the checkpoint stale" "stale" auto checkpoint feat-a5 --show
assert_exit_msg "A5i and the retry budget starts again for the new code" 0 "attempt 1/3" auto checkpoint feat-a5 --attempt build.step-2 --class transient
assert_grep .sdlc/work/feat-a5/checkpoint.md '^effect: push|' "A5j completed external effects survive the reset"
# the checkpoint is not authority: deleting it changes no gate verdict
before=$(auto next feat-a5 2>&1)
rm -f .sdlc/work/feat-a5/checkpoint.md
after=$(auto next feat-a5 2>&1)
[ "$before" = "$after" ] && pass "A5k the artifacts, not the checkpoint, decide the next action" \
  || fail "A5k next action changed when the checkpoint was deleted" "$before // $after"

# =====================================================================
# A6 nothing loosened: lazymode 0 keeps its human gates, and the ship source
#    binding is exactly as strict as check-gate.sh
# =====================================================================
P="$FIX/a6"; mkproj "$P" 0; cd "$P"
write_intent "$P" feat-a6
assert_exit_msg "A6a lazymode 0: the intent gate is a human decision" 10 "needs-human" auto next feat-a6
assert_msg "A6b and the machine view names the gate" "gate.human.intent" auto next feat-a6
assert_exit_msg "A6c --lazy is still refused by approve.sh at lazymode 0" 1 "keeps the 'intent' gate HUMAN" \
  gate approve.sh intent .sdlc/work/feat-a6/intent.md --lazy --review x
gate approve.sh intent .sdlc/work/feat-a6/intent.md >/dev/null
# full track at lazymode 0: the plan gate is tiered, a trip-wire keeps it human
P="$FIX/a6b"; mkproj "$P" 0; cd "$P"
mkdir -p .sdlc/work/feat-a6b
write_intent "$P" feat-a6b
sed 's/^- Track: compact.*/- Track: full/' .sdlc/work/feat-a6b/intent.md > i.tmp && mv i.tmp .sdlc/work/feat-a6b/intent.md
gate approve.sh intent .sdlc/work/feat-a6b/intent.md >/dev/null
printf '# Spec\n- R1: greeting\n' > .sdlc/work/feat-a6b/spec.md
gate approve.sh spec .sdlc/work/feat-a6b/spec.md >/dev/null
printf '# Plan\n## Gate tier\n- Tier: human — touches a migration\n' > .sdlc/work/feat-a6b/plan.md
assert_exit_msg "A6d a human-tier plan stays a human gate at lazymode 0" 10 "gate.human.plan" auto next feat-a6b
printf '# Plan\n## Gate tier\n- Tier: agent — no trip-wires\n' > .sdlc/work/feat-a6b/plan.md
assert_exit_msg "A6e a clean tier is the adversary's to record" 0 "agent-adversary" auto next feat-a6b
# source drift after the ship review: the machine view and check-gate.sh agree
P="$FIX/a6c"; mkproj "$P" 4; cd "$P"
write_intent "$P" feat-a6c
gate approve.sh intent .sdlc/work/feat-a6c/intent.md --lazy --review "read app.sh" >/dev/null
printf '# Evidence: feat-a6c\n- R1: ok\n' > .sdlc/work/feat-a6c/evidence.md
gate approve.sh ship .sdlc/work/feat-a6c/evidence.md --lazy --review "read the diff" >/dev/null
printf '#!/bin/sh\necho drifted\n' > app.sh
assert_exit_msg "A6f check-gate.sh still closes on post-review source drift" 1 "source changed after the ship review" \
  gate check-gate.sh ship .sdlc/work/feat-a6c/evidence.md
assert_exit_msg "A6g the machine view blocks on the same drift" 20 "source.drift" auto next feat-a6c
# an artifact edited after approval closes the gate in both views
P="$FIX/a6d"; mkproj "$P" 4; cd "$P"
write_intent "$P" feat-a6d
gate approve.sh intent .sdlc/work/feat-a6d/intent.md --lazy --review "read app.sh" >/dev/null
echo "a later edit" >> .sdlc/work/feat-a6d/intent.md
assert_exit_msg "A6h an edited artifact blocks the machine view too" 20 "gate.stale.intent" auto next feat-a6d

# =====================================================================
# A7 a v0.9.0 delivery record (no handoff fields) keeps working unchanged
# =====================================================================
P="$FIX/a7"; mkproj "$P" 4; cd "$P"
write_intent "$P" feat-a7
sed 's/^- Delivery target: pr/- Delivery target: local/' .sdlc/work/feat-a7/intent.md > i.tmp && mv i.tmp .sdlc/work/feat-a7/intent.md
gate approve.sh intent .sdlc/work/feat-a7/intent.md --lazy --review "read app.sh" >/dev/null
printf '# Evidence: feat-a7\n- R1: ok\n' > .sdlc/work/feat-a7/evidence.md
out=$(gate approve.sh ship .sdlc/work/feat-a7/evidence.md --lazy --review "read the diff")
DIG=$(printf '%s' "$out" | awk '/Reviewed source identity/{print $4}')
cat > .sdlc/work/feat-a7/delivery.md <<EOF
# Delivery: feat-a7
- Target: local
- Source: worktree:$DIG
- Verified-by: sh app.sh
- Evidence: hello
- Confirmed: yes
EOF
assert_exit_msg "A7a an old-style local delivery still reads as deliverable" 0 "ready delivery" auto next feat-a7
assert_msg "A7b its exit condition is local, not review-ready" "local" auto next feat-a7
assert_exit_msg "A7c close.sh accepts it exactly as before" 0 "delivery: local" gate close.sh feat-a7 shipped "local delivery"
assert_exit_msg "A7d a driver polling a closed feature reads complete" 30 "complete closed" auto next feat-a7


# =====================================================================
# A8 (B1) the MATERIAL question test reads CONTENT, not Markdown markers, and
#    only the exact resolution syntax releases it. Every notation below was
#    reported as "0 unresolved questions" by the first implementation.
# =====================================================================
P="$FIX/a8"; mkproj "$P" 4; cd "$P"
write_intent "$P" feat-a8
set_material() { # <line…> — replace the Material questions body in place
  awk -v body="$1" '
    /^## Material questions/ { print; print body; skip = 1; next }
    /^## / { skip = 0 }
    skip && $0 !~ /^## / { next }
    { print }' .sdlc/work/feat-a8/intent.md > m.tmp && mv m.tmp .sdlc/work/feat-a8/intent.md
}
set_material "- unresolved: do we drop the legacy greeting endpoint?"
assert_exit_msg "A8a 'unresolved:' is not the substring 'resolved' — it blocks" 10 "unresolved MATERIAL" auto intent-check feat-a8
set_material "- which tenant DB do we migrate? (to be resolved with the human)"
assert_exit_msg "A8b prose mentioning 'resolved' in passing does not release it" 10 "unresolved MATERIAL" auto intent-check feat-a8
set_material "- which tenant DB? not resolved: pending the human"
assert_exit_msg "A8b2 a NEGATED marker is not a resolution — the marker is anchored" 10 "unresolved MATERIAL" auto intent-check feat-a8
set_material "- which tenant DB? non-resolved: still open"
assert_exit_msg "A8b3 'non-resolved:' does not release it either" 10 "unresolved MATERIAL" auto intent-check feat-a8
set_material "  - do we delete the users table? (nested bullet)"
assert_exit_msg "A8c a nested bullet counts" 10 "unresolved MATERIAL" auto intent-check feat-a8
set_material "* do we delete the users table? (asterisk bullet)"
assert_exit_msg "A8d an asterisk bullet counts" 10 "unresolved MATERIAL" auto intent-check feat-a8
set_material "1. do we delete the users table? (numbered)"
assert_exit_msg "A8e a numbered item counts" 10 "unresolved MATERIAL" auto intent-check feat-a8
set_material "Do we delete the users table? (prose line, no marker at all)"
assert_exit_msg "A8f a bare prose line counts (fail-closed)" 10 "unresolved MATERIAL" auto intent-check feat-a8
assert_exit_msg "A8g and the loop stops for it at lazymode 4" 10 "intent.material" auto next feat-a8
set_material "- do we delete the users table? — resolved: no, the human kept it (chat 2026-09-17)"
assert_exit_msg "A8h the exact resolution syntax releases it" 0 "INTENT ok" auto intent-check feat-a8
set_material "- [resolved] which tenant DB? tenant A (chat 2026-09-17)"
assert_exit_msg "A8h2 the bracket form in the same anchored position releases it" 0 "INTENT ok" auto intent-check feat-a8
set_material "none"
assert_exit_msg "A8i an explicit 'none' releases it" 0 "INTENT ok" auto intent-check feat-a8
set_material ""
assert_exit_msg "A8j an empty section releases it" 0 "INTENT ok" auto intent-check feat-a8
set_material "- <material question>"
assert_exit_msg "A8k an unfilled template placeholder is incomplete, never silently ok" 20 "placeholder" auto intent-check feat-a8
# the template's own multi-line HTML comment is not content
set_material "PLACEHOLDER_COMMENT"
awk '{ if ($0 == "PLACEHOLDER_COMMENT") { print "<!-- a comment is not a question"; print "     and neither is its second line -->" } else print }' \
  .sdlc/work/feat-a8/intent.md > m.tmp && mv m.tmp .sdlc/work/feat-a8/intent.md
assert_exit_msg "A8l an HTML comment is not content" 0 "INTENT ok" auto intent-check feat-a8

# =====================================================================
# A9 (B2) the PROSE cockpit knows the same contract. This is the screen an
#    agent reads: it used to say "record the intent approval" over an open
#    material question while tools/auto.sh said "needs-human".
# =====================================================================
P="$FIX/a9"; mkproj "$P" 4; cd "$P"
write_intent "$P" feat-a9 "- which of the two greetings is correct?"
assert_exit_msg "A9a the machine view stops" 10 "needs-human" auto next feat-a9
assert_msg "A9b the cockpit names the open material question" "MATERIAL QUESTION OPEN" gate status.sh feat-a9
out=$(gate status.sh feat-a9 2>&1)
case "$out" in
  *"next  →  a MATERIAL question"*) pass "A9c and its next action is the human, not the lazy gate";;
  *) fail "A9c the cockpit still points at approve.sh" "$out";;
esac
case "$out" in
  *"next  →  lazy gate"*) fail "A9d the cockpit must not offer the lazy intent gate here" "$out";;
  *) pass "A9d the lazy intent gate is not offered over an open question";;
esac

# =====================================================================
# A10 (B3) every configured check runs. A check that reads stdin used to eat
#     the rest of the recipe, and the run reported "ok" over checks that never
#     happened — including the one that should have failed.
# =====================================================================
P="$FIX/a10"; mkproj "$P" 4; cd "$P"
write_intent "$P" feat-a10
gate approve.sh intent .sdlc/work/feat-a10/intent.md --lazy --review "read app.sh" >/dev/null
{ echo "profile: advisory"
  echo "check: unit | unit | sh app.sh"
  echo "check: greedy | unit | cat"
  echo "check: R1 | e2e | sh -c './app.sh | grep -q hello'"
  echo "check: R2 | unit | false"
} > .sdlc/verify.md
assert_exit_msg "A10a a stdin-eating check does not swallow the rest of the recipe" 1 "VERIFY fail" verify run feat-a10
n=$(grep -c '^check: ' .sdlc/work/feat-a10/verify-receipt.md)
[ "$n" = 4 ] && pass "A10b all four configured checks are on the receipt" || fail "A10b only $n of 4 checks ran"
assert_grep .sdlc/work/feat-a10/verify-receipt.md '^checks_run: 4' "A10c the receipt states how many checks ran"
assert_grep .sdlc/work/feat-a10/verify-receipt.md '^result: fail' "A10d the check that had to fail was reached"
# with the failing check fixed the same recipe passes — over ALL four checks
{ echo "profile: advisory"
  echo "check: unit | unit | sh app.sh"
  echo "check: greedy | unit | cat"
  echo "check: R1 | e2e | sh -c './app.sh | grep -q hello'"
  echo "check: R2 | unit | true"
} > .sdlc/verify.md
assert_exit_msg "A10e the fixed recipe passes over every check" 0 "(4/4)" verify run feat-a10
# and a receipt CLAIMING a pass without accounting for every configured check
# is invalid, not ok
sed 's/^checks_run: 4/checks_run: 2/' .sdlc/work/feat-a10/verify-receipt.md > r.tmp && mv r.tmp .sdlc/work/feat-a10/verify-receipt.md
assert_exit_msg "A10f a pass that does not account for every check is invalid" 1 "VERIFY invalid" verify check feat-a10

# =====================================================================
# A11 (B4) an owned runtime: launched in its own process group, proven alive,
#     and stopped as a GROUP. A runtime this run did not start never counts as
#     evidence about this source.
# =====================================================================
P="$FIX/a11"; mkproj "$P" 4; cd "$P"
write_intent "$P" feat-a11
gate approve.sh intent .sdlc/work/feat-a11/intent.md --lazy --review "read app.sh" >/dev/null
mkdir -p .sdlc/work/feat-a11/scratch
# a runtime that forks a grandchild and waits: killing the direct child alone
# leaves the grandchild holding whatever it holds
cat > server.sh <<'SH'
#!/bin/sh
( while :; do date +%s > .sdlc/work/feat-a11/scratch/served.txt; sleep 1; done ) &
echo $! > .sdlc/work/feat-a11/scratch/inner.pid
wait
SH
{ echo "profile: strict"
  echo "launch: sh server.sh"
  echo "doctor: test -s .sdlc/work/feat-a11/scratch/served.txt"
  echo "doctor_timeout: 20"
  echo "check: R1 | e2e | test -s .sdlc/work/feat-a11/scratch/served.txt"
} > .sdlc/verify.md
assert_exit_msg "A11a a launched runtime plus a passing doctor verifies" 0 "VERIFY ok" verify run feat-a11
assert_grep .sdlc/work/feat-a11/verify-receipt.md '^launch: started' "A11b the receipt records that THIS run started the runtime"
assert_grep .sdlc/work/feat-a11/verify-receipt.md '^runtime_instance: owned' "A11c and that the instance was its own"
before=$(cat .sdlc/work/feat-a11/scratch/served.txt)
sleep 3
after=$(cat .sdlc/work/feat-a11/scratch/served.txt)
[ "$before" = "$after" ] && pass "A11d the whole process group is gone: nothing keeps writing" \
  || fail "A11d LEAK: the grandchild survived tools/verify.sh ($before → $after)"
if [ -f .sdlc/work/feat-a11/scratch/inner.pid ]; then
  ipid=$(cat .sdlc/work/feat-a11/scratch/inner.pid)
  kill -0 "$ipid" 2>/dev/null && fail "A11e the forked grandchild ($ipid) is still alive" \
    || pass "A11e the forked grandchild is not alive either"
fi
# --no-launch: the checks run against something this run did not start. Under a
# strict profile that is NOT runtime proof of this source, and it says so.
rm -f .sdlc/work/feat-a11/scratch/served.txt
date +%s > .sdlc/work/feat-a11/scratch/served.txt   # an "external instance" already serving
assert_exit_msg "A11f --no-launch under strict refuses to call an external instance proof" 1 "EXTERNAL" \
  verify run feat-a11 --no-launch
assert_grep .sdlc/work/feat-a11/verify-receipt.md '^runtime_instance: external' "A11g the receipt labels the instance external"
# a launch that dies while something else answers the doctor: the doctor's
# "yes" is about a process this run does not own
P="$FIX/a11b"; mkproj "$P" 4; cd "$P"
write_intent "$P" feat-a11b
gate approve.sh intent .sdlc/work/feat-a11b/intent.md --lazy --review "read app.sh" >/dev/null
mkdir -p .sdlc/work/feat-a11b/scratch
# The launched runtime must still be up for the doctor's FIRST attempt and gone
# for the one that answers. A fixed `sleep` raced that window (python's own
# start-up cost alone is most of a second on the Windows runner), so the doctor
# ends the launch itself and waits for it to be really gone: same proof, no
# clock in it.
cat > launch.sh <<'SH'
#!/bin/sh
d=.sdlc/work/feat-a11b/scratch
: > "$d/up"
i=0
while [ ! -f "$d/stop" ] && [ "$i" -lt 300 ]; do sleep 0.2; i=$((i + 1)); done
rm -f "$d/up"
SH
cat > doctor.sh <<'SH'
#!/bin/sh
# answers only from the second attempt on — and by then the launch IS dead,
# because this is what stops it
d=.sdlc/work/feat-a11b/scratch
if [ ! -f "$d/tick" ]; then : > "$d/tick"; exit 1; fi
: > "$d/stop"
i=0
while [ -f "$d/up" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
[ -f "$d/up" ] && exit 1     # the launch never went away: assert nothing
sleep 1                      # let the shell that wrote it finish exiting
exit 0
SH
{ echo "profile: strict"
  echo "launch: sh launch.sh"
  echo "doctor: sh doctor.sh"
  echo "doctor_timeout: 20"
  echo "check: R1 | e2e | true"
} > .sdlc/verify.md
assert_exit_msg "A11h a doctor answered by a runtime this run did not start blocks" 1 "already dead" verify run feat-a11b
assert_grep .sdlc/work/feat-a11b/verify-receipt.md '^doctor: unowned-runtime' "A11i the receipt records the unowned runtime"
assert_exit_msg "A11j and the machine view will not call it verified" 1 "VERIFY blocked" verify check feat-a11b
# a launch that never comes up at all is a failure, not a skipped step
P="$FIX/a11c"; mkproj "$P" 4; cd "$P"
write_intent "$P" feat-a11c
gate approve.sh intent .sdlc/work/feat-a11c/intent.md --lazy --review "read app.sh" >/dev/null
{ echo "profile: strict"
  echo "launch: sh -c 'echo EADDRINUSE: port 3000 already in use >&2; exit 1'"
  echo "check: R1 | e2e | true"
} > .sdlc/verify.md
assert_exit_msg "A11k a launch that exits immediately fails the run" 1 "VERIFY" verify run feat-a11c
assert_grep .sdlc/work/feat-a11c/verify-receipt.md '^launch: failed' "A11l and the receipt says the launch failed"

# =====================================================================
# A12 (B4/N6) a check that hangs is bounded. Unattended, one hung command used
#     to stop the driver for good.
# =====================================================================
P="$FIX/a12"; mkproj "$P" 4; cd "$P"
write_intent "$P" feat-a12
gate approve.sh intent .sdlc/work/feat-a12/intent.md --lazy --review "read app.sh" >/dev/null
{ echo "profile: advisory"
  echo "check_timeout: 3"
  echo "check: hang | unit | sleep 120"
  echo "check: after | unit | true"
} > .sdlc/verify.md
t0=$(date +%s)
assert_exit_msg "A12a a hung check is killed at check_timeout, not waited on" 1 "TIMED OUT" verify run feat-a12
t1=$(date +%s)
[ $((t1 - t0)) -lt 60 ] && pass "A12b the bound really was the wall clock ($((t1 - t0))s)" \
  || fail "A12b the run took $((t1 - t0))s"
assert_grep .sdlc/work/feat-a12/verify-receipt.md '^checks_run: 2' "A12c the checks after the hung one still ran"
# a half-filled recipe is refused before anything is executed
P="$FIX/a12b"; mkproj "$P" 4; cd "$P"
write_intent "$P" feat-a12b
gate approve.sh intent .sdlc/work/feat-a12b/intent.md --lazy --review "read app.sh" >/dev/null
cp "$KIT/templates/verify.md" .sdlc/verify.md
t0=$(date +%s)
assert_exit_msg "A12d an unfilled recipe is refused immediately, not run" 2 "placeholder" verify run feat-a12b
t1=$(date +%s)
[ $((t1 - t0)) -lt 30 ] && pass "A12e it does not burn the doctor timeout on a placeholder" \
  || fail "A12e the placeholder recipe took $((t1 - t0))s"
assert_exit_msg "A12f the loop reports the recipe, not a fake verification" 20 "verify.recipe" auto next feat-a12b

# =====================================================================
# A13 (N5) a check that writes into the tree makes the receipt describe a
#     snapshot that no longer exists. Saying `ok` and then `stale` forever
#     livelocked the driver.
# =====================================================================
P="$FIX/a13"; mkproj "$P" 4; cd "$P"
write_intent "$P" feat-a13
gate approve.sh intent .sdlc/work/feat-a13/intent.md --lazy --review "read app.sh" >/dev/null
{ echo "profile: advisory"
  echo "check: cover | unit | sh -c 'date +%s%N > coverage.out'"
} > .sdlc/verify.md
assert_exit_msg "A13a a check that changes the source ends inconclusive, not ok" 1 "inconclusive" verify run feat-a13
assert_grep .sdlc/work/feat-a13/verify-receipt.md '^source_digest_before: ' "A13b the receipt records the source before"
assert_grep .sdlc/work/feat-a13/verify-receipt.md '^source_digest_after: ' "A13c and after"
assert_exit_msg "A13d the state stays inconclusive instead of flapping ok/stale" 1 "VERIFY" verify check feat-a13

# =====================================================================
# A14 (N4/N10) a receipt is change detection: a cited log that does not exist,
#     or one edited afterwards, is visible. (It is NOT authentication — see the
#     limitation in docs/automation.md.)
# =====================================================================
P="$FIX/a14"; mkproj "$P" 4; cd "$P"
write_intent "$P" feat-a14
gate approve.sh intent .sdlc/work/feat-a14/intent.md --lazy --review "read app.sh" >/dev/null
write_recipe "$P" advisory "check: R1 | e2e | sh -c './app.sh | grep -q hello'"
verify run feat-a14 >/dev/null 2>&1
assert_exit_msg "A14a the real receipt is ok" 0 "VERIFY ok" verify check feat-a14
mv .sdlc/work/feat-a14/scratch/verify/R1.log .sdlc/work/feat-a14/scratch/verify/R1.log.bak
assert_exit_msg "A14b a receipt citing a log that is not there is invalid" 1 "does not exist" verify check feat-a14
mv .sdlc/work/feat-a14/scratch/verify/R1.log.bak .sdlc/work/feat-a14/scratch/verify/R1.log
echo "and everything else passed too" >> .sdlc/work/feat-a14/scratch/verify/R1.log
assert_exit_msg "A14c a log edited after the run is invalid" 1 "changed after it was recorded" verify check feat-a14
# The digests a receipt binds are raw bytes of the artifact, whichever sha256
# tool the platform actually has (shasum, sha256sum, openssl — Git Bash does not
# necessarily ship the first). A tool that read in TEXT mode would hash a CRLF
# file and its LF twin to the same value, i.e. change detection would stop
# detecting a change; python3 (already required by tools/verify.sh) is the
# independent reading of those bytes.
if command -v python3 >/dev/null 2>&1; then
  want=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' .sdlc/verify.md)
  got=$(bash -c '. "'"$KIT"'/gates/_common.sh"; . "'"$KIT"'/gates/_auto.sh"; sdlc_verify_recipe_digest')
  [ "$want" = "$got" ] && pass "A14a2 the recipe digest is the sha256 of the recipe's actual bytes" \
    || fail "A14a2 the recipe digest is not the sha256 of the recipe's actual bytes" "bytes: $want
helper: $got
sha tool: $(command -v shasum || command -v sha256sum || command -v openssl || echo none)"
fi
# a hand-written receipt that cites logs nobody wrote. Its digests come from the
# kit's OWN helpers (as the source_digest lines above already did): hardcoding
# `shasum` here made the fixture, not the product, the thing under test — and on
# Git Bash it produced a digest the kit never would, so this case failed as
# `stale` (wrong recipe digest) long before it could reach the missing logs it
# is actually about.
P="$FIX/a14b"; mkproj "$P" 4; cd "$P"
write_intent "$P" feat-a14b
gate approve.sh intent .sdlc/work/feat-a14b/intent.md --lazy --review "read app.sh" >/dev/null
write_recipe "$P" strict "check: R1 | e2e | sh -c './app.sh | grep -q hello'"
cat > .sdlc/work/feat-a14b/verify-receipt.md <<EOF
receipt_schema: sdlc-kit/verify-receipt@1
slug: feat-a14b
source_digest_before: $(cd "$P" && bash -c '. "'"$KIT"'/gates/_common.sh"; sdlc_source_digest')
source_digest_after: $(cd "$P" && bash -c '. "'"$KIT"'/gates/_common.sh"; sdlc_source_digest')
recipe_digest: $(cd "$P" && bash -c '. "'"$KIT"'/gates/_common.sh"; . "'"$KIT"'/gates/_auto.sh"; sdlc_verify_recipe_digest')
profile: strict
doctor: pass
runtime_evidence: yes
checks_configured: 2
checks_run: 2
result: pass
check: unit | unit | 0 | deadbeef | deadbeef | .sdlc/work/feat-a14b/scratch/verify/unit.log
check: R1 | e2e | 0 | deadbeef | deadbeef | .sdlc/work/feat-a14b/scratch/verify/R1.log
EOF
assert_exit_msg "A14d a typed receipt whose logs never existed does not pass" 1 "VERIFY invalid" verify check feat-a14b
assert_exit_msg "A14e and it does not open the ship gate" 20 "verify" auto next feat-a14b

# =====================================================================
# A15 (B5) the COMPLETE ship gate is re-checked immediately before the push.
#     An evidence.md edited after approval closes the gate — and used to leave
#     the push running anyway.
# =====================================================================
P="$FIX/a15"; mkproj "$P" 4; cd "$P"
REMOTE="$FIX/a15-remote.git"; git init -q --bare "$REMOTE"; git remote add origin "$REMOTE"
write_intent "$P" feat-a15
gate approve.sh intent .sdlc/work/feat-a15/intent.md --lazy --review "read app.sh" >/dev/null
write_recipe "$P" advisory "check: R1 | e2e | sh -c './app.sh | grep -q hello'"
verify run feat-a15 >/dev/null 2>&1
printf '# Evidence: feat-a15\n- R1: sh app.sh → hello\n' > .sdlc/work/feat-a15/evidence.md
git checkout -q -b feat-a15
git add -A >/dev/null; git commit -qm "feat: greeting"
gate approve.sh ship .sdlc/work/feat-a15/evidence.md --lazy --review "read the diff" >/dev/null
printf -- '- full e2e suite green on staging\n' >> .sdlc/work/feat-a15/evidence.md
assert_exit_msg "A15a check-gate.sh calls the edited artifact CLOSED" 1 "changed after it was approved" \
  gate check-gate.sh ship .sdlc/work/feat-a15/evidence.md
assert_exit_msg "A15b the machine view blocks with it" 20 "gate.stale.ship" auto next feat-a15
assert_exit_msg "A15c and the push refuses, in check-gate.sh's own words" 1 "changed after it was approved" \
  handoff push feat-a15 --authorized "push the review branch"
[ -z "$(git ls-remote "$REMOTE" 2>/dev/null)" ] && pass "A15d no external effect happened over a closed gate" \
  || fail "A15d the remote has refs: something was pushed over a CLOSED ship gate"
# repairing the gate lets the same push through
gate approve.sh ship .sdlc/work/feat-a15/evidence.md --lazy --review "re-read the diff" >/dev/null
git add -A >/dev/null; git commit -qm "docs: evidence"
assert_exit_msg "A15e a repaired gate publishes the branch" 0 "HANDOFF review-ready" \
  handoff push feat-a15 --authorized "push the review branch"
# a verification that no longer covers this source also stops the push, on its
# own: the recipe lives under .sdlc/, so the ship source binding stays intact
write_recipe "$P" advisory "check: R1 | e2e | sh -c './app.sh | grep -q hello'" "check: R2 | unit | true"
assert_exit_msg "A15f a receipt that no longer covers the recipe stops the next push" 1 "verification stale" \
  handoff push feat-a15 --authorized "push the review branch"

# =====================================================================
# A16 (B6) a `pr` feature that was never pushed does not read as review-ready,
#     and does not close as shipped. `Verified-by:` prose is not a check.
# =====================================================================
P="$FIX/a16"; mkproj "$P" 4; cd "$P"
REMOTE="$FIX/a16-remote.git"; git init -q --bare "$REMOTE"; git remote add origin "$REMOTE"
write_intent "$P" feat-a16
gate approve.sh intent .sdlc/work/feat-a16/intent.md --lazy --review "read app.sh" >/dev/null
printf '# Evidence: feat-a16\n- R1: ok\n' > .sdlc/work/feat-a16/evidence.md
git checkout -q -b feat-a16
git add -A >/dev/null; git commit -qm "feat: greeting"
gate approve.sh ship .sdlc/work/feat-a16/evidence.md --lazy --review "read the diff" >/dev/null
SHA=$(git rev-parse HEAD)
cat > .sdlc/work/feat-a16/delivery.md <<EOF
# Delivery: feat-a16
- Target: pr
- Source: $SHA
- Verified-by: git ls-remote origin refs/heads/feat-a16
- Evidence: $SHA refs/heads/feat-a16
- Confirmed: yes
- Remote: origin
- Branch: feat-a16
- Handoff: review-ready
EOF
assert_exit_msg "A16a a branch that was never pushed blocks, by default and with no flag" 20 "handoff.remote-absent" auto next feat-a16
assert_exit_msg "A16b tools/handoff.sh check agrees" 1 "HANDOFF absent" handoff check feat-a16
assert_exit_msg "A16c close.sh refuses the shipped close over the same fact" 1 "does not exist on the remote" \
  gate close.sh feat-a16 shipped "delivered for review"
# a network-free poll may say 'not checked' — it may NOT say review-ready
out=$(auto next feat-a16 --no-remote-check 2>&1)
case "$out" in
  *"review-ready"*) fail "A16d --no-remote-check claimed review-ready without looking" "$out";;
  *) pass "A16d a network-free poll does not claim review-ready";;
esac
case "$out" in
  *"close.sh"*) fail "A16e --no-remote-check suggested closing as shipped" "$out";;
  *) pass "A16e nor does it suggest closing the feature";;
esac
assert_msg "A16f it names the check it did not run" "handoff.sh check" auto next feat-a16 --no-remote-check
# the prose cockpit reports the claim as a claim, never as a confirmed handoff
assert_msg "A16f2 the cockpit does not present an unchecked handoff as done" "NOT CHECKED HERE" gate status.sh feat-a16
# a Handoff claim with no Remote/Branch at all
sed '/^- Remote: /d; /^- Branch: /d' .sdlc/work/feat-a16/delivery.md > d.tmp && mv d.tmp .sdlc/work/feat-a16/delivery.md
assert_exit_msg "A16g a handoff claim naming no branch is incomplete, not ready" 20 "handoff.incomplete" auto next feat-a16
assert_exit_msg "A16h close.sh blocks on it too" 1 "names no Remote/Branch" gate close.sh feat-a16 shipped "delivered"
# once it really is pushed, everything lines up again
git checkout -q feat-a16 2>/dev/null || true
cat > .sdlc/work/feat-a16/delivery.md <<EOF
# Delivery: feat-a16
- Target: pr
- Source: $SHA
- Verified-by: git ls-remote origin refs/heads/feat-a16
- Evidence: $SHA refs/heads/feat-a16
- Confirmed: yes
- Remote: origin
- Branch: feat-a16
- Handoff: review-ready
EOF
git push -q origin "$SHA":refs/heads/feat-a16
assert_exit_msg "A16i a branch that IS there reads review-ready" 0 "review-ready" auto next feat-a16
assert_exit_msg "A16j and close.sh accepts it, having checked the remote itself" 0 "checked with git ls-remote" \
  gate close.sh feat-a16 shipped "pushed for review"

# =====================================================================
# A17 (B7) where the loop delivers decides what it proposes. It never proposes
#     a push for a local or unknown target, and never writes its own
#     authorization.
# =====================================================================
P="$FIX/a17"; mkproj "$P" 4; cd "$P"
write_intent "$P" feat-a17
sed 's/^- Delivery target: pr/- Delivery target: local/' .sdlc/work/feat-a17/intent.md > i.tmp && mv i.tmp .sdlc/work/feat-a17/intent.md
gate approve.sh intent .sdlc/work/feat-a17/intent.md --lazy --review "read app.sh" >/dev/null
printf '# Evidence: feat-a17\n- R1: ok\n' > .sdlc/work/feat-a17/evidence.md
gate approve.sh ship .sdlc/work/feat-a17/evidence.md --lazy --review "read the diff" >/dev/null
out=$(auto next feat-a17 2>&1)
case "$out" in
  *"handoff.sh push"*) fail "A17a a local delivery was told to push" "$out";;
  *) pass "A17a a local target is delivered locally, not pushed";;
esac
case "$out" in
  *"<the human's authorization>"*) fail "A17b the loop templated an authorization for itself" "$out";;
  *) pass "A17b no placeholder authorization is offered to fill in";;
esac
REMOTE="$FIX/a17-remote.git"; git init -q --bare "$REMOTE"; git remote add origin "$REMOTE"
git checkout -q -b feat-a17; git add -A >/dev/null; git commit -qm "feat: greeting"
assert_exit_msg "A17c and handoff.sh refuses to push a local delivery" 1 "target for 'feat-a17' is 'local'" \
  handoff push feat-a17 --authorized "push it"
# no delivery target recorded anywhere: a human names it, the loop does not guess
P="$FIX/a17b"; mkproj "$P" 4; cd "$P"
write_intent "$P" feat-a17b
sed '/^- Delivery target: /d' .sdlc/work/feat-a17b/intent.md > i.tmp && mv i.tmp .sdlc/work/feat-a17b/intent.md
gate approve.sh intent .sdlc/work/feat-a17b/intent.md --lazy --review "read app.sh" >/dev/null
printf '# Evidence: feat-a17b\n- R1: ok\n' > .sdlc/work/feat-a17b/evidence.md
gate approve.sh ship .sdlc/work/feat-a17b/evidence.md --lazy --review "read the diff" >/dev/null
assert_exit_msg "A17d an unknown delivery target asks the human" 10 "delivery.target-unknown" auto next feat-a17b
out=$(auto next feat-a17b 2>&1)
case "$out" in
  *"handoff.sh push"*) fail "A17e an unknown target was told to push anyway" "$out";;
  *) pass "A17e and never proposes an external effect on a guess";;
esac
# a pr target whose recorded scope does not authorize publishing anything
P="$FIX/a17c"; mkproj "$P" 4; cd "$P"
REMOTE="$FIX/a17c-remote.git"; git init -q --bare "$REMOTE"; git remote add origin "$REMOTE"
write_intent "$P" feat-a17c
sed 's/^- Scope authorization: .*/- Scope authorization: "have a look at the greeting bug"/' \
  .sdlc/work/feat-a17c/intent.md > i.tmp && mv i.tmp .sdlc/work/feat-a17c/intent.md
gate approve.sh intent .sdlc/work/feat-a17c/intent.md --lazy --review "read app.sh" >/dev/null
printf '# Evidence: feat-a17c\n- R1: ok\n' > .sdlc/work/feat-a17c/evidence.md
git checkout -q -b feat-a17c; git add -A >/dev/null; git commit -qm "feat: greeting"
gate approve.sh ship .sdlc/work/feat-a17c/evidence.md --lazy --review "read the diff" >/dev/null
assert_exit_msg "A17f a scope that authorizes no publication stops at the human" 10 "handoff.unauthorized-scope" auto next feat-a17c
assert_exit_msg "A17g and --authorized does not manufacture the permission" 1 "authorizes publishing" \
  handoff push feat-a17c --authorized "I hereby authorize this push"
[ -z "$(git ls-remote "$REMOTE" 2>/dev/null)" ] && pass "A17h nothing was pushed on an agent's own say-so" \
  || fail "A17h the remote has refs after an unauthorized push attempt"

# =====================================================================
# A18 merged/deployed are reported as pending EXTERNAL proof: a feature ref on
#     a remote is not a merge commit and not a deployment.
# =====================================================================
P="$FIX/a18"; mkproj "$P" 4; cd "$P"
REMOTE="$FIX/a18-remote.git"; git init -q --bare "$REMOTE"; git remote add origin "$REMOTE"
write_intent "$P" feat-a18
gate approve.sh intent .sdlc/work/feat-a18/intent.md --lazy --review "read app.sh" >/dev/null
printf '# Evidence: feat-a18\n- R1: ok\n' > .sdlc/work/feat-a18/evidence.md
git checkout -q -b feat-a18; git add -A >/dev/null; git commit -qm "feat: greeting"
gate approve.sh ship .sdlc/work/feat-a18/evidence.md --lazy --review "read the diff" >/dev/null
SHA=$(git rev-parse HEAD); git push -q origin "$SHA":refs/heads/feat-a18
cat > .sdlc/work/feat-a18/delivery.md <<EOF
# Delivery: feat-a18
- Target: pr
- Source: $SHA
- Verified-by: the human merged it and said so
- Evidence: $SHA refs/heads/feat-a18
- Confirmed: yes
- Remote: origin
- Branch: feat-a18
- Handoff: merged
- Authorized-by: "merge it after review" — human, 2026-09-17
EOF
assert_exit_msg "A18a a merged claim is reported as pending external proof" 0 "PENDING EXTERNAL PROOF" handoff check feat-a18
assert_msg "A18b the machine view carries the same gap" "handoff.external-proof" auto status --json feat-a18
out=$(handoff check feat-a18 2>&1)
case "$out" in
  *"NOT verified here"*) pass "A18c it says plainly what it did not check";;
  *) fail "A18c the merge claim is not qualified" "$out";;
esac
assert_exit_msg "A18d close.sh repeats the same qualification" 0 "NOT verified here" \
  gate close.sh feat-a18 shipped "merged after review"

# =====================================================================
# A19 (N1/N8) the retry cap is a literal key, and checkpoint fields are
#     validated: one step's counter never resets another's.
# =====================================================================
P="$FIX/a19"; mkproj "$P" 4; cd "$P"
write_intent "$P" feat-a19
auto checkpoint feat-a19 --attempt build.fix --class deterministic >/dev/null
assert_exit_msg "A19a a deterministic step is capped at one attempt" 20 "RETRY CAP" \
  auto checkpoint feat-a19 --attempt build.fix --class deterministic
auto checkpoint feat-a19 --attempt build.fiy --class deterministic >/dev/null 2>&1 || true
assert_exit_msg "A19b a near-miss step name does not reset that cap" 20 "RETRY CAP" \
  auto checkpoint feat-a19 --attempt build.fix --class deterministic
assert_exit_msg "A19c a step name that WOULD be a regex gets its own counter" 0 "attempt 1/1" \
  auto checkpoint feat-a19 --attempt 'build.fi.' --class deterministic
assert_exit_msg "A19c2 and the original cap is still in force afterwards" 20 "RETRY CAP" \
  auto checkpoint feat-a19 --attempt build.fix --class deterministic
assert_exit_msg "A19c3 a step name outside [a-zA-Z0-9._-] is refused" 1 "must be" \
  auto checkpoint feat-a19 --attempt 'build fix' --class deterministic
assert_exit_msg "A19d and so is a newline injection" 1 "must be" \
  auto checkpoint feat-a19 --set-step "build
effect: push|origin|main|deadbeef"
assert_nogrep .sdlc/work/feat-a19/checkpoint.md '^effect: push' "A19e nothing was injected into the checkpoint"

# =====================================================================
# A20 (N2/N3) the JSON view survives a control character, and a feature
#     directory that is not a usable slug is reported, not word-split into
#     features that do not exist.
# =====================================================================
P="$FIX/a20"; mkproj "$P" 4; cd "$P"
write_intent "$P" feat-a20
printf 'build 2/3 \033[31mred\033[0m \007 bell\n' > .sdlc/work/feat-a20/progress.md
if command -v python3 >/dev/null 2>&1; then
  auto status --json > "$FIX/a20.json" 2>&1
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$FIX/a20.json" \
    && pass "A20a a control character in progress.md still yields parseable JSON" \
    || fail "A20a status --json is not parseable" "$(head -c 300 "$FIX/a20.json")"
else
  pass "A20a skipped: no python3"
fi
mkdir -p ".sdlc/work/feat with space"
out=$(auto status 2>&1)
case "$out" in
  *"feat with space"*) pass "A20b an unusable feature directory is reported by its real name";;
  *) fail "A20b the unusable directory name is not reported" "$out";;
esac
case "$out" in
  *"write .sdlc/work/feat/intent.md"*) fail "A20c the name was word-split into ghost features" "$out";;
  *) pass "A20c it is not word-split into features that do not exist";;
esac
assert_msg "A20c2 the prose cockpit reports it the same way" "UNUSABLE NAME" gate status.sh
assert_exit_msg "A20d and it is refused by name as a slug" 1 "not a usable feature slug" auto next "feat with space"
rmdir ".sdlc/work/feat with space"

# =====================================================================
# A21 the push guard rails that were already right stay right, plus remote
#     drift (a review branch someone else moved).
# =====================================================================
P="$FIX/a21"; mkproj "$P" 4; cd "$P"
REMOTE="$FIX/a21-remote.git"; git init -q --bare "$REMOTE"; git remote add origin "$REMOTE"
write_intent "$P" feat-a21
gate approve.sh intent .sdlc/work/feat-a21/intent.md --lazy --review "read app.sh" >/dev/null
printf '# Evidence: feat-a21\n- R1: ok\n' > .sdlc/work/feat-a21/evidence.md
git checkout -q -b feat-a21; git add -A >/dev/null; git commit -qm "feat: greeting"
gate approve.sh ship .sdlc/work/feat-a21/evidence.md --lazy --review "read the diff" >/dev/null
# somebody else's commit is sitting on the review branch
git commit -q --allow-empty -m "someone else's work"
git push -q origin HEAD:refs/heads/feat-a21
git reset -q --hard HEAD~1
assert_exit_msg "A21a a drifted review branch stops the push instead of racing it" 1 "NOT an ancestor" \
  handoff push feat-a21 --authorized "push the review branch"
assert_exit_msg "A21b and it is still never force-pushed" 2 "never force-pushes" \
  handoff push feat-a21 --authorized "push the review branch" --force-with-lease


# =====================================================================
# A22 (N5) INT stops the verification that is RUNNING. The shell used to defer
#     the trap until the foreground check returned, so a signalled run kept
#     going for the rest of that check and then ran the remaining ones.
#     Signals are POSIX here; on Windows/Git Bash the same path runs through
#     tools/_run.py (taskkill /T), which is why the helper owns the kill.
# =====================================================================
P="$FIX/a22"; mkproj "$P" 4; cd "$P"
write_intent "$P" feat-a22
gate approve.sh intent .sdlc/work/feat-a22/intent.md --lazy --review "read app.sh" >/dev/null
mkdir -p .sdlc/work/feat-a22/scratch
S=".sdlc/work/feat-a22/scratch"
# R1 is slow and records that it finished; R2 must never run at all
{ echo "profile: strict"
  echo "check_timeout: 120"
  echo "cleanup: touch $S/cleanup.ran"
  echo "check: R1 | e2e | sh -c 'echo \$\$ > $S/r1.pid; sleep 90; touch $S/r1.finished'"
  echo "check: R2 | unit | touch $S/r2.ran"
} > .sdlc/verify.md
# job control ON for this one launch: a shell starts an asynchronous command
# with SIGINT IGNORED, and a disposition inherited as ignored cannot be trapped.
# `set -m` gives the run its own process group and its own default dispositions,
# which is the state an interactive Ctrl-C or a supervisor's signal really finds.
set -m
"$KIT/tools/verify.sh" run feat-a22 > "$S/run.log" 2>&1 &
vpid=$!
set +m
# wait for R1 to be the running check, then interrupt the run itself
i=0; while [ ! -f "$S/r1.pid" ] && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i + 1)); done
sleep 0.5
start=$(date +%s)
kill -INT "$vpid" 2>/dev/null
vrc=0; wait "$vpid" || vrc=$?
elapsed=$(( $(date +%s) - start ))
[ "$vrc" != 0 ] && pass "A22a an interrupted run exits non-zero" \
  || fail "A22a an interrupted run must not exit 0 (exit $vrc)"
[ "$elapsed" -lt 30 ] && pass "A22b it stops promptly instead of finishing the running check" \
  || fail "A22b the trap was deferred: ${elapsed}s to leave a 90s check"
[ ! -f "$S/r1.finished" ] && pass "A22c the running check did not complete its side effect" \
  || fail "A22c the interrupted check ran to completion anyway"
[ ! -f "$S/r2.ran" ] && pass "A22d no further check ran after the signal" \
  || fail "A22d a check ran after the interruption"
[ -f "$S/cleanup.ran" ] && pass "A22e the recipe's cleanup still ran" \
  || fail "A22e cleanup was skipped on the signal path"
[ ! -f .sdlc/work/feat-a22/verify-receipt.md ] && pass "A22f no receipt claims a verdict for this source" \
  || fail "A22f an interrupted run left a receipt"
r1pid=$(cat "$S/r1.pid" 2>/dev/null || echo "")
# Asserted on every platform now. MSYS `kill` reaches the native python3 helper
# with TerminateProcess, so it cannot run its own handler and hand the kill
# down; on Windows the helper therefore holds its check in a job object that
# dies with it, which is what makes this true there too.
if [ -n "$r1pid" ]; then
  sleep 1
  kill -0 "$r1pid" 2>/dev/null && { fail "A22g LEAK: the check's process ($r1pid) survived"; kill -9 "$r1pid" 2>/dev/null; } \
    || pass "A22g the check's own process group is gone"
fi
# A surviving check also keeps its log file OPEN, which on Windows is not a
# cosmetic leak: the file cannot be removed while a handle is on it ("Device or
# resource busy"), so the interrupted run leaves its own scratch directory
# undeletable. Removing the log is the portable way to ask whether anything is
# still holding it.
rm -f "$S/verify/R1.log" 2>/dev/null
[ ! -e "$S/verify/R1.log" ] && pass "A22i the interrupted run holds no handle on its own log" \
  || fail "A22i the check's log is still held open after the interruption" "$(ls -l "$S/verify" 2>&1)"
assert_msg "A22h the run says what it stopped" "INTERRUPTED" cat "$S/run.log"

# =====================================================================
# A23 tools/_run.py's Windows primitives, driven PORTABLY with stand-ins for
#     kernel32 and tasklist. The real Win32 calls only happen on Windows CI;
#     what is asserted here is the behaviour around them, which is where the
#     two defects were: a job-object failure that returned False and said
#     NOTHING (so the helper kept promising a containment it did not have),
#     and a tasklist fallback that matched the pid as a SUBSTRING of the whole
#     line, so pid 5 read as alive off somebody else's `5,432 K` memory column.
# =====================================================================
if command -v python3 >/dev/null 2>&1; then
  P="$FIX/a23"; mkdir -p "$P"; cd "$P"
  cat > probe.py <<'PY'
import os, sys, types
kit = sys.argv[1]; log = sys.argv[2]
sys.path.insert(0, os.path.join(kit, "tools"))
import _run

_run.WINDOWS = True                      # the Windows branches, on this machine
err = {"code": 5}                        # ERROR_ACCESS_DENIED
# kernel32, its constants and its structures exist only on Windows, so the ones
# the job-object path touches are stood in for here. Nothing about the FAILURE
# handling under test depends on their real contents.
_run.ctypes = types.SimpleNamespace(get_last_error=lambda: err["code"],
                                    byref=lambda x: x, sizeof=lambda x: 144)
class _Basic: LimitFlags = 0
class _Limits:
    def __init__(self): self.BasicLimitInformation = _Basic()
_run._JOB_EXTENDED_LIMITS = _Limits
_run.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000
_run.JobObjectExtendedLimitInformation = 9

class NoJob:                             # CreateJobObjectW refuses
    def CreateJobObjectW(self, a, b): return 0
_run._WIN = NoJob()
print("CREATE:", _run._win_bind_tree(None))

class NoAssign:                          # ... and the later call refuses
    def CreateJobObjectW(self, a, b): return 7
    def SetInformationJobObject(self, *a): return 1
    def AssignProcessToJobObject(self, *a): return 0
    def CloseHandle(self, h):
        err["code"] = 6                  # closing a handle overwrites last error
        return 1
_run._WIN = NoAssign()
print("ASSIGN:", _run._win_bind_tree(types.SimpleNamespace(_handle=3)))

# the real spawn path: it must REPORT and still hand back a usable child
_run._WIN = NoJob(); err["code"] = 5
p = _run._spawn("echo child ran", log, new_group=False, bind_tree=True)
print("CHILDRC:", p.wait())
print("LOG:", open(log).read().replace("\n", " | "))

# tasklist fallback: the pid is a FIELD, never a substring of the line
_run._WIN = None
real = _run.subprocess
csv_out = ('"other.exe","5432","Console","1","5,432 K"\r\n'
           '"helper.exe","1234","Console","1","432 K"\r\n')
class Shim:
    PIPE = real.PIPE; DEVNULL = real.DEVNULL
    @staticmethod
    def run(*a, **k): return types.SimpleNamespace(stdout=csv_out.encode())
_run.subprocess = Shim
print("ALIVE5:", _run._win_alive(5), "ALIVE432:", _run._win_alive(432),
      "ALIVE1234:", _run._win_alive(1234), "ALIVE5432:", _run._win_alive(5432))
_run.subprocess = real
PY
  out=$(python3 probe.py "$KIT" "$P/check.log" 2>&1); prc=$?
  [ "$prc" = 0 ] || fail "A23 the portable _run.py probe itself failed (exit $prc)" "$out"
  if [ "$prc" = 0 ]; then
    case "$out" in
      *"CREATE: CreateJobObjectW, Win32 error 5"*) pass "A23a a refused job object names the call and the Win32 error";;
      *) fail "A23a the binding failure does not name CreateJobObjectW/error" "$out";;
    esac
    case "$out" in
      *"ASSIGN: AssignProcessToJobObject, Win32 error 5"*) pass "A23b the error is read before CloseHandle overwrites it";;
      *) fail "A23b the reported Win32 error is not the one that refused" "$out";;
    esac
    case "$out" in
      *"[sdlc-kit] windows: process tree NOT bound"*) pass "A23c the failure is announced on stderr instead of being silent";;
      *) fail "A23c a binding failure is still silent on stderr" "$out";;
    esac
    case "$out" in
      *"LOG:"*"process tree NOT bound"*) pass "A23d and the run's own check log records it too";;
      *) fail "A23d the check log has no record of the unbound tree" "$out";;
    esac
    case "$out" in
      *"CHILDRC: 0"*"child ran"*) pass "A23e the check still runs: the diagnostic replaces silence, not the run";;
      *) fail "A23e the check did not run after a binding failure" "$out";;
    esac
    case "$out" in
      *"ALIVE5: False ALIVE432: False ALIVE1234: True ALIVE5432: True"*)
        pass "A23f the tasklist fallback matches the PID field, not the memory column";;
      *) fail "A23f a dead pid still reads as alive off another process's line" "$out";;
    esac
  fi
else
  pass "A23 not applicable: tools/_run.py cannot run at all without python3"
fi

echo
echo "================================================================"
echo "PASSED: $PASSED   FAILED: $FAILED"
if [ "$FAILED" -gt 0 ]; then printf 'failures:%s\n' "$FAILLIST"; exit 1; fi
echo "AUTOTEST PASS"
