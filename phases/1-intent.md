# Phase 1: Intent

Goal: `intent.md` saying what the human wants, what you understood, and the
risks in that understanding — at least 90% clear and confirmed before anyone
plans how to build it.

1. `sdlc.sh new <slug>`. Prefix the slug with the ticket key or the date
   (`abc-123-fix-login`, `261012-fix-login`).
2. Read the request and its source (ticket, issue, pull request, document)
   with its comments and links, and pages in the `memory` folder with the same words.
3. Fill `intent.md` (`templates/intent.md`):
   - **Request** — the human's words, verbatim or a faithful excerpt.
   - **Understood as** — the outcome, what is in and out of scope, and
     success criteria `O1..On`, each observable so a scenario can check it.
   - **Terms** — match each term the request turns on to `glossary.md` in
     the `memory` folder, else the code. A ❓ term, read two ways,
     leaves its Clarity area open and is a blocking question; the question
     shows each reading with a real value.
   - **Clarity** — one row per area: Outcome, Scope, AS-IS, TO-BE, Success,
     Constraints. State `clear` only when How settled cites evidence that
     leaves one reading: the requester's words, a file:line, a log, a
     primary source. Otherwise `assumed` (and why) or `open` (and what is
     missing).
   - **Risks in this intent** — ambiguity, a claim the code or data already
     contradicts (with the evidence), a policy the request would change and
     who owns it, work that needs authority (rule 3). Before logs, error
     records, reports or metrics count as evidence, check their source (the
     user, agent or job behind them) shows real use, not tests, automation
     or synthetic traffic.
   - **Blocking questions** — only those whose wrong answer changes what
     gets built or leaves the authorized scope. In the chat ask them one at
     a time; record each answer in place as `— resolved: <answer, source>`
     and cite it in its Clarity area. Other uncertainty is written as
     `[assumed: why]`.
   - **Delivery** — `local`, `pr` or `deploy` alone on the Target line
     (`pr` also covers pushing a branch for review with no pull request),
     details such as branch or environment on a `Note:` line, and
     `Authorized: yes — "<the human's words>"` when they authorized it, else
     `no`.
4. Several independent outcomes → one slug each; list them under Understood
   as.
5. A bug report also records what was done, what happened against what was
   expected, where and when, as whom, and what trace exists.

## Raise clarity to 90%

`sdlc.sh next` scores Clarity: clear 1, assumed ½, open 0, over six areas.
One assumed area passes; two, or one open, do not. Settle each weak area the
cheapest way that works, in this order:

1. **Explore** — the code path, screen or command the request names, and
   earlier tickets or commits on it. Look only as far as what is wanted; how
   to change it safely (every caller, data states, side effects) is phase 2.
   A question needing more than a few reads goes to a scout
   (`roles/scout.md`); phase 2 reuses its `refs/` file.
2. **Reproduce** — drive a reported bug where that is safe: locally or in a
   test environment, never writing shared or production data. Save the
   output in `logs/` and cite it in AS-IS. Root cause, rival causes and the
   failing test stay in phase 2's `refs/repro.md`. Not reproduced → ask the
   reporter for the missing step, account, data or time; do not guess.
3. **Research** — when TO-BE depends on something outside the repository (a
   standard, an API, a vendor's or product's behavior the request points
   to), read the primary source and cite it.
4. **Ask** — what evidence cannot settle, ask where the request came from:
   a comment on its ticket, issue or pull request (Jira, GitHub, GitLab,
   Linear…), else the chat. Posting there is rule 3 work: without the
   human's words for it, show them the draft. One comment carries every open
   question, numbered, each with its options and the answer you will assume;
   mark each `— asked: <where, when>` until answered. A question that
   blocks nothing rides in the same comment and is noted in its area's How
   settled, not under Blocking questions. An answer from the
   requester or the policy owner resolves it; anyone else's is a lead. An
   answer settles what to build; it grants no authority.

## Gate

Once clarity is 90% and every blocking question is resolved, dispatch the
reviewer in intent mode (`roles/reviewer.md`); skip it only when every area
cites the requester's own words. An area it shows unsettled goes back to
Raise clarity. Then — human gate (the default): show the human Understood
as, Clarity and Risks, and ask one question — is this what you want? On
explicit approval run
`sdlc.sh approve intent <slug> --human "<their words>"`.
Otherwise check intent.md against the request yourself, run
`sdlc.sh approve intent <slug> --agent "<what you checked>"`, and post it as
FYI. Then phase 2.
