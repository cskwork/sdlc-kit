# v0.23.0 — written to be skimmed: bottom line first

Human summaries could run ten sentences with no bottom line, and long
records restated facts. AGENTS.md rule 8 now adapts the Attention-kind
output style (github.com/alexgreensh/attention-span, AGPL-3.0: principles
restated, no text copied). No new file, axis, gate, or check; no
script-read line changed.

## Changes

- **Rule 8, three parts.** Messages and Human summaries: the bottom line
  first, one line of context, one `**→ Lead-in.**` paragraph per point,
  the decision last. Records: one idea per line, each fact stated once
  and then pointed at; a section without a verdict line opens with its
  conclusion. Always: numbers and scoped conditions exact, warnings never
  cut, verbatim output and script-read lines untouched.
- **Changed:** a message used to start with a context paragraph; it now
  starts with the bottom line.
- **templates/spec.md, plan.md:** the Human summary is the bottom line plus
  five (spec) or three (plan) `**→**` points, pointing at rule 8 instead of
  restating it. skills/3-plan points at the template.
- **templates/summary.md:** each section opens with its point in bold.

## Example (spec Human summary)

> Teachers can re-order quiz questions by dragging them; one decision is
> needed.
>
> **→ Students see the new order** from their next attempt; submitted
> answers keep theirs.
>
> **→ Reports and exports are unchanged.**
>
> **→ Decision:** quizzes over **200 questions** load slowly in the editor.
> Recommend re-ordering only below 200 for now.

Nothing to migrate: older artifacts stay valid.
