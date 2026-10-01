# v0.21.0 — Jev QA mode: a switchable way to check screens

The verifier's UI checks can now run through Jego (Jev on Ego Lite): each UI
scenario is a plain-language goal with the texts that must appear, the result
is re-checked in a fresh tab, and one HTML report (screenshots, time, cost per
scenario) goes to the ship gate. The default stays the agent driving a browser
itself; nothing changes until someone switches.

## Changes

- **tools/qa-mode.sh:** `show`, `get`, `set <agent|jev> [--project]
  [--jev-dir <path>]`, `check`. `set` saves to
  `${XDG_CONFIG_HOME:-~/.config}/sdlc-kit/config`, so the choice holds in
  every project until switched back; `.sdlc/config.md` `qa_mode:` overrides it
  for one project. Unknown values fall back to `agent`. `check` reports whether
  Jego can run (checkout, `ego-browser`, `node`, a TypeSafe key — presence
  only, never printed).
- **roles/verifier.md:** in jev mode the E2E lens runs UI scenarios through
  `docs/jev-qa.md`; when `check` fails or a scenario needs what Jego cannot
  drive (upload, canvas, iframe), it uses the agent way for that scenario and
  says why.
- **docs/jev-qa.md:** switching, writing scenarios from the plan, running
  `qa/run.mjs`, reviewer notes, the report, and what counts as evidence (the
  agent's own DONE never does; quote the deciding lines, not a bare path).
- **init.sh:** new projects get empty `qa_mode:` and `jev_dir:` lines (empty =
  the user default). Existing configs need no change.
- **SKILL.md:** routes "use jev for QA" / "jev로 QA" / "switch QA back to
  agent" to `tools/qa-mode.sh`.
- **gates/selftest.sh:** new `qa_mode` section — default agent, a switch is
  remembered across projects, a project setting wins, unknown modes are
  refused, and `check` fails closed without a usable Jego.
