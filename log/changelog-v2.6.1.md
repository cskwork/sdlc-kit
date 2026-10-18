# v2.6.1 — real evidence that starts with "<" counts

Follow-up to the v2.6.0 review. One rule fix and one stronger test.

## Changes

- **Placeholder test for How settled.** v2.6.0 treated any How settled
  cell starting with `<` as an unfilled template placeholder, so real
  evidence such as `<200 ms p95, per the SLA page` was refused. Only a cell
  wrapped as a whole in `<…>` (the template's form) is a placeholder now;
  empty cells and cells holding only `-`, `—`, `?`, `.`, `n/a` or `tbd` are
  still refused.
- **Escaped pipes in Clarity rows.** The selftest now writes a placeholder
  that contains an escaped pipe (`<policy \| owner>`) and expects it refused.
  With the escape handling removed from the parser, that check fails, so a
  broken escape no longer passes unseen.
