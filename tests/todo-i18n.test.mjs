import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { defaultLanguage, languages, locales, phaseLabel, resolveLanguage, translator } from '../todo/i18n.mjs';

const plural = /\.(?:zero|one|two|few|many|other)$/;
const shape = messages => {
  const keys = new Map();
  for (const [key, text] of Object.entries(messages)) {
    const base = key.replace(plural, '');
    keys.set(base, new Set([...(keys.get(base) || []), ...[...text.matchAll(/\{(\w+)\}/g)].map(m => m[1])]));
  }
  return new Map([...keys].map(([key, names]) => [key, [...names].sort()]));
};

test('every registered locale has the keys and {placeholders} of the default', () => {
  assert.equal(defaultLanguage, 'en');
  const expected = shape(locales[defaultLanguage].messages);
  assert.ok(languages.length >= 2);
  for (const language of languages) {
    const { name, messages } = locales[language];
    assert.ok(typeof name === 'string' && name.trim(), `${language} has a display name`);
    const actual = shape(messages);
    assert.deepEqual([...actual.keys()].sort(), [...expected.keys()].sort(), `${language} keys`);
    for (const [key, names] of expected) assert.deepEqual(actual.get(key), names, `${language} ${key} placeholders`);
    for (const key of Object.keys(messages)) if (plural.test(key)) {
      assert.ok(Object.hasOwn(messages, key.replace(plural, '.other')), `${language} ${key} needs .other`);
    }
  }
});

test('translator fills placeholders, picks plural forms and falls back to the default', () => {
  const t = translator('en');
  assert.equal(t('page.counts', { you: 1, agent: 2, blocked: 0, done: 3 }), '1 your turn · 2 agent · 0 blocked · 3 done');
  assert.equal(t('announce.addedCount', { count: 1 }), 'One item added');
  assert.equal(t('announce.addedCount', { count: 3 }), '3 items added');
  const registry = { ...locales, xx: { name: 'Test', messages: {} } };
  assert.equal(translator('xx', registry)('row.details'), t('row.details'));
  assert.equal(translator('nope')('row.details'), t('row.details'));
  const other = languages.find(l => l !== defaultLanguage);
  assert.notEqual(translator(other)('row.details'), t('row.details'));
  assert.doesNotMatch(translator(other)('announce.addedCount', { count: 1 }), /\{count\}|^announce/, 'a locale with only .other covers every count');
});

test('language: flag wins over SDLC_TODO_LANG, unknown env falls back, invalid flag is refused', () => {
  const other = languages.find(l => l !== defaultLanguage);
  assert.equal(resolveLanguage(undefined, undefined), defaultLanguage);
  assert.equal(resolveLanguage(undefined, other), other);
  assert.equal(resolveLanguage(defaultLanguage, other), defaultLanguage);
  assert.equal(resolveLanguage(undefined, 'xx'), defaultLanguage);
  assert.throws(() => resolveLanguage('xx', other), /invalid language: xx/);
});

// fileURLToPath, not URL.pathname: on Windows the pathname keeps a leading slash before the drive.
const entry = fileURLToPath(new URL('../todo/todo.mjs', import.meta.url));
for (const args of [['--lang', 'xx'], ['web', '--lang', 'xx', '--open'], ['--lang']]) {
  test(`CLI refuses ${args.join(' ')} as a usage error`, () => {
    const run = spawnSync(process.execPath, [entry, ...args], { encoding: 'utf8', env: { ...process.env, SDLC_TODO: '/nonexistent/todo.md' } });
    assert.equal(run.status, 2, run.stderr);
    assert.match(run.stderr, args.length > 1 ? /invalid language: xx/ : /missing value: --lang/);
    assert.match(run.stderr, /--lang en\|ko/);
  });
}
test('CLI accepts --lang on the TUI and web modes only', () => {
  const run = spawnSync(process.execPath, [entry, 'list', '--lang', 'en'], { encoding: 'utf8' });
  assert.equal(run.status, 2);
  assert.match(run.stderr, /unexpected option: --lang/);
});

test('every data-i18n key in the page exists in the default locale', () => {
  const html = readFileSync(new URL('../todo/page/index.html', import.meta.url), 'utf8');
  const keys = [...html.matchAll(/data-i18n(?:-[a-z]+)?="([^"]+)"/g)].map(m => m[1]);
  assert.ok(keys.length > 20, 'static page text is translatable');
  for (const key of keys) assert.ok(Object.hasOwn(locales[defaultLanguage].messages, key), key);
});

test('phase labels are translated and an unknown phase shows as written', () => {
  assert.equal(phaseLabel(translator('ko'), 'evidence'), '검증');
  assert.equal(phaseLabel(translator('en'), 'evidence'), 'Evidence');
  assert.equal(phaseLabel(translator('ko'), 'review'), 'Review');
});
