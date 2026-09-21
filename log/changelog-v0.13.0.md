# v0.13.0 — records a human can read: digest, overview, unmerged knowledge

v0.12.0 moved the records out of git and made them retrievable. Retrieval
returned paths: `kb.sh show` was a table of contents, the generated page was a
flat slug-ordered list, and a feature's knowledge became visible only when
`close.sh` merged its harvest — which, in a loop with many open features, is
rarely. This release changes what a reader gets, not what the loop records.
Gate authority, tamper detection, source binding, the `--json` schema and
lazymode are untouched; nothing under `work/` or `archive/` is written by any
of it.

## Changes

- **`summary.md` — the reader's page** (`templates/summary.md`). Five one-line
  bullets (Problem, Cause, Change, Result, Lesson) and a `Tags` line, in plain
  language, ten lines at most. It is not a stage artifact and no approval binds
  it — deliberately, so it can stay TRUE while `intent.md` stays frozen by its
  approval: written with the intent (skills/1-intent), Result and Lesson set at
  ship from what `delivery.md` proves (skills/5-ship). `kb.sh show` and the
  contents page print it before anything else. An older store that wrote a
  `## Summary` section into `intent.md` is still read.
- **`kb.sh show` is a digest.** Goal (falling back to the intent's H1 when an
  older intent has no `- Goal:` line), Track/Type/Date/Tags/Requested by/Refs on
  one line, the summary, `Delivered:` with its confirmation and handoff,
  `Closed:` with its date, the feature's **unmerged `harvest.md` candidates**,
  lesson **titles** with their files — and the document paths last, relative to
  the store. Every line comes from a record; the tool selects and bounds, it
  never summarizes. Long blocks are cut with a `… N more line(s): <path>` line.
- **The contents page opens with an overview table** — feature, state, date,
  tags, goal — open features first, **newest first** (the intent's `Date`, else
  a `YYMMDD-` slug prefix; closed features by `closed_at`), then a
  **"Knowledge not merged yet"** section listing every open feature whose
  `harvest.md` holds candidates, with the first lines of each, then one section
  per feature (goal, summary, track, close reason, documents, lesson titles).
  Goal cells are bounded in bytes under `LC_ALL=C` and cut at a UTF-8 character
  boundary, so a Korean goal is never rendered with a broken glyph. Record
  headings embedded in the page are demoted to labels so a harvest's `###`
  cannot hijack the page outline.
- **`kb.sh harvest [--stale <days>]`** — the trigger the close-only merge
  lacked. Lists open features whose `harvest.md` no close has merged, with the
  candidate line count and the idle time (newest mtime among the feature's own
  records, never `scratch/`); `STALE` at or past the threshold (default 30
  days). Exit `0` something is unmerged, `1` nothing, `2` usage. It reports and
  writes nothing.
- **AGENTS.md rule 4: a loop that never closes must not hide its knowledge.**
  An unmerged harvest is readable before close (`show`, the page, `harvest`),
  and a feature idle 30 days or more may have its harvest merged **without
  closing** — the same procedure, one merge at a time in the owning checkout,
  `harvest.md` deleted afterwards, the feature stays open. `close.sh` still
  blocks on an unmerged harvest exactly as before.
- **`kb.sh index --obsidian`**, or `index_style: obsidian` in the store's
  `config.md` so `init.sh` and `close.sh` keep the style: YAML frontmatter
  (`title`, `sdlc_store`, `tags`) and the feature tags rendered as inline
  `#tags` for a vault's tag pane. Links stay standard relative markdown, which
  Obsidian resolves and graphs; only the generated page is touched. **No
  timestamp is written into the page** in either style — a regenerated page
  whose records did not change is byte-identical, so a vault under git gets no
  diff and no sync conflict from it. The generated-page marker is now
  recognized within the first 12 lines (after frontmatter); a page you wrote
  yourself is still never overwritten.
- **Stage guidance and docs.** `skills/1-intent` (write `summary.md`, read the
  digest before opening files), `skills/5-ship` (bring Result/Lesson up to
  date), `skills/6-maintain` (`kb.sh harvest` before opening a fix-slug),
  `templates/intent.md` (a pointer: the digest lives in `summary.md`),
  `templates/harvest.md`, `SKILL.md` routes, `AGENTS.md` rule 4, both READMEs.

## Usage

```sh
~/sdlc-kit/tools/kb.sh show 260920-login-fix          # digest first, paths last
~/sdlc-kit/tools/kb.sh harvest                        # what is learned but not in memory/ yet
~/sdlc-kit/tools/kb.sh harvest --stale 14 --area ~/knowledge
~/sdlc-kit/tools/kb.sh index --obsidian               # once; or add to <store>/config.md:
#   index_style: obsidian   # tools/kb.sh index
```

## Upgrade notes

- **Nothing to migrate.** Existing records are read as they are; a feature
  without `summary.md` shows its goal and harvest, and older intents without a
  `- Goal:` line show their title. Add `summary.md` to a feature when you next
  touch it.
- **The generated page changes shape** the first time `init.sh`, `close.sh` or
  `kb.sh index` runs under this kit. A `README.md` you wrote yourself is still
  refused, not overwritten.
- **`kb.sh show` output is longer** (digest before paths). Scripts that parsed
  the old `documents:` block should read the `Documents:` block, whose paths are
  now relative to the store.
- Merging a stale harvest without closing is permitted, not automated: the
  agent does the merge under rule 4's guards, then deletes `harvest.md`.

## Validation

Local, on macOS (darwin 25.6.0, arm64, GNU bash 3.2.57, git 2.54.0, APFS
case-insensitive, UTF-8):

- `bash gates/knowledge-test.sh` → `KNOWLEDGE-TEST PASS`, 145 assertions
  (38 new in section H: the digest, the overview order, tags, the unmerged
  section, UTF-8-safe truncation, byte-identical regeneration, `harvest` exit
  codes and `--stale`, `--obsidian` and `index_style`, and that no record under
  `work/` was written)
- `bash gates/selftest.sh` → `SELFTEST PASS`
- `bash gates/e2e.sh` → `E2E PASS`, 152 assertions, 0 failures
- `bash gates/autotest.sh` → `AUTOTEST PASS`, 195 assertions, 0 failures
- `bash -n` over every changed shell script: clean. `git diff --check`: clean.
- Smoke on a real store (84 open features, Korean records): `show` renders a
  digest with the harvest facts; `harvest` lists 9 features / 157 lines; the
  page's overview table cuts long goals at a character boundary.
