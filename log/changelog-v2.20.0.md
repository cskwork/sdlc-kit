# v2.20.0: Waiting on someone else

To-do only; the sdlc loop is unchanged.

## Problem

A worker that waited on QA or a planner had only `wait`, which puts the item in Needs you. In one factory's history 49 of 218 human replies went to such items: the human had nothing to decide, answered "ok" to clear the list, and the item came back unchanged.

## Changes

- **`others <id> ["who"]`** records that someone else answers first (`  - others:` field). The item shows "Waiting on someone else" with what it waits for, leaves Needs you (the app lists it under In progress), and `next` passes it by; `take` exits 15. A human reply, `wait` or `resume` clears it; no text clears it too.
- **App, web, TUI** show the new status; `list --json` and `take --json` carry `others`, and `asked`: what the item last waited for, kept after a reply clears the wait, so an agent can tell that an answer changed nothing.
- **Windows lock:** opening the lock file while another process is still deleting it fails with EPERM on Windows; that now counts as a busy lock and is retried, so parallel writers no longer fail (seen in CI S14).
- **Tests:** a core test covers the field round trip, the status, `next`/`take`, and every way it clears.
