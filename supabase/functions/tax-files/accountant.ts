// Returns and statements an accountant changed and uploaded again. Counta reads the figures that matter from the upload
// (the same cells it fills when it makes the file), puts them beside its own, and the database works out what changed and
// the journal that books it. Nothing in the upload is trusted beyond its figures: it is stored as it came, and the figures
// are numbers read from known cells.
import { FORM_LINES, type VatSchedule } from './vat.ts';
import type { WhtSchedule } from './wht.ts';
import { type Value, Workbook } from './xlsx.ts';

export class FileProblem extends Error {}

export type Row = { key: string; label: string; counta: number | null; uploaded: number | null; bookable?: boolean };
export type Figures = { rows: { key: string; label: string; value: number | null; bookable?: boolean }[]; checks: string[] };

const r2 = (n: number) => Math.round(n * 100) / 100;

// A number as an accountant may leave it in a cell: a number, or text such as "12,500.00", "(3,000)" or "-".
export function numOf(v: Value): number | null {
  if (typeof v === 'number') return Number.isFinite(v) ? r2(v) : null;
  if (typeof v === 'boolean' || v == null) return null;
  const s = String(v).trim().replace(/[₦,\s]/g, '').replace(/^NGN/i, '');
  if (s === '' || s === '-' || s === '–') return s === '' ? null : 0;
  const neg = /^\(.*\)$/.test(s);
  const n = Number(neg ? s.slice(1, -1) : s);
  return Number.isFinite(n) ? r2(neg ? -n : n) : null;
}

// Reads stored values (what Excel saved) and works a formula out only when the file holds no value for it.
export function reader(bytes: Uint8Array) {
  let lazy: Workbook;
  try { lazy = new Workbook(bytes, { lazy: true }); } catch { throw new FileProblem('Counta could not open that file as an Excel workbook (.xlsx). Save it as .xlsx and upload it again.'); }
  let full: Workbook | null = null;
  const has = (sheet: string) => lazy.sheets.has(sheet);
  const value = (sheet: string, addr: string): Value => {
    if (!has(sheet)) throw new FileProblem(`The file has no sheet named "${sheet}". Upload the file Counta gave you, with your changes in it.`);
    // A formula the file holds no result for (some tools save formulas without their results) is worked out here.
    const cell = lazy.sheet(sheet).cells.get(addr);
    const noResult = !!cell && !!(cell.f || cell.fShared) && (cell.v == null || cell.v === '');
    if (!noResult) { try { return lazy.value(sheet, addr); } catch { return null; } }
    try { full ||= new Workbook(bytes); return full.value(sheet, addr); } catch { return null; }
  };
  return { wb: lazy, has, value };
}

// ------------------------------------------------------------------ VAT: the form's sixteen lines
export function vatFigures(bytes: Uint8Array): Figures {
  const r = reader(bytes);
  const rows = FORM_LINES.map(([line, cell, label]) => ({ key: `line_${line}`, label: `Line ${line}: ${label}`, value: numOf(r.value('VAT RETURNS FORM', cell)) }));
  const checks: string[] = [];
  if (rows.every((x) => x.value == null)) throw new FileProblem('The VAT form in the file is empty. Upload the return Counta gave you, with your changes in it.');
  return { rows, checks };
}
export function vatCounta(s: VatSchedule): Figures {
  return { rows: FORM_LINES.map(([line, , label]) => ({ key: `line_${line}`, label: `Line ${line}: ${label}`, value: r2(Number(s.lines?.[line] ?? 0)) })), checks: [] };
}

