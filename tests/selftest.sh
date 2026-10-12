#!/usr/bin/env bash
set -eu
KIT=$(cd "$(dirname "$0")/.." && pwd)
SDLC=$KIT/sdlc.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
COUNT=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { COUNT=$((COUNT + 1)); printf 'ok: %s\n' "$*"; }
# CI must run every symlink check; elsewhere an OS without symlinks skips them.
skip() { [ -z "${CI:-}" ] || fail "symlink check skipped on CI: $*"; printf 'skip: %s\n' "$*"; }
contains() { case "$OUTPUT" in *"$1"*) ;; *) fail "missing '$1' in: $OUTPUT" ;; esac; }
expect() {
  expected=$1; shift
  actual=0
  bash "$SDLC" "$@" > "$TMP/stdout" 2> "$TMP/stderr" || actual=$?
  OUTPUT=$(cat "$TMP/stdout" "$TMP/stderr")
  [ "$actual" -eq "$expected" ] || fail "$* exited $actual, expected $expected: $OUTPUT"
}
assert_file() { [ -f "$1" ] || fail "missing file: $1"; }
state() { awk -F ': ' -v key="$1" '$1==key {print substr($0,index($0,": ")+2)}' "$F/.state"; }
repo() {
  local dir
  dir=$TMP/$1
  mkdir -p "$dir"
  cd "$dir"
  git -c init.defaultBranch=main init -q
  git config user.name 'sdlc selftest'
  git config user.email selftest@sdlc.invalid
  git config init.defaultBranch main
  git config core.autocrlf false
  printf 'baseline\n' > README
  git add README
  git commit -qm baseline
  expect 0 init
  [ -z "$(git status --porcelain)" ] || fail 'init changed the working tree'
  SHA=$(git rev-parse HEAD)
}
intent() {
  cat > "$F/intent.md" <<'DOC'
# Intent
## Understood as
- O1: The operator observes the requested behavior.
## Blocking questions
- none
## Delivery
- Target: local
- Authorized: no
DOC
}
plan() {
  local i must covers
  N=$1
  cat > "$F/PLAN.md" <<'DOC'
# Plan
- Risk flags: migration no · data deletion no · public API no · security no · infra no
## Scenarios
| ID | Persona | Steps | Expected | Must | Covers |
|---|---|---|---|---|---|
DOC
  i=1
  while [ "$i" -le "$N" ]; do
    must=no; covers=
    if [ "$i" -eq 1 ]; then must=yes; covers=O1; fi
    printf '| S%s | operator | run real CLI | observable output | %s | %s |\n' "$i" "$must" "$covers" >> "$F/PLAN.md"
    i=$((i + 1))
  done
}
feature() {
  SLUG=$1
  expect 0 new "$SLUG"
  F=$PWD/.sdlc/work/$SLUG
  intent
}
reviewed() { printf 'VERDICT: %s\n' "$2" >> "$F/review.md"; expect 0 review "$@"; }

