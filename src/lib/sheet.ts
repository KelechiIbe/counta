// Reading whatever spreadsheet a business already keeps: find the sheet and header row, match columns
// to Counta's fields (by name, then by Martina when the names are unclear), and turn each row into an
// item with its opening stock.
import { ALL_FIELDS, ITEM_TYPES, fieldsFor, type ItemType } from './industries';
import type { Location } from './types';

export type Cell = string | number | boolean | Date | null;
// rowNo[i] is the spreadsheet row number (1-based) of rows[i], since blank rows are dropped when reading.
export interface SheetData { name: string; rows: Cell[][]; rowNo?: number[] }

// Core fields. Keys ending in _pu are per purchase unit (carton, bag...) and get converted.
export interface CoreField { key: string; label: string; group: 'Item' | 'Stock & units' | 'Pricing'; syn: string[]; template?: string }
export const CORE_FIELDS: CoreField[] = [
  { key: 'name', label: 'Product name', group: 'Item', template: 'Product name*', syn: ['product name', 'product', 'item name', 'item', 'description of goods', 'product description', 'name', 'goods', 'particulars', 'stock name', 'item description', 'material', 'material description', 'article'] },
  { key: 'sku', label: 'Catalogue ID / SKU', group: 'Item', template: 'Catalogue ID / SKU', syn: ['sku', 'item code', 'code', 'product code', 'product id', 'item id', 'catalogue id', 'catalog id', 'item no', 'item number', 'stock code', 'material code', 'ref', 'reference'] },
  { key: 'barcode', label: 'Barcode', group: 'Item', template: 'Barcode', syn: ['barcode', 'bar code', 'ean', 'upc', 'gtin', 'ean13', 'ean code'] },
  { key: 'category', label: 'Category', group: 'Item', template: 'Category', syn: ['category', 'group', 'department', 'class', 'product group', 'product category', 'section', 'family'] },
  { key: 'brand', label: 'Brand', group: 'Item', template: 'Brand', syn: ['brand', 'brand name', 'make', 'label'] },
  { key: 'item_type', label: 'Kind of item', group: 'Item', template: 'Kind of item', syn: ['item type', 'type of item', 'kind of item', 'kind', 'stock type', 'material type', 'inventory type'] },
  { key: 'description', label: 'Description', group: 'Item', template: 'Description', syn: ['long description', 'details', 'remarks', 'comment', 'comments', 'notes'] },
  { key: 'vat_treatment', label: 'VAT', group: 'Item', template: 'VAT (standard / zero / exempt)', syn: ['vat', 'tax', 'vat treatment', 'vat status', 'vatable', 'tax code', 'vat applicable'] },
  { key: 'nafdac_no', label: 'NAFDAC number', group: 'Item', template: 'NAFDAC no.', syn: ['nafdac', 'nafdac no', 'nafdac number', 'nafdac reg no', 'reg no', 'registration number'] },
  { key: 'vendor', label: 'Preferred vendor', group: 'Item', template: 'Preferred vendor', syn: ['vendor', 'supplier', 'preferred vendor', 'preferred supplier', 'distributor', 'source'] },
  { key: 'track_batches', label: 'Track batches (Yes/No)', group: 'Stock & units', template: 'Track batches (Yes/No)', syn: ['track batches', 'batch tracked', 'track expiry', 'batch tracking'] },
  { key: 'purchase_unit', label: 'Buy by the (purchase unit)', group: 'Stock & units', template: 'Buy by the', syn: ['purchase unit', 'buy unit', 'buying unit', 'pack type', 'case type', 'carton type', 'outer'] },
  { key: 'pack_size', label: 'Units per purchase unit', group: 'Stock & units', template: 'Units per purchase unit', syn: ['pack size', 'units per carton', 'carton size', 'ctn size', 'case size', 'qty per carton', 'pcs per ctn', 'per carton', 'pack qty', 'units per pack', 'conversion', 'pieces per carton', 'packing', 'pack'] },
  { key: 'selling_unit', label: 'Sell by the (selling unit)', group: 'Stock & units', template: 'Sell by the', syn: ['unit', 'uom', 'selling unit', 'sell unit', 'unit of measure', 'base unit', 'units'] },
  { key: 'qty', label: 'Quantity on hand (selling units)', group: 'Stock & units', template: 'Opening qty', syn: ['qty', 'quantity', 'on hand', 'stock', 'balance', 'closing stock', 'stock level', 'qty on hand', 'stock on hand', 'soh', 'available', 'current stock', 'opening stock', 'opening qty', 'qty in pcs', 'pieces', 'loose'] },
  { key: 'qty_pu', label: 'Quantity on hand (purchase units)', group: 'Stock & units', syn: ['qty in ctn', 'qty ctn', 'cartons', 'ctns', 'no of cartons', 'cases', 'bags', 'qty in cartons', 'carton qty', 'qty (ctn)'] },
  { key: 'reorder_floor', label: 'Reorder floor (selling units)', group: 'Stock & units', template: 'Reorder floor', syn: ['reorder level', 'reorder', 'reorder point', 'min', 'minimum', 'min stock', 'minimum stock', 'safety stock', 'rol', 'floor'] },
  { key: 'batch_no', label: 'Batch / lot number', group: 'Stock & units', template: 'Batch no.', syn: ['batch', 'batch no', 'batch number', 'lot', 'lot no', 'lot number'] },
  { key: 'expiry_date', label: 'Expiry date', group: 'Stock & units', template: 'Expiry date (DD/MM/YYYY)', syn: ['expiry', 'expiry date', 'exp', 'exp date', 'expiration', 'expires', 'best before', 'bbd', 'use by'] },
  { key: 'price', label: 'Selling price (per selling unit)', group: 'Pricing', template: 'Selling price (₦ per selling unit)', syn: ['price', 'selling price', 'sell price', 'retail price', 'unit price', 'sp', 'sales price', 'rrp', 'price per unit', 'retail'] },
  { key: 'price_pu', label: 'Selling price (per purchase unit)', group: 'Pricing', syn: ['price per carton', 'carton price', 'ctn price', 'price/ctn', 'case price', 'bag price', 'price per bag'] },
  { key: 'cost', label: 'Cost (per selling unit)', group: 'Pricing', template: 'Cost (₦ per selling unit)', syn: ['cost', 'cost price', 'unit cost', 'buy price', 'buying price', 'purchase price', 'cp', 'landing cost', 'avg cost', 'average cost'] },
  { key: 'cost_pu', label: 'Cost (per purchase unit)', group: 'Pricing', syn: ['cost per carton', 'carton cost', 'ctn cost', 'cost/ctn', 'case cost', 'cost per bag', 'bag cost'] },
  { key: 'import_priced', label: 'Import-priced (Yes/No)', group: 'Pricing', template: 'Import-priced (Yes/No)', syn: ['imported', 'import priced', 'import'] },
];

