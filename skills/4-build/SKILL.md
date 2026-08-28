---
name: sdlc-build
description: Stage 4 — execute the plan with continuous verification, fresh-context verifier, triaged fix loop. Triggers: plan gate approved.
---

# Stage 4: Build

Goal: the plan executed, continuously verified — evals woven through
implementation, not a QA gate at the end.

## Before you start

1. `gates/check-gate.sh plan .sdlc/work/<slug>/plan.md` — STOP if closed.
2. Read plan.md and spec.md. Read `.sdlc/memory/INDEX.md`; open matching lessons.
3. **Brownfield: capture the regression baseline NOW** — run the baseline
   commands from plan.md, save output to `.sdlc/work/<slug>/baseline.txt`.
   No baseline = no way to prove you didn't break anything.

## Execute

- Follow plan.md's order. Reality differs from plan? Small deviation: note it
  in plan.md's **Deviations** section and continue. Structural deviation
  (different files, different approach): STOP, tell the human, re-gate the plan.
- A check that must fail the build must fail it synchronously (direct throw,
  sync IO, or top-level await). An unawaited promise is not a gate — it fails
  only through environment defaults, which is a race, not a contract.
- After each step, run test + lint from `.sdlc/config.md`. A failing test is
  information about the code: fix the code and keep the test intact until it
  passes honestly (catch yourself reaching for the test file instead? record
  a lesson).
- **When you hit a mistake — yours, the plan's, or a surprise in the codebase —
  record it immediately** as a lesson (format in skill 6). This is how the
  same mistake never happens twice.
- Independent parallel work: use worktrees/subagents if your harness supports
  them, one writer per file set. Otherwise, sequential is fine.
- Tools: you may use build/test/dev tools freely. You must NOT use deploy or
  release tools, or production systems/credentials — shipping is stage 5's
  gate, not a build step. When your harness can restrict subagent tools, copy
  each role's "Must not" list into the dispatch.

## Verify (fresh context, every time)

When all steps are done and local checks are green, dispatch a fresh-context
verifier (`roles/verifier.md`) with: plan.md, spec.md, changed-file list, and
`.sdlc/config.md` commands (full dispatch contract per AGENTS.md rule 5). It
runs the app/tests itself and reports evidence. You do not verify your own
work in your own context.

Verifier or adversary findings enter the **fix loop**:

1. Triage every finding into **accepted** (will fix now) or **declined**
   (with the reason). Both lists are recorded — in plan.md's Deviations or
   the evidence file. Declined is a record, not an omission.
2. The fix touches ONLY the accepted findings — no scope beyond them. A
   finding that implies new scope goes to the human, not into the fix.
3. Re-dispatch a NEW fresh-context checker with exactly two questions:
   is each named finding resolved, and is there a new defect inside the
   fix's blast radius?
4. Max 3 rounds. Round 3 still red → STOP and escalate to the human with
   the receipts; a fourth attempt without new information repeats the third.

## Exit

No gate script here — the build's gate is stage 5's evidence review. Proceed
to `skills/5-ship/SKILL.md` in a fresh session, passing only the slug.