ready() {
  feature "$1"
  expect 0 approve intent "$SLUG" --human 'approved scope'
  plan "$2"
  expect 0 approve plan "$SLUG" --agent 'scenarios and risks reviewed'
  reviewed "$SLUG" pass 'independent review passed'
}
evidence() {
  local i result cause override id rest
  E=$F/evidence.md
  printf '# Evidence\n- Commit: %s\n## Results\n| ID | Result | Cause | Observed | Log |\n|---|---|---|---|---|\n' "$SHA" > "$E"
  i=1
  while [ "$i" -le "$N" ]; do
    result=PASS; cause=
    for override in "$@"; do
      id=${override%%:*}; rest=${override#*:}
      if [ "$id" = "S$i" ]; then result=${rest%%:*}; cause=${rest#*:}; fi
    done
    printf 'real observed output S%s\n' "$i" > "$F/logs/S$i.txt"
    printf '| S%s | %s | %s | observed S%s | logs/S%s.txt |\n' "$i" "$result" "$cause" "$i" "$i" >> "$E"
    i=$((i + 1))
  done
}
delivery() {
  cat >> "$E" <<DOC
## Delivery
- Target: ${1:-local}
- Delivered: ${2:-$SHA}
- Checked with: git rev-parse HEAD
- Output: $SHA
- Authorized: ${3:-no}
DOC
}
replace() { awk "$1" "$2" > "$TMP/rewrite"; mv "$TMP/rewrite" "$2"; }
route() { expect 0 score "$SLUG"; contains "ROUTE $1"; }

regression_stop() {
  repo regression-stop
  ready review-stop 2
  for i in 1 2 3; do reviewed "$SLUG" fail "finding $i"; done
  printf '\nagent escape\n' >> "$F/PLAN.md"
  expect 1 approve plan "$SLUG" --agent 'edited plan to reset cap'
  contains 'stopped for the human'
  expect 1 check plan "$SLUG"; contains 'resume with approve plan --human'
  cp "$F/intent.md" "$TMP/stop-intent"
  rm "$F/intent.md"
  expect 1 approve plan "$SLUG" --agent 'missing intent stop bypass'; contains 'stopped for the human'
  mv "$TMP/stop-intent" "$F/intent.md"
  expect 10 next "$SLUG"; contains 'NEEDS-HUMAN'; contains '3 review FAILs'
  expect 0 status "$SLUG"; contains 'NEEDS-HUMAN'
  expect 1 review "$SLUG" pass bypass
  expect 1 score "$SLUG"
  expect 1 close "$SLUG" shipped bypass
  before=$(state entry)
  expect 0 approve plan "$SLUG" --human 'resume after review stop'
  [ "$(state entry)" -eq "$((before+1))" ] && [ "$(state fails)" -eq 0 ] && [ -z "$(state review)" ] || fail 'review stop resume state'
  ok 'regression 1: edited PLAN cannot escape three review FAILs; human resumes'
  ready cap-stop 19
  for i in 2 3 4 5; do
    evidence "S$i:FAIL:code"
    if [ "$i" -lt 5 ]; then route build; reviewed "$SLUG" pass fixed; else route human; fi
  done
  printf '\nagent cap escape\n' >> "$F/PLAN.md"
  expect 1 approve plan "$SLUG" --agent 'edited cap plan'
  contains 'stopped for the human'; contains 'cap: 3 returns to build'
  evidence
  expect 10 next "$SLUG"; contains 'cap: 3 returns to build'
  before=$(state entry)
  expect 0 approve plan "$SLUG" --human 'resume after cap'
  [ "$(state returns_build)" -eq 3 ] && [ "$(state entry)" -eq "$((before+1))" ] || fail 'human resume reset return cap'
  ok 'regression 1: cap human route persists across plan and evidence edits'
  ready unchanged-stop 2
  evidence S1:BLOCKED:; route human
  before=$(state entry)
  expect 0 approve plan "$SLUG" --human 'resume unchanged artifacts'
  [ "$(state entry)" -eq "$((before+1))" ] || fail 'unchanged human resume did not open new entry'
  expect 0 check plan "$SLUG"
  ok 'human can resume a stopped feature with unchanged plan and intent'
  ready pending-plan 1
  evidence S1:FAIL:plan; route plan
  expect 1 check plan "$SLUG"; contains 'GATE CLOSED: Evidence routed to plan: update PLAN.md and approve plan'
  expect 1 review "$SLUG" pass bypass; contains 'Evidence routed to plan'
  expect 1 score "$SLUG"; contains 'Evidence routed to plan'
  expect 1 approve plan "$SLUG" --agent unchanged
  expect 0 approve plan "$SLUG" --human 'override unchanged plan route'
  expect 0 check plan "$SLUG"
  ok 'pending plan route closes the common plan gate; human unchanged override opens it'
}
regression_scenarios() {
  repo regression-scenarios
  ready history 3
  replace '/\| S3 \|/ {$0="| S3 | operator | CLI | output | yes | O1 |"} {print}' "$F/PLAN.md"
  expect 0 approve plan "$SLUG" --agent 'add must scenario'
  reviewed "$SLUG" pass reviewed
  evidence; route deliver
  replace '!/\| S2 \|/ {gsub(/yes \| O1/,"no | O1");if($0~/\| S1 \|/)gsub(/no \| O1/,"yes | O1");print}' "$F/PLAN.md"
  expect 1 approve plan "$SLUG" --agent 'remove scenario and drop must'
  contains 'S2 removed'; contains 'S3 no longer must'
  expect 0 approve plan "$SLUG" --human 'approved smaller scope'
  case "$(state plan)" in *'approved smaller scope (removed: S2; must dropped: S3)'*) :;; *) fail 'human override note missing';; esac
  [ "$(state scored)" = 'S1 S3' ] || fail 'removed scenario not deleted from scored history'
  reviewed "$SLUG" pass reviewed
  evidence
  replace '!/\| S2 \|/ {print}' "$E"
  route deliver
  ok 'regression 3: agent cannot remove scenarios or drop must; human note and scored removal recorded'
  ready qa-history 1
  evidence
  printf 'QA output\n' > "$F/logs/S9.txt"
  printf '| S9 | PASS | | extra QA scenario | logs/S9.txt |\n' >> "$E"
  route deliver
  evidence
  expect 1 score "$SLUG"; contains 'evidence.md is missing S9: scenarios are never removed'
  expect 0 next "$SLUG"; contains 'evidence.md is missing S9: scenarios are never removed'
  expect 0 status "$SLUG"; contains 'evidence.md is missing S9: scenarios are never removed'
  printf '| S9 | PASS | | restored QA scenario | logs/S9.txt |\n' >> "$E"
  route deliver
  [ "$(state scored)" = 'S1 S9' ] || fail 'QA-added ID missing from scored union'
  ok 'scored QA-added scenarios cannot disappear from evidence; next and status agree'
}
regression_delivery() {
  repo regression-delivery
  ready target-authority 1
  replace '/Target:/ {$0="- Target: pr"} /Authorized:/ {$0="- Authorized: **YES** — push approved"} {print}' "$F/intent.md"
  expect 0 approve intent "$SLUG" --human 'approved pr'
  expect 0 approve plan "$SLUG" --agent reviewed
  reviewed "$SLUG" pass reviewed
  evidence; delivery deploy; route deliver
  expect 10 next "$SLUG"; contains 'authorize deploy'
  expect 1 close "$SLUG" shipped 'escalate PR to deploy'; contains 'authorize deploy'
  ok 'regression 4: PR intent authority cannot authorize deploy evidence'
  evidence; delivery pr; route deliver
  expect 0 next "$SLUG"; contains 'READY deliver'
  printf '\nchanged after delivery route\n' >> "$F/intent.md"
  expect 1 close "$SLUG" shipped 'ship edited intent'; contains 'intent.md changed after approval'
  ok 'shipped close requires unchanged approved intent and plan'
  ready nope-authority 1
  evidence; delivery pr "$SHA" nope; route deliver
  expect 10 next "$SLUG"; contains 'authorize pr'
  expect 1 close "$SLUG" shipped nope; contains 'authorize pr'
  for auth in yesterday yesman 'not yes' ''; do
    evidence; delivery pr "$SHA" "$auth"; expect 10 next "$SLUG"; contains 'authorize pr'
  done
  evidence; delivery deploy "$SHA" 'Yes — deploy approved'
  expect 0 next "$SLUG"; contains 'READY deliver'
  ok 'only Authorized starting with word yes grants authority; evidence can approve a changed target'
}
regression_review() {
  repo regression-review
  ready binding 1
  rm "$F/review.md"
  expect 1 review "$SLUG" pass missing; contains 'review.md has no VERDICT line'
  printf 'No verdict yet\n' > "$F/review.md"
  expect 1 review "$SLUG" pass missing; contains 'review.md has no VERDICT line'
  printf 'VERDICT: PASS\n**VERDICT:** `fail`\r\n' > "$F/review.md"
  expect 1 review "$SLUG" pass mismatch; contains "review.md's last VERDICT is FAIL"
  expect 0 review "$SLUG" fail matched
  printf 'VERDICT: FAIL\n**VeRdIcT:** `PaSs` — no blocking findings\n<!-- VERDICT: FAIL -->\n' >> "$F/review.md"
  expect 1 review "$SLUG" fail mismatch; contains "review.md's last VERDICT is PASS"
  expect 0 review "$SLUG" pass matched
  [ "$(state rounds)" -eq 4 ] || fail 'review rounds count includes HTML comments or loses prior rounds'
  case "$(state review)" in *" $SHA "*) :;; *) fail 'review did not record HEAD';; esac
  printf 'committed after review\n' >> README
  git add README
  git commit -qm 'change after review'
  SHA=$(git rev-parse HEAD)
  evidence
  expect 1 score "$SLUG"; contains "Commit $SHA is not the reviewed commit"; contains 'commit, then review again'
  reviewed "$SLUG" pass 'review committed change'
  evidence; route deliver
  for alias in . ./ nested/..; do
    mkdir -p nested
    evidence
    replace '/Commit:/ {$0=$0" '"$alias"'"} {print}' "$E"
    route deliver
  done
  ok 'regression 5: review artifact last verdict and project Commit bind to reviewed HEAD'
  cd "$TMP"
  mkdir nonrepo
  cd nonrepo
  expect 0 init
  ready no-git 1
  case "$(state review)" in *' - '*) :;; *) fail 'non-repo review needs dash SHA';; esac
  git -c init.defaultBranch=main init -q
  git config user.name 'sdlc selftest'
  git config user.email selftest@sdlc.invalid
  ready unborn 1
  case "$(state review)" in *' - '*) :;; *) fail 'unborn repo review needs dash SHA';; esac
  ok 'review outside a repo or before its first commit records dash'
}
regression_other() {
  repo regression-other
  contains 'Initialized'
  ready pipes 1
  replace '/\| S1 \|/ {$0="| S1 | operator | run CLI \\| inspect output | expected \\| output | yes | O1 |"} {print}' "$F/PLAN.md"
  expect 0 approve plan "$SLUG" --agent 'escaped pipes preserve must and covers'
  reviewed "$SLUG" pass reviewed
  evidence
  printf 'literal pipe log\n' > "$F/logs/pipe|output.txt"
  replace '/\| S1 \|/ {$0="| S1 | PASS | | left \\| right | logs/pipe\\|output.txt |"} {print}' "$E"
  route deliver
  ok 'escaped table pipes in Steps, Expected, Observed and Log preserve columns and literal filename'
  printf 'untracked\n' > surprise
  expect 1 score "$SLUG"; contains 'dirty tree'; contains 'surprise'
  rm surprise
  printf 'ignored\n' > ignored
  printf 'ignored\n' >> .git/info/exclude
  route deliver
  ok 'untracked source counts as dirty; ignored files and store do not'
  ready build-names 19
  evidence S2:FAIL:code S5:FAIL:code
  route build; contains 'return 1/3: S2 S5'
  expect 0 next "$SLUG"; contains 'READY build: fix S2 S5 (return 1/3), commit, review'
  ok 'build route and next name every code-FAIL scenario'
  mkdir -p .sdlc/archive/archived-v0
  expect 30 next archived-v0; contains 'DONE'
  expect 0 status archived-v0; contains 'DONE'
  expect 1 close archived-v0 dropped archived; contains 'archived'
  ok 'archived feature without state is DONE and cannot close again'
  feature plan-validity
  expect 0 approve intent "$SLUG" --human approved
  plan 1
  while [ "$(wc -l < "$F/PLAN.md")" -lt 151 ]; do printf '\n' >> "$F/PLAN.md"; done
  expect 1 approve plan "$SLUG" --agent invalid; contains 'PLAN.md has 151 lines; keep it to 150 and move detail into refs/'
  for placeholder in '<three lines for the human: summary>' '<file or symbol>' '<another reader or writer>' '<…>' '## Understanding <…>'; do
    plan 1
    printf '%s\n' "$placeholder" >> "$F/PLAN.md"
    expect 1 approve plan "$SLUG" --human invalid; contains 'template placeholder'
  done
  plan 1
  replace '/Risk flags:/ {$0="- Risk flags: migration no · security yes, auth changes; secrets reviewed · infra no"} {print}' "$F/PLAN.md"
  expect 1 approve plan "$SLUG" --agent flags; contains 'security yes, auth changes; secrets reviewed'
  expect 10 next "$SLUG"; contains 'security yes, auth changes; secrets reviewed'
  ok 'PLAN length/placeholders rejected and raised risk segment shown in full'
  rm "$F/intent.md"
  expect 0 next "$SLUG"; contains 'intent.md missing'
  intent
  expect 0 approve intent "$SLUG" --human approved
  rm "$F/PLAN.md"
  expect 0 next "$SLUG"; contains 'PLAN.md missing'
  ok 'missing artifacts are explicit parser problems'
  mkdir -p subfolder
  cd subfolder
  exclude=$(git rev-parse --git-path info/exclude)
  expect 0 init; contains "Ignored .sdlc/ in $exclude (this clone only; no tracked file changed)."
  [ "$(awk '$0=="/subfolder/.sdlc" {n++} END {print n+0}' "$exclude")" -eq 1 ] || fail 'nested exclude entry'
  [ ! -e .gitignore ] && [ -z "$(git status --porcelain)" ] || fail 'nested init changed the working tree'
  replace '$0!="/subfolder/.sdlc" {print}' "$exclude"
  SHA=$(git rev-parse HEAD)
  ready subfolder-root 1
  evidence
  replace '/Commit:/ {$0=$0" .."} {print}' "$E"
  route deliver
  printf 'parent untracked\n' > ../parent-surprise
  expect 1 score "$SLUG"; contains 'parent-surprise'
  rm ../parent-surprise
  route deliver
  ok 'unignored subfolder ROOT store excluded for parent repo; other untracked files count'
  mv .sdlc "$TMP/external-nested-store"
  if ln -s "$TMP/external-nested-store" .sdlc 2>/dev/null && [ -L .sdlc ]; then
    route deliver
    ok 'unignored external symlink store excluded from parent repo with canonical paths'
  else
    mv "$TMP/external-nested-store" .sdlc
    skip 'external nested symlink unavailable on this OS'
  fi
}
regression_init() {
  mkdir -p "$TMP/preignored"
  cd "$TMP/preignored"
  git -c init.defaultBranch=main init -q
  git config user.name 'sdlc selftest'
  git config user.email selftest@sdlc.invalid
  printf '.sdlc/\n' > .gitignore
  git add .gitignore
  git commit -qm 'existing project ignore'
  exclude=$(git rev-parse --git-path info/exclude)
  cp "$exclude" "$TMP/exclude.before"
  cp .gitignore "$TMP/gitignore.before"
  expect 0 init
  expect 0 init
  cmp "$exclude" "$TMP/exclude.before" || fail 'preignored init appended an exclude entry'
  cmp .gitignore "$TMP/gitignore.before" || fail 'preignored init changed .gitignore'
  [ -z "$(git status --porcelain)" ] || fail 'preignored init changed the working tree'
  ok 'init preserves existing .gitignore and appends nothing when .sdlc is already ignored'
  mkdir -p "$TMP/globby/a[1] b"
  cd "$TMP/globby"
  git -c init.defaultBranch=main init -q
  cd 'a[1] b'
  expect 0 init; contains 'Ignored .sdlc/ in'
  [ -z "$(git status --porcelain)" ] || fail 'store in a glob-named subfolder is not ignored'
  ok 'init escapes glob characters in the subfolder path'
}
regression_round3() {
  mkdir -p "$TMP/plain-root/a" "$TMP/plain-root/b"
  cd "$TMP/plain-root"
  for name in a b; do
    git -C "$name" -c init.defaultBranch=main init -q
    git -C "$name" config user.name 'sdlc selftest'
    git -C "$name" config user.email selftest@sdlc.invalid
    printf '%s\n' "$name" > "$name/file"
    git -C "$name" add file
    git -C "$name" commit -qm base
  done
  expect 0 init
  SHA=$(git -C a rev-parse HEAD); SHA_B=$(git -C b rev-parse HEAD)
  ready plain 1
  evidence
  replace '/Commit:/ {print "- Commit: '"$SHA"' a"; print "- Commit: '"$SHA_B"' b"; next} {print}' "$E"
  route deliver
  ok 'project root outside git: multi-repo evidence scores (no silent exit)'
  repo regression-round3
  ready withdrawn 3
  evidence; route deliver
  replace '!/\| S2 \|/ {print}' "$F/PLAN.md"
  expect 0 approve plan "$SLUG" --human 'drop S2'
  [ "$(state withdrawn)" = S2 ] || fail 'human removal not recorded as withdrawn'
  reviewed "$SLUG" pass reviewed
  evidence
  expect 1 score "$SLUG"; contains 'S2 was removed by the human: delete its row'
  printf '| S2 | operator | run real CLI | observable output | no | |\n' >> "$F/PLAN.md"
  expect 0 approve plan "$SLUG" --agent 're-plan S2'
  [ -z "$(state withdrawn)" ] || fail 're-planned scenario still withdrawn'
  reviewed "$SLUG" pass reviewed
  evidence; route deliver
  ok 'a human-removed scenario cannot return through evidence; re-planning it clears the guard'
  printf 'VERDICT: PASS | FAIL\n' >> "$F/review.md"
  expect 1 review "$SLUG" pass 'template line'; contains "review.md's last VERDICT is UNDECIDED"
  ok 'a copied PASS | FAIL template line is not a verdict'
}
regression_round2() {
  repo "regression-round2-$1"
  case "$1" in
    a)
      ready repeated-review 1
      cp "$F/.state" "$TMP/rounds.before"
      expect 1 review "$SLUG" pass 'reuse recorded review'; contains 'no new round'
      cmp "$F/.state" "$TMP/rounds.before" || fail 'refused repeated review changed state'
      [ "$(state rounds)" -eq 1 ] || fail 'first review round not recorded'
      reviewed "$SLUG" pass 'new appended round'
      [ "$(state rounds)" -eq 2 ] || fail 'appended review round not recorded'
      ok 'round 2 (a): a recorded review cannot be reused; an appended round succeeds'
      ;;
    b)
      feature plan-review
      expect 0 approve intent "$SLUG" --human 'approved scope'
      plan 1
      printf 'VERDICT: PASS\n' > "$F/review.md"
      expect 0 approve plan "$SLUG" --agent 'plan gap check passed'
      expect 1 review "$SLUG" pass 'reuse plan gap check'; contains 'no new round'
      [ "$(state rounds)" -eq 1 ] || fail 'plan approval did not consume existing review rounds'
      expect 0 next "$SLUG"; contains 'implement PLAN.md, commit any change, review'
      reviewed "$SLUG" pass 'new build review'
      [ "$(state rounds)" -eq 2 ] || fail 'build review did not record the appended round'
      ok 'round 2 (b): plan approval consumes its gap-check PASS; build requires a new round'
      ;;
    c)
      ready subfolder-commit 1
      reviewed_sha=$SHA
      mkdir src
      printf 'new committed source\n' > src/change
      git add src/change
      git commit -qm 'change after review'
      SHA=$(git rev-parse HEAD)
      evidence
      replace '/Commit:/ {$0=$0" src"} {print}' "$E"
      expect 1 score "$SLUG"; contains "Commit $SHA is not the reviewed commit $reviewed_sha"
      reviewed "$SLUG" pass 'review new source commit'
      route deliver
      ok 'round 2 (c): a project subfolder Commit binds to the reviewed SHA'
      ;;
    d)
      ready stale-deliver 1
      evidence
      printf 'additional QA check passed\n' > "$F/logs/S2.txt"
      printf '| S2 | PASS | | additional QA check | logs/S2.txt |\n' >> "$E"
      delivery; route deliver
      printf '| S2 | operator | additional CLI check | observable output | no | |\n' >> "$F/PLAN.md"
      expect 0 approve plan "$SLUG" --agent 'additional non-must scenario'
      expect 1 close "$SLUG" shipped 'reuse previous build route'; contains 'current evidence and build need a deliver route'
      reviewed "$SLUG" pass 'review updated plan build'
      N=2; evidence; delivery; route deliver
      expect 0 close "$SLUG" shipped 'current build routed to deliver'
      ok 'round 2 (d): shipped close requires a deliver route for the current build'
      ;;
    e)
      ready qa-action 1
      expect 0 next "$SLUG"; contains 'run QA on S1, fill evidence.md, sdlc.sh score'
      evidence
      printf 'QA-added failure\n' > "$F/logs/S9.txt"
      printf '| S9 | FAIL | code | QA-added failure | logs/S9.txt |\n' >> "$E"
      route build
      reviewed "$SLUG" pass 'QA-added failure fixed'
      evidence
      printf '| S9 | PASS | | QA-added check now passes | logs/S9.txt |\n' >> "$E"
      expect 0 next "$SLUG"; contains 'run QA on S1 S9, fill evidence.md, sdlc.sh score'
      plan 2
      expect 0 approve plan "$SLUG" --agent 'add planned scenario'
      reviewed "$SLUG" pass 'review expanded build'
      evidence
      printf '| S9 | PASS | | QA-added check still passes | logs/S9.txt |\n' >> "$E"
      expect 0 next "$SLUG"; contains 'run QA on S1 S2 S9, fill evidence.md, sdlc.sh score'
      route deliver
      ok 'round 2 (e): QA action lists planned then scored IDs once, including S9 after a build return'
      ;;
    *) fail "unknown round 2 regression: $1";;
  esac
}
regression_ultra() {
  repo regression-ultra
  feature inline-question
  replace '/^- none$/ {print "- Can we drop the legacy column? <!-- waiting on the DBA -->"; next} {print}' "$F/intent.md"
  expect 1 approve intent "$SLUG" --human 'question open'; contains 'drop the legacy column'
  expect 10 next "$SLUG"; contains 'drop the legacy column'
  printf 'human_gates: intent plan <!-- every plan needs me -->\n' > .sdlc/config.md
  expect 0 status; contains 'human_gates: intent plan ·'
  printf '<!-- gates\n-->lazymode: 0\n' > .sdlc/config.md
  expect 0 status; contains 'human_gates: intent plan ·'
  ok 'ultra 1: text beside an inline or closing HTML comment still counts'
  for gates in all '[intent, plan]' 'intent;plan' spec; do
    printf 'human_gates: %s\n' "$gates" > .sdlc/config.md
    expect 0 status; contains 'human_gates: intent plan ·'; contains 'unknown human_gates value'
  done
  printf 'human_gates: Plan, intent, plan\n' > .sdlc/config.md
  expect 0 status; contains 'human_gates: plan intent ·'
  printf 'human_gates: intent\n' > .sdlc/config.md
  ok 'ultra 2: an unknown human_gates word fails closed to intent and plan'
  ready fail-cap 2
  reviewed "$SLUG" fail 'finding 1'; reviewed "$SLUG" fail 'finding 2'
  printf '\nagent edit before the third FAIL\n' >> "$F/PLAN.md"
  expect 0 approve plan "$SLUG" --agent 'reapproved mid-build'
  [ "$(state fails)" -eq 2 ] || fail 'agent plan approval reset the review FAIL cap'
  reviewed "$SLUG" fail 'finding 3'
  expect 10 next "$SLUG"; contains '3 review FAILs'
  expect 0 approve plan "$SLUG" --human 'human resumes'
  [ "$(state fails)" -eq 0 ] || fail 'human plan approval kept the review FAIL cap'
  ok 'ultra 3: an agent plan re-approval keeps the review FAIL count; the human resets it'
  printf 'services/\n' >> .git/info/exclude
  mkdir -p services/other
  git -C services/other -c init.defaultBranch=main init -q
  git -C services/other config user.name 'sdlc selftest'; git -C services/other config user.email selftest@sdlc.invalid
  printf 'v1\n' > services/other/source; git -C services/other add source; git -C services/other commit -qm v1
  ready nested-bound 1
  printf 'v2 unreviewed\n' > services/other/source; git -C services/other commit -qam v2
  evidence
  replace '/## Results/ {print "- Commit: '"$(git -C services/other rev-parse HEAD)"' services/other"} {print}' "$E"
  expect 1 score "$SLUG"; contains 'is not the reviewed commit'
  reviewed "$SLUG" pass 'review covers the nested commit'
  route deliver
  ok 'ultra 4: a review PASS binds the HEAD of every repository under the project root'
  ready log-escape 1
  evidence
  printf 'outside\n' > "$F/../outside.txt"
  replace '{sub(/logs\/S1\.txt/, "../outside.txt")} {print}' "$E"
  expect 1 score "$SLUG"; contains 'inside the feature folder'
  replace '{sub(/\.\.\/outside\.txt/, "logs/../../outside.txt")} {print}' "$E"
  expect 1 score "$SLUG"; contains 'inside the feature folder'
  replace '{sub(/logs\/\.\.\/\.\.\/outside\.txt/, "logs/S1.txt")} {print}' "$E"
  route deliver
  ok 'ultra 6: a Results log cannot point outside the feature folder'
  ready qa-added 1
  evidence
  printf 'qa only\n' > "$F/logs/S9.txt"
  printf '| S9 | PASS | | QA-added check | logs/S9.txt |\n' >> "$E"
  route deliver
  replace '!/^\| S9 /' "$E"
  expect 1 score "$SLUG"; contains 'missing S9'
  expect 1 approve plan "$SLUG" --agent 'agent cannot drop QA scenario'; contains 'S9 removed'
  expect 0 approve plan "$SLUG" --human 'S9 was a false lead'
  case " $(state scored) " in *" S9 "*) fail 'human approval kept S9 scored';; esac
  case " $(state withdrawn) " in *" S9 "*) :;; *) fail 'human approval did not withdraw S9';; esac
  reviewed "$SLUG" pass 'review after the withdrawal'
  route deliver
  ok 'ultra 7: the human withdraws a scenario only QA added by deleting its evidence row'
  mkdir -p "$TMP/no-store/deep"; cd "$TMP/no-store/deep"
  expect 2 status; contains 'no .sdlc/config.md found'
  ok 'ultra 8: the store walk-up stops at the filesystem root'
  if git -c init.defaultBranch=main init -q --object-format=sha256 "$TMP/sha256" 2>/dev/null; then
    cd "$TMP/sha256"
    git config user.name 'sdlc selftest'; git config user.email selftest@sdlc.invalid
    printf 'baseline\n' > README; git add README; git commit -qm baseline
    expect 0 init; SHA=$(git rev-parse HEAD)
    [ "${#SHA}" -eq 64 ] || fail "sha256 repository gave a ${#SHA}-character HEAD"
    ready sha256 1
    evidence; route deliver
    delivery
    expect 0 close "$SLUG" shipped 'full SHA-256 Commit and Delivered'
    ok 'ultra 9: 64-character SHA-256 Commit and Delivered hashes'
  else
    printf 'skip: git without SHA-256 repositories\n'
  fi
}
run_regressions() {
  case "$1" in
    stop) regression_stop;; scenarios) regression_scenarios;; delivery) regression_delivery;; review) regression_review;; other) regression_other;;
    init) regression_init;; ultra) regression_ultra;; round2-[abcde]) regression_round2 "${1#round2-}";; round3) regression_round3;;
    all) regression_stop; regression_scenarios; regression_delivery; regression_review; regression_other; regression_init; regression_ultra
      for round2 in a b c d e; do regression_round2 "$round2"; done; regression_round3;;
    *) fail "unknown regression group: $1";;
  esac
}
if [ "$#" -gt 0 ]; then
  [ "$#" -eq 1 ] || fail 'selftest accepts one regression group'
  run_regressions "$1"
  printf 'PASS: %s checks\n' "$COUNT"
  exit
