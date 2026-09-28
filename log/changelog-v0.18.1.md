# v0.18.1 — narrow the v0.18.0 reuse rule

v0.18.0 came from one feature. This patch keeps the probe and the reuse
option, and removes what was shaped by that one case.

## Changes

- **skills/1-intent:** the "Existing analogous flow" probe no longer lists
  example transitions; it searches by the behavior the request names. The
  Reuse rule is shorter: include the reuse option or say why it does not fit.
- **roles/researcher:** step 1b shortened to the general rule.
- **roles/adversary 4b:** blocking only when a researcher reported a concrete
  existing flow (file:line) and the options omit it without a reason. A
  missing or "none found" report is non-blocking.
- **log/changelog-v0.18.0.md:** the story is one line.
