---
name: sdlc-intent
description: "Stage 1 — grill the user until intent is exact and evidenced; write intent.md. Triggers: any new SDLC feature, fix, or change."
---

# Stage 1: Intent

Goal: an `intent.md` so precise that a spec can be generated from it without
guessing. The user may be mistaken about the problem, the cause, and even what
they want. Your job is to find that out NOW — this is the cheapest stage to be
wrong in.

## Before you start

1. Read `.sdlc/memory/INDEX.md` and `.sdlc/memory/DOMAIN.md`; open lessons
   whose tags match this request.
2. Pick a short kebab-case feature slug; create `.sdlc/work/<slug>/`.

## Explore FIRST — before any question reaches the human

Grilling without evidence produces questions the human cannot answer well and
options nobody has feasibility-checked. As soon as the request is framed, fan
out fresh-context researchers (`roles/researcher.md`, full dispatch contract),
in parallel where independent — and only then start the interview:

- **History** (brownfield): has this been tried before? Reverts, related
  tickets, prior fixes and WHY they failed — from git history and commit
  messages. A failed prior attempt reshapes the whole intent.
- **Affected area**: entry points, data shapes, callers, side effects of the
  code the request touches.
- **Feasibility**: can the behavior be reproduced/run locally? What test
  infra, dev environments, tools, and access actually exist — verified, not
  assumed?
- **Browser as-is** (UI-facing behavior or hard bugs, when a browser tool is
  available and an environment is reachable): walk the real flow on the live
  surface. Record actual behavior, the API calls fired, console errors —
  observed, not inferred from code. Screenshots follow the bulk rule. For a
  bug, the as-is capture IS the reproduction evidence.

Skip a probe only when its subject does not exist (say so), or the change is
trivial and you already know the exact file and symbol. Keep raw exploration
out of your own context — reports in, noise out.

**Feasibility rule:** every option you put before the human must cite
explorer evidence that it is actually possible (access exists, repro works,
infra present). An option whose feasibility is unknown is not an option — it
is a research task you have not dispatched yet.

## Grill protocol

Interview the user ONE question at a time — each answer shapes the next
question (use your harness's question tool if it has one). Keep going until you can state their
intent back and they say "yes, exactly" — aim for ~95% confidence. Cover:

1. **Problem, not solution.** What breaks / hurts today? Who hits it, how
   often? If the user leads with a solution, ask what problem it solves.
2. **Demand proof — the user may be mistaken.** For every factual claim ("the
   API is slow", "users can't find X", "this bug is in module Y"):
   - Ask for evidence: logs, reproduction steps, a ticket, a metric, a file path.
   - Verify what you can yourself (read the code, run the repro, check the data).
   - Label every claim in intent.md: `[verified: how]` or `[assumed: why]`.
   - If your check CONTRADICTS the user, show the evidence and ask which is
     right. Do not silently defer; do not silently override.
3. **Success criteria.** What observable behavior means "done"? How would a
   machine check it?
4. **Scope edges.** What is explicitly NOT included? What must not change?
5. **Constraints.** Deadlines, compatibility, security/compliance, data
   migration concerns.

## Classify: greenfield or brownfield

- **Brownfield** (changes existing behavior): use the explorer reports to
  challenge the user's claims — this is where "user is mistaken" is most
  often caught. Contradiction between a report and a claim goes to the user
  with the evidence, before the intent is written.
- **Greenfield**: ask what existing systems it must integrate with; the
  feasibility explorer verifies those integration points exist as described.

## Write the artifact

Fill `templates/intent.md` → `.sdlc/work/<slug>/intent.md`. Every claim
labeled. Every open question is carried forward explicitly in its own section.

## Gate

Tell the user:

> Review `.sdlc/work/<slug>/intent.md`. If it says exactly what you want, run:
> `<kit>/gates/approve.sh intent .sdlc/work/<slug>/intent.md`

STOP. Do not start the spec in this session even after approval — stage 2 runs
with fresh context so spec inherits the artifact, not your conversation bias.
