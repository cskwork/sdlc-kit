// Who acts next on an item, shared by the TUI and the web page. Labels live in locales as `status.<kind>`.
export const gateOf = item => item.sdlc?.state === 'NEEDS-HUMAN' && item.sdlc.action?.match(/\bapprove (intent|plan)\b/)?.[1] || '';
export function statusOf(item) {
  if (item.done) return { actor: 'done', kind: 'done' };
  // A block the human asked an agent to fix waits for that agent, like an unread reply.
  if (item.status === 'blocked') return item.fixRequested ? { actor: 'agent', kind: 'handoff' } : { actor: 'blocked', kind: 'blocked' };
  if (item.status === 'waiting') { const gate = gateOf(item); return { actor: 'you', kind: gate ? `approve-${gate}` : 'answer', gate }; }
  // Someone else (a planner, QA) answers first; it is neither your turn nor an agent's.
  if (item.status === 'others') return { actor: 'others', kind: 'others' };
  // An agent marked it with `working` and still beats. Blocked, waiting and others win above: a turn that is
  // yours or someone else's is not hidden by a heartbeat. Loaders attach only live markers (core.withWorking).
  if (item.working) return { actor: 'agent', kind: 'working' };
  // A reply stays unread until an agent takes it with next or take; nobody is working on it yet.
  if (item.unread) return { actor: 'agent', kind: 'handoff' };
  return { actor: 'agent', kind: item.sdlc ? 'agent' : 'new' };
}
// The status words, with how long an agent has been working and on what: "Working now · 12 min · build".
export function statusLabel(t, item, now = Date.now()) {
  const { kind } = statusOf(item), label = t(`status.${kind}`);
  if (kind !== 'working') return label;
  const minutes = Math.floor((now - Date.parse(item.working.since)) / 60000);
  const elapsed = minutes >= 1 ? t('working.minutes', { count: minutes }) : t('working.justNow');
  return [label, elapsed, item.working.what].filter(Boolean).join(' · ');
}
// Agents work Open items top-down and stop at the first one that is your turn or blocked.
export function queueOf(items) {
  const open = items.filter(item => !item.done);
  const stop = open.findIndex(item => ['you', 'blocked'].includes(statusOf(item).actor));
  if (stop < 0) return { stop: null, queued: new Set() };
  const behind = open.slice(stop + 1).filter(item => statusOf(item).actor === 'agent');
  return { stop: open[stop], queued: new Set(behind.map(item => item.id)) };
}
export function countsOf(items) {
  const counts = { you: 0, agent: 0, others: 0, blocked: 0, done: 0 };
  for (const item of items) counts[statusOf(item).actor]++;
  return counts;
}
// Open items that need the human and share one ticket link show together under that ticket, at the
// first one's place and in item order: [{ item }] or [{ ticket: { label, url }, items }].
export function ticketGroups(items) {
  const needs = item => !item.done && ['you', 'blocked'].includes(statusOf(item).actor) && !!item.link?.url;
  const count = new Map();
  for (const item of items) if (needs(item)) count.set(item.link.url, (count.get(item.link.url) || 0) + 1);
  const entries = [], seen = new Set();
  for (const item of items) {
    if (!needs(item) || count.get(item.link.url) < 2) { entries.push({ item }); continue; }
    if (seen.has(item.link.url)) continue;
    seen.add(item.link.url);
    entries.push({ ticket: item.link, items: items.filter(other => needs(other) && other.link.url === item.link.url) });
  }
  return entries;
}

// ---------- board ----------
// The board shows each sdlc phase as a column and who acts next as a lane. Open items that share one ticket
// link are one card. An optional feed (untrusted, written by an outside tool) may move a card that waits on an
// agent or on others; it never hides a turn of the human's or a block that comes from the to-do file.
export const boardColumns = ['intent', 'plan', 'build', 'evidence', 'deliver'];
export const boardLanes = ['you', 'others', 'blocked', 'agent'];
const urgency = ['you', 'blocked', 'others', 'agent'];
export const DAY_MS = 86400000, STALE_DAYS = 14, DONE_DAYS = 7;
// Event times are local "YYYY-MM-DD HH:MM"; feed times are ISO. Anything else is NaN.
export const timeOf = value => typeof value !== 'string' || !value ? NaN :
  Date.parse(/^\d{4}-\d{2}-\d{2} \d/.test(value) ? value.replace(' ', 'T') : value);
