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
- **Phase stepper:** each card shows every sdlc phase (intent › plan › build › evidence › deliver › done) under its status, past phases ticked, the current one filled, then "Now X · next Y". A brief can name its ticket's phase with an At a glance `Phase:` line.
- **Ticket beside Send:** when the human can answer, the item's ticket links sit next to the Send button instead of below the form.
- **Shared sync for reads:** `/api/items` and `/api/artifact` share one in-flight sync. Each artifact request used to run its own full sync, so opening many cards at once queued syncs past the app's 30-second timeout.
- **Order: situation, question, why.** The question box holds the call, what the agent will do (What changes), an optional At a glance `AI pick:` line and the reply line; Why comes after it.
- **Enter sends a reply** from the reply field, like the Send button.
- **Always three blocks:** with a document, Background and Why always show; a missing part reads "Not in the document yet" instead of disappearing.
- **No "Where is use_default?" prompt:** the app names its notification sender (`dev.sdlc-kit.todo` inside the bundle) before notifying; mac-notification-sys otherwise asked AppleScript for an application called `use_default` and macOS opened a chooser.
- **Liveness:** `/api/live` answers without syncing. The app and `serve` used `/api/items` with a 2-second limit, so a list with many sdlc items (each synced through `sdlc.sh status`) looked dead: the app kept starting new servers and never connected.
- **Docs:** the CLI usage and README describe `brief`; `todo/AGENT.md` stays within its 600-word budget.

## Validation

- `node --test tests/todo*.test.mjs`; `cargo build --release --manifest-path todo/app/Cargo.toml`.
