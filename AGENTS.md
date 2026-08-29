# sdlc-kit agent routing contract

This kit implements Anthropic's AI-Native SDLC playbook with plain files and
shell scripts. It works across agent tools without runtime hooks or
vendor-specific features.

## The loop

Six stages. Each stage produces ONE artifact. A human approval of that artifact
(recorded by `gates/approve.sh`) opens the next stage. A production issue in
stage 6 creates a new `intent.md` and starts the loop again.

| # | Stage    | Read this skill first              | Artifact (in project `.sdlc/work/<feature>/`) | Gate to pass BEFORE starting |
|---|----------|------------------------------------|-----------------------------------------------|------------------------------|
| 1 | Intent   | `skills/1-intent/SKILL.md`         | `intent.md`                                   | none; proceed               |
| 2 | Spec     | `skills/2-spec/SKILL.md`           | `spec.md`                                     | `intent`                     |
| 3 | Plan     | `skills/3-plan/SKILL.md`           | `plan.md`                                     | `spec`                       |
| 4 | Build    | `skills/4-build/SKILL.md`          | code + tests                                  | `plan`                       |
| 5 | Ship     | `skills/5-ship/SKILL.md`           | `evidence.md`                                 | none; build done and checks pass |
| 6 | Maintain | `skills/6-maintain/SKILL.md`       | new `intent.md` + lesson                      | none; triggered by incident |

Stage names double as gate names: `gates/check-gate.sh spec .sdlc/work/<feature>/spec.md`.

**Every feature ends in a terminal state.** Run `gates/close.sh <slug>
<shipped|abandoned|dead-end|handed-off> "reason"` after the human decides. Use
`--delegated` under rule 3. An abandoned or dead-end close requires a lesson
that records what was tried, why it failed, and what would unblock it. A
handed-off close requires the external ticket/PR key or URL in the reason, so
the audit trail continues outside this loop. Add durable facts to DOMAIN.md
when closing. `status.sh` shows each closed feature on one line and proposes
no next action.

## Hard rules (every stage, every harness)

1. **Read the stage skill file COMPLETELY before acting.** Resolve paths
   relative to this kit's directory. On Windows, run every `gates/*.sh` and
   `tools/*.sh` through Git Bash or WSL, not PowerShell or cmd. When a native
   Windows path is needed, `.sdlc/config.md` records it as `kit_windows:`.
2. **Check the gate first** for stages 2-4. Stages 1, 5, and 6 have no gate.
   Run `gates/check-gate.sh <prev-stage> <artifact>` from the project root.
   Treat any result other than a printed `GATE OPEN` as a closed gate. This
   includes GATE CLOSED, errors, and silence. STOP and tell the human exactly
   what to approve.
3. **Approval is a human decision. The command may be delegated.** Run
   `gates/approve.sh <stage> <artifact> --delegated` only after the human
   explicitly approves this artifact at this stage in chat. Valid responses
   include "approve", "looks right", or an equivalent answer to the gate
   request. The record then includes `mode: delegated-chat`. Never approve
   based on silence, a general "continue", or your own judgment. Never write
   directly to `.sdlc/approvals/`. If the artifact changes after the human
   approves it, ask again because the approval applied to different bytes.
   Commit approvals to git. Git history is the audit trail.
4. **Keep memory bounded.** At each stage start, read
   `.sdlc/memory/INDEX.md` and `.sdlc/memory/DOMAIN.md`. INDEX.md stores lessons
   about past mistakes and their corrections. DOMAIN.md stores terms, verified
   facts, and important constraints. Then open lesson files whose tags match
   the current task. Researchers return verified domain candidates in their
   reports. The dispatcher merges those candidates into DOMAIN.md. Keep
   INDEX.md at 50 lines or fewer and DOMAIN.md at 100 lines or fewer. If either
   file exceeds its limit, split it by subdomain and add pointer lines. Record
   each new mistake in the skill 6 format.
