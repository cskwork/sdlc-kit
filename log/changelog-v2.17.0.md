# v2.17.0: To-do items show the repositories their change touches

To-do only; the sdlc loop is unchanged. The to-do file gains one optional field; files without it parse and serialize byte for byte as before.

## Problem

An item said which project and ticket it belonged to, but not which repositories the work changed. In a multi-repository workspace (for example `aidt-lms-api` and `aidt-viewer-api` in one ticket) the human had to open the plan or the branch to see where the change landed.

## Changes

- **`  - repos: a, b`** is an optional item field (after `brief`), parsed into `item.repos` (`[]` when absent). Names are letters, digits, `.`, `_`, `-` and `/`; a hand edit with a bad name still loads and drops that name.
- **CLI:** `repos <id> name,name` (commas or spaces) records them with agent event `repos a, b`; the same list again adds no event; `repos <id>` clears them (`repos cleared`); a bad name exits 2. `list`/`next`/`take --json` include `repos`.
- **App:** every card, open or folded, shows `Repos: a, b` under its project line.
- **Page:** the row's info line shows the repositories as a chip; the detail lists them under Repositories.
- **TUI:** the row meta and the detail show them.
- **AGENT.md:** an agent records the repositories once it knows them and updates them when the set changes.
