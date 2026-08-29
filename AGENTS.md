# sdlc-kit agent routing contract

Anthropic's AI-Native SDLC playbook as plain Markdown and shell scripts. No
runtime hooks, no vendor-specific features.

## The loop

Six stages, one artifact each. An approval recorded by `gates/approve.sh`
opens the next stage. Intent, spec, and ship approvals are human decisions
unless the project's lazymode waives them; the plan gate is tiered (rule 3). A production issue in stage 6 writes the
next `intent.md` and restarts the loop.

| # | Stage    | Read this skill first              | Artifact (in project `.sdlc/work/<feature>/`) | Gate to pass BEFORE starting |
|---|----------|------------------------------------|-----------------------------------------------|------------------------------|
| 1 | Intent   | `skills/1-intent/SKILL.md`         | `intent.md`                                   | none; proceed               |
| 2 | Spec     | `skills/2-spec/SKILL.md`           | `spec.md`                                     | `intent`                     |
| 3 | Plan     | `skills/3-plan/SKILL.md`           | `plan.md`                                     | `spec`                       |
| 4 | Build    | `skills/4-build/SKILL.md`          | code + tests                                  | `plan` (tiered, rule 3)      |
| 5 | Ship     | `skills/5-ship/SKILL.md`           | `evidence.md`                                 | none; build done and checks pass |
| 6 | Maintain | `skills/6-maintain/SKILL.md`       | new `intent.md` + lesson                      | none; triggered by incident |

Stage names double as gate names: `gates/check-gate.sh spec .sdlc/work/<feature>/spec.md`.

**Every feature ends in a terminal state**: `gates/close.sh <slug>
<shipped|abandoned|dead-end|handed-off> "reason"` after the human decides
(`--delegated` under rule 3). Abandoned or dead-end requires a lesson first:
what was tried, why it failed, what would unblock it (lazymode ≥3 waives the
separate lesson file — the close reason is the record). Handed-off requires the
external ticket/PR key or URL in the reason. Add durable facts to DOMAIN.md
when closing.

## Hard rules (every stage, every harness)

1. **Read the stage skill file COMPLETELY before acting.** Resolve paths
   relative to this kit's directory. On Windows run `gates/*.sh` and
   `tools/*.sh` through Git Bash or WSL; `.sdlc/config.md` records a native
   path as `kit_windows:` when one is needed.
2. **Check the gate first** for stages 2-4 (stages 1, 5, and 6 have none):
   `gates/check-gate.sh <prev-stage> <artifact>` from the project root.
   Anything but a printed `GATE OPEN` — including errors and silence — is
   closed: STOP and tell the human exactly what to approve. At a gate
   lazymode waives (rule 3), the remedy is the stage's lazy review — the
   adversary pass for plan and ship; a tripwire scan, adversary on a hit,
   for intent and spec — plus `--lazy`, not a human ask.
3. **Intent, spec, and ship approvals are human decisions** (unless the
   project's lazymode waives one — see the table below). Run
   `gates/approve.sh <stage> <artifact> --delegated` only after the human
   explicitly approves that artifact in chat ("approve", "looks right", or
   equivalent). Never approve on silence, a general "continue", or your own
   judgment. Never write to `.sdlc/approvals/` directly.
   Approvals are committed once, at ship, with the code (skills/5-ship commit
   discipline); git history is the audit trail. Approvals do not
   bind file bytes: editing an approved artifact does not close its gate, but
   a change that alters what the human approved deserves a fresh ask.

   **The plan gate is tiered.** Trip-wires: schema or data migration, data
   deletion or destructive backfill, public API or contract change,
   security-sensitive paths (auth, secrets, permissions), infra or config
   change, beyond-spec scope — anything build would execute irreversibly.
   plan.md records the verdict in its **Gate tier** section; the adversary
   re-checks every trip-wire, and an understated tier is a blocking finding.
   - No trip-wires and no blockers: run `gates/approve.sh plan <plan.md>
     --agent-adversary` (recorded as `mode: agent-adversary`), post the
     plan's Human summary as FYI, and continue to build.
   - Any trip-wire: a human gate, exactly like the others.

   **lazymode moves the human/auto line.** `lazymode: 0-4` in
   `.sdlc/config.md` names which gates stay HUMAN; init.sh seeds 1 and the
   agent asks the human which level they want at init. Each level keeps
   these gates human and auto-approves the rest with `gates/approve.sh
   <stage> <artifact> --lazy`:
   - 0 — intent, spec, ship human; plan tiered (exactly the rules above)
   - 1 (default) — intent, spec, ship human; plan always auto,
     trip-wires included
   - 2 — intent and ship human; spec and plan auto
   - 3 — intent human; spec, plan, and ship auto
   - 4 — no human gates; the whole loop runs autonomously
   lazymode waives the human decision, nothing else. **Plan and ship keep
   their full adversary review before `--lazy`** — plan authorizes what
   build executes irreversibly, and ship's diff review is the last look
   before the push; a keyword scan must never be the only reviewer there.
   For intent and spec (recoverable downstream), scan the artifact with
   `tools/tripwire.sh`: a clean scan approves directly; any hit requires the
   stage's adversary review to pass first (intent defines no adversary — a
   hit on intent.md gets a fresh-context adversary). Approvals are still
   recorded, and every auto-approved gate still posts its Human summary
   (and any trip-wire list) to the human as FYI. `approve.sh --lazy` refuses a stage the configured level keeps
   human, and any `lazymode:` value outside 0-4 counts as 0.
