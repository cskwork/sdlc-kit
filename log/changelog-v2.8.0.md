# v2.8.0 — one memory folder

The durable folder scouts read first and Evidence writes to has one name
again: `memory`, the folder v0 stores already have. A default folder that is
not the configured one is now reported instead of silently ignored. Also, a
bug fix keeps its failing run in `logs/`. (v2.7.1 went to `dev` only and is
folded in here.)

## Why

- **Two names hid a store's knowledge.** v2 called the folder `knowledge`
  and defaulted to `.sdlc/knowledge`, reading `.sdlc/memory` only when
  config.md had no value. One v0 store had its config.md rewritten from the
  template, which wrote `knowledge: .sdlc/knowledge`. Its 36 pages in
  `.sdlc/memory` stopped reaching scouts for a week, nothing said so, and
  Evidence wrote six new pages into `.sdlc/knowledge` next to them instead of
  updating them.
- Run on that store's layout, v2.7.0 prints nothing; this release prints
  `sdlc: .sdlc/memory is not the memory folder (.sdlc/knowledge): move its
  pages there or name it in config.md memory:`.

## Changes

- **`memory` everywhere.** SKILL.md, the phases, the scout role, the
  template, the READMEs and the site say `memory`. config.md's key is
  `memory:`, its template value `.sdlc/memory`, and `init --memory <path>`
  replaces `init --knowledge <path>`. An empty or missing value means
  `.sdlc/memory` for every store, new or from v0.
- **Older configs keep working.** A `knowledge:` line is still read when
  there is no `memory:` line, and SKILL.md tells agents so, so a store that
  names `.sdlc/knowledge` keeps using it.
- **A stray default folder is reported.** On every command, `sdlc.sh` prints
  one line for `.sdlc/memory` or `.sdlc/knowledge` when it exists and is not
  the configured folder. The selftest drives this (126 checks): init's
  default, an older `knowledge:` line, and a stray folder of either name.
- **A bug fix keeps its failing run.** Build's bug-fix rule keeps the
  regression test's failing output in `logs/`, where the v2.7.0 reviewer
  looks for it. A blocking review finding fixed as a bug fix inherits this.

## Compatibility

- `init --knowledge` is refused with the usage line; use `--memory`.
- A store with no memory line and a `.sdlc/knowledge` folder now uses
  `.sdlc/memory` and is told about `.sdlc/knowledge` on every command: move
  its pages to `.sdlc/memory`, or add `memory: .sdlc/knowledge`.
- To move a store that names `.sdlc/knowledge` to the one name: move the
  folder's pages to `.sdlc/memory` and change the line to
  `memory: .sdlc/memory`.

## Known limits

- The word budget is unchanged: the plan load stays at 2500 of 2500.
