// Fills an official Excel template without touching anything else in it: only the input cells named are written, and every
// formula keeps its text. The cached result of each formula is recomputed (with the template's own formulas) so a reader that
// takes the stored values sees the same totals Excel shows, and Excel is told to recalculate on opening as well.
// Handles the formula forms the NRS templates use: cell and range references across sheets, + - * /, &, comparisons,
// SUM, SUMIF, IF, IFERROR, OR, AND, TRIM, INDEX, MATCH, TODAY, structured table references and shared formulas.
// A large template can be saved lazily: only the sheets written to, and those whose formulas read them, are recomputed
// (the rest keep the template's own stored values, and may hold formulas this evaluator does not know).
import { strFromU8, strToU8, unzipSync, zipSync } from 'npm:fflate@0.8.2';

export type Value = number | string | boolean | null;
type Cell = { addr: string; xml: string; style: string | null; type: string | null; f: string | null; fShared: { si: string; ref?: string } | null; v: string | null; inline: string | null };
type Sheet = { name: string; path: string; xml: string; cells: Map<string, Cell>; dirty: Map<string, Value>; added: Set<string>; rowAttrs: Map<number, string>;
  parsed: boolean; reads: Set<string> | null };
type Table = { name: string; sheet: string; ref: string; columns: string[]; path: string; header: number; totals: number; grown: boolean };

const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const unesc = (s: string) => s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, '&');

export function colNum(col: string) { let n = 0; for (const ch of col) n = n * 26 + (ch.charCodeAt(0) - 64); return n; }
export function colName(n: number) { let s = ''; while (n > 0) { const m = (n - 1) % 26; s = String.fromCharCode(65 + m) + s; n = Math.floor((n - 1) / 26); } return s; }
export function split(addr: string) { const m = /^\$?([A-Z]+)\$?(\d+)$/.exec(addr)!; return { col: colNum(m[1]), row: Number(m[2]) }; }

// Excel's date serial (the 1900 system) for a yyyy-mm-dd day.
export function serial(day: string) { const [y, m, d] = day.slice(0, 10).split('-').map(Number); return Math.round((Date.UTC(y, m - 1, d) - Date.UTC(1899, 11, 30)) / 86400000); }

export class Workbook {
  files: Record<string, Uint8Array>;
  order: string[];
  sheets = new Map<string, Sheet>();
  shared: string[] = [];
  tables = new Map<string, Table>();
  private cache = new Map<string, Value>();
  private stack = new Set<string>();
  private sharedMasters = new Map<string, { sheet: string; addr: string; f: string }>();

