---
name: sdlc-build
description: "Execute the approved full plan or compact intent, with fresh-context verification and a triaged fix loop. Triggers: plan gate approved, or approved compact intent."
---

# Stage 4: Build

Goal: execute the plan and verify each step. Run checks during implementation,
not only at the end.

Heartbeat throughout: AGENTS.md rule 9.

## Before you start

1. Run `gates/check-gate.sh plan .sdlc/work/<slug>/plan.md`. STOP if closed.
   Compact-route features (intent.md `Track: compact`) have no spec or plan
   and never need one: check
   `gates/check-gate.sh intent .sdlc/work/<slug>/intent.md` instead, and
   treat intent.md's Compact route section (Files · Proof · Risk · Baseline · Delivery
   target) plus its success criteria as the plan.
2. Read plan.md and spec.md (compact route: intent.md), and memory
   (AGENTS.md rule 4).
   On resume, compare the current branch, source changes, and runtime with the
   recorded state before continuing. Re-run the smallest affected smoke check
   when they differ; check completed external effects before retrying them.
   If recovering attempt counts or external effects, read the
   [checkpoint procedure](../../docs/automation.md#6-checkpoint-retries-pause-and-resume).
3. **Brownfield: capture the regression baseline before editing.** Run the
   baseline commands from plan.md (compact route: intent.md's Baseline line)
   and save output to
   `.sdlc/work/<slug>/baseline.txt`. Without a baseline, you cannot prove that
   existing behavior stayed unchanged. A pin or a before-measurement
   (AGENTS.md rule 6) is captured here too. With a `.sdlc/verify.md` recipe, also
   run `tools/verify.sh baseline <slug>` once the new tests exist, and again
   after editing them.

## Execute

- **First runnable slice.** Prove the planned bootstrap and one real action
  before expanding greenfield work; on brownfield work, drive the existing
  affected path before editing. Record a missing runtime explicitly and use
  the existing blocker/gap rules. A skeleton that only builds has not yet
  proved the product path.
- Follow plan.md's order. If reality differs, record a small deviation in
  `.sdlc/work/<slug>/deviations.md` and continue. Create the file from
  `templates/deviations.md` on first use — its numbered lines are the cap
  counters (AGENTS.md rule 5).
  Do not edit plan.md to match reality: the plan gate binds its content, so an
  edit closes the gate and check-gate.sh will say so (AGENTS.md rule 2). Small
  deviations belong in deviations.md. For a
  structural deviation such as different files or a different approach,
  re-gate the plan under AGENTS.md rule 3 before continuing. When its cause is a
  factual error in spec.md (wrong data shape, wrong AS-IS claim), re-gate the
  spec first — with the evidence — then the plan. Re-review changed artifacts;
  rule 3 decides whether approval is human or waived, and authority still bounds scope.
- **Deviation cap: five small deviations per feature.** On the sixth,
  full-route work re-gates the plan (counts against the re-gate cap below)
  or STOPs. Compact work STOPs and asks the human to reassess intent/route,
  at every lazymode. Small deviations are individually cheap and collectively a rewrite.
- **Compact route:** a surprise breaking compact eligibility upgrades to full
  (skills/1-intent "Which route"). STOP, rewrite Track, re-approve intent,
  then write spec.md. Small deviations preserving every criterion stay compact.
- **Re-gate cap: two per stage, per feature.** A third re-gate request for
  the same stage means stage 1 got the facts wrong, not that the plan needs
  another pass. STOP, show the human the trail (deviations.md + the
  re-approval history), and let them choose: back to intent with the new
  facts, or close dead-end with a lesson. Log every re-gate as a line in
  deviations.md the moment it happens — counters live on disk, not in
  context (AGENTS.md rule 5 "Caps survive dispatch"). Endless spec↔plan
  churn is a finding about intent, never progress.
- **Bug fix: the failing test comes first.** Before touching the fix, add
  the regression test (AGENTS.md rule 6; the one stage 6 drafted, if any)
  and watch it fail on the current code for the reported reason. Save that
  output under `scratch/`; ship quotes its deciding lines in evidence.md's
  Bug proof. A test you never saw fail is not proof. The fix carries only
  what the confirmed mechanism justifies; "might also help" is a hypothesis.
- **Preserve accepted inputs.** Turn stage 1's caller and stored-record
  evidence into focused executable checks before changing input handling.
  Exercise applicable missing, empty, null, wrong-type and unknown values
  through the real surface; preserve valid legacy results and check invalid
  cases for safe refusal, no crash and no partial state. Record an inapplicable
  case with its domain reason. A fallback or a new required field is correct
  only when that evidence supports its meaning; no blanket patch recipe.
- **With a recipe, write the checks with the code** in
  `.sdlc/work/<slug>/verify.md` (templates/verify-feature.md): one `check:`
  per requirement variant and per reach scenario plan.md picked
  (roles/verifier.md), new tests `must-fail-on-base`
  where allowed, a `gap:` line only for what truly cannot be checked.
  `tools/verify.sh coverage <slug>` lists no uncovered id; fix a `vacuous` test
  (or `test_paths:`) until it fails at base for the reason it tests.
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
  `.sdlc/work/<slug>/harvest.md` (AGENTS.md rule 4). This includes your mistakes,
  plan mistakes, and surprises in the codebase. Use the skill 6 lesson
  format so a future run can avoid it.
- Independent parallel work: use worktrees/subagents if your harness supports
  them, one writer per file set. Otherwise, sequential is fine.
- Tools: you may use build/test/dev tools freely. You must NOT use deploy or
  release tools or production systems and credentials. Shipping belongs to
  Stage 5, not the build step. When your harness can restrict subagent tools, copy
  each role's "Must not" list into the dispatch.

## Verify (fresh context, selected by approved Track)

When all steps are done and the full configured suite is green over the final
state, dispatch with intent.md and its `Refs:` origin, plan.md and spec.md
(compact: intent.md only), summary.md, changed-file list, `.sdlc/config.md`,
current proof and `baseline.txt` when present (AGENTS.md rule 5's full dispatch
contract):

- **Full:** three `roles/verifier.md` contexts, one lens each, in parallel.
  Ship dispatches a separate fresh adversary.
- **Approved compact:** one fresh reviewer gets `roles/verifier.md` AND
  `roles/adversary.md`, applies all three complete lens sections, then the
  complete adversarial diff checklist once on the same final source. Return
  three named lens reports with VERDICT lines plus the adversary report and
  per-file rows. Ship preserves these reports; unchanged source and inputs
  need no duplicate review dispatch.
  Log each adversarial diff pass in evidence.md's existing two-round counter,
  even when performed during build; combining roles never resets either cap.

Name the lenses **E2E**, **Side effects**, and **Intent match**; each applies
its complete role section. AGENTS.md rules 5/6 govern independence, missing
environments and proof. With a `.sdlc/verify.md` recipe the E2E lens runs
`tools/verify.sh run <slug>` unless current proof already covers that exact
source, recipe and inputs; independently inspect its deciding logs and
expectations. Quote the receipt's deciding lines in evidence.md. Changes to
source, recipe or upstream review inputs need fresh affected proof and final
diff review; keep live gate digest checks intact. Preserve reviewer provenance
under the role's Report contract, including explicit unknown identifiers.

A finding from any lens — a failing flow, a data skew, a missing origin
detail — enters the **fix loop**:

1. Mark every finding **accepted** or **declined**, with a reason for each
   declined one. Write the round line in deviations.md now — lens, both lists,
   `re-check: pending` (templates/deviations.md); ship copies it into
   evidence.md.
2. Fix only accepted findings. A finding that implies new scope — an origin
   detail intent.md never carried, a data model change — goes to the human as
   a decision, not into the fix.
3. Re-dispatch the lenses that had findings, plus E2E whenever code changed
   (compact: the combined reviewer, including a new final diff check),
   with two questions: is each named finding resolved, and did the fix create
   a defect in affected code? Update the round line's `re-check:` in place:
   `resolved`, or `open: <what>` and the next round begins.
4. **Cap: three rounds.** A round-3 re-check still `open` STOPs the loop:
   show the human the evidence and the deviations.md trail. No round 4 —
   `tools/auto.sh` reads the round lines and reports either as
   `fixloop.exhausted`, needs-human at every lazymode.

## Exit

There is no gate script here. Stage 5 evidence review is the build gate.
Continue with ship (`skills/5-ship/SKILL.md`); evidence assembly stays with
the author. Pass the current reports and source/input identities so ship can
retain valid proof without repeating checks or the compact diff review.
