---
name: sdlc-maintain
description: "Incident to diagnosed intent plus lesson. Triggers: bug report, incident, alert, ticket."
---

# Stage 6: Maintain

Goal: turn each bug report, incident, alert, or ticket into a diagnosed
`intent.md`. Restart the process with evidence, not a vague complaint. People
triage and review the work. They do not create the initial diagnosis.

Heartbeat: as soon as `.sdlc/work/<slug>/` exists, and at every sub-task
change, overwrite `.sdlc/work/<slug>/progress.md` with one line —
`maintain · <doing what> · <ISO timestamp>` (AGENTS.md rule 9).

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

**Headless, or no reachable reporter?** Do not stall on an interview nobody
will answer. Answer every question you can from the ticket text, the logs, the
deploy record, and the code — that is where most of these answers already
live — label each one `[verified: how]` or `[assumed: why]` in intent.md, and
carry only what is left. What remains is material only if a wrong answer would
change what gets built or exceed the authorized scope: those go to the human
as `## Material questions` and the loop stops for them (AGENTS.md rule 3).
Everything else is an `[assumed]` line and the diagnosis continues.

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

0. **Check the deployed source first.** Run `tools/refcheck.sh
   origin/<deploy-branch> [--deployed-sha <sha from the release system or
   runtime>] <suspected paths>` from the repo root. Exit 1 (drift): read
   every listed file via `git show <rev>:<path>` and name the revision behind
   each fact. Exit 2 (unknown ref, failed fetch, no repo): you know nothing
   about the running code — say exactly that; do not read the working tree
   as if it were live. Without `--deployed-sha` the deployed revision is
   UNKNOWN and the branch ref is a stand-in, never deployment evidence.
1. Run the cheap probes in `probes.md` (same directory) that match the
   symptom BEFORE dispatching researcher fan-out. Probes cost seconds and
   set direction; fan-out is for breadth the probes cannot cover.
2. Before forming a hypothesis or offering options, run fresh-context history
   and feasibility research under skill 1. Check whether this failure was fixed
   or reverted before, why, and whether it can be reproduced here.
3. Reproduce the issue first. **A fix needs the proof chain of AGENTS.md
   rule 6**: the failure before, the mechanism, the same reproduction passing
   after, the adjacent flows. If it cannot be reproduced, the honest outputs
   are a diagnosis, instrumentation, or a defensive change labelled as
   unconfirmed — never "fixed". An intermittent defect may stand on logs,
   traces, or an isolated deterministic reproduction, with the limitation
   stated.
4. Trace the cause. Read `.sdlc/memory/POLICY.md`, `.sdlc/memory/INDEX.md`,
   and `.sdlc/memory/DOMAIN.md`, then open lesson files whose tags match
   the task. Then ask the store directly whether this has been seen before:
   `tools/kb.sh search "<the error text>"`, `tools/kb.sh search "<the
   module or endpoint>"`, and `tools/kb.sh show <slug>` for the features
   the hits name — the search covers closed features, so a fix from two
   years ago comes back with its evidence and delivery record. Cite what
   you find by path in the diagnosis. Records of a checkout that no longer
   exists are reachable the same way with `--area <folder>`.
5. Separate the claim before hunting: "it does not react" is a state/handler
   problem; "it looks wrong/disabled" is a RENDERING problem until proven
   otherwise. They have different checklists.
6. **Class sweep.** When a found defect is an instance of a pattern (missing
   filter, guard, timeout, lock), grep the same file/module for the whole
   class and report a count table. Before changing any shared symbol,
   produce the call-site × guard table. One instance is a bug; the table is
   the scope, and it decides fix ordering.
7. Check the feature's `evidence.md` — a shipped feature is archived, so it
   sits at `.sdlc/archive/<slug>/evidence.md` (`tools/kb.sh show <slug>`
   names the path): was this covered by proof, or was it a verification gap? A gap is itself a lesson (`promote: skills/5-ship`).

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
**A waiver waives the REQUEST, never the proof.** It says "stop asking the
reporter", not "this is reproduced". Work that continues under a waiver is
unconfirmed by definition: it may ship as instrumentation, a defensive
change, or a documented hypothesis, and it says so in evidence.md's Bug
proof section. If it is later reproduced, the chain of AGENTS.md rule 6
applies in full before anything is called fixed.
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

Incidents use the same two routes as everything else (AGENTS.md "Two routes,
one contract"). There is no separate compressed loop.

- **Compact route.** Use it when one cause is reproduced, the changed file
  set is known, and affected behavior is limited. Create a new
  `.sdlc/work/<fix-slug>/` directory so prior approvals stay intact, and
  write ONE work artifact: `intent.md` with `- Track: compact`, carrying the
  reproduction and diagnosis as verified evidence plus the Compact route
  section (Files · Proof · Risk · Delivery target). Pass the intent gate,
  then build and verify under skill 4, then ship. No spec.md, no plan.md, and
  nothing downstream asks for one.
- **Full route.** Use it for everything else — an unclear cause, a wide blast
  radius, or risky ground. Create `.sdlc/work/<new-slug>/intent.md` from
  `templates/intent.md` with `- Track: full` and run Stage 1.

### Continuing older compressed work

A fix slug created by an older kit has a `plan.md` (perhaps an approved one)
and no `intent.md`. Nothing is lost and no gate is waived: write `intent.md`
with `- Track: compact`, carry the plan's files and proof into its Compact
route section, and pass the intent gate. The old plan approval stays on
record as history — it does not open build, because build on the compact
route checks the intent gate. `status.sh` prints this path for any such
feature. If the work turned out to be wider than compact allows, write
spec.md and run the full route instead; the intent gate still comes first.

**Recurrence cap: three fix loops for one symptom.** Before opening a
fix-slug, grep the symptom's tags in INDEX.md AND open features' harvests
(`grep -l <tag> .sdlc/work/*/harvest.md`) — in-flight lessons are not
merged yet. On the third match, stop fixing and start investigating: the repetition is
evidence that the cause found so far is not the cause. Widen the
investigation — what the three incidents share, which invariant keeps
breaking, what the earlier fixes actually changed — and take the finding to
the human as a design decision, with the promotion edit the tag has earned.
"It is architectural" is a conclusion the widened investigation may reach,
not a verdict to assert in place of one. Record the outcome in DOMAIN.md as a constraint at close.
Per-feature caps do not bound a defect that mints a new slug per incident;
this rule does.

## Record the lesson (only when it is reusable)

A lesson earns its place by changing what a future run does: a trap, a
non-obvious constraint, a wrong assumption that cost time. An incident whose
cause was local and obvious leaves no lesson, and "no lesson from this one"
is a valid, complete answer — INDEX.md is a 50-line budget, and filler
crowds out the entries that matter. Durable facts about the system are
domain candidates, not lessons.

When there is one, draft it in the fix feature's `.sdlc/work/<fix-slug>/harvest.md`
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
  replace promoted entries with one line — `- [tags] promoted →
  skills/<n> (was 3×)` — so the recurrence count survives the prune.
- When the same lesson recurs for a second time, propose the exact skill edit
  that would prevent it. (Distinct from the 3× tag rule in skills/5-ship:
  this fires on the same lesson, that one on the same tag.)
- State the trap and the correct move in each lesson. Keep it short and
  specific enough to change behavior.
