---
name: sdlc-kit
description: "Gated SDLC loop: intent → spec → plan → build → evidence → maintain, human approval between stages. Triggers ONLY on explicit SDLC intent: 'start SDLC for X', 'continue the SDLC loop', 'sdlc status', 'run this through the gates', or an incident in a project that has a .sdlc/ directory. Plain feature/bug requests without SDLC wording or a .sdlc/ dir belong to other skills."
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

## Coexistence (full text in AGENTS.md)

Project rules win on *how* (commands, branches, style); the kit wins on
*process* (stages, gates, memory) — conflicts get quoted to the human, not
resolved silently. DOMAIN.md points at existing glossaries/ADRs instead of
copying. Kit roles dispatch onto existing specialist agents when one fits.
Monorepos: one `.sdlc/` per shipping unit.

## Invariants (full text in AGENTS.md)

Gate check before stages 2–4 · fresh context for spec/plan/build/verify
dispatches · read `memory/INDEX.md` + `memory/DOMAIN.md` at every stage start ·
plain speech in every message to the human · artifacts live in the project,
bulk dies in scratch/.