fi
run_regressions all

cd "$KIT"
words=$(cat SKILL.md phases/*.md roles/*.md templates/*.md | wc -w | tr -d ' ')
[ "$words" -le 6000 ] || fail "prompt total $words words > 6000"
for phase in intent plan build evidence; do
  case "$phase" in
    intent) files='phases/1-intent.md templates/intent.md templates/config.md' ;;
    plan) files='phases/2-plan.md roles/scout.md roles/reviewer.md templates/PLAN.md templates/ref.md' ;;
    build) files='phases/3-build.md roles/reviewer.md' ;;
    evidence) files='phases/4-evidence.md roles/qa.md templates/evidence.md' ;;
  esac
  words=$(cat SKILL.md $files | wc -w | tr -d ' ')
  [ "$words" -le 2500 ] || fail "$phase load $words words > 2500"
  ok "$phase prompt load <= 2500 words ($words)"
done
assert_file "$SDLC"
[ "$(wc -l < "$SDLC")" -le 600 ] || fail 'sdlc.sh exceeds 600 lines'
ok 'all prompts <= 6000 words; sdlc.sh <= 600 lines'
awk 'NR==1 && $0!="---" {exit 1} NR>1 && $0=="---" {exit !(name && description)} /^name: sdlc-kit$/ {name=1} /^description: .+/ {description=1}' SKILL.md || fail 'invalid SKILL frontmatter'
paths=$(awk '{line=$0; while (match(line,/`(phases|roles|templates)\/[^`]+`/)) {print substr(line,RSTART+1,RLENGTH-2); line=substr(line,RSTART+RLENGTH)}}' SKILL.md phases/*.md roles/*.md)
while IFS= read -r path; do [ -e "$path" ] || fail "missing linked path $path"; done <<DOC
$paths
DOC
ok 'SKILL frontmatter and every linked phase/role/template path'
cd "$TMP"
expect 0 help
expect 0
expect 0 --version
[ "$OUTPUT" = "$(cat "$KIT/VERSION")" ] || fail 'version differs from VERSION'
expect 2 status
contains 'sdlc:'
expect 2 new '../unsafe'
expect 2 unknown
ok 'help, version, missing store and usage errors'
repo 'project with spaces'
assert_file .sdlc/config.md
[ -d .sdlc/work ] && [ -d .sdlc/archive ] && [ -d .sdlc/knowledge ] || fail 'init directories'
exclude=$(git rev-parse --git-path info/exclude)
contains "Ignored .sdlc/ in $exclude (this clone only; no tracked file changed)."
[ ! -e .gitignore ] || fail 'init created .gitignore'
case "$(cat .sdlc/config.md)" in *"kit: $KIT"*) ;; *) fail 'init kit path';; esac
cp .sdlc/config.md "$TMP/config.before"
expect 0 init --knowledge ignored
cmp .sdlc/config.md "$TMP/config.before" || fail 'second init overwrote config'
[ "$(awk '$0=="/.sdlc" {n++} END {print n+0}' "$exclude")" -eq 1 ] || fail 'two inits must append one exclude entry'
[ ! -e .gitignore ] && [ -z "$(git status --porcelain)" ] || fail 'second init changed the working tree'
expect 0 new first
F=$PWD/.sdlc/work/first; SLUG=first
assert_file "$F/.state"
assert_file "$F/intent.md"
[ -d "$F/refs" ] && [ -d "$F/logs" ] || fail 'new directories'
case "$(cat "$F/intent.md")" in *'<slug>'*) fail 'unreplaced slug';; esac
expect 0 next first; contains 'criterion; Delivery Target must be'
[ "$(awk '/Date:/ {print $3}' "$F/intent.md")" = "$(date +%Y-%m-%d)" ] || fail 'new date'
expect 1 new first
for bad in '../escape' 'Bad' '-bad' 'bad space' ''; do expect 2 new "$bad"; done
long=$(printf '%081d' 0); expect 2 new "$long"
expect 0 next first; contains 'READY intent'
expect 1 approve intent first --human approved
intent
expect 10 next first; contains 'NEEDS-HUMAN intent'
expect 1 approve intent first --agent checked
expect 2 approve intent first --human ''
expect 2 approve intent first --human yes --agent yes
ok 'init/new, duplicate and invalid slugs, default human intent gate'
replace ' /- none/ {$0="- not resolved: x"} {print}' "$F/intent.md"
expect 1 approve intent first --human approved
expect 10 next first
contains 'NEEDS-HUMAN intent'
replace ' /not resolved:/ {$0="1. Which output?\n   -- resolved: plain text"} {print}' "$F/intent.md"
expect 0 approve intent first --human $'approved\nby the user'
expect 0 check intent first; contains 'GATE OPEN'
cp "$F/.state" "$TMP/state.before"
expect 0 approve intent first --human again; contains 'already approved'
cmp "$F/.state" "$TMP/state.before" || fail 'repeat intent approval changed state'
printf '\nChanged intent\n' >> "$F/intent.md"
expect 1 check intent first; contains 'changed after approval'
expect 1 check plan first; contains 'GATE CLOSED'
intent
awk '{printf "%s\r\n",$0}' "$F/intent.md" > "$TMP/crlf"
mv "$TMP/crlf" "$F/intent.md"
expect 0 approve intent first --human 'CRLF reviewed'
ok 'unresolved questions, continuation resolution, approval idempotence and CRLF'
plan 1
cp "$F/PLAN.md" "$TMP/plan.valid"
for invalid in risk coverage placeholder must duplicate; do
  cp "$TMP/plan.valid" "$F/PLAN.md"
  case "$invalid" in
    risk) replace '!/Risk flags:/ {print}' "$F/PLAN.md" ;;
    coverage) replace '{gsub(/yes \| O1/,"no | O1"); print}' "$F/PLAN.md" ;;
    placeholder) replace '{gsub(/operator/,"<who>"); print}' "$F/PLAN.md" ;;
    must) replace '{gsub(/yes \| O1/,"maybe | O1"); print}' "$F/PLAN.md" ;;
    duplicate) printf '| S1 | operator | CLI | output | yes | O1 |\n' >> "$F/PLAN.md" ;;
  esac
  expect 1 approve plan first --human approved
  ok "PLAN rejects $invalid"
done
cp "$TMP/plan.valid" "$F/PLAN.md"
replace '{gsub(/security no/,"security YES"); print}' "$F/PLAN.md"
expect 1 approve plan first --agent reviewed; contains 'security'
expect 10 next first; contains 'NEEDS-HUMAN plan'
expect 0 approve plan first --human 'security scope approved'
expect 0 check plan first
printf '\nchanged\n' >> "$F/intent.md"
expect 1 check plan first; contains 'GATE CLOSED'
intent
expect 0 approve intent first --human restored
expect 0 approve plan first --human restored
expect 1 score first
for i in 1 2 3; do reviewed first fail "finding $i"; contains "review FAIL $i/3"; done
expect 10 next first; contains 'NEEDS-HUMAN build'
expect 1 review first fail fourth
expect 1 review first pass bypass
ok 'risk approval, upstream invalidation, review precondition and three-FAIL cap'
mkdir -p .sdlc/work/legacy
expect 20 next legacy; contains 'legacy v0'
expect 1 close legacy shipped 'cannot ship'
expect 0 close legacy dropped 'retire old records'
expect 30 next legacy; contains 'DONE'
expect 1 new legacy
ok 'legacy exit 20, dropped archive exit 30, archived duplicate refusal'
repo lazy
printf 'kit: %s # trailing comment\nlazymode: 4 # no human gate\n' "$KIT" > .sdlc/config.md
feature lazy
expect 0 approve intent lazy --agent reviewed
plan 1
expect 0 approve plan lazy --agent reviewed
ok 'legacy lazymode 4 and trailing config comments'
for mode in 0 1 2 3 4 invalid absent; do
  printf 'lazymode: %s # old setting\n' "$mode" > .sdlc/config.md
  if [ "$mode" = absent ]; then printf 'kit: %s\n' "$KIT" > .sdlc/config.md; fi
  expect 0 status
  actual_gates=$(printf '%s\n' "$OUTPUT" | awk 'NR==1{sub(/^.*human_gates: /,"");sub(/ · kit:.*/,"");print}')
  case "$mode" in 0|1|invalid) expected_gates='intent plan';; 2|3|absent) expected_gates=intent;; 4) expected_gates=;; esac
  [ "$actual_gates" = "$expected_gates" ] || fail "lazymode $mode gates '$actual_gates', expected '$expected_gates'"
  feature "mode-$mode"
  case "$mode" in
    4) expect 0 approve intent "$SLUG" --agent reviewed ;;
    *) expect 1 approve intent "$SLUG" --agent reviewed; expect 0 approve intent "$SLUG" --human reviewed ;;
  esac
  plan 1
  case "$mode" in
    0|1|invalid) expect 1 approve plan "$SLUG" --agent reviewed ;;
    *) expect 0 approve plan "$SLUG" --agent reviewed ;;
  esac
  ok "lazymode mapping $mode"
