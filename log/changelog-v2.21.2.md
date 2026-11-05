# v2.21.2: An agent's question outranks a stale sdlc BLOCKED

To-do only.

## Problem

Four factory tickets on legacy v0 slugs had a factory question for the human (`waiting`) and a suggested answer, but sdlc reported the slug BLOCKED ("legacy v0 feature …"). Status checked BLOCKED first, so the app showed the legacy message under Blocked and never showed the question or the reply field.

## Changes

- **Status:** an agent's unanswered `wait` now outranks an sdlc BLOCKED, so the item shows as Needs you with its question and reply field. A call error (`item.error`) still blocks, and once the human replies the block shows again.
- **Tests:** a core test covers the wait, `next` (exit 10), and the reply handing the block back.
