// To-do page. Rows are patched by id so drafts, focus and scroll survive live updates.
import { defaultLanguage, isLanguage, languages, locales, phaseLabel, translator } from './i18n.mjs';
import { countsOf, queueOf, statusOf } from './status.mjs';
const $ = id => document.getElementById(id);
const el = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};

// ---------- language ----------
// The server's language applies until the person picks one; the choice lasts until reload.
let lang = defaultLanguage, t = translator(lang), langChosen = false;
// A message is raw text (server or file) or { key, vars } translated whenever it is shown.
const say = message => typeof message === 'string' ? message : t(message.key,
  Object.fromEntries(Object.entries(message.vars || {}).map(([name, value]) => [name, value && typeof value === 'object' ? say(value) : value])));
const sourceOf = error => error.source ?? error.message;
function show(node, message) { node._message = message; node.textContent = say(message); }
function setLanguage(next) {
  lang = next;
  t = translator(lang);
  document.documentElement.lang = lang;
  $('lang').value = lang;
  for (const node of document.querySelectorAll('[data-i18n]')) node.textContent = t(node.dataset.i18n);
  for (const node of document.querySelectorAll('[data-i18n-label]')) node.setAttribute('aria-label', t(node.dataset.i18nLabel));
  for (const node of document.querySelectorAll('[data-i18n-placeholder]')) node.placeholder = t(node.dataset.i18nPlaceholder);
  const shown = ['error-text', 'approve-error', 'reply-error', 'live-text', 'artifact-title', 'approve-submit', 'approve-help'].map($);
  for (const node of [...shown, ...$('artifact').children]) if (node._message) node.textContent = say(node._message);
  detailVersion = '';
}

// Token stays in page memory. Keep the terminal's fragment so a reload can read it again.
let openOnLoad = '';
let token = '';
{
  const hash = location.hash.slice(1);
  const params = new URLSearchParams(hash.includes('=') ? hash : '');
  token = params.get('t') || '';
  if (!hash.includes('=') && /^[0-9a-f]{6}(?:-\d+)?$/.test(hash)) openOnLoad = hash;
  if (params.get('id')) openOnLoad = params.get('id');
}

let items = [], file = '';
let seenSnapshot = false, changedAt = null;
const drafts = new Map(); // item id -> {reply, words}

// ---------- server ----------
class RequestError extends Error {
  constructor(source, status) { super(say(source)); this.source = source; this.status = status; }
}
async function api(path, body) {
  let response;
  try {
    response = await fetch(path, {
      method: body ? 'POST' : 'GET',
      headers: body ? { 'X-Todo-Token': token, 'Content-Type': 'application/json' } : { 'X-Todo-Token': token },
      body: body ? JSON.stringify(body) : undefined,
      cache: 'no-store'
    });
  } catch {
    throw new RequestError({ key: 'error.unreachable' }, 0);
  }
  const text = await response.text();
  if (!response.ok) {
    let message = text.trim();
    try { const data = JSON.parse(text); message = data.error || data.message || message; } catch { /* plain text */ }
    if (response.status === 403) message = { key: 'error.forbidden' };
    if (response.status === 409 && body) {
      try { received(await api('/api/items')); } catch { /* keep the mutation's error */ }
    }
    throw new RequestError(message || { key: 'error.failed', vars: { status: response.status } }, response.status);
  }
  return text ? JSON.parse(text) : {};
}
async function mutate(path, body, done) {
  try {
    const data = await api(path, body);
    if (data.items) apply(data);
    if (done) announce(done);
    return data;
  } catch (error) {
    showError(sourceOf(error));
    throw error;
  }
}

// ---------- messages ----------
let announceTimer;
function announce(text) {
  const box = $('announce');
  box.textContent = '';
  clearTimeout(announceTimer);
  announceTimer = setTimeout(() => { box.textContent = text; }, 50);
}
function showError(message) {
  show($('error-text'), message);
  $('error').hidden = false;
}
$('error-dismiss').addEventListener('click', () => { $('error').hidden = true; $('add-text').focus(); });

