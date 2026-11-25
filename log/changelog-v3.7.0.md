# v3.7.0: An uncommitted review PASS writes a pre-commit-gate receipt

## Problem

[pre-commit-gate](https://github.com/cskwork/pre-commit-gate-skill) installs a git `pre-commit` hook that blocks a code commit unless a receipt names the HEAD and the staged tree that verify and review passed. A factory worker following phase 3 committed first and reviewed the commit, so in a repository with that hook its commit was refused before the reviewer ever ran. Writing the receipt by hand would let it drift from what the reviewer actually judged.

## Changes

- **Receipt from the PASS (`sdlc.sh review`).** When `review <slug> pass --uncommitted` binds a repository's HEAD and working-tree tree, it now also writes `HEAD tree` to that repository's `$(git rev-parse --git-path pre-commit-gate-receipt)`. The tree is the one the PASS already binds: what `git add -A` would commit, the store and untracked nested repositories left out. A committed review (HEAD only) writes nothing.
- **Output.** The PASS adds one line, `pre-commit-gate receipt written: N repository(s)`, when it wrote any.
- **Phase 3 (`phases/3-build.md`).** A repository whose pre-commit hook asks for a receipt reviews the uncommitted change, as one that needs the human's approval for every commit does; staging all of it and committing exactly that passes the hook.

## Verification

- New selftest assertion in `regression_uncommitted`: after an uncommitted PASS, the receipt equals `$(git rev-parse HEAD) $(git write-tree)` once the reviewed files are staged, and the PASS prints the receipt line.
- The nested-repository review still prints under 400 bytes.
