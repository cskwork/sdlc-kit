# sdlc-kit agent routing contract

Anthropic's AI-Native SDLC playbook as plain Markdown and shell scripts. No
runtime hooks, no vendor-specific features.

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

**Two routes, one contract.** Every feature runs the FULL route unless it is
small and well understood, in which case it runs the COMPACT route. There is
no third shape: what skills/6-maintain used to call the "compressed loop" is
this same compact route.

- **Compact** — `intent.md` is the single work artifact and carries the files
  to change, the proof, the risk, and the delivery target (templates/intent.md).
  Flow: intent (gate) → build → ship (evidence + delivery) → close. No spec,
  no plan, and none is ever demanded of it. Ship keeps its full adversary
  review — the only review that diff gets. Criteria: skills/1-intent.
- **Full** — all six stages, for anything ambiguous, broad, or risky. Any
  doubt means full.

Stage 1 records the verdict as `- Track: compact` or `- Track: full`
(`micro` is the older spelling of `compact` and still parses everywhere).
The intent approval freezes it: `approve.sh` records the track, `status.sh`
flags a post-approval rewrite, and `approve.sh spec|plan` refuses a
compact-track slug outright. **A track upgrade revalidates the approvals it
changes**: rewrite the Track line to `full — upgraded from compact (<reason>)`
and re-approve intent before any spec or plan gate. Work started under the
older compressed loop (a `plan.md` with no `intent.md`) is not stranded and
its gates are not waived — status.sh prints the continuation path
(skills/6-maintain "Continuing older compressed work").

**Every feature ends in a terminal state**: `gates/close.sh <slug>
<shipped|abandoned|dead-end|handed-off> "reason"` after the human decides
(`--delegated` under rule 3). **`shipped` means delivered** — see rule 6:
close.sh re-checks the ship approval and reads `delivery.md`. close.sh then archives the feature: the dir and
its approval records move to `.sdlc/archive/<slug>/`, so `gates/status.sh`
stays scoped to open work (`--all` lists the newest 20 archived).
Abandoned or dead-end requires a lesson first:
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
   Compact-route features have no spec or plan: build checks the `intent` gate.
   Anything but a printed `GATE OPEN` — including errors and silence — is
   closed: STOP and tell the human exactly what to approve. At a gate
   lazymode waives (rule 3), run that stage's review of the affected code and
   behavior, then `approve.sh <that stage> … --lazy --review "<what you
   reviewed>"`, not a human ask.
   **What a gate binds**: the approval record names the canonical
   `.sdlc/work/<slug>/<artifact>` path, the artifact's sha256, and the
   digests of the upstream artifacts it was granted on top of — `origin.md`,
   the snapshot of the ticket or 기획서 the request came from, included
   whenever it exists (templates/origin.md). Editing the
   approved artifact, or materially editing an upstream one, closes the gate
   with the exact re-approval command — a downstream gate never outlives the
   text it was granted for. The digest is CHANGE DETECTION, not
   authentication: it proves the bytes are the ones approved, never who
   approved them. Records written by an older kit carry no digest and fail
   closed, saying so.
