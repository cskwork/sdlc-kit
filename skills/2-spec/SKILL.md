---
name: sdlc-spec
description: "Spec generation, adversary-reviewed before the human gate. Triggers: intent gate approved."
---

# Stage 2: Spec

Goal: create `spec.md` from `intent.md` so engineering work has a clear
contract. The agent writes the spec, and the human reviews it. Automate checks
where possible. Keep human attention on gate decisions.

## Before you start

1. Run `gates/check-gate.sh intent .sdlc/work/<slug>/intent.md`. STOP if closed.
2. Read intent.md fully. Read `.sdlc/memory/INDEX.md` and
   `.sdlc/memory/DOMAIN.md`; open lesson files whose tags match the current
   task. Use DOMAIN.md terms so the spec uses the project's established
   vocabulary.
3. Brownfield: read the researcher report from stage 1 (or dispatch one now).

## Draft

Fill `templates/spec.md`. Rules:

- **Human summary first.** The spec body is an agent-facing contract. The gate
  reviewer is a human. Write the top "Human summary" section in plain
  speech (hard rule 8): what problem, what gets built, what stays unchanged,
  and each flagged concern as a one-line decision with your recommendation.
  Write it LAST (after the adversarial pass), place it FIRST.
- Every requirement traces to a line in intent.md. Do not add features that
  intent.md does not request.
- Every intent.md open question ends up in exactly one of two places: answered
  in the spec, or carried forward as a flagged concern.
- Define data shapes before behavior. Check schemas, API contracts, migrations,
  and serialization end to end.
- Behavior as AS-IS → TO-BE pairs (template table). Brownfield AS-IS comes
  from explorer or browser evidence with file:line or capture references. Use
  observations, not memory. The pair format is also how the change is
  presented to the human at the gate: what happens today, what will happen
  after.
- Brownfield: include a **"What stays untouched"** section with testable
  statements about behavior that must survive. This becomes the regression baseline.
- **Ask for constraints the code does not show.** Ownership boundaries,
  forbidden areas, deploy windows, compatibility promises. Record them in the
  spec. The plan stage inherits them and does not interview the human again.
- **State the release procedure in one line** (template section): branch →
  merge target → push → deploy command. Ship follows this line; "none" is a
  valid deploy command.
- Flag security, compliance, UX, and performance concerns inline. The human
  resolves them at the gate.

## Adversarial verification (automated, before the human)

Dispatch a fresh-context adversary (`roles/adversary.md`) with ONLY: intent.md,
draft spec.md, and researcher report if any. It checks intent mismatch, wrong
data shapes, missing edge cases, scope creep, and untestable requirements.

- Fix what it catches; note each objection + resolution in spec.md's
  **Adversarial review** section (proof for the human that review happened).
- If it finds an intent contradiction you cannot resolve from the artifacts:
  STOP, return the question to the user. Do not guess.
- Repeat until the adversary has no blocking objections (max 3 rounds; then
  escalate remaining objections to the human as flagged concerns).

## Gate

At lazymode ≥2 (AGENTS.md rule 3): after the adversary pass, run
`<kit>/gates/approve.sh spec .sdlc/work/<slug>/spec.md --lazy`, post the
Human summary and Flagged concerns as FYI, and continue to plan. Otherwise:

> Review `.sdlc/work/<slug>/spec.md`, especially **Flagged concerns**.
> Then: `<kit>/gates/approve.sh spec .sdlc/work/<slug>/spec.md`

STOP after requesting approval.
