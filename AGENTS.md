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
| 1 | Intent   | `skills/1-intent/SKILL.md`         | `intent.md`                                   | none                         |
| 2 | Spec     | `skills/2-spec/SKILL.md`           | `spec.md`                                     | `intent`                     |
| 3 | Plan     | `skills/3-plan/SKILL.md`           | `plan.md`                                     | `spec`                       |
| 4 | Build    | `skills/4-build/SKILL.md`          | code + tests                                  | `plan`                       |
| 5 | Ship     | `skills/5-ship/SKILL.md`           | `evidence.md`                                 | (build output)               |
| 6 | Maintain | `skills/6-maintain/SKILL.md`       | new `intent.md` + lesson                      | `ship`                       |

Stage names double as gate names: `gates/check-gate.sh spec .sdlc/work/<feature>/spec.md`.

## Hard rules (every stage, every harness)

1. **Read the stage skill file COMPLETELY before acting.** Resolve paths
   relative to this kit's directory.
2. **Check the gate first.** Run `gates/check-gate.sh <prev-stage> <artifact>`
   from the project root. If it prints GATE CLOSED, STOP and tell the human
   exactly what to approve. Never proceed past a closed gate.
3. **Never run `gates/approve.sh`.** Approval is a human act. Writing an
   approval yourself is falsifying an audit record.
4. **Memory, bounded.** At stage start, read `.sdlc/memory/INDEX.md` (never the
   whole lessons dir). Open only lesson files whose tags match the current
   task. When you make or discover a mistake, record it (see skill 6 format).
5. **Fresh context for helpers.** Verification and adversarial review must run
   in a fresh context: a subagent if your harness has them (pi: subagent tool;
   Claude Code: Task tool; Codex: spawn), else a new session given only the
   role file + artifact paths. The role files are `roles/*.md`. The author of
   an artifact never verifies its own artifact in the same context.
6. **Proof over claims.** Every "done" claim carries command output. Real
   verification commands live in the project's `.sdlc/config.md`.
7. **Artifacts live in the project repo**, under `.sdlc/work/<feature>/`, and
   are committed with the code. Never store work artifacts inside the kit.

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