done
printf 'human_gates: # deliberately empty\n' > .sdlc/config.md
feature ungated
expect 0 approve intent ungated --agent reviewed
ok 'present empty human_gates allows agent approval'
mkdir -p nested/deep
cd nested/deep
expect 0 status ungated; contains 'ungated'
cd ../..
ok 'store discovery from a nested project directory'
feature formatting
cat > "$F/intent.md" <<'DOC'
# Intent
## **UNDERSTOOD AS**
- **O1**: `The CLI works.`
<!-- ignored across lines
- O2: <unfilled criterion>
## Blocking questions
- this fake question must be ignored
-->
## BLOCKING QUESTIONS
* unresolved: choose the format
## DELIVERY
- **Target**: `LOCAL`
- **Authorized**: no
DOC
expect 1 approve intent "$SLUG" --agent reviewed
expect 10 next "$SLUG"; contains 'NEEDS-HUMAN intent'
replace '/unresolved: choose/ {$0="* Which format?\n    -- resolved: text approved"} {print}' "$F/intent.md"
awk '{printf "%s\r\n",$0}' "$F/intent.md" > "$TMP/crlf"; mv "$TMP/crlf" "$F/intent.md"
expect 0 approve intent "$SLUG" --agent 'formatting and comment parsing'
plan 1
printf '<!--\n| S99 | <who> | <steps through> | <observable> | nonsense | O2 |\n-->\n' >> "$F/PLAN.md"
expect 0 approve plan "$SLUG" --agent 'comments ignored'
ok 'CRLF, case, backticks, bold, asterisk continuations and multiline HTML comments'
repo symlink-project
mv .sdlc "$TMP/shared-store"
if ln -s "$TMP/shared-store" .sdlc 2>/dev/null && [ -L .sdlc ]; then
  expect 0 new linked
  assert_file "$TMP/shared-store/work/linked/.state"
  mkdir -p nested; cd nested
  expect 0 status linked; contains 'linked'
  cd ..
  ok 'real symlink store discovered and updated from nested directories'
