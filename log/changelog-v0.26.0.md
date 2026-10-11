# v0.26.0 — clearer guidance, stronger verification, practical QA steps

Users can follow shorter instructions, check delivered changes themselves,
and rely on stronger verification evidence. This release includes all changes
since the published v0.22.0 release, including the v0.23.0–v0.25.0 updates.

## Changes

- **Plain-language documentation.** The site explains the loop for readers
  who do not code. Messages and human summaries lead with the result;
  records state each fact once. English and Korean route summaries agree
  with the stage instructions.
  ([#18](https://github.com/cskwork/sdlc-kit/pull/18),
  [#19](https://github.com/cskwork/sdlc-kit/pull/19),
  [#23](https://github.com/cskwork/sdlc-kit/pull/23))
- **QA steps a person can follow.** Ship writes `qa-guide.md` with the
  environment, data, menu path, numbered actions, expected results,
  cleanup, and checks the agent did not run. The final report quotes it;
  credentials remain placeholders with their source.
  ([#20](https://github.com/cskwork/sdlc-kit/pull/20))
- **No shipping unit escapes the loop.** A store covers its directory tree;
  a monorepo unit without its own `.sdlc/` uses the nearest store above it.
  History research explicitly searches reverted and rolled-back attempts.
  Intent match now blocks an implementation that contradicts its origin
  unless the origin owner's decision is recorded in **Origin overrides**.
  ([#21](https://github.com/cskwork/sdlc-kit/pull/21))
- **Verification rejects missing proof.** Baseline output must still exist
  and match its recorded hash. Readiness retries count command execution
  time against the elapsed timeout; bounded process cleanup has its own
  grace period. On POSIX systems, cleanup also stops surviving descendants
  after their process-group leader exits.
  ([#22](https://github.com/cskwork/sdlc-kit/pull/22))
- **Real delivery exercised in CI.** A persisted CLI fixture drives a
  feature and bug fix through the lifecycle, including before/after proof,
  delivery, close, and knowledge readback. CI runs it alongside gate,
  receipt, and process-runner regressions on Linux, macOS, and Windows.
  The software-factory guide connects runnable slices, scoped quality
  checks, resume, and final-source verification to the existing stages.
  ([#22](https://github.com/cskwork/sdlc-kit/pull/22))
- **Less repeated guidance, clearer boundaries.** Shared rules have one
  source; the complete memory-merge procedure is required at close or
  idle-harvest merge. Read-only proposals do not start implementation.
  Small deviations can remain compact while all eligibility criteria hold;
  a sixth deviation stops compact work for human reassessment at every
  lazymode. Re-gates follow the configured approval authority. Full reviewer
  contracts, quality planning, and round caps remain required.
  ([#23](https://github.com/cskwork/sdlc-kit/pull/23))

## Compatibility

- Recipe, receipt, and machine-readable status formats are unchanged.
  Approval authority, authorization boundaries, and review caps remain.
- **Missing or changed baseline output now fails closed.** Recapture the
  baseline before continuing verification when its evidence is unavailable
  or no longer matches.
- Older artifacts remain valid. Features closed before v0.24.0 do not need
  a retroactive QA guide; existing configs are not rewritten.
