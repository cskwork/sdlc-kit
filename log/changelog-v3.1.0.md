# v3.1.0: The board follows a quiet design baseline: one blue accent, flat cards, readable type, and fixes for Hangul input, layout shift and screen readers

## Problem

The board shipped in v3.0.0 used yellow for the primary button, the selection, the your-turn lane and every hover, so nothing stood out as the one action to take. Cards sat in bordered cells inside a bordered board, lifted with a shadow on hover, and their text was 11.5–12.8 px. Empty lanes still held a full-height band with a dot in every cell. Five font sizes were in `px`, so the browser's font-size setting did not apply. At 390 px the top strip cut "Blocked 0" off, and its controls were 30–32 px tall. The strip used internal words ("Lanes", "Feed").

A browser check against the baseline also found defects that were already there:

- Renaming a list item: Enter that confirms a Hangul (IME) syllable committed the title, which cut its last syllable.
- The first snapshot pushed the loading placeholder and the board down: cumulative layout shift 0.22 on every load.
- A screen reader heard card fields in a different order from the screen (axe `label-content-name-mismatch` on every card and on the Done toggle).
- A ticket heading in the list carried `role="heading"` on an `<li>` (axe `list`).
- The browser's `/favicon.ico` request logged a 404 on every load.

## Changes

- **`todo/page/app.css`:**
  - **Colour:** two hex palettes, light and dark, as before. Blue is the accent: `--accent` for links, focus and the your-turn signal; `--accent-fill` for the one filled primary button. Secondary buttons use a neutral fill instead of a border. Hover is a neutral tint. The agent's turn, the most common state, is neutral grey, not a second blue. Warnings use their own amber `--warn`. The yellow token is gone.
  - **Board:** the board sits on the canvas without an outer frame. Cards are the only boxes, flat, with a firmer hairline on hover and no shadow. The selected card has a blue ring. Titles wrap to two lines before the ellipsis. Empty lanes shrink to their label, and the decorative dot in empty cells is gone.
  - **Type:** every font size is in `rem` on one scale (0.75 / 0.875 / 0.9375 / 1 / 1.25 rem). Counts and ages use tabular figures.
  - **Strip:** the strip wraps instead of clipping. Its controls are 36 px tall, and the language menu is 44 px on narrow screens. The list view hides the board's counts, because the list shows its own.
- **`todo/page/board.js`:**
  - The board appears with the first snapshot instead of pushing a placeholder down (layout shift 0.004).
  - A card's accessible name is its visible text plus its status.
  - Blocked and your-turn counts are coloured only when they are not zero.
  - Empty lanes are marked `data-empty`.
- **`todo/page/app.js`:**
  - The rename editor ignores Enter while an IME composes (`isComposing`, or `keyCode` 229 in Safari).
  - The ticket heading is a `role="heading"` element inside its list item.
- **`todo/page/index.html`, `todo/web.mjs`:** the page links `favicon.png`, served from the tray app's icon.
- **`todo/locales/en.mjs`, `todo/locales/ko.mjs`:**
  - Strip and health texts use plain words: "Working 3/5" for "Lanes 3/5", and "Automation" for "Feed".
  - The stale toggle names its action ("Show 12 cards unchanged for 14+ days").
  - The others tally reads "Others".
- **`tests/todo-page.test.mjs`:** the ticket-heading test reads the heading element's text.

## Verification

- `node --test tests/*.test.mjs`: 232 tests, 223 pass, 9 fail. All 9 are timing failures under machine load: `HTTP request timed out` ×7, `timed out waiting for TUI state` ×1, and the S14 lock test, which also failed for v3.0.0. Run alone, `tests/todo-web.test.mjs` passes 44 of 47 on both the previous release (634b126) and this branch, each time with 3 different HTTP timeouts. `tests/todo-page.test.mjs`, `tests/todo-board.test.mjs` and `tests/todo-i18n.test.mjs` pass all 61 tests.
- A browser gate in Chrome used a copy of a real 40-item list and a real factory feed. It covered 1440×900 in light and dark, the open decision panel, Runs and Health, 390×844, 200% page zoom and 200% text zoom. All 20 checks pass:
  - no page overflow and no cut text;
  - axe 4.14 (WCAG 2.2 A/AA rules) finds zero critical or serious violations in every state;
  - Tab shows the focus ring on cards, Enter opens the panel on its title, and Escape closes it and returns focus to the card;
  - one accent-filled button per view;
  - layout shift 0.004 (was 0.22);
  - zero console errors;
  - every tap target at 390 px is at least 44 px;
  - Enter while composing Hangul keeps the rename editor open.
- `todo/app` (the Rust tray app) and `todo/AGENT.md` are unchanged. The full `tests/selftest.sh` was not run locally, because a local hook blocks its `git reset --hard` step.