else
  skip 'real symlink creation unavailable on this OS'
fi

repo scoring
printf 'human_gates: intent\n' > .sdlc/config.md
ready threshold 20
evidence S20:FAIL:code
route deliver; contains '19/20 (95.0%)'; contains 'must 1/1'
cp "$F/.state" "$TMP/state.before"
route deliver
cmp "$F/.state" "$TMP/state.before" || fail 'idempotent deliver re-score'
replace '{gsub(/observed S20/,"reworded observation"); print}' "$E"
route deliver
cmp "$F/.state" "$TMP/state.before" || fail 'Observed changed evidence identity'
ok '19/20=95.0% delivers; re-score and Observed rewording preserve state'
rm "$F/logs/S20.txt"
expect 1 score "$SLUG"
printf 'restored raw output\n' > "$F/logs/S20.txt"
printf 'dirty after scoring\n' >> README
expect 1 score "$SLUG"; contains 'README'
git checkout -- README
reviewed "$SLUG" fail 'new finding invalidates review PASS'
expect 1 score "$SLUG"
reviewed "$SLUG" pass 'finding fixed and re-reviewed'
route deliver
ok 'score replay still refuses deleted logs, dirty trees and a later review FAIL'
ready below 19
evidence S19:FAIL:code
route build; contains '18/19 (94.7%)'
cp "$F/.state" "$TMP/state.before"
route build
cmp "$F/.state" "$TMP/state.before" || fail 'idempotent build re-score'
reviewed "$SLUG" fail 'new-entry review failed'
expect 1 score "$SLUG"
reviewed "$SLUG" pass 'fixed and reviewed'
evidence S19:FAIL:code
route plan; contains 'S19'
expect 1 approve plan "$SLUG" --agent unchanged; contains 'unchanged'
expect 0 next "$SLUG"; contains 'READY plan'
ok '18/19 builds; repeated same code FAIL routes to plan; unchanged plan refused'
evidence
expect 1 score "$SLUG"; contains 'routed to plan'
expect 1 review "$SLUG" pass 'skip the plan return'; contains 'routed to plan'
plan 20
expect 0 approve plan "$SLUG" --agent 'missed scenario added'
reviewed "$SLUG" pass 'reviewed after the plan return'
evidence
route deliver
ok 'a plan return blocks review and score until PLAN.md changes and is approved again'
ready added 20
evidence
printf 'QA missed-caller proof\n' > "$F/logs/extra.txt"
printf '| QA.extra | FAIL | plan | new caller failed | logs/extra.txt |\n' >> "$E"
route plan; contains '20/21 (95.2%)'; contains 'QA.extra'
ok 'QA-added plan FAIL wins over >=95% score'
ready must-fail 20
evidence S1:FAIL:code
route build; contains 'must 0/1'
ok 'must code FAIL at 95% still returns to build'
ready must-blocked 20
evidence S1:BLOCKED:
route human; contains 'BLOCKED S1'
expect 10 next "$SLUG"; contains 'NEEDS-HUMAN evidence'
ok 'must BLOCKED routes to human'
ready environment 2
evidence S2:BLOCKED:
route human; contains '1/2 (50.0%)'
ok 'only non-must BLOCKED below 95% routes to human'
ready build-cap 19
for i in 2 3 4 5; do
  evidence "S$i:FAIL:code"
  if [ "$i" -lt 5 ]; then
    route build
    [ "$(state returns_build)" -eq "$((i - 1))" ] || fail 'build return counter'
    reviewed "$SLUG" pass 'different failure fixed and reviewed'
  else
    route human; contains '3 returns to build'
    [ "$(state returns_build)" -eq 3 ] || fail 'build cap exceeded'
  fi
