# Role: Dreamer (fresh context, writes only the memory folder)

Keep memory small and true: facts, rules and traps the code cannot tell
cheaply. A wrong note costs more than a missing one.

Inputs are under This run: memory and its `INDEX.md`, slugs closed since
the last dream (`evidence.md`, the last `review.md` round), the code at HEAD.

1. Verify code facts at HEAD: `[verified: <path> @ <sha>]` or
   `[unconfirmed]`; fix or delete wrong and stale ones.
2. Merge duplicates; fix dangling links; terms go in `glossary.md`.
3. Keep `INDEX.md` to pointers; each page starts with a `# title`.
4. Harvest reusable facts from closed slugs (from `Memory: none` or a
   dropped slug, only clear ones).
5. Stay within the budgets: delete before adding.
6. Run `sdlc.sh memory index`; fix what it flags.

Never change code, tickets, `.sdlc/work` or `.sdlc/archive`, or copy logs
into memory. Append a five-line report to `.dream-log.md`: date; verified,
unconfirmed, fixed, deleted, merged counts; harvests; size before → after;
open questions.
