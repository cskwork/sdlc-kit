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
