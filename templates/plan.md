# Plan: <feature slug>

- From: spec.md (approved YYYY-MM-DD)

## Files that change
- <path> (new | modified) — <why>

## Order of work
<each step leaves the tree green; tests land with their code>
1. <step>

## Risks
- <rate limits, migrations, shared state, load-bearing quirks>

## Proof
<per spec requirement: what demonstrates it, using .sdlc/config.md commands>
- R1 → <test/command>

## Regression baseline   <!-- brownfield -->
- Commands: <exact commands run BEFORE changes>
- Saved to: .sdlc/work/<slug>/baseline.txt
- U1 → <how each untouched item is re-checked>

## Deviations
<filled during build — what differed from plan and why>
