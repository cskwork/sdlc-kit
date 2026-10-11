# Shared memory merge procedure

Read this entire procedure before merging candidates. Authority and startup
reads remain in AGENTS.md rule 4; this reference owns destinations and merge
mechanics. Destinations below are relative to .sdlc/; references are kit-relative.

| What | Where | Written by |
|---|---|---|
| A product's business rule (정책) — "a submitted answer cannot be edited" | memory/areas/<menu path>.md Business rules table, one plain sentence per P1… row (templates/area.md) | close merge, shipped only |
| How an on-screen count, rate, score or chart figure is calculated | the same page's Numbers table, one N1… row per figure | close merge, shipped only |
| A rule or figure's source, the code behind the area, and how to drive it | the same page's evidence block: Where and Drive lines, then one evidence row per rule or figure | close merge |
| What changed in an area, when | the area page's History table, one row per feature | close merge, shipped only |
| A fact that holds for one area only | the area page's How it works | close merge |
| A term, or a system fact/constraint that spans areas | memory/DOMAIN.md (100 lines max) | close merge |
| A trap and the correct move | memory/lessons/<date>-<slug>.md + one INDEX.md line (50 lines max) | close merge |
| A hard rule for agents, in the human's words | memory/POLICY.md | only on the human's word (AGENTS.md rule 4) |
| One feature's story for a reader | work/<slug>/summary.md (templates/summary.md) | any stage, kept current |

1. Merge every candidate into its destination. Create absent area pages from
   templates/area.md; read that template for file names, layout and row shapes.
   summary.md's Area and the area's Menu use the same words, which is how kb.sh
   links them. Add the feature's History row to each area it changed.
2. Business rules, figures and History describe what the product DOES: merge
   them only when closing shipped; any other terminal state drops them, with
   summary.md keeping the story. An idle merge leaves them in harvest.md for
   close. A feature idle 30 days or more may merge other candidates without
   closing, one merge at a time in the owning checkout; tools/kb.sh harvest
   lists them and never writes memory/.
3. Recency wins, with three guards. Date every fact; a contradicting candidate
   replaces the old entry with a fresh [verified: how — YYYY-MM-DD]. Weaker
   evidence never supersedes stronger (code-read vs production capture goes
   to the human); qualify facts true in different scopes instead of replacing
   them; reconcile by evidence a supersedes target rewritten by a parallel
   close. Human-stated lines are never deleted on recency alone — ask.
4. Keep DOMAIN at 100 lines: move area-specific facts to their area. Keep INDEX
   at 50 lines: merge near-duplicates, drop superseded entries and replace
   promoted ones under skills/6-maintain "Record the lesson" so recurrence
   counts survive pruning.
5. Delete harvest.md only after merging or dropping all candidates; stale
   product candidates stay there for close. close.sh blocks while it exists.
