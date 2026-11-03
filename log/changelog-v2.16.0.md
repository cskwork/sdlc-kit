# v2.16.0: To-do items carry a markdown brief

To-do only; the sdlc loop is unchanged. The to-do file gains one optional field; files without it parse and serialize byte for byte as before.

## Problem

Agents outside sdlc (for example an automated factory) put human decisions on the to-do as plain items: a title and a one-line `waiting` question. The app clipped that line to 160 characters and had no document to show, so the human could not see background, intent, options or reasons. sdlc items already showed a decision brief from intent.md or PLAN.md.

## Changes

- **`  - brief: <absolute path>`** is an optional item field (after `waiting`), parsed into `item.brief` ('' when absent).
- **CLI:** `add ... --brief PATH` and `brief <id> <path>` (agent event `brief <path>`; `""` clears it as `brief cleared`); a relative path is refused. `list`/`next`/`take --json` include `brief`.
- **Web `/api/artifact`:** an open item with a brief returns `{ gate: '', file, markdown, sha }` from that file (404 when missing, 409 when not absolute), without needing a project or slug. An sdlc item at an approval gate keeps serving its gated intent/PLAN so approval still works; sdlc items without a brief are unchanged.
- **App and page:** an open item with a brief shows it as a work document, like an sdlc item. Approval stays gate-only.
- **App brief in three blocks:** for any item with a document the app now shows Background, then Why, then one question box that holds the call (Your call or Questions for you), the gist (What changes) and the agent's waiting line. The separate "Your call" and "In one line" lists are gone because they repeated the question box; the full document still folds below.
- **Ticket beside Send:** when the human can answer, the item's ticket links sit next to the Send button instead of below the form.
- **Liveness:** `/api/live` answers without syncing. The app and `serve` used `/api/items` with a 2-second limit, so a list with many sdlc items (each synced through `sdlc.sh status`) looked dead: the app kept starting new servers and never connected.
- **Docs:** the CLI usage and README describe `brief`; `todo/AGENT.md` stays within its 600-word budget.

## Validation

- `node --test tests/todo*.test.mjs`; `cargo build --release --manifest-path todo/app/Cargo.toml`.
