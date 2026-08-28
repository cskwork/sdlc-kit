---
name: sdlc-plan
description: "Stage 3 — read-only planning: files, order, risks, proof into plan.md. Triggers: spec gate approved."
---

# Stage 3: Plan

Goal: a `plan.md` naming exactly which files change, in what order, with what
risks, and what proof will show it worked — before any code is written. This is
plan-mode-as-default, harness-neutral: the rule "read everything, change
nothing" is YOUR discipline in this stage, not a harness feature.

## Before you start

1. `gates/check-gate.sh spec .sdlc/work/<slug>/spec.md` — STOP if closed.
2. Read spec.md fully. Read `.sdlc/memory/INDEX.md` and
   `.sdlc/memory/DOMAIN.md`; open matching lessons. DOMAIN.md constraints
   are plan risks by default.
3. **Read-only rule: in this stage you may read code and run non-mutating
   commands only. No edits, no writes outside `.sdlc/work/<slug>/`.**

## Plan

Explore the codebase (fresh-context researcher for large areas — keep raw
exploration out of your context). Then fill `templates/plan.md`:

- **Files that change** — exact paths, new vs modified.
- **Order of work** — steps sized so each leaves the tree green; tests land
  with the code they test, not after.
- **Risks** — rate limits, migrations, shared state, load-bearing quirks.
- **Proof** — per spec requirement: the test or command that will demonstrate
  it, using commands from `.sdlc/config.md`.
- Brownfield additions:
  - **Regression baseline** — the exact commands to run BEFORE changes, and
    where output is saved (`.sdlc/work/<slug>/baseline.txt`).
  - **Untouched checks** — how each "stays untouched" spec item is verified.

## Interview the human

Walk them through the plan; iterate until they're satisfied. They know the
load-bearing quirks the code doesn't show. If the codebase contradicts the
spec (spec assumed X, code does Y), STOP and surface it — the spec gate may
need to reopen. Do not silently patch the plan around a wrong spec.

## Gate

> Review `.sdlc/work/<slug>/plan.md`, then:
> `<kit>/gates/approve.sh plan .sdlc/work/<slug>/plan.md`

STOP after requesting approval.
