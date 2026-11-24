# v3.3.3: The decision panel docks left beside the ticket window; Enter sends, every action has a key and a tooltip

## Problem

"Open ticket" opens one popup docked to the right 45% of the screen. The board usually runs full screen, and its decision panel sits on the right, so the ticket window covered exactly the panel the person decides in.

The panel also lacked a keyboard path for most actions. A reply needed Cmd/Ctrl+Enter or a click, and buttons named neither their key nor, for icon buttons, their action, except through a slow native title.

## Changes

- **Left dock (`todo/page/board.js`, `app.css`):**
  - While the ticket window is open, `#board-view` gets `data-dock="start"`. The panel moves to the board's left edge, and the board shifts right of it.
  - Only the boxes swap places (grid placement and `order`), so focus, scroll position and the reply draft stay. `reading-flow: grid-order` keeps Tab in the order on screen where the browser supports it.
  - A one-second check, cleared on close, plus `focus` and `visibilitychange` on the board window, notices the closed ticket window and returns the panel to the right. Live updates never move it.
  - Docked left, the resize handle sits on the panel's right edge: → widens and ← narrows; Home, End and Enter work as before; the stored width is shared.
  - Docked left, the width is capped at `screen.availWidth × 0.55 − 16px` (`--panel-cap`), never below the 20rem minimum. The separator's values follow the cap.
  - No animation: the panel jumps in place, so reduced motion needs nothing.
- **Enter sends (`board.js`, `app.js`):** in the panel's reply box and the list's reply box, Enter sends and Shift+Enter starts a new line. An Enter with `isComposing` or `keyCode` 229 (Hangul being composed; Safari's order) never sends. The prefilled suggestion goes with one Enter.
- **Keys (`board.js`):** outside a text box, `1`–`9` press the matching choice, `R` goes to the reply box, `T` opens the ticket, `F` runs Fix by agent, `M` toggles More, and `?` opens a key list (`<dialog>`, Esc closes it).
  - No key approves: `A` moves focus to Approve and shows its tooltip, and Enter or Space there decides.
  - Esc closes, in this order: a shown tooltip, the key list, the panel.
  - Controls carry `aria-keyshortcuts`.
- **Tooltips (`board.js`, `app.css`, `index.html`):** one shared tooltip (`popover="manual"`, `role="tooltip"`) names the action and key, e.g. "티켓 열기 (T)", "답 보내기 (Enter)", "계획 승인 (A, Enter)", "1 · <choice>".
  - It shows on keyboard focus at once and after a 300ms hover; the pointer may rest on it.
  - It describes its control (`aria-describedby`) while shown, and hides on typing, scrolling or Esc.
  - It is placed below its control, or above it, and never over the text box being typed in.
  - A tooltip that would only repeat a button's visible words is not shown.
  - The resize handle's help moved from `title` into it.
- **Strings (`todo/locales/*.mjs`):** the key list, tooltip formats and the [Keys]/[단축키] strip button; the reply help says Enter sends.
- **`README.md`, `README.ko.md`:** the left dock, Enter and a key table.

## Verification

- `node --test tests/todo-board.test.mjs tests/todo-page.test.mjs`: 66 pass (57 before, 9 new). `tests/todo-i18n.test.mjs`: 9 pass. The new tests cover:
  - the dock opening, closing by the check and by window focus, and staying put through live snapshots;
  - key direction docked left, and the width cap including the minimum;
  - Enter, Shift+Enter and composing Enter on both reply boxes;
  - number keys, and single keys inside a text box;
  - `A` focusing without approving, and `?`;
  - tooltip text with keys in Korean.
- Real browser (Chromium 1440×900, a copy of the to-do file and feed, external ticket URLs stubbed):
  - "티켓 열기" docked the panel at x=0 and the board at x=386, with the cap at 776px. Closing the popup brought the panel back within the one-second check.
  - Scroll position (59), the draft and the caret were unchanged through docking and closing.
  - On the handle docked left, → went 374→390px and ← went back.
  - The tooltip showed on hover and on Tab focus; Esc hid it and kept the panel open. `?` opened the 12-row key list.
  - Enter sent a reply (`/api/item` 200) to the copy.
  - `A` focused "계획 승인" with its tooltip and sent no `/api/approve`.
  - No console errors.