// ---------- words shown to people ----------
const basename = project => project.replace(/[\\/]+$/, '').split(/[\\/]/).pop() || project;
// What the person is asked to do: the explicit wait, the gate, else the sdlc question.
function whatWaits(item) {
  const status = statusOf(item);
  return item.waiting || (status.gate ? t(`next.${status.kind}`) : item.sdlc?.action || t(`next.${status.kind}`));
}
// Colour tone of a status pill, row bar and check ring: amber you, blue agent, grey not started.
const tones = { you: 'wait', agent: 'busy', blocked: 'blocked', done: 'ok' };
const toneOf = status => status.kind === 'new' ? 'open' : tones[status.actor];
const pill = item => { const status = statusOf(item); return chip(t(`status.${status.kind}`), `badge ${toneOf(status)}`); };
function doneAt(item) {
  const last = [...item.events].reverse().find(e => /^(done|DONE)\b/.test(e.what));
  return last ? last.at : '';
}

// ---------- rows ----------
const rows = new Map(); // id -> li
let queue = queueOf([]);

function button(label, role, text) {
  const b = el('button', 'icon', text);
  b.type = 'button';
  b.dataset.role = role;
  b.setAttribute('aria-label', label);
  return b;
}
function buildRow(item) {
  const li = el('li', 'row');
  li.dataset.id = item.id;
  li.tabIndex = 0;
  const check = el('input', 'check');
  check.type = 'checkbox';
  check.dataset.role = 'check';
  const main = el('div', 'main');
  const title = el('span', 'title');
  if (!item.done) {
    title.tabIndex = 0;
    title.dataset.role = 'title';
    title.setAttribute('role', 'button');
  }
  const info = el('div', 'info');
  main.append(title, info);
  li.append(check, main);
  const refs = { check, title, info, sig: '' };
  if (!item.done) {
    refs.waitLine = el('div', 'wait-line');
    refs.waitLabel = el('span', 'wait-label');
    refs.waitWhat = el('span');
    refs.review = button('', 'review');
    refs.review.className = 'text-button';
    refs.waitLine.append(refs.waitLabel, refs.waitWhat, refs.review);
    main.append(refs.waitLine);
  }
  const tools = el('div', 'tools');
  tools.id = `tools-${item.id}`;
  refs.more = button('', 'more', '⋯');
  refs.more.className = 'more icon';
  const dots = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  dots.setAttribute('viewBox', '0 0 20 20');
  dots.setAttribute('aria-hidden', 'true');
  for (const x of [4, 10, 16]) {
    const dot = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
    dot.setAttribute('cx', x); dot.setAttribute('cy', '10'); dot.setAttribute('r', '1.5');
    dots.append(dot);
  }
  refs.more.replaceChildren(dots);
  refs.more.setAttribute('aria-expanded', 'false');
  refs.more.setAttribute('aria-controls', tools.id);
  refs.open = button('', 'open', t('row.details'));
  refs.open.className = 'quiet';
  tools.append(refs.open);
  if (!item.done) {
    refs.up = button('', 'up', '↑');
    refs.down = button('', 'down', '↓');
    refs.del = button('', 'delete', '✕');
    tools.append(refs.up, refs.down, refs.del);
  } else {
    refs.when = el('span', 'when');
    main.append(refs.when);
  }
  li.append(refs.more, tools);
  li._refs = refs;
  return li;
}
function chip(text, className = 'chip') { return el('span', className, text); }
function updateRow(li, item) {
  const r = li._refs;
  li._item = item;
  if (!li.classList.contains('editing') && r.title.textContent !== item.title) r.title.textContent = item.title;
  r.check.checked = item.done;
  const title = item.title, status = statusOf(item);
  r.check.setAttribute('aria-label', t(item.done ? 'row.markOpen' : 'row.markDone', { title }));
  if (!item.done) r.title.setAttribute('aria-label', t('row.rename', { title }));
  if (r.when) r.when.textContent = doneAt(item) ? t('row.doneAt', { at: doneAt(item) }) : '';
  r.open.textContent = t('row.details');
  r.open.setAttribute('aria-label', t('row.detailsFor', { title }));
  r.more.setAttribute('aria-label', t('row.actionsFor', { title }));
  const stop = item.id === queue.stop?.id;
  if (r.waitLine) {
    li.classList.toggle('needs-you', stop && status.actor === 'you');
    // Your-turn rows name their action; the row where agents stop says so.
    const yours = status.actor === 'you';
    r.waitLine.hidden = !yours && !stop;
    r.waitLabel.hidden = !stop;
    r.waitLabel.dataset.actor = status.actor;
    r.waitLabel.textContent = stop ? t(`stop.${status.actor}`) : '';
    r.waitWhat.textContent = yours ? item.waiting || (status.gate ? '' : item.sdlc?.action || '') : '';
    r.waitWhat.hidden = !r.waitWhat.textContent;
    r.review.hidden = !yours;
    r.review.textContent = yours ? t(`action.${status.kind}`) : '';
    r.review.setAttribute('aria-label', yours ? t('row.actionFor', { action: t(`action.${status.kind}`), title }) : '');
    r.up.setAttribute('aria-label', t('row.up', { title }));
    r.down.setAttribute('aria-label', t('row.down', { title }));
    r.del.setAttribute('aria-label', t('row.delete', { title }));
  }
  li.dataset.status = item.status;
  li.dataset.tone = toneOf(status);
  const queued = queue.queued.has(item.id) ? queue.stop.status === 'blocked' ? 'row.queuedFix' : 'row.queued' : '';
  // Rebuild the small info line only when it changed, so a focused link keeps focus.
  const sig = JSON.stringify([lang, status.kind, queued, item.project, item.link, item.sdlc?.phase, item.error, item.sdlc?.action, item.done]);
  if (sig === r.sig) return;
  r.sig = sig;
  const parts = [];
  if (!item.done) {
    parts.push(pill(item));
    if (status.actor === 'blocked') parts.push(chip(item.error || item.sdlc?.action || t('row.unknownError'), 'row-error'));
    if (queued) parts.push(chip(t(queued), 'chip queued'));
  }
  if (item.project) { const c = chip(basename(item.project)); c.title = item.project; parts.push(c); }
  if (item.link && /^https?:\/\//i.test(item.link.url)) {
    const a = el('a', 'chip link', item.link.label);
    a.href = item.link.url;
    a.target = '_blank';
    a.rel = 'noopener noreferrer';
    a.setAttribute('aria-label', t('row.newTab', { label: item.link.label }));
    parts.push(a);
  }
  if (item.sdlc?.phase && !item.done) parts.push(chip(phaseLabel(t, item.sdlc.phase)));
  r.info.replaceChildren(...parts);
  r.info.hidden = !parts.length;
}

