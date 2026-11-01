// TaxStreem's public pages for e-invoicing: the Service Level Agreement (/sla), the API documentation (/developers) and
// the privacy notice (/privacy). No sign-in. The words live in ./content/*.md, written in a small part of Markdown that
// renderMarkdown below turns into React elements (headings, paragraphs, lists, tables, code blocks, bold, inline code and
// links); nothing in them is ever put in the page as HTML.
import { Fragment, useEffect, type ReactNode } from 'react';
import { Link, useLocation } from 'react-router-dom';
import sla from './content/sla.md?raw';
import developers from './content/developers.md?raw';
import privacy from './content/privacy.md?raw';

export const LEGAL_PAGES = [
  { path: '/sla', label: 'Service Level Agreement', short: 'SLA', text: sla },
  { path: '/developers', label: 'E-Invoicing API', short: 'API', text: developers },
  { path: '/privacy', label: 'Privacy Notice', short: 'Privacy', text: privacy },
] as const;

// ------------------------------------------------------------------ Markdown, the small part these pages use
const slug = (s: string) => s.toLowerCase().replace(/`/g, '').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
const safeHref = (h: string) => (/^(https:\/\/|http:\/\/|mailto:|\/|#)/i.test(h) ? h : '#');

// Bold, inline code and links inside one line of text.
export function inline(text: string, key = 'i'): ReactNode[] {
  const out: ReactNode[] = [];
  const re = /`([^`]+)`|\*\*([^*]+)\*\*|\[([^\]]+)\]\(([^)\s]+)\)/g;
  let last = 0, m: RegExpExecArray | null, n = 0;
  while ((m = re.exec(text))) {
    if (m.index > last) out.push(text.slice(last, m.index));
    const k = `${key}-${n++}`;
    if (m[1] !== undefined) out.push(<code key={k}>{m[1]}</code>);
    else if (m[2] !== undefined) out.push(<strong key={k}>{inline(m[2], k)}</strong>);
    else {
      const href = safeHref(m[4]);
      out.push(href.startsWith('/') && !href.startsWith('//')
        ? <Link key={k} to={href}>{inline(m[3], k)}</Link>
        : <a key={k} href={href} {...(/^https?:/i.test(href) ? { target: '_blank', rel: 'noopener noreferrer' } : {})}>{inline(m[3], k)}</a>);
    }
    last = re.lastIndex;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

const cells = (row: string) => row.trim().replace(/^\|/, '').replace(/\|$/, '').split(/(?<!\\)\|/).map((c) => c.trim().replace(/\\\|/g, '|'));

export function renderMarkdown(md: string): { body: ReactNode[]; headings: { id: string; text: string }[] } {
  const lines = md.replace(/\r\n/g, '\n').split('\n');
  const body: ReactNode[] = [];
  const headings: { id: string; text: string }[] = [];
  let i = 0, k = 0;
  const key = () => `b${k++}`;
  while (i < lines.length) {
    const line = lines[i];
    if (!line.trim()) { i++; continue; }
    // A fenced code block.
    const fence = line.match(/^```(\w*)\s*$/);
    if (fence) {
      const code: string[] = [];
      i++;
      while (i < lines.length && !/^```\s*$/.test(lines[i])) code.push(lines[i++]);
      i++;
      body.push(<pre key={key()} className="legal-code" data-lang={fence[1] || undefined}><code>{code.join('\n')}</code></pre>);
      continue;
    }
    const h = line.match(/^(#{1,4})\s+(.*)$/);
    if (h) {
      const level = h[1].length, text = h[2].trim(), id = slug(text);
      if (level === 2) headings.push({ id, text: text.replace(/`/g, '') });
      const Tag = (`h${level}`) as 'h1' | 'h2' | 'h3' | 'h4';
      body.push(<Tag key={key()} id={id}>{inline(text, id)}</Tag>);
      i++;
      continue;
    }
    // A table: a header row, a separator row, then rows.
    if (/^\s*\|/.test(line) && i + 1 < lines.length && /^\s*\|?\s*:?-{3,}/.test(lines[i + 1])) {
      const head = cells(line);
      i += 2;
      const rows: string[][] = [];
      while (i < lines.length && /^\s*\|/.test(lines[i])) rows.push(cells(lines[i++]));
      const tk = key();
      body.push(
        <div key={tk} className="legal-table"><table>
          <thead><tr>{head.map((c, j) => <th key={j}>{inline(c, `${tk}h${j}`)}</th>)}</tr></thead>
          <tbody>{rows.map((r, ri) => <tr key={ri}>{head.map((_, j) => <td key={j}>{inline(r[j] ?? '', `${tk}${ri}-${j}`)}</td>)}</tr>)}</tbody>
        </table></div>,
      );
      continue;
    }
    // A list: "- " or "1. ", one item per line, with lines indented under an item joining it.
    const li = line.match(/^(\s*)([-*]|\d+\.)\s+(.*)$/);
    if (li) {
      const ordered = /\d/.test(li[2]);
      const items: string[] = [];
      while (i < lines.length) {
        const m = lines[i].match(/^(\s*)([-*]|\d+\.)\s+(.*)$/);
        if (m && /\d/.test(m[2]) === ordered) { items.push(m[3]); i++; continue; }
        if (items.length && /^\s{2,}\S/.test(lines[i])) { items[items.length - 1] += ' ' + lines[i].trim(); i++; continue; }
        break;
      }
      const lk = key();
      const Tag = ordered ? 'ol' : 'ul';
      body.push(<Tag key={lk}>{items.map((t, j) => <li key={j}>{inline(t, `${lk}-${j}`)}</li>)}</Tag>);
      continue;
    }
    // A paragraph: lines until a blank line or another block.
    const para: string[] = [];
    while (i < lines.length && lines[i].trim() && !/^(#{1,4}\s|```|\s*\||\s*([-*]|\d+\.)\s)/.test(lines[i])) para.push(lines[i++].trim());
    const pk = key();
    body.push(<p key={pk}>{inline(para.join(' '), pk)}</p>);
  }
  return { body, headings };
}

// ------------------------------------------------------------------ the page
export default function LegalPage({ page }: { page: (typeof LEGAL_PAGES)[number]['path'] }) {
  const doc = LEGAL_PAGES.find((p) => p.path === page)!;
  const { body, headings } = renderMarkdown(doc.text);
  const { hash } = useLocation();
  useEffect(() => { document.title = `${doc.label} · TaxStreem`; }, [doc.label]);
  useEffect(() => {
    if (!hash) { window.scrollTo(0, 0); return; }
    const el = document.getElementById(decodeURIComponent(hash.slice(1)));
    if (el) el.scrollIntoView();
  }, [hash, page]);
  return (
    <div className="legal" data-testid="legal-page" data-page={page.slice(1)}>
      <header className="legal-top">
        <div className="legal-top-in">
          <Link to="/sla" className="legal-brand" aria-label="TaxStreem"><img src="/logo-brand.svg" alt="TaxStreem" /></Link>
          <nav className="legal-nav" aria-label="E-invoicing documents">
            {LEGAL_PAGES.map((p) => (
              <Link key={p.path} to={p.path} className={p.path === page ? 'on' : undefined} aria-current={p.path === page ? 'page' : undefined}>
                <span className="hide-sm">{p.label}</span><span className="show-sm">{p.short}</span>
              </Link>
            ))}
          </nav>
        </div>
      </header>
      <div className="legal-main">
        {headings.length > 3 && (
          <aside className="legal-toc hide-sm" aria-label="On this page">
            <div className="legal-toc-h">On this page</div>
            {headings.map((h) => <a key={h.id} href={`#${h.id}`}>{h.text}</a>)}
          </aside>
        )}
        <article className="legal-body">{body.map((b, j) => <Fragment key={j}>{b}</Fragment>)}</article>
      </div>
      <footer className="legal-foot">
        TaxStreem Technologies Limited, RC 8807119 · Silverwood Court 2, DPKAY Estate, Orchid Road, Lekki, Lagos ·{' '}
        <a href="mailto:support@taxstreem.com">support@taxstreem.com</a>
      </footer>
    </div>
  );
}
