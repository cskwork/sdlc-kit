# sdlc-kit — agent routing contract

You are operating an AI-native SDLC (per Anthropic's AI-Native SDLC playbook),
adapted to be harness-neutral: everything is plain files + shell scripts. No
runtime hooks, no harness-specific features required.

## The loop

Six stages. Each stage produces ONE artifact. A human approval of that artifact
(recorded by `gates/approve.sh`) opens the next stage. A production issue in
stage 6 writes a new `intent.md` — the loop feeds itself.

| # | Stage    | Read this skill first              | Artifact (in project `.sdlc/work/<feature>/`) | Gate to pass BEFORE starting |
|---|----------|------------------------------------|-----------------------------------------------|------------------------------|
| 1 | Intent   | `skills/1-intent/SKILL.md`         | `intent.md`                                   | none — proceed               |
| 2 | Spec     | `skills/2-spec/SKILL.md`           | `spec.md`                                     | `intent`                     |
| 3 | Plan     | `skills/3-plan/SKILL.md`           | `plan.md`                                     | `spec`                       |
| 4 | Build    | `skills/4-build/SKILL.md`          | code + tests                                  | `plan`                       |
| 5 | Ship     | `skills/5-ship/SKILL.md`           | `evidence.md`                                 | none — build done + checks green |
| 6 | Maintain | `skills/6-maintain/SKILL.md`       | new `intent.md` + lesson                      | none — triggered by incident |

Stage names double as gate names: `gates/check-gate.sh spec .sdlc/work/<feature>/spec.md`.

## Hard rules (every stage, every harness)

1. **Read the stage skill file COMPLETELY before acting.** Resolve paths
   relative to this kit's directory.
2. **Check the gate first** (stages 2-4; stages 1, 5, 6 have none — proceed).
   Run `gates/check-gate.sh <prev-stage> <artifact>` from the project root.
   Treat anything other than a printed `GATE OPEN` — including GATE CLOSED,
   errors, or silence — as a closed gate: STOP and tell the human exactly what
   to approve.
3. **Approval is a human DECISION; the keystrokes may be delegated.** You may
   run `gates/approve.sh <stage> <artifact> --delegated` ONLY after the human
   has explicitly approved THIS artifact at THIS stage in chat ("approve",
   "looks right", or equivalent, in response to your gate request). The record
   then carries a `mode: delegated-chat` line — delegation is always visible,
   never silent. Never approve on silence, on a general "continue", or on your
   own judgment; never write files under `.sdlc/approvals/` directly. If the
   artifact changed after the human's approval words, re-request — their words
   applied to a file that no longer exists. Approvals must be committed to git
   — the git history is the real audit trail.
4. **Memory, bounded.** At stage start, read `.sdlc/memory/INDEX.md` (never the
   whole lessons dir). Open only lesson files whose tags match the current
   task. When you make or discover a mistake, record it (see skill 6 format).
5. **Fresh context for helpers.** Verification and adversarial review must run
   in a fresh context: a subagent if your harness has them (pi: subagent tool;
   Claude Code: Task tool; Codex: spawn), else a new session given only the
   role file + artifact paths. The role files are `roles/*.md`. The author of
   an artifact never verifies its own artifact in the same context. If your
   harness lets you pick models, give the verifier and adversary the strongest
   one available — their failure mode is a silent PASS that no later stage
   catches.

   **Roles are contracts, not headcount.** A stage may fan out SEVERAL
   workers under one role in parallel when their probes are independent —
   e.g. one researcher on git history, one walking the live UI in a browser,
   one probing an API, one reading the DB. Read-only fanout is bounded only
   by usefulness; writers stay singular (one writer per checkout, always).
   The dispatcher merges reports and settles contradictions with primary
   evidence — a contradiction between two probes is a finding, not noise.

   **Dispatch contract.** Every role dispatch names, explicitly:
   goal · inputs (exact artifact paths) · authority (which paths it may
   write, usually none) · evidence (the verify commands from
   `.sdlc/config.md`) · success criteria · output (file or report format) ·
   stop rules (when to STOP and escalate instead of improvising). A dispatch
   missing one of these is how a helper silently invents scope.

   **Bulk rule.** Screenshots, probe logs, traces, and large command dumps
   are evidence to read, not artifacts to keep. Write them to
   `.sdlc/work/<feature>/scratch/` (gitignored), read them, quote the
   deciding lines into the stage artifact, then delete the file. The
   artifact is the record; cite the evidence, do not carry it.
6. **Proof over claims.** Every "done" claim carries command output. Real
   verification commands live in the project's `.sdlc/config.md`.
7. **Artifacts live in the project repo**, under `.sdlc/work/<feature>/`, and
   are committed with the code. Never store work artifacts inside the kit.
8. **Speak plainly (every report, every gate request).** Assume the reader
   lost the thread. Start with one short paragraph of context: what stage you
   are in, what happened before, what this message is for. Then the content.
   Write in Simplified Technical English: short sentences, one idea per
   sentence, active voice, no undefined jargon. Use the project's own
   vocabulary. End with the one decision or action the reader must take.

## Greenfield vs brownfield

Stage 1 classifies the feature as greenfield (new system/module) or brownfield
(change to existing behavior) and records it in `intent.md`. Downstream skills
branch on it — brownfield adds: researcher pass over existing code, a
regression baseline captured BEFORE changes, and "what stays untouched" as a
spec section.

## If your harness lacks a feature

- No subagents → open a fresh session/tab manually with the role file as the
  entire prompt, plus artifact paths. Paste the report back.
- No file-read tool → paste file contents manually. The contract is the files,
  not the transport.
