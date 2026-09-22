---
name: sdlc-spec
description: "Spec generation, adversary-reviewed before the human gate. Triggers: intent gate approved."
---

# Stage 2: Spec

Goal: create `spec.md` from `intent.md` so engineering work has a clear
contract. The agent writes the spec, and the human reviews it. Automate checks
where possible. Keep human attention on gate decisions.

Heartbeat throughout: AGENTS.md rule 9.

## Before you start

1. Run `gates/check-gate.sh intent .sdlc/work/<slug>/intent.md`. STOP if closed.
2. Read intent.md (and origin.md) fully, and memory (AGENTS.md rule 4).
   Use DOMAIN.md terms so the spec uses the project's established
   vocabulary.
3. Brownfield: read the researcher report from stage 1 (or dispatch one now).

## Draft

Fill `templates/spec.md`. Rules:

- **Human summary first.** The spec body is an agent-facing contract. The
  gate reviewer is a human — possibly one with no technical background.
  Write the top "Human summary" section so ANYONE can follow it (extends
  hard rule 8): no code identifiers, no jargon (gloss an unavoidable term in the same
  sentence), visible behavior rather than system internals — what problem,
  what gets built, what stays unchanged, and each flagged concern as a
  one-line decision with your recommendation. Test: would a non-developer
  colleague understand every sentence? If not, rewrite. Write it LAST
  (after the adversarial pass), place it FIRST.
- Every requirement cites the intent.md O-item it fulfils (`R1: … (O1)`). An
  O-item with no R becomes a flagged concern, never a silent drop; a feature no
  O-item asks for is not added.
- Every intent.md open question ends up in exactly one of two places: answered
  in the spec, or carried forward as a flagged concern.
- Define data shapes before behavior. Check schemas, API contracts, migrations,
  and serialization end to end.
- Behavior as AS-IS → TO-BE pairs (template table). Brownfield AS-IS comes
  from explorer or browser evidence with file:line or capture references. Use
  observations, not memory. The business rules on the area page (P-numbers)
  are AS-IS too: name each one this change keeps, changes, or retires. The
  pair format is also how the change is presented to the human at the gate:
  what happens today, what will happen after.
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

This review runs at every lazymode — lazymode changes who decides at the
gate, not whether the spec is reviewed (AGENTS.md rule 3). Include
`tools/tripwire.sh` output over the draft as evidence.

Dispatch a fresh-context adversary (`roles/adversary.md`) with ONLY:
intent.md, draft spec.md, `.sdlc/memory/POLICY.md` if present, the area
pages summary.md names, and the researcher report if any. It checks intent mismatch, wrong data shapes,
missing edge cases, scope creep, untestable requirements, and policy
violations.

- Fix what it catches; note each objection + resolution in spec.md's
  **Adversarial review** section (proof for the human that review happened).
- If it finds an intent contradiction you cannot resolve from the artifacts:
  STOP, return the question to the user. Do not guess.
- Repeat until the adversary has no blocking objections (max 2 rounds).
  Non-blocking leftovers become flagged concerns; a blocker surviving
  round 2 blocks `--lazy` — human ask at any lazymode (rule 3).

## Gate

At lazymode ≥2 (AGENTS.md rule 3): after the adversary review above passes,
run `<kit>/gates/approve.sh spec .sdlc/work/<slug>/spec.md --lazy --review
"<what the review covered>"` (add `--risk-authorized "<the human's words>"`
for risky work), post the Human summary and Flagged concerns as FYI, and
continue to plan (`skills/3-plan`). Otherwise:

> Review `.sdlc/work/<slug>/spec.md`, especially **Flagged concerns**.
> Then: `<kit>/gates/approve.sh spec .sdlc/work/<slug>/spec.md`

STOP after requesting approval.
