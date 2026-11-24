# v3.3.2: A later edit of the verified lines no longer blocks a stage; only a git revert does

## Problem

`ship` refused a stage whenever any line the verified Commit changed was no longer there. It used this to catch reverts.

On real data, that refused 5 of 14 already-released features at their staging or production stage. In every case the failing file was a test file the feature had created, which a later ticket then edited. The feature's production code was intact. The check could not tell a revert from a later edit, so the factory would log a contract refusal each time.

## Changes

- **`lib/ladder.sh`:** a Commit the stage commit contains is matched in one of three ways.
  - **`contains`:** every changed line is still there, as in v3.3.1.
  - **`contains-edited`:** some lines are gone, but no `git revert` between the Commit and the stage commit names the Commit, or names a merge that brought it in.
  - **Refused, "reverted by <sha>":** such a revert exists.
  - A hand-made revert without git revert's message reads as `contains-edited`, never as `contains`.
  - `status --json` `stages[].match` reports which of the three applied.
- **`README.md`, `README.ko.md`:** they describe the three outcomes.

## Verification

- Selftests:
  - a revert of the Commit is refused naming the reverting commit;
  - a revert of the promoting merge (`git revert -m 1`) is refused;
  - a later removal of one file the Commit added is accepted as `contains-edited`;
  - v3.3.1's neighbour-line and subfolder cases still pass.
  - Groups run: contains, stagerepos, stages. They ran on the filtered copy; CI runs the `git reset --hard` sections.
- Real data: the 5 refused features (12 stage records) now record as `contains-edited` on the same commits; the other 10 kept `exact`/`contains`.
