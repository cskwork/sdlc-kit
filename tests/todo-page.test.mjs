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
    for (const [foreground, background] of [['accent', 'highlight'], ['busy', 'busy-bg'], ['ok', 'ok-bg'], ['muted', 'open-bg'], ['bad', 'bad-bg'], ['busy', 'paper'], ['busy', 'highlight']]) {
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
      close() { this.open = false; this.listeners.close?.(); },
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
  assert.match(texts('bbbbbb'), /Agent working/);
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
