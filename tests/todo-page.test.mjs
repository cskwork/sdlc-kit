import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../todo/page/app.js', import.meta.url), 'utf8');

function page(hash = '') {
  const nodes = new Map(), requests = [], streams = [];
  const node = id => {
    if (!nodes.has(id)) nodes.set(id, {
      dataset: {}, value: '', hidden: true, elements: [],
      addEventListener() {}, focus() {}
    });
    return nodes.get(id);
  };
  const location = Object.freeze({ hash, pathname: '/', search: '' });
  const context = vm.createContext({
    document: { getElementById: node, addEventListener() {} },
    location, URLSearchParams, setTimeout, clearTimeout,
    EventSource: class {
      constructor(url) { streams.push(url); }
      addEventListener() {}
    },
    fetch: async (url, options) => {
      requests.push({ url, options });
      // Keep the initial load pending; this test exercises authentication, not DOM rendering.
      if (url === '/api/items') return new Promise(() => {});
      return { ok: true, text: async () => '{}' };
    }
  });
  vm.runInContext(source, context);
  return { context, nodes, requests, streams, location };
}

test('B4: the page never uses Web Storage or cookies', () => {
  assert.equal(/\b(?:sessionStorage|localStorage)\b|\bcookie(?:Store)?\b/i.test(source), false,
    'app.js must not use browser storage or cookies');
});

test('B4: fragment token stays in the URL and authenticates requests and live updates after reload', async () => {
  const hash = '#t=0123456789abcdef0123456789abcdef&id=abcdef';
  for (let reload = 0; reload < 2; reload++) {
    const p = page(hash);
    await vm.runInContext('api("/api/probe", {text: "New item"})', p.context);
    const request = p.requests.find(r => r.url === '/api/probe');
    assert.equal(request.options.headers['X-Todo-Token'], '0123456789abcdef0123456789abcdef');
    assert.equal(request.options.headers['Content-Type'], 'application/json');
    assert.equal(p.streams[0], '/events?t=0123456789abcdef0123456789abcdef');
    assert.equal(p.location.hash, hash);
  }
});

test('B4: a page without a token explains how to open it without making requests', () => {
  const p = page();
  assert.equal(p.nodes.get('error-text').textContent,
    'Open the link printed in your terminal (or press w in the TUI)');
  assert.equal(p.nodes.get('error').hidden, false);
  assert.equal(p.requests.length, 0);
  assert.equal(p.streams.length, 0);
});
