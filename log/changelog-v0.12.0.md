# v0.12.0 — records out of git, an external knowledge area, and retrieval

Records are the project's knowledge, not its source. `init.sh` now ignores the
whole of `.sdlc/` with one anchored rule, an optional external area keeps a
checkout's store outside the checkout entirely, and `tools/kb.sh` is the way to
read any of it back. Gate authority, tamper detection, source binding, the
`--json` automation schema and lazymode are unchanged in kind.

## Changes

- **One ignore rule: `/.sdlc`.** `init.sh` writes it, anchored to the project root, so it matches this project's records — a real directory or the symlink an external area installs — and never a `.sdlc` deeper in the tree (a nested shipping unit keeps its own rule, written by its own init run). The twenty narrower kit-owned lines earlier versions issued are subsumed and removed by exact match; a CRLF `.gitignore` is handled, and every other line, its bytes and its line ending, is written back untouched. **The git index is never touched**: records already committed by an older kit stay committed until you untrack them yourself, and `init.sh` prints the exact command.
- **`init.sh [dir] --area <folder>` — an external knowledge area.** The store is `<folder>/<unit>-<checkout-id>/`, `.sdlc` is a symlink to it, and `<store>/PROJECT` records the owning checkout, its unit, its id, the creation time and the kit version. One store per checkout, so two worktrees or two same-named clones never share approvals. Refused, writing nothing: an area inside the project, a project inside the area (checked before any folder is created), a store another checkout owns, a directory that is not a store, an unwritable area, a `.sdlc` link that points elsewhere, or a link the filesystem cannot create.
- **Ownership is enforced at runtime, not only at init.** `check-gate.sh`, `approve.sh`, `close.sh`, `status.sh` (prose and `--json`), `tools/auto.sh`, `tools/verify.sh`, `tools/handoff.sh`, `init.sh` (including an ordinary re-run) and `tools/kb.sh index` all refuse, before any verdict and before any write, when the store they reach names a different checkout, carries no ownership record, or carries an unreadable one. This closes a real accident: `cp -R`, rsync, `tar` without `--dereference` and most backup restores preserve the `.sdlc` symlink, so a copied working copy resolved into the ORIGINAL's store and could read its approvals and archive its features. An ordinary project-local `.sdlc` directory has no `PROJECT` record, needs none, and is unaffected.
- **Nothing is migrated, re-bound, or moved for you.** A refusal prints the store, the recorded owner, this checkout, how to read the records (`tools/kb.sh --store/--area`), how to give this checkout a store of its own, and — for a renamed or moved checkout — the one manual line to edit (`project:` in `<store>/PROJECT`). A real `.sdlc` directory is never relocated by `--area`; it keeps working exactly as it is.
- **`tools/kb.sh` — reading the records back.** `index` regenerates a store's contents page (`init.sh` and `close.sh` run it; a `README.md` it did not generate is never overwritten), `show <slug>` prints one feature's goal, track, documents, delivery and lessons, `search "<text>"` is a bounded literal (`grep -F`) search across open and closed features and durable memory, and `list` names stores and features. `--area <folder>` covers every owned store in that folder, read-only and one level deep, following no symlinks — **including features whose checkout no longer exists**. `scratch/`, `approvals/`, `progress.md`, `baseline.txt`, `checkpoint.md` and `verify-receipt.md` are never read. Exit codes: `0` found, `1` nothing found, `2` usage error or refusal.
- **Readable store names.** Only path-hostile characters are replaced in the unit name, so a Korean, Japanese or accented checkout name stays legible in the area listing and in `kb.sh` output (`지식-프로젝트-e2117a76`), instead of collapsing to `project-<id>`.
- **The source snapshot excludes the bare `.sdlc` entry** as well as its descendants, in both the working-source list and the committed-tree enumeration, so an external store's symlink is never bound by a ship approval and moving the area is not drift.
- **Stage guidance and docs.** `skills/1-intent`, `skills/5-ship`, `skills/6-maintain`, `templates/evidence.md`, `AGENTS.md` rule 7, `SKILL.md`, both READMEs, `docs/index.html` and `docs/automation.md` state the same storage behaviour: records are ignored by default, a clone does not carry them, the store is yours to back up, and a stage starts with a targeted `kb.sh search`/`show` instead of scanning the archive.

## Usage

```sh
# default: records stay in the checkout, ignored by git
~/sdlc-kit/init.sh .

# or keep this checkout's records outside it, in a folder you choose
~/sdlc-kit/init.sh . --area ~/knowledge
#   → ~/knowledge/<unit>-<checkout-id>/ , with .sdlc linked to it

# read the records back, from the project
~/sdlc-kit/tools/kb.sh index                       # refresh this store's contents page
~/sdlc-kit/tools/kb.sh show   260920-login-fix     # one feature: goal, documents, delivery, lessons
~/sdlc-kit/tools/kb.sh search "rate limit"         # bounded literal search

# … or across every store in the area, from anywhere, read-only
~/sdlc-kit/tools/kb.sh list   --area ~/knowledge
~/sdlc-kit/tools/kb.sh show   260920-login-fix --area ~/knowledge
~/sdlc-kit/tools/kb.sh search "rate limit" --area ~/knowledge --limit 20
```

## Upgrade notes

- **Existing projects keep working.** Re-run `init.sh` to get the single `/.sdlc` rule and the cleanup of the lines it subsumes. Your existing records are not moved, rewritten or deleted, and **the git index is left exactly as it is** — already-committed records stay in history until you run the untracking command `init.sh` prints.
- **There is no automated migration**, by design. `--area` never relocates a real `.sdlc` directory: to use an area for a checkout that already has local records, move them aside yourself and let `init.sh` create an empty store; the old records stay readable with `tools/kb.sh --store <path>`.
- **Approval state is per checkout; retrieval is area-wide.** Gates, status, verification and handoff answer only for the checkout that owns the store. Reading (`kb.sh list|show|search`, with or without `--area`) is not bound to any checkout, which is what lets knowledge outlive the worktree that produced it.
- **Backups and versioning of the store are yours**, whichever location you choose: git no longer carries the records, and this kit adds no backup mechanism.
- **Windows:** `--area` requires real symlinks — run Git Bash with `MSYS=winsymlinks:nativestrict`. `init.sh` fails loudly if the link comes out as a copy rather than creating a forked store, and `gates/knowledge-test.sh` reports the external-area cases as NOT VERIFIED where the filesystem cannot link at all.
- `docs/index.html` no longer describes the durable record as committable; that policy is the one this release inverts.

## Validation

Local, on macOS (darwin 25.6.0, arm64, GNU bash 3.2.57, git 2.54.0, APFS
case-insensitive, UTF-8):

- `bash gates/selftest.sh` → `SELFTEST PASS`
- `bash gates/knowledge-test.sh` → `KNOWLEDGE-TEST PASS`, 103 assertions, 0 failures (new suite: the ignore rule, area binding and every refusal, the loop through the link, owner isolation against a `cp -R` copy, CRLF ignore cleanup, readable Unicode store names, retrieval after the checkout is deleted)
- `bash gates/e2e.sh` → `E2E PASS`, 152 assertions, 0 failures
- `bash gates/autotest.sh` → `AUTOTEST PASS`, 195 assertions, 0 failures
- `bash -n` over every changed shell script: clean. `git diff --check`: clean.

**Linux and Windows/Git Bash: NOT VERIFIED locally.** The CI workflow covers
ubuntu, macos and windows runners, but that run has not happened for this
release yet — it is pending, not passing.
