# v2.22.2: Opening a work document no longer syncs every item

To-do only.

## Problem

Opening an sdlc item's document (`/api/artifact`) first synced every open sdlc item, running `sdlc.sh status` once per item. With 35 open items that took about 10 s, and the app gave up with `timed out reading response` before the document arrived.

## Changes

- **`core.sync(file, { only })`:** syncs one item id; other items keep their last synced state.
- **Web `/api/artifact`:** syncs only the requested item before choosing its gate and document.
