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
| "start SDLC for <idea/bug>" | New slug. Read `skills/1-intent/SKILL.md`. Trivial ticket → micro track (intent → build → ship); oversized → map first. |
| ticket too big or foggy for one intent pass | `map.md` in the same slug dir first (skills/1-intent "Chart a map first"); one Unknown per session, six sessions max. |
| "continue <slug>" / "what's next" | Run `gates/status.sh <slug>` from the project root. Its `next →` line names the stage skill or gate command. |
| "where are we" / "sdlc status" | `gates/status.sh` (open features; `--all` adds the newest 20 archived) + `gates/stats.sh` (open + recent closed). Full-archive sweeps: `ls`/`grep .sdlc/archive/`, never the whole listing into context. |
| gate request answered "approve" in chat | `gates/approve.sh <stage> <artifact> --delegated` per AGENTS.md rule 3. |
| incident / bug / alert on a shipped feature | Read `skills/6-maintain/SKILL.md`. |
| "we're done / drop this / dead end" for a feature | `gates/close.sh <slug> <shipped\|abandoned\|dead-end\|handed-off> "reason"`. Dead-end/abandoned need a lesson (lazymode ≥3: the reason line suffices); handed-off needs an external ticket/PR reference. close.sh archives the feature to `.sdlc/archive/<slug>/`. |
| project has no `.sdlc/` yet | Run `<kit>/init.sh` from the project root; ask the human which lazymode level they want (0–4, default 1; AGENTS.md rule 3) and set it in `.sdlc/config.md`; fill the config commands; then stage 1. |

## Coexistence (full text in AGENTS.md)

Project rules control implementation details such as commands, branches, and
style. The kit controls stages, gates, and memory. Quote conflicts to the human
instead of resolving them silently. DOMAIN.md points at existing
glossaries/ADRs instead of copying. Kit roles dispatch onto existing specialist agents when one fits.
Monorepos: one `.sdlc/` per shipping unit.

## Invariants (full text in AGENTS.md)

Before stages 2–4, check the gate. Dispatch stage work and verification to
subagents; the orchestrator keeps only artifacts, summaries, and gate
decisions (AGENTS.md rule 5). Read `.sdlc/memory/POLICY.md`,
`.sdlc/memory/INDEX.md`, and `.sdlc/memory/DOMAIN.md` at every stage start;
mid-loop memory candidates go to the feature's `harvest.md`, merged only at
close (rule 4). Speak plainly to the human. Keep artifacts in the project.
Store large evidence in scratch/ and cite only the deciding lines.
