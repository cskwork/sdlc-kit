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
   Compact-route features (intent.md `Track: compact`, older spelling
   `micro`) have no spec or plan and never need one: check
   `gates/check-gate.sh intent .sdlc/work/<slug>/intent.md` instead, and
   treat intent.md's Compact route section (Files · Proof · Risk · Delivery
   target) plus its success criteria as the plan.
2. Read plan.md and spec.md (compact route: intent.md). Read
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
  Do not edit plan.md to match reality: the plan gate binds its content, so an
  edit closes the gate and check-gate.sh will say so (AGENTS.md rule 2). Small
  deviations belong in deviations.md. For a
  structural deviation such as different files or a different approach, STOP,
  tell the human, and re-gate the plan. When the deviation's root cause is a
  factual error in spec.md (wrong data shape, wrong AS-IS claim), re-gate the
  spec first — with the evidence — then the plan: an artifact that no longer
  says what the human approved needs a fresh ask (AGENTS.md rule 3).
- **Deviation cap: five small deviations per feature.** The sixth means the
  plan no longer describes the work: re-gate the plan (counts against the
  re-gate cap below) or STOP. Small deviations are individually cheap and
  collectively a rewrite.
- **Compact route:** any structural surprise upgrades to full — STOP, rewrite
  the Track line, re-approve intent (the approval froze the compact verdict),
  and write spec.md (skills/1-intent).
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
- **Check narrowly per step, fully once.** After each step run the smallest
  check that covers what that step touched — the one test file, the one
  lint path, the one command from `.sdlc/config.md` scoped to the change.
  Run the full configured suite ONCE, at the end, over the final state that
  ship will review. Re-run it only after a later change or a failure; a
  green full suite re-run over unchanged code proves nothing it did not
  already prove.
- A failing test is information about the code: fix the code, not the test
  (catch yourself reaching for the test file instead? record a lesson).
  **When the expected behavior itself changed on purpose**, the test changes
  with it — record in deviations.md which expectation changed, the line in
  spec.md or intent.md that authorizes it, and the evidence that the new
  expectation is the correct one. What is forbidden is preserving a wrong
  expectation, and equally, editing a test to make a real failure quiet.
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

## Verify (fresh context, three lenses in parallel)

When all steps are done and the full configured suite is green over the final
state, dispatch `roles/verifier.md` three times — one lens each, fresh context
each, in parallel where the harness allows (AGENTS.md rule 5; full dispatch
contract) — with intent.md and its `Refs:` origin, plan.md and spec.md (compact
route: intent.md only), the changed-file list, `.sdlc/config.md`, and
`baseline.txt` when it exists:

1. **E2E** — the change works through the real interface; a bug fix carries
   its proof chain (AGENTS.md rule 6).
2. **Side effects** — AS-IS → TO-BE beyond the requirement: baseline, untouched
   items, data consistency across every producer and consumer of the shapes
   the diff touches.
3. **Intent match** — the build read back against the ticket or 기획서 the
   request came from: covered, missing, beyond.

You do not verify your own work in your own context; a harness that cannot
give a fresh context records the gap in evidence.md ("no independent
verification available: <reason>"). A lens with no environment reports NOT
VERIFIED, never a pass. With a `.sdlc/verify.md` recipe the E2E lens runs
`tools/verify.sh run <slug>`; quote the receipt's deciding lines in evidence.md
and re-run it after any code or recipe change (it goes `stale`).

A finding from any lens — a failing flow, a data skew, a missing origin
detail — enters the **fix loop**:

1. Mark every finding **accepted** or **declined**, with a reason for each
   declined one. Write the round line in deviations.md now — lens, both lists,
   `re-check: pending` (templates/deviations.md); ship copies it into
   evidence.md.
2. Fix only accepted findings. A finding that implies new scope — an origin
   detail intent.md never carried, a data model change — goes to the human as
   a decision, not into the fix.
3. Re-dispatch the lenses that had findings, plus E2E whenever code changed,
   with two questions: is each named finding resolved, and did the fix create
   a defect in affected code? Update the round line's `re-check:` in place:
   `resolved`, or `open: <what>` and the next round begins.
4. **Cap: three rounds.** A round-3 re-check still `open` STOPs the loop:
   show the human the evidence and the deviations.md trail. No round 4 —
   `tools/auto.sh` reads the round lines and reports either as
   `fixloop.exhausted`, needs-human at every lazymode.

## Exit

There is no gate script here. Stage 5 evidence review is the build gate.
Continue with ship (`skills/5-ship/SKILL.md`); dispatch it to a subagent when
a fresh context helps the review, passing only the slug (AGENTS.md rule 5).
