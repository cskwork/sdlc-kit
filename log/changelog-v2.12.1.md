# v2.12.1: To-do web page shows the work document, colours status and fits wide screens

Follow-up to v2.12.0. Web page and server only; the inbox file, CLI, TUI and approval rules are unchanged.

## Changes

- **Wide screens show the whole list at a glance.** At 1024 px and wider the page grows to 1280 px and each row puts its title and its status, project, ticket and phase side by side.
- **Every waiting row says what it waits for.** The first waiting row keeps its highlight and "Needs you"; the others show their question or gate with a Review button instead of only a "Waiting" badge.
- **Details shows the work document of every open sdlc item.** `/api/artifact` now returns the item's `intent.md`, or `PLAN.md` once one exists, read-only with `gate: ""` when the item has no approval gate. A question used to show "Could not load what needs approval: item has no approval gate"; it now shows the intent under "Work document" above Reply. Only `approve intent` or `approve plan` adds the decision form, and `/api/approve` still refuses an item without a gate.
- **Status is colour-coded.** Waiting (amber), blocked (red), in progress (blue), open (grey) and done (green) show as pills with their word, a matching left bar on the row and a matching check ring. Every pair meets 4.5:1 contrast in light and dark mode.
- **Details is wide and adjustable.** At 1024 px and wider Details fills the screen: the work document on the left, the decision, reply and history beside it, and the fields in two columns. A− and A+ set its text size from 80% to 160% in 10% steps; the size lasts until reload because the page never uses Web Storage. On phones the controls sit above the title.
- **Text no longer breaks badly.** Korean wraps between words instead of mid-word (`word-break: keep-all`; long tokens still wrap). The Details Close button no longer shrinks into "Clos/e". The `·` before a ticket link is no longer underlined.
- **Hover tools no longer reserve a column.** Between 561 and 1023 px the row tools float over the row's end on hover, so titles use the full width.

## Validation

- macOS local (Node 22.19.0): to-do Node tests 161/161 passed. The new work-document tests (two page, one web) fail on v2.12.0 (red) and pass with this change; the status contrast and text-size checks are new assertions.
- Chrome at 1440, 800 and 390 px, light and dark: no element extends past the page or the open Details dialog, for a question item and a plan-approval item.
- `tests/selftest.sh` was not run locally (a local hook blocks its `git reset --hard` fixtures); CI runs it.
