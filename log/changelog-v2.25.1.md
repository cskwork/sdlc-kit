# v2.25.1: The two-page spread reads ragged-right again

To-do app (`todo/app`) only. The web page, the TUI, the server and `todo.md` are unchanged.

## Problem

On a wide window (960 points or more) a decision opens as a two-page spread, built from egui columns. egui lays each column out justified, and a wrapped label in a justified layout is fully justified: word gaps stretched to the page edge, and a line followed by a long unbreakable token was spread letter by letter (e.g. "원 문 유 지 · 별 도 U T F - 8 서 명 경 로"). The single page on a narrow window was not affected.

## Changes

- **Pages are not justified.** Each page of the spread lays its content out top-down and left-aligned, as the single page does, so text is ragged-right. The question box, the agent's pick box and the answer fields still fill the page; the gap and the fold between the pages and the heading row are unchanged.
- **Buttons as on the single page.** The justified columns also stretched every button that sat directly on a page to the page width (choices stacked over what they do, approve, fix). They now take their label's width, as on the single page.
- The list tabs are unchanged: their one-line rows are truncated, not wrapped, and the one-column and two-column lists are laid out the same way.

## After updating

Rebuild the app: run `todo/app/install-macos.sh` again (macOS), or `cargo build --release` in `todo/app`.
