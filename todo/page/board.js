// Board view, the page's default screen: sdlc phases are columns, who acts next is the lane, and a side panel
// answers and approves in place. State and requests come from app.js (globalThis.todoPage); every item and feed
// string is shown with textContent, never as HTML. Only renderMarkdown output (it escapes first) uses innerHTML.
import { phaseLabel } from './i18n.mjs';
import { boardCards, boardColumns, boardLanes, statusLabel, statusOf, timeOf, DAY_MS, STALE_DAYS } from './status.mjs';

const page = globalThis.todoPage;
const $ = id => document.getElementById(id);
const t = (key, vars) => page.t(key, vars);
const el = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};
const str = value => typeof value === 'string' ? value : '';
const list = value => Array.isArray(value) ? value : [];
const record = value => value && typeof value === 'object' && !Array.isArray(value) ? value : null;
const isHttp = url => typeof url === 'string' && /^https?:\/\//i.test(url);
const basename = project => project.replace(/[\\/]+$/, '').split(/[\\/]/).pop() || project;
const clock = ms => new Intl.DateTimeFormat(page.lang, { hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(ms);
const dateTime = ms => new Intl.DateTimeFormat(page.lang, { dateStyle: 'medium', timeStyle: 'short' }).format(ms);
const alertLevel = alert => ['bad', 'warn'].includes(alert.level) ? alert.level : 'info';
const feedAlerts = feed => list(feed?.alerts).map(record).filter(alert => alert && str(alert.text));
const typing = target => target?.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT'].includes(target?.tagName);

// ---------- words ----------
// The panel's top section is for a person, not an agent: no code spans, file paths or command flags.
function plain(text) {
  return str(text)
    .replace(/`[^`]*`/g, ' ')
    .replace(/\[([^\]]+)\]\((?:[^)]+)\)/g, '$1')
    .replace(/\*\*|__/g, '')
    .replace(/(?:^|\s)(?:~|\.{1,2})?\/[^\s,)]*\/[^\s,)]*/g, ' ')
    .replace(/(?:^|\s)--[\w-]+/g, ' ')
    .replace(/\s+/g, ' ').replace(/\s+([,.)])/g, '$1').trim();
}
// "## At a glance" bullets of a brief or work document: { 'your call': '…', 'ai pick': '…', … }.
function glanceOf(markdown) {
  const lines = str(markdown).split(/\r?\n/), start = lines.findIndex(line => /^##\s+At a glance\s*$/i.test(line));
  if (start < 0) return null;
  const fields = {}, section = [];
  for (const line of lines.slice(start + 1)) {
    if (/^#{1,2}\s/.test(line)) break;
    section.push(line);
    const field = line.match(/^\s*[-*]\s+\*\*([^*:]+):?\*\*:?\s*(.*)$/);
    if (field) fields[field[1].trim().toLowerCase()] = field[2].trim();
  }
  return { fields, markdown: section.join('\n').trim() };
}
const tagOf = title => title.match(/^\[([^\]]+)\]\s*/);
// Line 1 names the ticket (or the [tag] of a title); line 2 is the title without it.
function cardWords(card) {
  const main = card.work || card.target;
  const tag = tagOf(main.title);
  const key = card.link?.label || tag?.[1] || '';
  let title = main.title;
  if (tag) title = title.slice(tag[0].length);
  for (let i = 0; key && i < 3 && title.startsWith(key); i++) title = title.slice(key.length).replace(/^[\s·:—-]+/, '');
  return { key, title: title.replace(/^[\s·:—-]+/, '') || main.title };
}
function projectChip(card) {
  const service = str(card.entry?.service);
  if (service) return service;
  const repos = card.members.flatMap(member => member.repos || []);
  const unique = [...new Set(repos)];
  if (unique.length) return unique.length > 1 ? `${unique[0]} +${unique.length - 1}` : unique[0];
  const project = card.members.find(member => member.project)?.project;
  return project ? basename(project) : '';
}
function ageOf(card, now) {
  if (!Number.isFinite(card.last)) return '';
  const days = Math.floor((now - card.last) / DAY_MS);
  return days < 1 ? t('board.today') : t('board.days', { count: days });
}
const toneOf = card => card.working ? 'working' : { you: 'wait', blocked: 'blocked', others: 'open', agent: 'busy', done: 'ok' }[card.lane];
const lastReply = item => [...item.events].reverse().find(event => event.who === 'human' && /^reply — /.test(event.what))?.what.slice(8) || '';

// ---------- view ----------
const narrow = matchMedia('(max-width: 899px)');
let chosenView = 'board';
function currentView() {
  if (narrow.matches) return 'list';
  if ((chosenView === 'runs' || chosenView === 'health') && !page.feed) return 'board';
  return chosenView;
}
function syncView() {
  const view = currentView();
  document.body.dataset.view = view;
  // The board appears whole with the first snapshot; a placeholder pushed down by it would count as a layout shift.
  $('board-view').hidden = view !== 'board' || !loaded;
  $('board-loading').hidden = view !== 'board' || loaded;
  $('runs-view').hidden = view !== 'runs';
  $('health-view').hidden = view !== 'health';
  $('list-view').hidden = view !== 'list';
  $('panel').hidden = view !== 'board' || !selectedKey;
  $('board-tools').hidden = view !== 'board';
  for (const button of $('views').querySelectorAll('[data-view]')) {
    button.setAttribute('aria-pressed', String(button.dataset.view === view));
    button.hidden = (button.dataset.view === 'runs' || button.dataset.view === 'health') && !page.feed;
  }
}
$('views').addEventListener('click', event => {
  const button = event.target.closest('[data-view]');
  if (!button) return;
  chosenView = button.dataset.view;
  render();
});
narrow.addEventListener('change', () => render());

// ---------- render ----------
let cards = [], selectedKey = '', showStale = false, doneOpen = false, updatedAt = 0, loaded = false;
function render() {
  const now = Date.now();
  cards = boardCards(page.items, page.feed, now);
  updatedAt = now;
  syncView();
  renderStrip();
  renderBoard(now);
  const view = currentView();
  if (view === 'runs') renderRuns(now);
  if (view === 'health') renderHealth();
  renderPanel(now);
  const yours = cards.filter(card => card.lane === 'you').length;
  document.title = yours ? `(${yours}) ${t('board.title')}` : t('board.title');
}

// ---------- strip ----------
function renderStrip() {
  const count = lane => cards.filter(card => card.lane === lane).length;
  const counts = $('board-counts');
  const parts = [['you', 'board.tally.you'], ['agent', 'board.tally.agent'], ['others', 'board.tally.others'], ['blocked', 'board.tally.blocked']]
    .map(([lane, key]) => {
      const n = count(lane);
      const part = el('span', `count-part lane-${lane}${n ? '' : ' zero'}`);
      part.append(el('span', '', t(key)), el('b', '', String(n)));
      return part;
    });
  counts.replaceChildren(...parts);
  const feed = record(page.feed), status = record(feed?.status), box = $('feed-status');
  box.hidden = !feed && !page.feedError;
  if (!box.hidden) {
    const bits = [];
    if (feed) {
      const state = ['idle', 'running', 'held', 'off'].includes(status?.state) ? status.state : 'idle';
      box.dataset.state = state;
      const head = el('span', 'feed-head');
      head.append(el('span', 'dot', ''), el('b', '', str(feed.source) || t('feed.source')), el('span', '', str(status?.text) || t(`feed.state.${state}`)));
      bits.push(head);
      const lanes = record(status?.lanes);
      if (Number.isFinite(lanes?.busy) && Number.isFinite(lanes?.total)) bits.push(el('span', 'feed-bit', t('feed.lanes', { busy: lanes.busy, total: lanes.total })));
      const next = timeOf(str(status?.nextRunAt));
      if (Number.isFinite(next)) bits.push(el('span', 'feed-bit', t('feed.next', { time: clock(next) })));
    } else box.dataset.state = 'off';
    if (page.feedError) bits.push(el('span', 'alert warn', t('feed.error')));
    box.replaceChildren(...bits);
  }
  const alerts = feedAlerts(feed);
  $('feed-alerts').hidden = !alerts.length || currentView() === 'list';
  $('feed-alerts').replaceChildren(...alerts.map(alert => {
    const chip = el('span', `alert ${alertLevel(alert)}`, alert.text);
    const since = timeOf(str(alert.since));
    chip.title = Number.isFinite(since) ? `${alert.text} · ${dateTime(since)}` : alert.text;
    return chip;
  }));
  const stale = cards.filter(card => card.stale && card.column !== 'done').length, toggle = $('stale-toggle');
  toggle.hidden = !stale;
  toggle.setAttribute('aria-pressed', String(showStale));
  toggle.textContent = t(showStale ? 'board.staleShown' : 'board.stale', { count: stale, days: STALE_DAYS });
  $('board-updated').textContent = loaded ? t('board.updated', { time: clock(updatedAt) }) : '';
}
$('stale-toggle').addEventListener('click', () => { showStale = !showStale; render(); });

// ---------- board ----------
const nodes = new Map(); // card key -> card button, reused so focus, selection and position survive live updates
let layout = '';
const cells = new Map(); // `${lane}|${column}` or 'done' -> cell
function buildGrid(columns) {
  const grid = $('board');
  grid.replaceChildren();
  grid.classList.toggle('done-open', doneOpen);
  cells.clear();
  grid.style.setProperty('--columns', columns.map(column => column === 'general' ? 'var(--col-general)' :
    column === 'done' ? (doneOpen ? 'var(--col-done-open)' : 'var(--col-done)') : 'var(--col)').join(' '));
  const corner = el('div', 'col-head corner');
  grid.append(corner);
  for (const column of columns) {
    const head = el('div', `col-head col-${column}`);
    head.dataset.column = column;
    if (column === 'done') {
      const toggle = el('button', 'done-toggle');
      toggle.type = 'button';
      toggle.id = 'done-toggle';
      toggle.setAttribute('aria-expanded', String(doneOpen));
      // Spaces between the parts keep the spoken name matching the visible words (label in name).
      toggle.append(el('span', 'col-name'), ' ', el('span', 'col-count'));
      head.append(toggle);
    } else head.append(el('span', 'col-name'), el('span', 'col-count'));
    grid.append(head);
  }
  boardLanes.forEach((lane, row) => {
    const head = el('div', `lane-head lane-${lane}`);
    head.dataset.lane = lane;
    head.style.gridRow = String(row + 2);
    head.append(el('span', 'lane-name'), el('span', 'lane-count'), el('span', 'lane-empty'));
    grid.append(head);
    for (const column of columns) {
      if (column === 'done') continue;
      const cell = el('div', `cell lane-${lane} col-${column}`);
      cell.style.gridRow = String(row + 2);
      cell.dataset.lane = lane;
      grid.append(cell);
      cells.set(`${lane}|${column}`, cell);
    }
  });
  if (columns.includes('done')) {
    const cell = el('div', 'cell done-cell');
    cell.style.gridRow = `2 / span ${boardLanes.length}`;
    cell.style.gridColumn = String(columns.length + 1);
    grid.append(cell);
    cells.set('done', cell);
  }
}
function cardNode(card, now) {
  let node = nodes.get(card.key);
  if (!node) {
    node = el('button', 'card');
    node.type = 'button';
    node.dataset.key = card.key;
    const top = el('span', 'card-top'), meta = el('span', 'card-meta');
    node._refs = { key: el('span', 'card-key'), proj: el('span', 'card-proj'), title: el('span', 'card-title'),
      chip: el('span', 'card-chip'), age: el('span', 'card-age'), sent: el('span', 'card-sent'), dot: el('span', 'status-dot'),
      status: el('span', 'visually-hidden') };
    const r = node._refs;
    // Spaces between the parts keep words apart in the name read from the card's text.
    top.append(r.key, ' ', r.proj);
    meta.append(r.chip, ' ', r.age, ' ', r.sent, ' ', r.status, r.dot);
    node.append(top, ' ', r.title, ' ', meta);
    nodes.set(card.key, node);
  }
  const r = node._refs, words = cardWords(card), proj = projectChip(card), age = ageOf(card, now);
  const status = statusLabel(t, card.target, now);
  const sig = JSON.stringify([page.lang, words, proj, age, card.chip, card.lane, card.working, card.sent, card.pinned, card.needsHuman, status]);
  if (node._sig !== sig) {
    node._sig = sig;
    r.key.textContent = words.key || words.title;
    r.title.textContent = words.key ? words.title : '';
    r.title.hidden = !words.key;
    r.proj.textContent = proj;
    r.proj.hidden = !proj;
    r.chip.textContent = card.chip;
    r.chip.hidden = !card.chip;
    r.age.textContent = age;
    r.sent.textContent = card.sent ? t('board.sent') : '';
    r.sent.hidden = !card.sent;
    r.dot.dataset.tone = toneOf(card);
    r.dot.title = status;
    node.dataset.tone = toneOf(card);
    node.classList.toggle('edge', card.pinned || card.needsHuman);
    node.title = (card.work || card.target).title;
    // The card's name is its visible words (a narrow cell hides the project chip from both), then the dot's status.
    r.status.textContent = status;
  }
  node.setAttribute('aria-current', String(card.key === selectedKey));
  node._card = card;
  return node;
}
function renderBoard(now) {
  const visible = cards.filter(card => card.column === 'done' || showStale || !card.stale);
  const general = visible.some(card => card.column === 'general');
  const columns = [...(general ? ['general'] : []), ...boardColumns, 'done'];
  const signature = JSON.stringify([columns, doneOpen]);
  if (signature !== layout) { layout = signature; buildGrid(columns); }
  $('board').hidden = !loaded;
  const grid = $('board');
  for (const head of grid.querySelectorAll('.col-head[data-column]')) {
    const column = head.dataset.column;
    head.querySelector('.col-name').textContent = t(`board.column.${column}`);
    head.querySelector('.col-count').textContent = String(visible.filter(card => card.column === column).length);
  }
  const done = $('done-toggle');
  const doneCount = visible.filter(card => card.column === 'done').length;
  if (done) done.setAttribute('aria-label', `${t('board.column.done')} ${doneCount}, ${t(doneOpen ? 'board.doneHide' : 'board.doneShow')}`);
  for (const head of grid.querySelectorAll('.lane-head')) {
    const lane = head.dataset.lane, here = cards.filter(card => card.lane === lane && !['done', 'legacy'].includes(card.column));
    const hidden = showStale ? 0 : here.filter(card => card.stale).length;
    head.querySelector('.lane-name').textContent = t(`board.lane.${lane}`);
    head.querySelector('.lane-count').textContent = [t('board.count', { count: here.length - hidden }), hidden ? t('board.hidden', { count: hidden }) : ''].filter(Boolean).join(' · ');
    // An empty lane shrinks to its label; its cells follow.
    const none = here.length - hidden === 0;
    head.toggleAttribute('data-empty', none);
    for (const [key, cell] of cells) if (key.startsWith(`${lane}|`)) cell.toggleAttribute('data-empty', none);
    const empty = head.querySelector('.lane-empty');
    empty.textContent = lane === 'you' && !here.length && loaded ? t('board.youEmpty') : '';
    empty.hidden = !empty.textContent;
  }
  const active = document.activeElement;
  const want = new Map([...cells.values()].map(cell => [cell, []]));
  const legacy = [];
  for (const card of visible) {
    if (card.column === 'legacy') { legacy.push(cardNode(card, now)); continue; }
    const cell = card.column === 'done' ? cells.get('done') : cells.get(`${card.lane}|${card.column}`);
    if (!cell) continue;
    // Pinned cards lead their cell; otherwise the list's order, which is the order agents work in.
    want.get(cell)[card.pinned ? 'unshift' : 'push'](cardNode(card, now));
  }
  const kept = new Set([...want.values()].flat().concat(legacy));
  for (const [key, node] of nodes) if (!kept.has(node)) { node.remove(); nodes.delete(key); }
  for (const [cell, wanted] of want) patchChildren(cell, wanted, kept);
  const legacyBox = $('legacy');
  legacyBox.hidden = !legacy.length;
  $('legacy-title').textContent = t('board.legacy', { count: legacy.length });
  patchChildren($('legacy-cards'), legacy, kept);
  if (active?.classList?.contains('card') && active.isConnected && document.activeElement !== active) active.focus({ preventScroll: true });
}
// Move only what changed: a node re-inserted at its own place would lose focus and replay its transition.
function patchChildren(parent, wanted, kept) {
  for (const child of [...parent.children]) if (!kept.has(child)) child.remove();
  wanted.forEach((node, index) => { if (parent.children[index] !== node) parent.insertBefore(node, parent.children[index] || null); });
  while (parent.children.length > wanted.length) parent.lastElementChild.remove();
}
$('board').addEventListener('click', event => {
  if (event.target.closest('#done-toggle')) { doneOpen = !doneOpen; layout = ''; render(); return; }
  const node = event.target.closest('.card');
  if (node) select(node.dataset.key, event.detail === 0);
});
$('legacy-cards').addEventListener('click', event => {
  const node = event.target.closest('.card');
  if (node) select(node.dataset.key, event.detail === 0);
});

// ---------- panel ----------
const drafts = new Map(); // target item id -> reply draft
// Work documents by item and status kind: a sync can change an item's version, so the version alone would refetch
// in a loop; a new kind (a gate opened or closed) fetches again. 409 on approval drops the entry.
const documents = new Map(); // `${id}|${kind}` -> { markdown, gate, sha, version } | { error } | { pending }
let panelSig = '', panelTarget = null, panelCard = null, sending = false;
function yourQueue() {
  const order = [...(cards.some(card => card.column === 'general') ? ['general'] : []), ...boardColumns];
  return order.flatMap(column => cards.filter(card => card.lane === 'you' && card.column === column && (showStale || !card.stale)));
}
function select(key, focusPanel) {
  if (!cards.some(card => card.key === key)) return;
  selectedKey = key;
  render();
  if (focusPanel) $('panel-title').focus();
  followTicket(cards.find(card => card.key === key));
  nodes.get(key)?.scrollIntoView?.({ block: 'nearest', inline: 'nearest' });
}
function closePanel() {
  const key = selectedKey;
  selectedKey = '';
  render();
  nodes.get(key)?.focus({ preventScroll: true });
}
function step(delta) {
  const queue = yourQueue();
  if (!queue.length) return;
  const at = queue.findIndex(card => card.key === selectedKey);
  const next = at < 0 ? (delta > 0 ? 0 : queue.length - 1) : (at + delta + queue.length) % queue.length;
  select(queue[next].key, false);
}
$('panel-close').addEventListener('click', closePanel);
$('panel-prev').addEventListener('click', () => step(-1));
$('panel-next').addEventListener('click', () => step(1));
document.addEventListener('keydown', event => {
  if (currentView() !== 'board' || event.altKey || event.ctrlKey || event.metaKey) return;
  if (event.key === 'Escape' && selectedKey) { event.preventDefault(); closePanel(); return; }
  if (typing(event.target) || !selectedKey) return;
  if (event.key === 'ArrowRight' || event.key === 'j') { event.preventDefault(); step(1); }
  else if (event.key === 'ArrowLeft' || event.key === 'k') { event.preventDefault(); step(-1); }
});

const skeletonMs = 1500;
const docKey = item => `${item.id}|${statusOf(item).kind}`;
function documentOf(item) {
  if (item.done || !(item.brief || item.sdlc)) return null;
  const key = docKey(item);
  if (!documents.has(key)) {
    documents.set(key, { pending: true, started: Date.now() });
    // A brief usually arrives at once; an sdlc document waits for its status. Past the skeleton's time, show the
    // item's own words instead of a placeholder.
    setTimeout(() => { if (panelTarget?.id === item.id && documents.get(key)?.pending) { panelSig = ''; renderPanel(Date.now()); } }, skeletonMs + 50);
    page.api(`/api/artifact?id=${encodeURIComponent(item.id)}`)
      .then(data => documents.set(key, { markdown: str(data.markdown), gate: str(data.gate), sha: str(data.sha), version: item.version }))
      .catch(error => documents.set(key, { error: page.say(page.sourceOf(error)) }))
      .finally(() => { if (panelTarget?.id === item.id) { panelSig = ''; renderPanel(Date.now()); } });
  }
  return documents.get(key);
}

function renderPanel(now) {
  const panel = $('panel');
  const card = cards.find(c => c.key === selectedKey);
  if (!selectedKey || currentView() !== 'board') { panel.hidden = true; panelSig = ''; panelTarget = panelCard = null; return; }
  panel.hidden = false;
  $('panel-gone').hidden = !!card;
  $('panel-content').hidden = !card;
  const queue = yourQueue(), at = card ? queue.findIndex(c => c.key === card.key) : -1;
  $('panel-page').textContent = at >= 0 ? t('panel.page', { n: at + 1, total: queue.length }) : t('panel.pageOther', { total: queue.length });
  $('panel-prev').disabled = $('panel-next').disabled = !queue.length || (queue.length === 1 && at === 0);
  if (!card) return;
  const item = card.target, doc = documentOf(item);
  const loading = !!doc?.pending && !!item.brief && Date.now() - doc.started < skeletonMs;
  const sig = JSON.stringify([page.lang, card.key, card.members.map(m => [m.id, m.version, m.working?.what]), card.lane, card.entry, doc, loading, sending, showDetails]);
  if (sig === panelSig) return;
  panelSig = sig;
  if (panelTarget?.id !== item.id) {
    $('panel-reply-text').value = drafts.get(item.id) || '';
    $('panel-error').hidden = true;
    $('panel-note').value = '';
  }
  panelTarget = item;
  panelCard = card;
  const words = cardWords(card), status = statusOf(item), glance = doc && !doc.pending && !doc.error ? glanceOf(doc.markdown) : null;
  $('panel-title').textContent = words.key ? words.title : (card.work || item).title;
  // The ticket and project sit with the status under the title, not as a label above it.
  const tags = [[words.key, 'tag key-tag'], [projectChip(card), 'tag'], [t(`board.lane.${card.lane}`), `tag tone-${toneOf(card)}`],
    [t(`board.column.${card.column}`), 'tag'], [card.chip, 'tag'], [ageOf(card, now), 'tag']];
  $('panel-tags').replaceChildren(...tags.filter(([text]) => text).map(([text, className]) => el('span', className, text)));

  // What the human is asked, from the brief's At a glance when there is one.
  const sent = card.members.find(member => member.status !== 'blocked' && statusOf(member).kind === 'handoff');
  $('panel-sent').hidden = !sent;
  if (sent) $('panel-sent').textContent = t('board.sentWhat', { text: lastReply(sent) || '…' });
  const fields = glance?.fields || {};
  const label = { you: 'panel.ask', blocked: 'panel.problem', others: 'panel.waitingOn', agent: 'panel.state', done: 'panel.state' }[statusOf(item).actor];
  $('panel-ask-label').textContent = t(label);
  const question = questionOf(card, item, status, fields, now);
  const ask = $('panel-question');
  ask.textContent = loading ? '' : question;
  ask.classList.toggle('skeleton', loading);
  const pick = plain(str(fields['ai pick'])).replace(/^AI\s*(?:권장|pick)\s*[:：]\s*/i, '');
  $('panel-ai').hidden = !pick;
  $('panel-ai-text').textContent = pick;
  for (const [id, name] of [['panel-background', 'background'], ['panel-why', 'why']]) {
    const value = plain(fields[name]);
    $(id).hidden = !value;
    $(id).replaceChildren(el('span', 'muted-label', t(`panel.${name}`)), document.createTextNode(value));
  }
  const target = $('panel-target');
  target.hidden = card.members.length < 2 || item.done;
  target.textContent = t('panel.target', { title: item.title });

  renderChoices(card, item);
  renderGate(item, doc, status);
  renderProblem(item, status);
  $('panel-reply').hidden = item.done;
  for (const control of $('panel-reply').elements) control.disabled = sending;
  const url = card.link?.url;
  $('panel-ticket').hidden = !isHttp(url);
  renderDetails(card, item, doc);
}
// The brief's "your call" when it asks something; otherwise the item's own words for whoever acts next.
function questionOf(card, item, status, fields, now) {
  const yourCall = plain(fields['your call']);
  if (yourCall && yourCall.toLowerCase() !== 'none') return yourCall;
  if (status.actor === 'you') return plain(status.gate ? t(`next.${status.kind}`) : item.waiting || item.sdlc?.action || t(`next.${status.kind}`));
  if (status.actor === 'blocked') return plain(item.error || item.sdlc?.action) || t('field.unknown');
  if (status.actor === 'others') return plain(item.others || str(card.entry?.waitingText)) || statusLabel(t, item, now);
  return [statusLabel(t, item, now), plain(str(card.entry?.waitingText))].filter(Boolean).join(' · ');
}
function renderChoices(card, item) {
  const box = $('panel-choices'), labels = item.done ? [] : item.choices || [];
  box.hidden = !labels.length;
  box.replaceChildren(...labels.map((label, index) => {
    const recommended = item.pick ? item.pick === index + 1 : item.suggest === label;
    const button = el('button', recommended ? 'choice primary' : 'choice secondary');
    button.type = 'button';
    button.disabled = sending;
    button.append(el('span', 'choice-number', String(index + 1)), el('span', 'choice-label', label));
    if (recommended) button.append(el('span', 'ai-badge', t('panel.ai')));
    button.addEventListener('click', () => answer(card, item, label));
    return button;
  }));
}
function renderGate(item, doc, status) {
  const box = $('panel-gate');
  box.hidden = !status.gate;
  if (!status.gate) return;
  const approve = $('panel-approve');
  approve.textContent = t(`decide.approve-${status.gate}`);
  const glance = $('panel-glance');
  if (!doc || doc.pending) {
    glance.replaceChildren(el('p', 'hint', t('artifact.loading')));
    approve.disabled = true;
    return;
  }
  if (doc.error) {
    glance.replaceChildren(el('p', 'field-error', t('artifact.failed', { message: doc.error })));
    approve.disabled = true;
    return;
  }
  approve.disabled = sending || doc.gate !== status.gate;
  const section = glanceOf(doc.markdown);
  if (!section?.markdown) { glance.replaceChildren(el('p', 'hint', t('panel.noGlance'))); return; }
  import('./markdown.js').then(({ renderMarkdown }) => {
    if (panelTarget?.id !== item.id) return;
    // renderMarkdown escapes all HTML first, as on the list's work document.
    glance.innerHTML = renderMarkdown(section.markdown);
  });
}
function renderProblem(item, status) {
  const box = $('panel-fix');
  box.hidden = !(status.actor === 'blocked' && !item.error);
  box.disabled = sending;
}
let showDetails = false;
function renderDetails(card, item, doc) {
  $('panel-more').setAttribute('aria-expanded', String(showDetails));
  $('panel-more').textContent = t(showDetails ? 'panel.less' : 'panel.more');
  $('panel-details').hidden = !showDetails;
  if (!showDetails) return;
  const dl = $('panel-fields');
  dl.replaceChildren();
  const field = (name, value) => { if (!value) return; dl.append(el('dt', '', name), el('dd', '', value)); };
  field(t('field.status'), statusLabel(t, item));
  field(t('field.project'), item.project);
  const repos = [...new Set(card.members.flatMap(member => member.repos || []))];
  if (repos.length) field(t('field.repos'), repos.join(', '));
  if (card.work) field(t('field.work'), `${card.work.sdlc.slug} · ${phaseLabel(t, card.work.sdlc.phase)} · ${card.work.sdlc.state}`);
  field(t('panel.nextStep'), str(card.entry?.nextStep));
  if (!item.done && item.run) field(t('field.run'), item.run);
  const members = $('panel-members');
  $('panel-members-box').hidden = card.members.length < 2;
  members.replaceChildren(...card.members.map(member => {
    const li = el('li', member.id === item.id ? 'member current' : 'member');
    li.append(el('span', `tag tone-${toneOf({ lane: statusOf(member).actor, working: statusOf(member).kind === 'working' })}`, statusLabel(t, member)), el('span', '', member.title));
    return li;
  }));
  const box = $('panel-doc');
  if (!doc) box.replaceChildren(el('p', 'hint', t('panel.noDocument')));
  else if (doc.pending) box.replaceChildren(el('p', 'hint', t('artifact.loading')));
  else if (doc.error) box.replaceChildren(el('p', 'field-error', t('artifact.failed', { message: doc.error })));
  else import('./markdown.js').then(({ renderMarkdown }) => { if (panelTarget?.id === item.id) box.innerHTML = renderMarkdown(doc.markdown); });
  const history = $('panel-history');
  const events = card.members.flatMap(member => member.events.map(event => ({ ...event, member }))).sort((a, b) => b.at.localeCompare(a.at)).slice(0, 40);
  history.replaceChildren(...events.map(event => {
    const li = el('li');
    li.append(el('time', '', event.at), document.createTextNode(` · ${event.who} · ${event.what}`));
    return li;
  }));
  if (!events.length) history.append(el('li', 'hint', t('history.empty')));
  const notes = card.members.flatMap(member => member.notes || []).map(note => note.trim()).filter(Boolean);
  $('panel-notes-box').hidden = !notes.length;
  $('panel-notes').textContent = notes.join('\n');
}
$('panel-more').addEventListener('click', () => { showDetails = !showDetails; panelSig = ''; renderPanel(Date.now()); });

// ---------- answering ----------
let toastTimer;
function toast(text) {
  const box = $('toast');
  box.textContent = text;
  box.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { box.hidden = true; }, 4000);
}
async function send(path, body, done) {
  sending = true;
  panelSig = '';
  renderPanel(Date.now());
  $('panel-error').hidden = true;
  try {
    const data = await page.api(path, body);
    if (data.items) page.apply(data);
    page.announce(done);
    toast(done);
    return data;
  } catch (error) {
    const message = page.say(page.sourceOf(error));
    $('panel-error').textContent = message;
    $('panel-error').hidden = false;
    page.showError(page.sourceOf(error));
    throw error;
  } finally {
    sending = false;
    panelSig = '';
    renderPanel(Date.now());
  }
}
// The same request the list's choice buttons and reply box send: an ordinary reply, never an approval.
async function answer(card, item, text) {
  try {
    await send('/api/item', { id: item.id, version: item.version, op: 'reply', text }, t('board.sentToast'));
    drafts.delete(item.id);
    if (panelTarget?.id === item.id || card.target.id === item.id) $('panel-reply-text').value = '';
  } catch { /* shown */ }
}
$('panel-reply').addEventListener('submit', event => {
  event.preventDefault();
  const text = page.oneLine($('panel-reply-text').value);
  if (!text) { $('panel-error').textContent = t('reply.empty'); $('panel-error').hidden = false; $('panel-reply-text').focus(); return; }
  if (panelCard && panelTarget) answer(panelCard, panelTarget, text);
});
$('panel-reply-text').addEventListener('input', () => { if (panelTarget) drafts.set(panelTarget.id, $('panel-reply-text').value); });
$('panel-reply-text').addEventListener('keydown', event => {
  if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) { event.preventDefault(); $('panel-reply').requestSubmit(); }
});
$('panel-approve').addEventListener('click', async () => {
  const item = panelTarget, doc = item && documents.get(docKey(item));
  if (!item || !doc?.sha || !doc.gate) return;
  const words = page.oneLine($('panel-note').value);
  if (words.length > 500) { $('panel-error').textContent = t('decide.length'); $('panel-error').hidden = false; return; }
  try {
    await send('/api/approve', { id: item.id, version: doc.version, gate: doc.gate, sha: doc.sha, words }, t('announce.approved'));
    $('panel-note').value = '';
  } catch (error) {
    // A changed document cannot be approved as shown: fetch it again.
    if (error.status === 409) { documents.delete(docKey(item)); panelSig = ''; renderPanel(Date.now()); }
  }
});
$('panel-fix').addEventListener('click', async () => {
  const item = panelTarget;
  if (!item) return;
  try {
    const data = await send('/api/item', { id: item.id, version: item.version, op: 'fix' }, t('fix.queued'));
    const launch = data.launch || 'queued';
    if (launch.startsWith('failed: ')) page.showError(t('fix.failed', { reason: launch.slice(8) }));
    else if (launch === 'started') toast(t('fix.started'));
  } catch { /* shown */ }
});

// ---------- ticket window ----------
// Ticket sites refuse frames, so the ticket opens in one named popup docked to the screen's right edge, and that
// window follows the selection. Trade-off (decided 2026-11-19): following needs the opener link, because Chromium
// lets a page with a cut opener neither navigate nor close its popup. So a hostile http(s) ticket page could redirect
// this board window. It gains nothing: the token lives only in this page's URL fragment and memory, a redirected
// window loses both, and another origin can never read them, so a fake page cannot approve or answer anything.
let ticketWindow = null, ticketUrl = '';
function openTicket(url) {
  if (!isHttp(url)) return;
  if (ticketWindow && !ticketWindow.closed) {
    if (url !== ticketUrl) { ticketWindow.location.href = url; ticketUrl = url; }
    ticketWindow.focus();
    return;
  }
  const width = Math.round(screen.availWidth * 0.45), height = screen.availHeight;
  const left = (screen.availLeft || 0) + screen.availWidth - width, top = screen.availTop || 0;
  const opened = window.open(url, 'sdlc-ticket', `popup=yes,width=${width},height=${height},left=${left},top=${top}`);
  if (!opened) { page.showError({ key: 'panel.popupBlocked' }); return; }
  ticketWindow = opened;
  ticketUrl = url;
  opened.focus();
}
// Only a person's selection (a click or ←/→/j/k) moves the ticket window; live updates never call select().
function followTicket(card) {
  const url = card?.link?.url;
  if (!ticketWindow || ticketWindow.closed || !isHttp(url) || url === ticketUrl) return;
  ticketWindow.location.href = url;
  ticketUrl = url;
}
$('panel-ticket').addEventListener('click', () => openTicket(panelCard?.link?.url));

// ---------- runs ----------
let runsDay = '';
const dayKey = ms => { const d = new Date(ms); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; };
function runsOf() {
  return list(page.feed?.runs).map(record).filter(Boolean).map(run => ({
    key: str(run.key), label: str(run.label), start: timeOf(str(run.startedAt)), end: timeOf(str(run.endedAt)),
    outcome: ['ok', 'fail'].includes(run.outcome) ? run.outcome : 'unknown'
  })).filter(run => Number.isFinite(run.start));
}
function renderRuns(now) {
  const runs = runsOf(), today = dayKey(now);
  if (!runsDay) runsDay = today;
  const days = Array.from({ length: 7 }, (_, i) => dayKey(now - (6 - i) * DAY_MS));
  const dayLabel = key => new Intl.DateTimeFormat(page.lang, { month: '2-digit', day: '2-digit', weekday: 'short' }).format(new Date(`${key}T12:00`));
  $('runs-days').replaceChildren(...days.map(key => {
    const here = runs.filter(run => dayKey(run.start) === key), fails = here.filter(run => run.outcome === 'fail').length;
    const button = el('button', 'day');
    button.type = 'button';
    button.dataset.day = key;
    button.setAttribute('aria-pressed', String(key === runsDay));
    button.append(el('span', 'day-name', key === today ? `${dayLabel(key)} · ${t('runs.today')}` : dayLabel(key)),
      el('b', 'day-count', String(here.length)), el('span', fails ? 'day-fail bad' : 'day-fail', t('runs.failCount', { count: fails })));
    return button;
  }));
  const here = runs.filter(run => dayKey(run.start) === runsDay).sort((a, b) => a.start - b.start);
  const counts = { ok: 0, fail: 0, unknown: 0 };
  for (const run of here) counts[run.outcome]++;
  $('runs-title').textContent = t('runs.title', { date: dayLabel(runsDay), count: here.length });
  $('runs-summary').textContent = t('runs.summary', counts);
  // 08:00–19:00; runs outside the axis are clamped to its edge.
  const base = new Date(`${runsDay}T08:00`).getTime(), span = 11 * 3600000;
  const axis = $('runs-axis');
  axis.replaceChildren(...Array.from({ length: 12 }, (_, i) => {
    const tick = el('span', 'tick', `${String(8 + i).padStart(2, '0')}:00`);
    tick.style.left = `${(i / 11) * 100}%`;
    return tick;
  }));
  const rows = [], bars = here.map(run => {
    const end = Number.isFinite(run.end) ? run.end : Math.min(now, run.start + 60000);
    const left = Math.min(100, Math.max(0, (run.start - base) / span * 100));
    const width = Math.max(0.6, Math.min(100 - left, (end - run.start) / span * 100));
    // Greedy rows; a label needs about 9% of the axis beyond its bar.
    let row = rows.findIndex(edge => edge <= left);
    if (row < 0) { rows.push(0); row = rows.length - 1; }
    rows[row] = left + width + 9;
    const bar = el('div', `run ${run.outcome}`);
    bar.style.left = `${left}%`;
    bar.style.width = `${width}%`;
    bar.style.top = `${row * 1.9}rem`;
    bar.append(el('span', 'run-bar'), el('span', 'run-label', [run.key, run.label].filter(Boolean).join(' · ')));
    bar.title = `${clock(run.start)}${Number.isFinite(run.end) ? `–${clock(run.end)}` : ''} · ${t(`runs.${run.outcome}`)}`;
    return bar;
  });
  const track = $('runs-track');
  track.style.height = `${Math.max(1, rows.length) * 1.9 + 0.6}rem`;
  track.replaceChildren(...bars);
  $('runs-empty').hidden = here.length > 0;
  $('runs-empty').textContent = t('runs.empty');
}
$('runs-days').addEventListener('click', event => {
  const button = event.target.closest('[data-day]');
  if (!button) return;
  runsDay = button.dataset.day;
  renderRuns(Date.now());
});

// ---------- health ----------
function renderHealth() {
  const feed = record(page.feed);
  const alerts = feedAlerts(feed);
  $('health-alerts').hidden = !alerts.length;
  $('health-alert-list').replaceChildren(...alerts.map(alert => {
    const li = el('li', `alert-row ${alertLevel(alert)}`);
    li.append(el('span', 'dot'), el('span', '', alert.text));
    const since = timeOf(str(alert.since));
    if (Number.isFinite(since)) li.append(el('span', 'muted', dateTime(since)));
    return li;
  }));
  const sections = list(feed?.health).map(record).filter(Boolean);
  $('health-sections').replaceChildren(...sections.map(section => {
    const box = el('section', 'health-card');
    box.append(el('h3', '', str(section.title)));
    const dl = el('dl', 'health-rows');
    for (const row of list(section.rows).map(record).filter(Boolean)) {
      const dd = el('dd', `level-${['ok', 'warn', 'bad'].includes(row.level) ? row.level : 'none'}`);
      dd.append(el('span', 'dot'), el('span', '', str(row.value)));
      dl.append(el('dt', '', str(row.label)), dd);
    }
    box.append(dl);
    return box;
  }));
  const generated = timeOf(str(feed?.generatedAt));
  $('health-generated').textContent = Number.isFinite(generated) ? t('feed.generated', { time: dateTime(generated) }) : '';
  $('health-empty').hidden = sections.length > 0 || alerts.length > 0;
}

// A page with an unsent answer or a request in flight is never closed for a newer window.
page.addBusyCheck(() => sending || [...drafts.values()].some(draft => draft.trim()) || !!$('panel-note').value.trim());
page.subscribe(() => { loaded = true; render(); });
render();
// Event times turn into "N days" and the clock moves on without a snapshot.
setInterval(() => { if (loaded) render(); }, 60000);
