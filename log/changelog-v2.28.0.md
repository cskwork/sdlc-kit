# v2.28.0: An added or changed database query needs Proof for the claim

## Problem

A change could add or rewrite a SELECT that passed every test and review yet ran ten times slower on production-sized data, because Proof for the claim covered only explicit performance and refactor claims. A correlated subquery placed inside a join condition is correct on a small fixture and only shows its cost on the largest real scope.

## Changes

- **`phases/3-build.md`:** Proof for the claim now also applies to an added or changed database query. *Query* proof is base and after actual plans (`EXPLAIN ANALYZE` or equivalent) on the largest realistic data scope, with time and plan shape. It fails on time over 2x or 500 ms, a full scan repeated per outer row, a lost hash join, or a correlated subquery added to a join condition or select list on a large table; a scoped set filter is preferred. A missing index becomes a proposed DDL file, not applied.
- **`roles/reviewer.md`:** plan and diff review block any change that needs Proof for the claim without a planned method or without the proof in `logs/`.
- **`roles/qa.md`:** changed-query scenarios need Proof for the claim, like performance and refactor scenarios.

## Verification

CI is not used for this repository; local checks instead. Prompt budgets: total 5991/6000 words, plan 2497, build 2149, evidence 2118 (each ≤ 2500); every linked phase/role/template path exists. `node --test tests/*.test.mjs`: 207/220 pass; the 13 failures are HTTP/TUI/lock timeouts in the to-do tests, which also fail on the previous release commit (6 of 168 in the same files), and this release changes no code. The rest of `tests/selftest.sh` was not run: a local hook blocks its `git reset --hard` step.