// ------------------------------------------------------------------ WHT: the schedule's rows and totals
const NRS_FIRST = 6, NRS_LAST = 135;
export function whtFigures(bytes: Uint8Array, authority: string): Figures {
  const r = reader(bytes);
  let n = 0, amount = 0, wht = 0;
  const checks: string[] = [];
  if (authority === 'NRS') {
    for (let row = NRS_FIRST; row <= NRS_LAST; row++) {
      const name = r.value('WHT', `B${row}`), g = numOf(r.value('WHT', `G${row}`)), k = numOf(r.value('WHT', `K${row}`));
      if ((name == null || String(name).trim() === '') && !g) continue;
      n++; amount += g || 0; wht += k || 0;
    }
  } else {
    for (let row = 3; row < 3 + 5000; row++) {
      const name = r.value('WHT', `A${row}`), e = numOf(r.value('WHT', `E${row}`)), g = numOf(r.value('WHT', `G${row}`));
      if ((name == null || String(name).trim() === '') && !e) { if (row > 3 + n + 50) break; continue; }
      n++; amount += e || 0; wht += g || 0;
    }
  }
  if (!n) throw new FileProblem('The schedule in the file has no rows. Upload the schedule Counta gave you, with your changes in it.');
  return { rows: whtRows(n, amount, wht), checks };
}
function whtRows(n: number, amount: number, wht: number) {
  return [{ key: 'rows', label: 'Deductions listed', value: n }, { key: 'amount_total', label: 'Total of the payments', value: r2(amount) },
    { key: 'wht_total', label: 'Total WHT deducted', value: r2(wht) }];
}
export function whtCounta(s: WhtSchedule): Figures {
  return { rows: whtRows(s.rows.length, s.rows.reduce((a, x) => a + Number(x.amount || 0), 0), s.rows.reduce((a, x) => a + Number(x.wht || 0), 0)), checks: [] };
}

// ------------------------------------------------------------------ CIT: the Rev360 template's summary cells
export const CIT_CELLS: [string, string, string, string][] = [
  ['revenue', 'Revenue', 'INCOME_STATEMENT', 'E107'], ['cost_of_sales', 'Cost of sales', 'INCOME_STATEMENT', 'E108'],
  ['gross_profit', 'Gross profit', 'INCOME_STATEMENT', 'E109'], ['other_income', 'Other income', 'INCOME_STATEMENT', 'E110'],
  ['admin_expenses', 'Administrative expenses', 'INCOME_STATEMENT', 'E112'], ['finance_cost', 'Finance cost', 'INCOME_STATEMENT', 'E114'],
  ['pbt', 'Profit before tax', 'INCOME_STATEMENT', 'E115'], ['taxation', 'Taxation', 'INCOME_STATEMENT', 'E116'], ['pat', 'Profit after tax', 'INCOME_STATEMENT', 'E117'],
  ['addbacks', 'Total added back', 'PROFIT_ADJUSTMENT', 'E33'], ['deductions', 'Total deductions', 'PROFIT_ADJUSTMENT', 'E41'],
  ['total_assets', 'Total assets', 'STATEMENT_OF_FINANCIAL_POSITION', 'E69'], ['current_tax', 'Current tax liabilities', 'STATEMENT_OF_FINANCIAL_POSITION', 'E74'],
  ['equity_liabilities', 'Total equity and liabilities', 'STATEMENT_OF_FINANCIAL_POSITION', 'E127'],
];
export function citFigures(bytes: Uint8Array): Figures {
  const r = reader(bytes);
  const rows: Figures['rows'] = CIT_CELLS.map(([key, label, sheet, addr]) => ({ key, label, value: numOf(r.value(sheet, addr)) }));
  const v = (k: string) => rows.find((x) => x.key === k)?.value ?? 0;
  rows.splice(11, 0, { key: 'adjusted_profit', label: 'Adjusted profit (profit before tax, add-backs, deductions)', value: r2(v('pbt') + v('addbacks') - v('deductions')) });
  const checks: string[] = [];
  if (Math.abs(v('total_assets') - v('equity_liabilities')) >= 1) {
    checks.push(`The statement of financial position in the file does not balance: total assets ${v('total_assets')} against equity and liabilities ${v('equity_liabilities')}.`);
  }
  return { rows, checks };
}