// Where focus was, so it can land somewhere sensible if its row goes away.
function focusInfo() {
  const active = document.activeElement;
  const li = active?.closest?.('li.row');
  if (!li) return null;
  const list = li.parentElement;
  return { list, id: li.dataset.id, index: [...list.children].indexOf(li), role: active.dataset.role || '' };
}
function restoreFocus(info) {
  if (!info) return;
  const active = document.activeElement;
  if (active && active !== document.body && active.isConnected) return;
  const same = rows.get(info.id);
  const target = same && same.parentElement === info.list ? same : info.list.children[Math.min(info.index, info.list.children.length - 1)];
  const node = target && (target.querySelector(`[data-role="${info.role}"]`) || target.querySelector('[data-role="check"]'));
  (node || $('add-text')).focus({ preventScroll: true });
}
function patchList(list, wanted) {
  const want = wanted.map(item => {
    let li = rows.get(item.id);
    if (li && li.parentElement !== list) { li.remove(); rows.delete(item.id); li = null; }
    if (!li) { li = buildRow(item); rows.set(item.id, li); }
    updateRow(li, item);
    return li;
  });
  const keep = new Set(want);
  for (const li of [...list.children]) if (!keep.has(li)) { rows.delete(li.dataset.id); li.remove(); }
  want.forEach((li, i) => { if (list.children[i] !== li) list.insertBefore(li, list.children[i] || null); });
}

