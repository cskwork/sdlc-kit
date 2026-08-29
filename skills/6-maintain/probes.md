# Cheap decisive probes — run BEFORE any researcher fan-out

Each probe costs seconds and can kill or confirm a hypothesis class. Fan-out
buys breadth; probes buy direction. Run the relevant probes first, then
dispatch researchers only for the questions probes cannot answer.

## 1. Deployed-ref drift (always, for any bug on deployed code)

    tools/refcheck.sh origin/<deploy-branch> <suspected paths>

Non-zero exit means the working tree is NOT the running code. All reads then
go through `git show <ref>:<path>`, and every report names its ref.

## 2. Sibling-query filter diff (when one method issues 2+ queries on one entity)

    awk '/id="queryA"/,/<\/select>/' mapper.xml | grep -E 'WHERE|AND'
    awk '/id="queryB"/,/<\/select>/' mapper.xml | grep -E 'WHERE|AND'

Any predicate present in one and absent in the other is a candidate defect.
Watch for filters written in JOIN ON clauses, not only WHERE.

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

## 8. Timeout audit (when the symptom is "nothing happened")

    grep -n 'timeout' <api-client files>

An awaited call with no timeout that precedes the visible action (popup,
navigation) explains a dead-looking UI better than most crash theories.
