# Phase 4: Evidence

Goal: prove the change works for every persona through the real interfaces,
score it, and ship exactly what was verified.

## Run

Dispatch QA (`roles/qa.md`) with intent.md, PLAN.md, `refs/`, config.md and
the reviewed commit. QA runs the checks and every scenario, saves raw output
and scripts in `logs/`, adds scenarios for anything new it finds, and fills
`evidence.md` (`templates/evidence.md`): one row per scenario — PASS, FAIL
with a cause (`plan` or `code`), or BLOCKED with what is missing. Scenarios
are never dropped: `sdlc.sh next` lists every ID the table needs, earlier
QA-added ones included.

## Score

`sdlc.sh score <slug>` checks evidence.md against PLAN.md — every planned
scenario present, every PASS and FAIL with its log, the commit is the one
checked out — then counts and routes:

1. a `plan` failure, or a `code` failure that also failed last round →
   **plan** (phase 2)
2. every must scenario PASS and PASS/total ≥ 95% → **deliver** (ship)
3. a must scenario BLOCKED, or only BLOCKED rows keep it under 95% →
   **human** (an environment is missing)
4. otherwise → **build** (phase 3)

BLOCKED counts as not passed. On a human route, show the human the score lines,
the failing rows and their logs; they resume with `sdlc.sh approve plan
<slug> --human` or drop the feature. For a BLOCKED row, offer all three:
remove the scenario (the approval records the removal and the gap), retry
with what is missing and a limit on attempts, or drop. When intent.md, the
HEADs a PASS bound (not a working tree) and PLAN.md outside Scenarios are
unchanged, the approval keeps the review PASS: go straight to QA.

## Ship

Ship the verified commit by the project's rules and intent.md's Ship to:
`local` needs nothing more; `pr` and `deploy` need the human's words, in
intent.md or, for a later or different target, in evidence.md's Shipping as
`Allowed: yes — "<their words>"`. Do not change code after scoring. Fill
evidence.md's Shipping: Ship to, the shipped commit per repository, the
command that checked it and its deciding output line. A changed policy is
updated where it is written in the same delivery, or its follow-up and owner
go in Shipping's `Policy:` line. Then:
- move verified facts from the refs (and `refs/learnings.md`, if any) into
  the `memory` folder: one place per fact, updating a page rather than adding a
  duplicate, and a term settled here into its `glossary.md`; a fact that
  rests on code ends with its file (path from the project root) and the
  shipped commit of that file's repository, after re-checking the fact
  there if the file changed since it was checked:
  `[verified: <file> @ <short sha>]`;
- add the saved scripts (`logs/scripts/`) worth keeping to the project's
  `e2e` suite, or name them as a follow-up in Shipping;
- `sdlc.sh close <slug> shipped "<one line>"` — refused if the shipped
  tree differs from the verified one.

## Report

The bottom line — shipped where, and the score — then known issues
(failing non-must and BLOCKED rows) and the scenario table, which is the
human's own QA checklist.
