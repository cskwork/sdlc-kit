# v2.10.0 — Intent reads top-down for a human

intent.md now opens with a three-line Bottom line and keeps the agent's
working record at the bottom. An answer to a blocking question no longer
counts as approval of the whole intent.

## Why

- **The human could not find the decision.** Long Clarity cells (one AS-IS
  cell held ten facts with file:line references) buried what needed the
  human. Risks mixed approval-level warnings with evidence limits.
- **A question's answer was recorded as approval.** A requester answered one
  blocking question; the agent passed those words to
  `approve intent --human` and went on to plan without asking "is this what
  you want?".

## Changes

- **`## Bottom line`** at the top: Changes (now the outcome; Understood as
  drops its Outcome line), Left out and Needs you, which cite the Out of
  scope item or risk instead of restating it.
- **One fact, one place inside intent.md:** other sections cite O2, F3, Q1
  or Request instead of restating.
- **Order:** Bottom line, Request, Understood as, Risks, Delivery, Blocking
  questions, then `---` and the agent's record: Terms, Clarity, Facts.
- **`## Facts`:** Clarity cells are one sentence citing `F1`-style IDs; the
  proof sits one fact per line in Facts.
- **Writing rule** in phase 1: one idea per line, bold lead-in, exact
  numbers, warning on the line it guards, the requester's language with
  headings, field labels and Clarity words in English.
- **Gate:** show Bottom line, Risks and any assumed Clarity area, ask once,
  end the turn. `approve intent --human` refuses a note of 12 bytes or more
  found inside a resolved blocking-question line, compared as the parser
  reads it (comments dropped, `*` and backticks stripped, case folded).
  Limit: a generic phrase that is also part of an answer ("yes, go ahead")
  is refused too; record the human's fuller words.

## Compatibility

Sections are still read by heading, in any order; the parser only adds
resolved answers for the Gate check. Older
intent.md files still pass; Bottom line and Facts are optional to the script.
