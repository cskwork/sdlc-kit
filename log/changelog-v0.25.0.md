# v0.25.0 — no unit outside the loop, and history that names its undone attempts

Two gaps let a change skip the kit's checks. A unit in a monorepo with no
`.sdlc/` of its own was read as "no loop here", and the History probe said
"read reverts" without saying how, so an earlier attempt that was rolled back
for a side effect went unread. No new gate or check; no script-read line
changed.

## Changes

- **AGENTS.md "Monorepos", SKILL.md "When this skill runs":** a store covers
  its whole tree. A change in a unit without its own `.sdlc/` runs the loop in
  the nearest store above it, gates run from that store's directory.
- **skills/1-intent "History":** run `git log --no-merges -i -E
  --grep='revert|rollback|back out' -- <paths>` on the shipping branch, plus
  the project's own words for an undo; read each hit's ticket for the side
  effect that forced it.
- **templates/intent.md:** Researcher findings opens with a `History:` line —
  the search run and its hits, or `none found` with the command.
- **README.md, README.ko.md:** the monorepo line says the same.

Nothing to migrate.
