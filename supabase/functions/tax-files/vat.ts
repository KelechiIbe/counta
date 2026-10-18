// The NRS VAT return (Form VAT 002) on the official workbook: schedules A to F written from the month's schedule
// (public.vat_schedule), the form's lines left to the template's own formulas, and each line checked against what Counta
// worked out. Only input cells are written; the template's totals and the form compute themselves.
import { serial, Workbook } from './xlsx.ts';

export type VatSchedule = {
  period: string; to: string; file_name: string;
  org: { name: string; tin: string | null; tax_id: string | null; state: string | null };
  a: { customer: string; tin: string | null; product: string; category: number; label: string | null; state: string | null; lga: string | null; amount: number }[];
  b: { description: string; tin: string | null; customer: string; date: string; invoice: string; invoice_amount: number; adjusted: number }[];
  c2: Record<'goods' | 'services' | 'fixed_assets', { seller: string; tin: string | null; description: string; amount: number }[]>;
  c_variance: Record<'goods' | 'services' | 'fixed_assets', number>;
  zero_share: number;
  c1: { description: string; amount: number; zero: number }[];
  d: { importer: string; description: string; vessel: string | null; country: string | null; form_m: string | null; bill_of_lading: string | null; quantity: number | null;
    currency: string; invoice_value: number; fx_rate: number; value_ngn: number; other_charges: number; total_cost: number; import_vat: number }[];
  e: { name: string; tin: string | null; status: string; description: string; category: string; place: string | null; amount: number }[];
  f: { agent: string; address: string | null; tin: string | null; nature: string; date: string; invoice: string; currency: string; invoice_value: number; fx_rate: number;
    value_ngn: number; vat: number }[];
  lines: Record<string, number>;
  counta: { net: number; output: number; input: number; wvat_credit: number; filed: boolean; status: string };
  difference: number; tolerance: number;
  checks: { severity: string; code: string; text: string; fix?: unknown }[];
  blocked: boolean;
};
export type VatTie = { line: string; label: string; template: number; counta: number; ok: boolean };

const FORM = 'VAT RETURNS FORM', A = 'A - Sales', B = 'B - Sales Adjustments', C = 'C - Purchases', C2 = 'C_2_Purchases List', D = 'D - Imports',
  E = 'E - Self-Charge VAT', F = 'F - Sales to MDAs';
// Form line -> its cell in column U, with what it is.
export const FORM_LINES: [string, string, string][] = [
  ['10', 'U6', 'Total sales, excluding VAT'], ['15', 'U7', 'Exempt sales'], ['20', 'U8', 'Zero-rated sales'], ['22', 'U9', 'Sales adjustments'],
  ['25', 'U10', 'Sales subject to VAT'], ['35', 'U11', 'Output VAT at 7.5%'], ['40', 'U14', 'Standard-rated local purchases'], ['45', 'U15', 'Inventory adjustments'],
  ['55', 'U16', 'VAT on local purchases'], ['85', 'U17', 'Imports'], ['90', 'U18', 'VAT on imports'], ['95', 'U19', 'Total input VAT'],
  ['100', 'U21', 'VAT balance for the period'], ['105', 'U23', 'Input tax on VAT self-charged'], ['110', 'U24', 'VAT withheld by MDAs and agents'],
  ['115', 'U25', 'Net VAT for the period'],
];
const A_FIRST = 6, A_LAST = 9978, B_FIRST = 6, B_LAST = 34, C2_FIRST = 8, C2_LAST = 44, C1_FIRST = 22, C1_ROWS = 14, D_FIRST = 6, D_LAST = 10005,
  E_FIRST = 5, E_LAST = 41, F_FIRST = 6, F_LAST = 2304;
const r2 = (n: number) => Math.round(n * 100) / 100;
const num = (v: unknown) => (typeof v === 'number' ? v : Number(v) || 0);
const regionName = (() => { try { return new Intl.DisplayNames(['en'], { type: 'region' }); } catch { return null; } })();
const country = (code: string | null) => { if (!code) return ''; try { return regionName?.of(code) || code; } catch { return code; } };
const tin = (t: string | null) => (t && /^\d{13}$/.test(t) ? Number(t) : '');

