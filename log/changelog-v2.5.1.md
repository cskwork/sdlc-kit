# v2.5.1 — URL assertions wait for the settled screen

A negative control run after v2.5.0 found a false pass in the e2e adapter's
deterministic layer. Documentation and template only; no script change.

## Changes

- **URL checks after a redirect.** A test that opened `/a` and asserted
  `toHaveURL('/a')` passed, although the app redirects `/a` to `/b`: the
  assertion matched the address before the client-side redirect. The same
  assertion after waiting for a rendered element failed as it should, and
  the settled path was `/b`. `adapters/e2e/README.md` lists this under
  "Limits seen in use", and `templates/scenario.e2e.ts` waits for a settled
  element before its URL check. A test that expects the redirect target was
  unaffected: `toHaveURL` waits until it matches.
