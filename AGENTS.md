# sdlc-kit agent routing contract

Anthropic's AI-Native SDLC playbook as plain Markdown and shell scripts. No
runtime hooks, no vendor-specific features. The scripts enforce the mechanics
and, when they refuse, print the reason and the fix; this file states only
what an agent must decide or do.

## The loop

Six stages, one artifact each. An approval recorded by `gates/approve.sh`
opens the next stage. Intent, spec, and ship approvals are human decisions
unless the project's lazymode waives them; the plan gate is tiered (rule
3). A production issue in stage 6 writes the next `intent.md` and restarts
the loop.

| # | Stage    | Read this skill first              | Artifact (in project `.sdlc/work/<feature>/`) | Gate to pass BEFORE starting |
|---|----------|------------------------------------|-----------------------------------------------|------------------------------|
| 1 | Intent   | `skills/1-intent/SKILL.md`         | `intent.md`                                   | none; proceed               |
| 2 | Spec     | `skills/2-spec/SKILL.md`           | `spec.md`                                     | `intent`                     |
| 3 | Plan     | `skills/3-plan/SKILL.md`           | `plan.md`                                     | `spec`                       |
| 4 | Build    | `skills/4-build/SKILL.md`          | code + tests                                  | `plan` (tiered, rule 3)      |
| 5 | Ship     | `skills/5-ship/SKILL.md`           | `evidence.md` + `delivery.md`                 | none; build done and checks pass |
| 6 | Maintain | `skills/6-maintain/SKILL.md`       | new `intent.md` + lesson                      | none; triggered by incident |

Stage names double as gate names: `gates/check-gate.sh spec .sdlc/work/<feature>/spec.md`.

**Two routes, one contract.** There is no third shape.

- **Compact** — small and well understood. `intent.md` is the single work
  artifact and carries the files to change, the proof, the risk, and the
  delivery target (templates/intent.md). Flow: intent (gate) → build → ship
  → close. No spec, no plan, and none is ever demanded of it. Ship keeps its
  full adversary review — the only review that diff gets. Criteria:
  skills/1-intent.
- **Full** — all six stages, for anything ambiguous, broad, or risky. Any
  doubt means full.

intent.md's `- Track:` line records the route (`micro` is the older spelling
of compact) and the intent approval freezes it. **A track upgrade
revalidates the approvals it changes**: rewrite the line to `full — upgraded
from compact (<reason>)` and re-approve intent before any spec or plan gate.
Older compressed work (a `plan.md` with no `intent.md`) keeps its gates;
`status.sh` prints its continuation path (skills/6-maintain).

**Every feature ends in a terminal state**: `gates/close.sh <slug>
<shipped|abandoned|dead-end|handed-off> "reason"` after the human decides
(`--delegated` under rule 3). `shipped` needs a confirmed delivery (rule 6).
Abandoned or dead-end needs a lesson first — what was tried, why it failed,
what would unblock it (lazymode ≥3: the close reason is the record).
Handed-off needs the external ticket/PR key or URL in the reason. close.sh
archives the feature to `.sdlc/archive/<slug>/`.

## Hard rules (every stage, every harness)

1. **Read the stage skill file COMPLETELY before acting.** Resolve paths
   relative to this kit's directory. On Windows run `gates/*.sh` and
   `tools/*.sh` through Git Bash or WSL; `.sdlc/config.md` records a native
   path as `kit_windows:` when one is needed.
2. **Check the gate first** for stages 2-4: `gates/check-gate.sh
   <prev-stage> <artifact>` from the project root (compact route: build
   checks the `intent` gate). Anything but a printed `GATE OPEN` — including
   errors and silence — is closed: STOP and tell the human exactly what to
   approve. Where lazymode waives that gate, run the stage's review instead
   and approve with `--lazy` (rule 3).
   **What a gate binds**: the artifact's content and the upstream artifacts
   it was granted on — `origin.md`, the snapshot of the ticket or 기획서,
   included (templates/origin.md). Editing any of them closes the gate and
   the script prints the re-approval command; a downstream gate never
   outlives the text it was granted for. The digest is CHANGE DETECTION, not
   authentication.
