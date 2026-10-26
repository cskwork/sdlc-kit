# v2.12.0: Personal to-do inbox

## Changes

- One human-readable `~/.sdlc/todo.md` holds work across projects; `SDLC_TODO` overrides its path.
- A TUI and localhost web page read and update the same file live.
- Agents and programs add items with project paths and ticket links through `todo.mjs add`.
- `todo.mjs next` selects the first Open item: 0 workable, 10 waiting for the human, 20 blocked, 30 empty.
- Agents stop at waiting or blocked items; they never skip to a lower item. Gate approvals and intent blocking questions surface through sync without an explicit `wait`; `wait` is only for questions sdlc.sh does not track.
- Every new or resumed sdlc slug has an item; `todo/AGENT.md` documents the agent loop and host schedules.
- Replies inform artifacts and never approve gates; chat approvals still go through `sdlc.sh approve --human`.
- The web page binds approval to the bytes shown through `sdlc.sh approve --sha`.
- The web server binds 127.0.0.1, checks Host and Origin, and uses a per-run token held in memory by the server and page. The kit never writes it to disk; the browser may keep the opened URL in history. The token dies when the process exits.
- Done items are checked and struck through; the newest 30 stay, and older items move to `todo-archive.md`.
- Item history records local timestamps and authors.
- Concurrent stale-lock reclaimers preserve owner tokens; sync calls sdlc.sh outside the inbox lock.
- Artifact reads and approval use the same canonical project path, including symlinked projects.
- TUI startup syncs with or without web; yellow accents and round checklist glyphs remain readable with `NO_COLOR`.
- Oversized HTTP bodies (>64 KiB) retain status 413.

## Compatibility

- `sdlc.sh approve` gains optional trailing `--sha <hex>`; existing 4-argument calls are unchanged.
- `sdlc.sh` stays at or below 600 lines.
- Prompt word counts do not increase, including each standard phase load.
- Only `todo/` adds an optional Node 18+ dependency; the core loop still needs only bash and Markdown.
- Same-user programs remain outside the web security boundary, as with `--human`.

## Validation

- macOS local (Node 22.22.3): selftest 130 checks passed; to-do Node tests 157/157 passed.
- Independent review (Sol, diff mode): Round 9 PASS after 6 FAIL rounds, each blocker fixed with an assertion-red regression; every test has recorded red evidence.
- QA round 1: every must scenario passed (21/21); S17, S23 and S24 were fixed afterwards and have not been re-run by QA.
- Windows follow-up: Git Bash (MSYS) paths are converted for Node, web artifact reads and approvals use the store `sdlc.sh` reports (junction-safe), and POSIX-only test assumptions were removed; independent review Round 10 PASS.
- CI run 40256109504 (Windows fix commits): ubuntu, macOS and windows passed.
