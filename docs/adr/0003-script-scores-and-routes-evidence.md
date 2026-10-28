# ADR 0003: The script, not the agent, scores evidence and routes failures

- **Status:** Accepted
- **Source:** `sdlc.sh` (`score`, `score_counts`, `stopped`, `derive`),
  `phases/4-evidence.md`, `SKILL.md` rules 5–6

## Context

An agent that judges its own results tends to call them good enough, and a
loop with no limit can retry forever.

## Decision

`sdlc.sh score` reads `evidence.md` and decides where work goes next:

- a FAIL with cause `plan`, or the same code FAIL after a build return → Plan;
- every must scenario PASS and at least 95% of rows PASS → deliver;
- a BLOCKED must scenario, or no FAIL but not enough PASS → the human;
- otherwise → Build.

BLOCKED counts as not passed. Every PASS/FAIL needs a non-empty log inside the
feature folder. Scenarios can only be removed by the human. Three review FAILs,
three returns to Plan, or three returns to Build stop the loop until
`approve plan --human`.

## Consequences

- Routing is deterministic and testable; `tests/selftest.sh` covers the
  boundaries and caps.
- The thresholds (95%, three returns) are fixed in the script, not
  configurable per project.
- The script trusts the result rows; it checks that logs exist, not what they
  say. Independence comes from QA running in a fresh context (`roles/qa.md`).

## Alternatives considered

- **Agent decides the route.** Rejected: the kit's premise is that the author
  does not grade its own work.
- **Unlimited retries.** Rejected: caps make a stuck feature visible to the
  human instead of consuming time.
