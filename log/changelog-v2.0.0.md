# v2.0.0 — four phases, one script, routed proof

The kit is rebuilt around four phases — Intent, Plan, Build, Evidence — with
one script. It reads about a sixth of the words it used to, explores before
any code is written, and decides from scored evidence where failed work goes
next. This is a new contract: v0 records stay readable but cannot continue
under v2.

## Why

- **The old loop cost more than it caught on small work.** In the PR #26
  comparison, two small tasks took a median 85 s without the kit and 842–916 s
  with it, and every arm passed all 48 product assertions. Complex work was not
  measured.
- **Features did not reach the end.** Four local stores held 19 open features
  and no closed one; several could not close over formatting (a backtick around
  `local` in a delivery record). `gates/status.sh` took over 30 s on a large
  monorepo.
- **Agents wrote their own files anyway** (`spec-review-1.md`, `callers.md`,
  `research.md`): exploration needed a home, not more templates.

## Changes

- **Four phases.** Intent (what was asked, understood, and risked) →
  Plan (parallel read-only scouts write `refs/`; one `PLAN.md` holds AS-IS →
  TO-BE, side effects, risk flags and the QA scenarios) → Build (the smallest
  complete change, committed, then a separate adversarial reviewer; three
  FAILs stop the loop) → Evidence (fresh QA runs every scenario as its persona
  through the real interface). Spec, ship and maintain fold into these; the
  three verification lenses become planned scenarios.
- **Scored, routed evidence.** `sdlc.sh score` validates `evidence.md` against
  `PLAN.md` (every planned and earlier-scored scenario present, a log behind
  every PASS and FAIL, the reviewed commit checked out and clean) and routes: a
  plan-caused failure or the same code failure twice → Plan; every must
  scenario passing and ≥ 95% overall → deliver; scenarios that could not run
  blocking delivery → the human; otherwise → Build. Three returns of each kind,
  then the human. BLOCKED counts as failed; only the human can remove a
  scenario or drop its must.
- **Stops hold.** Three review FAILs, a capped return or a human route stop
  the loop until `sdlc.sh approve plan --human`; editing PLAN.md does not
  reopen it.
- **One script.** `sdlc.sh` (init, new, status, next, check, approve, review,
  score, close) replaces `init.sh`, `gates/` and `tools/`. Gates bind
  `intent.md` and `PLAN.md` by hash. A review PASS needs a new round in
  `review.md` and binds to the HEAD of every repository under the project
  root; a Commit in a repository the review did not see is refused.
  `close shipped` re-checks the gates, refuses a delivered tree that differs
  from the verified commit, and needs `Authorized: yes …` for pr or deploy (a
  target other than intent.md's needs its own). `init` keeps `.sdlc/` out of
  git through `.git/info/exclude` and changes no tracked file.
- **Three roles** — scout, reviewer, QA — replace researcher, verifier and
  adversary. Build carries the ponytail rules (smallest complete change)
  inline, so no other skill is needed.
- **Smaller everything.** Prompts and templates: 3,922 words (was about
  23,700); the heaviest phase loads 2,080. Scripts: 477 lines (was about
  7,000). Five templates instead of fifteen. `status` on the 12-feature legacy
  store above: 0.2 s.
- **Knowledge stays simple.** Scouts read the `knowledge` folder first;
  Evidence moves verified facts into it. Lessons, harvest, memory-merge and
  area pages are gone.
- **Selftest** (95 checks) covers prompt budgets, gates, stops, routing
  boundaries and caps, scenario history, review binding, delivery authority and
  legacy stores, and drives one real feature through all four phases on a CLI
  fixture, on Linux, macOS and Windows.

## Verified with a real agent

A fresh agent took one request ("add an optional quantity to inventory items")
through all four phases on a small CLI with two rules hidden in its docs:
export columns are read by position, and a missing quantity is unknown (`?`),
never 0. It found both rules during Intent, asked one blocking question,
stopped for the human at intent and at the plan (public-API flag), passed the
diff review on its first round, scored 14/14 with four QA-added scenarios, and
shipped one local commit. Its feedback on the kit led to six fixes: `init` no
longer edits `.gitignore`, `\|` works inside table cells, the reviewer sees
intent.md, the intent gate's question order is explicit, risk flags print in
full, and config.md says what `qa:` holds.

## Compatibility

- **Breaking.** `AGENTS.md`, `init.sh`, `gates/*`, `tools/*`, spec.md,
  summary.md, delivery.md, qa-guide.md, map.md, harvest, verification
  receipts, handoff, tripwire, refcheck and the QA-mode switch are removed.
- **v0 features show as `legacy`** (`next` exits 20). Finish them with
  `v0.27.0` or close them: `sdlc.sh close <slug> dropped "<reason>"`.
- **`lazymode` still reads**: 0–1 → `human_gates: intent plan`, 2–3 →
  `intent`, 4 → none; an unknown `human_gates` word means both.
  `.sdlc/memory/` is the knowledge folder until `knowledge:` is set. An
  existing `/.sdlc` line in `.gitignore` keeps working.
- Hosts: `sdlc.sh status --json` and `sdlc.sh next` replace
  `gates/status.sh --json` and `tools/auto.sh next`, with the same exit codes
  (0 ready, 10 needs the human, 20 blocked, 30 done).

## Known limits

- An approval, an `Authorized:` line or a resolved question records the words
  given; the script cannot prove who said them.
- Small-task timing was not re-measured: the PR #26 harness is not in this
  repository.