done
ok 'fourth distinct build return stops at human without exceeding cap'
ready plan-cap 1
for i in 1 2 3 4; do
  evidence S1:FAIL:plan
  if [ "$i" -lt 4 ]; then
    route plan
    [ "$(state returns_plan)" -eq "$i" ] || fail 'plan return counter'
    printf '\nPlan correction %s\n' "$i" >> "$F/PLAN.md"
    expect 0 approve plan "$SLUG" --agent 'corrected plan independently checked'
    reviewed "$SLUG" pass 'rebuilt and reviewed'
  else
    route human; contains '3 returns to plan'
    [ "$(state returns_plan)" -eq 3 ] || fail 'plan cap exceeded'
  fi
done
ok 'fourth plan return stops at human without exceeding cap'
ready invalid-evidence 2
for invalid in missing cause log empty-log duplicate blocked placeholder bad-sha missing-repo; do
  evidence
  case "$invalid" in
    missing) replace '!/\| S2 \|/ {print}' "$E" ;;
    cause) replace '/\| S2 \|/ {$0="| S2 | FAIL | | failed | logs/S2.txt |"} {print}' "$E" ;;
    log) replace '/\| S2 \|/ {$0="| S2 | PASS | | passed | logs/missing.txt |"} {print}' "$E" ;;
    empty-log) : > "$F/logs/S2.txt" ;;
    duplicate) printf '| S2 | PASS | | passed | logs/S2.txt |\n' >> "$E" ;;
    blocked) replace '/\| S2 \|/ {$0="| S2 | BLOCKED | | | |"} {print}' "$E" ;;
    placeholder) replace '/Commit:/ {$0="- Commit: <sha>"} {print}' "$E" ;;
    bad-sha) replace '/Commit:/ {$0="- Commit: 1234567"} {print}' "$E" ;;
    missing-repo) replace '/Commit:/ {$0=$0" nonexistent repo"} {print}' "$E" ;;
  esac
  expect 1 score "$SLUG"
  ok "score refuses $invalid evidence"
