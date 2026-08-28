# Spec: <feature slug>

- From: intent.md (approved YYYY-MM-DD)
- Type: greenfield | brownfield

## Human summary (read this first)

<Plain language, ≤10 short sentences. Assume the reader lost the thread.
Cover: what problem this solves · what will be built, concretely · what will
NOT change · the decisions waiting at this gate (the flagged concerns, one
line each, with your recommendation). One idea per sentence. No jargon.
Everything below this section is the agent-facing contract; the human may
read only this summary plus Flagged concerns and still gate safely.>

## Requirements
<each traces to intent.md; each machine-checkable>
- R1: <requirement> (intent: "<quoted line>")

## Data shapes
<schemas, API contracts, migrations, serialization — end to end>

## Behavior
<flows, states, error handling. Edge cases explicit: empty/huge/concurrent/unauthorized/malformed>

## What stays untouched   <!-- brownfield: testable statements; becomes regression baseline -->
- U1: <existing behavior> — checked by: <command/test>

## Flagged concerns
<what an analyst would escalate — human resolves at the gate>
- [ ] <concern> — owner: <security/compliance/UX/...>

## Open questions from intent
- <question> → <answered: how | carried forward>

## Adversarial review
<objections raised and how each was resolved — proof review happened>
- <objection> → <resolution>
