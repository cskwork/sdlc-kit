# v2.5.0 — optional e2e runner adapter, carried inside the kit

v2.4.0 made QA save a script per scenario so later rounds re-run instead of
re-driving by hand. This adds a runner those scripts can be written for,
tried first on one feature's four browser scenarios against a dev server.

## Changes

- **`adapters/e2e/`.** With config `qa_runner: e2e`, QA writes each browser
  or mobile scenario as an [e2e](https://www.npmjs.com/package/e2e) test in
  two layers tagged with the scenario ID: `det` (exact steps, locator, URL
  and request assertions, no model) decides PASS or FAIL; `agent` (optional)
  uses `agent.act` for churning steps and replays without model calls on
  later runs. Measured on the trial: `det` 24.6–25.9 s per run, 0 model
  calls, 2 of 2 runs green; `agent` 47.8 s and 10 model calls on an empty
  cache, then 32.6 s and 2 calls (both `agent.assert`, which never caches)
  with 3 of 3 act steps replayed. A hand-driven script covering a wider
  scope took 292 s.
- **Portable.** The kit vendors e2e's own agent guide (`skills/e2e`,
  Apache-2.0, `LICENSE` and `NOTICE` kept) pinned in `adapters/e2e/VERSION`
  (e2e 0.20.0, @e2e-dev/web 0.14.0, Node `^22.22.3 || >=24.8.0`), so an
  agent can write and debug tests offline. `adapters/e2e/update.sh
  [version]` refreshes it from npm. The project installs the runner itself.
- **`qa_session:`.** e2e does not follow windows an app opens, so a sign-in
  through a popup, SSO or a device prompt cannot be driven. `qa_session`
  names a command that signs in and writes the storage the setup template
  injects before saving a named session.
- **Popup bridge.** e2e does not follow windows an app opens. The template
  `popup-bridge.ts` turns `window.open` into a full-viewport iframe in the
  same tab, with `window.opener`, `close()` and `focus()` working inside it,
  so same-origin popups that talk through opener and postMessage run
  unchanged. Tried on two document-viewer popups: deterministic run 25.0 s
  and 24.1 s, 4 of 4 both times; an agent step inside the popup took 2 model
  calls (12.3k tokens) first and 0 on replay. Screenshots matched real
  popups except window size. Not covered: cross-origin popups,
  `target="_blank"` links, `noopener`.
- **Opening can write.** In that trial, opening a one-page assignment in its
  viewer marked it submitted. QA's preflight now treats no step as read-only
  until it knows what the step writes, and drives only accounts whose state
  may change.
- **Templates.** `e2e.config.ts`, `session.setup.e2e.ts`,
  `scenario.e2e.ts` (both layers) and `popup-bridge.ts`, checked with `e2e list` and `tsc`.
- **Limits written down from the trial.** An agent step absorbs a renamed
  control and still passes, so the `det` locator stays the gate. A wrong
  expectation after a correct replay evicts the correct recording. A replay
  that cannot find its target waits before handing over and counts as
  missed. Sessions keep cookies and localStorage, not sessionStorage. The
  replay cache stores typed inputs in plain text. Agent steps use a
  subscription login made once by the human; telemetry is turned off with
  `E2E_TELEMETRY_DISABLED=1`.
- `roles/qa.md` reads the adapter when `qa_runner` is set and runs
  `qa_session` in its preflight; config template, SKILL.md and both READMEs
  name the two keys. Selftest checks the adapter's files, pinned version
  and updater (120 checks).