5. **Fresh context for helpers.** Verification and adversarial review must run
   in a fresh context: a subagent if your harness has them (pi: subagent tool;
   Claude Code: Task tool; Codex: spawn), else a new session given only the
   role file + artifact paths. The role files are `roles/*.md`. Verification
   always runs in a context that did not author the artifact. If your
   harness lets you pick models, give the verifier and adversary the strongest
   one available. A weak review can let defects pass.

   **Roles are contracts, not headcount.** A stage may run several workers
   under one role when their probes are independent. Examples include git
   history, the live UI, an API, and the database. Use the fewest read-only
   workers needed. Use one writer per checkout. The dispatcher merges reports
   and resolves contradictions with primary evidence. A contradiction between
   two probes is a finding.

   **Dispatch contract.** Every role dispatch must name its goal, exact input
   paths, write authority, verification commands from `.sdlc/config.md`,
   success criteria, output format, and stop rules. Stop rules say when to STOP
   and escalate instead of improvising. Missing fields let a helper invent
   scope.

   **Bulk rule.** Screenshots, probe logs, traces, and large command dumps are
   temporary evidence. Write them to the gitignored
   `.sdlc/work/<feature>/scratch/` directory. Read them, quote the deciding
   lines in the stage artifact, then delete them. Keep the citation, not the
   bulk file.
6. **Proof over claims.** Every "done" claim carries command output. Real
   verification commands live in the project's `.sdlc/config.md`.
7. **Artifacts live in the project repo**, under `.sdlc/work/<feature>/`, and
   are committed with the code. The kit directory stays framework-only.
8. **Speak plainly in every report, gate request, and question.** Assume the
   reader lost the thread. Start with one short paragraph of context: what stage you
   are in, what happened before, what this message is for. Then the content.
   Write in Simplified Technical English: short sentences, one idea per
   sentence, active voice, no undefined jargon. Use the project's own
   vocabulary. End with the one decision or action the reader must take.

## Greenfield vs brownfield

Stage 1 classifies the feature as greenfield (new system/module) or brownfield
(change to existing behavior) and records it in `intent.md`. Downstream skills
branch on it. Brownfield work adds a researcher pass over existing code, a
regression baseline captured before changes, and a "what stays untouched"
section in the spec.

## Running beside other AGENTS.md files, skills, and agents

Large codebases already have their own rules, docs, and specialist agents.
The kit is a process layer on top of them, so precedence is explicit:

1. **Precedence.** The project's own rules control implementation details such
   as build commands, branch policy, code style, commit format, and tool choice.
   The kit controls stage order, gates, and memory. No
   other document can waive a gate; only the human at the gate can. When a
   project rule and a kit rule genuinely conflict, show both texts to the
   human. Do not resolve the conflict silently.
2. **Existing knowledge wins.** If the project already has a glossary,
   CONTEXT.md, ADRs, or domain docs, DOMAIN.md defers to them: add a pointer
   line (`- see docs/glossary.md [verified: exists]`) instead of copying
   content. DOMAIN.md holds only facts that exist nowhere else.
3. **Existing agents win.** When the environment has a specialist agent that
   matches a kit role (a QA agent, a code reviewer, a DB reader), dispatch
   that agent with the kit's role file as its task contract. The role file
   defines the contract, and the local specialist executes it. Spawn a generic
   worker only when no specialist fits. Fresh context and the dispatch
   contract still apply either way.
4. **Monorepos.** Seed `.sdlc/` at the level where features ship and gates
   are decided. This is usually the service or package, not the repo root. One
   `.sdlc/` per shipping unit; a root `.sdlc/` only for changes that span
   units. Say in intent.md which unit owns the feature.

## If your harness lacks a feature

- Without subagents, open a fresh session or tab with the role file and
  artifact paths as the complete prompt. Paste the report back.
- Without a file-read tool, paste file contents manually. The contract is the
  files, not the transport.
