# v2.7.1 — an upgraded store keeps its knowledge

Two small fixes found while applying v2.7.0. Template and prompt only; no
script change.

## Changes

- **The template leaves `knowledge:` empty.** It used to say
  `knowledge: .sdlc/knowledge`, and `sdlc.sh` falls back to `.sdlc/memory`
  only when the value is empty. So a v0 store whose config.md was rewritten
  from the template stopped reading its knowledge. In one store this hid 36
  knowledge pages from scouts for a week, and Evidence wrote six new pages
  next to them instead of updating them. The template now leaves the value
  empty and states the default in its comment, and SKILL.md states the
  same default instead of naming only `.sdlc/knowledge`. `init` still creates
  `.sdlc/knowledge` for a new store, and `--knowledge` still writes the path
  given. A store that already names a folder keeps it, so check that it is
  the folder holding your knowledge.
- **A bug fix keeps its failing run.** Build's bug-fix rule now keeps the
  regression test's failing output in `logs/`, where v2.7.0's reviewer
  looks for it. A blocking review finding fixed as a bug fix inherits this.