done
evidence
printf 'dirty\n' >> README
expect 1 score "$SLUG"; contains 'README'
git checkout -- README
printf 'new source\n' > README
git add README; git commit -qm 'new HEAD'
expect 1 score "$SLUG"
git reset --hard -q "$SHA"
ok 'dirty tracked tree and HEAD != evidence Commit refused'
ready no-route 1
evidence; delivery
expect 1 close "$SLUG" shipped 'not yet scored'
expect 0 close "$SLUG" dropped 'stop feature'
assert_file .sdlc/archive/no-route/.state
ok 'close requires deliver route; dropped feature archives'
ready local 1
evidence
awk '/^## Delivery/ {delivery=1} delivery {print}' "$KIT/templates/evidence.md" >> "$E"
route deliver
expect 0 next "$SLUG"; contains 'READY deliver'
expect 1 close "$SLUG" shipped 'delivery placeholders not filled'; contains 'Delivery Target must be local, pr or deploy'
ok "raw template Delivery allows scoring; next falls back to intent's target; close requires a valid target"
evidence; route deliver
OLD_SHA=$SHA
printf 'different tree\n' > README
git add README; git commit -qm 'different tree'
OTHER=$(git rev-parse HEAD)
git reset --hard -q "$SHA"
delivery local "$OTHER"
expect 1 close "$SLUG" shipped 'different tree'
evidence; delivery; route deliver
expect 0 close "$SLUG" shipped 'local delivery complete'
assert_file .sdlc/archive/local/evidence.md
[ ! -d .sdlc/work/local ] || fail 'shipped directory remained in work'
expect 30 next local
ok 'different delivered tree refused; verified local delivery ships and archives'
ready remote 1
evidence; delivery pr "$SHA" no; route deliver
expect 10 next "$SLUG"; contains 'authorize pr'
expect 1 close "$SLUG" shipped 'unauthorized PR'
evidence; delivery pr "$SHA" 'No — ask before delivery'; route deliver
expect 1 close "$SLUG" shipped 'a no with a note is not authorization'
evidence; delivery pr "$SHA" 'yes — push approved'; route deliver
expect 1 close "$SLUG" shipped 'not on remote'
git -c init.defaultBranch=main init -q --bare "$TMP/remote.git"
git remote add origin "$TMP/remote.git"
git push -q -u origin main
expect 0 close "$SLUG" shipped 'review branch on throwaway remote'
assert_file .sdlc/archive/remote/.state
ok 'PR requires authorization and remote containment; temp remote PR ships'
mkdir -p .sdlc/work/old-v0
expect 0 status; contains 'old-v0'; contains 'legacy'; contains 'threshold'
expect 0 status --json
printf '%s\n' "$OUTPUT" > "$TMP/status.json"
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d["features"],list); assert all(set(("slug","phase","state","action","score","route","returns_plan","returns_build","review_fails")) <= set(f) for f in d["features"])' < "$TMP/status.json" || fail 'invalid status JSON'
else
  case "$OUTPUT" in '{"store":'*'"human_gates":'*'"features":['*']}') ;; *) fail 'invalid JSON structure';; esac
