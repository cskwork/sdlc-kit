# v2.14.2: A multi-line answer on the to-do web page no longer fails with "invalid reply"

Follow-up to v2.14.1. To-do web page only; the server checks, the inbox file format and the sdlc approval rules are unchanged.

## Problem

On 2026-10-26 an answer typed on several lines in the web page's answer box failed with `400 invalid reply`. The box is a multi-line textarea, but the page sent the line breaks and the server rejects them, because `~/.sdlc/todo.md` keeps one event per line. The approval note box had the same gap (`invalid words`).

## Changes

- **The page joins the lines of an answer or approval note with ` / ` before sending.** Blank lines and the spaces around each break are dropped. The note's character count counts the joined text.

## Validation

- macOS local (Node 22.19.0): the new page test fails on v2.14.1 (red) and passes with this change.
