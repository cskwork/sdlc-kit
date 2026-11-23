# v3.3.0: Ship in stages, keep a per-feature event log, require an Undo for risky plans, and prefill the board's answer

## Problem

- **One ship target per feature.** A project that ships to dev, then staging, then production over days had a single ship target. A feature deployed to staging and being watched could only sit at `deliver READY`. In one store, 17 features sat there unclosed. Because memory dreaming waits for closes, it stopped too.
- **No history in `.state`.** Each command rewrote `.state` with the latest values, so nobody could tell how long a phase took, how often scores failed, or why features were BLOCKED.
- **Risky plans with no way back.** A plan could raise a risk flag (migration, data deletion, public API, security, infra) without saying how to undo the change.
- **Hand-typed answers on the board.** The board showed the agent's suggested answer only as a marked button. Items without buttons needed it typed by hand. In one store, 244 of 352 answers were one word, and "done" was typed 55 times exactly as suggested.

## Changes

- **`stages:` (`templates/config.md`, `lib/ladder.sh`, `sdlc.sh`):** an optional ordered list, such as `stages: dev, stg, prd`. Names are letters, digits, `.`, `_` and `-`, each listed once. It is read raw, so an empty item, a stray character or a trailing comment is refused.
  - `sdlc.sh ship <slug> <stage> <sha> [repo] --checked "<command>" --output "<line>"` records a stage.
    - It needs what `close shipped` needs: a current deliver route, valid evidence, authority, and a `<sha>` whose tree equals the verified `Commit:` and is on a remote beyond `local`. It checks every `Commit:` line of that repository.
    - It refuses an unknown stage, a repeat, an out-of-order stage, and a folder no `Commit:` line names.
    - The record lives in `.state`. It is bound to the scored evidence and the build entry, so a new score or a re-approved plan starts the ladder again. It is keyed by git repository, so `Commit:` lines for folders of one repository share it.
  - `status` and `next` show `deliver READY · at stg (2/3)` and name the next stage. `status --json` adds `stage` and `stages`.
  - `close <slug> shipped` needs the last stage for every repository, or `--at <stage> "<reason>"` naming a recorded one. The reason goes into the closed note.
  - Without `stages:`, every flow is unchanged, and `ship` and `--at` are refused.
- **`events.log` and `stats`:** every state-changing command appends `ts⇥command⇥phase-after⇥result⇥detail` to `work/<slug>/events.log`. The file moves into `archive/` with the folder. A failed write warns and the command continues.
  - `status --json` adds `ageDays` and `lastEventAt`. `ageDays` counts from the earlier of folder creation and the first event.
  - `sdlc.sh stats [--json] [--since YYYY-MM-DD]` reports:
    - counts by phase and state;
    - median and p90 time per phase;
    - score rounds and returns;
    - the top BLOCKED reasons;
    - closes per week.

    Slugs without a log count as legacy, and slugs whose log does not start at `new` count as partial. Neither adds to the timings.
- **`Undo:` (`templates/PLAN.md`, `sdlc.sh`, `roles/reviewer.md`, `phases/2-plan.md`):** PLAN.md has `- Undo: <flag <name> | revert <what> | config <key> | none — why>` next to the risk flags.
  - A plan with any risk flag set to yes cannot be approved while `Undo:` is missing, empty, a placeholder, or `none` without a reason. Until it is fixed, `next` keeps it the agent's turn with "edit PLAN.md: …; then approve plan --human …".
  - Plans approved before this release keep working, and re-approving them still says "already approved".
  - The reviewer blocks an Undo that would not work. Evidence names the flag-removal follow-up.
- **Board (`todo/page/board.js`, `todo/page/app.js`):** the answer box starts with the agent's suggestion, using the list page's rule:
  - an edited answer is never replaced;
  - a newer suggestion replaces an unedited one;
  - a done item stays empty;
  - each card keeps its own draft.
- **Run cost on the board:** when the feed's run rows carry `costUsd` or `tokens`, the bar's tooltip shows them, for example `$0.95 · 96만 토큰`. The day summary shows the known cost total and "some cost unknown". Feeds without these fields look exactly as before.
- **Docs:** `README.md`, `README.ko.md`, `SKILL.md`, `docs/architecture.md` and `phases/4-evidence.md` cover all of the above.

## Verification

- CI selftest on ubuntu, macos and windows gates the merge (PR #98).
- Local selftest:
  - The filtered copy passes every group, with these new or extended groups: events 5, stats 4, stages 8, undo 3, other 8.
  - A local hook blocks the four sections that run `git reset --hard`. CI runs those.
  - `interrupt` failed under load on both trees and passes alone.
  - Budgets: plan load 2500/2500 words, total under 6000, `sdlc.sh` 600 lines.
- Default-flow probe (new → approve → review → score → close local, no `stages:`): compared with v3.2.0, the output differs only in the four new `status --json` fields and the new `events.log`.
- `tests/todo-board.test.mjs` and `tests/todo-page.test.mjs`: 57 of 57 pass, 5 of them new. The web and core node tests timed out under machine load on both v3.2.0 and this tree; the failing tests changed from run to run.
- Browser check (Chromium, a copy of a real list and feed):
  - an alert card's answer box showed the suggested answer;
  - run tooltips and the day summary showed cost;
  - a day without cost fields rendered as before.
- Two independent reviews ran. Every finding from them is fixed.
