# v2.21.1: Waiting on someone else outranks a stale sdlc NEEDS-HUMAN

To-do only.

## Problem

Three factory items had `others` (waiting on QA or a planner) while their sdlc slug still read NEEDS-HUMAN from an earlier gate. Status checked NEEDS-HUMAN first, so they sat in Needs you with an empty reply field and nothing for the human to decide.

## Changes

- **Status:** `others` now outranks an sdlc NEEDS-HUMAN. An explicit `wait` still asks the human, and an unread reply still goes to an agent.
- **Tests:** a core test covers the four cases.
