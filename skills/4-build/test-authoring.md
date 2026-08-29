# Test authoring

Read this reference only when the plan adds or changes browser E2E or a
source-analysis checker.

## Browser E2E

- Synchronize on an app-specific postcondition that distinguishes the new
  state from the old state. Use a condition-based wait with a bounded timeout.
  At a documented transient boundary, bound and record retries. Treat fixed
  delays as pacing, not readiness evidence.
- When an action should issue a request, correlate that request's result with
  the resulting UI state. For cached or client-only transitions, assert the
  distinguishing UI state directly.
- Start keyboard checks from the product's real entry state, preferably a
  fresh top-level navigation. If the harness needs a focus-reset helper,
  verify it in every supported browser and assert the observed focus sequence.
- Keep embedded scripts valid in the host language's string syntax. Prefer an
  external fixture when quoting makes a script hard to read or validate.

## Source-analysis checks

- Use an existing grammar-aware parser for the project language. Treat parse
  errors and mismatches as failures, and prove both paths with small fixtures.
  If a bounded scanner is unavoidable, document its accepted grammar and fail
  on unsupported syntax.
