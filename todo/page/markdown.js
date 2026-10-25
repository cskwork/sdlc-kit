// Deliberately small Markdown: raw HTML and non-HTTP links never become markup.
const escape = text => text.replace(/&/g, '&amp;').replace(/</g, '&lt;')
  .replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
const unescape = text => text.replace(/&(?:amp|lt|gt|quot|#39);/g,
  entity => ({ '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&#39;': "'" })[entity]);

function inline(text, links = true) {
  let html = '', i = 0;
  while (i < text.length) {
    if (text[i] === '\\' && /[\\`*_[\]{}()#+.!|>-]/.test(text[i + 1] || '')) {
      html += text[i + 1]; i += 2; continue;
    }
    if (text[i] === '`') {
      const ticks = text.slice(i).match(/^`+/)[0];
      const end = text.indexOf(ticks, i + ticks.length);
      if (end >= 0) {
        html += `<code>${text.slice(i + ticks.length, end).replace(/\n/g, ' ')}</code>`;
        i = end + ticks.length; continue;
      }
    }
    const bold = text.slice(i, i + 2);
    if (bold === '**' || bold === '__') {
      const end = text.indexOf(bold, i + 2);
      if (end > i + 2) {
        html += `<strong>${inline(text.slice(i + 2, end), links)}</strong>`;
        i = end + 2; continue;
      }
    }
    if (links && text[i] === '[') {
      const labelEnd = text.indexOf('](', i + 1);
      if (labelEnd >= 0) {
        let end = labelEnd + 2, depth = 1;
        for (; end < text.length; end++) {
          if (text[end] === '(') depth++;
          if (text[end] === ')' && --depth === 0) break;
        }
        if (depth === 0) {
          const destination = text.slice(labelEnd + 2, end).trim();
          const url = unescape(destination);
          let safe = /^https?:\/\/[^\s<>"'\\]+$/i.test(url);
          try { safe = safe && /^https?:$/.test(new URL(url).protocol); } catch { safe = false; }
          const label = inline(text.slice(i + 1, labelEnd), false);
          html += safe ? `<a href="${destination}" rel="noopener noreferrer" target="_blank">${label}</a>` : label;
          i = end + 1; continue;
        }
      }
    }
    html += text[i++];
  }
  return html;
}

function cells(line) {
  const values = [''];
  let escaped = false;
  for (const char of line.trim()) {
    if (char === '|' && !escaped) values.push('');
    else values[values.length - 1] += char;
    escaped = char === '\\' && !escaped;
  }
  if (!values[0].trim()) values.shift();
  if (values.length && !values.at(-1).trim()) values.pop();
  return values.map(value => value.trim());
}
const listItem = line => line.match(/^( *)([-+*]|\d+[.)])\s+(.*)$/);
const fence = line => line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
const heading = line => line.match(/^ {0,3}(#{1,6})\s+(.+?)(?:\s+#+)?\s*$/);
const rule = line => /^ {0,3}(?:(?:\*\s*){3,}|(?:-\s*){3,}|(?:_\s*){3,})$/.test(line);
const quote = line => /^ {0,3}&gt; ?/.test(line);
function isTable(lines, i) {
  if (i + 1 >= lines.length || !lines[i].includes('|')) return false;
  const columns = cells(lines[i + 1]);
  return columns.length > 0 && columns.every(cell => /^:?-{3,}:?$/.test(cell)) && columns.length === cells(lines[i]).length;
}
function blocks(lines) {
  let html = '', i = 0;
  const startsBlock = index => heading(lines[index]) || fence(lines[index]) || rule(lines[index]) ||
    quote(lines[index]) || listItem(lines[index]) || isTable(lines, index);
  while (i < lines.length) {
    if (!lines[i].trim()) { i++; continue; }
    const code = fence(lines[i]);
    if (code) {
      const body = [], marker = code[1][0], length = code[1].length;
      i++;
      while (i < lines.length && !new RegExp(`^ {0,3}${marker === '`' ? '`' : '~'}{${length},}\\s*$`).test(lines[i])) body.push(lines[i++]);
      if (i < lines.length) i++;
      html += `<pre><code>${body.join('\n')}${body.length ? '\n' : ''}</code></pre>\n`; continue;
    }
    const title = heading(lines[i]);
    if (title) { html += `<h${title[1].length}>${inline(title[2])}</h${title[1].length}>\n`; i++; continue; }
    if (rule(lines[i])) { html += '<hr>\n'; i++; continue; }
    if (quote(lines[i])) {
      const body = [];
      while (i < lines.length && quote(lines[i])) body.push(lines[i++].replace(/^ {0,3}&gt; ?/, ''));
      html += `<blockquote>${blocks(body)}</blockquote>\n`; continue;
    }
    if (isTable(lines, i)) {
      const headers = cells(lines[i]); i += 2;
      html += `<div class="table-scroll"><table><thead><tr>${headers.map(value => `<th scope="col">${inline(value)}</th>`).join('')}</tr></thead><tbody>`;
      while (i < lines.length && lines[i].trim() && lines[i].includes('|')) {
        const row = cells(lines[i++]);
        html += `<tr>${headers.map((_, column) => `<td>${inline(row[column] || '')}</td>`).join('')}</tr>`;
      }
      html += '</tbody></table></div>\n'; continue;
    }
    const first = listItem(lines[i]);
    if (first) {
      const base = first[1].length, ordered = /^\d/.test(first[2]), tag = ordered ? 'ol' : 'ul';
      html += `<${tag}>`;
      while (i < lines.length) {
        const item = listItem(lines[i]);
        if (!item || item[1].length !== base || /^\d/.test(item[2]) !== ordered) break;
        const contentIndent = lines[i].indexOf(item[3], base + item[2].length);
        const body = [item[3]]; i++;
        while (i < lines.length) {
          if (!lines[i].trim()) {
            let next = i + 1;
            while (next < lines.length && !lines[next].trim()) next++;
            if (next >= lines.length || lines[next].match(/^ */)[0].length <= base) break;
            body.push(''); i++; continue;
          }
          const indent = lines[i].match(/^ */)[0].length;
          if (indent <= base) break;
          body.push(lines[i++].slice(Math.min(indent, contentIndent)));
        }
        const content = blocks(body).replace(/^<p>([\s\S]*?)<\/p>\n/, '$1\n');
        html += `<li>${content}</li>`;
        while (i < lines.length && !lines[i].trim()) i++;
      }
      html += `</${tag}>\n`; continue;
    }
    const paragraph = [lines[i++]];
    while (i < lines.length && lines[i].trim() && !startsBlock(i)) paragraph.push(lines[i++]);
    html += `<p>${inline(paragraph.join('\n'))}</p>\n`;
  }
  return html;
}

export function renderMarkdown(text) {
  // Comments are removed before escaping, including an unfinished final comment.
  const source = String(text ?? '').replace(/<!--[\s\S]*?(?:-->|$)/g, '').replace(/\r\n?/g, '\n');
  return blocks(escape(source).replace(/\t/g, '    ').split('\n'));
}
