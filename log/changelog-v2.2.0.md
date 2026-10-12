# v2.2.0 — friction from a large monorepo

Six fixes from using the kit on a project root that holds hundreds of git
worktrees, where a human approves every commit.

## Changes

- **`repos:` in config.md.** A space-separated list of repository top
  folders, relative to the project root (`.` for the repository holding the
  root; no spaces inside a path), limits which repositories a review PASS
  binds. Empty or absent binds every repository under the root, as before,
  but `review` now also runs one `git status` per repository to find
  uncommitted changes, so a root with many repositories is slower than in
  v2.1.0: list them in `repos:` to bound it. On a root with hundreds of
  worktrees the full scan took over 30 s per `review`. An entry that is not a
  folder under the root (`../x`, or a symlink resolving outside it), not in a
  repository, or a plain folder inside one is refused by name, and a Commit
  outside the list says the list limited the review.
- **Review before commit.** `sdlc.sh review` on uncommitted changes binds the
  PASS to each such repository's HEAD and the tree its working tree would
  commit (untracked, unignored files included; the store and untracked
  repositories nested inside it excluded, so a root full of worktrees is not
  dirty and `review` prints no git warning per nested repository). `score`
  then accepts, with no new round, a Commit that is or descends from that HEAD,
  holds the reviewed tree inside its Commit path, and changes nothing outside
  the path that the reviewed tree lacks. Anything else needs a new round:
  reverting or stashing the change and scoring the reviewed HEAD itself, an
  amended or rebased commit, or any other content. Only repositories named on
  Commit lines are compared. Reviewing a commit works as before: uncommitted
  changes outside every Commit path still do not block it. Renames count as
  a deletion plus an addition, so an unreviewed rename outside the path is
  refused too. The store stays out of the tree whether it is untracked,
  ignored or partly tracked. If git cannot read the working tree (an
  unreadable file, say), `review` prints one line saying why and binds HEAD
  alone, as v2.1.0 did. The temporary index used for the tree is removed on
  interrupt too.
- **Cell counts.** A Scenarios row in PLAN.md or a Results row in evidence.md
  with more cells than its header is reported as `S1: row has 6 cells, header
  has 5` instead of a misleading log error. A row with fewer cells (GFM allows
  it, e.g. `| S1 | BLOCKED | | no env |`) reads as in v2.1.0. `\|` still
  counts as text.
- **Repository paths.** A Commit or Delivered path that is not a folder under
  the project root says so, quoted, with the line format
  `<sha> <relative-path>`, instead of `repository missing`.
- **QA sandbox.** QA that cannot write the feature folder writes evidence.md
  and `logs/` to a temporary folder and reports its path; the coordinator
  copies them in (roles/qa.md, SKILL.md rule 4).
- **Real-use evidence in Intent.** Before logs, error records, reports or
  metrics count as evidence, Intent checks their source shows real use, not
  tests, automation or synthetic traffic.

Selftest adds eight regression groups (`repos`, `cells`, `paths`,
`uncommitted`, `nested`, `interrupt`, `scoped`, `fingerprint`); each fails
without its fix for the reported reason. `interrupt` and the unreadable-file
check in `fingerprint` skip on Git Bash, whose signals and permissions are
untested.

## Compatibility

Existing records stay valid. A review recorded by v2.1.0 binds HEADs as
before; a `.state` written by v2.2.0 for an uncommitted review stores
`<head>+<tree>` for that repository, which v2.1.0 cannot read as a match.
