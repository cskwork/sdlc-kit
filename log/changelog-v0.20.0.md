# v0.20.0 — batched source hashing: close in seconds, not minutes

`close.sh <slug> shipped` could take minutes on Windows (Git Bash) in a repo
with a few thousand files. The source snapshot started a process or three per
file, the commit read (a delivered `Source` sha) started two or three more per
file, one of them `git`, and a shipped close with a verification recipe walked
the whole source twice. Git Bash starts processes slowly, so the cost was
mostly process startup. The verdicts are the same. Only the number of
processes changes.

## Changes

- **gates/_common.sh `sdlc_sha256_paths`:** hashes many files with one
  `sha256sum` (or `shasum`) run through `xargs -0`, one digest per path in
  order. The openssl fallback still hashes one file at a time.
- **Worktree snapshot (`sdlc_source_entries`):** files are classified as
  before, then hashed in one batch. If the batch fails (an unreadable file, or
  a file gone since it was listed), the files are hashed one at a time, so the
  `FAIL:` line still names the file.
- **Commit read (`sdlc_tree_entries`):** the commit is checked out once into a
  temp dir through a temp index, so the repository's index and worktree are
  untouched. `checkout-index` writes the bytes a checkout would, through the
  same filters, and one batch hashes them. Symlinks, submodules and quoted
  names still go blob by blob. On any failure (names that clash when case is
  ignored, a name the filesystem refuses), the whole commit is read blob by
  blob as before. `tools/handoff.sh` uses this read too.
- **close.sh takes one snapshot:** when the source binding is `ok`, the digest
  it just computed is reused by the verification check (`SDLC_SOURCE_DIGEST_NOW`).
  The variable is cleared each time `_common.sh` loads, so a value from the
  environment is never trusted.

Measured on macOS (bash 3.2) with the same digests before and after:

| repo | worktree snapshot | commit read |
|---|---|---|
| 1,550 files | 14 s → <1 s | 33 s → 4 s |
| 3,700 files | 21 s → 1 s | 88 s → 11 s |

Most of the remaining commit-read time comes from endpoint antivirus scanning
the freshly written temp files on first read. A second read of the same files
takes 0.5 s. A shipped close over a commit `Source` in the 3,700-file repo went
from about 130 s to about 12 s. The approve, status, verify and handoff
commands share these helpers, so they get faster too.

## Validation

- `bash gates/selftest.sh` → `SELFTEST PASS` on macOS; CI runs ubuntu, macos
  and windows. The new section 10 checks that the worktree snapshot, the
  one-checkout commit read, and the blob-by-blob read of the same commit give
  identical entries. The fixture has spaces, a leading `-`, a Hangul name, an
  executable, a symlink, an `eol=crlf` filter and `.sdlc/`. It also checks the
  one-at-a-time fallback, a case clash that has to take the blob read, and
  that an inherited `SDLC_SOURCE_DIGEST_NOW` is ignored.
- Digests compared on three real repositories (65, 1,550 and 3,700 files):
  byte-identical to v0.19.0 for both the worktree and the `HEAD` reads.
