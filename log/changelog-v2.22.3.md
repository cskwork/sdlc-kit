# v2.22.3: To-do sync reads sdlc status in parallel

To-do only.

## Problem

Every to-do command that syncs (`list`, `next`, `take`, the web `/api/items`) ran `sdlc.sh status` once per open sdlc item, one after another. With 37 open items a sync took 39–49 s on a busy machine, and callers with a 60 s limit timed out.

## Changes

- **`readStatuses`:** reads up to 6 items at a time. `sdlc.sh status` is read-only, and the result order is unchanged. Measured on the same 37 items: about 15 s instead of 39–49 s.
