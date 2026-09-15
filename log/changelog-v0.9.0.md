# v0.9.0 — feature and bug-fix workflow

## Changes

- Route ordinary feature and bug-fix requests through SDLC Kit, with a unified compact path for bounded changes and a full path for complex work.
- Bind gate records to their project, artifact contents, upstream decisions, and reviewed source state. Reject stale or mismatched approvals.
- Bind the ship approval to the project's whole source snapshot as the review saw it: tracked files plus untracked files git does not ignore, minus `.sdlc/`, by path, content, and executable bit, with symlinks bound to their target. Staging or committing the reviewed bytes keeps the binding valid — including work that was already committed when the review ran — while a later edit, new file, deletion, chmod, or symlink swap closes the gate and names the files that changed. Submodule contents are not bound.
- Require a `pr` or `deploy` delivery source to be a commit that CONTAINS the reviewed source: close compares that commit's tree against the reviewed snapshot instead of only checking that the sha exists. A `local` delivery may cite either a matching commit or the current worktree identity.
- Bind the full-route ship approval to the upstream decisions it was granted on top of — `intent.md`, `spec.md`, and `plan.md` as they stood at review time. Those files live under `.sdlc/`, which the source snapshot excludes, so a spec or plan rewritten or deleted after the ship review now closes the ship gate in `check-gate.sh`, `status.sh`, and `close.sh` with the re-approval command. A ship record that binds no digest for a spec or plan that exists (an older kit's record) fails closed the same way. The compact route has no spec and no plan, and none is ever demanded of it.
- Report one shared verdict on the ship source binding and the delivery record from `check-gate.sh`, `status.sh`, and `close.sh`, including an explicit diagnosis for ship approvals written by an older kit.
- Distinguish working-tree state from an observed deployment version.
- Require evidence that the agreed delivery target was reached before closing work as shipped.
- Require a real, scoped end-to-end check before shipping — the changed behavior driven through the interface a user or caller actually meets, recorded as command or tool, environment, scenario, and observed result — with a missing environment reported as NOT VERIFIED instead of a claimed pass or a silent unit-test substitute. Optional `e2e:` line in `.sdlc/config.md`; existing configs without it keep working.
- State the verifier's authority explicitly: no source or artifact edits, but build and test output, logs, and disposable fixtures are allowed. Remove the instruction to use `git stash`, which mutates the human's working tree.
- Record a clean supplemental risk scan in the approval record, so a record where risk was considered and one where it was not are distinguishable.
- Keep risk review independent of automation level and retain requirement and final verification summaries.
- Remove mandatory delegation at every stage, repeated requests for the same authorization, unconditional full-suite checks after each step, and immediate evidence cleanup after push.
- Add `gates/e2e.sh`: an integration suite that drives the real scripts through throwaway local git fixtures. It does not run `gates/selftest.sh` inside itself — CI and the release check run both suites — so a failure is reported once, by the suite that owns it.
- Refuse path names the kit cannot bind. A name git C-quotes (a tab, newline, double quote, or backslash in it) is not a path on disk once printed, so it was recorded as a stable `missing` placeholder that a later edit never changed — a source change that could close silently. Now `approve.sh ship` refuses such names by name before any record is written; a name that appears after the review makes `check-gate.sh`, `status.sh`, and `close.sh` report an invalid source and never pass; a `pr`/`deploy` Source commit whose tree has one is refused with its own reason. A tracked file deleted in the worktree still binds as `missing`, and Unicode or spaces in names still work. Supporting those names is out of scope; renaming or ignoring them is the fix.
- Propagate snapshot failures instead of hashing around them: a file or symlink that cannot be read or hashed, or a `git ls-files`/`ls-tree` that fails, is an explicit refusal (`error` state, no digest, no partial record), not a shorter list that hashes fine. Paths are addressed as `./<path>`, so a root symlink named `-link` hashes its real target and a retarget is drift, where before `readlink` read the name as an option and recorded a stable error.

## Upgrade notes

- Legacy approval markers require reapproval under the new content-binding rules.
- Ship approvals recorded before this release bound only the uncommitted diff — nothing at all when the work was already committed. They fail closed with that diagnosis; re-run the ship review and re-approve.
- The ship binding now covers the whole source snapshot, so an unrelated change made after the review also closes the gate. That is intentional: re-review and re-approve rather than closing over source nobody looked at.
- A full-route feature whose ship approval predates this release binds no spec or plan digest. It fails closed with the re-approval command; re-run the ship review and re-approve. Compact features are unaffected.
- Existing micro track names remain accepted; the old Maintain compressed route has an explicit continuation procedure.
- Run init.sh to update kit-owned ignore entries. Read and review the resulting diff; it does not modify the Git index.
- Approval hashes detect changes. They do not authenticate a human decision or prove a deployment occurred.
- The source snapshot is hashed file by file in shell: about 1 s per 40 files on a 2026 laptop. A repository with thousands of tracked files will notice it at ship approval, close, and status.

## Validation

Local, on macOS (Bash 3.2) — darwin 25.6.0, arm64, GNU bash 3.2.57, the oldest supported target — with git 2.54.0:

- `bash gates/selftest.sh` → `SELFTEST PASS`, exit 0 (35 cases, including the new one for work committed before the review, commit containment, and status/gate agreement).
- `bash gates/e2e.sh` → `E2E PASS`, 133 assertions, 0 failures, exit 0 (the suite no longer calls the selftest; the two run side by side). The 17 added assertions (C16–C17) cover git-quoted names refused before approval and detected after it, a delivered commit whose tree has one, and a root `-link` symlink whose retarget is drift and whose true commit delivers.
- `bash -n` over every shell script in the repository: clean.

Independent review found no remaining blockers after the source-binding and unsupported-path regressions were fixed. The final independent run also passed all 35 selftests and 133 E2E assertions.

The remote CI matrix (Ubuntu, macOS, Windows/Git Bash) runs on the PR and merged commit; its checks must pass before publication.
