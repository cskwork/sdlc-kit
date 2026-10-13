# v2.2.1 — opt-in review of uncommitted changes

Two regressions in v2.2.0, both against flows v2.1.0 accepted, and three
small fixes.

## Changes

- **Binding the working tree is opt-in.** v2.2.0 bound every review PASS on
  a dirty repository to its working tree, so a commit reviewed beside a stray
  untracked file (`coverage.txt`, say) that was deleted before `score` was
  refused with "is not the reviewed uncommitted change: commit exactly it",
  asking the user to commit the stray file. `sdlc.sh review <slug> pass
  "<note>"` now binds HEAD alone, as v2.1.0 did: no `git status`, no
  fingerprint, nothing written to the object store. To review before
  committing, record `sdlc.sh review <slug> pass --uncommitted "<note>"`:
  the v2.2.0 binding with all its checks (revert, stash, amend and rebase
  refused; comparison scoped to the Commit path; store and nested
  repositories left out; HEAD alone when git cannot read the tree). The
  "Uncommitted changes are bound" notice prints only then. `--uncommitted`
  goes with `pass` and before the note; with `fail`, or without a note, the
  command is refused with exit 2.
- **Extra Delivered lines.** v2.2.0 stopped `close` at a Delivered line
  whose path is not a folder here (`- Delivered: <sha> deploy-repo` beside
  `- Delivered: <sha>`). Such lines are skipped again, as in v2.1.0. When no
  Delivered line matches a Commit repository, `Delivered missing for repo`
  still names a Delivered path that is not a folder, with the line format.
- **A pruned reviewed tree.** The tree an `--uncommitted` PASS binds is
  unreachable until committed, so `git gc` may prune it (after
  `gc.pruneExpire`, two weeks by default). `score` now says `the reviewed
  tree <id> of <repo> is gone (git gc?): review again` instead of calling
  the Commit wrong. The tree is not pinned with a ref: a ref would be written
  into the user's repository, shared by its linked worktrees, pushed by a
  mirror push and left behind by a feature never closed.
- **A FAIL binds no heads.** `review <slug> fail` no longer scans the
  repositories; only a PASS is ever scored.
- **Commas in `repos:`.** `repos: ., services/a` reads like `repos: .
  services/a`, as `human_gates` already did. A `repos:` value with no entry
  (`repos: ,`) is refused at `review` instead of binding nothing.
- **Delivered missing.** The message now says which line to add, and names
  a skipped Delivered path only as a note.

Selftest adds the `optin` group and checks in `uncommitted` (pruned tree),
`paths` (extra Delivered line) and `repos` (commas); each fails on v2.2.0.
Groups that test the uncommitted binding (`uncommitted`, `nested`,
`scoped`, `fingerprint`, `interrupt`) now pass `--uncommitted`.

## Compatibility

Existing records stay valid: a `.state` with `<head>+<tree>` from v2.2.0 is
still checked as before. A feature already refused by the v2.2.0 stray-file
regression keeps that `<head>+<tree>` binding: record a new review PASS
after upgrading. A commit-gated project that relied on v2.2.0 binding the
working tree implicitly must add `--uncommitted`; without it a Commit made
after the review is refused with "Commit <sha> is not the reviewed commit
<sha>: commit, then review again".

The default path matches v2.1.0 with one difference kept from v2.2.0: an
untracked nested repository (a worktree or clone) inside the Commit path no
longer makes the tree dirty at `score`, since it is never part of a commit.
