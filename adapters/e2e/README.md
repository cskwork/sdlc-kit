# Adapter: e2e (optional QA runner)

Use when config.md says `qa_runner: e2e`. QA then writes each browser or
mobile scenario as an [e2e](https://www.npmjs.com/package/e2e) test, so a
later round re-runs it with one command instead of re-driving it by hand.
Without that key, nothing here applies.

The kit carries what an agent needs to write and run these tests offline:
`vendor/e2e-skill/` is e2e's own agent guide (Apache-2.0, `LICENSE` and
`NOTICE` inside), pinned in `VERSION`. `update.sh [version]` refreshes it from
npm. The project still installs the runner itself.

## Set up once per project

1. Node `^22.22.3 || >=24.8.0` (see `VERSION`). Install the pinned packages
   as dev dependencies: `e2e`, `@e2e-dev/web` (or `@e2e-dev/mobile`).
2. Turn telemetry off for every run: `E2E_TELEMETRY_DISABLED=1`.
3. Copy `templates/e2e.config.ts` and fill the app URL. Agent steps need a
   model: prefer a subscription login the human makes once
   (`npx e2e login openai`, or another plan listed in
   `vendor/e2e-skill/references/setup.md`). Deterministic tests need none.
4. Sign-in the runner cannot drive (a popup, SSO, a device prompt) goes in
   `qa_session:` — a command that writes the signed-in storage to a file the
   setup test injects (`templates/session.setup.e2e.ts`). e2e does not follow
   windows the app opens.

Read `vendor/e2e-skill/SKILL.md` and the one reference it points to before
writing tests.

## Popups

e2e does not follow windows the app opens. `templates/popup-bridge.ts` is an
init script that turns `window.open` into a full-viewport iframe in the same
tab and makes `window.opener`, `close()` and `focus()` behave inside it, so a
same-origin popup that talks through opener and postMessage works unchanged;
assert inside it with `browser.frameLocator`. Its header lists what it does
not cover (cross-origin popups, `target="_blank"` links, `noopener`) and how
it differs from a real popup. Tried on two document-viewer popups: the
deterministic run passed twice, and an agent step inside the popup replayed
with no model call on its second run.

## Each scenario, two layers

`templates/scenario.e2e.ts` shows both, tagged with the scenario ID:

- **det** — exact steps and locator, URL and request assertions; no model.
  This is the evidence: its result is the scenario's PASS or FAIL.
- **agent** (optional) — `agent.act` for steps whose wording or layout
  churns, each followed by a locator assertion so the replay cache records
  it. The first run calls the model; later runs replay with no model call
  until the screen changes. `agent.assert` always calls the model.

Run det in every round; run agent with `--strict-cache` when it must not
spend model calls (a stale recording then fails instead of re-planning).
Save `--reporter json` output in `logs/` with the scenario ID.

## Limits seen in use

- Opening is not always read-only. In the trial, merely opening a one-page
  assignment in its viewer marked it submitted on the server. Before driving
  a flow on shared or seeded data, find out what opening, closing and
  navigating write, and use fixture accounts whose state may change.
- A URL assertion right after `app.open` can pass on the address the app is
  about to redirect away from: expecting the opened URL passed in the trial
  although the app redirected to another page. Wait for an element only the
  settled screen shows, then assert the URL.
- An agent step absorbs a renamed control and still passes; only the det
  locator catches that regression. Keep det as the gate.
- A wrong expectation after a correct replay evicts the correct recording;
  the next run pays the model again. Fix expectations before re-running.
- A replay that cannot find its target waits for it before handing over and
  is counted as missed, not handed off.
- Sessions keep cookies and localStorage, not sessionStorage; inject that in
  the test when the app needs it. Signed-in tokens expire: re-run
  `qa_session` when the setup assertion fails.
- The replay cache stores typed inputs in plain text. Commit it only as
  reviewed test data, or keep it local.
- e2e is pre-1.0: pin versions; update with `update.sh` and re-run the suite.
