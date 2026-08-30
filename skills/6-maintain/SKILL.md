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
PR, or run a pre-approved runbook. A wrong diagnosis may produce a wrong
document, but it must never change production. Handle rollback through the plan gate or the project's
rehearsed rollback runbook. Never revert production directly from this stage.

## Intake (before any research or hypothesis)

Ask the reporter these five questions in one message. Skip any already
answered. Each answer kills hypothesis classes for free; a researcher
fan-out dispatched before these answers wastes most of its budget.

1. Which exact control did you use? (button label / menu item / gesture)
2. What did you see immediately after? (nothing at all, a popup, an error,
   a partial change) — "nothing at all" and "something wrong appeared" are
   different bug classes.
3. Which environment and when? (prod/stg/dev, URL, approximate time — this
   picks the deploy ref and the log window)
4. What account/role? (permissions often hide or disable the control)
5. Do you have a console log, network capture, or screenshot? If not, can
   you reproduce once with DevTools open?

Record the answers in `intent.md` under Evidence. Track question 5
explicitly (see Evidence tracking below).

## Diagnose

0. **Check the deployed ref first.** Run `tools/refcheck.sh
   origin/<deploy-branch> <suspected paths>` from the repo root. On DRIFT,
   read every file via `git show <ref>:<path>` and name the ref for each
   fact in every report. A diagnosis of the working tree may describe code
   nobody is running.
1. Run the cheap probes in `probes.md` (same directory) that match the
   symptom BEFORE dispatching researcher fan-out. Probes cost seconds and
   set direction; fan-out is for breadth the probes cannot cover.
2. Before forming a hypothesis or offering options, run fresh-context history
   and feasibility research under skill 1. Check whether this failure was fixed
   or reverted before, why, and whether it can be reproduced here.
3. Reproduce the issue first. If it cannot be reproduced, say so and record
   what is known. Do not fix an issue you cannot reproduce.
4. Trace the cause. Read `.sdlc/memory/POLICY.md`, `.sdlc/memory/INDEX.md`,
   and `.sdlc/memory/DOMAIN.md`, then open lesson files whose tags match
   the task. Check whether this failure mode has occurred before; if a past
   lesson matches, cite it in the diagnosis.
5. Separate the claim before hunting: "it does not react" is a state/handler
   problem; "it looks wrong/disabled" is a RENDERING problem until proven
   otherwise. They have different checklists.
6. **Class sweep.** When a found defect is an instance of a pattern (missing
   filter, guard, timeout, lock), grep the same file/module for the whole
   class and report a count table. Before changing any shared symbol,
   produce the call-site × guard table. One instance is a bug; the table is
   the scope, and it decides fix ordering.
7. Check the feature's `evidence.md` — a shipped feature is archived, so it
   sits at `.sdlc/archive/<slug>/evidence.md`: was this covered by proof, or
   was it a verification gap? A gap is itself a lesson (`promote: skills/5-ship`).

## Evidence tracking

Reproduction evidence requested from a human tends to evaporate in chat.
Make its state explicit in `intent.md`:

    - reproduction evidence: requested 2026-08-29 (console+network capture)
      → update to: received <date> | waived-by-human <date, why>

A diagnosis that ships while evidence is `requested` must say so in its
report and in any ticket it produces. Do not silently drop the request.
Ask at most twice. After the second unanswered request, either proceed
with `waived-by-agent <date> — unreproduced; diagnosis stays [assumed]`
carried into every downstream artifact, or close the fix-slug handed-off
with the reporter's ticket key. Never re-request a third time.
If `.sdlc/config.md` has empty `test:`/`lint:` commands, record one line of
verification debt in the artifact: what could not be run, and what manual
check replaced it.

## Adversarial review of the diagnosis (before the fix plan is approved)

A confident diagnosis built without reproduction NEEDS hostile review.
Dispatch fresh-context adversaries (rule 5 of AGENTS.md) with these four
standing assignments — each has caught real errors:

1. **Recount.** Redo every enumeration independently (counts of queries,
   call sites, guards). Watch for aliases and pattern variants the first
   pass missed.
2. **Propagation proof.** For each claimed error mechanism, prove the error
   can actually REACH the code the fix would touch. A layer that swallows
   its own errors refutes the fix above it.
3. **Zero-risk attack.** Attack every "zero risk", "never happens",
   "always" phrase. Enumerate the states where the impossible thing is
   normal today.
4. **Rival hypothesis.** Propose at least one alternative that fits the
   same evidence, and name the single observation that would distinguish it.

## Route by size

- **Compressed loop.** Use it only when one cause is reproduced, the changed
  file set is known, and affected behavior is limited. Create a new
  `.sdlc/work/<fix-slug>/` directory so prior approvals stay intact. Write a
  mini `plan.md` with files and proof. Pass the plan gate as usual (tiered /
  lazymode, AGENTS.md rule 3), then build and verify
  under skill 4. Create `evidence.md` and stop at the ship gate.
- **Full loop.** Use it for all other changes. Create
  `.sdlc/work/<new-slug>/intent.md` from `templates/intent.md`. Include the
  reproduction and diagnosis as verified evidence, then run Stage 1.

**Recurrence cap: three fix loops for one symptom.** Before opening a
fix-slug, grep INDEX.md for the symptom's tags. On the third match the
defect is architectural, not a bug: STOP, write the promotion edit the tag
already earned, and take it to the human as a design decision — not a
fourth fix. Record the outcome in DOMAIN.md as a constraint at close.
Per-feature caps do not bound a defect that mints a new slug per incident;
this rule does.

## Record the lesson (every incident, no exceptions)

Draft the lesson in the fix feature's `.sdlc/work/<fix-slug>/harvest.md`
(INDEX.md, DOMAIN.md, and lessons/ are written only at close — AGENTS.md
rule 4). The
close merge materializes it as `.sdlc/memory/lessons/YYYY-MM-DD-<slug>.md`
via `templates/lesson.md` plus ONE line in `.sdlc/memory/INDEX.md`:

```
- [tags,comma,separated] one-line summary → lessons/YYYY-MM-DD-<slug>.md
```

Memory discipline (context stays bounded):

- Keep INDEX.md at 50 lines or fewer. If it grows past the limit, merge
  near-duplicates, drop superseded entries (their subject changed), and
  remove entries already promoted into a skill.
- When the same lesson recurs for a second time, propose the exact skill edit
  that would prevent it. (Distinct from the 3× tag rule in skills/5-ship:
  this fires on the same lesson, that one on the same tag.)
- State the trap and the correct move in each lesson. Keep it short and
  specific enough to change behavior.