3. **Intent, spec, and ship approvals are human decisions** (unless the
   project's lazymode waives one — see the lazymode levels below). On the
   compact route there is no spec approval at all: the human authorized that
   by approving the intent.md that carries the `Track: compact` verdict. Run
   `gates/approve.sh <stage> <artifact> --delegated` only after the human
   explicitly approves that artifact in chat ("approve", "looks right", or
   equivalent). Never approve on silence, a general "continue", or your own
   judgment. Never write to `.sdlc/approvals/` directly.
   Approval records are gitignored (init.sh): they live in the working copy,
   not in git history, so `.sdlc/approvals/` and its `.approval.history`
   files ARE the audit trail — a fresh clone mid-feature has none and must
   re-gate. Approvals bind a path and content (rule 2): a rewritten artifact
   needs a new approval (build-time procedure: skills/4-build deviations).
   Re-gates are capped:
   two per stage, per feature, at any point in the loop — a third means
   intent got the facts wrong (escalation: skills/4-build "Re-gate cap").

   **Autonomy is not authority.** Two separate questions, never merged:
   - *Who decides?* — lazymode. It moves human checkpoints to the agent.
   - *May this be done at all?* — authorization. Risky operations need the
     human's prior word, whatever the lazymode: data loss or destructive
     backfill, public API or contract change, security-sensitive paths
     (auth, secrets, permissions), schema or data migration, and external
     delivery (push to a shared branch, deploy, anything leaving this repo).
   Inside a scope the human already authorized, do not ask again — that is
   the point of the authorization. A red flag OUTSIDE that scope stops the
   loop and goes to the human as a decision, at every lazymode level.
   `approve.sh --lazy` records both: `--review "<what you actually reviewed>"`
   is mandatory, and `--risk-authorized "<the human's words>"` is required
   when the artifact shows risky work. **`tools/tripwire.sh` is supplemental**:
   it scans English keywords in one file, so a hit can ADD the authorization
   requirement, but a clean scan clears nothing and authorizes nothing. The
   review that matters is a read of the affected code and behavior.

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
   <stage> <artifact> --lazy --review "<what you reviewed>"`:
   - 0 — intent, spec, ship human; plan tiered (exactly the rules above)
   - 1 (default) — intent, spec, ship human; plan always auto,
     trip-wires included
   - 2 — intent and ship human; spec and plan auto
   - 3 — intent human; spec, plan, and ship auto
   - 4 — no human gates; the whole loop runs autonomously
   The `lazymode:` line itself is a human decision: edit it only on
   explicit instruction, and commit config.md so the level is audit-trailed.
   lazymode waives the human decision, nothing else. **Every `--lazy`
   approval still carries a real review of the affected code and behavior**,
   recorded in `--review`: plan authorizes what build executes irreversibly,
   ship's diff review is the last look before delivery, and intent/spec are
   reviewed for what the change actually does, not for which words it uses.
   Run `tools/tripwire.sh` as one input among others; a hit means the
   stage's adversary review runs and the risk authorization must exist
   (intent defines no adversary — a hit on intent.md gets a fresh-context
   adversary).
   **A waived gate is not a stop.** A stage skill's "tell the human, then
   STOP" applies to the gates the project's lazymode keeps HUMAN. Where the
   level waives one, the agent runs that stage's review, records the approval
   with `--lazy --review`, posts the summary as FYI, and CONTINUES — it does
   not ask, and it does not wait. Exactly four things still stop a waived
   loop, at every level including 4: work outside the authorized scope, an
   unresolved MATERIAL question in intent.md, a blocker surviving its round
   cap, and external delivery beyond a review branch (merge, deploy). Ask each
   of them ONCE, as one concrete decision; a question already answered for
   this scope is not asked again.

   **The full-auto intent contract.** An unattended run may act on an
   `intent.md` only when it states an actionable outcome, its scope and
   non-goals, acceptance criteria, labelled evidence, a `Scope authorization`
   line (the human's words), and a `## Material questions` section with
   nothing unresolved in it. Known facts from the ticket, the code, and
   DOMAIN.md come first; what remains are the questions. A question is
   MATERIAL when a wrong answer would change what gets built, break something,
   or exceed the authorized scope — it goes to the human, and is never guessed
   away to make progress. Optional uncertainty is decided from evidence or
   carried as `[assumed: why]` under `## Open questions`, and blocks nothing.
   Missing required evidence or an unauthorized risk blocks the same way.
   `tools/auto.sh intent-check <slug>` reports the verdict.

   **A blocker surviving its round cap blocks `--lazy` at every stage**:
   the gate reverts to a human ask; at lazymode 4 the loop stops.
   Approvals are still recorded, and every auto-approved gate still posts its
   Human summary (and any trip-wire list) to the human as FYI. `approve.sh
   --lazy` refuses a stage the configured level keeps human, and any
   `lazymode:` value outside 0-4 counts as 0.
4. **Keep memory bounded.** At each stage start read
   `.sdlc/memory/POLICY.md` (human-declared hard rules),
   `.sdlc/memory/INDEX.md` (lessons; 50 lines max), `.sdlc/memory/DOMAIN.md`
   (terms, verified facts, constraints; 100 lines max), and the feature's
   own `harvest.md` if present, then open lesson files whose tags match the
   task. DOMAIN over its limit: split by subdomain, leave pointer lines.
   INDEX over its limit: merge near-duplicates, drop superseded entries,
   remove entries already promoted (skills/6-maintain).
   **INDEX.md, DOMAIN.md, and lessons/ have one writer: the close step.**
   Mid-loop, stages and researchers append candidates to
   `.sdlc/work/<slug>/harvest.md` (templates/harvest.md), never to the
   shared files. At close, merge harvest into lessons/INDEX/DOMAIN and
   delete it; `close.sh` blocks while harvest.md exists.
   **Recency wins on merge, three guards.** A contradicting candidate
   replaces the old entry with a fresh `[verified: how — YYYY-MM-DD]`;
   date every fact. Guards: weaker evidence never supersedes stronger (a
   code-read vs a production capture goes to the human); both-true-in-
   different-scopes gets qualified, not replaced; a `supersedes:` target
   already rewritten by a parallel close is reconciled by evidence, not
   appended. Human-stated lines are never deleted on recency alone — ask.
   **POLICY.md is written only on the human's word** (the one shared-memory
   file outside the close-writer rule). When the human states a hard rule in
   chat, transcribe it with the date and their words; never add, soften, or
   remove a rule on your own judgment. A mid-loop transcription commits
   with the next close. The adversary treats a violation as blocking.
   The archive is bounded the same way: `status.sh --all` and `stats.sh`
   default to the newest 20 closed features. Never read the whole
   `.sdlc/archive/` into a working context — answer archive questions with
   a targeted `ls`, `grep`, or a single slug lookup.