function apply(data) {
  if (!langChosen && isLanguage(data.lang) && data.lang !== lang) setLanguage(data.lang);
  const before = new Map(items.map(i => [i.id, i]));
  items = Array.isArray(data.items) ? data.items : [];
  file = data.file || file;
  const open = items.filter(i => !i.done), done = items.filter(i => i.done);
  queue = queueOf(items);

  const focus = focusInfo(), active = document.activeElement, x = scrollX, y = scrollY;
  const selection = active?.matches('input.edit') ? [active.selectionStart, active.selectionEnd] : null;
  patchList($('open'), open);
  patchList($('done'), done);
  if (active && active !== document.body && active.isConnected && active.getClientRects().length) {
    active.focus({ preventScroll: true });
    if (selection) active.setSelectionRange(...selection);
  } else restoreFocus(focus);
  if (scrollX !== x || scrollY !== y) scrollTo(x, y);

  $('counts').textContent = t('page.counts', countsOf(items));
  $('empty').hidden = open.length > 0;
  $('done-box').hidden = done.length === 0;
  $('done-count').textContent = String(done.length);
  $('file').textContent = file ? t('page.saved', { file }) : '';
  const lastChange = items.flatMap(item => item.events).map(event => event.at).sort().at(-1);
  // The API has event times but no file mtime; observe subsequent edits, moves and deletions here.
  if (!seenSnapshot) changedAt = lastChange ? new Date(lastChange.replace(' ', 'T')) : null;
  else if (JSON.stringify([...before.values()]) !== JSON.stringify(items)) changedAt = new Date();
  seenSnapshot = true;
  const changed = $('changed');
  changed.hidden = !changedAt;
  if (changedAt) {
    if (!Number.isNaN(changedAt.getTime())) {
      changed.dateTime = changedAt.toISOString();
      changed.textContent = new Intl.DateTimeFormat(lang, { dateStyle: 'long', timeStyle: 'short' }).format(changedAt);
    } else changed.hidden = true;
  }
  syncPane();
  if (detailId) renderDetail();
  return before;
}

// Brief, polite summary of changes made elsewhere (terminal, editor, agent).
function describeChange(before) {
  const now = new Map(items.map(i => [i.id, i]));
  const added = items.filter(i => !before.has(i.id)).length;
  const removed = [...before.keys()].filter(id => !now.has(id)).length;
  const newlyWaiting = items.filter(i => i.status === 'waiting' && before.get(i.id)?.status !== 'waiting' && before.has(i.id));
  if (newlyWaiting.length) return t('announce.needsYou', { title: newlyWaiting[0].title });
  if (added && !removed) return t('announce.addedCount', { count: added });
  if (removed && !added) return t('announce.removedCount', { count: removed });
  return JSON.stringify([...before.values()]) === JSON.stringify(items) ? '' : t('announce.updated');
}

// ---------- row actions ----------
const op = (item, name, extra, done) => mutate('/api/item', { id: item.id, version: item.version, op: name, ...extra }, done);

function rowOf(node) { return node.closest('li.row'); }
async function move(li, delta) {
  try { await op(li._item, 'move', { delta }, t(delta < 0 ? 'announce.movedUp' : 'announce.movedDown')); } catch { /* shown */ }
}
async function remove(li) {
  const item = li._item;
  if (!confirm(t('row.confirmDelete', { title: item.title }))) return;
  try { await op(item, 'delete', {}, t('announce.deleted', { title: item.title })); } catch { /* shown */ }
}

function startEdit(li) {
  if (li.classList.contains('editing') || li._item.done) return;
  const r = li._refs, item = li._item;
  const input = el('input', 'edit');
  input.type = 'text';
  input.value = li._item.title;
  input.dataset.role = 'title';
  input.setAttribute('aria-label', t('row.renameInput', { title: li._item.title }));
  li.classList.add('editing');
  r.title.hidden = true;
  r.title.after(input);
  input.focus();
  input.select();
  let finished = false;
  const finish = async save => {
    if (finished) return;
    finished = true;
    const value = input.value.trim(), oldTitle = item.title;
    const restore = () => { li.classList.remove('editing'); r.title.hidden = false; input.remove(); };
    if (!save || !value || value === oldTitle) {
      restore();
      if (li.isConnected) r.title.focus();
      return;
    }
    // Ids follow the title for items without a slug, so the row may come back under a new id.
    const index = [...li.parentElement.children].indexOf(li);
    try {
      await op(item, 'edit', { title: value }, t('announce.renamed'));
    } catch {
      finished = false;
      input.focus();
      return;
    }
    if (li.isConnected) { restore(); r.title.textContent = value; r.title.focus(); return; }
    const next = $('open').children[index];
    (next?.querySelector('[data-role="title"]') || $('add-text')).focus();
  };
  input.addEventListener('keydown', event => {
    if (event.key === 'Enter') { event.preventDefault(); finish(true); }
    else if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); finish(false); }
  });
  // Only Enter commits: moving a live row can blur its editor without a human decision.
}

