// sdlc-kit adapter template — restore a sign-in that config `qa_session:` captured
// (popup, SSO or device flows the runner cannot drive), then save it as a named session.
import { readFileSync } from 'node:fs';
import { test } from '@e2e-dev/web';
import { expect } from 'e2e';

// Written by the qa_session command: { "localStorage": {...}, "sessionStorage": {...} }
const STATE_FILE = process.env.QA_SESSION_FILE ?? '.auth/session.json';

test.setup('signed-in session', { sessions: ['user'] }, async ({ app, browser, session }) => {
  const state = JSON.parse(readFileSync(STATE_FILE, 'utf8')) as {
    localStorage?: Record<string, string>;
    sessionStorage?: Record<string, string>;
  };
  await app.open('/');
  await browser.evaluate((s: typeof state) => {
    for (const [k, v] of Object.entries(s.localStorage ?? {})) localStorage.setItem(k, v);
    for (const [k, v] of Object.entries(s.sessionStorage ?? {})) sessionStorage.setItem(k, v);
    return true;
  }, state);
  await app.open('/'); // reload signed in
  // Assert a signed-in element before saving; session.save does not check it.
  await expect(browser.locator('[data-signed-in], nav')).toBeVisible();
  await session.save('user');
});
