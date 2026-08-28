---
name: sdlc-maintain
description: "Incident to diagnosed intent plus lesson. Triggers: bug report, incident, alert, ticket."
---

# Stage 6: Maintain

Goal: turn each bug report, incident, alert, or ticket into a diagnosed
`intent.md`. Restart the process with evidence, not a vague complaint. People
triage and review the work. They do not create the initial diagnosis.

## Running headless? Sandbox first

This stage may start without a human through cron, a webhook, or a ticket. Run
it stateless in a sandbox with scoped, read-only access to logs, metrics, and
code. Do not provide standing production credentials or deploy tools. The
agent may act only through gated routes: write an `intent.md`, open a review
PR, or run a pre-approved runbook. A wrong diagnosis may produce a wrong document, but it must never
change production. Handle rollback through the plan gate or the project's
rehearsed rollback runbook. Never revert production directly from this stage.

## Diagnose

0. Before forming a hypothesis or offering options, run fresh-context history
   and feasibility research under skill 1. Check whether this failure was fixed
   or reverted before, why, and whether it can be reproduced here.
1. Reproduce the issue first. If it cannot be reproduced, say so and record
   what is known. Do not fix an issue you cannot reproduce.
2. Trace the cause. Read `.sdlc/memory/INDEX.md` and
   `.sdlc/memory/DOMAIN.md`, then open lesson files whose tags match the task.
   Check whether this failure mode has occurred before. If a past lesson matches, cite it in the diagnosis.
3. Check the feature's `evidence.md`: was this covered by proof, or was it a
   verification gap? A gap is itself a lesson (`promote: skills/5-ship`).

## Route by size

- **Compressed loop.** Use it only when one cause is reproduced, the changed
  file set is known, and affected behavior is limited. Create a new
  `.sdlc/work/<fix-slug>/` directory so prior approvals stay intact. Write a
  mini `plan.md` with files and proof. Get plan approval, then build and verify
  under skill 4. Create `evidence.md` and stop at the ship gate.
- **Full loop.** Use it for all other changes. Create
  `.sdlc/work/<new-slug>/intent.md` from `templates/intent.md`. Include the
  reproduction and diagnosis as verified evidence, then run Stage 1.

## Record the lesson (every incident, no exceptions)

Create `.sdlc/memory/lessons/YYYY-MM-DD-<slug>.md` via `templates/lesson.md`
and add ONE line to `.sdlc/memory/INDEX.md`:

```
- [tags,comma,separated] one-line summary → lessons/YYYY-MM-DD-<slug>.md
```

Memory discipline (context stays bounded):

- Keep INDEX.md at 50 lines or fewer. If it grows past the limit, merge
  near-duplicates and remove entries already promoted into a skill.
- When the same lesson recurs for a second time, propose the exact skill edit
  that would prevent it.
- State the trap and the correct move in each lesson. Keep it short and
  specific enough to change behavior.
