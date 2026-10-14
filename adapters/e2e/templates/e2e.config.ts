// sdlc-kit adapter template — fill APP_URL and, for agent steps, a model.
import type { E2EConfig } from 'e2e';
import { web } from '@e2e-dev/web';
// Agent steps only. A subscription login made once by the human, e.g.:
//   npx e2e login openai   then   import { chatgpt } from 'e2e/oauth/chatgpt';
// import { chatgpt } from 'e2e/oauth/chatgpt';

const APP_URL = process.env.APP_URL ?? 'http://localhost:3000';

export default {
  targets: [
    {
      name: 'web',
      engine: web(),
      // A fixed identity keeps replay recordings valid when the host changes (dev, staging).
      app: { url: APP_URL, identity: 'my-app' },
    },
  ],
  // agents: { default: { model: chatgpt('<model from `npx e2e models openai`>'), context: 'Read-only QA: never create, submit or delete data.' } },
  workers: 1, // one signed-in account shared by every test
  retries: 0,
  cache: { mode: 'read-write', dir: '.e2e/cache' },
  reporters: ['list'],
} satisfies E2EConfig;