4. **Keep memory bounded.** At each stage start read `.sdlc/memory/INDEX.md`
   (lessons; 50 lines max) and `.sdlc/memory/DOMAIN.md` (terms, verified
   facts, constraints; 100 lines max), then open lesson files whose tags
   match the task. The dispatcher merges researchers' verified domain
   candidates into DOMAIN.md. Over a limit: split by subdomain and leave
   pointer lines. Record each new mistake in the skill 6 format.
5. **Fresh context for helpers.** Verification and adversarial review run in
   a fresh context — a subagent (pi: subagent tool; Claude Code: Task;
   Codex: spawn), else a new session given only the `roles/*.md` file and
   artifact paths — never in the context that authored the artifact. Give
   the verifier and adversary the strongest model available.

   **Stages are dispatches too.** When the harness has subagents, run each
   stage's work — spec draft, plan, build, evidence assembly — as a subagent
   given the stage skill path and the artifact paths. The orchestrator (the
   session talking to the human) routes, checks gates, and holds only
   summaries and decisions; raw exploration and file contents stay in the
   subagent and die with it. This is what keeps the loop cheap: one long
   orchestrator context that read everything defeats the point.

   **Roles are contracts, not headcount.** Independent probes (git history,
   live UI, API, DB) may run in parallel under one role: fewest read-only
   workers, one writer per checkout. The dispatcher resolves contradictions
   with primary evidence; a contradiction between probes is a finding.

   **Dispatch contract.** Every dispatch names: goal, exact input paths,
   write authority, verification commands from `.sdlc/config.md`, success
   criteria, output format, and stop rules (when to STOP and escalate
   instead of improvising).

   **Bulk rule.** Screenshots, probe logs, traces, and large command dumps
   go to the gitignored `.sdlc/work/<feature>/scratch/`; quote the deciding
   lines in the stage artifact and keep the file. Cleanup happens once, at
   the end of ship (skills/5-ship), never mid-loop.
6. **Proof over claims.** Every "done" claim carries command output, using
   the real commands in `.sdlc/config.md`.
7. **Artifacts live in the project repo** under `.sdlc/work/<feature>/`,
   committed with the code. The kit directory stays framework-only.
8. **Speak plainly.** Every report, gate request, and question starts with
   one short context paragraph (which stage, what happened before, what this
   message is for), uses short active sentences and the project's own
   vocabulary, and ends with the one decision or action the reader must
   take.

## Greenfield vs brownfield

Stage 1 records the classification in `intent.md`; downstream skills branch
on it. Brownfield adds a researcher pass over existing code, a regression
baseline captured before changes, and a "what stays untouched" spec section.

## Running beside other AGENTS.md files, skills, and agents

1. **Precedence.** Project rules control implementation (build commands,
   branch policy, style, commit format, tools); the kit controls stage
   order, gates, and memory. Only the human at a gate — or the lazymode
   level the human set in `.sdlc/config.md` — can waive a gate. On a
   genuine conflict, show both texts to the human — never resolve it
   silently.
2. **Existing knowledge wins.** DOMAIN.md points at existing glossaries,
   CONTEXT.md, ADRs, and domain docs (`- see docs/glossary.md
   [verified: exists]`) and holds only facts that exist nowhere else.
3. **Existing agents win.** Dispatch a matching local specialist (QA agent,
   code reviewer, DB reader) with the kit's role file as its task contract;
   spawn a generic worker only when no specialist fits. Fresh context and
   the dispatch contract still apply.
4. **Monorepos.** One `.sdlc/` per shipping unit — usually the service or
   package, not the repo root; a root `.sdlc/` only for cross-unit changes.
   intent.md names the owning unit.

## If your harness lacks a feature

- No subagents: open a fresh session or tab with the role file and artifact
  paths as the complete prompt; paste the report back.
- No file-read tool: paste file contents manually. The contract is the
  files, not the transport.
