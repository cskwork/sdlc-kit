# Phase 3: Build

Goal: the smallest complete change that does what PLAN.md says, passed by an
adversarial reviewer.

## Implement

`sdlc.sh check plan <slug>` must print GATE OPEN. Then work through PLAN.md's
Changes:
- Take the first option that fully works: not needed → skip it and say so;
  already in the codebase → reuse it as nearby code does;
  standard library or installed dependency → use it; otherwise the least
  code that works.
- Finish what the change touches: callers, tests, fixtures, config.
- No abstraction, option or "for later" code nobody asked for; keep the
  codebase's structure and conventions.
- Bug fix: write the regression test first and watch it fail for the
  reported reason, keeping the output in `logs/`; fix the root cause once,
  in the shared code.
- A new or changed test for new behavior: run it once where it must fail, on
  the base commit in a disposable worktree (never stash or touch the human's
  tree) or, for a new symbol, with the behavior disabled, output in `logs/`;
  it must fail on its assertion, not a missing symbol or compile error.
- **Proof for the claim**, only for a numeric performance or unchanged-behavior
  (refactor) claim; base run before the first edit, output in `logs/`.
  - *Performance*: repeated base and after samples of one fixed, realistic
    workload, command and environment, with median, spread, errors and work
    done; insufficient samples or a difference within spread do not establish
    improvement.
  - *Refactor*: behavior checks pass before and after, and one fails on a
    behavioral assertion, not compilation, when deliberately broken in a disposable
    worktree; tests alone do not replace the real-interface run, nor do lint
    or typecheck.
  - *Optimization loop*, only on the human's request: an agreed target and
    effort limit; per round one hypothesis, change and measurement, kept or
    reverted alone.
- Never cut validation at trust boundaries, error handling that prevents data
  loss, security or accessibility.
- After each step run the narrowest check; the full `build`, `test` and
  `lint` once at the end.
- A failing test means fix the code — unless PLAN.md changed that expected
  behavior.
- Two failed fixes for one failure (test, review finding or scenario) that
  share a premise → test that premise, recording it and the result in
  `refs/repro.md`, before the next fix.
- Reality differs from PLAN.md in files or approach → stop and go back to
  phase 2. Small differences go in `review.md` for the reviewer.

## Review

Commit locally (the project's rules decide the message) and dispatch the
reviewer (`roles/reviewer.md`, diff mode); where every commit needs the
human's approval, review the uncommitted change instead. Record its verdict
with `sdlc.sh review <slug> pass|fail "<one line>"`: the script reads the
newest `review.md` round (each recording needs a new one) and binds a PASS to
the HEAD of every repository in `--repos "<path> ..."` (before the note), else
config `repos:`, else under the project root (name the touched repositories
when the root holds many). `score` and `close` compare only repositories named
on evidence `Commit` lines; each Commit must be that HEAD. For an uncommitted
review, `sdlc.sh review <slug> pass --uncommitted "<one line>"` also binds the
working tree of each repository with uncommitted changes (non-ignored files,
tracked or not, excluding the store and untracked repositories nested inside
it; if git cannot read it, the PASS binds HEAD alone and says so). Each Commit
must then be or descend from the reviewed HEAD, hold the reviewed tree inside
its Commit path, and change nothing outside that path the reviewed tree lacks;
uncommitted changes outside every Commit path do not count. Reverting or
stashing the change, amending or rebasing the reviewed HEAD, or changing code
after a PASS needs a new round; rewording a commit made on top does not.
Recording hashes those files into the object store (not the index): ignore
large or secret files first.
FAIL → fix the blocking findings, commit, review again. A blocking diff
finding a screen, API, job or log could show is a bug fix: its
regression test first, failing on the FAILed commit for the finding's reason,
then the fix; if no test can show it, the fix's commit message (or, for an
uncommitted review, the review request) says why.
Plan-review FAILs and findings nothing can observe (wording,
docs, structure) need no test. The third FAIL stops
the loop (rule 6). Then phase 4.

## Back from Evidence

`sdlc.sh next` names the scenarios that failed for code reasons; evidence.md
and `logs/` hold what was seen. Each is a bug fix as above: regression test
first, then fix, commit, and review again.
