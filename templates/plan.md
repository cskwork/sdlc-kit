# Plan: <feature slug>

- From: spec.md (approved YYYY-MM-DD)

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
