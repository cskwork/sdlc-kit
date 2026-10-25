# v2.12.0: Personal to-do inbox

## Changes

- One human-readable `~/.sdlc/todo.md` holds work across projects; `SDLC_TODO` overrides its path.
- A TUI and localhost web page read and update the same file live.
- Agents and programs add items with project paths and ticket links through `todo.mjs add`.
- `todo.mjs next` selects the first Open item: 0 workable, 10 waiting for the human, 20 blocked, 30 empty.
- Agents stop at waiting or blocked items; they never skip to a lower item.
- Every new or resumed sdlc slug has an item; `todo/AGENT.md` documents the agent loop and host schedules.
- Replies inform artifacts and never approve gates; chat approvals still go through `sdlc.sh approve --human`.
- The web page binds approval to the bytes shown through `sdlc.sh approve --sha`.
- The web server binds 127.0.0.1, checks Host and Origin, and uses a per-run token kept off disk.
- Done items are checked and struck through; the newest 30 stay, and older items move to `todo-archive.md`.
- Item history records local timestamps and authors.

## Compatibility

- `sdlc.sh approve` gains optional trailing `--sha <hex>`; existing 4-argument calls are unchanged.
- `sdlc.sh` stays at or below 600 lines.
- Prompt word counts do not increase, including each standard phase load.
- Only `todo/` adds an optional Node 18+ dependency; the core loop still needs only bash and Markdown.
- Same-user programs remain outside the web security boundary, as with `--human`.

## Validation

- pending: selftest
- pending: independent review
- pending: CI
