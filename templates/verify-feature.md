# Feature verification recipe — copy to `.sdlc/work/<slug>/verify.md` and fill in
#
# This feature's own requirement checks. Everything shared (settings, the
# build/unit/lint checks) stays in `.sdlc/verify.md` (templates/verify.md), and
# tools/verify.sh runs the two as one recipe. Only `check:` and `gap:` lines and
# `#` comments are allowed here, a check id appears once across both files, and
# editing this file stales only this feature's receipt. Line syntax:
# templates/verify.md. Coverage and the baseline: docs/automation.md §4.
#
#   check: <id> | <kind> | <command> [| must-fail-on-base]
#   gap:   <id> | <why this requirement has no check, for the reviewer>
#
# id: R<n> (spec.md, full route) or O<n> (intent.md, compact route), optionally
# with a variant: R1.happy, R1.regression, or a reach axis from plan.md's
# Reach: R1.entry, R1.state, R1.context (roles/verifier.md). A check here is
# never `pre-existing`: it belongs to this change.
#
# EVERY placeholder below must be replaced or the line deleted.
check: R1.happy | e2e | <the project's own e2e command for R1's main path>
check: R1.regression | unit | <the new test that reproduces the defect> | must-fail-on-base
check: R1.entry | e2e | <the same behavior reached through the other caller Reach picked>
gap: R2 | <why R2 cannot be checked here, and how it is verified instead>
