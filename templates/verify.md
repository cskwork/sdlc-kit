# Verification recipe — copy to `.sdlc/verify.md` and fill in
#
# This is the project's own verification contract, read by `tools/verify.sh`.
# It maps every requirement to the REAL command that proves it and names the
# commands that bring a runtime up and take it down again. One directive per
# line; anything else in this file is a comment.
#
# EVERY placeholder below must be replaced or the line deleted. A recipe still
# holding `<…>` is refused before anything runs — a placeholder handed to a
# shell is not a verification, and a 60s doctor wait on one looks like work.
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

# The requirement → command map. One line per check:
#   check: <id> | <kind> | <command>
#   id     [a-zA-Z0-9._-]+ — usually the requirement id (R1, R2, …). It names
#          the log file under .sdlc/work/<slug>/scratch/verify/<id>.log.
#   kind   build | unit | lint | runtime | e2e | data
#          `runtime` and `e2e` are the only kinds that count as the real run:
#          the change driven through the interface a user or caller meets.
#          `data` is a READ-ONLY query that proves a consistency claim (the
#          Side effects lens, roles/verifier.md) — receipted, never the real run.
#   command  the project's OWN command, scoped to the change where possible.
#          It runs with stdin on /dev/null, in its own process group, bounded
#          by check_timeout. EVERY configured check runs, and the receipt
#          records how many were configured and how many ran.
check: build | build | <the build command from .sdlc/config.md>
check: unit | unit | <the test command, scoped to the change where possible>
check: lint | lint | <the lint command>
check: R1 | e2e | <the project's own e2e command for this requirement>
check: R2 | runtime | <a real request/command against the launched instance>
check: D1 | data | <a read-only query: e.g. rows written in the new shape == rows read by its consumer>
