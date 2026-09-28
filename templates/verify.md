# Verification recipe — copy to `.sdlc/verify.md` and fill in
#
# This is the project's own verification contract, read by `tools/verify.sh`.
# It maps every requirement to the REAL command that proves it and names the
# commands that bring a runtime up and take it down again. What each state
# means, coverage and the baseline: docs/automation.md §4.
#
# Settings and shared build/unit/lint checks live here; a feature's own
# requirement checks go in `.sdlc/work/<slug>/verify.md`
# (templates/verify-feature.md). The two are one recipe: an id appears once.
#
# EVERY placeholder below must be replaced or the line deleted. A recipe still
# holding `<…>` is refused before anything runs — a placeholder handed to a
# shell is not a verification, and a 60s doctor wait on one looks like work.
#
# Syntax. One directive per line, from column 1; anything else is a comment. An
# indented `check:`/`gap:` line, or one holding a tab, is refused, never
# skipped. A UTF-8 BOM is ignored. Value lines (profile, the timeouts,
# environment, test_paths, forbidden_hosts) may end in ` # comment`; commands
# (launch, doctor, cleanup, baseline_setup, check) go to `sh -c` verbatim.
# Timeouts are whole seconds.
#
# profile: strict | advisory
#   strict   — a feature is not review-ready until a `runtime` or `e2e` check
#              has actually passed over the current source, against a runtime
#              THIS run launched (`--no-launch` does not qualify), with the
#              doctor confirming it. A missing runtime environment blocks; it
#              never downgrades to "unit tests passed".
#   advisory — the same checks run and the same receipt is written, but a
#              missing runtime is reported as a gap instead of a block.
profile: advisory

# Optional. Start whatever the runtime checks need (a server, a worker, a
# container). It is started in ITS OWN PROCESS GROUP and the whole group is
# stopped at the end — children included. If it exits immediately (a port
# already in use, a syntax error) the run fails there and says so.
launch: <e.g. npm run start:test>

# Optional but strongly recommended, and REQUIRED by `profile: strict` whenever
# `launch:` is set. Exit 0 ONLY when the environment is really ready to be
# driven. Make it prove IDENTITY, not just liveness: have it assert the build
# or version of the instance that answers (e.g. a /health payload carrying the
# commit sha, or `--version` matching the build under test). A bare port probe
# cannot tell this run's runtime from yesterday's still holding the port — and
# `tools/verify.sh` will only tell you that the process it started is the one
# still alive, not that the thing answering is the right build.
doctor: <e.g. curl -fsS http://localhost:3000/health | grep -q "$(git rev-parse HEAD)">
doctor_timeout: 60          # total seconds to wait for the doctor to come up
doctor_attempt_timeout: 30  # seconds ONE doctor attempt may take
check_timeout: 900          # seconds ONE check may take before it is killed
cleanup_timeout: 30         # seconds cleanup (and stopping the runtime) may take

# Optional. Always runs at the end, including after a failure. If it fails or
# times out, the run is reported as blocked: a leftover runtime would make the
# next result meaningless.
cleanup: <e.g. docker compose -f compose.test.yml down -v>

# Optional, free text: where these checks run, for the receipt and evidence.md.
environment: <local dev instance · seeded fixture data · staging URL>

# Optional but recommended. Hosts no command here or in a feature recipe may
# name, comma separated (case-insensitive, on the command text only). A hit
# refuses the run before anything executes.
forbidden_hosts: <e.g. api.example.com, db.prod.example.com>

# Required by must-fail-on-base. Where tests live, as shell patterns (comma or
# space separated; `*` also matches `/`): the changed files they match are
# copied into the base checkout, so the NEW test runs against the OLD code.
test_paths: <e.g. tests/*, src/*.test.ts>

# Optional. Runs first in the base worktree of `tools/verify.sh baseline`, which
# has no installed dependencies (without them a regression can read as
# pre-existing). Install or copy; never link into the real checkout
# ($SDLC_PROJECT_ROOT is for reading), or a base build writes the human's tree.
baseline_setup: <e.g. npm ci --prefer-offline --no-audit>

# The requirement → command map. One line per check:
#   check: <id> | <kind> | <command> [| must-fail-on-base]
#   id     [a-zA-Z0-9._-]+ — the requirement id (R1 on the full route, O1 on the
#          compact one), optionally with a variant: R1.happy, R1.boundary,
#          R1.negative, R1.regression, R1.authz, or a reach axis: R1.entry,
#          R2.state, R1.context (roles/verifier.md). It names
#          the log .sdlc/work/<slug>/scratch/verify/<id>.log.
#   kind   build | unit | lint | runtime | e2e | data
#          `runtime` and `e2e` are the only kinds that count as the real run:
#          the change driven through the interface a user or caller meets.
#          `data` is a READ-ONLY query that proves a consistency claim (the
#          Side effects lens, roles/verifier.md) — receipted, never the real run.
#          A visual or performance-budget check is an e2e/runtime check that
#          exits non-zero past its budget.
#   command  the project's OWN command, scoped to the change where possible.
#          It runs with stdin on /dev/null, in its own process group, bounded
#          by check_timeout. EVERY configured check runs, and the receipt
#          records how many were configured and how many ran.
#   must-fail-on-base  optional: the check must FAIL at the base commit, or it
#          is `vacuous`. Only this exact word after the last `|` (a ` # comment`
#          may follow); not on runtime/e2e checks when `launch:` is set.
#
# A requirement no check can cover gets a gap line instead, listed, never hidden:
#   gap: <id> | <reason a reviewer can weigh>
# `tools/verify.sh coverage <slug>` shows what covers each requirement.
check: build | build | <the build command from .sdlc/config.md>
check: unit | unit | <the test command, scoped to the change where possible>
check: lint | lint | <the lint command>
check: R1 | e2e | <the project's own e2e command for this requirement>
check: R2 | runtime | <a real request/command against the launched instance>
check: D1 | data | <a read-only query: e.g. rows written in the new shape == rows read by its consumer>
