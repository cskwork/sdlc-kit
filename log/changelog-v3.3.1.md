# v3.3.1: A stage commit holds the verified change even when the promotion branch edited the line next to it

## Problem

`ship` records a stage when the deployed commit contains the verified Commit's change. It checked this by reverse-applying the Commit's patch onto the stage commit, which also required the three context lines around every hunk to match.

A real promotion branch had rewritten the line just before one hunk in a documentation file, for a conflict another ticket resolved there. That branch was a development branch that had drifted far from production. The changed lines were all still there, but the context did not match, so the development stage was refused. The same Commit passed on the staging and production branches.

## Changes

- **`lib/ladder.sh`:** the patch-presence check runs `git apply -R --check -C0`, so no context lines need to match. Every changed line must still be there.
  - A revert, or a rewrite of a changed line, still does not apply and is refused.
  - An edit next to a hunk, or elsewhere in the same file, is accepted.
- **`README.md`, `README.ko.md`:** they say what `contains` now requires.

## Verification

- New selftest: a promotion branch that rewrote the line next to the verified hunk is accepted as `contains`.
  - The revert and subfolder refusals still pass.
  - Groups run: contains 5, stages 8, stagerepos 6. They ran on the filtered copy; a local hook blocks the `git reset --hard` sections, and CI runs those.
- Real data: the Commit of one feature, a viewer API change that also edited `CONTEXT.md`:
  - Before: refused on the development branch at `CONTEXT.md:77`. After: accepted with `-C0`.
  - Staging and production: accepted both before and after.
