---
name: sdlc-plan
description: "Read-only planning with a tiered gate: files, order, risks, proof. Triggers: spec gate approved."
---

# Stage 3: Plan

Goal: create `plan.md` before changing code. Name the files, work order, risks,
and proof. During this stage, read and run non-mutating commands only.

Heartbeat throughout: AGENTS.md rule 9.

## Before you start

1. Run `gates/check-gate.sh spec .sdlc/work/<slug>/spec.md`. STOP if closed.
2. Read spec.md fully, and memory (AGENTS.md rule 4). Treat DOMAIN.md
   constraints and POLICY.md rules as plan risks.
3. **Read-only rule: in this stage you may read code and run non-mutating
   commands only. No edits, no writes outside `.sdlc/work/<slug>/`** (the heartbeat and
   the plan artifact live there).

## Plan

Explore the codebase. Use a fresh-context researcher for large areas so raw
exploration stays out of the main context. Then fill `templates/plan.md`:

- **Files that change.** Give exact paths and mark each as new or modified.
- **Data touched.** Every shape those files write or read — table, column,
  type, event, file — with its other producers and consumers and what happens
  to records that predate the change. The adversary checks it is complete;
  the verifier's Side effects lens executes it.
  Carry forward stage 1's caller/record evidence and domain-valid legacy
  shapes. Proof covers applicable missing, empty, null, wrong-type and unknown
  values with preserved valid results or safe invalid refusal; an inapplicable
  case needs a domain reason.
- **Reach.** Every caller of each changed behavior — search the other
  repositories and tiers that call it, not only this one — with what each
  sends; the states of existing records it meets; the conditions that change
  its outcome. Pick the riskiest of each as the entry, state, and context
  scenarios the verifier runs; say how the product itself brings a user back
  to the picked state, and which picks can happen in one real use (they run
  together as well). When the change refuses input it accepted
  before (a new validation, a newly required field, a narrowed type), list
  what every caller sends today: that change is a contract change (AGENTS.md
  rule 3).
- **Order of work.** Use delivery-sized vertical slices, each tied to R-items
  and an observable result through the real interface. Put the shortest
  runnable path first; greenfield starts with bootstrap, readiness, one action,
  and cleanup proved before expansion. Keep configured checks passing and add
  tests with the code they test. Order steps that write the same file.
  If a slice's boundary or runnable path is unclear, read
  [`Choose a slice that can finish`](../../docs/software-factory.md#choose-a-slice-that-can-finish)
  and [`Make the product runnable early`](../../docs/software-factory.md#make-the-product-runnable-early)
  before finalizing the order.
- **Risks.** Record rate limits, migrations, shared state, and important quirks.
  When UI/interaction, data/state, authentication/permissions, or API/CLI/job
  behavior is affected, read
  [`Spend checks where failure matters`](../../docs/software-factory.md#spend-checks-where-failure-matters)
  and include its applicable quality checks in **Risks** and **Proof**.
- **Proof.** For each spec requirement, name the test or command that proves it
  (bug fix: the regression test — AGENTS.md rule 6).
  Use commands from `.sdlc/config.md`.
- Brownfield additions:
  - **Regression baseline.** Give the exact commands to run before changes and
    save their output to `.sdlc/work/<slug>/baseline.txt`.
  - **Untouched checks.** Say how each "stays untouched" item is verified.
- **Gate tier.** Check every trip-wire from AGENTS.md rule 3 (migration, data
  deletion, public API, security paths, infra/config, beyond-spec scope) and
  record the verdict in the template's **Gate tier** section, with reasons.
  Run `<kit>/tools/tripwire.sh .sdlc/work/<slug>/plan.md` and include its
  output in the adversary dispatch.
- **Human summary.** In the template's shape (AGENTS.md rule 8). Write it
  last, place it first.

Constraints the code does not show (ownership, forbidden areas, deploy
windows) are collected at the spec gate, not here. If a missing constraint
blocks planning, return the question to the spec gate instead of
improvising — this counts against the re-gate cap of two per stage
(AGENTS.md rule 3; escalation: skills/4-build "Re-gate cap").

## Adversarial review (fresh context)

Run this review at every lazymode; apply AGENTS.md rule 3 to the tier and
tripwire evidence.

Dispatch an adversary (`roles/adversary.md`) with ONLY: spec.md, draft
plan.md, `.sdlc/memory/DOMAIN.md`, `.sdlc/memory/POLICY.md` if present, and
the tripwire output. Apply the role's complete plan checklist, including its
**Gate tier** re-check. Fix findings; record
each objection + resolution and the tier re-check in plan.md's
**Adversarial review** section. If there were blocking findings, re-run the
adversary over the fixed plan (max 2 rounds). Non-blocking leftovers become
flagged concerns; a blocker surviving round 2 blocks `--lazy` — human ask
at any lazymode (rule 3). Plan never opens over a live blocker.
If the code contradicts the spec,
STOP and show the conflict to the human. The spec gate may need to reopen —
that reopen counts against the re-gate cap (AGENTS.md rule 3).
Do not change the plan to hide a wrong spec.

## Gate (tiered, AGENTS.md rule 3)

At lazymode ≥1: after the adversary review above passes, run
`<kit>/gates/approve.sh plan .sdlc/work/<slug>/plan.md --lazy --review
"<what the adversary checked>"`, post the Human summary and any trip-wire
list as FYI, and continue to build. A plan whose **Gate tier** is `human`, or
whose artifact trips the scan, also needs `--risk-authorized "<the human's
words>"`: lazymode moves the checkpoint, it does not grant authority for
irreversible work (AGENTS.md rule 3).

At lazymode 0:

- **No trip-wires and no blockers**: run
  `<kit>/gates/approve.sh plan .sdlc/work/<slug>/plan.md --agent-adversary`,
  post the Human summary to the human as FYI, and continue to build.
- **Any trip-wire**: this is a human gate:

  > Review `.sdlc/work/<slug>/plan.md`, then:
  > `<kit>/gates/approve.sh plan .sdlc/work/<slug>/plan.md`

  STOP after requesting approval.
