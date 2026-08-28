# Verify report — sdlc-kit (2026-08-28)

VERDICT: PASS (after fixes) — 1 blocking + 1 regression found and fixed during the run.

Base: empty tree (new repo). Scope: whole kit — 4 shell scripts, AGENTS.md, README, 6 skills, 3 roles, 5 templates. No HTTP endpoints exist; gate 4 = scenario matrix against the gate *scripts* (the kit's real API).

| Gate | Verdict | Receipt |
|------|---------|---------|
| 1 Build (selftest) | PASS | receipts/01-build.log, 05-fix-verification.log (final: 6/6 ok, exit=0) |
| 2 Static (bash -n ×4, 16 cross-refs) | PASS | receipts/02-static.log |
| 3 Clean code (fresh-context reviewer) | FAIL→fixed | reviewer report (session log); fixes in 05-fix-verification.log |
| 4 Scenario (happy/boundary/negative ×11) | FAIL→fixed | receipts/04-scenario/*.txt |
| 5 Report | PASS | this file |

Found and fixed:
1. BLOCKING: corrupt approval record (missing sha256 line) → check-gate died under pipefail with NO output; agents' contract is output-based. Now: explicit "GATE CLOSED: corrupt approval record". Selftest case 6 covers it.
2. Scenario: stage-name injection ("../../etc/pwn") wrote approval outside approvals/. Now rejected; selftest case 4.
3. Regression (introduced by fix 1 rewrite): dropped `mkdir -p .sdlc/approvals` — caught by selftest rerun, restored.
4. Bare-path artifact (slug ".") now rejected; selftest case 5.
5. Linux portability: shasum→sha256sum fallback; verified via PATH simulation (receipt in 05-fix-verification.log).
6. Doc fixes: gate table rows for stages 1/5/6 (no stall), rule 2 treats silence as closed, rule 3 forbids writing approvals/ at all, README tamper-evidence claim scoped to real threat model, skill-6 hotfix loop gets its own feature dir, memory cap wording unified (≤50 lines), config.md tells agents to stop on empty commands.

Unverified:
- Real Linux box (only PATH simulation), Windows/WSL untested.
- A live feature driven through all six gates by a real harness — first-use territory.

Next: commit+push (done in same session).
