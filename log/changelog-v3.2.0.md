# v3.2.0: Resize the board's decision panel from its left edge

## Problem

The decision panel beside the board had a fixed width: 26% of the window, between 21rem and 29rem. A long question, a brief's background or a work document wrapped into a narrow column, while the board stayed wide. A narrow board could not give the panel more room.

## Changes

- **`todo/page/index.html`, `todo/page/app.css`, `todo/page/board.js`:** the panel's left edge is a resize handle (`role="separator"`). It replaces the panel's border with the same hairline, which turns blue on hover, on focus and while dragging. It appears only while the panel is open.
  - Drag the handle to resize the panel.
  - Click it without moving, or press Enter, to switch between wide (half the board) and the default width.
  - With the handle focused, ← and → change the width by 16 px (Shift: 64 px), and Home and End go to the narrowest and widest. These keys no longer page to another card while the handle has focus; Escape still closes the panel.
  - The width stays between 20rem and the width that leaves the board 24rem. CSS re-applies these bounds when the window or the text size changes.
  - The separator reports the panel's share of the board (`aria-valuenow`, and `aria-valuetext` "40% of the board").
  - The width is kept in `localStorage`. Each server run has its own port, so a restarted server opens the panel at the default width again.
- **`todo/page/app.js`:** `data-i18n-title` sets a translated tooltip; the handle uses it for its instructions.
- **`todo/locales/en.mjs`, `todo/locales/ko.mjs`:** the handle's name, tooltip and value text.

## Verification

- `node --test tests/*.test.mjs`: 232 tests, 226 pass, 6 fail. All 6 are timing failures under machine load: `HTTP request timed out` ×4, `timed out waiting for TUI state`, and `SSE change did not arrive within one second`. This release changes only page files. `tests/todo-page.test.mjs`, `tests/todo-board.test.mjs` and `tests/todo-i18n.test.mjs` pass all 61 tests.
- A browser check in Chrome at 1440×900 used a copy of a real list and feed. All 14 checks pass:
  - the handle is hidden while the panel is closed, and shown when it opens;
  - a 200 px drag widens the panel by exactly 200 px;
  - dragging stops at 20rem and at leaving the board 24rem;
  - the width survives a reload;
  - a click switches to half the board and back to the default;
  - ← widens by 16 px and Shift+→ narrows by 64 px without changing the selected card;
  - the separator exposes its value, and its focus ring shows;
  - axe 4.14 finds zero critical or serious violations;
  - Escape closes the panel and hides the handle;
  - zero console errors.
- The v3.1.0 design gate passes all 20 checks again (1440, dark, 390, 200% page and text zoom, axe, CLS, IME).
