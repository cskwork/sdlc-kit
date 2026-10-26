# v2.14.1: Waits outside sdlc show as yours, and any unread reply reads as not picked up

Follow-up to v2.13.1 (released after v2.14.0). To-do CLI, TUI and web page; the inbox file format and the sdlc approval rules are unchanged.

## Problem

On 2026-10-26 four ticket items read "Agent working" while the ticket factory working them waited on a human (risk review, a reporter's answer). Their sdlc state was `READY`, and the factory kept its wait in its own queue, so the to-do had nothing to show. v2.13.1 also flagged unread replies only on sdlc waits: a reply to a `wait` still read "Agent working" before any agent had seen it.

## Changes

- **Any unread human reply shows "Answered — no agent has picked it up yet".** `next` and `take` mark the replies they hand out read (`agent: read replies`), or re-arm the sdlc wait as before; `list --json` reports `unread`.
- **`resume <id> ["note"]`** drops the agent's own wait when the answer came another way (for example a Jira comment). Without a wait it writes nothing.
- A worker that waits outside sdlc records it with `wait`; the item then shows as your turn even when sdlc says `READY`. This already worked; AGENT.md and both READMEs now say so.

## Validation

- macOS local (Node 22.19.0): to-do Node tests 182/182 passed. The new outside-wait test fails on v2.14.0 (red) and passes with this change.
