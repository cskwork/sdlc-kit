# v0.27.0 — one compact reviewer, input compatibility proof, safer close

Compact work needs one independent reviewer instead of several, brownfield
changes prove they still accept existing inputs, and close refuses two ways
proof could be swapped or source could drift unnoticed.

## Changes

- **Duplicate proof and late source drift are refused.** A receipt with a
  repeated check ID no longer replaces a configured check, including on
  accepted doctor/cleanup gaps. Source written by Git clean filters during
  baseline or pre-existing-failure validation is caught before `shipped`
  close; the source digest is no longer reused. Fresh verifiers receive
  `summary.md`.
  ([#25](https://github.com/cskwork/sdlc-kit/pull/25))
- **One reviewer for approved compact work.** One fresh reviewer applies all
  three verifier lenses and the complete adversarial diff on the same final
  source. The full route keeps three verifiers and a separate adversary.
  Current proof and reports are reused while source, recipe and upstream
  review inputs are unchanged; any change re-runs affected proof and the
  final diff review. Scenario floors, approval authority and caps are
  unchanged.
  ([#26](https://github.com/cskwork/sdlc-kit/pull/26))
- **Existing inputs stay accepted.** Before scope freezes, brownfield work
  records the callers and stored records it reads. Before input handling
  changes, build turns that evidence into checks for missing, empty, null,
  wrong-type and unknown values. Valid legacy input keeps its result, and
  invalid input is refused without a crash or partial state.
  ([#26](https://github.com/cskwork/sdlc-kit/pull/26))
- **Fewer false tripwire alarms.** Authorization and prohibition wording no
  longer trips the scanner, while removing a credential restriction (quoted,
  same-line or multiline) still does. Windows guidance adds a saved-script
  preflight for spaced paths.
  ([#26](https://github.com/cskwork/sdlc-kit/pull/26))
- **Faster verification reads.** The late whole-source recheck runs only
  when a failing check reached pre-existing validation, the one path that
  can write source after the digest. On a 4,000-file fixture,
  `tools/verify.sh check` dropped from a 1.057 s to a 0.613 s median (one
  macOS host, 7 runs each).
  ([#27](https://github.com/cskwork/sdlc-kit/pull/27))
- **Prompt length is held.** Compact review and proof reuse are stated once,
  in AGENTS.md rule 6; the build path is back to 5,245 words from 5,635. The
  selftest now gives every stage and role prompt a word ceiling, so growth
  must raise it in the same diff.
  ([#27](https://github.com/cskwork/sdlc-kit/pull/27),
  [#28](https://github.com/cskwork/sdlc-kit/pull/28))

## Compatibility

- **A receipt with repeated check IDs now closes the ship gate**
  (`GATE CLOSED: verification invalid`). Regenerate it with
  `tools/verify.sh run <slug>`.
- **Brownfield input changes need caller and stored-input evidence** before
  scope freezes.
- Recipe, receipt and machine-readable status formats are unchanged. Full
  route review, approval authority, authorization boundaries and caps remain.
- Contributors: editing a stage or role prompt past its budget fails
  `gates/selftest.sh` until the budget in that file is raised.

## Known limits

The small-task comparisons in #25 and #26 found no correctness advantage
for the kit over no kit, and the revised kit took about 9.9× no-kit's median
time. This release does not change that; where the time goes is not yet
measured per stage.
