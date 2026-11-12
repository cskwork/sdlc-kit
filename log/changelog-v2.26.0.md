# v2.26.0: The to-do shows which items an agent is working on right now

## Problem

Every open item whose next step was an agent's read "Agent working" (`status.agent`), whether or not any agent held it. On 2026-11-12, 26 items read "Agent working" while no agent ran, so the human could not tell real work from a queue.

## Changes

- **`todo.mjs working <id> ["what"]`** marks an item as worked on now, or refreshes the mark: `beat` becomes now, `since` stays while the mark is live (else now), and `what` is a one-line label such as `build` or `dev QA` (80 characters at most; omitted keeps the previous one). `working <id> --off` clears it. An unknown id exits 1, a done item exits 1 unless `--off`. It runs no sdlc sync and never writes `todo.md`, so a heartbeat can call it every 60 s.
- **`todo-working.json`** beside `todo.md` (follows `SDLC_TODO`) holds `{ id: { what, since, beat } }` in ISO times, written atomically with mode 0600; expired marks are pruned on each write. A mark is live while its `beat` is younger than 180 s (`core.WORKING_TTL_MS`; `SDLC_TODO_WORKING_TTL` in seconds overrides it for tests). An expired mark is ignored everywhere, so the mark of a worker that died disappears by itself. Two writers at the same moment can lose one update; the next beat restores it.
- **New status `working`** (`statusOf` → `{ actor: 'agent', kind: 'working' }`): "Working now" / "지금 작업 중", shown with elapsed minutes and the label, e.g. "지금 작업 중 · 12분째 · build". Blocked, waiting for you and waiting on someone else still win over a live mark: a turn that is yours or someone else's is never hidden by a heartbeat. The header counts are unchanged (it is still an agent's turn).
- **"Agent working" is now "Agent's turn"** / "에이전트 차례": an open item an agent should take next but nobody has marked.
- **Item JSON** (`list --json`, `next`/`take --json`, `/api/items`, `/events`) carries `working: { what, since, beat }` or `null` (null when the item is done or the mark expired).
- **Every surface tells it apart:** the app gives it its own green tint, a halo around the row dot and a pulsing dot in its pill, repainting once a second only while an item is working; the web page shows a green pill with a CSS-pulsing dot and a green row bar; the TUI marks it `◉` in bold green with a "Working now · 12 min · build" line under the row (legend updated).
- **The app says it above the tabs:** a line under the title reads "N건 지금 작업 중 — <first item> — 지금 작업 중 · 6분째 · build" (click opens 진행 중), or a muted "지금 작업 중인 에이전트 없음". Working rows lead their tab and carry the label pill on the row itself, not only on hover. The empty Needs-you text no longer claims agents keep working.
- **Expiry without a write:** the server and the TUI watch `todo-working.json` and also arm a timer for the oldest live mark's expiry (`core.watchWorking`), so a mark nobody refreshes leaves every view within the TTL (plus 50 ms), with no file change.
- **Agents:** `todo/AGENT.md` asks to run `working <id> "<step>"` at least every 60 s while working an item and `working <id> --off` when they stop; README and CLI help describe the command.

## After updating

Rebuild the app: run `todo/app/install-macos.sh` again (macOS), or `cargo build --release` in `todo/app`. Restart a running to-do server (`serve`) so it watches the new file.
