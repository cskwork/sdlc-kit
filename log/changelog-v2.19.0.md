# v2.19.0: One brief format for agents outside sdlc

To-do only; the sdlc loop is unchanged.

## Problem

An agent outside sdlc (for example an automated factory) could attach a brief, but the format the app reads (At a glance labels Your call, What changes, AI pick, Phase, Background, Why) was written down only in the app's code. Each agent had to copy it, and a brief without `AI pick:` or `Phase:` silently lost the recommendation and the phase bar.

## Changes

- **`todo/brief.md`** is the one brief template: a title, At a glance with the six labels the app reads, and an Options list. Agents fill it and drop any line they cannot fill.
- **`todo/AGENT.md`** says to ask the human outside sdlc with that template, `brief`, and `choices --pick` (still under 600 words).
- **README** (en, ko) points the brief paragraph at the template.
- **Test:** every At a glance label in `todo/brief.md` must be one the app reads, so the template and the app cannot drift apart.
