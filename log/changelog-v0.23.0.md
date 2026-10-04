# v0.23.0 — records written to be skimmed: bottom line first, bold carries the answer

The documents the loop writes were complete but hard to read: a spec's Human
summary could be ten sentences with no bottom line, and a long plan restated
the same facts across sections. This release adapts the Attention-kind output
style (github.com/alexgreensh/attention-span) to the kit's artifacts. That
project is AGPL-3.0; nothing is copied from it, the principles are restated
in the kit's own words. No new file, axis, gate, or check; scripts read
nothing that changed.

## Changes

- **AGENTS.md rule 8 — "Speak plainly, bottom line first."** Two tiers.
  *Reader parts* (reports, gate requests, questions, the Human summary of
  spec.md and plan.md, summary.md, intent.md's Goal line): the first sentence
  is the bottom line, then one line of context, then each point as a
  `**→ Lead-in.** rest` paragraph whose bold alone carries the answer and
  every warning; the decision or blocking question comes last.
  *Records* (evidence.md, spec and plan bodies, logs, handoff notes): each
  section opens with its conclusion, one idea per line, a fact written once
  and pointed at afterwards; no arrows or bold added. *Both*: numbers,
  thresholds, and scoped conditions stay exact; a warning is never cut for
  length; breadth is named and pointed at, never dumped or silently dropped;
  verbatim output and every line a script reads keep their exact form.
- **Changed from v0.22.0:** a report or gate request used to *start* with a
  context paragraph. It now starts with the bottom line; context follows in
  one line.
- **templates/spec.md, templates/plan.md** — the Human summary placeholder
  asks for a one-sentence bottom line plus five (spec) or three (plan)
  `**→**` points, instead of "ten short sentences" / "five short sentences".
  skills/2-spec and skills/3-plan say the same.
- **templates/summary.md** — each section opens with its point in bold; the
  `- Field:` lines kb.sh reads keep their form.
- **README.md, README.ko.md** — one paragraph, "Written to be skimmed".

## Before → after (a spec Human summary)

Before: eight unbroken sentences. The reader meets "drag handles", "the
ordering column", and "the export format" before learning that a decision
is being asked of them.

After:

> Teachers can re-order quiz questions by dragging them.
>
> **→ Students see the new order** from their next attempt; answers already
> submitted keep the order they were given in.
>
> **→ Reports and exports are unchanged.**
>
> **→ Decision needed:** quizzes with **more than 200 questions** would load
> slowly in the editor. Recommendation: allow re-ordering only below 200
> for this release.

## Upgrading

Nothing to migrate. Artifacts written before v0.23.0 stay valid; the new
shape applies to what is written next.
