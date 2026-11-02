# v2.15.0: A tray app for the to-do, a choice of surfaces, and "Fix by agent" for blocks

To-do add-on only; the sdlc loop, the `todo.md` format and the approval rules are unchanged.

## Problem

On 2026-11-02 the to-do was only a TUI plus a web page in a browser tab whose link changed on every restart, so a reply waiting for the human was easy to miss. A blocked item ("blocked — fix needed") had no way to hand the block to an agent: a reply left it stopped.

## Changes

- **`todo.mjs` opens the app by default; `--ui tui,web,app` picks any surfaces.** Without a built app it says so and opens the TUI with its web link, as before. `--ui app` without a build fails with the build command. `--no-web` still means the TUI alone.
- **One shared server.** The web server writes its port and token to `todo-web.json` beside the to-do file (mode 0600) and removes it on close; launches, the app and the new `todo.mjs serve` reuse a server that answers. Agents still never read the token (`todo/AGENT.md`).
- **`todo/app`: a Rust tray app (macOS, Windows).** Menu-bar or tray count of items that need you, a notification when one appears, replies, intent/plan approval of the shown document, and the fix button, all through the existing web API (`Origin` and token checks unchanged). It starts `todo.mjs serve` when no server answers and stops it on Quit. Optional: Node-only installs are unaffected.
- **The app shows what a decision needs, not history.** An item that needs you opens with its question or problem (clipped), then at most three short lines to decide, one line of summary and one of why, taken from `intent.md`/`PLAN.md`; the full document folds under "More detail". Buttons open the item's ticket link and any other ticket URLs in its question, never the local web page.
- **intent.md At a glance is four fixed, plain lines:** Your call (the decision, as a question), What changes, Background and Why, written for a newcomer without file names or codes. The app shows them as "your call, in one line, background, why it matters"; older documents fall back to their sections. A gate's agent command (`approve intent --human`) shows as a plain question.
- **Fix by agent.** App/page button and TUI `f` on a blocked sdlc item (not a project-path error) record `fix requested`. The item shows "answered — not picked up yet"; the next `next`/`take` returns it once with exit `0` and `"fix": true`, then it stops the queue again. A plain reply still never unblocks. `todo-agent.json` may name a `fix` command (argv array with `{id}`, `{kit}`, `{project}`) that starts an agent at once; without it the next scheduled agent run picks it up.
- **Items from the API carry `turn`** (`statusOf`), so clients do not reimplement the status rules.

## Validation

- macOS local (Node 22.19.0): `node --test tests/todo*.test.mjs` passes, including new tests for `--ui`, the unbuilt-app fallback, app arguments, `serve` reuse and cleanup, the session file mode and staleness, and fix requests in core, CLI and web.
- macOS local (Rust 1.88.0): `cargo build --release` (4.0 MB binary); the app ran against a copy of a real `todo.md`, rendered Korean, followed live changes, and a fix request on the copy turned the blocked item into a hand-off and back to blocked after `take`.
- Windows: `cargo check --target x86_64-pc-windows-msvc` passes; the app was not run on Windows.
