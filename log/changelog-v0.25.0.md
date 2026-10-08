# v0.25.0 — no unit outside the loop, undone attempts read, contradicted origins blocked

Three gaps let a change skip the kit's checks. A unit in a monorepo with no
`.sdlc/` of its own was read as "no loop here". The History probe said "read
reverts" without saying how, so an earlier attempt that was rolled back for a
side effect went unread. And the Intent match lens counted Covered, Missing
and Beyond only, so a build that handled an origin detail with the opposite
rule (origin: expired coupons greyed out; build: hidden) could pass as
Covered. No new gate or check; no script-read line
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
- **roles/verifier.md Lens 3, templates/evidence.md:** a fourth class,
  **Contradicts** — an origin detail built with a different rule. Blocking
  unless the origin owner's decision is recorded; an agent-proposed rule is
  not an override. The evidence line gains `Contradicts: <list or none>`.
- **templates/spec.md:** new **Origin overrides** section (R → origin text →
  owner's decision: who, date, words; `none` by default).
- **roles/adversary.md Traceability:** the same contradiction is blocking at
  the spec gate, before anything is built.
- **README.md, README.ko.md:** the monorepo line says the same.

Nothing to migrate.
