---
name: sdlc-intent
description: "Explore-first grilling until intent is exact and evidenced. Triggers: new SDLC feature, fix, or change."
---

# Stage 1: Intent

Goal: create an `intent.md` precise enough to plan without guessing. Verify
the problem, cause, and requested outcome before moving on. Stage 1 is the
least costly place to correct a wrong assumption.

## Before you start

1. Read `.sdlc/memory/INDEX.md` and `.sdlc/memory/DOMAIN.md`; open lessons
   whose tags match this request.
2. Pick a short kebab-case feature slug; create `.sdlc/work/<slug>/`.

## Explore before asking questions

Do not ask questions until you have evidence. Without evidence, the user cannot
answer well and you cannot assess options. Once the request is clear, run
fresh-context researchers under `roles/researcher.md`. Run independent probes
in parallel, then start the interview:

- **History** for brownfield work. Check whether this was tried before. Read
  reverts, related tickets, prior fixes, and why they failed in git history
  and commit messages.
- **Affected area**: entry points, data shapes, callers, side effects of the
  code the request touches.
- **Feasibility**: can the behavior run or be reproduced locally? Verify the
  available test infrastructure, development environments, tools, and access.
- **Current browser behavior** for UI changes or hard bugs. When a browser
  tool and reachable environment exist, walk the real flow. Record behavior,
  API calls, and console errors. Use observations, not inferences from code.
  Screenshots follow the bulk rule. For a bug, this capture is reproduction
  evidence.

Skip a probe only when its subject does not exist (say so), or the change is
trivial and you already know the exact file and symbol. Keep raw exploration out of the main context. Use reports.

**Feasibility rule:** Every option shown to the human must cite evidence that
it is possible. This may include working access, a reproduction, or available
infrastructure. If feasibility is unknown, dispatch research instead of
presenting the option. When dependency compatibility is material and
uncertain, test the exact resolved versions in an isolated disposable
environment with the smallest relevant resolve, compile, or test command.
Record the command, toolchain, and resolved versions. If execution is
unavailable, cite authoritative compatibility evidence and label the remaining
uncertainty.

## Grill protocol

Interview the user one question at a time. Each answer shapes the next
question. Use the agent tool's question feature when available. Continue until
you can restate the intent and the user confirms it. Aim for about 95%
confidence. Cover:

1. **Problem, not solution.** What breaks or hurts today? Who encounters it,
   and how often? If the user leads with a solution, ask what problem it solves.
2. **Demand proof. The user may be mistaken.** For every factual claim ("the
   API is slow", "users can't find X", "this bug is in module Y"):
   - Ask for evidence: logs, reproduction steps, a ticket, a metric, a file path.
   - Verify what you can yourself (read the code, run the repro, check the data).
   - Label every claim in intent.md: `[verified: how]` or `[assumed: why]`.
   - If your check contradicts the user, show the evidence and ask which is
     right. Do not defer or override the conflict silently.
3. **Success criteria.** What observable behavior means "done"? How would a
   machine check it?
4. **Scope edges.** What is explicitly NOT included? What must not change?
5. **Constraints.** Deadlines, compatibility, security/compliance, data
   migration concerns.

## Classify: greenfield or brownfield

- **Brownfield** (changes existing behavior): use the explorer reports to
  challenge the user's claims. This is where incorrect assumptions are most
  often caught. Contradiction between a report and a claim goes to the user
  with the evidence, before the intent is written.
- **Greenfield**: ask what existing systems it must integrate with; the
  feasibility explorer verifies those integration points exist as described.

## Write the artifact

Fill `templates/intent.md` → `.sdlc/work/<slug>/intent.md`. Every claim
labeled. Every open question is carried forward explicitly in its own section.

## Gate

At lazymode 4 (AGENTS.md rule 3): dispatch a fresh-context adversary
(`roles/adversary.md`) over intent.md — this stage has no other adversary
pass. When it raises no blocking objection, run
`<kit>/gates/approve.sh intent .sdlc/work/<slug>/intent.md --lazy`, post the
intent summary and any objections to the human as FYI, and move to Stage 2
in a fresh context. Otherwise tell the user:

> Review `.sdlc/work/<slug>/intent.md`. If it says exactly what you want, run:
> `<kit>/gates/approve.sh intent .sdlc/work/<slug>/intent.md`

STOP. Do not start Stage 2 in this session after approval. Stage 2 uses a
fresh context and the approved artifact, not this conversation.
