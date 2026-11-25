# v3.6.1: Copy button on code blocks in the board and the list

## Problem

A factory card can ask the person to run SQL from a run sheet. The factory now puts the run sheet and each SQL file in the card's brief as fenced code blocks, so the person can read them in the board. Copying one meant selecting a long, sideways-scrolling block by hand, which easily missed a line or picked up nearby text.

## Changes

- **[복사] / [Copy] button (`todo/page/markdown.js`).** `addCopyButtons(root, { t, announce })` puts one button above every fenced block that `renderMarkdown` produced. Inline code gets none.
  - The button is built with DOM calls and sits outside the `<code>`. The renderer's HTML escaping is unchanged.
  - It copies `code.textContent`: the original text with entities decoded and newlines kept. The renderer's final newline is dropped, so a pasted command waits for Enter.
  - Running it again on the same root adds no second button.
- **Copy path.** It uses `navigator.clipboard.writeText` in a secure context. Without it, or when the write is rejected, it selects the text in a hidden field and runs `document.execCommand('copy')`.
- **Feedback.** The label reads "복사했어요" / "Copied" for 1.5 s, and the result is announced through the page's polite live region. When both copy paths fail, it reads "복사하지 못했어요 — 직접 선택해 주세요" / "Couldn't copy — select it yourself" for 4 s and leaves the block's text selected, so ⌘C still works. A repeated announcement gets a no-break space so VoiceOver reads it again.
- **Where (`todo/page/board.js`, `todo/page/app.js`).** The panel's "At a glance" section, its work document, and the list page's work document.
- **Keyboard and tooltip.** It is a real `<button>`: Tab reaches it, Enter or Space copies, and it has the page's focus ring. The shared tooltip shows "이 코드 블록을 복사" / "Copy this code block". There is no new single-letter key.
- **Look (`todo/page/app.css`).** A code block now has a quiet `--open-bg` tile. The button has its own row at the top right, so it never covers the first line, even when a long line is scrolled sideways.
- **Words (`todo/locales/*.mjs`).** `copy.label`, `copy.done`, `copy.failed`, `copy.tip` in English and Korean.
- **README.** The brief section says fenced code blocks get a Copy button.

## Verification

- New tests:
  - page: 3, covering one button per fenced block and none on inline code, exact text with `<`, `&`, quotes, a literal `&amp;` and several lines, the label and announcement, no second button on a repeat or re-render, the selection fallback, and the failure path with the block selected;
  - i18n: 1, the four words in both locales.
- The contrast test now also checks `--control`, `--ok` and `--bad` on `--open-bg`.
- Page, board and i18n tests: 84 of 84 before, 88 of 88 after.
- A headless Chromium check on a temporary to-do file with a `sql` brief:
  - board panel: one button, Tab reached it with a 2 px focus ring, Enter and Space copied the exact SQL, the label changed and came back, and the live region announced it;
  - list page: the same copy, and the label changed to English when the language was switched.
- Not checked: the tray app's WKWebView. Its clipboard path can only be checked by hand.
