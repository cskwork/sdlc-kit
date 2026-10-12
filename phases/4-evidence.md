# Phase 4: Evidence

Goal: prove the change works for every persona through the real interfaces,
score it, and deliver exactly what was verified.

## Run

Dispatch QA (`roles/qa.md`) with intent.md, PLAN.md, `refs/`, config.md and
the reviewed commit. QA runs the checks and every scenario, saves raw output
in `logs/`, adds scenarios for anything new it finds, and fills `evidence.md`
(`templates/evidence.md`): one row per scenario — PASS, FAIL with a cause,
or BLOCKED with what is missing. Scenarios are never dropped: `sdlc.sh next`
lists every ID the table needs, earlier QA-added ones included.
A cause is `plan` when the plan was wrong or missed something (a caller, a
data state, a rule, a scenario), and `code` when the plan was right and the
code is not.

## Score

`sdlc.sh score <slug>` checks evidence.md against PLAN.md — every planned
scenario present, every PASS and FAIL with its log, the commit is the one
checked out — then counts and routes:

1. a `plan` failure, or a `code` failure that also failed last round →
   **plan** (phase 2)
2. every must scenario PASS and PASS/total ≥ 95% → **deliver**
3. a must scenario BLOCKED, or only BLOCKED rows keep it under 95% →
   **human** (an environment is missing)
4. otherwise → **build** (phase 3)

BLOCKED counts as not passed. Each kind of return is capped at three; after
that the route is human. On a human route, show the human the score lines,
the failing rows and their logs; they resume with `sdlc.sh approve plan
<slug> --human` or drop the feature.

## Deliver

Deliver the verified commit by the project's rules and intent.md's target:
`local` needs nothing more; `pr` and `deploy` need the human's words, in
intent.md or, for a later or different target, in evidence.md's Delivery as
`Authorized: yes — "<their words>"`. Do not change code after scoring. Fill
evidence.md's Delivery: target, delivered commit per repository, the command
that checked it and its deciding output line. A changed policy is updated
where it is written in the same delivery, or its follow-up and owner go in
Delivery's `Policy:` line. Then:
- move verified facts from the refs (and `refs/learnings.md`, if any) into
  `knowledge`: one place per fact, updating a page rather than adding a
  duplicate;
- `sdlc.sh close <slug> shipped "<one line>"` — refused if the delivered
  tree differs from the verified one.

## Report

The bottom line — delivered where, and the score — then known issues
(failing non-must and BLOCKED rows) and the scenario table, which is the
human's own QA checklist.
