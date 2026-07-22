#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(scriptDirectory, '..');
const markdownPath = resolve(repositoryRoot, 'docs/MIGRATION_GUIDE.md');
const htmlPath = resolve(repositoryRoot, 'docs/migration-guide.html');
const markdown = readFileSync(markdownPath, 'utf8').replace(/\r\n/g, '\n');

function escapeHtml(value) {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
}

function slugify(value) {
  return value
    .toLowerCase()
    .replace(/[`*_]/g, '')
    .replace(/[^a-z0-9\s-]/g, '')
    .trim()
    .replace(/[\s-]+/g, '-');
}

function renderInline(value) {
  const codeTokens = [];
  const linkTokens = [];
  let rendered = value.replace(/`([^`]+)`/g, (_match, code) => {
    const token = `@@CODE${codeTokens.length}@@`;
    codeTokens.push(`<code>${escapeHtml(code)}</code>`);
    return token;
  });

  rendered = rendered.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+|[^\s)]+)\)/g, (_match, label, href) => {
    const token = `@@LINK${linkTokens.length}@@`;
    linkTokens.push(`<a href="${escapeHtml(href)}">${escapeHtml(label)}</a>`);
    return token;
  });

  rendered = escapeHtml(rendered)
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/\*([^*]+)\*/g, '<em>$1</em>');

  codeTokens.forEach((token, index) => {
    rendered = rendered.replace(`@@CODE${index}@@`, token);
  });
  linkTokens.forEach((token, index) => {
    rendered = rendered.replace(`@@LINK${index}@@`, token);
  });
  return rendered;
}

function splitTableRow(line) {
  return line
    .trim()
    .replace(/^\|/, '')
    .replace(/\|$/, '')
    .split('|')
    .map((cell) => cell.trim());
}

function isBlockStart(lines, index) {
  const line = lines[index] ?? '';
  const next = lines[index + 1] ?? '';
  return /^#{1,6}\s+/.test(line)
    || /^```/.test(line)
    || /^[-*]\s+/.test(line)
    || /^\d+\.\s+/.test(line)
    || (line.trim().startsWith('|') && /^\|?\s*:?-{3,}/.test(next.trim().replace(/^\|/, '')));
}

function renderMarkdown(source) {
  const lines = source.split('\n');
  const output = [];
  const headings = [];
  let index = 0;

  while (index < lines.length) {
    const line = lines[index];
    if (!line.trim()) {
      index += 1;
      continue;
    }

    const heading = line.match(/^(#{1,6})\s+(.+)$/);
    if (heading) {
      const level = heading[1].length;
      const label = heading[2];
      const id = slugify(label);
      headings.push({ level, label: label.replace(/`/g, ''), id });
      output.push(`<h${level} id="${id}">${renderInline(label)}<a class="anchor" href="#${id}" aria-label="Link to this section">#</a></h${level}>`);
      index += 1;
      continue;
    }

    const fence = line.match(/^```\s*([\w-]*)\s*$/);
    if (fence) {
      const language = fence[1];
      const code = [];
      index += 1;
      while (index < lines.length && !/^```\s*$/.test(lines[index])) {
        code.push(lines[index]);
        index += 1;
      }
      index += 1;
      const className = language ? ` class="language-${escapeHtml(language)}"` : '';
      output.push(`<pre><code${className}>${escapeHtml(code.join('\n'))}</code></pre>`);
      continue;
    }

    if (
      line.trim().startsWith('|')
      && index + 1 < lines.length
      && /^\|?\s*:?-{3,}/.test(lines[index + 1].trim().replace(/^\|/, ''))
    ) {
      const headers = splitTableRow(line);
      index += 2;
      const rows = [];
      while (index < lines.length && lines[index].trim().startsWith('|')) {
        rows.push(splitTableRow(lines[index]));
        index += 1;
      }
      output.push('<div class="table-scroll"><table><thead><tr>');
      headers.forEach((cell) => output.push(`<th>${renderInline(cell)}</th>`));
      output.push('</tr></thead><tbody>');
      rows.forEach((row) => {
        output.push('<tr>');
        row.forEach((cell) => output.push(`<td>${renderInline(cell)}</td>`));
        output.push('</tr>');
      });
      output.push('</tbody></table></div>');
      continue;
    }

    const unordered = line.match(/^[-*]\s+(.+)$/);
    const ordered = line.match(/^\d+\.\s+(.+)$/);
    if (unordered || ordered) {
      const orderedList = Boolean(ordered);
      const pattern = orderedList ? /^\d+\.\s+(.+)$/ : /^[-*]\s+(.+)$/;
      const tag = orderedList ? 'ol' : 'ul';
      output.push(`<${tag}>`);
      while (index < lines.length) {
        const item = lines[index].match(pattern);
        if (!item) break;
        let content = item[1];
        if (!orderedList && /^\[[ xX]\]\s+/.test(content)) {
          const checked = /^\[[xX]\]/.test(content);
          content = content.replace(/^\[[ xX]\]\s+/, '');
          output.push(`<li class="check"><input type="checkbox" disabled${checked ? ' checked' : ''}> ${renderInline(content)}</li>`);
        } else {
          output.push(`<li>${renderInline(content)}</li>`);
        }
        index += 1;
      }
      output.push(`</${tag}>`);
      continue;
    }

    const paragraph = [line.trim()];
    index += 1;
    while (index < lines.length && lines[index].trim() && !isBlockStart(lines, index)) {
      paragraph.push(lines[index].trim());
      index += 1;
    }
    output.push(`<p>${renderInline(paragraph.join(' '))}</p>`);
  }

  return { body: output.join('\n'), headings };
}