// ------------------------------------------------------------------ the financial statements, as Counta's Excel download lays them out
export const FS_SHEETS: [string, 'pl' | 'fp'][] = [['Profit or loss and OCI', 'pl'], ['Financial position', 'fp']];
const NOT_BOOKED = /^(total\b|gross profit|operating profit|profit before tax|profit for the|other comprehensive income for|total comprehensive|assets$|equity and liabilities$|equity$|non-current|current (assets|liabilities)$)/i;

function keyed(prefix: string, rows: { label: string; value: number | null; bookable?: boolean }[]) {
  const seen = new Map<string, number>();
  return rows.map((x) => {
    const n = (seen.get(x.label) || 0) + 1; seen.set(x.label, n);
    return { key: `${prefix}:${x.label}${n > 1 ? `#${n}` : ''}`, ...x };
  });
}
export function fsFigures(bytes: Uint8Array): Figures {
  const r = reader(bytes);
  const out: Figures['rows'] = [];
  for (const [sheet, prefix] of FS_SHEETS) {
    if (!r.has(sheet)) throw new FileProblem(`The file has no sheet named "${sheet}". Upload the Excel statements Counta gave you, with your changes in it.`);
    const last = r.wb.lastRow(sheet);
    const rows: { label: string; value: number | null; bookable?: boolean }[] = [];
    for (let row = 1; row <= Math.min(last, 400); row++) {
      const a = r.value(sheet, `A${row}`), c = r.value(sheet, `C${row}`);
      const label = typeof a === 'string' ? a.trim() : '';
      const value = numOf(c);
      if (!label || value == null) continue;
      rows.push({ label, value, bookable: !NOT_BOOKED.test(label) });
    }
    out.push(...keyed(prefix, rows));
  }
  if (!out.length) throw new FileProblem('Counta found no figures in the statements in the file.');
  return { rows: out, checks: [] };
}
// Counta's own statements for the period, from the same report the download is made from.
export function fsCounta(sopl: any[], sofp: any[]): Figures {
  const pick = (rows: any[]) => (rows || []).filter((x) => ['line', 'subtotal', 'total'].includes(String(x?._style || 'line')) && x?.current != null && String(x?.line || '').trim())
    .map((x) => ({ label: String(x.line).trim(), value: r2(Number(x.current)), bookable: String(x._style || 'line') === 'line' }));
  return { rows: [...keyed('pl', pick(sopl)), ...keyed('fp', pick(sofp))], checks: [] };
}

// ------------------------------------------------------------------ side by side
// Counta's figures (or the version in use) beside the upload's, in the upload's order; lines only one side has come last.
export function sideBySide(base: Figures['rows'], up: Figures['rows']): Row[] {
  const b = new Map(base.map((x) => [x.key, x]));
  const rows: Row[] = up.map((x) => ({ key: x.key, label: x.label, counta: b.get(x.key)?.value ?? (b.has(x.key) ? null : 0), uploaded: x.value,
    bookable: b.has(x.key) ? (b.get(x.key)!.bookable ?? x.bookable ?? false) : (x.bookable ?? false) }));
  const upKeys = new Set(up.map((x) => x.key));
  for (const x of base) if (!upKeys.has(x.key)) rows.push({ key: x.key, label: x.label, counta: x.value, uploaded: 0, bookable: x.bookable ?? false });
  return rows;
}

// The version in use's own figures, as the base for the next upload.
export function fromVersion(figures: Row[]): Figures['rows'] {
  return (figures || []).map((x) => ({ key: x.key, label: x.label, value: x.uploaded, bookable: x.bookable }));
}

// A file name that is safe in a storage path and still recognisable.
export function safeName(name: string) {
  const base = String(name || 'upload.xlsx').split(/[\\/]/).pop()!.replace(/[^A-Za-z0-9._ -]+/g, '_').replace(/\s+/g, '_').slice(-120);
  return /\.xlsx$/i.test(base) ? base : `${base}.xlsx`;
}
