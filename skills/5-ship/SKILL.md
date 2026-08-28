---
name: sdlc-ship
description: Stage 5 — assemble evidence.md (proof per requirement, adversarial code review), request the ship gate. Use after build completes.
---

# Stage 5: Ship

Goal: an `evidence.md` that lets the human approve the release by reviewing
what the agents flagged — layered agentic review first, human attention
reserved for intent and risk.

## Before you start

Fresh session. Read plan.md, spec.md, and the diff (`git diff` against the
base branch). Read `.sdlc/memory/INDEX.md`.

## Adversarial code review (fresh context)

Dispatch an adversary (`roles/adversary.md`) with: spec.md, plan.md, the diff.
It attacks: spec mismatch, missing untouched-checks, security issues, test
theater (tests that can't fail), complexity that hides bugs. Fix findings or
record justified rejections.

## Assemble evidence

Fill `templates/evidence.md` → `.sdlc/work/<slug>/evidence.md`:

- Per spec requirement: the command run + REAL output (paste, don't summarize
  away the numbers). Evidence comes from the toolchain, not from your claims.
- Brownfield: baseline vs after — same commands, diffed; each "stays
  untouched" item explicitly checked.
- Full test/lint/build output (trimmed to verdict lines + failures, if any).
- Adversary findings + resolutions.
- Anything NOT verified, stated plainly (environment limits, skipped checks).
  An honest gap beats a false green.

## Retro (mandatory, 2 minutes)

Scan the feature's history: what went wrong, what surprised, what would you
tell the next agent? Record lessons per skill 6 format. If a lesson fires on
something a stage skill should have prevented, note in the lesson:
`promote: skills/<n>` — the human can then patch the skill; that is the
continual-improvement loop closing.

## Gate

> Review `.sdlc/work/<slug>/evidence.md`, then:
> `<kit>/gates/approve.sh ship .sdlc/work/<slug>/evidence.md`
> After approval, merge/release per your process. Commit `.sdlc/work/<slug>/`
> and `.sdlc/approvals/` with the code.

STOP after requesting approval.
