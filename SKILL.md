---
name: sdlc-kit
description: "Gated SDLC loop with human approvals, for building features and fixing bugs. Triggers: any request to implement, change, or fix something in a project that has .sdlc/ — plain wording counts (\"add X\", \"fix this bug\", \"make Y work\") — plus \"start SDLC\", \"sdlc status\", \"continue the loop\", and incident reports. Does NOT trigger on read-only work: explaining code, answering questions, reviews and audits that change nothing."
---

# sdlc-kit router

This file routes requests. Read this kit's `AGENTS.md` completely before the
first stage of a session: it owns gates, authority, memory, review and proof.

## When this skill runs

A requested product change in a directory with `.sdlc/`, or below one, runs
this loop (AGENTS.md "Monorepos"); no SDLC wording is required. Read-only
explanations, log reads, reviews and audits run directly. Proposing a patch
alone does not authorize implementation: start stage 1 when the human requests
the change. Project specialists implement under the same contract.

## Route by request

| Request looks like | Do |
|---|---|
| a feature/change request, including a fix with a known cause | New slug. Read `skills/1-intent/SKILL.md` for compact/full eligibility and mapping oversized work. |
| "explain X" / "why does Y happen" / read-only audit | Answer it. No slug, no artifacts, no gates. Propose stage 1 only if the human wants the change made. |
| ticket too big or foggy for one intent pass | `map.md` in the same slug dir first (skills/1-intent "Chart a map first"); one Unknown per session, six sessions max. |
| "continue <slug>" / "what's next" | Run `gates/status.sh <slug>` from the project root. Its `next →` line names the stage skill or gate command. |
| "where are we" / "sdlc status" | `gates/status.sh` (open features; `--all` adds the newest 20 archived) + `gates/stats.sh` (open + recent closed). Archive sweeps: AGENTS.md rule 4. |
| "use jev for QA" / "jev로 QA" / "switch QA back to agent" / "which QA mode" | `tools/qa-mode.sh set jev` (or `set agent`; `--project` for this project only; default is agent, the choice is remembered) or `tools/qa-mode.sh` to show it. Jev mode changes how the verifier drives screens: `docs/jev-qa.md`. |
| "has this been done before" / "why is X like this" / "what are the rules for <menu>" | `tools/kb.sh search "<text>"`, then `tools/kb.sh show <slug>` or `show <product area>`; `tools/kb.sh index` lists the areas (AGENTS.md rule 7). |
| "what did we learn that is not in memory yet" / many open features, few closes | `tools/kb.sh harvest [--stale <days>]`; a stale one may be merged without closing (AGENTS.md rule 4). Contents page: `tools/kb.sh index` (`index_style: obsidian` in config.md for a vault). |
| a host/scheduler drives the loop, or you need machine state | `gates/status.sh --json`, `tools/auto.sh next <slug>`; contract: `docs/automation.md`. |
| gate request answered "approve" in chat | `gates/approve.sh <stage> <artifact> --delegated` per AGENTS.md rule 3. |
| something is broken and the cause is not known — bug report, incident, alert | Read `skills/6-maintain/SKILL.md` first: it diagnoses, then writes the intent. Takes precedence over the first row. |
| "we're done / drop this / dead end" for a feature | `gates/close.sh <slug> <shipped\|abandoned\|dead-end\|handed-off> "reason"` — what each needs: AGENTS.md "Every feature ends in a terminal state". |
| project has no `.sdlc/` yet | Run `<kit>/init.sh` from the project root (records are gitignored; `--area <folder>` keeps them in a folder the human names instead); ask the human which lazymode level they want (0–4, default 1; AGENTS.md rule 3) and set it in `.sdlc/config.md`; fill the config commands from the repo (package scripts, Makefile, CI) and run each once — ask only for what the repo cannot show; then stage 1. |
