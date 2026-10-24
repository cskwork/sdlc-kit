# v2.11.0: Proof matched to the claim

Merged in [PR #54](https://github.com/cskwork/sdlc-kit/pull/54) to cskwork/sdlc-kit.

## Changes

- Safe disposable probes settle empirical uncertainty. Behavior evidence is kept separate from real-use claims.
- Numeric performance claims require repeated, comparable baseline and after samples, reporting median, spread, errors, and work completed.
- Behavior-preserving refactors require before/after behavior checks. They also require a deliberate assertion failure in a disposable worktree; a compile failure does not count.
- After two failed fixes that share a premise, test that premise before trying another fix.
- Plan review checks the proposed proof methods. Diff review and QA check the results.
- The optimization loop runs only on request, with an agreed target and effort limit.
- Redundant prose was shortened. Total instruction words went from 5,998 to 5,993, and all four standard phase bundles are below 2,500.

## Compatibility

- Five existing instruction files changed.
- No new workflow artifacts or profiles were added.
- Gates, caps, scripts, schemas, and templates are unchanged.

## Validation

- Shared and Pi local self-tests: 127 passed.
- Independent review: PASS.
- PR #54 CI passed on Linux, macOS, and Windows.

Source: [poteto-mode](https://github.com/cursor/plugins/tree/main/pstack/skills/poteto-mode)
