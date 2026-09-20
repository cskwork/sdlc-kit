---
name: sdlc-kit
description: "Gated SDLC loop with human approvals, for building features and fixing bugs. Triggers: any request to implement, change, or fix something in a project that has .sdlc/ — plain wording counts (\"add X\", \"fix this bug\", \"make Y work\") — plus \"start SDLC\", \"sdlc status\", \"continue the loop\", and incident reports. Does NOT trigger on read-only work: explaining code, answering questions, reviews and audits that change nothing."
---

# sdlc-kit router

One loop, six stages, one artifact per stage, and a gate between stages:
human at intent, spec, and ship; tiered at plan; `lazymode:` in
`.sdlc/config.md` can waive human gates (AGENTS.md rule 3).
This file routes requests. `AGENTS.md` in this directory is the full contract.
Read it completely on first contact with a project, then return here.

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
| "has this been done before" / "why is X like this" / debugging an old area | `tools/kb.sh search "<text>"` then `tools/kb.sh show <slug>` — open and closed features plus durable memory, bounded output (`--area <folder>` covers every store, even one whose checkout is gone). Exit 0 found · 1 nothing · 2 usage/refusal. |
| a host/scheduler drives the loop, or you need machine state | `gates/status.sh --json` (= `tools/auto.sh status --json`) and `tools/auto.sh next <slug>` (exit 0 ready · 10 needs-human · 20 blocked · 30 complete). Verification receipts: `tools/verify.sh`; review handoff: `tools/handoff.sh`. Contract: `docs/automation.md`. These report and record — they run no stage. |
| gate request answered "approve" in chat | `gates/approve.sh <stage> <artifact> --delegated` per AGENTS.md rule 3. |
| incident / bug / alert on a shipped feature | Read `skills/6-maintain/SKILL.md`. |
| "we're done / drop this / dead end" for a feature | `gates/close.sh <slug> <shipped\|abandoned\|dead-end\|handed-off> "reason"`. `shipped` needs a confirmed `delivery.md` (templates/delivery.md) and an unchanged ship approval; dead-end/abandoned need a lesson (lazymode ≥3: the reason line suffices); handed-off needs an external ticket/PR reference. close.sh archives the feature to `.sdlc/archive/<slug>/`. |
| project has no `.sdlc/` yet | Run `<kit>/init.sh` from the project root (records are gitignored; `--area <folder>` keeps them in a folder the human names instead); ask the human which lazymode level they want (0–4, default 1; AGENTS.md rule 3) and set it in `.sdlc/config.md`; fill the config commands; then stage 1. |

## Coexistence (full text in AGENTS.md)

Project rules control implementation details such as commands, branches, and
style. The kit controls stages, gates, and memory. Quote conflicts to the human
instead of resolving them silently. DOMAIN.md points at existing
glossaries/ADRs instead of copying. Kit roles dispatch onto existing specialist agents when one fits.
Monorepos: one `.sdlc/` per shipping unit.

## Invariants (full text in AGENTS.md)

Before stages 2–4, check the gate. One delegate carries the loop; verification
and adversarial review always run in a fresh context, and a harness that cannot
provide one gets an explicit gap line in the artifact (AGENTS.md rule 5).
Read `.sdlc/memory/POLICY.md`,
`.sdlc/memory/INDEX.md`, and `.sdlc/memory/DOMAIN.md` at every stage start;
mid-loop memory candidates go to the feature's `harvest.md`, merged only at
close (rule 4). Speak plainly to the human. Keep artifacts in the record
store, which is gitignored in full and is the human's to back up (rule 7).
Store large evidence in scratch/ and cite only the deciding lines.
