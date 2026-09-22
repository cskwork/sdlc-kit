---
name: sdlc-kit
description: "Gated SDLC loop with human approvals, for building features and fixing bugs. Triggers: any request to implement, change, or fix something in a project that has .sdlc/ — plain wording counts (\"add X\", \"fix this bug\", \"make Y work\") — plus \"start SDLC\", \"sdlc status\", \"continue the loop\", and incident reports. Does NOT trigger on read-only work: explaining code, answering questions, reviews and audits that change nothing."
---

# sdlc-kit router

One loop, six stages, one artifact per stage, and a gate between stages:
human at intent, spec, and ship; tiered at plan; `lazymode:` in
`.sdlc/config.md` can waive human gates (AGENTS.md rule 3).
This file routes requests. `AGENTS.md` in this directory is the full contract
— gates, authority, memory, fresh-context review, proof. Read it completely
before the first stage of a session, then return here.

## When this skill runs

In a project with `.sdlc/`, any request that CHANGES the product runs through
this loop — "add a filter to the report", "fix the login redirect", "make the
export faster". No SDLC vocabulary is required; the words the human used are
not the trigger, the change is.

Read-only requests do NOT start the loop: explaining how something works,
answering a question, reading logs, reviewing or auditing code without
changing it. Answer those directly. If the answer turns into "…and here is
what I would change", that is where stage 1 starts — say so, then start it.

Specialist agents and project-local skills still do the implementation work;
they do it under this contract (gates, artifacts, memory), not beside it.

## Route by request

| Request looks like | Do |
|---|---|
| any feature, fix, or change request, however worded | New slug. Read `skills/1-intent/SKILL.md`. Small and well understood → compact route (one work artifact: intent → build → ship); anything ambiguous, broad, or risky → full route; oversized → map first. |
| "explain X" / "why does Y happen" / read-only audit | Answer it. No slug, no artifacts, no gates. Propose stage 1 only if the human wants the change made. |
| ticket too big or foggy for one intent pass | `map.md` in the same slug dir first (skills/1-intent "Chart a map first"); one Unknown per session, six sessions max. |
| "continue <slug>" / "what's next" | Run `gates/status.sh <slug>` from the project root. Its `next →` line names the stage skill or gate command. |
| "where are we" / "sdlc status" | `gates/status.sh` (open features; `--all` adds the newest 20 archived) + `gates/stats.sh` (open + recent closed). Full-archive sweeps: `ls`/`grep .sdlc/archive/`, never the whole listing into context. |
| "has this been done before" / "why is X like this" / debugging an old area | `tools/kb.sh search "<text>"` then `tools/kb.sh show <slug>` (AGENTS.md rule 7). |
| "what did we learn that is not in memory yet" / many open features, few closes | `tools/kb.sh harvest [--stale <days>]`; a stale one may be merged without closing (AGENTS.md rule 4). Contents page: `tools/kb.sh index` (`index_style: obsidian` in config.md for a vault). |
| a host/scheduler drives the loop, or you need machine state | `gates/status.sh --json`, `tools/auto.sh next <slug>`; contract: `docs/automation.md`. |
| gate request answered "approve" in chat | `gates/approve.sh <stage> <artifact> --delegated` per AGENTS.md rule 3. |
| incident / bug / alert on a shipped feature | Read `skills/6-maintain/SKILL.md`. |
| "we're done / drop this / dead end" for a feature | `gates/close.sh <slug> <shipped\|abandoned\|dead-end\|handed-off> "reason"` — what each needs: AGENTS.md "Every feature ends in a terminal state". |
| project has no `.sdlc/` yet | Run `<kit>/init.sh` from the project root (records are gitignored; `--area <folder>` keeps them in a folder the human names instead); ask the human which lazymode level they want (0–4, default 1; AGENTS.md rule 3) and set it in `.sdlc/config.md`; fill the config commands; then stage 1. |
