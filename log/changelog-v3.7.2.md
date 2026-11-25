# v3.7.2: The board no longer loses a request on an idle connection

## Problem

The board sometimes said "Cannot reach the to-do list" while the server was running and answering in milliseconds. Node closes an idle keep-alive connection about 6 seconds after its last answer. When the board reused one at that moment, the request was dropped without an answer. On 2026-11-25 the app's WebKit log held two such failures (`NSURLErrorDomain -1005`).

## Changes

- **One connection per request (`todo/web.mjs`).** Every answer carries `Connection: close`, so no idle connection is left to reuse. `/events` keeps its open stream.

## Verification

- New test: the page, `/api/live`, a 404, a 403 and a POST answer with `Connection: close`; `/events` with `keep-alive`. It fails without the change.
- All to-do node tests pass.