export interface ColMap { field: string; location?: string | null }   // field: core key, 'attr:<key>', 'note' or 'ignore'

const norm = (h: string) => String(h ?? '').toLowerCase().replace(/[*_\-.:#()/\\₦]/g, ' ').replace(/\s+/g, ' ').trim();

export function cellText(c: Cell): string {
  if (c == null) return '';
  if (c instanceof Date) return parseDate(c) || '';
  if (typeof c === 'number') return Number.isInteger(c) ? String(c) : String(Math.round(c * 10000) / 10000);
  return String(c).trim();
}

export async function readWorkbook(file: File): Promise<SheetData[]> {
  const XLSX = await import('xlsx');
  const wb = XLSX.read(await file.arrayBuffer(), { type: 'array', cellDates: true });
  return wb.SheetNames.map((name) => {
    const ws = wb.Sheets[name];
    if (!ws?.['!ref']) return { name, rows: [], rowNo: [] };
    // Read from A1 with blank rows kept so each row knows its spreadsheet row number, then drop the blanks.
    // The range is capped because some files claim a million formatted rows.
    const r = XLSX.utils.decode_range(ws['!ref']);
    const range = { s: { r: 0, c: 0 }, e: { r: Math.min(r.e.r, 20000), c: Math.min(r.e.c, 150) } };
    const all = XLSX.utils.sheet_to_json<Cell[]>(ws, { header: 1, raw: true, defval: null, blankrows: true, range }) as Cell[][];
    const rows: Cell[][] = []; const rowNo: number[] = [];
    all.forEach((row, i) => {
      const clean = row.map((c) => (typeof c === 'string' ? c.trim() || null : c));
      if (clean.some((c) => c != null && c !== '')) { rows.push(clean); rowNo.push(i + 1); }
    });
    return { name, rows, rowNo };
  }).filter((s) => s.rows.some((r) => r.some((c) => c != null && c !== '')));
}

// The sheet most likely to hold the item list: "Items" from our template, otherwise the one with the most data rows.
export function pickSheet(sheets: SheetData[]): number {
  const named = sheets.findIndex((s) => /^(items?|products?|inventory|stock)( list)?$/i.test(s.name.trim()));
  if (named >= 0) return named;
  let best = 0, score = -1;
  sheets.forEach((s, i) => {
    if (/guide|instruction|read ?me|lists?$|example/i.test(s.name)) return;
    const n = s.rows.filter((r) => r.filter((c) => c != null && c !== '').length >= 2).length;
    if (n > score) { score = n; best = i; }
  });
  return best;
}

const KNOWN = new Set<string>([
  ...CORE_FIELDS.flatMap((f) => [...f.syn, norm(f.label), norm(f.template || '')]),
  ...ALL_FIELDS.flatMap((f) => [...(f.syn || []), norm(f.label)]),
].map(norm).filter(Boolean));

// Header row: the row in the first 25 with the most text cells that look like column names.
export function detectHeader(rows: Cell[][]): number {
  let best = 0, bestScore = -1;
  for (let i = 0; i < Math.min(rows.length, 25); i++) {
    const cells = rows[i].map(cellText);
    const texts = cells.filter((c) => c && isNaN(Number(c.replace(/,/g, ''))));
    if (texts.length < 2) continue;
    const known = cells.filter((c) => c && (KNOWN.has(norm(c)) || [...KNOWN].some((k) => k.length > 3 && norm(c).includes(k)))).length;
    const below = rows.slice(i + 1, i + 6).filter((r) => r.filter((c) => c != null && c !== '').length >= 2).length;
    const score = known * 3 + texts.length + below;
    if (score > bestScore) { bestScore = score; best = i; }
  }
  return best;
}

export interface Matched { maps: ColMap[]; how: ('exact' | 'close' | 'none')[] }

// Name-based matching: exact names and synonyms first, then the longest synonym found inside the header.
// When no column is called a product name, a "Description" column (or the wordiest text column) is used.
export function autoMatch(headers: string[], industry: string | undefined, locations: Location[], samples: Cell[][] = []): Matched {
  const fields = fieldsFor(industry);
  const cands: { field: string; syn: string; core: boolean }[] = [
    ...CORE_FIELDS.flatMap((f) => [norm(f.label), norm(f.template || ''), ...f.syn.map(norm)].filter(Boolean).map((syn) => ({ field: f.key, syn, core: true }))),
    ...fields.flatMap((f) => [norm(f.label), ...(f.syn || []).map(norm)].map((syn) => ({ field: 'attr:' + f.key, syn, core: false }))),
  ];
  const used = new Set<string>();
  const maps: ColMap[] = []; const how: Matched['how'] = [];
  const locFor = (h: string) => locations.find((l) => h.includes(norm(l.name)) || (l.code && new RegExp(`\\b${norm(l.code)}\\b`).test(h)));
  const numeric = (i: number) => {
    const vals = samples.map((r) => r[i]).filter((v) => v != null && v !== '');
    return vals.length > 0 && vals.filter((v) => parseNum(v) != null && !(v instanceof Date)).length / vals.length >= 0.7;
  };
  const PER = /\b(ctn|ctns|carton|cartons|case|cases|bag|bags|bale|bales|crate|crates|drum|drums|roll|rolls)\b/;
  headers.forEach((raw, idx) => {
    const h = norm(raw);
    let m: ColMap | null = null; let kind: 'exact' | 'close' | 'none' = 'none';
    if (/^(s ?n|s no|sno|no|sl no|serial|#|s ?no)$/.test(h)) { maps.push({ field: 'ignore' }); how.push('exact'); return; }
    const loc = h ? locFor(h) : undefined;
    // A branch column: "Yaba qty", "Stock - Ikeja", or just "Ikeja" over a column of numbers.
    if (loc && (/(qty|quantity|stock|on hand|balance|soh|opening|count|units|pcs|ctn|carton)/.test(h) || ((h === norm(loc.name) || (!!loc.code && h === norm(loc.code))) && numeric(idx)))) {
      m = { field: /(ctn|carton|case|bag|purchase unit)/.test(h) && !/selling unit/.test(h) ? 'qty_pu' : 'qty', location: loc.id }; kind = 'exact';
    }
    if (!m && h) {
      const ex = cands.find((c) => !used.has(c.field) && c.syn === h);
      if (ex) { m = { field: ex.field }; kind = 'exact'; }
    }
    // Shorthand with a carton word in it: "CP/Ctn", "SP per bag", "Ctn Qty".
    if (!m && h && PER.test(h) && !/\b(size|per ctn qty|units per|pcs per|qty per)\b/.test(h)) {
      const w = new Set(h.split(' '));
      const any = (...xs: string[]) => xs.some((x) => w.has(x));
      const pick = any('cp', 'cost', 'bp', 'buying', 'landed') ? 'cost_pu' : any('sp', 'price', 'selling', 'rrp') ? 'price_pu'
        : any('qty', 'quantity', 'stock', 'soh', 'balance', 'count', 'no', 'number') ? 'qty_pu' : null;
      if (pick && !used.has(pick)) { m = { field: pick }; kind = 'exact'; }
    }
    if (!m && h) {
      const close = cands.filter((c) => !used.has(c.field) && c.syn.length > 3 && h.includes(c.syn))
        .sort((a, b) => b.syn.length - a.syn.length || Number(b.core) - Number(a.core))[0];
      if (close) { m = { field: close.field }; kind = 'close'; }
    }
    if (m && m.field !== 'qty' && m.field !== 'qty_pu') used.add(m.field);
    maps.push(m || { field: raw ? 'note' : 'ignore' }); how.push(kind);
  });
  if (!maps.some((m) => m.field === 'name')) {
    let idx = maps.findIndex((m) => m.field === 'description');
    if (idx < 0 && samples.length) {
      let best = -1; let bestLen = 0;
      maps.forEach((m, i) => {
        if (m.field !== 'note' && m.field !== 'ignore' && m.field !== 'description') return;
        const vals = samples.map((r) => cellText(r[i])).filter(Boolean);
        const texty = vals.filter((v) => isNaN(Number(v.replace(/[,₦]/g, '')))).length;
        const avg = vals.reduce((a, v) => a + v.length, 0) / Math.max(1, vals.length);
        if (vals.length && texty / vals.length > 0.7 && avg > bestLen) { best = i; bestLen = avg; }
      });
      idx = best;
    }
    if (idx >= 0) { maps[idx] = { field: 'name' }; how[idx] = 'close'; }
  }
  return { maps, how };
}

// ---------- value parsing ----------
export function parseNum(v: Cell): number | null {
  if (v == null || v === '') return null;
  if (typeof v === 'number') return isFinite(v) ? v : null;
  if (typeof v === 'boolean' || v instanceof Date) return null;
  let s = String(v).trim().toLowerCase();
  if (!s || s === '-' || s === '—' || s === 'n/a' || s === 'nil') return null;
  const neg = /^\(.*\)$/.test(s) || /^-/.test(s);
  s = s.replace(/^\(|\)$/g, '').replace(/ngn|naira|₦|n(?=\s*\d)/g, '').replace(/[,\s]/g, '');
  const m = s.match(/(\d+(?:\.\d+)?)(k|m)?/);
  if (!m) return null;
  let n = parseFloat(m[1]);
  if (m[2] === 'k') n *= 1000; else if (m[2] === 'm') n *= 1_000_000;
  return neg ? -n : n;
}

// "24", "24pcs", "24 x 50cl", "ctn of 12", "12/ctn", "12 per carton", "1x24"
export function parsePack(v: Cell): number | null {
  if (v == null || v === '') return null;
  if (typeof v === 'number') return v >= 1 ? Math.floor(v) : null;
  const s = String(v).toLowerCase();
  let m = s.match(/(\d+)\s*(?:pcs|pc|pieces|units|pks|packs|tins|btls|bottles|sachets|tabs|tablets|bags|rolls|pairs|sets)?\s*(?:\/|per|in a|in one)\s*(?:ctn|carton|case|pack|box|bag|bale|crate|dozen|outer)/);
  if (m) return parseInt(m[1]);
  m = s.match(/(?:ctn|carton|case|box|bag|bale|crate|pack|outer)\s*(?:of|x|:)?\s*(\d+)/);
  if (m) return parseInt(m[1]);
  m = s.match(/^\s*1\s*[x×*]\s*(\d+)/);
  if (m) return parseInt(m[1]);
  m = s.match(/^\s*(\d+)\s*[x×*]\s*\d/);
  if (m) return parseInt(m[1]);
  if (/dozen|doz/.test(s) && !/\d/.test(s)) return 12;
  const n = parseNum(v);
  return n != null && n >= 1 ? Math.floor(n) : null;
}

export function parseBool(v: Cell): boolean | null {
  if (v == null || v === '') return null;
  if (typeof v === 'boolean') return v;
  const s = String(v).trim().toLowerCase();
  if (/^(y|yes|true|1|✓|✔|x|on|tracked)$/.test(s)) return true;
  if (/^(n|no|false|0|off|-)$/.test(s)) return false;
  return null;
}

const MONTHS: Record<string, number> = { jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, jul: 7, aug: 8, sep: 9, sept: 9, oct: 10, nov: 11, dec: 12 };
const iso = (y: number, m: number, d: number) => {
  if (y < 100) y += 2000;
  if (m < 1 || m > 12 || d < 1 || d > 31) return null;
  const dt = new Date(Date.UTC(y, m - 1, d));
  return dt.getUTCMonth() === m - 1 ? dt.toISOString().slice(0, 10) : null;
};
const lastDay = (y: number, m: number) => { if (y < 100) y += 2000; return new Date(Date.UTC(y, m, 0)).toISOString().slice(0, 10); };

// Nigerian sheets write day first. "06/2027" or "Jun 2027" means the end of that month.
export function parseDate(v: Cell): string | null {
  if (v == null || v === '') return null;
  if (v instanceof Date) {
    if (isNaN(v.getTime())) return null;
    const d = new Date(v.getTime() + 12 * 3600_000);
    return d.toISOString().slice(0, 10);
  }
  if (typeof v === 'number') {
    if (v > 20000 && v < 80000) return new Date(Math.round((v - 25569) * 86400_000)).toISOString().slice(0, 10);
    return null;
  }
  const s = String(v).trim().toLowerCase();
  let m = s.match(/^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})/);
  if (m) return iso(+m[1], +m[2], +m[3]);
  m = s.match(/^(\d{1,2})[-/.](\d{1,2})[-/.](\d{2,4})$/);
  if (m) return iso(+m[3], +m[2], +m[1]);
  m = s.match(/^(\d{1,2})[-/.](\d{4}|\d{2})$/);
  if (m) return lastDay(+m[2], +m[1]);
  m = s.match(/^(?:(\d{1,2})(?:st|nd|rd|th)?[\s\-/.]*)?([a-z]{3,9})[\s,\-/.]*(\d{2,4})$/);
  if (m) {
    const mon = MONTHS[m[2].slice(0, 3)];
    if (mon) return m[1] ? iso(+m[3], mon, +m[1]) : lastDay(+m[3], mon);
  }
  return null;
}

export function parseVat(v: Cell): 'standard' | 'zero' | 'exempt' | null {
  if (v == null || v === '') return null;
  const s = String(v).trim().toLowerCase();
  if (/exempt|^ex$|^e$|^no$|^n$|none|non.?vat|not vatable|^false$/.test(s)) return 'exempt';
  if (/zero|^0(\.0+)?%?$|^z$/.test(s)) return 'zero';
  if (/standard|^yes$|^y$|7\.?5|vatable|^s$|^true$|^v$/.test(s)) return 'standard';
  return null;
}

export function parseType(v: Cell): ItemType | null {
  if (v == null || v === '') return null;
  const s = String(v).trim().toLowerCase();
  const exact = ITEM_TYPES.find((t) => t.id === s.replace(/\s+/g, '_') || t.label.toLowerCase() === s);
  if (exact) return exact.id;
  if (/raw|^rm$|input|ingredient/.test(s)) return 'raw_material';
  if (/packag|packing|label/.test(s)) return 'packaging';
  if (/wip|work.?in.?progress|semi/.test(s)) return 'work_in_progress';
  if (/finished|^fg$|product(ion)?$/.test(s)) return 'finished_good';
  if (/spare|part|tool/.test(s)) return 'spare_part';
  if (/chemical|reagent|gas/.test(s)) return 'chemical';
  if (/consum|suppl|stationer|cleaning/.test(s)) return 'consumable';
  if (/resale|merch|goods|trading|stock/.test(s)) return 'merchandise';
  return null;
}

export function parseSelect(v: Cell, options: string[] = []): string | null {
  const s = cellText(v);
  if (!s) return null;
  const l = s.toLowerCase();
  return options.find((o) => o.toLowerCase() === l) || options.find((o) => o.toLowerCase().startsWith(l) || l.startsWith(o.toLowerCase().split(' (')[0]))
    || options.find((o) => o.toLowerCase().includes(`(${l})`)) || s;
}

// ---------- rows ----------
export interface BuildSettings { defaultLocation: string; qtyIn: 'selling' | 'purchase'; costIn: 'selling' | 'purchase'; priceIn: 'selling' | 'purchase'; rowNo?: number[] }
export interface BuiltRow { row: number; data: any; issues: string[]; warnings: string[] }

// "BEVERAGES:" → "Beverages". Headings typed in capitals read better as categories in title case.
const heading = (t: string) => { const x = t.replace(/[:\-–]+$/, '').trim(); return /[a-z]/.test(x) ? x : x.toLowerCase().replace(/(^|[\s/&(-])([a-z])/g, (_, a, b) => a + b.toUpperCase()); };
const isTotalRow = (cells: string[]) => /^(grand\s+)?(sub\s*)?totals?\b|^total value|^summary/i.test(cells.find((c) => c) || '');

export function buildRows(rows: Cell[][], headerIdx: number, maps: ColMap[], industry: string | undefined, s: BuildSettings): BuiltRow[] {
  const fields = fieldsFor(industry);
  const byKey = new Map(ALL_FIELDS.map((f) => [f.key, f]));
  const has = (k: string) => maps.some((m) => m.field === k);
  const out: BuiltRow[] = [];
  const headers = rows[headerIdx].map(cellText);
  let section: string | null = null;
  for (let i = headerIdx + 1; i < rows.length; i++) {
    const r = rows[i] || [];
    const texts = r.map(cellText);
    const filled = texts.filter((t) => t !== '');
    if (!filled.length) continue;
    if (isTotalRow(texts)) continue;
    // A row with one text cell and nothing else is a section heading ("BEVERAGES"); it becomes the category.
    if (filled.length === 1 && isNaN(Number(filled[0].replace(/,/g, ''))) && !has('category')) { section = heading(filled[0]); continue; }
    const d: any = { row: s.rowNo?.[i] ?? i + 1, attributes: {}, notes: {}, stock: [] };
    const issues: string[] = []; const warnings: string[] = [];
    let pack: number | null = null; let qtyByLoc: Record<string, { su: number; pu: number }> = {};
    const stockAt = (loc: string) => (qtyByLoc[loc] ||= { su: 0, pu: 0 });
    maps.forEach((m, c) => {
      const v = r[c]; const t = texts[c];
      if (m.field === 'ignore' || t === '') return;
      if (m.field === 'note') { if (headers[c]) d.notes[headers[c]] = t.slice(0, 300); return; }
      if (m.field.startsWith('attr:')) {
        const key = m.field.slice(5); const f = byKey.get(key) || fields.find((x) => x.key === key);
        if (f?.type === 'number') { const n = parseNum(v); if (n != null) d.attributes[key] = n; else d.attributes[key] = t; }
        else if (f?.type === 'bool') { const b = parseBool(v); if (b != null) d.attributes[key] = b; }
        else if (f?.type === 'select') d.attributes[key] = parseSelect(v, f.options);
        else if (f?.type === 'date') d.attributes[key] = parseDate(v) || t;
        else d.attributes[key] = t.slice(0, 500);
        return;
      }
      switch (m.field) {
        case 'name': case 'sku': case 'category': case 'brand': case 'description': case 'nafdac_no': case 'vendor':
        case 'purchase_unit': case 'selling_unit': case 'batch_no':
          d[m.field] = t; break;
        case 'barcode': d.barcode = typeof v === 'number' ? v.toFixed(0) : t.replace(/\s/g, ''); break;
        case 'item_type': { const ty = parseType(v); if (ty) d.item_type = ty; else warnings.push(`Kind "${t}" not recognised`); break; }
        case 'vat_treatment': { const vt = parseVat(v); if (vt) d.vat_treatment = vt; break; }
        case 'track_batches': case 'import_priced': { const b = parseBool(v); if (b != null) d[m.field] = b; break; }
        case 'pack_size': pack = parsePack(v); if (pack == null) warnings.push(`Pack size "${t}" not read`); break;
        case 'expiry_date': { const dt = parseDate(v); if (dt) d.expiry_date = dt; else warnings.push(`Expiry "${t}" not read`); break; }
        case 'reorder_floor': { const n = parseNum(v); if (n != null) d.reorder_floor = n; break; }
        case 'price': case 'price_pu': case 'cost': case 'cost_pu': {
          const n = parseNum(v); if (n == null) { warnings.push(`${m.field.startsWith('price') ? 'Price' : 'Cost'} "${t}" not read`); break; }
          d['_' + m.field] = n; break;
        }
        case 'qty': case 'qty_pu': {
          const n = parseNum(v); if (n == null) { warnings.push(`Quantity "${t}" not read`); break; }
          const loc = m.location || s.defaultLocation;
          const isPu = m.field === 'qty_pu' || (!m.location && s.qtyIn === 'purchase');
          if (isPu) stockAt(loc).pu += n; else stockAt(loc).su += n;
          break;
        }
      }
    });
    if (!d.category && section) d.category = section;
    // Pack size hidden in the name: "Indomie Chicken 70g x40", "(Ctn of 24)".
    if (pack == null && d.name) { const p = parsePack(d.name.match(/(?:x\s*\d+|ctn\s*of\s*\d+|\d+\s*(?:pcs|pc)?\s*\/\s*ctn)/i)?.[0] || ''); if (p && p > 1) pack = p; }
    const pk = pack && pack >= 1 ? pack : 1;
    d.pack_size = pk;
    const per = (n: number | undefined, basis: 'selling' | 'purchase', isPuField: boolean) => n == null ? undefined : (isPuField || basis === 'purchase' ? n / pk : n);
    d.price = d._price_pu != null ? d._price_pu / pk : per(d._price, s.priceIn, false);
    d.cost = d._cost_pu != null ? d._cost_pu / pk : per(d._cost, s.costIn, false);
    for (const k of ['_price', '_price_pu', '_cost', '_cost_pu']) delete d[k];
    if (d.price != null) d.price = Math.round(d.price * 100) / 100;
    if (d.cost != null) d.cost = Math.round(d.cost * 10000) / 10000;
    for (const [loc, q] of Object.entries(qtyByLoc)) {
      const total = q.su + q.pu * pk;
      if (total < 0) { warnings.push('Negative quantity left out'); continue; }
      if (total > 0) d.stock.push({ location_id: loc, qty: Math.round(total * 1000) / 1000, batch_no: d.batch_no || null, expiry_date: d.expiry_date || null });
    }
    if (!d.stock.length && (d.batch_no || d.expiry_date)) d.track_batches = true;
    delete d.batch_no; delete d.expiry_date;
    if (!d.name) issues.push('No product name');
    const sells = !d.item_type || d.item_type === 'merchandise' || d.item_type === 'finished_good';
    if (sells && !(d.price > 0)) issues.push('No selling price');
    if (d.stock.length && !(d.cost > 0)) warnings.push('No cost, so opening stock posts at ₦0');
    if (!Object.keys(d.attributes).length) delete d.attributes;
    if (!Object.keys(d.notes).length) delete d.notes;
    out.push({ row: d.row, data: d, issues, warnings });
  }
  return out;
}

// Field choices for the column matcher, grouped for a <select>.
export function fieldChoices(industry: string | undefined): { group: string; options: { value: string; label: string }[] }[] {
  const ind = fieldsFor(industry);
  const groups = ['Item', 'Stock & units', 'Pricing'] as const;
  return [
    ...groups.map((g) => ({ group: g, options: CORE_FIELDS.filter((f) => f.group === g).map((f) => ({ value: f.key, label: f.label })) })),
    { group: 'Details', options: ind.map((f) => ({ value: 'attr:' + f.key, label: f.label })) },
  ];
}
export const choiceLabel = (field: string) =>
  field === 'note' ? 'Keep as a note' : field === 'ignore' ? 'Leave out'
    : field.startsWith('attr:') ? ALL_FIELDS.find((f) => f.key === field.slice(5))?.label || field.slice(5)
    : CORE_FIELDS.find((f) => f.key === field)?.label || field;
