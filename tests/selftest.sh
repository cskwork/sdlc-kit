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
  reviewed "$SLUG" pass ${3+"$3"} 'independent review passed'
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
nested_repo() {
  mkdir -p "$1"
  git -C "$1" -c init.defaultBranch=main init -q
  git -C "$1" config user.name 'sdlc selftest'; git -C "$1" config user.email selftest@sdlc.invalid
  printf '%s\n' "$1" > "$1/source"; git -C "$1" add source; git -C "$1" commit -qm base
}
regression_repos() {
  repo regression-repos
  printf 'services/\n' >> .git/info/exclude
  for name in a b c; do nested_repo "services/$name"; done
  printf 'human_gates: intent\nrepos: . services/a # repositories a review binds\n' > .sdlc/config.md
  ready bound 1
  case "$(state heads)" in *'/services/a'*) :;; *) fail 'repos: did not bind services/a';; esac
  case "$(state heads)" in *'/services/b'*|*'/services/c'*) fail 'repos: bound an unlisted repository';; esac
  [ "${#OUTPUT}" -lt 200 ] || fail "review printed ${#OUTPUT} bytes"
  evidence
  replace '/## Results/ {print "- Commit: '"$(git -C services/a rev-parse HEAD)"' services/a"} {print}' "$E"
  route deliver
  replace '/## Results/ {print "- Commit: '"$(git -C services/b rev-parse HEAD)"' services/b"} {print}' "$E"
  expect 1 score "$SLUG"; contains 'services/b was not under review'; contains 'config repos: (now: . services/a) or review --repos names'
  printf 'human_gates: intent\nrepos: ., services/a\n' > .sdlc/config.md
  reviewed "$SLUG" pass 'comma-separated repos'
  case "$(state heads)" in *'/services/b'*|*'/services/c'*) fail 'comma-separated repos: bound an unlisted repository';; esac
  [ "$(state heads | awk -F'\t' '{print NF}')" -eq 4 ] || fail "comma-separated repos: did not bind . and services/a: $(state heads)"
  ok 'config repos: takes commas between entries, as human_gates does'
  printf 'human_gates: intent\nrepos: ,\n' > .sdlc/config.md
  printf 'VERDICT: PASS\n' >> "$F/review.md"
  expect 1 review "$SLUG" pass 'only a comma'; contains "repos: ',' lists no repository"
  printf 'human_gates: intent\nrepos: services/a services/none\n' > .sdlc/config.md
  printf 'VERDICT: PASS\n' >> "$F/review.md"
  expect 1 review "$SLUG" pass 'listed path is missing'; contains "repos: 'services/none' is not a directory under the project root"
  printf 'human_gates: intent\nrepos: %s\n' "$PWD/services/a" > .sdlc/config.md
  expect 1 review "$SLUG" pass 'listed path is absolute'; contains "repos: '$PWD/services/a' must be a path relative to the project root"
  printf 'human_gates: intent\nrepos: services\n' > .sdlc/config.md
  expect 1 review "$SLUG" pass 'listed path is a plain folder'; contains "repos: 'services' is not the top folder of a git repository"
  nested_repo "$TMP/outside-repos"
  printf 'human_gates: intent\nrepos: . ../outside-repos\n' > .sdlc/config.md
  expect 1 review "$SLUG" pass 'listed path leaves the root'; contains "repos: '../outside-repos' is not a directory under the project root"
  if ln -s "$TMP/outside-repos" services/out 2>/dev/null && [ -L services/out ]; then
    printf 'human_gates: intent\nrepos: services/out\n' > .sdlc/config.md
    expect 1 review "$SLUG" pass 'listed symlink leaves the root'; contains "repos: 'services/out' is not a directory under the project root"
  else
    skip 'symlink to a repository outside the root unavailable on this OS'
  fi
  ok 'config repos: limits the repositories a review binds, takes only repository top folders under the root, and names itself when a Commit is outside it'
}
regression_cells() {
  repo regression-cells
  ready cells 1
  evidence
  replace '/\| S1 \|/ {$0="| S1 | PASS | | observed | extra cell | logs/S1.txt |"} {print}' "$E"
  expect 1 score "$SLUG"; contains 'S1: row has 6 cells, header has 5'
  case "$OUTPUT" in *'needs a non-empty log'*) fail 'cell mismatch reported as a log problem';; esac
  replace '/\| S1 \|/ {$0="| S1 | PASS | | left \\| right | logs/S1.txt"} {print}' "$E"
  route deliver
  printf '| S2 | operator | run CLI | output | no | O1 | extra |\n' >> "$F/PLAN.md"
  expect 1 approve plan "$SLUG" --agent 'long scenario row'; contains 'S2: row has 7 cells, header has 6'
  feature short-rows
  expect 0 approve intent "$SLUG" --human 'approved scope'
  plan 1; printf '| S2 | operator | run CLI | output | no |\n' >> "$F/PLAN.md"; N=2
  expect 0 approve plan "$SLUG" --agent 'short scenario row as v2.1.0 read it'
  reviewed "$SLUG" pass 'short rows'
  evidence; replace '/\| S2 \|/ {$0="| S2 | BLOCKED | | no env |"} {print}' "$E"
  expect 0 score "$SLUG"; contains 'ROUTE human'
  case "$OUTPUT" in *'row has'*) fail 'a short row was refused';; esac
  feature trailing-cells
  expect 0 approve intent "$SLUG" --human 'approved scope'
  plan 1; replace '/\| S1 \|/ {$0=$0" |"} {print}' "$F/PLAN.md"
  expect 0 approve plan "$SLUG" --agent 'scenario row with a trailing empty cell'
  reviewed "$SLUG" pass 'trailing empty cells'
  evidence; replace '/\| S1 \|/ {$0=$0" |  |"} {print}' "$E"
  route deliver
  case "$OUTPUT" in *'row has'*) fail 'a trailing empty cell was refused';; esac
  ok 'a Results or Scenarios row with more cells than its header is named, a shorter row reads as before; escaped pipes still count as text; trailing empty cells are allowed'
}
regression_paths() {
  repo regression-paths
  ready paths 1
  evidence
  replace '/Commit:/ {$0=$0" (reviewed)"} {print}' "$E"
  expect 1 score "$SLUG"; contains "Commit path '(reviewed)' is not a directory under the project root: write '- Commit: <sha> <relative-path>'"
  evidence; route deliver; delivery local "$SHA nowhere"
  expect 1 close "$SLUG" shipped 'delivered path is not a folder'; contains "Delivered missing for repo: .: add '- Delivered: <sha> .'"; contains "the line for 'nowhere' was skipped: it is not a folder under the project root"
  ok 'a Commit path that is not a folder says so with the line format; a Delivered line for no folder is skipped and named when nothing matches'
  evidence; route deliver; delivery local "$SHA deploy-repo"; printf -- '- Delivered: %s\n' "$SHA" >> "$E"
  expect 0 close "$SLUG" shipped 'extra Delivered line for a repository not checked out here'; contains 'Archived'
  ok 'a Delivered line for a repository not present locally is skipped when another Delivered line matches'
}
regression_uncommitted() {
  repo regression-uncommitted
  feature precommit
  expect 0 approve intent "$SLUG" --human 'approved scope'
  plan 1; expect 0 approve plan "$SLUG" --agent reviewed
  printf 'reviewed change\n' >> README; printf 'new file\n' > added.txt
  reviewed "$SLUG" pass --uncommitted 'reviewed before the human commits'; review_output=$OUTPUT
  git add README added.txt; git commit -qm 'commit the reviewed change'; SHA=$(git rev-parse HEAD)
  evidence; route deliver; delivery
  expect 0 close "$SLUG" shipped 'reviewed before commit, committed unchanged'
  OUTPUT=$review_output; contains 'Uncommitted changes are bound'
  ok 'a review PASS on uncommitted changes accepts the commit of exactly that change'
  feature precommit-changed
  expect 0 approve intent "$SLUG" --human 'approved scope'
  plan 1; expect 0 approve plan "$SLUG" --agent reviewed
  printf 'reviewed two\n' >> README
  reviewed "$SLUG" pass --uncommitted 'reviewed before commit'
  reviewed_sha=$SHA
  printf 'unreviewed extra\n' >> README; git commit -qam 'commit more than was reviewed'; SHA=$(git rev-parse HEAD)
  evidence
  expect 1 score "$SLUG"; contains "is not the reviewed uncommitted change"; contains "on top of the reviewed commit $reviewed_sha"
  git reset -q --hard "$reviewed_sha"; printf 'reviewed two\n' >> README
  git stash -q; git commit -q --amend --allow-empty -m 'rewritten base'; git stash pop -q
  git commit -qam 'reviewed change on another base'; SHA=$(git rev-parse HEAD)
  evidence
  expect 1 score "$SLUG"; contains 'is not the reviewed uncommitted change'
  reviewed "$SLUG" pass 'review the committed change'
  route deliver
  ok 'a commit that differs from the reviewed uncommitted change, or sits on another base, needs a new review'
  feature precommit-dropped
  expect 0 approve intent "$SLUG" --human 'approved scope'
  plan 1; expect 0 approve plan "$SLUG" --agent reviewed
  printf 'reviewed three\n' >> README
  reviewed "$SLUG" pass --uncommitted 'reviewed before commit'
  git checkout -q README; SHA=$(git rev-parse HEAD)
  evidence
  expect 1 score "$SLUG"; contains 'is not the reviewed uncommitted change'
  printf 'reviewed three\n' >> README; git stash -q
  expect 1 score "$SLUG"; contains 'is not the reviewed uncommitted change'
  git stash pop -q; git commit -qam 'commit the reviewed change at last'; SHA=$(git rev-parse HEAD)
  evidence; route deliver
  ok 'the reviewed HEAD alone does not satisfy a review of uncommitted changes that were reverted or stashed'
  feature precommit-gone
  expect 0 approve intent "$SLUG" --human 'approved scope'
  plan 1; expect 0 approve plan "$SLUG" --agent reviewed
  printf 'reviewed four\n' >> README
  reviewed "$SLUG" pass --uncommitted 'reviewed before commit'
  tree=$(state heads | awk -F'\t' '{print $1}'); tree=${tree#*+}
  git checkout -q README; rm -f ".git/objects/${tree:0:2}/${tree:2}"
  ! git cat-file -e "$tree" 2>/dev/null || fail 'the reviewed tree is still in the object store'
  SHA=$(git rev-parse HEAD); evidence
  expect 1 score "$SLUG"; contains "the reviewed tree $tree of . is gone (git gc?): review again"
  ok 'a reviewed tree pruned from the object store asks for a new review'
}
# Without --uncommitted a review binds HEAD alone, as in v2.1.0: a stray file present at review and gone by score
# does not matter, and nothing is written to the object store. A FAIL binds nothing.
regression_optin() {
  repo regression-optin
  feature committed-first
  expect 0 approve intent "$SLUG" --human 'approved scope'
  plan 1; expect 0 approve plan "$SLUG" --agent reviewed
  printf 'committed change\n' >> README; git commit -qam 'commit first'; SHA=$(git rev-parse HEAD)
  printf 'test artifact\n' > coverage.txt; printf 'unstaged\n' >> README; objects=$(git count-objects -v)
  reviewed "$SLUG" pass 'review after commit, stray artifact present'; review_output=$OUTPUT
  rm coverage.txt; git checkout -q README
  evidence; route deliver
  case "$(state heads)" in *+*) fail 'a review without --uncommitted bound the working tree';; esac
  [ "$(git count-objects -v)" = "$objects" ] || fail 'a review without --uncommitted wrote to the object store'
  OUTPUT=$review_output; case "$OUTPUT" in *'Uncommitted changes are bound'*) fail 'notice printed without --uncommitted';; esac
  ok 'without --uncommitted a review binds HEAD alone: a stray file deleted before score does not block the reviewed commit'
  feature flag-args
  expect 0 approve intent "$SLUG" --human 'approved scope'
  plan 1; expect 0 approve plan "$SLUG" --agent reviewed
  printf 'VERDICT: FAIL\n' >> "$F/review.md"
  expect 2 review "$SLUG" fail --uncommitted 'flag on a FAIL'; contains '--uncommitted binds a PASS'
  expect 2 review "$SLUG" pass --uncommitted; contains 'review <slug> pass --uncommitted note'
  expect 0 review "$SLUG" fail 'finding'
  [ -z "$(state heads)" ] || fail 'a review FAIL recorded heads'
  ok '--uncommitted goes with a PASS and a note; a FAIL binds no heads'
}
regression_nested() {
  repo regression-nested
  for name in a b c; do nested_repo "worktrees/$name"; done
  git worktree add -q --detach worktrees/linked
  ready nested-clean 1 --uncommitted
  case "$(state heads)" in *+*) fail 'untracked nested repositories bound as uncommitted changes';; esac
  feature nested
  expect 0 approve intent "$SLUG" --human 'approved scope'
  plan 1; expect 0 approve plan "$SLUG" --agent reviewed
  printf 'real change\n' >> README
  reviewed "$SLUG" pass --uncommitted 'reviewed beside untracked nested repositories'; contains 'Uncommitted changes are bound'
  case "$OUTPUT" in *'embedded git repository'*) fail 'review warned about nested repositories';; esac
  [ "${#OUTPUT}" -lt 400 ] || fail "review printed ${#OUTPUT} bytes"
  git commit -qam 'commit only the real change'; SHA=$(git rev-parse HEAD)
  evidence; route deliver
  git init -q worktrees/empty
  printf 'more\n' >> README
  reviewed "$SLUG" pass --uncommitted 'nested repository without a commit'
  ok 'untracked nested repositories stay out of the bound change, its dirty check and the review output'
}
# Uncommitted changes outside every Commit path do not block a reviewed commit, as in v2.1.0.
regression_scoped() {
  local parent=$TMP/regression-scoped
  mkdir -p "$parent/proj" "$parent/other"; cd "$parent"
  git -c init.defaultBranch=main init -q
  git config user.name 'sdlc selftest'; git config user.email selftest@sdlc.invalid; git config core.autocrlf false
  printf 'other\n' > other/o.txt; printf 'baseline\n' > proj/README; git add other proj; git commit -qm baseline
  cd proj; expect 0 init
  printf 'committed change\n' >> README; git commit -qam 'change in the project'; SHA=$(git rev-parse HEAD)
  printf 'outside the project\n' >> ../other/o.txt
  ready scoped-parent 1 --uncommitted
  evidence; route deliver
  ok 'a reviewed commit passes beside uncommitted changes in the parent repository outside the project root'
  printf 'reviewed in the project\n' >> README
  feature scoped-later
  expect 0 approve intent "$SLUG" --human 'approved scope'
  plan 1; expect 0 approve plan "$SLUG" --agent reviewed
  reviewed "$SLUG" pass --uncommitted 'reviewed before commit beside outside changes'
  printf 'unreviewed\n' > ../other/x.txt; git add README ../other/x.txt; git commit -qm 'reviewed change plus an unreviewed one'; SHA=$(git rev-parse HEAD)
  evidence
  expect 1 score "$SLUG"; contains 'is not the reviewed uncommitted change'
  git reset -q HEAD~1; rm ../other/x.txt; git add README; git commit -qm 'only the reviewed change'; SHA=$(git rev-parse HEAD)
  evidence; route deliver
  ok 'a commit after an uncommitted review is compared inside its path, and refused for unreviewed changes outside it'
  repo regression-scoped-pkg
  mkdir pkg; printf 'package\n' > pkg/file; git add pkg; git commit -qm 'add package'; SHA=$(git rev-parse HEAD)
  printf 'notes\n' > notes.txt
  ready scoped-pkg 1 --uncommitted
  evidence; replace '/^- Commit:/ {$0=$0" pkg"} {print}' "$E"
  route deliver
  ok 'an untracked file outside the Commit path does not block a reviewed commit'
  mkdir out; seq 1 50 > out/secret.txt; git add out; git commit -qm 'add a file outside the package'
  feature scoped-rename
  expect 0 approve intent "$SLUG" --human 'approved scope'
  plan 1; expect 0 approve plan "$SLUG" --agent reviewed
  printf 'reviewed\n' >> pkg/file
  reviewed "$SLUG" pass --uncommitted 'reviewed before commit'
  git mv out/secret.txt other-secret.txt; printf 'EVIL\n' >> other-secret.txt
  git add -A; git commit -qm 'reviewed change plus an unreviewed rename and edit'; SHA=$(git rev-parse HEAD)
  evidence; replace '/^- Commit:/ {$0=$0" pkg"} {print}' "$E"
  expect 1 score "$SLUG"; contains 'is not the reviewed uncommitted change'
  ok 'an unreviewed rename outside the Commit path is refused like any other unreviewed change'
}
# Fingerprinting uncommitted changes never breaks a review that v2.1.0 accepted.
regression_fingerprint() {
  repo regression-fingerprint
  mkdir -p .sdlc/memory; printf 'shared\n' > .sdlc/memory/team.md; git add -f .sdlc/memory/team.md; git commit -qm 'share store knowledge'
  mkdir pkg; printf 'package\n' > pkg/file; git add pkg; git commit -qm 'add package'; SHA=$(git rev-parse HEAD)
  printf 'notes\n' > notes.txt
  ready tracked-store 1 --uncommitted
  evidence; replace '/^- Commit:/ {$0=$0" pkg"} {print}' "$E"
  route deliver
  ok 'a partly tracked, ignored store does not stop the working tree fingerprint'
  repo 'regression-c++proj'
  ready plus-path 1 --uncommitted
  case "$OUTPUT" in *'Uncommitted changes are bound'*) fail 'a + in the repository path read as bound uncommitted changes';; esac
  ok 'a + in a repository path is not a bound working tree'
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) printf 'skip: unreadable files need POSIX permissions\n'; return;; esac
  repo regression-unreadable
  mkdir pkg; printf 'package\n' > pkg/file; git add pkg; git commit -qm 'add package'; SHA=$(git rev-parse HEAD)
  mkdir build; printf 'locked\n' > build/locked.bin; chmod 000 build/locked.bin
  if cat build/locked.bin > /dev/null 2>&1; then chmod 600 build/locked.bin; printf 'skip: unreadable files are readable for this user\n'; return; fi
  ready unreadable 1 --uncommitted; contains 'the PASS binds its HEAD only'
  [ "$(printf '%s\n' "$OUTPUT" | grep -c 'cannot fingerprint')" -eq 1 ] || fail "fingerprint warning not printed once: $OUTPUT"
  evidence; replace '/^- Commit:/ {$0=$0" pkg"} {print}' "$E"
  route deliver
  chmod 600 build/locked.bin
  ok 'an unreadable untracked file binds HEAD alone with one warning, as v2.1.0 bound it'
}
# An interrupted review removes its temporary index folder. Needs job control and POSIX signals.
regression_interrupt() {
  local real mark dir pid n
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) printf 'skip: interrupt cleanup needs POSIX signals\n'; return;; esac
  repo regression-interrupt
  feature interrupt
  expect 0 approve intent "$SLUG" --human 'approved scope'
  plan 1; expect 0 approve plan "$SLUG" --agent reviewed
  printf 'change\n' >> README; printf 'VERDICT: PASS\n' >> "$F/review.md"
  real=$(command -v git); mark=$TMP/interrupt-mark; mkdir -p "$TMP/slowgit"
  printf '#!/bin/sh\ncase " $* " in *" write-tree"*) printf %%s "$GIT_INDEX_FILE" > "%s"; sleep 5;; esac\nexec "%s" "$@"\n' "$mark" "$real" > "$TMP/slowgit/git"
  chmod +x "$TMP/slowgit/git"
  set -m; PATH="$TMP/slowgit:$PATH" bash "$SDLC" review "$SLUG" pass --uncommitted interrupted > /dev/null 2>&1 & pid=$!; set +m
  n=0; while [ ! -s "$mark" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n+1)); done
  [ -s "$mark" ] || fail 'review never fingerprinted the working tree'
  dir=$(dirname "$(cat "$mark")"); kill -INT -- "-$pid"; wait "$pid" || :
  n=0; while [ -e "$dir" ] && [ "$n" -lt 30 ]; do sleep 0.1; n=$((n+1)); done
  [ ! -e "$dir" ] || { rm -rf "$dir"; fail 'interrupted review left its temporary index'; }
  ok 'an interrupted review removes its temporary index'
}
regression_reposflag() {
  repo regression-reposflag
  printf 'services/\n' >> .git/info/exclude
  for name in a b; do nested_repo "services/$name"; done
  printf 'human_gates: intent\nrepos: services/b\n' > .sdlc/config.md
  feature flag-repos
  expect 0 approve intent "$SLUG" --human 'approved scope'
  plan 1; expect 0 approve plan "$SLUG" --agent reviewed
  reviewed "$SLUG" pass --repos 'services/a' 'review names its repository'
  case "$(state heads)" in *'/services/a') :;; *) fail "review --repos did not bind services/a: $(state heads)";; esac
  [ "$(state heads | awk -F'\t' '{print NF}')" -eq 2 ] || fail "review --repos bound more than services/a: $(state heads)"
  evidence
  replace '/^- Commit:/ {print "- Commit: '"$(git -C services/a rev-parse HEAD)"' services/a"; next} {print}' "$E"
  route deliver
  replace '/^- Commit:/ {print "- Commit: '"$(git -C services/b rev-parse HEAD)"' services/b"; next} {print}' "$E"
  expect 1 score "$SLUG"; contains 'services/b was not under review'; contains 'or review --repos names'
  printf 'VERDICT: PASS\n' >> "$F/review.md"
  expect 0 review "$SLUG" pass --repos 'services/a' --uncommitted 'flags in either order'
  printf 'VERDICT: PASS\n' >> "$F/review.md"
  expect 0 review "$SLUG" pass --uncommitted --repos 'services/a, services/b' 'commas between entries'
  [ "$(state heads | awk -F'\t' '{print NF}')" -eq 4 ] || fail "review --repos with a comma did not bind both: $(state heads)"
  printf 'VERDICT: PASS\n' >> "$F/review.md"
  expect 2 review "$SLUG" pass --repos '' 'empty list'; contains 'review --repos lists no repository'
  expect 2 review "$SLUG" pass --repos 'services/a'; contains 'review <slug> pass|fail note'
  expect 2 review "$SLUG" pass --repos 'services/a' --repos 'services/b' 'repeated flag'; contains 'review <slug> pass|fail note'
  printf 'VERDICT: FAIL\n' >> "$F/review.md"
  expect 2 review "$SLUG" fail --repos 'services/a' 'flag on a FAIL'; contains 'as --repos does'
  printf 'VERDICT: PASS\n' >> "$F/review.md"
  expect 1 review "$SLUG" pass --repos 'services/none' 'missing path'; contains "review --repos 'services/none' is not a directory under the project root"
  ok 'review --repos replaces config repos: for one review, takes either flag order, and refuses an empty or missing list'
}
regression_carry() {
  repo regression-carry
  ready blocked-retry 2
  evidence S1:BLOCKED:; route human
  replace '/^\| S2 / {sub(/run real CLI/, "run the CLI with a fixture")} {print}' "$F/PLAN.md"
  expect 0 approve plan "$SLUG" --human 'retry S1 with a fixture'; contains 'review PASS carried'
  case "$(state review)" in "pass $(state entry) "*' carried: independent review passed') :;; *) fail "review not carried: $(state review)";; esac
  evidence S1:BLOCKED:; route human
  printf '## Round — plan gap check\nVERDICT: PASS\n' >> "$F/review.md"
  expect 0 approve plan "$SLUG" --human 'retry S1 again after a passing gap check'; contains 'review PASS carried'
  case "$(state review)" in *'carried: carried:'*) fail "carried note stacked: $(state review)";; esac
  evidence; route deliver
  ok 'a plan re-approval that changes only Scenarios keeps the review PASS while every reviewed HEAD is unchanged'
  ready code-moved 2
  evidence S1:BLOCKED:; route human
  printf 'fix\n' >> README; git commit -qam fix; SHA=$(git rev-parse HEAD)
  expect 0 approve plan "$SLUG" --human 'retry after a new commit'
  case "$OUTPUT" in *carried*) fail 'review carried across a new commit';; esac
  [ -z "$(state review)" ] && [ -z "$(state heads)" ] || fail 'a new commit kept the review'
  evidence; expect 1 score "$SLUG"; contains 'review PASS required'
  ready plan-moved 2
  evidence S1:BLOCKED:; route human
  replace '/^## Scenarios/ {print "## Changes"; print "1. README — one more step"} {print}' "$F/PLAN.md"
  expect 0 approve plan "$SLUG" --human 'plan changed outside Scenarios'
  [ -z "$(state review)" ] || fail 'a PLAN.md change outside Scenarios kept the review'
  ready legacy-state 2
  evidence S1:BLOCKED:; route human
  replace '!/^planbody:/' "$F/.state"
  expect 0 approve plan "$SLUG" --human 'state from an older kit'
  [ -z "$(state review)" ] || fail 'a state without planbody kept the review'
  printf 'work in progress\n' > wip.txt
  ready tree-bound 2 --uncommitted
  case "$(state heads)" in *+*) :;; *) fail "review --uncommitted bound no working tree: $(state heads)";; esac
  rm wip.txt
  replace '/^\| S2 / {sub(/run real CLI/, "run the CLI again")} {print}' "$F/PLAN.md"
  expect 0 approve plan "$SLUG" --agent 'scenario wording'
  [ -z "$(state review)" ] || fail 'a review bound to a working tree was carried'
  ready intent-moved 2
  evidence S1:BLOCKED:; route human
  printf -- '- O2: The operator also observes the log.\n' > "$TMP/o2"
  replace '/^- O1:/ {print; while ((getline l < "'"$TMP/o2"'") > 0) print l; next} {print}' "$F/intent.md"
  replace '/^\| S1 / {sub(/\| O1 \|$/, "| O1 O2 |")} {print}' "$F/PLAN.md"
  expect 0 approve intent "$SLUG" --human 'added O2'
  expect 0 approve plan "$SLUG" --human 'S1 covers O2'
  [ -z "$(state review)" ] || fail 'an intent change kept the review'
  ready build-return 2
  evidence S2:FAIL:code; route build
  replace '/^\| S2 / {sub(/run real CLI/, "run the CLI after the fix")} {print}' "$F/PLAN.md"
  expect 0 approve plan "$SLUG" --agent 'scenario wording after a build return'
  [ -z "$(state review)" ] || fail 'a review from before a build return was carried'
  ready unrecorded-round 2
  evidence S1:BLOCKED:; route human
  printf 'VERDICT: FAIL\n' >> "$F/review.md"
  expect 0 approve plan "$SLUG" --human 'retry with a newer round unrecorded'
  [ -z "$(state review)" ] || fail 'a PASS was carried past a newer unrecorded round'
  feature commented-change
  expect 0 approve intent "$SLUG" --human 'approved scope'
  plan 2; replace '/^## Scenarios/ {print "## Changes"; print "<!--"; print "## Scenarios draft"; print "-->"} {print}' "$F/PLAN.md"
  expect 0 approve plan "$SLUG" --agent reviewed; reviewed "$SLUG" pass 'independent review passed'
  evidence S1:BLOCKED:; route human
  replace '{print} /^-->/ {print "1. README — a change after a commented heading"}' "$F/PLAN.md"
  expect 0 approve plan "$SLUG" --human 'change hidden after a commented heading'
  [ -z "$(state review)" ] || fail 'a commented Scenarios heading hid a change outside Scenarios'
  ok 'the review is not carried after a new commit, a change to intent.md or PLAN.md outside Scenarios, a build return, an unrecorded round, a state without planbody, or a bound working tree'
}
regression_target() {
  repo regression-target
  feature target-detail
  replace '{sub(/^- Target: local$/, "- Target: deploy (dev then stg)")} {print}' "$F/intent.md"
  expect 1 approve intent "$SLUG" --human 'approved scope'; contains 'found "deploy (dev then stg)"'; contains 'put any detail on a "- Note:" line'
  replace '!/^- Target:/' "$F/intent.md"
  expect 1 approve intent "$SLUG" --human 'approved scope'; contains 'or deploy, alone on its line (missing)'
  intent
  replace '/^- Target:/ {print; print "- Note: push the branch after review"; next} {print}' "$F/intent.md"
  expect 0 approve intent "$SLUG" --human 'approved scope'
  ready target-close 1
  evidence; route deliver; delivery 'deploy (dev)'
  expect 1 close "$SLUG" shipped 'detail after the target'; contains 'or deploy (found "deploy (dev)")'
  case "$OUTPUT" in *'")deploy'*|*'"deploy (dev)"deploy'*) fail "Target repeated: $OUTPUT";; esac
  ok 'an intent or evidence Target error quotes what it found once and points intent detail to a Note line'
}
run_regressions() {
  case "$1" in
    stop) regression_stop;; scenarios) regression_scenarios;; delivery) regression_delivery;; review) regression_review;; other) regression_other;;
    init) regression_init;; ultra) regression_ultra;; round2-[abcde]) regression_round2 "${1#round2-}";; round3) regression_round3;;
    repos) regression_repos;; cells) regression_cells;; paths) regression_paths;; uncommitted) regression_uncommitted;;
    nested) regression_nested;; interrupt) regression_interrupt;; scoped) regression_scoped;; fingerprint) regression_fingerprint;; optin) regression_optin;;
    reposflag) regression_reposflag;; carry) regression_carry;; target) regression_target;;
    all) regression_stop; regression_scenarios; regression_delivery; regression_review; regression_other; regression_init; regression_ultra
      for round2 in a b c d e; do regression_round2 "$round2"; done; regression_round3
      regression_repos; regression_cells; regression_paths; regression_uncommitted; regression_nested; regression_interrupt; regression_scoped; regression_fingerprint; regression_optin
      regression_reposflag; regression_carry; regression_target;;
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
# The e2e adapter is self-contained: vendored guide with its license, a pinned VERSION, a runnable updater.
A=$KIT/adapters/e2e
for f in README.md VERSION update.sh vendor/e2e-skill/SKILL.md vendor/e2e-skill/LICENSE vendor/e2e-skill/NOTICE templates/e2e.config.ts templates/session.setup.e2e.ts templates/scenario.e2e.ts templates/popup-bridge.ts; do assert_file "$A/$f"; done
awk -F': *' '$1=="e2e"&&$2~/^[0-9]+\.[0-9]+\.[0-9]+$/{ok=1}END{exit !ok}' "$A/VERSION" || fail 'adapters/e2e/VERSION has no pinned e2e version'
bash "$A/update.sh" --help > "$TMP/update-help" || fail 'adapters/e2e/update.sh --help failed'
ok 'e2e adapter: vendored guide, license, pinned version, templates, updater help'
printf 'PASS: %s checks\n' "$COUNT"
