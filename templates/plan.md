# Plan: <feature slug>

- From: spec.md (approved YYYY-MM-DD)

## Human summary (read this first)

<Five short sentences or fewer: what changes, the main risk, how it is
proven. Write it last, place it first.>

## Gate tier

<Any "yes" makes the tier human. The adversary re-checks every trip-wire.
Policy: AGENTS.md rule 3.>

- migration/schema: no · data deletion: no · public API: no · security paths: no · infra/config: no · beyond spec scope: no
- Tier: agent | human — <reason if human>

## Files that change
- <path> (new | modified): <why>

## Order of work
<Each step keeps configured checks passing. Add tests with the code they test.>
1. <step>

## Risks
- <rate limits, migrations, shared state, important quirks>

## Proof
<per spec requirement: what demonstrates it, using .sdlc/config.md commands>
- R1 → <test/command>

## Regression baseline   <!-- brownfield -->
- Commands: <exact commands run BEFORE changes>
- Saved to: .sdlc/work/<slug>/baseline.txt
- U1 → <how each untouched item is re-checked>
