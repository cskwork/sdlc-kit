# Spec: <feature slug>

- From: intent.md (approved YYYY-MM-DD)
- Type: greenfield | brownfield

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
