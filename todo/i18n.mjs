// UI language registry. Add a language: write locales/<code>.mjs and list it here.
import en from './locales/en.mjs';
import ko from './locales/ko.mjs';

export const locales = { en, ko };
export const defaultLanguage = 'en';
export const languages = Object.keys(locales);
export const isLanguage = value => typeof value === 'string' && Object.hasOwn(locales, value);
export const nextLanguage = language => languages[(languages.indexOf(language) + 1) % languages.length];

// A flag must name a registered language; an unknown environment value falls back to the default.
export function resolveLanguage(flag, env) {
  if (flag === undefined) return isLanguage(env) ? env : defaultLanguage;
  if (!isLanguage(flag)) throw new RangeError(`invalid language: ${flag} (use ${languages.join('|')})`);
  return flag;
}

// t(key, vars): `{name}` takes vars.name; with vars.count, `key.<plural category>`, `key.other`, then `key` is used.
// sdlc phase name in the UI language; an unknown phase shows as written, capitalised.
export function phaseLabel(t, phase) {
  const key = `phase.${phase}`, text = t(key);
  return text === key ? phase[0].toUpperCase() + phase.slice(1) : text;
}

export function translator(language, registry = locales) {
  const own = registry[language] ? language : defaultLanguage;
  const sources = [[registry[own].messages, new Intl.PluralRules(own)],
    [registry[defaultLanguage].messages, new Intl.PluralRules(defaultLanguage)]];
  const find = (messages, rules, key, count) => count === undefined ? messages[key] :
    messages[`${key}.${rules.select(count)}`] ?? messages[`${key}.other`] ?? messages[key];
  return (key, vars = {}) => {
    let text = key;
    for (const [messages, rules] of sources) { const found = find(messages, rules, key, vars.count); if (found !== undefined) { text = found; break; } }
    return text.replace(/\{(\w+)\}/g, (match, name) => Object.hasOwn(vars, name) ? String(vars[name]) : match);
  };
}
