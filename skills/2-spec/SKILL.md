---
name: sdlc-spec
description: Stage 2 — generate spec.md from approved intent.md, then adversarial-review it before human sees it. Use after the intent gate is approved.
---

# Stage 2: Spec

Goal: a `spec.md` the engineering pass can plan against, generated from
`intent.md` — the human reviews it, they don't write it. Automate as much of
spec-making and spec-verifying as possible; concentrate the human at the gate.

## Before you start

1. `gates/check-gate.sh intent .sdlc/work/<slug>/intent.md` — STOP if closed.
2. Read intent.md fully. Read `.sdlc/memory/INDEX.md`; open matching lessons.
3. Brownfield: read the researcher report from stage 1 (or dispatch one now).

## Draft

Fill `templates/spec.md`. Rules:

- **Human summary first.** The spec body is an agent-facing contract; the
  gate reviewer is a human. Write the top "Human summary" section in plain
  speech (hard rule 8): what problem, what gets built, what stays unchanged,
  and each flagged concern as a one-line decision with your recommendation.
  Write it LAST (after the adversarial pass), place it FIRST.
- Every requirement traces to a line in intent.md. No invented features —
  gold-plating here is the #1 spec failure.
- Answer intent.md's open questions or carry them forward explicitly as
  flagged concerns. Never drop one.
- Data shapes end-to-end first: schemas, API contracts, migrations, serialization.
  Get the domain model right before behavior.
- Behavior as AS-IS → TO-BE pairs (template table). Brownfield AS-IS comes
  from explorer/browser evidence with file:line or capture references — never
  from memory of the request. The pair format is also how the change is
  presented to the human at the gate: what happens today, what will happen
  after.
- Brownfield: include a **"What stays untouched"** section — behavior that must
  survive, as testable statements. This becomes the regression baseline.
- Flag concerns (security, compliance, UX, performance) inline — these are
  what a human analyst would have escalated; the human resolves them at the gate.

## Adversarial verification (automated, before the human)

Dispatch a fresh-context adversary (`roles/adversary.md`) with ONLY: intent.md,
draft spec.md, researcher report if any. It attacks: intent mismatch, wrong
data shapes, missing edge cases, scope creep, untestable requirements.

- Fix what it catches; note each objection + resolution in spec.md's
  **Adversarial review** section (proof for the human that review happened).
- If it finds an intent contradiction you cannot resolve from the artifacts:
  STOP, return the question to the user. Do not guess.
- Repeat until the adversary has no blocking objections (max 3 rounds; then
  escalate remaining objections to the human as flagged concerns).

## Gate

> Review `.sdlc/work/<slug>/spec.md` — especially **Flagged concerns**.
> Then: `<kit>/gates/approve.sh spec .sdlc/work/<slug>/spec.md`

STOP after requesting approval.
