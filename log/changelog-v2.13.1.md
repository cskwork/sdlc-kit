# v2.13.1: A reply nobody has read no longer shows as "Agent working"

Fix to v2.13.0. To-do CLI, TUI and web page; the inbox file format and the sdlc approval rules are unchanged.

## Problem

An sdlc item waiting for the human (`NEEDS-HUMAN`) turned "Agent working" as soon as the human replied, and stayed that way until an agent ran `next` with that item first. A worker that owns specific items rather than the top-down queue (2026-10-26: a Jira ticket factory) never calls `next` for them, so a reply of "continue" left the item showing "Agent working" for hours while no agent had read it and sdlc.sh still reported `NEEDS-HUMAN`.

## Changes

- **New status "Answered — no agent has picked it up yet"** (`status.handoff`, Korean "답변 전달됨 — 에이전트 수신 전") for an sdlc wait with an unread reply. It still counts as the agent's turn, so the queue and the header counts are unchanged; it shows `◌` in the TUI and the grey tone on the page instead of the blue "Agent working".
- **`take <id> [--json]`** hands one named item to its worker the same way `next` hands out the first: same exit codes (`0`, `10`, `20`) and `replies`, and it marks those replies read so the item waits for the human again until sdlc.sh moves on. A missing id exits `1`.
- **`list --json` returns each item's unread `replies`.** It always returned an empty array before.
- `todo/AGENT.md` and both READMEs describe `take` and the new status.

## Validation

- macOS local (Node 22.19.0): to-do Node tests 181/181 passed. The new handoff test fails on v2.13.0 (red: the replied item reads `agent`/`agent`) and passes with this change.
