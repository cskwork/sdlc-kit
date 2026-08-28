---
name: sdlc-kit
description: "Gated SDLC loop: intent → spec → plan → build → evidence → maintain, human approval between stages. Triggers: start SDLC for X, continue the SDLC loop, where is feature X, sdlc status, run this through the gates, an incident/bug arrives for a project using .sdlc/."
---

# sdlc-kit router

One loop, six stages, one artifact per stage, a human gate between stages.
This file routes; `AGENTS.md` in this directory is the full contract — read
it completely on first contact with a project, then come back here.

## Route by request

| Request looks like | Do |
|---|---|
| "start SDLC for <idea/bug>" | New slug. Read `skills/1-intent/SKILL.md`. |
| "continue <slug>" / "what's next" | Run `gates/status.sh <slug>` from the project root; its `next →` line names the stage skill or gate command. |
| "where are we" / "sdlc status" | `gates/status.sh` (all features) + `gates/stats.sh` (timings). |
| gate request answered "approve" in chat | `gates/approve.sh <stage> <artifact> --delegated` per AGENTS.md rule 3. |
| incident / bug / alert on a shipped feature | Read `skills/6-maintain/SKILL.md`. |
| "we're done / drop this / dead end" for a feature | `gates/close.sh <slug> <shipped\|abandoned\|dead-end> "reason"` — non-shipped closes need a lesson first. |
| project has no `.sdlc/` yet | Run `<kit>/init.sh` from the project root; fill `.sdlc/config.md` commands; then stage 1. |

## Invariants (full text in AGENTS.md)

Gate check before stages 2–4 · fresh context for spec/plan/build/verify
dispatches · read `memory/INDEX.md` + `memory/DOMAIN.md` at every stage start ·
plain speech in every message to the human · artifacts live in the project,
bulk dies in scratch/.
