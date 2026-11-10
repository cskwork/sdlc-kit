# v2.24.0: A ship gate before any delivery

## Problem

Phase 4 said "ship the verified commit", but nothing checked before the delivery commands ran. In a product built with the kit by parallel agents, two releases were pushed and deployed on the build-phase review PASS while QA was still running or had not started; QA then found regressions, and the human found about eight defects after "done". `close <slug> shipped` caught this only after the delivery. In another round, QA carried typecheck and performance results over from the previous round instead of running them at the new commit.

## Changes

- **`sdlc.sh check ship <slug>`:** prints `GATE OPEN` only when what `close <slug> shipped` needs before a delivery already holds: a deliver route that is current for this evidence and build, the plan gate open, evidence that validates, each evidence Commit checked out clean at HEAD (`validate_commits`, as `score` uses), and authority for the target (Shipping's Ship to, else intent.md's). Otherwise `GATE CLOSED: <reason>`, exit 1: no evidence yet, evidence not scored, route is plan/build/human, code changed after QA, or target not authorized.
- **`next` / `status`:** the deliver action ends with `before shipping: sdlc.sh check ship <slug>`; its start (`ship, fill Shipping, sdlc.sh close <slug> shipped`) is unchanged.
- **Phase 4 Ship:** push, merge, release or deploy only once the ship gate is open; a review PASS is not that. A delivery the human orders earlier is recorded as `Shipped before evidence: <sha> — "<their words>"` in Shipping and reported as unverified; `close shipped` still needs a deliver route, so the slug stays open until evidence passes.
- **QA role:** every check and scenario runs at the round's commit; a result carried from an earlier round or commit is BLOCKED, `not re-run`. This stays a role rule: `score` has no record of when or at which commit a log was written.
- **SKILL.md rule 2** names the ship gate. Phase 3's `--uncommitted` paragraph now points to the PASS output for what a Commit must hold, keeping the prompt total at 6,000 words.
