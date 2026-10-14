// sdlc-kit adapter template — one PLAN.md scenario, two layers, tagged with its ID.
//   det:   npx e2e run --tag det --reporter json      (evidence; no model)
//   agent: npx e2e run --tag agent --strict-cache     (optional; replays without model calls)
import { describe, test } from '@e2e-dev/web';
import { expect } from 'e2e';

describe('S1 <persona> <behavior>', { session: 'user', tags: ['S1'] }, () => {
  test('det', { tags: ['det'] }, async ({ app, browser }) => {
    await app.open('/start');
    // Wait for something only the settled screen shows before any URL check: right after
    // open, toHaveURL can match the address the app is about to redirect away from.
    await expect(browser.locator('nav')).toBeVisible();
    await browser.locator('nav >> text=Reports').tap();
    await expect(browser).toHaveURL('/reports');
    // A request the change must (or must not) send: record it, then assert.
    const sent: string[] = [];
    await browser.route('**/api/audit-log', async (route) => {
      if (route.request.method === 'POST') sent.push(route.request.postData ?? '');
      await route.continue();
    });
    await browser.locator('text=Monthly').tap();
    await expect.poll(() => sent.length).toBeGreaterThan(0);
  });

  test('agent', { tags: ['agent'] }, async ({ app, agent, browser }) => {
    await app.open('/start');
    // Keep the act wording stable: it keys the replay recording.
    await agent.act('open the Reports page from the main menu');
    // A locator or URL check after the act is what records it for replay.
    await expect(browser).toHaveURL('/reports');
  });
});