3. **Intent, spec, and ship approvals are human decisions** unless the
   project's lazymode waives one (compact route: no spec approval — the
   human approved the intent that chose compact). Run `gates/approve.sh
   <stage> <artifact> --delegated` only after the human explicitly approves
   that artifact in chat ("approve", "looks right", or equivalent). Never
   approve on silence, a general "continue", or your own judgment. Never
   write to `.sdlc/approvals/` directly. Those records are the audit trail;
   they are gitignored, so a fresh clone mid-feature must re-gate. Re-gates
   are capped at two per stage, per feature — a third means intent got the
   facts wrong (skills/4-build "Re-gate cap").

   **Autonomy is not authority.** Two separate questions, never merged:
   - *Who decides?* — lazymode. It moves human checkpoints to the agent.
   - *May this be done at all?* — authorization. Risky operations need the
     human's prior word, whatever the lazymode: data loss or destructive
     backfill, public API or contract change, security-sensitive paths
     (auth, secrets, permissions), schema or data migration, and external
     delivery (push to a shared branch, deploy, anything leaving this repo).
   Inside a scope the human already authorized, do not ask again. A red flag
   OUTSIDE that scope stops the loop and goes to the human as a decision, at
   every lazymode level. `approve.sh --lazy` records both: `--review "<what
   you actually reviewed>"` is mandatory, and `--risk-authorized "<the
   human's words>"` is required when the artifact shows risky work.
   `tools/tripwire.sh` scans English keywords in one file: a hit ADDS the
   authorization requirement and a fresh-context adversary review; a clean
   scan clears nothing. The review that matters is a read of the affected
   code and behavior.

   **The plan gate is tiered.** Trip-wires: schema or data migration, data
   deletion or destructive backfill, public API or contract change,
   security-sensitive paths, infra or config change, beyond-spec scope —
   anything build would execute irreversibly. plan.md records the verdict
   in its **Gate tier** section; the adversary re-checks every trip-wire,
   and an understated tier is a blocking finding. No trip-wires and no
   blockers → `approve.sh plan <plan.md> --agent-adversary`, post the
   plan's Human summary as FYI, continue. Any trip-wire → a human gate.

   **lazymode moves the human/auto line.** `lazymode: 0-4` in
   `.sdlc/config.md` names which gates stay HUMAN (init.sh seeds 1; ask the
   human at init); the rest auto-approve with `approve.sh <stage> <artifact>
   --lazy --review "<what you reviewed>"`:
   - 0 — intent, spec, ship human; plan tiered (exactly the rules above)
   - 1 (default) — intent, spec, ship human; plan always auto, trip-wires included
   - 2 — intent and ship human; spec and plan auto
   - 3 — intent human; spec, plan, and ship auto
   - 4 — no human gates; the whole loop runs autonomously
   The `lazymode:` line is itself a human decision: edit it only on explicit
   instruction. lazymode waives the decision, never the review: every
   `--lazy` approval carries a real review of the affected code and
   behavior. `approve.sh --lazy` refuses a stage the level keeps human, and
   any value outside 0-4 counts as 0.

   **A waived gate is not a stop.** "Tell the human, then STOP" applies to
   the gates the level keeps HUMAN. At a waived one the agent reviews,
   approves with `--lazy --review`, posts the summary (and any trip-wire
   list) as FYI, and CONTINUES. Exactly four things stop a waived loop, at
   every level including 4: work outside the authorized scope, an
   unresolved MATERIAL question in intent.md, a blocker surviving its round
   cap, and external delivery beyond a review branch (merge, deploy). Ask
   each ONCE, as one concrete decision; a question already answered for
   this scope is not asked again.

   **3a. The full-auto intent contract.** An unattended run may act on an
   `intent.md` only when it states an actionable outcome, scope and
   non-goals, acceptance criteria, labelled evidence, a `Scope
   authorization` line (the human's words), and no unresolved MATERIAL
   question — one whose wrong answer would change what gets built, break
   something, or exceed the authorized scope. Those go to the human and are
   never guessed away; optional uncertainty is carried as `[assumed: why]`
   and blocks nothing. `tools/auto.sh intent-check <slug>` reports the
   verdict (section rules: templates/intent.md; full text: docs/automation.md §3).
4. **Keep memory bounded.** At each stage start read
   `.sdlc/memory/POLICY.md` (human-declared hard rules),
   `.sdlc/memory/INDEX.md` (lessons; 50 lines max), `.sdlc/memory/DOMAIN.md`
   (terms, verified facts, constraints; 100 lines max), and the feature's
   own `harvest.md` if present, then open lesson files whose tags match the
   task. Stage skills do not repeat this. DOMAIN over its limit: split by
   subdomain, leave pointer lines. INDEX over its limit: merge
   near-duplicates, drop superseded entries, replace promoted ones
   (skills/6-maintain).
   **INDEX.md, DOMAIN.md, and lessons/ have one writer: the close step.**
   Mid-loop, stages and researchers append candidates — one line each — to
   `.sdlc/work/<slug>/harvest.md` (templates/harvest.md). At close, merge
   harvest into lessons/INDEX/DOMAIN and delete it; `close.sh` blocks while
   it exists. A feature idle 30 days or more may have its harvest merged the
   same way WITHOUT closing — one merge at a time, in the owning checkout
   (`tools/kb.sh harvest` lists them); nothing in `kb.sh` writes `memory/`.
   **Recency wins on merge, three guards.** A contradicting candidate
   replaces the old entry with a fresh `[verified: how — YYYY-MM-DD]`; date
   every fact. Weaker evidence never supersedes stronger (a code-read vs a
   production capture goes to the human); both-true-in-different-scopes gets
   qualified, not replaced; a `supersedes:` target already rewritten by a
   parallel close is reconciled by evidence. Human-stated lines are never
   deleted on recency alone — ask.
   **POLICY.md is written only on the human's word**: transcribe a hard rule
   they state in chat with the date and their words; never add, soften, or
   remove one on your own judgment. The adversary treats a violation as
   blocking.
   Never read the whole `.sdlc/archive/` into context: use `tools/kb.sh
   search "<text>"` / `show <slug>` (rule 7), a targeted `ls`/`grep`, or a
   single slug lookup.
5. **Fresh context for helpers.** Verification and adversarial review run in
   a fresh context — a subagent (pi: subagent tool; Claude Code: Task;
   Codex: spawn), else a new session given only the `roles/*.md` file and
   artifact paths — never in the context that authored the artifact. Give
   them the strongest model available. A harness that cannot provide one
   gets an explicit gap line in the artifact ("no independent verification
   available: <reason>"), never a quiet self-review.

   **One delegate is the default.** A single implementer carries the loop;
   do not dispatch a subagent per stage as a matter of course. Dispatch when
   it buys something concrete: a large read-only exploration, independent
   probes that can run in parallel, or a sub-task with a crisp contract.

   **Caps survive dispatch.** Write each count the moment it increments:
   deviations, re-gates, fix-loop rounds → deviations.md; ship adversary
   rounds → evidence.md; map sessions → map.md's Session log; evidence
   requests → one intent.md line each; re-approvals → `.approval.history`
   (approve.sh). Grill and fan-out caps are per-session and do not persist.

   **Roles are contracts, not headcount.** Independent probes (git history,
   live UI, API, DB) may run in parallel under one role: fewest read-only
   workers, one writer per checkout. A contradiction between probes is a
   finding, resolved with primary evidence; at most two fan-out rounds per
   question, then it goes to the human.

   **Dispatch contract.** Every dispatch names: goal, exact input paths,
   write authority, verification commands from `.sdlc/config.md`, success
   criteria, output format, and stop rules (when to STOP and escalate
   instead of improvising).

   **Bulk rule.** Screenshots, probe logs, traces, and large command dumps
   go to `.sdlc/work/<feature>/scratch/`; quote the deciding lines in the
   stage artifact beside the citation (a bare `scratch/…` path does not
   survive a fresh clone; a PR body or artifact URL does). Nothing is
   deleted mid-loop; close prunes scratch and keeps what a record cites.
6. **Proof over claims.** Every "done" claim carries command output, using
   the real commands in `.sdlc/config.md`.

   **Verification runs the real thing, through three lenses** — E2E, Side
   effects, Intent match — each in its own fresh context, in parallel
   (roles/verifier.md defines them). **No environment to run it in = NOT
   VERIFIED**: say what is missing, in evidence.md. A passing unit suite is
   never a silent substitute, and a delivery over a known gap is allowed
   only when the human accepts that gap explicitly. A finding from any lens
   enters the build fix loop (skills/4-build): three rounds, then the human
   at every lazymode (`tools/auto.sh` reports `fixloop.exhausted`).
   A project that fills `.sdlc/verify.md` (templates/verify.md) gets a
   receipt from `tools/verify.sh run <slug>` that makes "this never ran" and
   "this was edited afterwards" detectable (docs/automation.md §4). It does
   not replace the fresh-context verifier.

   **A bug fix carries its own proof chain**: the failure observed before
   the fix, the causal mechanism, the SAME reproduction passing after, and
   the adjacent flows that share the changed code. **The reproduction is a
   test by default**: an automated test at the lowest level that reaches the
   defect — unit, integration, API, or browser — that FAILS on the pre-fix
   code for the reported reason, passes after, and stays in the suite as the
   regression guard. Manual steps, logs, or traces stand in only when no
   test can reach the defect: say why. An intermittent defect may use logs,
   traces, or an isolated deterministic reproduction, with its limitation
   stated. Without the chain the work is a diagnosis or an instrumentation
   change — say so; never call it a confirmed fix.

   **"Shipped" means delivered.** The ship approval is a decision to
   deliver, not a delivery. A feature closes as `shipped` only when the
   agreed target — `local`, `pr`, or `deploy` — is proven in
   `.sdlc/work/<slug>/delivery.md` (templates/delivery.md): target, the
   delivered source, the command or project tool actually run, and its
   verbatim deciding output. Remote facts (PR state, deploy result) come
   from the project's own tools, never from prose. The ship approval binds
   the project's whole source snapshot as the review saw it; any change
   afterwards closes the gate, and check-gate/status/close name the files.
   **Review-ready is not merged, and not deployed.** A loop's own exit is a
   feature branch pushed for review (`tools/handoff.sh push <slug>
   --authorized "<the human's words>"`); merging or deploying it is a
   separate human approval, recorded as `Authorized-by:` in delivery.md at
   every lazymode (skills/5-ship).
7. **Artifacts live in the record store** under `.sdlc/work/<feature>/`
   while open and `.sdlc/archive/<feature>/` after close. The store is
   gitignored in full (`/.sdlc`): the records are the project's knowledge,
   not its source, and a clone does not carry them. They stay where they
   are written — the working copy, or the folder the human chose with
   `init.sh <dir> --area <folder>`. A store another checkout owns is
   refused, never shared. **Backing the store up is the human's, not
   git's.** The durable record is `origin.md`, `intent.md`, `spec.md`,
   `plan.md`, `map.md`, `evidence.md`, `delivery.md`, `CLOSED`, `memory/`,
   and `config.md`; working residue (`approvals/`, `baseline.txt`,
   `deviations.md`, `harvest.md`, `progress.md`, `scratch/`) is never quoted
   into an artifact. The kit directory stays framework-only.
   **Records are read back, not just written**, through `tools/kb.sh`:
   `search "<text>"` (bounded, literal, open and closed features plus
   memory), `show <slug>` (summary.md first, then goal, delivery, lessons,
   paths), `harvest` (unmerged candidates), `index` (contents page).
   `--area <folder>` covers every store in that folder, including features
   whose checkout is gone. Exit 0 found · 1 nothing · 2 usage/refusal.
8. **Speak plainly.** Every report, gate request, and question starts with
   one short context paragraph (which stage, what happened before, what this
   message is for), uses short active sentences and the project's own
   vocabulary, and ends with the one decision or action the reader must
   take.
9. **Heartbeat.** `.sdlc/work/<slug>/progress.md` holds exactly one line —
   `<stage>[ n/m] · <what is happening, ≤10 words> · <ISO timestamp>` —
   overwritten, never appended: as soon as the slug dir exists, on stage
   entry, at every sub-task change, and before every dispatch. `<stage>` is
   the stage name (`intent`, `spec`, `plan`, `build`, `ship`, `maintain`);
   build adds `n/m` over plan.md's Order of work. A long sub-task refreshes
   the line at each natural checkpoint even when the text does not change,
   so a stale heartbeat means a dead loop, not a slow step. It is a live
   signal (`status.sh` shows its age), never quoted into artifacts. Stage
   skills do not repeat this rule.

## Driving the loop from a host (no daemon, no scheduler)

`gates/status.sh --json` (= `tools/auto.sh status --json`) is the machine
view and `tools/auto.sh next <slug>` exits 0 ready · 10 needs-human · 20
blocked · 30 complete. Every verdict comes from `gates/_common.sh`, so the
machine view is never more permissive than the gates. These scripts REPORT
and RECORD; they run no model and perform no stage. Drive/resume procedure,
verification recipe, and handoff boundary: `docs/automation.md`.

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
3. **Existing agents win.** When `.sdlc/config.md` names a project agent or
   skill for a role (`researcher:`, `verifier:`, `adversary:`), dispatch
   that one with the kit's role file as its task contract; otherwise pick a
   matching local specialist (QA agent, debugger, code reviewer, DB reader)
   and spawn a generic worker only when none fits. Fresh context and the
   dispatch contract still apply.
4. **Monorepos.** One `.sdlc/` per shipping unit — usually the service or
   package, not the repo root; a root `.sdlc/` only for cross-unit changes.
   intent.md names the owning unit.

## If your harness lacks a feature

- No subagents: open a fresh session or tab with the role file and artifact
  paths as the complete prompt; paste the report back.
- No file-read tool: paste file contents manually. The contract is the
  files, not the transport.
