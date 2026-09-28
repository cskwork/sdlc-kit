# v0.19.0 — reach scenarios: test how a change is met, not only what it is given

The per-requirement floor (happy, boundary, negative) varies the input and
runs through the caller the change was built against. A change can pass all
of it and still fail for a second caller of the same behavior that sends an
older or smaller request (from one fix whose new validation refused a request
another screen had always sent).

## Changes

- **roles/verifier: Lens 1 step 5, Reach.** Beyond the floor, each change gets
  three scenarios run for real: `entry` (another caller of the same behavior —
  the one whose request differs most), `state` (a record the change did not
  create), `context` (a condition no requirement names). Named `<id>.entry`,
  `<id>.state`, `<id>.context`; an axis with nothing else to try gets a gap
  line. New report line and red flag (every scenario through one caller).
  The state is reached through the product's own steps (do the earlier step,
  leave, return, continue), not by acting on seeded data; picks that can
  happen in one real use also run together, since a defect that needs two of
  them at once passes every single-axis run.
- **templates/plan.md and skills/3-plan: Reach section.** Every caller of each
  changed behavior, found across the repositories and tiers that call it, with
  what each sends; the record states and conditions it meets; the three picked
  scenarios, how the product returns a user to the picked state, and which
  picks combine. The Proof section lists them. Compact route: a `- Reach:`
  line in templates/intent.md.
- **Contract tightening is a contract change.** Refusing input that existing
  callers send (a new validation, a newly required field, a narrowed type) is
  named under AGENTS.md rule 3's "public API or contract change";
  `tools/tripwire.sh` scans for it; the plan's Gate tier line reads
  `public API/contract`.
- **roles/adversary.** Plans: Reach must list every caller with what it sends;
  a missing caller blocks when the change refuses input it accepted before.
  Diffs: a new refusal with no check of what existing callers send blocks.
- **`profile: strict` enforces reach.** Once any requirement is proved,
  coverage needs a proving `<id>.entry`, `<id>.state` and `<id>.context`
  check (any requirement id) or a `gap: <id>.<axis>` line; a missing axis
  shows as `reach.<axis>` and is `uncovered` (docs/automation.md §4).
- **selftest:** a tightening plan trips the contract wire; strict coverage
  names each missing reach axis and accepts a check or gap per axis.

## Upgrade note

A `profile: strict` recipe whose features pass coverage today needs three
more lines per feature — a check or a gap for entry, state and context — or
`tools/verify.sh coverage` reports `reach.<axis>` uncovered. `advisory`
recipes, records, and gate formats are unchanged.
