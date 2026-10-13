# v2.4.0 — find consumers before QA does, cheaper QA rounds

Lessons from one feature (a front-end route restructure) that took three
review rounds and three QA rounds. Each QA round re-drove 18 to 20 browser
scenarios by hand (45 and 38 minutes); two of its three code defects were
knowable before QA. No script change: the rules moved.

## Changes

- **Consumers of changed identifiers.** The change turned list routes into
  redirects. A privacy-audit logger still compared the old route names, so
  its log stopped silently; the plan missed it and the first review called
  the old references harmless. The logic scout now lists every consumer of
  an identifier the change renames, retires or redirects — searching the
  literal value too, and counting consumers that only compare it (loggers,
  audit and analytics events, permission checks, watchers, flags, links from
  other apps). PLAN.md's side effects cover each; the reviewer blocks a plan
  that skips them and a diff that leaves one comparing the old value.
- **Observable review findings become scenarios.** A finding the first
  review rated non-blocking (a redirect missing a required parameter) was
  only driven in QA round 2, where it failed and cost a loop. A non-blocking
  finding a screen, API, job or log could show now ends in `(observable)`,
  and QA runs each as a scenario in the first round.
- **QA preflight.** Three environment faults were each found mid-run: a dev
  proxy pointing at a local API that was not running, a dev server killed by
  its host's 30-minute background limit, and a browser driver that cannot
  start in a sandboxed peer agent. QA now checks once, before any scenario,
  that one real call per route reaches the intended environment, that the
  driver starts, and that long-running processes outlive the run, and records
  what it learned.
- **Re-runnable scenarios, cheaper rounds.** QA saves the script behind each
  scenario in `logs/scripts/`. A later round re-runs every script against
  the new commit and drives by hand only FAIL and BLOCKED rows, new rows and
  rows the new diff touches, writing `logs/r<round>-<ID>.txt` beside the old
  logs. Every row still gets a run on the new commit. At delivery, scripts
  worth keeping go to the project's `e2e` suite or into Delivery as a
  follow-up.
- **A code FAIL is a bug fix.** Back from Evidence, each code FAIL gets its
  regression test first, failing for the reported reason, as Implement
  already asks of bug fixes. In that feature one fix went to review without
  one and the review failed on exactly that.
