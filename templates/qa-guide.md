# QA guide: <feature slug>

<!-- The steps a PERSON follows to see the delivered change working with their
     own eyes — written at ship once delivery.md is written, quoted in full
     in the final report, and archived with the feature (skills/5-ship).
     Write for a tester who was not there: the team's language, the words on
     the screen, one action per step, each with what they should see.
     Build it from what the E2E lens actually drove (evidence.md E2E; the
     area page's Drive line, or its harvest.md candidate); the account from
     the verifier report's Roles/platforms line (roles/verifier.md). A step
     the agent did not run is marked `[not run by agent]`, never presented
     as checked. Cite evidence.md sections, not scratch/ files: close prunes
     what evidence.md, delivery.md, or a lesson does not cite.
     NEVER write a password, token, cookie, or key here or in the report:
     name the account and where its password is kept; a command uses a
     placeholder (`$TOKEN`) and names where it comes from. A value you do
     not know is "unknown — <who can provide it>", never a guess. -->

- Environment: <the URL, app build, or command the tester opens — where the delivered change really runs (delivery.md). Not deployed yet, or delivery.md says `Confirmed: no` → say so, and give the local run command from .sdlc/config.md `run:`>
- Account: <account ID> · role <role> · password: <where it is kept, e.g. 1Password "dev-teacher01"> | none needed | unknown — <who can provide one>
- Menu: <the menu path, as summary.md's Area line reads; no screen → the API, job, or CLI command, secrets as placeholders>
- Data: <the record or condition the steps need and how to get it, or none>

## Before the fix   <!-- bug fixes only: what the tester would have seen; delete for features -->
<the reported symptom, in the words a user would use>

## Steps
1. <one action, naming the exact menu, button, field, and value> → Expect: <what the screen shows>
2. <…> → Expect: <the value the change is about>

## Also check   <!-- optional: another role, mobile, a neighbouring flow — one line each -->
- <role, platform, or flow> → <the step that differs> → Expect: <…>

## Clean up
<what to undo or delete afterwards so the next test starts clean, or "nothing">

## Not checked by the agent
<what evidence.md's Not verified lists that a person should look at, in plain words, or "none">
