# v2.27.1: A blocking question of "none" with a reason counts as none

## Problem

The intent parser treated a line under Questions for you (or Blocking questions) as answered only when it was exactly `none`. An intent that wrote `- none (all six areas clear; nothing open)` made `sdlc.sh status` and `next` report the intent NEEDS-HUMAN with that text as the open question, and `approve intent` refused it, although nothing was open.

## Changes

- **`sdlc.sh`:** a question line reads as none when it is `none`, any case, alone or followed by a space, tab, `.`, `,`, `;`, `:` or `(` and any explanation, e.g. `none (all areas clear)`, `None — settled`, `None.`. Any other value is still an open question; `none` inside a longer word (`nonexistent`) is too.
- **Selftest:** `none (reason)`, `None — reason` and `None.` are not open questions; `Which output format?` is.
