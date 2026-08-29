---
name: sdlc-plan
description: "Read-only planning with a tiered gate: files, order, risks, proof. Triggers: spec gate approved."
---

# Stage 3: Plan

Goal: create `plan.md` before changing code. Name the files, work order, risks,
and proof. During this stage, read and run non-mutating commands only.

## Before you start

1. Run `gates/check-gate.sh spec .sdlc/work/<slug>/spec.md`. STOP if closed.
2. Read spec.md fully. Read `.sdlc/memory/INDEX.md` and
   `.sdlc/memory/DOMAIN.md`; open lesson files whose tags match the current
   task. Treat DOMAIN.md constraints as plan risks.
3. **Read-only rule: in this stage you may read code and run non-mutating
   commands only. No edits, no writes outside `.sdlc/work/<slug>/`.**

## Plan

Explore the codebase. Use a fresh-context researcher for large areas so raw
exploration stays out of the main context. Then fill `templates/plan.md`:

- **Files that change.** Give exact paths and mark each as new or modified.
- **Order of work.** Make each step keep the configured checks passing. Add
  tests with the code they test.
- **Risks.** Record rate limits, migrations, shared state, and important quirks.
- **Proof.** For each spec requirement, name the test or command that proves it.
  Use commands from `.sdlc/config.md`.
- Brownfield additions:
  - **Regression baseline.** Give the exact commands to run before changes and
    save their output to `.sdlc/work/<slug>/baseline.txt`.
  - **Untouched checks.** Say how each "stays untouched" item is verified.
- **Gate tier.** Check every trip-wire from AGENTS.md rule 3 (migration, data
  deletion, public API, security paths, infra/config, beyond-spec scope) and
  record the verdict in the template's **Gate tier** section, with reasons.
- **Human summary.** Five short sentences or fewer at the top: what changes,
  the main risk, how it is proven. Write it last, place it first.

Constraints the code does not show (ownership, forbidden areas, deploy
windows) are collected at the spec gate, not here. If a missing constraint
blocks planning, return the question to the spec gate instead of improvising.

## Adversarial review (fresh context)

Dispatch an adversary (`roles/adversary.md`) with ONLY: spec.md, draft
plan.md, and `.sdlc/memory/DOMAIN.md`. It checks that every requirement has a
proof command, the file list and order are complete, risks are not
understated, and the **Gate tier** verdict is correct. Fix findings; note
each objection + resolution in plan.md. If the code contradicts the spec,
STOP and show the conflict to the human. The spec gate may need to reopen.
Do not change the plan to hide a wrong spec.

## Gate (tiered, AGENTS.md rule 3)

- **No trip-wires and no blockers**: run
  `<kit>/gates/approve.sh plan .sdlc/work/<slug>/plan.md --agent-adversary`,
  post the Human summary to the human as FYI, and continue to build.
- **Any trip-wire**: this is a human gate.

  > Review `.sdlc/work/<slug>/plan.md`, then:
  > `<kit>/gates/approve.sh plan .sdlc/work/<slug>/plan.md`

  STOP after requesting approval.