function wireList(list) {
  list.addEventListener('change', event => {
    if (event.target.dataset.role !== 'check') return;
    const li = rowOf(event.target), item = li._item;
    const wantDone = event.target.checked;
    event.target.checked = item.done; // the server decides; the next list sets it
    op(item, wantDone ? 'done' : 'undone', {}, t(wantDone ? 'announce.done' : 'announce.reopened', { title: item.title })).catch(() => {});
  });
  list.addEventListener('click', event => {
    const target = event.target.closest('[data-role]');
    // Anywhere else on a row, including its title, shows it in the side pane; links and the rename box keep their own job.
    if (!target || target.dataset.role === 'title') {
      const li = event.target.closest('li.row');
      if (li && isWide && !event.target.closest('a, input')) openDetail(li.dataset.id, li, event.detail === 0);
      return;
    }
    const li = rowOf(target);
    const role = target.dataset.role;
    if (role === 'open' || role === 'review') openDetail(li.dataset.id, target);
    else if (role === 'more') {
      const expanded = li.classList.toggle('actions-open');
      target.setAttribute('aria-expanded', String(expanded));
    }
    else if (role === 'up') move(li, -1);
    else if (role === 'down') move(li, 1);
    else if (role === 'delete') remove(li);
  });
  list.addEventListener('dblclick', event => {
    if (event.target.dataset.role === 'title' && event.target.tagName === 'SPAN') startEdit(rowOf(event.target));
  });
  list.addEventListener('keydown', event => {
    const li = rowOf(event.target);
    if (!li) return;
    if (event.target === li && (event.key === 'Enter' || event.key === ' ')) {
      event.preventDefault();
      openDetail(li.dataset.id, li);
      return;
    }
    if (li._item.done) return;
    if (event.key === 'Escape' && li.classList.contains('actions-open') && !li.classList.contains('editing')) {
      li.classList.remove('actions-open');
      li._refs.more.setAttribute('aria-expanded', 'false');
      li._refs.more.focus();
    } else if (event.altKey && (event.key === 'ArrowUp' || event.key === 'ArrowDown') && !li.classList.contains('editing')) {
      event.preventDefault();
      move(li, event.key === 'ArrowUp' ? -1 : 1);
    } else if ((event.key === 'Enter' || event.key === ' ') && event.target.tagName === 'SPAN' && event.target.dataset.role === 'title') {
      event.preventDefault();
      startEdit(li);
    }
  });
}
wireList($('open'));
wireList($('done'));