export function lastEventAt(items) {
  let last = NaN;
  for (const item of items) for (const event of item.events || []) {
    const at = timeOf(event.at);
    if (Number.isFinite(at) && !(at <= last)) last = at;
  }
  return last;
}
export function doneAtOf(item) {
  const events = item.events || [];
  return timeOf(([...events].reverse().find(event => /^(done|DONE)\b/.test(event.what)) || events.at(-1))?.at);
}
const isEntry = value => !!value && typeof value === 'object' && !Array.isArray(value);
// A feed entry matches a card by its ticket label (A20-1531), else by a member's sdlc slug (as key or `slug`).
export function feedEntryOf(feed, members) {
  const entries = isEntry(feed) && isEntry(feed.items) ? feed.items : null;
  if (!entries) return null;
  const entry = key => typeof key === 'string' && key && Object.hasOwn(entries, key) && isEntry(entries[key]) ? entries[key] : null;
  const slugs = members.map(member => member.sdlc?.slug).filter(Boolean);
  return members.map(member => entry(member.link?.label)).find(Boolean) || slugs.map(entry).find(Boolean) ||
    Object.values(entries).find(value => isEntry(value) && typeof value.slug === 'string' && slugs.includes(value.slug)) || null;
}
// Who an answer goes to on a card: the human's turn, preferring offered choices, then a gate, then an item outside sdlc.
export function targetOf(members) {
  const yours = members.filter(member => statusOf(member).actor === 'you');
  if (yours.length) return yours.find(member => member.choices?.length) || yours.find(member => statusOf(member).gate) ||
    yours.find(member => !member.sdlc) || yours[0];
  return members.find(member => statusOf(member).actor === 'blocked') || members.find(member => member.sdlc) || members[0];
}
const own = (entry, name) => entry && typeof entry[name] === 'string' ? entry[name] : '';
// Cards in item order: open items grouped by link, then items done in the last DONE_DAYS days, one card each.
export function boardCards(items, feed = null, now = Date.now()) {
  const groups = new Map(), sets = [];
  for (const item of items) {
    if (item.done) continue;
    const url = item.link?.url;
    if (url && groups.has(url)) { groups.get(url).push(item); continue; }
    const members = [item];
    if (url) groups.set(url, members);
    sets.push(members);
  }
  const cards = sets.map(members => {
    const work = members.find(member => member.sdlc) || null, entry = feedEntryOf(feed, members);
    const actor = urgency.find(name => members.some(member => statusOf(member).actor === name));
    const lane = ['agent', 'others'].includes(actor) && boardLanes.includes(entry?.turn) ? entry.turn : actor;
    const phase = work?.sdlc?.phase;
    const needsHuman = actor === 'you' || actor === 'blocked';
    // The feed may move a card between work columns, never one the human must act on, and never an open card to Done.
    const column = !needsHuman && boardColumns.includes(entry?.column) ? entry.column :
      [...boardColumns, 'done', 'legacy'].includes(phase) ? phase : 'general';
    const times = [lastEventAt(members), timeOf(own(entry, 'updatedAt'))].filter(Number.isFinite);
    const last = times.length ? Math.max(...times) : NaN, pinned = members.some(member => member.pin);
    return {
      key: members[0].link?.url ? `link:${members[0].link.url}` : `item:${members[0].id}`,
      members, target: targetOf(members), work, link: members.find(member => member.link)?.link || null,
      column, lane, actor, entry, chip: own(entry, 'chip'), last, pinned, needsHuman,
      working: members.some(member => statusOf(member).kind === 'working'),
      // A reply waits for an agent to read it: the human already answered this card.
      sent: members.some(member => member.status !== 'blocked' && statusOf(member).kind === 'handoff'),
      stale: !needsHuman && !pinned && Number.isFinite(last) && now - last > STALE_DAYS * DAY_MS
    };
  });
  for (const item of items) {
    const at = item.done ? doneAtOf(item) : NaN;
    if (!Number.isFinite(at) || now - at > DONE_DAYS * DAY_MS) continue;
    cards.push({ key: `done:${item.id}`, members: [item], target: item, work: item.sdlc ? item : null, link: item.link || null,
      column: 'done', lane: 'done', actor: 'done', entry: null, chip: '', last: at, pinned: false, needsHuman: false,
      working: false, sent: false, stale: false });
  }
  return cards;
}
