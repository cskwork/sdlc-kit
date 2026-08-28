---
name: sdlc-intent
description: Stage 1 — grill the user until intent is exact and evidenced, then write intent.md. Use when starting any SDLC feature, fix, or change.
---

# Stage 1: Intent

Goal: an `intent.md` so precise that a spec can be generated from it without
guessing. The user may be mistaken about the problem, the cause, and even what
they want. Your job is to find that out NOW — this is the cheapest stage to be
wrong in.

## Before you start

1. Read `.sdlc/memory/INDEX.md`; open lessons whose tags match this request.
2. Pick a short kebab-case feature slug; create `.sdlc/work/<slug>/`.

## Grill protocol

Interview the user ONE question at a time (never a questionnaire dump; use your
harness's question tool if it has one). Keep going until you can state their
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

- **Brownfield** (changes existing behavior): before finishing the interview,
  dispatch a fresh-context researcher (`roles/researcher.md`) on the affected
  area. Use its report to challenge the user's claims — this is where "user is
  mistaken" is most often caught.
- **Greenfield**: ask what existing systems it must integrate with; verify
  those integration points exist as described.

## Write the artifact

Fill `templates/intent.md` → `.sdlc/work/<slug>/intent.md`. Every claim
labeled. Open questions carried explicitly, never silently dropped.

## Gate

Tell the user:

> Review `.sdlc/work/<slug>/intent.md`. If it says exactly what you want, run:
> `<kit>/gates/approve.sh intent .sdlc/work/<slug>/intent.md`

STOP. Do not start the spec in this session even after approval — stage 2 runs
with fresh context so spec inherits the artifact, not your conversation bias.
