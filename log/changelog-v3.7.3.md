# v3.7.3: Automatic commit receipts withdrawn; the tray app uses about 166 MB less memory

## Problem

- **A review PASS wrote commit receipts (v3.7.0).** The receipt means "verify and review both passed on this tree", but a PASS came before QA, could hold edits made after the reviewer read the change, and was written for every repository found under the project root, reviewed or not. A pre-commit hook then let that code through.
- **The tray app was large.** On macOS it read the whole Hangul system font (53 MB) into memory, and epaint copied it once more: 106 MB, and more while loading.

## Changes

- **Receipts (`sdlc.sh`, `phases/3-build.md`).** `review pass --uncommitted` no longer writes one. Where a pre-commit-gate hook guards commits, that skill writes its own receipt after verify and review. **Upgrading from v3.7.0–v3.7.2:** a receipt written before the upgrade still opens the hook for its exact tree; remove `pre-commit-gate-receipt` from the git folder (`git rev-parse --git-path pre-commit-gate-receipt`) of the repository holding a project root where such a review ran and of every repository and worktree under it, also ones the review was not about, and run the gate again.
- **Fonts (`todo/app/src/theme.rs`).** macOS's system font is mapped from its sealed volume and the built-in font is used in place; neither is copied. On other systems the font is read once instead of held twice. A font the person picks is still read and checked as before.

## Verification

- Selftest: an uncommitted review PASS leaves no receipt.
- App footprint on a copy of a real list, board window open, 20 s after start: 221 MB before, 55 MB after. The 106 MB of large allocations is gone.
- `cargo test --release` in `todo/app`: 26 of 26.