  // lazy: a sheet not written to, and not reading from one that is, keeps its stored values (nothing in it is evaluated, and it
  // is only parsed when read); a sheet's cells are parsed when first needed.
  lazy: boolean;
  constructor(bytes: Uint8Array, opts: { lazy?: boolean } = {}) {
    this.lazy = !!opts.lazy;
    this.files = unzipSync(bytes);
    this.order = Object.keys(this.files);
    const wb = strFromU8(this.files['xl/workbook.xml']);
    const rels = strFromU8(this.files['xl/_rels/workbook.xml.rels']);
    const target = new Map<string, string>();
    for (const m of rels.matchAll(/<Relationship\b([^>]*)\/?>/g)) {
      const id = /\bId="([^"]+)"/.exec(m[1])?.[1]; const t = /\bTarget="([^"]+)"/.exec(m[1])?.[1];
      if (id && t) target.set(id, t.startsWith('/') ? t.slice(1) : 'xl/' + t);
    }
    if (this.files['xl/sharedStrings.xml']) {
      const ss = strFromU8(this.files['xl/sharedStrings.xml']);
      for (const m of ss.matchAll(/<si>([\s\S]*?)<\/si>/g)) this.shared.push(unesc([...m[1].matchAll(/<t[^>]*>([\s\S]*?)<\/t>/g)].map((t) => t[1]).join('')));
    }
    for (const m of wb.matchAll(/<sheet\b([^>]*)\/>/g)) {
      const name = unesc(/\bname="([^"]+)"/.exec(m[1])![1]); const rid = /\br:id="([^"]+)"/.exec(m[1])![1];
      const path = target.get(rid)!;
      const xml = strFromU8(this.files[path]);
      const sh: Sheet = { name, path, xml, cells: new Map(), dirty: new Map(), added: new Set(), rowAttrs: new Map(), parsed: false, reads: null };
      this.sheets.set(name, sh);
      // Tables on this sheet.
      const relPath = path.replace(/worksheets\/(sheet\d+\.xml)$/, 'worksheets/_rels/$1.rels');
      if (this.files[relPath]) {
        const srels = strFromU8(this.files[relPath]);
        for (const r of srels.matchAll(/<Relationship\b([^>]*)\/?>/g)) {
          const t = /\bTarget="([^"]+)"/.exec(r[1])?.[1];
          if (!t || !/tables\//.test(t)) continue;
          const tp = t.startsWith('/') ? t.slice(1) : 'xl/' + t.replace(/^\.\.\//, '');
          const tx = strFromU8(this.files[tp]);
          const tname = /<table\b[^>]*\bname="([^"]+)"/.exec(tx)![1]; const ref = /<table\b[^>]*\bref="([^"]+)"/.exec(tx)![1];
          const columns = [...tx.matchAll(/<tableColumn\b[^>]*\bname="([^"]+)"/g)].map((c) => unesc(c[1]));
          // A table may have no header row (headerRowCount="0"), and may have a totals row.
          const header = /<table\b[^>]*\bheaderRowCount="0"/.test(tx) ? 0 : 1;
          const totals = Number(/<table\b[^>]*\btotalsRowCount="(\d+)"/.exec(tx)?.[1] || 0);
          this.tables.set(tname.toLowerCase(), { name: tname, sheet: name, ref, columns, path: tp, header, totals, grown: false });
        }
      }
    }
  }

  private parseCells(sh: Sheet) {
    sh.cells.clear();
    for (const m of sh.xml.matchAll(/<c\b([^>]*?)(\/>|>([\s\S]*?)<\/c>)/g)) {
      const attrs = m[1]; const body = m[3] || '';
      const addr = /\br="([A-Z]+\d+)"/.exec(attrs)![1];
      const fm = /<f\b([^>]*?)(?:\/>|>([\s\S]*?)<\/f>)/.exec(body);
      let fShared: Cell['fShared'] = null;
      if (fm && /t="shared"/.test(fm[1])) {
        fShared = { si: /si="(\d+)"/.exec(fm[1])![1], ref: /ref="([^"]+)"/.exec(fm[1])?.[1] };
        if (fm[2]) this.sharedMasters.set(sh.name + '|' + fShared.si, { sheet: sh.name, addr, f: unesc(fm[2]) });
      }
      sh.cells.set(addr, { addr, xml: m[0], style: /\bs="(\d+)"/.exec(attrs)?.[1] ?? null, type: /\bt="([^"]+)"/.exec(attrs)?.[1] ?? null,
        f: fm && fm[2] ? unesc(fm[2]) : null, fShared, v: /<v>([\s\S]*?)<\/v>/.exec(body)?.[1] ?? null,
        inline: /<is>([\s\S]*?)<\/is>/.exec(body) ? unesc([.../<is>([\s\S]*?)<\/is>/.exec(body)![1].matchAll(/<t[^>]*>([\s\S]*?)<\/t>/g)].map((t) => t[1]).join('')) : null });
    }
  }

  sheet(name: string) {
    const s = this.sheets.get(name); if (!s) throw new Error(`No sheet ${name}`);
    if (!s.parsed) { this.parseCells(s); s.parsed = true; }
    return s;
  }

  // The sheets a sheet's formulas read (itself included when it has any), from the formula text alone (a table counts as its sheet).
  private readsOf(sh: Sheet): Set<string> {
    if (sh.reads) return sh.reads;
    const out = new Set<string>();
    for (const m of sh.xml.matchAll(/<f\b[^>]*>([^<]+)<\/f>/g)) {
      const f = unesc(m[1]);
      out.add(sh.name);
      for (const r of f.matchAll(/(?:'((?:[^']|'')+)'|([A-Za-z_][\w.]*))!/g)) { const n = (r[1] ?? r[2]).replace(/''/g, "'"); if (this.sheets.has(n)) out.add(n); }
      for (const r of f.matchAll(/([A-Za-z_][\w.]*)\[/g)) { const t = this.tables.get(r[1].toLowerCase()); if (t) out.add(t.sheet); }
    }
    if ([...sh.xml.matchAll(/<f\b[^>]*\/>/g)].length) out.add(sh.name);
    return (sh.reads = out);
  }

  // The sheets whose values can differ from the template's: those written to, and every sheet that reads one of them.
  private affectedCache: Set<string> | null = null;
  affected(): Set<string> {
    if (this.affectedCache) return this.affectedCache;
    const out = new Set([...this.sheets.values()].filter((s) => s.dirty.size || s.added.size).map((s) => s.name));
    for (const t of this.tables.values()) if (t.grown) out.add(t.sheet);
    for (let changed = true; changed;) {
      changed = false;
      for (const sh of this.sheets.values()) {
        if (out.has(sh.name)) continue;
        if ([...this.readsOf(sh)].some((n) => n !== sh.name && out.has(n))) { out.add(sh.name); changed = true; }
      }
    }
    return (this.affectedCache = out);
  }

  // A cell's stored value straight from the sheet XML (a formula's cached result), without parsing the sheet.
  private stored(sheet: string, addr: string): Value {
    const sh = this.sheets.get(sheet)!;
    if (sh.parsed) { const c = sh.cells.get(addr); return c ? this.decode(c.type, c.v, c.inline) : null; }
    const m = new RegExp(`<c\\b[^>]*?\\br="${addr}"([^>]*?)(?:/>|>([\\s\\S]*?)</c>)`).exec(sh.xml);
    if (!m) return null;
    const attrs = m[0].slice(0, m[0].indexOf('>')); const body = m[2] || '';
    const inline = /<is>([\s\S]*?)<\/is>/.exec(body);
    return this.decode(/\bt="([^"]+)"/.exec(attrs)?.[1] ?? null, /<v>([\s\S]*?)<\/v>/.exec(body)?.[1] ?? null,
      inline ? unesc([...inline[1].matchAll(/<t[^>]*>([\s\S]*?)<\/t>/g)].map((t) => t[1]).join('')) : null);
  }
  private decode(type: string | null, v: string | null, inline: string | null): Value {
    if (inline != null) return inline;
    if (v == null) return null;
    if (type === 's') return this.shared[Number(v)] ?? '';
    if (type === 'str' || type === 'e') return unesc(v);
    if (type === 'b') return v === '1';
    const n = Number(v); return Number.isFinite(n) ? n : unesc(v);
  }

  // The last row of a sheet holding anything (a cell, written or not), so a range down to row 1,000,000 stops there.
  private lastRows = new Map<string, number>();
  lastRow(sheet: string): number {
    const hit = this.lastRows.get(sheet); if (hit != null) return hit;
    const sh = this.sheet(sheet); let max = 0;
    for (const a of sh.cells.keys()) { const r = Number(/\d+$/.exec(a)![0]); if (r > max) max = r; }
    for (const a of sh.dirty.keys()) { const r = Number(/\d+$/.exec(a)![0]); if (r > max) max = r; }
    this.lastRows.set(sheet, max);
    return max;
  }

  // Make a table reach down to a row (the rows below the template's own are added with cloneRow first).
  growTable(name: string, lastRow: number) {
    const t = this.tables.get(name.toLowerCase()); if (!t) throw new Error(`No table ${name}`);
    const [a, b] = t.ref.split(':'); const q = split(b);
    if (lastRow <= q.row) return;
    t.ref = `${a}:${colName(q.col)}${lastRow}`; t.grown = true;
    this.cache.clear(); this.affectedCache = null;
  }

  // The formula of a cell, with a shared formula moved to the cell's own position.
  formula(sheet: string, addr: string): string | null {
    const c = this.sheet(sheet).cells.get(addr);
    if (!c) return null;
    if (c.f && !(c.fShared && !c.f)) return c.f;
    if (c.fShared) {
      const master = this.sharedMasters.get(sheet + '|' + c.fShared.si);
      if (!master) return null;
      const a = split(master.addr), b = split(addr);
      return shift(master.f, b.row - a.row, b.col - a.col);
    }
    return null;
  }

  // Raw (stored or written) value of a cell, without evaluating.
  private raw(sheet: string, addr: string): Value {
    const sh = this.sheet(sheet);
    if (sh.dirty.has(addr)) return sh.dirty.get(addr)!;
    const c = sh.cells.get(addr);
    if (!c) return null;
    return this.decode(c.type, c.v, c.inline);
  }

  // Copy a row's cells (styles, and formulas moved to the new row) to a row the template does not have, so a list can grow
  // past the template's sample row. Cells already in the target row are left alone.
  cloneRow(sheet: string, from: number, to: number) {
    const sh = this.sheet(sheet);
    const rm = new RegExp(`<row\\b([^>]*\\br="${from}"[^>]*?)(?:/>|>)`).exec(sh.xml);
    if (rm && !sh.rowAttrs.has(to)) sh.rowAttrs.set(to, rm[1].replace(/\br="\d+"/, `r="${to}"`).replace(/\s*\/$/, ''));
    for (const c of [...sh.cells.values()]) {
      const p = split(c.addr); if (p.row !== from) continue;
      const addr = colName(p.col) + to;
      if (sh.cells.has(addr)) continue;
      const f = this.formula(sheet, c.addr);
      const moved = f == null ? null : shift(f, to - from, 0);
      sh.cells.set(addr, { addr, xml: moved == null ? '' : `<c r="${addr}"><f>${esc(moved)}</f></c>`, style: c.style, type: null, f: moved, fShared: null, v: null, inline: null });
      sh.added.add(addr);
    }
    this.cache.clear(); this.lastRows.delete(sheet); this.affectedCache = null;
  }

  set(sheet: string, addr: string, value: Value) {
    const sh = this.sheet(sheet);
    const c = sh.cells.get(addr);
    if (c && (c.f || c.fShared)) throw new Error(`${sheet}!${addr} holds a formula; it is not an input`);
    if (!sh.dirty.size) this.affectedCache = null;
    sh.dirty.set(addr, value);
    this.cache.clear(); this.lastRows.delete(sheet);
  }

  // Value of a cell: a formula is evaluated, anything else read.
  value(sheet: string, addr: string): Value {
    addr = addr.replace(/\$/g, '');
    const key = sheet + '!' + addr;
    if (this.cache.has(key)) return this.cache.get(key)!;
    if (this.lazy && !this.affected().has(sheet)) { const v = this.stored(sheet, addr); this.cache.set(key, v); return v; }
    const f = this.sheet(sheet).dirty.has(addr) ? null : this.formula(sheet, addr);
    let v: Value;
    if (f == null) v = this.raw(sheet, addr);
    else {
      if (this.stack.has(key)) throw new Error(`Circular reference at ${key}`);
      this.stack.add(key);
      try { v = new Evaluator(this, sheet, addr).run(f); } finally { this.stack.delete(key); }
    }
    this.cache.set(key, v);
    return v;
  }

  // Write the inputs and every formula's freshly computed value into the sheet XML.
  private render(sh: Sheet) {
    let xml = sh.xml;
    const updates = new Map<string, string>();
    for (const [addr, val] of sh.dirty) updates.set(addr, this.cellXml(sh, addr, val, null));
    for (const c of sh.cells.values()) {
      if (sh.dirty.has(c.addr)) continue;
      if (c.f || c.fShared) updates.set(c.addr, this.cellXml(sh, c.addr, this.value(sh.name, c.addr), c));
      else if (sh.added.has(c.addr)) updates.set(c.addr, this.cellXml(sh, c.addr, null, null));
    }
    // Replace existing cells in place; add cells that are not in the sheet yet in column order within their row.
    xml = xml.replace(/<c\b([^>]*?)(\/>|>([\s\S]*?)<\/c>)/g, (whole, attrs) => {
      const addr = /\br="([A-Z]+\d+)"/.exec(attrs)![1];
      const u = updates.get(addr); if (u == null) return whole;
      updates.delete(addr); return u;
    });
    if (updates.size) {
      const byRow = new Map<number, [number, string][]>();
      for (const [addr, x] of updates) { const p = split(addr); if (!byRow.has(p.row)) byRow.set(p.row, []); byRow.get(p.row)!.push([p.col, x]); }
      for (const [row, list] of [...byRow.entries()].sort((a, b) => a[0] - b[0])) {
        list.sort((a, b) => a[0] - b[0]);
        const rowRe = new RegExp(`<row\\b[^>]*\\br="${row}"[^>]*?(?:/>|>([\\s\\S]*?)</row>)`);
        const rm = rowRe.exec(xml);
        if (rm) {
          const open = /<row\b[^>]*?(?=\/?>)/.exec(rm[0])![0];
          let inner = rm[1] || '';
          for (const [col, x] of list) {
            const cells = [...inner.matchAll(/<c\b[^>]*?\br="([A-Z]+)\d+"[\s\S]*?(?:\/>|<\/c>)/g)];
            const after = cells.find((cm) => colNum(cm[1]) > col);
            inner = after ? inner.slice(0, after.index!) + x + inner.slice(after.index!) : inner + x;
          }
          xml = xml.replace(rm[0], `${open.replace(/\s*\/$/, '')}>${inner}</row>`);
        } else {
          const newRow = `<row ${sh.rowAttrs.get(row) ?? `r="${row}"`}>${list.map((l) => l[1]).join('')}</row>`;
          const rows = [...xml.matchAll(/<row\b[^>]*\br="(\d+)"[^>]*?(?:\/>|>[\s\S]*?<\/row>)/g)];
          const next = rows.find((r) => Number(r[1]) > row);
          if (next) xml = xml.slice(0, next.index!) + newRow + xml.slice(next.index!);
          else xml = xml.replace(/<sheetData\s*\/>/, `<sheetData>${newRow}</sheetData>`).replace('</sheetData>', `${newRow}</sheetData>`);
        }
      }
      // Keep the sheet's used range covering what was written.
      const max = [...xml.matchAll(/<c\b[^>]*?\br="([A-Z]+)(\d+)"/g)].reduce((a, m) => ({ c: Math.max(a.c, colNum(m[1])), r: Math.max(a.r, Number(m[2])) }), { c: 1, r: 1 });
      xml = xml.replace(/<dimension ref="([A-Z]+\d+)(?::([A-Z]+\d+))?"\/>/, (_w, a) => `<dimension ref="${a}:${colName(max.c)}${max.r}"/>`);
    }
    return xml;
  }

  private cellXml(sh: Sheet, addr: string, val: Value, c: Cell | null) {
    const existing = c ?? sh.cells.get(addr) ?? null;
    const style = existing?.style != null ? ` s="${existing.style}"` : '';
    let fXml = '';
    if (c) {
      const fm = /<f\b[\s\S]*?(?:\/>|<\/f>)/.exec(c.xml); fXml = fm ? fm[0] : '';
    }
    if (val == null || val === '') {
      if (c) return `<c r="${addr}"${style}${typeof val === 'string' ? ' t="str"' : ''}>${fXml}${typeof val === 'string' ? '<v></v>' : ''}</c>`;
      return `<c r="${addr}"${style}/>`;
    }
    if (typeof val === 'number') return `<c r="${addr}"${style}>${fXml}<v>${Number.isInteger(val) ? val : +val.toFixed(10)}</v></c>`;
    if (typeof val === 'boolean') return `<c r="${addr}"${style} t="b">${fXml}<v>${val ? 1 : 0}</v></c>`;
    if (c && /^#(N\/A|DIV\/0!|VALUE!|REF!|NAME\?|NUM!|NULL!)$/.test(val)) return `<c r="${addr}"${style} t="e">${fXml}<v>${val}</v></c>`;
    if (c) return `<c r="${addr}"${style} t="str">${fXml}<v>${esc(val)}</v></c>`;
    return `<c r="${addr}"${style} t="inlineStr"><is><t xml:space="preserve">${esc(val)}</t></is></c>`;
  }

  save(opts: { level?: 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 } = {}): Uint8Array {
    let addedFormulas = false;
    // Lazily, only the sheets whose values can have changed are rewritten.
    const render = this.lazy ? this.affected() : null;
    for (const t of this.tables.values()) {
      if (!t.grown) continue;
      this.files[t.path] = strToU8(strFromU8(this.files[t.path]).replace(/(<table\b[^>]*\bref=")[^"]+(")/, `$1${t.ref}$2`)
        .replace(/(<autoFilter\b[^>]*\bref=")[^"]+(")/, `$1${t.ref}$2`));
    }
    for (const name of this.sheets.keys()) {
      if (render && !render.has(name)) continue;
      const sh = this.sheet(name);
      const hasFormula = [...sh.cells.values()].some((c) => c.f || c.fShared);
      if (!sh.dirty.size && !hasFormula && !sh.added.size) continue;
      this.files[sh.path] = strToU8(this.render(sh));
      if ([...sh.added].some((a) => sh.cells.get(a)?.f)) addedFormulas = true;
    }
    // The calculation chain lists formula cells; with new ones added it is dropped and Excel rebuilds it.
    if (addedFormulas && this.files['xl/calcChain.xml']) {
      delete this.files['xl/calcChain.xml'];
      this.order = this.order.filter((k) => k !== 'xl/calcChain.xml');
      const ct = strFromU8(this.files['[Content_Types].xml']).replace(/<Override\b[^>]*PartName="\/xl\/calcChain\.xml"[^>]*\/>/, '');
      this.files['[Content_Types].xml'] = strToU8(ct);
      const rels = strFromU8(this.files['xl/_rels/workbook.xml.rels']).replace(/<Relationship\b[^>]*Target="[^"]*calcChain\.xml"[^>]*\/>/, '');
      this.files['xl/_rels/workbook.xml.rels'] = strToU8(rels);
    }
    // Excel recalculates everything when the file is opened.
    let wb = strFromU8(this.files['xl/workbook.xml']);
    if (/<calcPr\b/.test(wb)) wb = wb.replace(/<calcPr\b([^>]*?)\/>/, (_w, a) => `<calcPr${a.replace(/\s*fullCalcOnLoad="[^"]*"/, '')} fullCalcOnLoad="1"/>`);
    else wb = wb.replace('</workbook>', '<calcPr fullCalcOnLoad="1"/></workbook>');
    this.files['xl/workbook.xml'] = strToU8(wb);
    const out: Record<string, Uint8Array> = {};
    for (const k of this.order) out[k] = this.files[k];
    return zipSync(out, { level: opts.level ?? 6 });
  }
}

// Move a formula's relative references by rows and columns (for shared formulas).
export function shift(f: string, dr: number, dc: number) {
  return f.replace(/("[^"]*")|(\[[^\]]*\])|(?<![\w.$'])((?:'[^']+'|[A-Za-z_][\w.]*)!)?(\$?)([A-Z]{1,3})(\$?)(\d+)(?![\w(])/g,
    (m, str, br, sheet, cAbs, col, rAbs, row) => {
      if (str || br) return m;
      const c = cAbs ? col : colName(colNum(col) + dc); const r = rAbs ? row : String(Number(row) + dr);
      return `${sheet || ''}${cAbs}${c}${rAbs}${r}`;
    });
}

// ---- Formula evaluation: parse to a tree, then evaluate (IF, IFERROR, AND and OR only evaluate what they need). ----
type Tok = { t: 'num' | 'str' | 'ref' | 'func' | 'op' | 'lp' | 'rp' | 'comma' | 'struct' | 'bool'; v: string };
type Range = { sheet: string; c1: number; r1: number; c2: number; r2: number };
type EV = Value | Range;
type Node =
  | { k: 'lit'; v: Value }
  | { k: 'ref'; v: string }
  | { k: 'struct'; v: string }
  | { k: 'neg'; a: Node }
  | { k: 'bin'; op: string; a: Node; b: Node }
  | { k: 'call'; name: string; args: Node[] };

export class FormulaError extends Error {}

const parsed = new Map<string, Node>();
function parse(f: string): Node {
  const hit = parsed.get(f); if (hit) return hit;
  const toks = tokenize(f); let i = 0;
  const peek = () => toks[i]; const next = () => toks[i++];
  const isOp = (...ops: string[]) => peek()?.t === 'op' && ops.includes(peek().v);
  const expect = (t: Tok['t']) => { const x = next(); if (!x || x.t !== t) throw new Error(`Expected ${t} in ${f}`); };
  const compare = (): Node => { let a = concat(); while (isOp('=', '<>', '<', '>', '<=', '>=')) { const op = next().v; a = { k: 'bin', op, a, b: concat() }; } return a; };
  const concat = (): Node => { let a = add(); while (isOp('&')) { next(); a = { k: 'bin', op: '&', a, b: add() }; } return a; };
  const add = (): Node => { let a = mul(); while (isOp('+', '-')) { const op = next().v; a = { k: 'bin', op, a, b: mul() }; } return a; };
  const mul = (): Node => { let a = unary(); while (isOp('*', '/')) { const op = next().v; a = { k: 'bin', op, a, b: unary() }; } return a; };
  const unary = (): Node => { if (isOp('-', '+')) { const op = next().v; const a = unary(); return op === '-' ? { k: 'neg', a } : a; } return primary(); };
  const primary = (): Node => {
    const t = next();
    if (!t) throw new Error(`Unexpected end of formula ${f}`);
    if (t.t === 'num') return { k: 'lit', v: Number(t.v) };
    if (t.t === 'str') return { k: 'lit', v: t.v };
    if (t.t === 'bool') return { k: 'lit', v: t.v === 'TRUE' };
    if (t.t === 'lp') { const v = compare(); expect('rp'); return v; }
    if (t.t === 'ref') return { k: 'ref', v: t.v };
    if (t.t === 'struct') return { k: 'struct', v: t.v };
    if (t.t === 'func') {
      const args: Node[] = []; expect('lp');
      if (peek()?.t !== 'rp') for (;;) { args.push(compare()); if (peek()?.t === 'comma') { next(); continue; } break; }
      expect('rp');
      return { k: 'call', name: t.v.toUpperCase().replace(/^_XLFN\./, ''), args };
    }
    throw new Error(`Unexpected "${t.v}" in ${f}`);
  };
  const tree = compare();
  if (i < toks.length) throw new Error(`Unexpected "${toks[i].v}" in ${f}`);
  parsed.set(f, tree);
  return tree;
}

export function tokenize(f: string): Tok[] {
  const out: Tok[] = []; let i = 0;
  while (i < f.length) {
    const ch = f[i]; const rest = f.slice(i);
    if (/\s/.test(ch)) { i++; continue; }
    if (ch === '"') { let j = i + 1, s = ''; while (j < f.length) { if (f[j] === '"') { if (f[j + 1] === '"') { s += '"'; j += 2; continue; } break; } s += f[j++]; } out.push({ t: 'str', v: s }); i = j + 1; continue; }
    if (ch === '(') { out.push({ t: 'lp', v: ch }); i++; continue; }
    if (ch === ')') { out.push({ t: 'rp', v: ch }); i++; continue; }
    if (ch === ',') { out.push({ t: 'comma', v: ch }); i++; continue; }
    const two = f.slice(i, i + 2);
    if (two === '<>' || two === '<=' || two === '>=') { out.push({ t: 'op', v: two }); i += 2; continue; }
    if ('+-*/&=<>'.includes(ch)) { out.push({ t: 'op', v: ch }); i++; continue; }
    const bm = /^(TRUE|FALSE)(?![\w(!])/i.exec(rest);
    if (bm) { out.push({ t: 'bool', v: bm[1].toUpperCase() }); i += bm[0].length; continue; }
    const rm = /^(?:(?:'(?:[^']|'')+'|[A-Za-z_][\w.]*)!)?\$?[A-Z]{1,3}\$?\d+(?::\$?[A-Z]{1,3}\$?\d+)?(?![\w(\[])/.exec(rest);
    if (rm) { out.push({ t: 'ref', v: rm[0] }); i += rm[0].length; continue; }
    if (/[0-9.]/.test(ch)) { const m = /^[0-9]*\.?[0-9]+(?:[eE][+-]?\d+)?/.exec(rest)!; out.push({ t: 'num', v: m[0] }); i += m[0].length; continue; }
    const fm = /^[A-Za-z_][\w.]*(?=\s*\()/.exec(rest);
    if (fm) { out.push({ t: 'func', v: fm[0] }); i += fm[0].length; continue; }
    // Structured reference: name[...] with nested brackets.
    const sm = /^([A-Za-z_][\w.]*)\[/.exec(rest);
    if (sm) {
      let j = i + sm[1].length, depth = 0;
      for (; j < f.length; j++) { if (f[j] === '[') depth++; else if (f[j] === ']') { depth--; if (depth === 0) { j++; break; } } }
      out.push({ t: 'struct', v: f.slice(i, j) }); i = j; continue;
    }
    throw new Error(`Cannot read formula at "${f.slice(i, i + 20)}"`);
  }
  return out;
}

class Evaluator {
  constructor(private wb: Workbook, private sheet: string, private at: string) {}
  run(f: string): Value {
    try { return this.scalar(this.ev(parse(f))); }
    catch (e) { if (e instanceof FormulaError) return e.message; throw e; }   // an error value is stored as text (#N/A etc.)
  }
  private ev(n: Node): EV {
    switch (n.k) {
      case 'lit': return n.v;
      case 'ref': return this.ref(n.v);
      case 'struct': return this.struct(n.v);
      case 'neg': return -num(this.scalar(this.ev(n.a)));
      case 'bin': {
        const x = this.scalar(this.ev(n.a)); const y = this.scalar(this.ev(n.b));
        switch (n.op) {
          case '+': return num(x) + num(y);
          case '-': return num(x) - num(y);
          case '*': return num(x) * num(y);
          case '/': { const d = num(y); if (d === 0) throw new FormulaError('#DIV/0!'); return num(x) / d; }
          case '&': return str(x) + str(y);
          default: return compare(n.op, x, y);
        }
      }
      case 'call': return this.call(n.name, n.args);
    }
  }
  scalar(v: EV): Value {
    if (isRange(v)) { if (v.r1 === v.r2 && v.c1 === v.c2) return this.wb.value(v.sheet, colName(v.c1) + v.r1); throw new FormulaError('#VALUE!'); }
    if (typeof v === 'string' && /^#(N\/A|DIV\/0!|VALUE!|REF!|NAME\?|NUM!|NULL!)$/.test(v)) throw new FormulaError(v);   // errors propagate
    return v;
  }
  private ref(s: string): EV {
    let sheet = this.sheet; let r = s;
    const bang = s.lastIndexOf('!');
    if (bang >= 0) { sheet = s.slice(0, bang).replace(/^'|'$/g, '').replace(/''/g, "'"); r = s.slice(bang + 1); }
    r = r.replace(/\$/g, '');
    if (r.includes(':')) { const [a, b] = r.split(':'); const p = split(a), q = split(b); return { sheet, c1: Math.min(p.col, q.col), r1: Math.min(p.row, q.row), c2: Math.max(p.col, q.col), r2: Math.max(p.row, q.row) }; }
    return { sheet, c1: split(r).col, r1: split(r).row, c2: split(r).col, r2: split(r).row };
  }
  private struct(s: string): EV {
    // table[col], table[[#This Row],[col]], table[[#Data],[col]]
    const m = /^([\w.]+)\[(.*)\]$/.exec(s)!;
    const tb = this.wb.tables.get(m[1].toLowerCase()); if (!tb) throw new Error(`No table ${m[1]}`);
    const [a, b] = tb.ref.split(':'); const p = split(a), q = split(b);
    const inner = m[2];
    const parts = inner.startsWith('[') ? [...inner.matchAll(/\[([^\]]*)\]/g)].map((x) => x[1]) : [inner];
    const colPart = parts.find((x) => !x.startsWith('#'));
    const thisRow = parts.some((x) => x.toLowerCase() === '#this row');
    const rowFrom = thisRow ? split(this.at).row : p.row + tb.header, rowTo = thisRow ? split(this.at).row : q.row - tb.totals;
    if (!colPart) return { sheet: tb.sheet, c1: p.col, r1: rowFrom, c2: q.col, r2: rowTo };
    const ci = tb.columns.findIndex((c) => c.toLowerCase() === colPart.replace(/'(.)/g, '$1').toLowerCase());
    if (ci < 0) throw new Error(`No column ${colPart} in ${tb.name}`);
    return { sheet: tb.sheet, c1: p.col + ci, r1: rowFrom, c2: p.col + ci, r2: rowTo };
  }
  // Rows below the last one holding anything are blank, so a range stops there.
  private values(r: Range): Value[] {
    const out: Value[] = [];
    const last = Math.min(r.r2, this.wb.lastRow(r.sheet));
    for (let row = r.r1; row <= last; row++) for (let c = r.c1; c <= r.c2; c++) out.push(this.wb.value(r.sheet, colName(c) + row));
    return out;
  }
  private call(name: string, args: Node[]): EV {
    const S = (i: number) => this.scalar(this.ev(args[i]));
    switch (name) {
      case 'SUM': {
        let s = 0;
        for (const a of args) {
          const v = this.ev(a);
          if (isRange(v)) for (const x of this.values(v)) { if (typeof x === 'string' && x.startsWith('#')) this.scalar(x); if (typeof x === 'number') s += x; }
          else s += num(this.scalar(v));
        }
        return s;
      }
      case 'SUMIF': {
        // SUMIF(range, criteria, [sum_range]): Excel takes the sum range from its top-left cell at the size of the range.
        const r = this.ev(args[0]); if (!isRange(r)) throw new Error('SUMIF needs a range');
        const want = S(1);
        let sr = r;
        if (args.length > 2) { const x = this.ev(args[2]); if (!isRange(x)) throw new Error('SUMIF needs a sum range'); sr = { sheet: x.sheet, c1: x.c1, r1: x.r1, c2: x.c1 + (r.c2 - r.c1), r2: x.r1 + (r.r2 - r.r1) }; }
        const test = criteria(want);
        const last = Math.min(r.r2, this.wb.lastRow(r.sheet));
        let s = 0;
        for (let row = r.r1; row <= last; row++) for (let c = r.c1; c <= r.c2; c++) {
          if (!test(this.wb.value(r.sheet, colName(c) + row))) continue;
          const v = this.wb.value(sr.sheet, colName(sr.c1 + (c - r.c1)) + (sr.r1 + (row - r.r1)));
          if (typeof v === 'number') s += v;
        }
        return s;
      }
      case 'IF': return truthy(S(0)) ? (args.length > 1 ? this.ev(args[1]) : true) : (args.length > 2 ? this.ev(args[2]) : false);
      case 'IFERROR': {
        try { const v = this.ev(args[0]); return isRange(v) ? this.scalar(v) : this.scalar(v); }
        catch (e) { if (e instanceof FormulaError) return this.ev(args[1]); throw e; }
      }
      case 'ISBLANK': { const v = this.ev(args[0]); const x = isRange(v) ? this.wb.value(v.sheet, colName(v.c1) + v.r1) : v; return x == null; }
      case 'OR': { for (let i = 0; i < args.length; i++) if (truthy(S(i))) return true; return false; }
      case 'AND': { for (let i = 0; i < args.length; i++) if (!truthy(S(i))) return false; return true; }
      case 'NOT': return !truthy(S(0));
      case 'TRIM': return str(S(0)).trim().replace(/ +/g, ' ');
      case 'UPPER': return str(S(0)).toUpperCase();
      case 'ROUND': { const p = 10 ** num(S(1)); const x = num(S(0)); return Math.sign(x) * Math.round(Math.abs(x) * p) / p; }
      case 'ABS': return Math.abs(num(S(0)));
      case 'MAX': case 'MIN': {
        const xs: number[] = [];
        for (const a of args) { const v = this.ev(a); if (isRange(v)) xs.push(...this.values(v).filter((x): x is number => typeof x === 'number')); else xs.push(num(this.scalar(v))); }
        return xs.length ? (name === 'MAX' ? Math.max(...xs) : Math.min(...xs)) : 0;
      }
      case 'TODAY': return serial(today());
      case 'INDEX': {
        const r = this.ev(args[0]); if (!isRange(r)) throw new Error('INDEX needs a range');
        const i = num(S(1)); const j = args.length > 2 ? num(S(2)) : 1;
        const rows = r.r2 - r.r1 + 1, cols = r.c2 - r.c1 + 1;
        const ri = rows === 1 && args.length === 2 ? 1 : i, cj = rows === 1 && args.length === 2 ? i : j;
        if (ri < 1 || ri > rows || cj < 1 || cj > cols) throw new FormulaError('#REF!');
        return this.wb.value(r.sheet, colName(r.c1 + cj - 1) + (r.r1 + ri - 1));
      }
      case 'MATCH': {
        const want = S(0); const r = this.ev(args[1]); if (!isRange(r)) throw new Error('MATCH needs a range');
        const type = args.length > 2 ? num(S(2)) : 1;
        if (type !== 0) throw new Error('Only exact MATCH (type 0) is supported');
        const k = this.values(r).findIndex((v) => typeof want === 'number' ? v === want : str(v).toLowerCase() === str(want).toLowerCase());
        if (k < 0) throw new FormulaError('#N/A');
        return k + 1;
      }
      default: throw new Error(`Function ${name} is not supported`);
    }
  }
}

let todayOverride: string | null = null;
export function setToday(day: string | null) { todayOverride = day; }
function today() { return todayOverride ?? new Date().toISOString().slice(0, 10); }

function isRange(v: EV): v is Range { return !!v && typeof v === 'object' && 'sheet' in v; }

// A SUMIF/COUNTIF criterion: a number or text to match, or a comparison such as ">0" or "<>x" (no wildcards).
function criteria(want: Value): (v: Value) => boolean {
  if (typeof want === 'number' || typeof want === 'boolean') return (v) => v != null && v !== '' && compare('=', typeof v === 'string' && v.trim() !== '' && Number.isFinite(Number(v)) ? Number(v) : v, want);
  const s = str(want);
  const m = /^(<=|>=|<>|=|<|>)(.*)$/.exec(s);
  const op = m ? m[1] : '='; const rhs = m ? m[2] : s;
  const n = Number(rhs);
  const target: Value = rhs.trim() !== '' && Number.isFinite(n) ? n : rhs;
  return (v) => {
    if (op === '=' && rhs === '') return v == null || v === '';
    if (v == null || v === '') return op === '<>' ? rhs !== '' : false;
    if (typeof target === 'number' && typeof v !== 'number') { const x = Number(v); if (!Number.isFinite(x)) return op === '<>'; return compare(op, x, target); }
    return compare(op, v, target);
  };
}
function num(v: Value): number {
  if (v == null || v === '') return 0;
  if (typeof v === 'boolean') return v ? 1 : 0;
  if (typeof v === 'number') return v;
  const n = Number(v.replace(/,/g, '')); if (!Number.isFinite(n) || v.trim() === '') throw new FormulaError('#VALUE!'); return n;
}
function str(v: Value): string { if (v == null) return ''; if (typeof v === 'boolean') return v ? 'TRUE' : 'FALSE'; if (typeof v === 'number') return String(+v.toPrecision(15)); return v; }
function truthy(v: Value) { if (typeof v === 'string') { if (v.toUpperCase() === 'TRUE') return true; if (v.toUpperCase() === 'FALSE' || v === '') return false; throw new FormulaError('#VALUE!'); } return !!num(v); }
function compare(op: string, x: Value, y: Value) {
  // Excel: blank compares as 0 against a number and as "" against text; text sorts after numbers.
  const xb = x == null ? (typeof y === 'string' ? '' : 0) : x; const yb = y == null ? (typeof x === 'string' ? '' : 0) : y;
  let cmp: number;
  if (typeof xb === 'string' && typeof yb === 'string') cmp = xb.toLowerCase() < yb.toLowerCase() ? -1 : xb.toLowerCase() > yb.toLowerCase() ? 1 : 0;
  else if (typeof xb === 'string') cmp = 1; else if (typeof yb === 'string') cmp = -1;
  else cmp = num(xb) - num(yb);
  return op === '=' ? cmp === 0 : op === '<>' ? cmp !== 0 : op === '<' ? cmp < 0 : op === '>' ? cmp > 0 : op === '<=' ? cmp <= 0 : cmp >= 0;
}
