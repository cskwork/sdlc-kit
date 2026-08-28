---
name: sdlc-maintain
description: Stage 6 — turn an incident/bug/request into a diagnosed new intent.md and a lesson; the loop feeds itself. Use when something breaks or a maintenance task arrives.
---

# Stage 6: Maintain — closing the loop

Goal: any trigger (bug report, incident, monitoring alert, ticket) becomes a
*diagnosed* new `intent.md`, so the loop restarts with evidence instead of a
vague complaint. People triage and review the work; they no longer start it.

## Diagnose

1. Reproduce first. No repro → say so; capture what IS known. Never fix what
   you can't reproduce.
2. Trace the cause. Read `.sdlc/memory/INDEX.md` — has this failure mode been
   seen before? If a past lesson matches, cite it in the diagnosis.
3. Check the feature's `evidence.md`: was this covered by proof, or was it a
   verification gap? A gap is itself a lesson (`promote: skills/5-ship`).

## Route by size

- **Small, well-bounded fix** (single cause, obvious change, low blast
  radius): run a compressed loop in one pass, in a NEW feature dir
  `.sdlc/work/<fix-slug>/` (never reuse an old feature's dir — approvals are
  keyed per slug and re-approving would overwrite its records): mini `plan.md`
  (files + proof) → human approves plan gate → fix → verifier → `evidence.md`
  → ship gate. The two gates survive even for hotfixes.
- **Anything larger**: write `.sdlc/work/<new-slug>/intent.md` via
  `templates/intent.md`, with reproduction and diagnosis as embedded evidence
  (these claims are `[verified]` from birth). Then stage 1's gate applies and
  the full loop runs.

## Record the lesson (every incident, no exceptions)

Create `.sdlc/memory/lessons/YYYY-MM-DD-<slug>.md` via `templates/lesson.md`
and add ONE line to `.sdlc/memory/INDEX.md`:

```
- [tags,comma,separated] one-line summary → lessons/YYYY-MM-DD-<slug>.md
```

Memory discipline (context stays bounded):

- INDEX.md stays ≤ 50 lines. Over? Merge near-duplicates, drop entries whose
  lesson got promoted into a skill (the skill now carries it).
- A lesson that fires twice = promotion candidate: propose the exact skill
  edit to the human.
- Lessons state the trap and the correct move — short enough to read in
  seconds, specific enough to change behavior.
