# Phase 1: Intent

Goal: `intent.md` saying what the human wants, what you understood, and the
risks in that understanding — confirmed before anyone explores deeply.

1. `sdlc.sh new <slug>`. Prefix the slug with the ticket key or the date
   (`abc-123-fix-login`, `261012-fix-login`).
2. Read the request and its source (ticket, issue, document). Look only as
   far as you need to restate it: the main code path, the screen or command,
   and `knowledge` pages with the same words. Deep exploration is phase 2.
3. Fill `intent.md` (`templates/intent.md`):
   - **Request** — the human's words, verbatim or a faithful excerpt.
   - **Understood as** — the outcome, what is in and out of scope, and
     success criteria `O1..On`, each observable so a scenario can check it.
   - **Risks in this intent** — ambiguity, a claim the code or data already
     contradicts (with the evidence), a policy the request would change and
     who owns it, work that needs authority (rule 3). Before logs, error
     records, reports or metrics count as evidence, check their source (the
     user, agent or job behind them) shows real use, not tests, automation
     or synthetic traffic.
   - **Blocking questions** — only those whose wrong answer changes what
     gets built or leaves the authorized scope. Ask them one at a time and
     record each answer in place as `— resolved: <answer, source>`. Other
     uncertainty is written as `[assumed: why]`.
   - **Delivery** — `local`, `pr` or `deploy` alone on the Target line
     (`pr` also covers pushing a branch for review with no pull request),
     details such as branch or environment on a `Note:` line, and
     `Authorized: yes — "<the human's words>"` when they authorized it, else
     `no`.
4. Several independent outcomes → one slug each; list them under Understood
   as.
5. A bug report also records what was done, what happened against what was
   expected, where and when, as whom, and what trace exists. Ask once for
   what is missing; reproducing it is phase 2's job.

## Gate

Once every blocking question is resolved — human gate (the default): show
the human Understood as and Risks, and ask one question — is this what you
want? On explicit approval run
`sdlc.sh approve intent <slug> --human "<their words>"`.
Otherwise check intent.md against the request yourself, run
`sdlc.sh approve intent <slug> --agent "<what you checked>"`, and post it as
FYI. Then phase 2.
