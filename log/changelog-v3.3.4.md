# v3.3.4: The ticket popup opens at the screen's left; the decision panel stays on the right

## Problem

In v3.3.3, "티켓 열기" opened the ticket popup on the right 45% of the screen and moved the decision panel to the board's left edge to make room. The panel moved, so the decision context jumped: the question, choices and reply box the person was reading went to the other side of the screen the moment they opened the ticket, and came back when they closed it.

## Changes

- **Panel stays put (`todo/page/board.js`, `app.css`):** the left dock is gone. That covers `data-dock`, `--panel-cap`, the one-second close check, the `focus` and `visibilitychange` listeners, the docked width cap, and the mirrored handle direction and keys. The panel and its resize handle work as in v3.3.2: on the right, ← widens and → narrows, and the width is capped at the board less 24rem.
- **Ticket popup at the left (`board.js` `openTicket`):** the popup opens at `left = screen.availLeft`, `top = screen.availTop`, with the full available height.
  - Its width is 45% of `screen.availWidth`. It is narrower when the panel leaves less room: `availWidth − panel width − 16px`, never below 480px. On a full-screen board the popup and the panel therefore do not overlap.
  - The popup still follows the selection to the next card's ticket (`followTicket`).
- **Kept from v3.3.3:** Enter to send, keyboard shortcuts, tooltips and the key list.
- **`README.md`, `README.ko.md`:** "티켓 열기" opens one popup docked to the screen's left edge, beside the decision panel on the right; the left-dock paragraph is removed.

## Verification

- `node --test tests/todo-board.test.mjs tests/todo-page.test.mjs tests/todo-i18n.test.mjs`: 75 pass (board 6, page 60, i18n 9). The four v3.3.3 dock tests are replaced by four that cover:
  - the popup's features: `left` = `availLeft` (also a negative one, for a second screen), `top` = `availTop`, 45% width and full height;
  - the width when a wide panel leaves less room, and the 480px minimum;
  - the panel never moves: no `data-dock`, no class change on the board view, panel or handle, and no `--panel-cap`, when the ticket opens, follows, closes and opens again;
  - the handle keeping the right-side keys while the ticket is open.
- Real browser (headless Chromium 1255, screen 1440×900, a copy of the to-do file and feed, external ticket URLs stubbed by a Playwright route):
  - "티켓 열기" opened the popup at `screenX` 0 (`availLeft`), `screenY` 0, 648×900 (45% width, full height), ending left of the panel.
  - The panel stayed on the right before and after the open, a card step and the popup's close: x 1066, width 374, right edge at the window's 1440, no `data-dock`, no class change, no `--panel-cap`.
  - No console errors.