// ---------- add ----------
const addText = $('add-text');
let adding = false;
$('add').addEventListener('submit', async event => {
  event.preventDefault();
  const text = addText.value.trim();
  if (!text || adding) return;
  adding = true;
  try {
    await mutate('/api/items', { text }, t('announce.added'));
    if (addText.value.trim() === text) addText.value = '';
  } catch { /* draft stays */ }
  finally { adding = false; }
  addText.focus();
});
document.addEventListener('keydown', event => {
  if ((event.key !== '/' && event.key !== 'n') || event.altKey || event.ctrlKey || event.metaKey) return;
  const t = event.target;
  if (($('detail').open && !isWide) || t.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT'].includes(t.tagName)) return;
  event.preventDefault();
  addText.focus();
});

// ---------- detail ----------
// One <dialog>: a modal on narrow screens, a persistent side pane beside the list on wide ones.
const dialog = $('detail');
const wideQuery = matchMedia('(min-width: 1100px)');
let isWide = wideQuery.matches, quietClose = false;
// detailId is what the dialog shows ('' when closed); selectedId is the row chosen for the pane.
let detailId = '', selectedId = '', opener = null, artifact = null, artifactRequest = 0, detailVersion = '';

function draftFor(id) { if (!drafts.has(id)) drafts.set(id, { reply: '', words: '' }); return drafts.get(id); }
function openDetail(id, from, focus = true) {
  const item = items.find(i => i.id === id);
  if (!item) return;
  selectedId = id;
  delete dialog.dataset.empty;
  if (id !== detailId || !dialog.open) {
    detailId = id;
    detailVersion = '';
    artifact = null;
    const d = draftFor(id);
    $('reply-text').value = d.reply;
    $('approve-words').value = d.words;
    $('reply-error').hidden = $('approve-error').hidden = true;
    $('artifact-box').hidden = $('decide').hidden = true;
    updateCount();
    renderDetail();
    // Every open sdlc item shows its work document; only an approval gate adds the decision form.
    if (!item.done && item.sdlc) loadArtifact();
  }
  opener = from || document.activeElement;
  if (!dialog.open) { if (isWide) showPane(); else dialog.showModal(); }
  markSelected();
  if (focus) $('detail-title').focus();
}
// show() runs the dialog focusing steps; a pane opened by a live update must not take focus.
function showPane() {
  const keep = document.activeElement;
  dialog.show();
  if (keep && keep !== document.body && keep.isConnected) keep.focus({ preventScroll: true });
  else document.activeElement?.blur?.();
}
function markSelected() {
  for (const [id, li] of rows) li.setAttribute('aria-current', String(isWide && id === selectedId));
}
// Wide screens always show an item: the chosen one, else where agents stop, else the first open one.
function paneTarget() {
  if (items.some(i => i.id === selectedId)) return selectedId;
  return queue.stop?.id || items.find(i => !i.done)?.id || '';
}
function syncPane() {
  if (!isWide) return markSelected();
  const id = paneTarget();
  if (id) { if (id !== detailId || !dialog.open) openDetail(id, null, false); return; }
  selectedId = detailId = '';
  dialog.dataset.empty = 'true';
  if (!dialog.open) showPane();
  markSelected();
}
function closeQuietly() {
  if (!dialog.open) return;
  const inside = dialog.contains?.(document.activeElement);
  quietClose = true;
  dialog.close();
  quietClose = false;
  if (inside) (rows.get(selectedId) || addText).focus({ preventScroll: true });
}
// Crossing the breakpoint never leaves a modal over the panes; the selection is kept.
wideQuery.addEventListener('change', () => {
  isWide = wideQuery.matches;
  closeQuietly();
  syncPane();
});
function field(dl, name, value) {
  if (!value) return;
  const dt = el('dt', '', name), dd = el('dd');
  if (value instanceof Node) dd.append(value); else dd.textContent = value;
  dl.append(dt, dd);
}
function renderDetail() {
  const item = items.find(i => i.id === detailId);
  const version = JSON.stringify(item);
  if (version === detailVersion) return;
  detailVersion = version;
  $('detail-gone').hidden = !!item;
  for (const form of [$('approve-form'), $('reply-form')]) for (const c of form.elements) c.disabled = !item;
  if (!item) {
    artifact = null;
    $('artifact-box').hidden = $('decide').hidden = true;
    return;
  }
  $('approve-submit').disabled = !artifact;
  $('detail-title').textContent = item.title;
  const dl = $('detail-fields');
  dl.replaceChildren();
  const actor = statusOf(item).actor;
  field(dl, t('field.status'), pill(item));
  if (actor === 'you') field(dl, t('field.next'), whatWaits(item));
  if (actor === 'blocked') field(dl, t('field.problem'), item.error || item.sdlc?.action || t('field.unknown'));
  field(dl, t('field.project'), item.project);
  if (item.link && /^https?:\/\//i.test(item.link.url)) {
    const a = el('a', '', item.link.label);
    a.href = item.link.url; a.target = '_blank'; a.rel = 'noopener noreferrer';
    field(dl, t('field.link'), a);
  }
  if (item.sdlc) field(dl, t('field.work'), `${item.sdlc.slug}${item.sdlc.phase ? ` · ${phaseLabel(t, item.sdlc.phase)}` : ''}`);
  $('reply-box').hidden = item.done;
  const history = $('history');
  history.replaceChildren(...item.events.map(e => {
    const li = el('li');
    li.append(el('time', '', e.at), document.createTextNode(` · ${e.who} · ${e.what}`));
    return li;
  }));
  if (!item.events.length) history.append(el('li', 'hint', t('history.empty')));
  $('notes-box').hidden = !item.notes.length;
  $('notes').textContent = item.notes.map(n => n.trim()).join('\n');
}
async function loadArtifact() {
  const id = detailId, version = items.find(item => item.id === id)?.version, request = ++artifactRequest;
  artifact = null;
  $('decide').hidden = true;
  $('approve-submit').disabled = true;
  $('approve-error').hidden = true;
  $('artifact-reload').hidden = true;
  // The document can take seconds (the server syncs with sdlc first); say so instead of showing nothing.
  $('artifact-box').hidden = false;
  show($('artifact-title'), { key: 'artifact.document' });
  $('artifact-file').textContent = '';
  const loading = el('p', 'hint');
  show(loading, { key: 'artifact.loading' });
  $('artifact').replaceChildren(loading);
  try {
    const data = await api(`/api/artifact?id=${encodeURIComponent(id)}`);
    if (id !== detailId || request !== artifactRequest) return;
    $('artifact-box').hidden = false;
    show($('artifact-title'), { key: data.gate ? 'artifact.approve' : 'artifact.document' });
    const { renderMarkdown } = await import('./markdown.js');
    const rendered = renderMarkdown(data.markdown || '');
    if (id !== detailId || request !== artifactRequest) return;
    // The renderer escapes all HTML first; this is the page's only innerHTML.
    $('artifact').innerHTML = rendered;
    $('artifact-file').textContent = data.file || '';
    if (!data.gate) return;
    artifact = { ...data, version };
    $('decide').hidden = false;
    $('approve-submit').disabled = false;
    show($('approve-submit'), { key: `decide.approve-${artifact.gate}` });
    show($('approve-help'), { key: `decide.help-${artifact.gate}`, vars: { version: artifact.sha.slice(0, 12) } });
  } catch (error) {
    if (id !== detailId || request !== artifactRequest) return;
    artifact = null;
    $('decide').hidden = true;
    $('approve-submit').disabled = true;
    $('artifact-box').hidden = false;
    $('artifact-reload').hidden = false;
    show($('artifact-title'), { key: 'artifact.document' });
    $('artifact-file').textContent = '';
    const failed = el('p', 'field-error');
    show(failed, { key: 'artifact.failed', vars: { message: sourceOf(error) } });
    $('artifact').replaceChildren(failed);
  }
}
// Text size of Details only; kept in memory because the page never uses Web Storage.
let textScale = 1;
function scaleText(step) {
  textScale = Math.min(1.6, Math.max(0.8, Math.round((textScale + step) * 10) / 10));
  dialog.style.setProperty('--detail-scale', textScale);
  $('text-smaller').disabled = textScale <= 0.8;
  $('text-larger').disabled = textScale >= 1.6;
  announce(t('announce.textSize', { percent: Math.round(textScale * 100) }));
}
$('text-smaller').addEventListener('click', () => scaleText(-0.1));
$('text-larger').addEventListener('click', () => scaleText(0.1));
function updateCount() { $('approve-count').textContent = `${$('approve-words').value.trim().length} / 500`; }
$('approve-words').addEventListener('input', () => { draftFor(detailId).words = $('approve-words').value; updateCount(); });
$('reply-text').addEventListener('input', () => {
  const draft = draftFor(detailId);
  if (!draft.reply) draft.replyVersion = items.find(item => item.id === detailId)?.version;
  draft.reply = $('reply-text').value;
});
$('artifact-reload').addEventListener('click', () => loadArtifact().then(() => $('artifact-title').focus()));
$('artifact-title').tabIndex = -1;

$('approve-form').addEventListener('submit', async event => {
  event.preventDefault();
  const words = $('approve-words').value.trim();
  const error = $('approve-error');
  error.hidden = true;
  if (!artifact) return;
  if (words.length > 500) {
    show(error, { key: 'decide.length' });
    error.hidden = false;
    $('approve-words').focus();
    return;
  }
  const id = detailId, draft = draftFor(id);
  try {
    const data = await api('/api/approve', { id, version: artifact.version, gate: artifact.gate, sha: artifact.sha, words });
    draft.words = '';
    if (detailId === id) {
      $('approve-words').value = '';
      updateCount();
    }
    if (data.items) apply(data);
    announce(t('announce.approved'));
    if (detailId === id) {
      $('decide').hidden = $('artifact-box').hidden = true;
      $('detail-title').focus();
    }
  } catch (failure) {
    if (detailId !== id) return;
    show(error, failure.status === 409 ? { key: 'decide.conflict', vars: { message: sourceOf(failure) } } : sourceOf(failure));
    error.hidden = false;
    $('artifact-reload').hidden = failure.status !== 409;
    if (failure.status === 409) $('approve-submit').disabled = true;
    (failure.status === 409 ? $('artifact-reload') : $('approve-words')).focus();
  }
});
$('reply-form').addEventListener('submit', async event => {
  event.preventDefault();
  const text = $('reply-text').value.trim();
  const error = $('reply-error');
  error.hidden = true;
  if (!text) { show(error, { key: 'reply.empty' }); error.hidden = false; $('reply-text').focus(); return; }
  const id = detailId, draft = draftFor(id);
  try {
    const data = await api('/api/item', { id, version: draft.replyVersion, op: 'reply', text });
    draft.reply = '';
    if (detailId === id) $('reply-text').value = '';
    if (data.items) apply(data);
    announce(t('announce.replied'));
  } catch (failure) {
    if (detailId !== id) return;
    show(error, sourceOf(failure));
    error.hidden = false;
    $('reply-text').focus();
  }
});
$('detail-close').addEventListener('click', () => dialog.close());
dialog.addEventListener('close', () => {
  const id = detailId;
  detailId = '';
  if (quietClose) return;
  const row = rows.get(id);
  // Mobile row tools hide while the dialog has focus; reveal them before restoring the opener.
  if (opener?.isConnected && !opener.getClientRects().length) row?.focus({ preventScroll: true });
  const target = opener?.isConnected && opener.getClientRects().length ? opener
    : row?.isConnected && row.getClientRects().length ? row : addText;
  target.focus({ preventScroll: true });
});

// ---------- live updates ----------
function setLive(state, key) {
  $('live').dataset.state = state;
  show($('live-text'), { key });
}
let source = null, retry = 0, retryTimer, firstLoad = true;
function received(data) {
  const before = apply(data);
  if (firstLoad) {
    firstLoad = false;
    if (openOnLoad && items.some(i => i.id === openOnLoad)) openDetail(openOnLoad, addText);
    return;
  }
  const text = describeChange(before);
  if (text) announce(text);
}
function connect() {
  clearTimeout(retryTimer);
  source?.close();
  source = new EventSource(`/events?t=${encodeURIComponent(token)}`);
  source.addEventListener('open', () => { retry = 0; setLive('live', 'live.live'); $('error').hidden = true; });
  source.addEventListener('message', event => {
    try { received(JSON.parse(event.data)); } catch { /* ignore a malformed message */ }
  });
  source.addEventListener('error', () => {
    setLive('retry', 'live.retry');
    source.close();
    // Reconnect with capped backoff while the server or network is unavailable.
    const wait = Math.min(30000, 1000 * 2 ** retry++);
    retryTimer = setTimeout(async () => {
      try { received(await api('/api/items')); }
      catch (error) { if (error.status === 403) { setLive('off', 'live.denied'); showError(sourceOf(error)); return; } }
      connect();
    }, wait);
  });
}

// ---------- language switcher ----------
$('lang').append(...languages.map(code => {
  const option = el('option', '', locales[code].name);
  option.value = code;
  option.lang = code;
  return option;
}));
$('lang').value = lang;
$('lang').addEventListener('change', () => {
  if (!isLanguage($('lang').value)) return;
  langChosen = true;
  setLanguage($('lang').value);
  apply({ items, file });
  announce(t('announce.language', { name: locales[lang].name }));
});

if (!token) {
  setLive('off', 'live.off');
  showError({ key: 'error.noToken' });
} else {
  setLive('connecting', 'live.connecting');
  api('/api/items').then(received).catch(error => showError(sourceOf(error)));
  connect();
}
