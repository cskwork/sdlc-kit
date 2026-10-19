# v2.7.0 — keep the contrast: failing tests and dated facts

Three rules make a defect, a test and a fact each carry the run that proves
it. A reviewer's caught defect becomes a test, a new test is seen failing
once, and a fact in `knowledge` names the commit it was verified at.

## Why

- Across three projects, 17 features ran v2 reviews; 11 had at least one
  FAIL verdict, 26 `VERDICT: FAIL` rounds in total, 14 on plans and 12 on
  diffs. Only Evidence's code FAILs had to become regression tests. Of the 10
  diff-review findings that were a code defect or a weak test, the next round
  cited a new or changed test aimed at the finding for 3 and not for 7
  (counted from `review.md` citations, not from the test files); for the 7
  the defect lived on only as prose in `review.md`.
- v2.5.1's false e2e pass (a URL assertion matching the address before a
  client-side redirect) was found only by a negative control. One project
  already proved its tests that way: head PASS 12/12, base FAIL 12/12.
- Facts in `knowledge` cite files and lines but not the commit they were
  verified at, so a scout could cite one as AS-IS after the code changed.
- The recurring FAIL categories across features — missed consumers (5
  features), intent or policy mismatches (7), scenario gaps (4), code defects
  (4), weak tests (3) — are each already targeted by an existing reviewer or
  scout rule. A lesson store would only repeat them.

The idea came from reviewing a proposal built on Harness² (arXiv
2610.14224, "Recursive Agent Harnessing for an Open World", 2026-10-09),
which keeps a lesson only when an execution contrast supports it. These
rules keep that contrast in the project's own tests and on the fact itself.
The proposal's lesson store, context packer and auto-promotion scripts were
not adopted: v2.0.0 removed that kind of structure.

## Changes

- **A blocking diff finding that shows a defect becomes a test.** In Build,
  a blocking diff-review finding that a screen, API, job or log could show
  is fixed like a bug fix: its regression test first, failing on the
  FAILed commit for the finding's reason, then the fix. If no test can show
  it (no test runner, a production-only symptom), the fix's commit message
  (or, for an uncommitted review, the review request) says why. Plan-review FAILs and findings nothing can observe (wording,
  docs, structure) are excluded. The reviewer blocks an observable blocking
  diff finding left untested and unexplained. Non-blocking `(observable)`
  findings still become QA scenarios, as in v2.4.0.
- **A new test for new behavior is seen failing once.** Build runs each new
  or changed test for new behavior once where it must fail: on the base
  commit in a disposable worktree (never stashing or touching the human's
  tree, as QA already does), or, for a new symbol, with the behavior
  disabled. The output goes to `logs/`. It must fail on its assertion;
  "symbol not found" or a compile error does not count. The reviewer now
  receives `logs/` and blocks a new-behavior test with no recorded assertion
  failure. SKILL.md lists `logs/` among Build's writes.
- **Facts carry the commit they hold at.** Evidence writes each fact that
  rests on code into `knowledge` with its file (path from the project root)
  and the delivered commit of that file's repository,
  `[verified: <file> @ <short sha>]`, re-checking the fact on that commit
  first when the file changed since the fact was checked (this change, a
  rebase or a merge), so a fact verified in Plan against older code is not
  stamped with the new commit. Before citing a
  code fact, a scout checks whether its file changed since that commit (in
  the file's repository, `git log --oneline <sha>.. -- <file>` prints
  anything); if it changed, or the fact has no commit, the scout re-checks it
  against the code or cites it as `[assumed: <why>]`. Running `git log` in
  the file's own repository makes this work for one repository or a root
  holding several. Facts not about code (policies, data) are not checked
  this way, and only facts a scout cites are checked; there is no list of
  watched paths and no cache.

No script change; existing records stay valid.

## Known limits

- Facts already in `knowledge` have no commit; each is re-checked whenever
  a scout cites it, until Evidence records it again with its commit.
- A fact that rests on several files carries one file; a change to another
  file it depends on is not caught.
- The plan load is at 2500 of 2500 words; the next rule for scouts,
  reviewer, plan or SKILL.md must replace words, not add them.
- Whether a finding could be observed is a judgment, as `(observable)`
  already is.
