# v0.24.0 — a QA guide the human can follow

The final report said what was delivered but not how a person could see it
for themselves. Ship now writes `qa-guide.md` and quotes it in the report.
No new gate or check; no script-read line changed.

## Changes

- **templates/qa-guide.md (new):** environment, account and role (where the
  password is kept, never the password), menu path, data needed, numbered
  steps each with what the tester should see, the before-fix symptom for a
  bug fix, clean-up, and what the agent did not check.
- **skills/5-ship:** after delivery, write `.sdlc/work/<slug>/qa-guide.md`
  from what the E2E lens actually drove (a step it did not run is marked
  `[not run by agent]`); after close, report the bottom line plus the guide
  as one quoted block and its archive path. Commands carry a placeholder
  (`$TOKEN`) and its source, never a token, cookie, or key.
- **AGENTS.md rule 8:** a QA guide quoted in a final report keeps its form.
- **AGENTS.md:** ship's artifact list and rule 7's durable record include
  `qa-guide.md`. **templates/summary.md:** How to check points at it.
- **tools/kb.sh:** `show` and `index` list `qa-guide.md` with the other
  records.

Nothing to migrate: features closed before v0.24.0 simply have no guide.
