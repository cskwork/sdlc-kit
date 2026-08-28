---
name: sdlc-build
description: Stage 4 — execute approved plan.md with continuous verification and fresh-context verifier. Use after the plan gate is approved.
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
- After each step, run test + lint from `.sdlc/config.md`. Fix code, never
  tests — a failing test is information about the code. Never weaken, skip, or
  delete a failing test to get green (record a lesson if you catch yourself trying).
- **When you hit a mistake — yours, the plan's, or a surprise in the codebase —
  record it immediately** as a lesson (format in skill 6). This is how the
  same mistake never happens twice.
- Independent parallel work: use worktrees/subagents if your harness supports
  them, one writer per file set. Otherwise, sequential is fine.

## Verify (fresh context, every time)

When all steps are done and local checks are green, dispatch a fresh-context
verifier (`roles/verifier.md`) with: plan.md, spec.md, changed-file list, and
`.sdlc/config.md` commands. It runs the app/tests itself and reports evidence.
You do not verify your own work in your own context.

- Verifier finds a gap → fix → dispatch a NEW verifier. Repeat until clean.

## Exit

No gate script here — the build's gate is stage 5's evidence review. Proceed
to `skills/5-ship/SKILL.md` in a fresh session, passing only the slug.
