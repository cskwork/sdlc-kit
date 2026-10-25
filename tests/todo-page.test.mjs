import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../todo/page/app.js', import.meta.url), 'utf8');

function page(hash = '', options = {}) {
  const nodes = new Map(), requests = [], streams = [];
  const node = id => {
    if (!nodes.has(id)) nodes.set(id, {
      dataset: {}, value: '', hidden: true, elements: [], children: [],
      attributes: {}, listeners: {}, classList: { contains() { return false; }, toggle() {}, add() {}, remove() {} },
      addEventListener(type, fn) { this.listeners[type] = fn; },
      focus() { context.document.activeElement = this; },
      showModal() { this.open = true; },
      close() { this.open = false; this.listeners.close?.(); },
      setAttribute(name, value) { this.attributes[name] = value; },
      append(...children) { this.children.push(...children); },
      replaceChildren(...children) { this.children = children; }
    });
    return nodes.get(id);
  };
  const location = new URL(`http://127.0.0.1:12345/${hash}`);
  const storage = () => {
    const values = new Map();
    return { getItem: key => values.get(key) ?? null,
      setItem: (key, value) => values.set(key, String(value)), removeItem: key => values.delete(key) };
  };
  let element = 0;
  const optionsHandler = options.fetch;
  const context = vm.createContext({
    document: { getElementById: node, addEventListener() {},
      createElement: () => node(`element-${++element}`),
      createElementNS: () => node(`element-${++element}`), createTextNode: text => ({ textContent: text }) },
    sessionStorage: storage(), localStorage: storage(),
    history: { replaceState(_state, _title, url) { location.href = new URL(url, location).href; } },
    location, URLSearchParams, setTimeout, clearTimeout, Node: class {},
    EventSource: class {
      constructor(url) { streams.push(url); }
      addEventListener() {}
    },
    fetch: async (url, options) => {
      requests.push({ url, options });
      if (optionsHandler) return optionsHandler(url, options);
      // Keep the initial load pending; this test exercises authentication, not DOM rendering.
      if (url === '/api/items') return new Promise(() => {});
      return { ok: true, text: async () => '{}' };
    }
  });
  vm.runInContext(options.source || source, context);
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

test('B1: pending delete confirmation submits the shown version even if the row is replaced', async () => {
  const p = page('#t=test-token');
  vm.runInContext(`
    const shown = { id: 'abcdef', title: 'Duplicate', version: 'shown-A' };
    const replacement = { id: 'abcdef', title: 'Duplicate', version: 'current-B' };
    const li = { dataset: { id: shown.id }, _item: shown };
    items = [shown];
    confirm = () => { items = [replacement]; li._item = replacement; return true; };
  `, p.context);
  await vm.runInContext('remove(li)', p.context);
  const body = JSON.parse(p.requests.find(r => r.url === '/api/item').options.body);
  assert.equal(body.id, 'abcdef');
  assert.equal(body.version, 'shown-A', 'confirmation must keep the item shown before the dialog');
});
test('B1: a changed-target response shows the server message and refreshes the snapshot', async () => {
  let loads = 0;
  const p = page('#t=test-token', { fetch: async url => {
    if (url === '/api/items') {
      if (++loads === 1) return new Promise(() => {});
      return { ok: true, text: async () => JSON.stringify({ items: [{ id: 'abcdef', version: 'current-B' }] }) };
    }
    return { ok: false, status: 409, text: async () => JSON.stringify({ error: 'This item changed. Reload and try again.' }) };
  } });
  vm.runInContext('apply = data => { items = data.items; return new Map(); };', p.context);
  await assert.rejects(vm.runInContext('mutate("/api/item", {id: "abcdef", version: "shown-A", op: "delete"})', p.context),
    /This item changed/);
  assert.equal(p.nodes.get('error-text').textContent, 'This item changed. Reload and try again.');
  assert.equal(p.nodes.get('error').hidden, false);
  assert.equal(loads, 2, '409 must reload current items');
  assert.equal(vm.runInContext('items[0].version', p.context), 'current-B');
});
test('N1: Done rows expose Details to audit their history', () => {
  const p = page();
  const row = vm.runInContext(`buildRow({ id: 'abcdef', done: true, title: 'Finished' })`, p.context);
  assert.equal(row._refs.open?.dataset.role, 'open', 'Done needs the same Details action as Open');
  assert.equal(row._refs.open?.textContent, 'Details');
});

test('B1: a reply draft keeps the version it was written for when a duplicate replaces the detail item', async () => {
  const p = page('#t=test-token');
  vm.runInContext(`detailId = 'abcdef'; items = [{ id: 'abcdef', version: 'shown-A' }];`, p.context);
  p.nodes.get('reply-text').value = 'Answer intended for A';
  p.nodes.get('reply-text').listeners.input();
  vm.runInContext(`items = [{ id: 'abcdef', version: 'current-B' }];`, p.context);
  await p.nodes.get('reply-form').listeners.submit({ preventDefault() {} });
  const body = JSON.parse(p.requests.find(r => r.url === '/api/item').options.body);
  assert.equal(body.version, 'shown-A', 'live details must not retarget a pending reply to B');
  assert.equal(body.text, 'Answer intended for A');
});

test('B1: approval sends the version of the item whose artifact was shown', async () => {
  const p = page('#t=test-token');
  vm.runInContext(`
    detailId = 'abcdef';
    artifact = { gate: 'intent', sha: 'a'.repeat(64), version: 'shown-A' };
    items = [{ id: 'abcdef', version: 'current-B' }];
  `, p.context);
  p.nodes.get('approve-words').value = 'Approve what I reviewed';
  await p.nodes.get('approve-form').listeners.submit({ preventDefault() {} });
  const body = JSON.parse(p.requests.find(r => r.url === '/api/approve').options.body);
  assert.equal(body.version, 'shown-A', 'approval binds the reviewed item as well as its artifact hash');
});


test('B1: an artifact response cannot replace the version of the item shown in Details', async () => {
  const p = page('#t=test-token', {
    // Stub only Markdown rendering; the real artifact request and item binding run in the VM.
    source: source.replace("await import('./markdown.js')", '({ renderMarkdown: text => text })'),
    fetch: async url => url === '/api/items' ? new Promise(() => {}) : {
      ok: true, text: async () => JSON.stringify({ gate: 'intent', markdown: '# Scope', sha: 'a'.repeat(64), version: 'server-B' })
    }
  });
  vm.runInContext(`detailId = 'abcdef'; items = [{ id: 'abcdef', version: 'shown-A' }];`, p.context);
  await vm.runInContext('loadArtifact()', p.context);
  assert.equal(vm.runInContext('artifact?.version', p.context), 'shown-A',
    'a concurrent target change during artifact loading must not grant a fresh version to stale Details');
});

for (const kind of ['reply', 'approve']) {
  for (const outcome of ['success', 'conflict', 'failure']) {
    test(`pending ${kind} ${outcome} keeps another item's Details draft and form`, async () => {
      let resolveRequest, loads = 0;
      const pending = new Promise(resolve => { resolveRequest = resolve; });
      const p = page('#t=test-token', { fetch: url => {
        if (url === (kind === 'reply' ? '/api/item' : '/api/approve')) return pending;
        if (url === '/api/items' && ++loads > 1) return { ok: true, text: async () => '{}' };
        return new Promise(() => {});
      } });
      vm.runInContext(`
        // Keep list rendering outside this dialog-handler regression.
        apply = () => new Map();
        items = ['aaaaaa', 'bbbbbb'].map(id => ({
          id, title: id, version: id + '-v1', status: 'workable', events: [], notes: []
        }));
        openDetail('aaaaaa');
        artifact = { gate: 'intent', sha: 'a'.repeat(64), version: 'aaaaaa-v1' };
      `, p.context);
      const field = p.nodes.get(kind === 'reply' ? 'reply-text' : 'approve-words');
      const draftKey = kind === 'reply' ? 'reply' : 'words';
      field.value = 'Draft for A';
      field.listeners.input();
      const submitted = p.nodes.get(`${kind}-form`).listeners.submit({ preventDefault() {} });
      const request = JSON.parse(p.requests.find(r => r.url === (kind === 'reply' ? '/api/item' : '/api/approve')).options.body);
      assert.equal(request.id, 'aaaaaa');
      p.nodes.get('detail-close').listeners.click();
      vm.runInContext(`
        openDetail('bbbbbb');
        artifact = { gate: 'intent', sha: 'b'.repeat(64), version: 'bbbbbb-v1' };
        $('decide').hidden = $('artifact-box').hidden = false;
        $('artifact-reload').hidden = true;
        $('approve-submit').disabled = false;
      `, p.context);
      field.value = 'Draft for B';
      field.listeners.input();
      field.focus();
      const count = p.nodes.get('approve-count').textContent;
      resolveRequest({
        ok: outcome === 'success', status: outcome === 'conflict' ? 409 : 500,
        text: async () => JSON.stringify(outcome === 'success' ? {} : { error: 'A request failed' })
      });
      await submitted;
      assert.equal(vm.runInContext(`draftFor('bbbbbb').${draftKey}`, p.context), 'Draft for B', 'B draft must survive A completion');
      assert.equal(field.value, 'Draft for B', 'B field must survive A completion');
      assert.equal(vm.runInContext(`draftFor('aaaaaa').${draftKey}`, p.context), outcome === 'success' ? '' : 'Draft for A');
      assert.equal(p.nodes.get('approve-count').textContent, count, 'B counter must stay unchanged');
      assert.equal(p.nodes.get(`${kind}-error`).hidden, true, 'A error must not appear on B');
      assert.equal(p.nodes.get('decide').hidden, false, 'B decision area must stay visible');
      assert.equal(p.nodes.get('artifact-box').hidden, false, 'B artifact must stay visible');
      assert.equal(p.nodes.get('artifact-reload').hidden, true, 'B must not offer to reload A');
      assert.equal(p.nodes.get('approve-submit').disabled, false, 'B approval must stay enabled');
      assert.equal(p.context.document.activeElement, field, 'A completion must not move focus on B');
    });
  }
}