export function fillVat(template: Uint8Array, s: VatSchedule): { bytes: Uint8Array; ties: VatTie[]; rows: Record<string, number> } {
  if (s.a.length > A_LAST - A_FIRST + 1) throw new Error(`Schedule A holds ${A_LAST - A_FIRST + 1} rows; this month has ${s.a.length}.`);
  if (s.e.length > E_LAST - E_FIRST + 1) throw new Error(`Schedule E holds ${E_LAST - E_FIRST + 1} rows; this month has ${s.e.length}.`);
  if (s.f.length > F_LAST - F_FIRST + 1) throw new Error(`Schedule F holds ${F_LAST - F_FIRST + 1} rows; this month has ${s.f.length}.`);
  if (s.d.length > D_LAST - D_FIRST + 1) throw new Error(`Schedule D holds ${D_LAST - D_FIRST + 1} rows; this month has ${s.d.length}.`);
  if (s.c1.length > C1_ROWS) throw new Error(`Sub-schedule C1 holds ${C1_ROWS} rows; this month has ${s.c1.length}.`);
  // Lazily: a schedule with nothing written to it keeps the template's own values, and is not even read.
  const wb = new Workbook(template, { lazy: true });

  // A: sales by customer, product, VAT status, NRS description and place of consumption.
  s.a.forEach((r, i) => {
    const row = A_FIRST + i;
    wb.set(A, `B${row}`, r.customer);
    if (tin(r.tin) !== '') wb.set(A, `C${row}`, tin(r.tin));
    wb.set(A, `D${row}`, r.product);
    wb.set(A, `E${row}`, r.category);
    if (r.category !== 0 && r.label) wb.set(A, `F${row}`, r.label);
    if (r.state) wb.set(A, `G${row}`, r.state);
    if (r.lga) wb.set(A, `H${row}`, r.lga);
    wb.set(A, `I${row}`, r2(num(r.amount)));
  });

  // B: one row per credit note on standard-rated sales; the table grows past its 29 rows when needed.
  s.b.forEach((r, i) => {
    const row = B_FIRST + i;
    if (row > B_LAST) wb.cloneRow(B, B_LAST, row);
    wb.set(B, `B${row}`, r.description);
    if (tin(r.tin) !== '') wb.set(B, `C${row}`, tin(r.tin));
    wb.set(B, `D${row}`, r.customer);
    wb.set(B, `E${row}`, serial(r.date));
    wb.set(B, `F${row}`, r.invoice);
    wb.set(B, `G${row}`, r2(num(r.invoice_amount)));
    wb.set(B, `H${row}`, r2(num(r.adjusted)));
  });
  if (s.b.length > B_LAST - B_FIRST + 1) wb.growTable('tbl_sales_adjustment', B_FIRST + s.b.length - 1);

  // C_2: the purchases list, goods (B-F), services (J-N) and fixed assets (P-T), all standard-rated.
  const lists: [keyof VatSchedule['c2'], string[]][] = [['goods', ['B', 'C', 'D', 'E', 'F']], ['services', ['J', 'K', 'L', 'M', 'N']], ['fixed_assets', ['P', 'Q', 'R', 'S', 'T']]];
  const c2Rows = Math.max(0, ...lists.map(([k]) => (s.c2[k] || []).length));
  for (let row = C2_LAST + 1; row < C2_FIRST + c2Rows; row++) wb.cloneRow(C2, C2_LAST, row);
  for (const [k, cols] of lists) {
    (s.c2[k] || []).forEach((r, i) => {
      const row = C2_FIRST + i;
      wb.set(C2, `${cols[0]}${row}`, r.seller);
      if (tin(r.tin) !== '') wb.set(C2, `${cols[1]}${row}`, tin(r.tin));
      wb.set(C2, `${cols[2]}${row}`, r.description);
      wb.set(C2, `${cols[3]}${row}`, r2(num(r.amount)));
      wb.set(C2, `${cols[4]}${row}`, 'Standard-Rated');
    });
  }

  // C: suppliers' credit notes as the reconciliation, and the zero-rated part of each total.
  const zs = num(s.zero_share);
  ([['goods', 5], ['services', 6], ['fixed_assets', 7]] as const).forEach(([k, row]) => {
    const v = r2(num(s.c_variance?.[k]));
    if (v !== 0) wb.set(C, `D${row}`, v);
    const total = num(wb.value(C, `C${row}`)) + v;
    if (zs > 0 && total !== 0) wb.set(C, `F${row}`, r2(total * zs));
  });
  // C1: opening and closing stock stay blank; stock written off goes on the sub-schedule.
  s.c1.forEach((r, i) => {
    const row = C1_FIRST + i;
    wb.set(C, `B${row}`, r.description);
    wb.set(C, `C${row}`, r2(num(r.amount)));
    if (num(r.zero)) wb.set(C, `D${row}`, r2(num(r.zero)));
  });

  // D: imports; the template works the VAT out (7.5% of the total cost).
  s.d.forEach((r, i) => {
    const row = D_FIRST + i;
    wb.set(D, `C${row}`, r.importer);
    wb.set(D, `D${row}`, r.description);
    if (r.vessel) wb.set(D, `E${row}`, r.vessel);
    if (r.country) wb.set(D, `F${row}`, country(r.country));
    if (r.form_m) wb.set(D, `G${row}`, r.form_m);
    if (r.bill_of_lading) wb.set(D, `H${row}`, r.bill_of_lading);
    if (r.quantity != null) wb.set(D, `I${row}`, num(r.quantity));
    wb.set(D, `J${row}`, r.currency);
    wb.set(D, `K${row}`, r2(num(r.invoice_value)));
    wb.set(D, `L${row}`, num(r.fx_rate));
    wb.set(D, `M${row}`, r2(num(r.value_ngn)));
    wb.set(D, `N${row}`, r2(num(r.other_charges)));
    wb.set(D, `O${row}`, r2(num(r.total_cost)));
  });

  // E: VAT self-charged.
  s.e.forEach((r, i) => {
    const row = E_FIRST + i;
    wb.set(E, `B${row}`, r.name);
    if (tin(r.tin) !== '') wb.set(E, `C${row}`, tin(r.tin));
    wb.set(E, `D${row}`, r.status);
    wb.set(E, `E${row}`, r.description);
    wb.set(E, `F${row}`, r.category);
    if (r.place) wb.set(E, `G${row}`, r.place);
    wb.set(E, `H${row}`, r2(num(r.amount)));
  });

  // F: VAT withheld by MDAs and appointed agents; the template works out 7.5% of the value.
  s.f.forEach((r, i) => {
    const row = F_FIRST + i;
    wb.set(F, `C${row}`, r.agent);
    if (r.address) wb.set(F, `D${row}`, r.address);
    if (tin(r.tin) !== '') wb.set(F, `E${row}`, tin(r.tin));
    wb.set(F, `F${row}`, r.nature);
    wb.set(F, `G${row}`, serial(r.date));
    wb.set(F, `H${row}`, r.invoice);
    wb.set(F, `I${row}`, r.currency);
    wb.set(F, `J${row}`, r2(num(r.invoice_value)));
    wb.set(F, `K${row}`, num(r.fx_rate));
    wb.set(F, `L${row}`, r2(num(r.value_ngn)));
  });

  // The form, as the template computes it, against Counta's lines.
  const ties: VatTie[] = FORM_LINES.map(([line, cell, label]) => {
    const t = num(wb.value(FORM, cell)); const c = num(s.lines?.[line]);
    return { line, label, template: r2(t), counta: r2(c), ok: Math.abs(t - c) <= 0.03 };
  });
  return { bytes: wb.save({ level: 1 }), ties,
    rows: { a: s.a.length, b: s.b.length, c2: lists.reduce((n, [k]) => n + (s.c2[k] || []).length, 0), c1: s.c1.length, d: s.d.length, e: s.e.length, f: s.f.length } };
}
