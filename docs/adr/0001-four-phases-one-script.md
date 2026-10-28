# ADR 0001: Four phases and one script instead of six stages and many tools

- **Status:** Accepted (v2.0.0)
- **Source:** `log/changelog-v2.0.0.md`, `sdlc.sh`, `SKILL.md`

## Context

Up to v0.27.0 the kit ran six stages (intent → spec → plan → build →
evidence → maintain, per the v0.27.0 README) with a separate ship gate,
about 23,700 words of prompts, fifteen templates, and about 7,000 lines of scripts split across `init.sh`, `gates/` and `tools/`. The
v2.0.0 changelog records why that stopped working:

- In the PR #26 comparison, two small tasks took a median 85 s without the kit
  and 842–916 s with it, and both arms passed all 48 product assertions.
- Four local stores held 19 open features and no closed one; some could not
  close because of formatting in a delivery record.
- `gates/status.sh` took over 30 s on a large monorepo.

## Decision

Rebuild around four phases (Intent → Plan → Build → Evidence) and one script,
`sdlc.sh`, with the subcommands `init`, `new`, `status`, `next`, `check`,
`approve`, `review`, `score` and `close`. Spec, Ship and Maintain fold into
these phases. Three roles (scout, reviewer, QA) replace researcher, verifier
and adversary.

## Consequences

- The changelog reports 3,922 words of prompts and templates and 477 script
  lines at v2.0.0, and `status` on a 12-feature legacy store in 0.2 s.
- It is a breaking contract: v0 features show as `legacy` in `status` and must
  be finished with the v0.27.0 tag or closed as dropped.
- One script is a single point of parsing logic; `tests/selftest.sh` carries
  that risk by driving a real feature through all four phases on a fixture.

## Alternatives considered

- **Trim the six-stage kit.** The changelog's evidence was about overall cost
  and features never closing, not one slow stage, so trimming was not chosen.
- **A runtime or service.** Not chosen; the kit stays files plus a shell
  script so it works in any harness that can read a skill folder.