fi
ok 'text status lists live and legacy features; JSON parses with every required field'
mkdir -p '.sdlc/work/Old Ticket'
expect 0 status; contains 'skipped Old Ticket'; contains 'old-v0'
rmdir '.sdlc/work/Old Ticket'
ok 'status skips a folder that is not a valid slug instead of failing'
feature json-escaped
expect 0 close "$SLUG" dropped 'stopped "quoted" \ reason'
expect 0 status "$SLUG" --json
case "$OUTPUT" in *'\"quoted\"'*'\\ reason'*) ;; *) fail 'JSON action quote or backslash not escaped';; esac
if command -v python3 >/dev/null 2>&1; then
  printf '%s\n' "$OUTPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); a=d["features"][0]["action"]; assert "\"quoted\"" in a and "\\ reason" in a' || fail 'escaped JSON does not round trip'
fi
ok 'JSON escapes and round trips quotes and backslashes in an action'
repo multi-repository
printf 'services/\n' >> .git/info/exclude
mkdir -p 'services/other repo'
git -C 'services/other repo' -c init.defaultBranch=main init -q
git -C 'services/other repo' config user.name 'sdlc selftest'
git -C 'services/other repo' config user.email selftest@sdlc.invalid
git -C 'services/other repo' config init.defaultBranch main
git -C 'services/other repo' config core.autocrlf false
printf 'secondary source\n' > 'services/other repo/source'
git -C 'services/other repo' add source
git -C 'services/other repo' commit -qm 'secondary baseline'
SECOND_SHA=$(git -C 'services/other repo' rev-parse HEAD)
ready multi 1
evidence
replace '/## Results/ {print "- Commit: '"$SECOND_SHA"' services/other repo"} {print}' "$E"
printf 'dirty secondary\n' >> 'services/other repo/source'
expect 1 score "$SLUG"; contains 'source'
git -C 'services/other repo' checkout -- source
route deliver
delivery local "$SHA ./"
printf -- '- Delivered: %s services/other repo/.\n' "$SECOND_SHA" >> "$E"
expect 0 close "$SLUG" shipped 'both repository trees verified'
ok 'multiple repositories, space-containing paths, secondary dirty tree and same-repository delivery path aliases'
ready same-tree 1
evidence; route deliver
git commit --allow-empty -qm 'different commit, identical tree'
SAME_TREE=$(git rev-parse HEAD)
git reset --hard -q "$SHA"
delivery local "$SAME_TREE"
expect 0 close "$SLUG" shipped 'same tree is the delivery contract'
ok 'different delivered commit with identical tree is accepted'

repo lifecycle
cp "$KIT/tests/fixture/"*.sh .
git add todo.sh test.sh; git commit -qm 'baseline todo CLI'
SHA=$(git rev-parse HEAD)
bash test.sh > "$TMP/baseline-test"
export TODO_FILE=$TMP/old-data
bash todo.sh add 'written by old version'
expect 0 new count-todos
SLUG=count-todos; F=$PWD/.sdlc/work/$SLUG
cat > "$F/intent.md" <<'DOC'
# Intent: count-todos
## Understood as
- O1: A CLI user can count saved tasks.
- O2: Data written by the old CLI still lists unchanged.
## Blocking questions
- none
## Delivery
- Target: local
- Authorized: local feature implementation approved
DOC
expect 0 approve intent "$SLUG" --human 'add count and preserve old saved tasks'
printf '[verified: bash todo.sh list] Existing add/list commands store one task per line.\n' > "$F/refs/logic.md"
printf '[verified: old-data fixture] Existing saved data contains written by old version.\n' > "$F/refs/data.md"
printf '[verified: bash test.sh] Existing add/list and invalid-input checks passed.\n' > "$F/refs/flow.md"
cat > "$F/PLAN.md" <<'DOC'
# Plan: count-todos
## Summary
Add a count command while preserving add/list behavior and saved data.
## Understanding
- Logic: refs/logic.md
- Data: refs/data.md
- Flow: refs/flow.md
## Side effects
- Old saved files continue to list unchanged (S2).
- Risk flags: migration no · data deletion no · public API no · security no · infra no
## Changes
1. todo.sh: count lines, return zero when the data file is missing.
## Scenarios
| ID | Persona | Steps | Expected | Must | Covers |
|---|---|---|---|---|---|
| S1 | CLI user | add tasks then run count | exact saved count | yes | O1 |
| S2 | existing user | list data written by old CLI | original text unchanged | yes | O2 |
| S3 | new user | count with no data file | zero | no | O1 |
| S4 | existing user | run existing test.sh | add/list and invalid-input checks pass | no | O2 |
DOC
expect 0 approve plan "$SLUG" --agent 'scenarios cover both outcomes and data compatibility'
awk '/^  \*\)/ {print "  count)"; print "    if [ -f \"$file\" ]; then awk '\''END {print NR+0}'\'' \"$file\"; else echo 0; fi"; print "    ;;"} {print}' todo.sh > "$TMP/product"
mv "$TMP/product" todo.sh
chmod +x todo.sh
bash test.sh > "$TMP/changed-test"
git add todo.sh; git commit -qm 'add task count command'
SHA=$(git rev-parse HEAD)
printf 'VERDICT: PASS\n' > "$F/review.md"
reviewed "$SLUG" pass 'count path and old add/list independently checked'
bash todo.sh add 'new task'
actual=$(bash todo.sh count)
[ "$actual" = 2 ] || fail "lifecycle S1 count: $actual"
printf 'bash todo.sh count -> %s\n' "$actual" > "$F/logs/S1.txt"
actual=$(bash todo.sh list)
[ "$actual" = "$(printf 'written by old version\nnew task')" ] || fail 'lifecycle S2 old data changed'
printf 'bash todo.sh list ->\n%s\n' "$actual" > "$F/logs/S2.txt"
actual=$(TODO_FILE="$TMP/absent-data" bash todo.sh count)
[ "$actual" = 0 ] || fail 'lifecycle S3 missing data is not zero'
printf 'TODO_FILE=absent bash todo.sh count -> %s\n' "$actual" > "$F/logs/S3.txt"
bash test.sh > "$F/logs/S4.txt"
E=$F/evidence.md
printf '# Evidence\n- Commit: %s\n## Results\n| ID | Result | Cause | Observed | Log |\n|---|---|---|---|---|\n' "$SHA" > "$E"
for i in 1 2 3 4; do printf '| S%s | PASS | | real CLI output asserted | logs/S%s.txt |\n' "$i" "$i" >> "$E"; done
route deliver; contains '4/4 (100.0%)'; contains 'must 2/2'
delivery
expect 0 close "$SLUG" shipped 'count command and old saved data verified locally'
assert_file .sdlc/archive/count-todos/evidence.md
assert_file .sdlc/archive/count-todos/refs/data.md
expect 30 next "$SLUG"
ok 'real four-phase lifecycle: old CLI data, scouts, plan, change, commit, review, four CLI scenarios, score, local archive'
printf 'PASS: %s checks\n' "$COUNT"
