# ADR 0002: Bind approvals and reviews to content hashes and commits

- **Status:** Accepted
- **Source:** `sdlc.sh` (`gate_intent`, `gate_plan`, `approve`, `review_heads`,
  `validate_commits`, `close`), `log/changelog-v2.0.0.md`

## Context

An agent can edit an artifact after a human approved it, or ship code other
than the code that was reviewed. A boolean "approved" flag cannot detect
either.

## Decision

- `approve intent` stores `sha256(intent.md)`, the approver kind (`human` or
  `agent`), a sequence number, a timestamp and the note in `.state`.
- `approve plan` stores `sha256(PLAN.md)` **and** the `intent.md` hash it was
  approved against. `gate_plan` closes if either file changes.
- `approve ... --sha <hex>` refuses the approval when the file no longer has
  the bytes the human was shown.
- A review PASS records the HEAD of every bound repository (HEAD + tree with
  `--uncommitted`). `score` refuses a `Commit:` that is not that HEAD or a
  dirty tree; `close shipped` refuses a `Shipped:` tree that differs from the
  verified commit.

## Consequences

- Any edit to an approved artifact closes its gate and later gates;
  `sdlc.sh next` says which file changed. Fixing a typo needs a new approval.
- Agents cannot approve their own gates where `human_gates` or a plan risk flag
  demands `--human`.
- `--human` is a recorded claim, not authentication; the README notes that
  same-user programs are outside this boundary.

## Alternatives considered

- **Approval flag or timestamp only.** Does not detect edits after approval.
- **Git commits of the artifacts.** `.sdlc/` is kept out of git by design
  (`init` writes `.git/info/exclude`), so the hash lives in `.state` instead.
