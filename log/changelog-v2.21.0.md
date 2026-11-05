# v2.21.0: Suggested answer and a decision-only ask box

To-do only; the sdlc loop is unchanged.

## Problem

In one factory's to-do, a ticket waiting on the human showed a generic "it stopped because it is risky" line plus the agent's work log ("check_adf PASS", "Kira …") in the "agent is asking" box, and an empty reply field. The real question sat in the folded document. The human answered "approve", "approve", "yes" over one afternoon and none of them settled anything.

## Changes

- **`suggest <id> ["answer"]`** stores the one-line reply the agent recommends (`  - suggest:` field). A human reply, `answer`, `done` or no text clears it; `list --json` and `take --json` carry `suggest`.
- **App, web, TUI** start the reply field with the suggestion, so sending it as-is is one press (TUI: `r`, then Enter). An edit is never overwritten; a new suggestion replaces only an unedited draft.
- **App ask box** holds only what the human decides: the brief's Your call and AI pick. The waiting line joins only when the brief asks nothing (or the item is blocked). What changes moves under the box as one muted line.
- **Tests:** core, page and TUI tests cover the field, its clearing, and the prefill.
