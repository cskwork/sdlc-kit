# v0.16.0 — area pages record how a figure is calculated

v0.15.0 gave a product area one home for its business rules (P-numbers). A
menu that shows counts, rates, scores or charts had nowhere to say what a
number on screen actually means — "what is counted, out of what, real-time
or batch" lived in someone's head or nowhere. This release adds an optional
Numbers section to the area page, numbered N1… with the same permanence and
filing rules as a business rule. Gates, approvals, the `--json` schema, and
`kb.sh`'s rule count are unchanged.

## Changes

- **`templates/area.md`** gains an optional **Numbers (통계 산정)** section
  between Business rules and How it works: one line per on-screen figure,
  named as the screen labels it, recording what it counts, out of what,
  whether it is real-time or batch (job, refresh, data-as-of), its source,
  and who set it. Delete the section for an area with no figures. N-numbers
  follow the P-number rules: permanent, a changed figure is edited in place,
  a retired one stays struck through.
- **The loop treats a figure like a business rule** wherever omitting it
  would leave it unprotected:
  - `templates/spec.md`'s "Business rules touched" section gains a sibling
    line for numbers touched (kept/changed/new), so the Side effects
    verifier re-checks a figure it did not set out to change, the same way
    it already re-checks a P-number.
  - Ship's retrospective (`skills/5-ship/SKILL.md`) writes a figure a
    feature sets, changes, or retires as an area candidate, same as a
    business rule.
  - `templates/harvest.md`'s Area candidates format gains the `N<n>`
    line shape the close merge numbers, next to the existing `P<n>` one.
  - AGENTS.md rule 4's "what goes where" table gains a row: a figure's
    calculation method files to the area page's Numbers, written by the
    close merge on a shipped close only — same as a business rule.
- **README.md / README.ko.md**: the "Knowledge is filed by product area"
  paragraph and the memory-tree comment now mention the optional Numbers
  section.

## Compatibility

An area page with no Numbers section is unaffected: the section is
optional and `kb.sh`'s Rules column stays a P-number count only (a store
with only P-numbers renders identically to before). No script parses the
`N<n>:` line; filing it is an instruction to the agent, exactly like a
`P<n>:` line.

## Validation

- `bash gates/selftest.sh` → `SELFTEST PASS` (unchanged; the smoke test
  does not exercise the Numbers section, and this change does not touch
  the scripts it does cover — gate mechanics, lazymode, close proof,
  product-area filing by menu path).
