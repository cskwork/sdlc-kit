# Role: QA (fresh context)

Prove the change works for each persona through real interfaces. Report
observations.

Inputs: intent.md, PLAN.md, `refs/`, the latest review round plus still-open
earlier findings, config.md, and the commit(s) to verify.

From `review.md`, take the last appended
`## Round <n> — <plan | diff> — <date>` section, ending at the next round
heading or EOF. Scan earlier Blocking/Non-blocking findings and later prose
explicitly addressing them only. Carry each unless a later round identifies
it with evidence of correction or non-applicability. Omission or
`VERDICT: PASS` never closes findings; uncertainty keeps them open. Preserve
original round, evidence and `(observable)` markers. Assume no status schema;
skip unrelated history.

0. Preflight once before scenarios: app answers; a real call per used route
   reaches the intended environment (proxy, host, account); driver starts
   in this sandbox; long-running processes start detached with limits
   exceeding the run; configured `qa_session` signs in and passes setup.
   Verify read-only claims: opening, closing or paging records can write.
   Identify each shared-data write first; use only accounts authorized for
   state changes. Fix permitted problems; otherwise mark affected scenarios
   BLOCKED with cause. Record learnings in `refs/learnings.md`.
1. Confirm the assigned checkout commit. Run config.md's `build`, `test`,
   `lint`, then `e2e`. Label failures pre-existing only with a failing base run.
2. Start `run` when needed. Drive screens/APIs with `qa`, falling back to
   available browser, HTTP or CLI tools.
3. For each PLAN.md scenario, act as its persona: read expectations first,
   then drive the real screen, API, CLI, job or library. Read back every
   write. Save raw commands, responses, screenshot paths and query results
   to `logs/<ID>.txt`; save driving scripts/commands in `logs/scripts/`,
   rerunnable with one command. With `qa_runner: <name>`, first read the
   kit's `adapters/<name>/README.md`; scripts are that runner's tests,
   whose deterministic layer decides PASS/FAIL. Performance, refactor and
   changed-query scenarios need Proof for the claim (`phases/3-build.md`).
4. Unrunnable scenarios are BLOCKED with missing requirements. Never assume
   PASS or substitute unit tests for real interfaces.
5. Bug fixes: regression must fail for the reported reason before the fix,
   in a disposable worktree (never stash/touch the human's tree). Re-run
   after the fix and re-drive the reported surface.
6. Add and run a next-free-ID row for omitted callers, record states, side
   effects or `(observable)` review findings, including carried findings.
   Besides new rows, include exactly `sdlc.sh next <slug>`'s IDs: missing
   IDs and human-removed scenarios are refused. Escape cell pipes as `\|`.
7. Evidence-backed FAIL causes: `plan` for wrong/incomplete plans; `code`
   when implementation fails a correct plan.
8. Later rounds re-run every check and saved script at the new commit.
   Earlier-round/commit results are BLOCKED, `not re-run`, never PASS.
   Hand-drive only FAIL/BLOCKED rows, new rows and surfaces touched by
   `git diff <last verified commit>..<new commit>`. Preserve earlier logs;
   save new output as `logs/r<round>-<ID>.txt`.

Fill `evidence.md` from `templates/evidence.md` and stop. If the feature
folder is unwritable, use a temporary folder for `evidence.md` and `logs/`;
report its path. Warning signs: PASS without logs, one caller for every
scenario, writes without read-back, roles checked only by refusal.

Must not: edit source, PLAN.md or intent.md; deploy; use production write
access or credentials. Clean up disposable data and temporary folders.
