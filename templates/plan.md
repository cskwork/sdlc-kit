# Plan: <feature slug>

- From: spec.md (approved YYYY-MM-DD)

## Human summary (read this first)

<Five short sentences or fewer: what changes, the main risk, how it is
proven. Write it last, place it first.>

## Gate tier

<Any "yes" makes the tier human. The adversary re-checks every trip-wire.
Policy: AGENTS.md rule 3.>

- migration/schema: no · data deletion: no · public API/contract: no · security paths: no · infra/config: no · beyond spec scope: no
- Tier: agent | human — <reason if human>

## Files that change
- <path> (new | modified): <why>

## Data touched   <!-- the Side effects lens (roles/verifier.md) executes this list -->
<Every shape the files above write or read — table, column, type, event,
file — with its OTHER producers and consumers, and what happens to records
that predate the change.>
- <shape> · written | read · also produced/consumed by: <list> · pre-existing records: <what happens>

## Reach   <!-- the E2E lens runs one scenario per axis (roles/verifier.md) -->
<How else the changed behavior is met. Search every repository and tier that
calls it, not only the one being changed.>
- Entry: <each caller — screen, route, client, job, service — and what it sends or assumes>
- State: <states of existing records the change meets — made before it, in progress, finished, copied>
- Context: <conditions that change the outcome — tenant, category, locale, configuration, shared ownership>
- Picked: <R1.entry: the caller least like the one built against> · <R2.state: reached through the product's own steps> · <R1.context: …> | gap: <axis — why nothing else exists>
- Combined: <the picks that can happen in one real use, run together> | none — <why they cannot meet>

## Order of work
<Each step keeps configured checks passing. Add tests with the code they test.>
1. <step>

## Risks
- <rate limits, migrations, shared state, important quirks>

## Proof
<per spec requirement: what demonstrates it, using .sdlc/config.md commands,
its variants (roles/verifier.md) and every role/platform in scope>
- R1 → <test/command> · variants: R1.happy, R1.boundary, R1.negative · roles/platforms: <each, or n/a>
- Reach → <each picked scenario from Reach: test/command>

## Regression baseline   <!-- brownfield -->
- Commands: <exact commands run BEFORE changes>
- Saved to: .sdlc/work/<slug>/baseline.txt
- U1 → <how each untouched item is re-checked>

## Adversarial review
<objections + resolutions and the adversary's tier re-check; this records
that the review behind an --agent-adversary approval actually occurred>
- <objection>: <resolution>
- Gate tier re-check: <adversary verdict on the trip-wires>
- VERDICT: <NO BLOCKERS | n blockers, fixed>
