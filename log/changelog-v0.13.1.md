# v0.13.1 — kb.sh without the duplication v0.13.0 shipped with

A refactor of `tools/kb.sh` with one intentional behaviour change. Output of
`show`, `index`, `list`, `search` and `harvest` is unchanged byte for byte
except where noted; the gates are untouched.

## Changes

- **One definition of "unmerged harvest".** `index` and `harvest` each had their
  own loop deciding which open features still hold candidates; both now read
  `kb_unmerged`. `index`'s two passes over the features (overview table, then
  one section each) share `kb_meta` for state, date, tags and title instead of
  extracting them twice.
- **`kb_get`** replaces the nine `kb_real "$(kb_field …)"` idioms; `kb_closed`
  replaces the three awk one-liners over `CLOSED`.
- **Dropped: the `## Summary`-inside-intent.md fallback.** It supported a format
  no store ever wrote — designed and abandoned inside the v0.13.0 work — and its
  helper `kb_summary_where` with it. `summary.md` is the digest.
- **Dropped: `index --obsidian`.** The page style is a property of the store, and
  `init.sh` and `close.sh` regenerate the page without flags, so
  `index_style: obsidian` in the store's `config.md` was already the setting
  that mattered. One setting, one place; the flag is now an unknown option.
- **Fixed on the way:** `show` printed `Tags:` only when the intent carried them,
  although the tags live in `summary.md` — the meta line now uses the same
  `kb_tags` the page uses. A feature that carries a `CLOSED` record but was never
  archived (an interrupted close) is now treated as closed everywhere on the
  page — sorted by `closed_at` and labelled `closed <date>` — where before only
  `archive/` entries were.
- Internal record lines use `\037` as separator, not a tab: a tab is IFS
  whitespace, so `read` collapses adjacent tabs and an empty field (no tags, no
  date) shifted the fields after it.
- Header comment shortened; `tools/kb.sh` 605 → 538 lines.

Checked against a real store (84 open, 2 archived, Korean records): the page
and the `show` digests are byte-identical to v0.13.0 except for the two lines
the fixes above describe; `harvest` output is identical.

## Validation

- `bash gates/knowledge-test.sh` → `KNOWLEDGE-TEST PASS`, 144 assertions
  (section H rewritten for the config-only style; the flag refusal is asserted)
- `bash gates/selftest.sh` → `SELFTEST PASS`
- `bash gates/e2e.sh` → `E2E PASS`, 152 · `bash gates/autotest.sh` → `AUTOTEST PASS`, 195
