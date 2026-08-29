---
name: sdlc-build
description: "Plan execution with fresh-context verification and triaged fix loop. Triggers: plan gate approved."
---

# Stage 4: Build

Goal: execute the plan and verify each step. Run checks during implementation,
not only at the end.

## Before you start

1. Run `gates/check-gate.sh plan .sdlc/work/<slug>/plan.md`. STOP if closed.
2. Read plan.md and spec.md. Read `.sdlc/memory/INDEX.md` and
   `.sdlc/memory/DOMAIN.md`; open lesson files whose tags match the current
   task.
3. **Brownfield: capture the regression baseline before editing.** Run the
   baseline commands from plan.md and save output to
   `.sdlc/work/<slug>/baseline.txt`. Without a baseline, you cannot prove that
   existing behavior stayed unchanged.

## Execute

- Follow plan.md's order. If reality differs, record a small deviation in
  `.sdlc/work/<slug>/deviations.md` and continue. Create the file on first use.
  Keep the approved plan.md byte-identical so its gate stays open. For a
  structural deviation such as different files or a different approach, STOP,
  tell the human, and re-gate the plan.
- A check that must fail the build must fail it synchronously (direct throw,
  sync IO, or top-level await). An unawaited promise is not a gate. It depends
  on environment behavior and may finish too late.
- **Browser-E2E authoring rules** (each earned by a recorded lesson):
  - Settlement: waiting for a selector shared by two routes proves nothing.
    Mark the old node (e.g. `data-e2e-stale`), then wait for the NEW render's
    distinguishing proof — exact expected heading text plus focus set by the
    router's completion path. No retries, no sleeps.
  - Existing UI is not proof a replacement request settled. Wait for the NEW
    request to complete and for its distinguishing DOM before asserting.
  - No backticks inside Go raw strings. Embedded browser JavaScript uses
    string concatenation.
  - A Tab walk starts at the document origin only after focusing `body` with
    a temporary `tabindex` then removing it; `activeElement.blur()` resets
    nothing.
  - Home-grown checkers (catalogue parsers, parity scripts) must fail closed:
    accept the full source shape (quoted AND identifier keys, comments,
    template literals), validate with a real parser, and prove the failure
    path with a synthetic mismatch.
- After each step, run test + lint from `.sdlc/config.md`. A failing test is
  information about the code: fix the code and keep the test intact until it
  passes honestly (catch yourself reaching for the test file instead? record
  a lesson).
- **Record each mistake immediately.** This includes your mistakes, plan
  mistakes, and surprises in the codebase. Use the skill 6 lesson format so a
  future run can avoid it.
- Independent parallel work: use worktrees/subagents if your harness supports
  them, one writer per file set. Otherwise, sequential is fine.
- Tools: you may use build/test/dev tools freely. You must NOT use deploy or
  release tools or production systems and credentials. Shipping belongs to
  Stage 5, not the build step. When your harness can restrict subagent tools, copy
  each role's "Must not" list into the dispatch.

## Verify (fresh context, every time)

When all steps are done and local checks are green, dispatch a fresh-context
verifier (`roles/verifier.md`) with: plan.md, spec.md, changed-file list, and
`.sdlc/config.md` commands (full dispatch contract per AGENTS.md rule 5). It
runs the app/tests itself and reports evidence. You do not verify your own
work in your own context.

Verifier or adversary findings enter the **fix loop**:

1. Mark every finding **accepted** or **declined**. Give a reason for each
   declined finding. Record both lists in deviations.md or evidence.md.
2. Fix only accepted findings. Do not add unrelated scope. A
   finding that implies new scope goes to the human, not into the fix.
3. Dispatch a new fresh-context checker with two questions. Is each named
   finding resolved? Did the fix create a defect in affected code?
4. Stop after three rounds. If round 3 still fails, show the evidence to the
   human. Do not run a fourth round without new information.

## Exit

There is no gate script here. Stage 5 evidence review is the build gate. Proceed
to `skills/5-ship/SKILL.md` in a fresh session, passing only the slug.
