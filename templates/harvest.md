# Harvest: <feature slug>

<!-- Mid-loop staging for shared memory (AGENTS.md rule 4). Stages and
     researchers append candidates HERE, never to INDEX.md or DOMAIN.md —
     parallel loops would race or merge-conflict on the shared files.
     At close: merge into memory/ (lesson files + INDEX.md lines + DOMAIN.md
     facts), then DELETE this file. close.sh blocks while it exists.
     Readable BEFORE close: `tools/kb.sh show <slug>` and the contents page
     print these candidates, and `tools/kb.sh harvest` lists every open
     feature that still holds one. A feature idle 30 days or more may be
     merged without closing (same procedure; it stays open — rule 4). -->

## Domain candidates
<!-- - fact / term / constraint — [verified: how — YYYY-MM-DD]
     Contradicts an existing DOMAIN.md entry? Add `supersedes: <old line>` —
     the close merge REPLACES the old entry; recency wins, never keep both. -->

## Lesson candidates
<!-- - [tags] the trap and the correct move; add `promote: skills/<n>` when a
     stage skill should have prevented it -->
