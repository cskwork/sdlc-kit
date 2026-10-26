// Who acts next on an item, shared by the TUI and the web page. Labels live in locales as `status.<kind>`.
export const gateOf = item => item.sdlc?.state === 'NEEDS-HUMAN' && item.sdlc.action?.match(/\bapprove (intent|plan)\b/)?.[1] || '';
export function statusOf(item) {
  if (item.done) return { actor: 'done', kind: 'done' };
  if (item.status === 'blocked') return { actor: 'blocked', kind: 'blocked' };
  if (item.status === 'waiting') { const gate = gateOf(item); return { actor: 'you', kind: gate ? `approve-${gate}` : 'answer', gate }; }
  return { actor: 'agent', kind: item.sdlc ? 'agent' : 'new' };
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
  const counts = { you: 0, agent: 0, blocked: 0, done: 0 };
  for (const item of items) counts[statusOf(item).actor]++;
  return counts;
}
