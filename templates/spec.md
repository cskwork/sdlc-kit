# Spec: <feature slug>

- From: intent.md (approved YYYY-MM-DD)
- Type: greenfield | brownfield

## Human summary (read this first)

<Use no more than 10 short sentences. Write for a reader with NO technical
background: no code identifiers, no jargon (explain an unavoidable term in
the same sentence), describe what a user can or cannot do — not system
internals. State the problem, what will be built, what will not change, and
each flagged concern with your recommendation. One idea per sentence. If a
non-developer colleague could not follow a sentence, rewrite it. The human
should be able to approve the spec from this section and Flagged concerns
alone.>

## Requirements
<each traces to intent.md; each machine-checkable>
- R1: <requirement> (intent: "<quoted line>")

## Data shapes
<schemas, API contracts, migrations, and serialization end to end>

## Behavior: AS-IS → TO-BE
<For each flow, record what happens today and what happens after the change.
For brownfield work, cite explorer or browser evidence for AS-IS. For each
listed existing flow, behavior not changed in TO-BE belongs in "What stays
untouched." Include empty, huge, concurrent, unauthorized, and malformed
cases where they apply.>

| # | Flow | AS-IS (evidence) | TO-BE |
|---|------|------------------|-------|
| B1 | <flow> | <today, with source> | <after> |

## What stays untouched   <!-- brownfield: testable statements; becomes regression baseline -->
- U1: <existing behavior>; checked by <command/test>

## Release procedure
<one line; ship follows this; "none" is a valid deploy command>
- branch `feat/<slug>` → merge to `<target>` → push → deploy: `<command | none>`

## Flagged concerns
<List concerns for human decision at the gate.>
- [ ] <concern>; owner: <security/compliance/UX/...>

## Open questions from intent
- <question>: <answered: how | carried forward>

## Adversarial review
<objections raised and resolutions; this records that the review occurred>
- <objection>: <resolution>
