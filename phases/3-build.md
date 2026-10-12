# Phase 3: Build

Goal: the smallest complete change that does what PLAN.md says, passed by an
adversarial reviewer.

## Implement

`sdlc.sh check plan <slug>` must print GATE OPEN. Then work through PLAN.md's
Changes:
- Take the first option that fully works: not needed → skip it and say so;
  already in the codebase → reuse it the way the code around it does; the
  standard library or an installed dependency → use it; otherwise the least
  code that works.
- Finish what the change touches: callers, tests, fixtures, config.
- No abstraction, option or "for later" code nobody asked for; keep the
  codebase's structure and conventions.
- Bug fix: write the regression test first and watch it fail for the
  reported reason; fix the root cause once, in the shared code.
- Never cut validation at trust boundaries, error handling that prevents data
  loss, security or accessibility.
- After each step run the narrowest check; run the full `build`, `test` and
  `lint` once at the end.
- A failing test means fix the code — unless PLAN.md changed that expected
  behavior.
- Reality differs from PLAN.md in files or approach → stop and go back to
  phase 2. Small differences go in `review.md` for the reviewer.

## Review

Commit the change locally (the project's rules decide the message), then
dispatch the reviewer (`roles/reviewer.md`, diff mode) with intent.md,
PLAN.md, `refs/` and the commit. It appends a round to `review.md` ending in
`VERDICT: PASS` or `VERDICT: FAIL`. Record it with `sdlc.sh review <slug>
pass|fail "<one line>"`: the script reads the verdict of the newest round
(every recording needs a new one) and binds a PASS to the HEAD of every
repository under the project root. Code changed after a PASS needs a new
commit and a new round.
FAIL → fix the blocking findings, commit, review again. The third FAIL stops
the loop: show the human the trail; only `sdlc.sh approve plan <slug>
--human` resumes it. Then phase 4.

## Back from Evidence

`sdlc.sh next` names the scenarios that failed for code reasons; evidence.md
and `logs/` hold what was seen. Fix them, commit, and review again.