5. **Fresh context for helpers.** Verification and adversarial review run in
   a fresh context — a subagent (pi: subagent tool; Claude Code: Task;
   Codex: spawn), else a new session given only the `roles/*.md` file and
   artifact paths — never in the context that authored the artifact. Give
   the verifier and adversary the strongest model available.

   **One delegate is the default.** A single implementer carries the loop.
   Do NOT dispatch a subagent per stage as a matter of course — the handoffs
   cost more than they save on ordinary work. Scope a dispatch when it
   genuinely helps: a large read-only exploration whose raw output should not
   enter the main context, independent probes that can run in parallel, or a
   sub-task with a crisp contract. Verification and adversarial review are
   the exception that always stands: they run in a fresh context, because
   the author cannot review their own work. If the harness cannot give them
   one, say so in the artifact as an explicit gap ("no independent
   verification available: <reason>") instead of self-reviewing quietly.

   **Caps survive dispatch.** Write each count the moment it increments:
   deviations, re-gates, fix-loop rounds → deviations.md (template); ship
   adversary rounds → evidence.md; map sessions → map.md's Session log;
   evidence requests → one intent.md line each; re-approvals →
   `.approval.history` (approve.sh). Counters live on disk, not in context;
   grill and fan-out caps are per-session and do not persist.

   **Roles are contracts, not headcount.** Independent probes (git history,
   live UI, API, DB) may run in parallel under one role: fewest read-only
   workers, one writer per checkout. The dispatcher resolves contradictions
   with primary evidence; a contradiction between probes is a finding. At
   most two fan-out rounds per question — after that the contradiction goes
   to the human, not to more probes.

   **Dispatch contract.** Every dispatch names: goal, exact input paths,
   write authority, verification commands from `.sdlc/config.md`, success
   criteria, output format, and stop rules (when to STOP and escalate
   instead of improvising).

   **Bulk rule.** Screenshots, probe logs, traces, and large command dumps
   go to the gitignored `.sdlc/work/<feature>/scratch/`; quote the deciding
   lines in the stage artifact and keep the file. A bare `scratch/…` citation
   does not survive a fresh clone — cite it only beside the quoted lines, or
   point at a durable home (the PR body, an artifact URL). Scratch survives the push:
   it is pruned once, at close, and anything evidence.md, delivery.md, or a
   lesson cites is KEPT and named as load-bearing there. Nothing is deleted
   mid-loop, and nothing referenced is deleted at all.
6. **Proof over claims.** Every "done" claim carries command output, using
   the real commands in `.sdlc/config.md`.

   **Verification runs the real thing, through three lenses.** Before a
   feature ships, a fresh-context verifier (roles/verifier.md) checks it three
   ways, in parallel. **E2E**: the changed behavior exercised through the
   interface a user or caller actually meets, with the project's own commands
   (`.sdlc/config.md`: `e2e:`, `qa:`, `run:`), scoped to the change — never
   the whole product suite as a ritual. **Side effects**: what else changed
   between AS-IS and TO-BE — the baseline, the untouched items, and the
   consistency of every data shape the change writes or reads across its other
   producers and consumers. **Intent match**: the build read back against the
   origin of the request — `origin.md`, the snapshot the intent gate bound,
   plus the live ticket or 기획서 when reachable — per intent.md O-item,
   naming what is covered, missing, and beyond. Each check records command or tool,
   environment, scenario, and the observed result. **No environment to run it
   in = NOT VERIFIED**: say what is missing, in evidence.md. A passing unit
   suite is never a silent substitute, and a delivery over a known gap is
   allowed only when the human accepts that gap explicitly. A finding from any
   lens enters the build fix loop (skills/4-build): three rounds, then the
   human — `tools/auto.sh` reads the round lines in deviations.md and reports
   an exhausted loop as `fixloop.exhausted`, needs-human at every lazymode.

   **A receipt makes a missing proof detectable** (optional, and the loop
   works without it). A project that fills `.sdlc/verify.md`
   (templates/verify.md) maps each requirement to its own real command, plus
   the launch, doctor, and cleanup commands around them; `tools/verify.sh run
   <slug>` executes EVERY one of them, bounded and isolated, and records a
   receipt bound to the source snapshot before and after the run, the recipe,
   and each command's and output's digest. Editing the code, the commands, or
   the recipe makes the receipt `stale`; a cited log that is missing or was
   edited, or checks that do not add up, make it `invalid`. Under
   `profile: strict` a feature is not review-ready without a passing `runtime`
   or `e2e` check against a runtime that run actually launched, and a doctor
   that never comes up is NOT VERIFIED — never "the unit suite is green".
   A receipt is CHANGE DETECTION, not authentication: it makes "this never
   ran" and "this was edited afterwards" visible, and says nothing about who
   produced it. It does not replace the independent fresh-context verifier
   (rule 5).

   **"Shipped" means delivered.** The ship approval is a decision to
   deliver; it is not a delivery. A feature closes as `shipped` only when
   the agreed target — local implementation, PR, or deploy — is proven to
   have happened, in `.sdlc/work/<slug>/delivery.md` (templates/delivery.md):
   target, the source identity that was reviewed, the command or project
   tool actually run, and its verbatim deciding output. Remote facts (PR
   state, deploy result) are established with the project's own tools, never
   by asserting them in prose; a `pr` or `deploy` delivery must name the
   delivered commit, and that commit must CONTAIN the reviewed source —
   close.sh compares its tree against the reviewed snapshot, so a commit that
   merely exists is refused. Local work needs no production step — `local` is
   a first-class target. close.sh re-checks the ship approval (evidence
   unchanged, source unchanged since the review) and refuses an absent,
   mismatching, or unconfirmed delivery.
   **What the ship approval binds is the project's whole source snapshot** as
   the review saw it: every tracked file plus every untracked file git does
   not ignore, minus `.sdlc/`, by path, content, and executable bit. Staging
   or committing those exact bytes keeps the binding valid — work committed
   BEFORE the review is bound too. An edit, a new file, a deletion, a chmod,
   or a symlink swap afterwards breaks it, including in a file the review did
   not name: a source change nobody reviewed never closes silently. check-gate,
   status, and close say the same thing in the same words, and name the files
   that changed. Approvals written by an older kit bound only the uncommitted
   diff and fail closed, saying so. (Submodule contents are not bound.) A
   path name git C-quotes — tab, newline, double quote, or backslash in the
   name — cannot be bound: approve.sh refuses it by name, and one that
   appears after the review closes the gate as an invalid source.

   **Review-ready is not merged, and not deployed.** A loop's own exit is a
   FEATURE BRANCH pushed for a human to review: `tools/handoff.sh push <slug>
   --authorized "<the human's words>"` refuses without that authorization,
   refuses protected or shared branches, never force-pushes, refuses a commit
   whose tree does not CONTAIN the reviewed source, and repeats no push that
   already happened. `tools/handoff.sh check <slug>` establishes the remote
   branch's SHA with git, never in prose. Merging that branch or deploying it
   is a separate human approval, recorded as `Authorized-by:` in delivery.md at
   every lazymode level. delivery.md's `Remote`, `Branch`, `Handoff` and
   `Authorized-by` lines are optional and backward-compatible: an older record
   closes exactly as it did.

   **A bug fix carries its own proof chain** (skills/6-maintain): the
   failure observed before the fix, the causal mechanism, the SAME
   reproduction passing after, and the adjacent flows that share the changed
   code. An intermittent defect may substitute logs, traces, or an isolated
   deterministic reproduction, with its limitation stated. Without that
   chain the work is a diagnosis or an instrumentation change — say so; do
   not call it a confirmed fix.
7. **Artifacts live in the project repo** under `.sdlc/work/<feature>/`
   while open and `.sdlc/archive/<feature>/` after close. Git keeps the
   durable record — `origin.md`, `intent.md`, `spec.md`, `plan.md`, `map.md`,
   `evidence.md`, `delivery.md`, `CLOSED`, `memory/`, `config.md`: the
   decisions and the final proof, readable a year later without the working
   copy. Gitignored working residue stays local (`approvals/`,
   `baseline.txt`, `deviations.md`, `harvest.md`, `progress.md`,
   `scratch/`). Bulk evidence lives in `scratch/`; evidence.md quotes the
   deciding lines and cites the file, so the durable record stays small. A
   PR body that carries the same evidence is an acceptable durable home —
   link it from evidence.md. The kit directory stays framework-only.
8. **Speak plainly.** Every report, gate request, and question starts with
   one short context paragraph (which stage, what happened before, what this
   message is for), uses short active sentences and the project's own
   vocabulary, and ends with the one decision or action the reader must
   take.
9. **Heartbeat.** `.sdlc/work/<slug>/progress.md` holds exactly one line —
   `<stage>[ n/m] · <what is happening, ≤10 words> · <ISO timestamp>` —
   overwritten (never appended) on stage entry and whenever the sub-task
   changes; before a dispatch, the orchestrator writes the dispatch as the
   line. A sub-task that runs long refreshes the line at each natural
   checkpoint (a command finished, a file edited) even when the text does
   not change, so a stale heartbeat means a dead loop, not a slow step.
   It is a live signal for the human, not a record: gitignored
   (init.sh), never quoted into artifacts, and `status.sh` shows it with
   its age so silence and a dead loop look different. History stays where
   it already lives (deviations.md, evidence.md, harvest.md).

## Driving the loop from a host (no daemon, no scheduler)

`gates/status.sh --json` (= `tools/auto.sh status --json`, schema
`sdlc-kit/auto-status@1`) is the machine view: per feature the stage, a
`status` of `ready | needs-human | blocked | complete`, the next action, the
blockers, the source identity, the verification and delivery state, and the
`exit_condition` (`review-ready` ≠ `deployed`). `tools/auto.sh next <slug>`
prints one line and exits 0 / 10 / 20 / 30 for those four states. Every verdict
comes from `gates/_common.sh`, so the machine view is never more permissive
than the gates.

These scripts REPORT and RECORD. They run no model and perform no stage: a
`ready` status means the next action is one the project's lazymode lets an
agent take, and the agent still takes it under the stage skill. The drive /
resume procedure, the verification recipe, the handoff boundary, the checkpoint
and its retry classes are documented in `docs/automation.md`.

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
