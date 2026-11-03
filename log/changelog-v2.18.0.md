# v2.18.0: To-do decisions offer one-click answers and group by ticket

To-do only; the sdlc loop is unchanged. The to-do file gains two optional fields; files without them parse and serialize byte for byte as before.

## Problem

A factory puts decisions on the to-do as items like `[결정 D35] A20-1462 · <question>` with a `waiting:` line listing numbered options. The human had to type the number or the label as a reply, although 81% of recent decisions picked the recommended option. Several decisions for one ticket also sat apart in the list.

## Changes

- **`  - choices: a | b | c`** and **`  - pick: N`** are optional item fields (after `repos`), parsed into `item.choices` (`[]` when absent) and `item.pick` (`null` when absent). A hand edit with an empty label or an out-of-range pick still loads and drops it.
- **CLI:** `choices <id> "a | b | c" [--pick N]` records up to 6 trimmed, non-empty, one-line labels and the 1-based recommended one, with agent event `choices a | b | c`; the same list and pick again adds no event; `choices <id>` clears both (`choices cleared`); bad input exits 2. `done` keeps them as history. `list`/`next`/`take --json` include `choices` and `pick`.
- **App:** an open card shows one button per label above the reply line; a click posts the label as a reply through `/api/item` (`op: reply`), the picked one first as a filled button marked Recommended (권장). Open items that need you and share a ticket link sit under one heading with that link's label.
- **Page:** Details shows the same buttons above the reply box, through the same reply request as the box; the open list groups items that need you by ticket link under a heading.
- **TUI:** the row and detail list the answers; number keys 1-6 send one as a reply.
