---
name: sdlc-build
description: "Execute the approved full plan or compact intent, with fresh-context verification and a triaged fix loop. Triggers: plan gate approved, or approved compact intent."
---

# Stage 4: Build

Goal: execute the plan and verify each step. Run checks during implementation,
not only at the end.

Heartbeat throughout: AGENTS.md rule 9.

## Before you start

1. Run `gates/check-gate.sh plan .sdlc/work/<slug>/plan.md`; STOP if closed.
   Compact (intent.md `Track: compact`) has no spec or plan and never needs
   one: check `gates/check-gate.sh intent .sdlc/work/<slug>/intent.md`
   instead; intent.md's Compact route section (Files · Proof · Risk ·
   Baseline · Delivery target) plus its success criteria is the plan.
2. Read plan.md and spec.md (compact route: intent.md), and memory
   (AGENTS.md rule 4).
   On resume, compare the current branch, source changes, and runtime with the
   recorded state before continuing. Re-run the smallest affected smoke check
   when they differ; check completed external effects before retrying them.
   If recovering attempt counts or external effects, read the
   [checkpoint procedure](../../docs/automation.md#6-checkpoint-retries-pause-and-resume).
3. **Brownfield: capture the regression baseline before editing.** Run the
   baseline commands from plan.md (compact: intent.md's Baseline line) and
   save output to `.sdlc/work/<slug>/baseline.txt` — without it, unchanged
   existing behavior is unprovable. A pin or before-measurement (AGENTS.md
   rule 6) is captured here too. With a `.sdlc/verify.md` recipe, also run
   `tools/verify.sh baseline <slug>` once the new tests exist and after
   editing them.

## Execute

- **First runnable slice.** Prove the planned bootstrap and one real action
  before expanding greenfield work; brownfield: drive the existing affected
  path before editing. Record a missing runtime under the blocker/gap rules.
  A skeleton that only builds proves no product path.
- Follow plan.md's order. If reality differs, record a small deviation in
  `.sdlc/work/<slug>/deviations.md` (from `templates/deviations.md` on first
  use; its numbered lines are the cap counters, AGENTS.md rule 5) and
  continue. Never edit plan.md to match reality: the plan gate binds its
  content, so an edit closes the gate (rule 2). A structural deviation —
  different files or approach — re-gates the plan under rule 3 first; when
  its cause is a factual error in spec.md (wrong data shape or AS-IS claim),
  re-gate the spec first, with the evidence, then the plan. Re-review changed
  artifacts; rule 3 decides human or waived approval; authority still bounds scope.
- **Deviation cap: five small deviations per feature.** On the sixth,
  full-route work re-gates the plan (counts against the re-gate cap below)
  or STOPs. Compact work STOPs and asks the human to reassess intent/route,
  at every lazymode.
- **Compact route:** a surprise breaking compact eligibility (skills/1-intent
  "Which route") STOPs and upgrades to full: rewrite Track, re-approve
  intent, then write spec.md. Small deviations keeping every criterion stay compact.
- **Re-gate cap: two per stage, per feature.** A third request for the same
  stage means stage 1 got the facts wrong: STOP, show the human the trail
  (deviations.md + re-approval history), and let them choose — back to intent
  with the new facts, or close dead-end with a lesson. Log each re-gate in
  deviations.md the moment it happens (rule 5 "Caps survive dispatch").
  Endless spec↔plan churn is a finding about intent, never progress.
- **Bug fix: the failing test comes first.** Before touching the fix, add
  the regression test (AGENTS.md rule 6; the one stage 6 drafted, if any)
  and watch it fail on the current code for the reported reason. Save that
  output under `scratch/`; ship quotes its deciding lines in evidence.md's
  Bug proof. A test you never saw fail is not proof. The fix carries only
  what the confirmed mechanism justifies; "might also help" is a hypothesis.
- **Preserve accepted inputs.** Before changing input handling, turn stage
  1's caller and stored-record evidence into executable checks: missing,
  empty, null, wrong-type and unknown values through the real surface. Valid
  legacy input keeps its result; invalid input is refused safely, without a
  crash or partial state; an inapplicable case records its domain reason. A
  fallback or new required field needs that evidence, not a blanket recipe.
- **With a recipe, write the checks with the code** in
  `.sdlc/work/<slug>/verify.md` (templates/verify-feature.md): one `check:`
  per requirement variant and per reach scenario plan.md picked
  (roles/verifier.md), new tests `must-fail-on-base`
  where allowed, a `gap:` line only for what truly cannot be checked.
  `tools/verify.sh coverage <slug>` lists no uncovered id; fix a `vacuous` test
  (or `test_paths:`) until it fails at base for the reason it tests.
- A check that must fail the build fails it synchronously (direct throw,
  sync IO, or top-level await): an unawaited promise may finish too late
  and is not a gate.
- When a plan adds or changes browser E2E or a source-analysis checker, read
  [`test-authoring.md`](test-authoring.md) before editing it and apply every
  relevant rule.
- **Check narrowly per step, fully once.** After each step run the smallest
  check covering what it touched (one test file, one lint path, one
  `.sdlc/config.md` command scoped to the change). Run the full configured
  suite ONCE, at the end, over the final state ship reviews; re-run it only
  after a later change or a failure — over unchanged code it proves nothing new.
- A failing test is information about the code: fix the code, not the test
  (caught reaching for the test file? record a lesson). **When the expected
  behavior changed on purpose**, the test changes with it: record in
  deviations.md the changed expectation, the spec.md or intent.md line
  authorizing it, and the evidence it is correct. Forbidden: keeping a wrong
  expectation, or editing a test to quiet a real failure.
- **Record each mistake immediately** — yours, the plan's, and codebase
  surprises — in `.sdlc/work/<slug>/harvest.md` (AGENTS.md rule 4), in the
  skill 6 lesson format.
- Independent parallel work: worktrees/subagents where the harness supports
  them, one writer per file set; otherwise sequential.
- Tools: build/test/dev tools freely; NEVER deploy or release tools,
  production systems or credentials — shipping is Stage 5. When the harness
  can restrict subagent tools, copy each role's "Must not" list into the dispatch.

## Verify (fresh context, selected by approved Track)

When all steps are done and the full configured suite is green over the final
state, dispatch the Track's reviewers (AGENTS.md rule 6) — full: three
`roles/verifier.md` lenses in parallel, adversary at ship; approved compact:
one fresh reviewer with `roles/verifier.md` AND `roles/adversary.md` — with
intent.md and its `Refs:` origin, plan.md and spec.md (compact: intent.md
only), summary.md, changed-file list, `.sdlc/config.md`, current proof and
`baseline.txt` when present (rule 5's dispatch contract). The lenses are
**E2E**, **Side effects** and **Intent match**, each its complete role
section. A compact diff pass made here counts in evidence.md's two-round
counter; combining roles never resets either cap.

With a `.sdlc/verify.md` recipe the E2E lens runs `tools/verify.sh run <slug>`
unless rule 6's proof reuse applies, inspects deciding logs and
expectations itself, and evidence.md quotes the receipt's deciding lines.

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
Continue with ship (`skills/5-ship/SKILL.md`); the author assembles evidence,
passing the current reports and source/input identities so ship reuses valid
proof (rule 6).
