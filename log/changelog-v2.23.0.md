# v2.23.0: Pinned items stay at the top of every app tab

To-do only.

## Problem

A setting kept as a to-do item (for example an agent switch with `켜기 | 끄기` choices) never appeared on the app's default **Needs you** tab. Making it wait would raise the Needs-you count for good, and as an ordinary item it sat folded somewhere in **In progress**.

## Changes

- **`todo.mjs pin <id> [on|off]`:** stores `- pin: yes`; one event per change; replies keep it.
- **App:** pinned open items show above the list on every tab except **Done**, as one line with their title and choices; the current pick is marked `✓`. They are not counted as needing you.
- **Web page:** pinned items sort first.
- **`list --json`:** includes `pin`.
