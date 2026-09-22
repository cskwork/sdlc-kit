# Cheap decisive probes — run BEFORE any researcher fan-out

Each probe costs seconds and can kill or confirm a hypothesis class. Fan-out
buys breadth; probes buy direction. Run the relevant probes first, then
dispatch researchers only for the questions probes cannot answer.

## 1. Deployed-ref drift (always, for any bug on deployed code)

    tools/refcheck.sh origin/<deploy-branch> [--deployed-sha <sha>] <suspected paths>

Exit 1 means the working tree is NOT that source — the listed files differ,
including staged, unstaged, and untracked ones. All reads then go through
`git show <rev>:<path>`, and every report names its revision. Exit 2 means
UNKNOWN (bad ref, failed fetch): no claim about the running code is available
at all. Pass `--deployed-sha` whenever the release system or the running app
reports one; a branch ref is a pointer in this clone, not deployment
evidence.

## 2. Sibling-query filter diff (when one flow reads or writes one entity 2+ ways)

List the filter of every query on that entity along the flow — SQL WHERE and
JOIN ON, ORM criteria, API query params, cache keys — side by side. A
predicate present in one and absent in another (soft delete, tenant, status,
version) is a candidate defect; so is a read key that differs from the
write's unique key.

## 3. Blame the failing lines (who, when, and was it ever revisited)

    git blame -L <start>,<end> --date=short <ref> -- <file>
    git log --all --oneline --grep='revert' -i -- <file>

Answers "recent regression vs long-dormant defect" and "was a fix reverted".

## 4. Caller guard audit (before trusting or changing any shared symbol)

    grep -n '<symbol>(' <file>        # list call sites
    # for each site: does the next statement dereference without a null/empty check?

Produce the call-site × guard table BEFORE proposing a change to the shared
symbol. This table decides fix ordering.

## 5. Class sweep (when one defect is an instance of a pattern)

A missing filter, guard, timeout, or lock at one site is rarely alone.
Grep the same file/module for the whole class and report a count table.
One instance is a bug; the full table is the scope.

## 6. Gate check on "impossible" claims

Before writing "X never happens" or "logs are on", read the CONDITION AROUND
the constant, not just the constant. A hardcoded `true` inside a dead branch
is false. (This exact trap shipped a wrong repro instruction once.)

## 7. Propagation proof (before proposing any try/catch or guard)

Trace the claimed error to the fix site. A lower layer that catches its own
errors and returns false/null cannot reject an upper await; a try/catch
there fixes nothing. Prove the error can REACH the handler you are editing.

## 8. Timeout audit (when the symptom is "nothing happened" or "hangs")

    grep -n -i 'timeout' <files that make outbound calls: HTTP clients, DB, queues, locks>

A call with no timeout that precedes the expected effect (a popup, a
response, the next job step) explains a hang or a silent no-op better than
most crash theories.
