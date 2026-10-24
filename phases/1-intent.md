# Phase 1: Intent

Goal: `intent.md` stating what the human wants, what you understood and its
risks, at least 90% clear and confirmed before planning.

1. `sdlc.sh new <slug>`. Prefix the slug with the ticket key or the date
   (`abc-123-fix-login`, `261012-fix-login`).
2. Read the request and its source with its comments and links, and pages
   in the `memory` folder with the same words.
3. Fill `intent.md` (`templates/intent.md`) for a skimming reader (rule 8):
   a bold lead-in so the bold alone carries the gist, each warning on the
   line it guards; proof goes to Facts. Each fact appears once; elsewhere
   cite it (O2, F3, Q1, Request).
   Write in the requester's language; headings, field labels and Clarity words stay English.
   - **Understood as** — scope (Bottom line Changes is the outcome) and
     success criteria `O1..On`, each observable so a scenario can check it.
   - **Terms** — match each term the request turns on to `glossary.md` in
     the `memory` folder, else the code. A ❓ term leaves its Clarity area
     open and is a blocking question.
   - **Clarity** — state `clear` only when How settled cites evidence that
     leaves one reading: the requester's words, a file:line, a log, a
     primary source. Otherwise `assumed` or `open`.
   - **Facts** — that evidence, one `F1:` line each, with its source.
   - **Risks in this intent** — ambiguity, a claim the code or data already
     contradicts, a policy the request would change and who owns it, work that
     needs authority (rule 3). Claims about real use need verified sources
     (user, agent or job), excluding tests, automation and synthetic traffic.
     Probes establish behavior only.
   - **Blocking questions** — only those whose wrong answer changes what
     gets built or leaves the authorized scope. In the chat ask them one at
     a time; record each answer in place and cite it in its Clarity area.
     Other uncertainty: `[assumed: why]`.
   - **Delivery** — `pr` also covers a branch pushed for review; record
     `Authorized: yes` only with the human's words.
4. Several independent outcomes → one slug each; list them under Understood
   as.
5. A bug report also records what was done, what happened versus expected,
   where and when, as whom, and what trace exists.

## Raise clarity to 90%

`sdlc.sh next` scores Clarity: clear 1, assumed ½, open 0, over six areas.
One assumed area passes; two, or one open, do not. Settle each weak area the
cheapest way, in order:

1. **Explore** — the code path, screen or command the request names, and
   earlier tickets or commits on it. Look only as far as what is wanted; how
   to change it safely is phase 2.
   A question needing more than a few reads goes to a scout
   (`roles/scout.md`); phase 2 reuses its `refs/` file.
2. **Reproduce** — drive a reported bug safely: locally or in a
   test environment, never writing shared or production data. Save the
   output in `logs/` and cite it in AS-IS. Root cause, rival causes and the
   failing test stay in phase 2's `refs/repro.md`. Not reproduced → ask the
   reporter for the missing step, account, data or time; do not guess.
3. **Research** — when TO-BE depends on something outside the repository (a
   standard, an API, a vendor's or product's behavior), read the primary
   source and cite it.
4. **Probe** — a fact one cheap, safe throwaway run settles (does the
   parser accept X?): run it outside the human's tree, within rule 3;
   record it in `refs/`, output in `logs/`. Probe code never ships.
5. **Ask** — what evidence cannot settle, ask where the request came from:
   a comment on its ticket, issue or pull request, else the chat. Posting is
   rule 3 work: without the human's words, show the draft. One comment
   carries every open question, numbered, each with its options and the
   answer you will assume. A question that blocks nothing rides in the same
   comment, noted in its area's How settled, not under Blocking questions.
   An answer from the requester or the policy owner resolves it; anyone
   else's is a lead. An answer settles what to build; it grants no authority.

## Gate

Once clarity is 90% and every blocking question is resolved, dispatch the
reviewer in intent mode (`roles/reviewer.md`); skip it only when every area
cites the requester's own words. An area it shows unsettled goes back to
Raise clarity. Then — human gate (the default): show the human Bottom line,
Risks and any assumed Clarity area, ask one question — is this what you
want? — and end the turn. Only a reply to that question approves:
`sdlc.sh approve intent <slug> --human "<their words>"`. An answer to a
blocking question is not approval; ask again after it.
Without an intent gate, check intent.md against the request yourself, run
`sdlc.sh approve intent <slug> --agent "<what you checked>"`, and post it as
FYI. Then phase 2.
