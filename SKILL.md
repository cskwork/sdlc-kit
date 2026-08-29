---
name: sdlc-kit
description: "Gated SDLC loop with human approvals. Triggers: \"start SDLC\", \"sdlc status\", \"continue the loop\", \"through the gates\", or an incident in a project with .sdlc/. Plain feature requests without SDLC wording belong to other skills."
---

# sdlc-kit router

One loop, six stages, one artifact per stage, and a gate between stages:
human at intent, spec, and ship; tiered at plan; `lazymode:` in
`.sdlc/config.md` can waive human gates (AGENTS.md rule 3).
This file routes requests. `AGENTS.md` in this directory is the full contract.
Read it completely on first contact with a project, then return here.

## Route by request

| Request looks like | Do |
|---|---|
| "start SDLC for <idea/bug>" | New slug. Read `skills/1-intent/SKILL.md`. |
| "continue <slug>" / "what's next" | Run `gates/status.sh <slug>` from the project root. Its `next →` line names the stage skill or gate command. |
| "where are we" / "sdlc status" | `gates/status.sh` (all features) + `gates/stats.sh` (timings). |
| gate request answered "approve" in chat | `gates/approve.sh <stage> <artifact> --delegated` per AGENTS.md rule 3. |
| incident / bug / alert on a shipped feature | Read `skills/6-maintain/SKILL.md`. |
| "we're done / drop this / dead end" for a feature | `gates/close.sh <slug> <shipped\|abandoned\|dead-end\|handed-off> "reason"`. Dead-end/abandoned need a lesson; handed-off needs an external ticket/PR reference. |
| project has no `.sdlc/` yet | Run `<kit>/init.sh` from the project root; ask the human which lazymode level they want (0–4, default 1; AGENTS.md rule 3) and set it in `.sdlc/config.md`; fill the config commands; then stage 1. |

## Coexistence (full text in AGENTS.md)

Project rules control implementation details such as commands, branches, and
style. The kit controls stages, gates, and memory. Quote conflicts to the human
instead of resolving them silently. DOMAIN.md points at existing glossaries/ADRs instead of
copying. Kit roles dispatch onto existing specialist agents when one fits.
Monorepos: one `.sdlc/` per shipping unit.

## Invariants (full text in AGENTS.md)

Before stages 2–4, check the gate. Use fresh contexts for spec, plan, build,
and verification. Read `memory/INDEX.md` and `memory/DOMAIN.md` at every stage
start. Speak plainly to the human. Keep artifacts in the project. Store large
evidence in scratch/ and cite only the deciding lines.
