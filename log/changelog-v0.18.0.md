# v0.18.0 — look for the flow that already exists before designing a new one

A feature asked students to switch between two teachers and reload under the
chosen one. Stage 1 framed it as "where do we store the chosen teacher",
sent researchers after backend token-reissue precedents, and approved a
design with new APIs. The product already had a working re-entry flow for a
similar switch in the frontend repository; it surfaced after build, and the
design changed three times, past the spec re-gate cap. Nothing in the kit
asked for that search. This release adds it.

## Changes

- **skills/1-intent: new probe "Existing analogous flow".** Before options
  exist, find flows that already make the same kind of user-visible
  transition, in every repository and tier the request crosses, and match
  the request's behavior words against them. The report names each flow with
  file:line and the roles it works for, or "none found" with the searches.
- **skills/1-intent: Reuse rule.** When such a flow exists, reusing it is one
  of the options shown to the human, with evidence; omitting it needs a
  reason. A "where do we store X / which new mechanism" question is restated
  as the user's transition first.
- **roles/researcher: step 1b and an "Analogous flows" report line.** The
  search is not narrowed to the mechanism named in the question.
- **roles/adversary: 4b Reuse.** A new mechanism proposed while a working
  flow for the same transition exists, with no stated reason, is blocking at
  the intent and spec gates.

No script, gate, or template format changed; existing records stay valid.
