# v2.9.0 — Intent pins the request's terms

Intent now lists the terms a request turns on and what each means, before it
scores clarity. A term that reads two ways blocks the plan the same way an
open area does. The project's terms live in one place: `glossary.md` in the
`memory` folder.

## Why

- **A misread term passes self-scoring.** An agent that reads "module number"
  as the wrong one of two identifiers is confident, so it marks the area
  `clear`. Unattended runs approve their own intent, so nothing caught it.
  The reviewer only checked whole-request readings, not single words.
- **Matching by the same words misses synonyms.** Intent read memory pages
  that used the request's words; a requester who uses a different word from
  the code found nothing.
- **Settled terms were lost.** A feature that worked out which of two
  identifiers a word meant wrote it as a note; the next request with the same
  word re-did the research.

## Changes

- **`## Terms` in intent.md.** One entry per term, two lines: a mark, the
  term, its plain meaning and a real example value; then its source and code
  name. ✅ one meaning, ⚠️ assumed, ❓ two readings. A ❓ term leaves its
  Clarity area open and becomes a blocking question that shows each reading
  with a real value, so a non-developer can answer it.
- **One glossary, in `memory`.** Intent matches terms against
  `glossary.md` in the `memory` folder, else the code. Evidence adds the terms
  a feature settled to it. No new config key.
- **Reviewer, intent mode.** A term with an unruled second reading, or a ✅
  term whose source does not say so, blocks.
- Plan's "it summarizes; link, do not copy" line is removed: SKILL.md rule 7
  says the same, and the plan load needed the words.

## Compatibility

- No `sdlc.sh` change; existing intent.md files without `## Terms` still
  approve.
- A project whose glossary lives elsewhere can keep it there and give
  `glossary.md` a pointer per term, or move it in.

## Known limits

- The script does not parse Terms: a ❓ term blocks only through the Clarity
  area the agent marks open, and the intent reviewer.
- Word budget: total 5958 of 6000, plan load 2494 of 2500.
