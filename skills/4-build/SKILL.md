---
name: sdlc-build
description: "Plan execution with fresh-context verification and triaged fix loop. Triggers: plan gate approved."
---

# Stage 4: Build

Goal: execute the plan and verify each step. Run checks during implementation,
not only at the end.

Heartbeat: on entry, at every plan step, and at every fix-loop round,
overwrite `.sdlc/work/<slug>/progress.md` with one line —
`build <n>/<m> · <doing what> · <ISO timestamp>`, n/m counting plan.md's
Order of work — and update it before each dispatch (AGENTS.md rule 9).

## Before you start

1. Run `gates/check-gate.sh plan .sdlc/work/<slug>/plan.md`. STOP if closed.
   Micro-track features (intent.md `Track: micro`) have no spec or plan:
   check `gates/check-gate.sh intent .sdlc/work/<slug>/intent.md` instead,
   and treat intent.md's success criteria as the plan.
2. Read plan.md and spec.md (micro: intent.md). Read
   `.sdlc/memory/POLICY.md`, `.sdlc/memory/INDEX.md`,
   `.sdlc/memory/DOMAIN.md`, and the feature's `harvest.md` if present;
   open lesson files whose tags match the current task.
3. **Brownfield: capture the regression baseline before editing.** Run the
   baseline commands from plan.md and save output to
   `.sdlc/work/<slug>/baseline.txt`. Without a baseline, you cannot prove that
   existing behavior stayed unchanged.

## Execute

- Follow plan.md's order. If reality differs, record a small deviation in
  `.sdlc/work/<slug>/deviations.md` and continue. Create the file from
  `templates/deviations.md` on first use — its numbered lines are the cap
  counters (AGENTS.md rule 5).
  Keep the approved plan.md byte-identical so its gate stays open. For a
  structural deviation such as different files or a different approach, STOP,
  tell the human, and re-gate the plan. When the deviation's root cause is a
  factual error in spec.md (wrong data shape, wrong AS-IS claim), re-gate the
  spec first — with the evidence — then the plan: an artifact that no longer
  says what the human approved needs a fresh ask (AGENTS.md rule 3).
- **Deviation cap: five small deviations per feature.** The sixth means the
  plan no longer describes the work: re-gate the plan (counts against the
  re-gate cap below) or STOP. Small deviations are individually cheap and
  collectively a rewrite.
- **Micro track:** any structural surprise upgrades to full — STOP, rewrite
  the Track line, and write spec.md (skills/1-intent).
- **Re-gate cap: two per stage, per feature.** A third re-gate request for
  the same stage means stage 1 got the facts wrong, not that the plan needs
  another pass. STOP, show the human the trail (deviations.md + the
  re-approval history), and let them choose: back to intent with the new
  facts, or close dead-end with a lesson. Log every re-gate as a line in
  deviations.md the moment it happens — counters live on disk, not in
  context (AGENTS.md rule 5 "Caps survive dispatch"). Endless spec↔plan
  churn is a finding about intent, never progress.
- A check that must fail the build must fail it synchronously (direct throw,
  sync IO, or top-level await). An unawaited promise is not a gate. It depends
  on environment behavior and may finish too late.
- When a plan adds or changes browser E2E or a source-analysis checker, read
  [`test-authoring.md`](test-authoring.md) before editing it and apply every
  relevant rule.
- After each step, run test + lint from `.sdlc/config.md`. A failing test is
  information about the code: fix the code and keep the test intact until it
  passes honestly (catch yourself reaching for the test file instead? record
  a lesson).
- **Record each mistake immediately** in the feature's
  `.sdlc/work/<slug>/harvest.md` (INDEX.md, DOMAIN.md, and lessons/ are
  written only at close — AGENTS.md rule 4). This includes your mistakes,
  plan mistakes, and surprises in the codebase. Use the skill 6 lesson
  format so a future run can avoid it.
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
   declined finding. Record both lists — and the round number — in
   deviations.md; ship copies them into evidence.md.
2. Fix only accepted findings. Do not add unrelated scope. A
   finding that implies new scope goes to the human, not into the fix.
3. Dispatch a new fresh-context checker with two questions. Is each named
   finding resolved? Did the fix create a defect in affected code?
4. Stop after three rounds. If round 3 still fails, show the evidence to the
   human. Do not run a fourth round without new information.

## Exit

There is no gate script here. Stage 5 evidence review is the build gate.
Dispatch ship (`skills/5-ship/SKILL.md`) as a subagent task, passing only the
slug (AGENTS.md rule 5).