const { body, headings } = renderMarkdown(markdown);
const tableOfContents = headings
  .filter(({ level }) => level === 2)
  .map(({ label, id }) => `<li><a href="#${id}">${escapeHtml(label)}</a></li>`)
  .join('\n');
const sourceHash = createHash('sha256').update(markdown).digest('hex');

const html = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="description" content="Complete migration runbook for the homelabCloud services">
  <meta name="source-sha256" content="${sourceHash}">
  <title>Homelab Server Migration Guide</title>
  <style>
    :root { color-scheme: light dark; --bg: #f7f8fa; --panel: #fff; --text: #172033; --muted: #5d687a; --line: #d8dee9; --accent: #1769aa; --code: #eef2f7; --warn: #fff8dd; }
    @media (prefers-color-scheme: dark) { :root { --bg: #10141c; --panel: #171d28; --text: #e8edf5; --muted: #aeb8c8; --line: #394254; --accent: #70b7ff; --code: #202838; --warn: #362f16; } }
    * { box-sizing: border-box; }
    html { scroll-behavior: smooth; }
    body { margin: 0; background: var(--bg); color: var(--text); font: 16px/1.62 system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    .layout { display: grid; grid-template-columns: minmax(220px, 290px) minmax(0, 980px); gap: 2rem; max-width: 1340px; margin: 0 auto; padding: 2rem; }
    nav { position: sticky; top: 1rem; align-self: start; max-height: calc(100vh - 2rem); overflow: auto; padding: 1.25rem; background: var(--panel); border: 1px solid var(--line); border-radius: 12px; }
    nav strong { display: block; margin-bottom: .75rem; }
    nav ol { margin: 0; padding-left: 1.25rem; font-size: .92rem; }
    nav li { margin: .35rem 0; }
    nav .source { display: block; margin-top: 1rem; font-size: .85rem; color: var(--muted); }
    main { min-width: 0; padding: 2.4rem 3rem; background: var(--panel); border: 1px solid var(--line); border-radius: 12px; box-shadow: 0 10px 30px rgb(0 0 0 / 7%); }
    h1, h2, h3 { line-height: 1.25; scroll-margin-top: 1rem; }
    h1 { margin-top: 0; font-size: clamp(2rem, 5vw, 3.2rem); }
    h2 { margin-top: 2.8rem; padding-bottom: .35rem; border-bottom: 1px solid var(--line); }
    h3 { margin-top: 2rem; }
    .anchor { margin-left: .45rem; color: var(--muted); text-decoration: none; opacity: 0; font-weight: 400; }
    h1:hover .anchor, h2:hover .anchor, h3:hover .anchor { opacity: 1; }
    a { color: var(--accent); }
    p, li { max-width: 82ch; }
    li { margin: .3rem 0; }
    code { padding: .12rem .3rem; background: var(--code); border-radius: 4px; font: .9em ui-monospace, SFMono-Regular, Consolas, monospace; }
    pre { overflow: auto; padding: 1rem 1.15rem; background: var(--code); border: 1px solid var(--line); border-radius: 8px; line-height: 1.45; }
    pre code { padding: 0; background: transparent; }
    .table-scroll { overflow-x: auto; margin: 1.25rem 0; }
    table { width: 100%; border-collapse: collapse; font-size: .93rem; }
    th, td { padding: .65rem .75rem; border: 1px solid var(--line); text-align: left; vertical-align: top; }
    th { background: var(--code); }
    .check { list-style: none; margin-left: -1.4rem; }
    input[type="checkbox"] { vertical-align: middle; }
    .generated { margin-top: 4rem; padding-top: 1rem; border-top: 1px solid var(--line); color: var(--muted); font-size: .85rem; }
    @media (max-width: 860px) { .layout { display: block; padding: .75rem; } nav { position: static; max-height: none; margin-bottom: .75rem; } main { padding: 1.4rem; } }
    @media print { body { background: #fff; color: #000; font-size: 10pt; } .layout { display: block; max-width: none; padding: 0; } nav { display: none; } main { padding: 0; border: 0; box-shadow: none; } pre, table { break-inside: avoid; } a { color: #000; text-decoration: none; } .anchor { display: none; } }
  </style>
</head>
<body>
  <div class="layout">
    <nav aria-label="Table of contents">
      <strong>Contents</strong>
      <ol>${tableOfContents}</ol>
      <a class="source" href="MIGRATION_GUIDE.md">Open Markdown source</a>
    </nav>
    <main>
${body}
      <p class="generated">Generated from <code>docs/MIGRATION_GUIDE.md</code>. Source SHA-256: <code>${sourceHash}</code>.</p>
    </main>
  </div>
</body>
</html>
`;

writeFileSync(htmlPath, html, 'utf8');
console.log(`Rendered ${htmlPath}`);
