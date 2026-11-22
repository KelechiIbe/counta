// Reading a month of sales exported from another POS or sales system, for Sell → Import sales.
//
// Two layouts are read. One row per sale (the usual POS export): a date, the products as a list in one cell, the total,
// any discount, the cash part and the way it was paid ("card-and-cash"). One row per product (Counta's template, and most
// accounting exports): rows sharing a receipt number are one sale, each with its quantity and unit price, and the payment
// amounts on the receipt's first row. Either way every sale gets a key that is the same each time the same sale is
// uploaded (its receipt number, else a fingerprint of the row), so the database never posts it twice.
//
// Nothing here talks to the database: it turns sheet rows into sales the database posts (see sales_import_batch).
import type { Cell } from './sheet';

export type Method = 'cash' | 'card' | 'pos' | 'transfer' | 'cheque' | 'other';
export type Layout = 'per_sale' | 'per_line';
// fixed: the quantity is in the file (a quantity column, "2 x", or the name listed twice); otherwise it may be worked out.
export type UpLine = { name: string; key: string; qty: number; unit_price: number | null; discount: number; fixed: boolean };
export type UpPay = { label: string; method: Method; amount: number };
export type UpRow = {
  row: number; key: string; receipt: string | null; kind: 'sale' | 'return'; at: string | null; day: string | null;
  customer: { name: string | null; phone: string | null; email: string | null; tin: string | null };
  branch: string | null; total: number | null; discount: number; lines: UpLine[]; pay: UpPay[]; owed: number;
  original: string | null; sold_by: string | null; note: string | null; problems: string[];
};
export type Field = { key: string; label: string; layouts: Layout[]; syn: string[]; hint?: string };

export const FIELDS: Field[] = [
  { key: 'date', label: 'Date (and time)', layouts: ['per_sale', 'per_line'], syn: ['sale date', 'date', 'transaction date', 'trans date', 'date time', 'datetime', 'created at', 'created', 'receipt date', 'invoice date', 'order date', 'timestamp'] },
  { key: 'time', label: 'Time (if separate)', layouts: ['per_sale', 'per_line'], syn: ['time', 'sale time', 'transaction time'] },
  { key: 'receipt', label: 'Receipt or sale number', layouts: ['per_sale', 'per_line'], syn: ['receipt no', 'receipt number', 'receipt', 'invoice no', 'invoice number', 'sale no', 'sale id', 'order no', 'order id', 'order number', 'transaction id', 'reference', 'ref', 'ticket'] },
  { key: 'customer', label: 'Customer', layouts: ['per_sale', 'per_line'], syn: ['customer', 'customer name', 'client', 'buyer', 'client name'] },
  { key: 'phone', label: 'Customer phone', layouts: ['per_sale', 'per_line'], syn: ['phone', 'customer phone', 'phone number', 'mobile', 'telephone'] },
  { key: 'email', label: 'Customer email', layouts: ['per_sale', 'per_line'], syn: ['email', 'customer email', 'e mail'] },
  { key: 'tin', label: 'Customer Tax ID', layouts: ['per_sale', 'per_line'], syn: ['tin', 'tax id', 'customer tin', 'customer tax id'] },
  { key: 'branch', label: 'Branch or location', layouts: ['per_sale', 'per_line'], syn: ['business location', 'location', 'branch', 'store', 'outlet', 'shop'] },
  { key: 'items', label: 'Products sold (a list in one cell)', layouts: ['per_sale'], syn: ['sale items', 'items', 'products', 'items sold', 'products sold', 'line items', 'basket', 'description', 'details'] },
  { key: 'item', label: 'Product', layouts: ['per_line'], syn: ['product', 'item', 'product name', 'item name', 'description', 'sale item'] },
  { key: 'qty', label: 'Quantity', layouts: ['per_line'], syn: ['quantity', 'qty', 'units', 'count'] },
  { key: 'unit_price', label: 'Unit price', layouts: ['per_line'], syn: ['unit price', 'price', 'rate', 'selling price'] },
  { key: 'line_discount', label: 'Discount on the product', layouts: ['per_line'], syn: ['discount on the product', 'line discount', 'item discount', 'product discount'] },
  { key: 'total', label: 'Sale total', layouts: ['per_sale'], syn: ['total amount', 'total', 'amount', 'grand total', 'sale total', 'gross', 'value', 'amount paid'] },
  { key: 'discount', label: 'Discount on the sale', layouts: ['per_sale', 'per_line'], syn: ['discount on the sale', 'discount amount', 'discount', 'sale discount', 'cart discount'] },
  { key: 'method', label: 'Way of paying', layouts: ['per_sale', 'per_line'], syn: ['payment method', 'payment type', 'payment', 'method', 'tender', 'paid by', 'payment mode', 'mode', 'channel'] },
  { key: 'cash_amount', label: 'Cash part', layouts: ['per_sale'], syn: ['cash amount', 'cash', 'cash paid', 'cash tendered'] },
  { key: 'paid_cash', label: 'Paid in cash', layouts: ['per_line'], syn: ['paid in cash', 'cash', 'cash amount', 'paid cash'] },
  { key: 'paid_card', label: 'Paid by card or POS', layouts: ['per_line'], syn: ['paid by card or pos', 'card', 'pos', 'paid by card', 'card amount', 'pos amount'] },
  { key: 'paid_transfer', label: 'Paid by transfer', layouts: ['per_line'], syn: ['paid by transfer', 'transfer', 'transfer amount', 'bank transfer'] },
  { key: 'owed', label: 'Amount owed (on credit)', layouts: ['per_sale', 'per_line'], syn: ['amount owed', 'owed', 'balance', 'balance due', 'outstanding', 'credit', 'due'] },
  { key: 'status', label: 'Payment status', layouts: ['per_sale'], syn: ['payment status', 'status', 'paid status'] },
  { key: 'type', label: 'Sale or return', layouts: ['per_sale', 'per_line'], syn: ['type', 'sale or return', 'transaction type', 'kind'] },
  { key: 'original', label: 'Original receipt (for a return)', layouts: ['per_sale', 'per_line'], syn: ['original receipt', 'original sale', 'returned receipt', 'refund of', 'original'] },
  { key: 'sold_by', label: 'Sold by', layouts: ['per_sale', 'per_line'], syn: ['sold by', 'cashier', 'staff', 'salesperson', 'served by', 'user', 'attendant'] },
  { key: 'note', label: 'Note', layouts: ['per_sale', 'per_line'], syn: ['note', 'notes', 'remark', 'remarks', 'comment'] },
];

const norm = (h: unknown) => String(h ?? '').toLowerCase().replace(/[*_\-.:#()/\\₦[\]]/g, ' ').replace(/\s+/g, ' ').trim();
const text = (c: Cell | undefined): string => (c == null ? '' : c instanceof Date ? c.toISOString() : typeof c === 'number' ? String(c) : String(c).trim());
const round2 = (n: number) => Math.round(n * 100) / 100;

export function num(c: Cell | undefined): number | null {
  if (c == null || c === '') return null;
  if (typeof c === 'number') return isFinite(c) ? c : null;
  if (typeof c === 'boolean' || c instanceof Date) return null;
  let s = String(c).trim();
  const neg = /^\(.*\)$/.test(s) || /^-/.test(s.replace(/^[₦N$\s]+/, ''));
  s = s.replace(/[()₦,\s]|NGN|^N/gi, '').replace(/^-/, '');
  if (!/^\d*\.?\d+$/.test(s)) return null;
  const n = Number(s);
  return isFinite(n) ? (neg ? -n : n) : null;
}

// The product key the database uses (private.product_key): lower case, single spaces, trimmed.
export const productKey = (s: string) => s.trim().replace(/\s+/g, ' ').toLowerCase().slice(0, 200);

// Which column holds which field: an exact header wins, then the longest synonym inside the header.
export function matchColumns(headers: string[], layout: Layout): Record<string, number> {
  const out: Record<string, number> = {}; const used = new Set<number>();
  const fields = FIELDS.filter((f) => f.layouts.includes(layout));
  // Exact headers first, so "Cash Amount" goes to cash and "Total Amount" to total before looser matches.
  for (const pass of [0, 1]) {
    for (const f of fields) {
      if (out[f.key] != null) continue;
      let best = -1, score = 0;
      headers.forEach((raw, i) => {
        if (used.has(i)) return;
        const x = norm(raw);
        const s = f.syn.reduce((a, syn) => Math.max(a, x === syn ? 100 : pass === 1 && syn.length > 3 && (` ${x} `).includes(` ${syn} `) ? syn.length : 0), 0);
        if (s > score) { score = s; best = i; }
      });
      if (best >= 0) { out[f.key] = best; used.add(best); }
    }
  }
  return out;
}

// One row per product when the file has quantities or unit prices per row; one row per sale when it has a list of products.
export function guessLayout(headers: string[]): Layout {
  const h = headers.map(norm);
  const has = (...xs: string[]) => h.some((x) => xs.includes(x));
  if (has('sale items', 'items', 'products sold', 'items sold', 'line items')) return 'per_sale';
  if (has('quantity', 'qty') && has('unit price', 'price', 'rate')) return 'per_line';
  return 'per_sale';
}

// "['Procold Tab X 4', 'Otrivin Adults Nasal Drop 01']" (a Python list, as Brooks' POS writes it), a JSON list, or
// products separated by semicolons, new lines or commas. "2 x Panadol" is two of Panadol; repeats add up.
export function splitItems(cell: string): { name: string; qty: number; fixed: boolean }[] {
  const s = cell.trim();
  let parts: string[] = [];
  if (/^\[.*\]$/s.test(s)) {
    const re = /'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)"/g;
    let m: RegExpExecArray | null;
    while ((m = re.exec(s))) parts.push((m[1] ?? m[2]).replace(/\\(.)/g, '$1'));
    if (!parts.length) parts = s.slice(1, -1).split(',');
  } else {
    parts = s.split(/[;\n|]+/);
    if (parts.length === 1 && /,\s/.test(s)) parts = s.split(/,\s+/);
  }
  const out = new Map<string, { name: string; qty: number; fixed: boolean }>();
  for (const raw of parts) {
    let name = raw.replace(/\s+/g, ' ').trim();
    if (!name) continue;
    let qty = 1, fixed = false;
    const m = /^(\d+(?:\.\d+)?)\s*[x×*]\s+(.+)$/i.exec(name);
    if (m) { qty = Number(m[1]); name = m[2].trim(); fixed = true; }
    const k = productKey(name);
    const had = out.get(k);
    if (had) { had.qty += qty; had.fixed = true; } else out.set(k, { name, qty, fixed });
  }
  return [...out.values()];
}

export function methodOf(label: string): Method {
  const s = label.toLowerCase();
  if (/cash/.test(s)) return 'cash';
  if (/\bpos\b|terminal|moniepoint|opay|palmpay|paystack terminal/.test(s)) return 'pos';
  if (/card|visa|master|verve|debit|credit card/.test(s)) return 'card';
  if (/transfer|bank|trf|nip|ussd|account/.test(s)) return 'transfer';
  if (/cheque|check/.test(s)) return 'cheque';
  return 'other';
}
// "card-and-cash", "Cash + Transfer", "card/cash": each way of paying named, in order.
export function splitMethods(cell: string): string[] {
  return cell.toLowerCase().split(/\s*(?:-and-|\band\b|&|\+|\/|,|;)\s*/).map((x) => x.replace(/[-_]+/g, ' ').trim()).filter(Boolean);
}

// A date and time from the file: a timestamp with its zone ("2026-07-31 20:44:48.05+00:00") keeps its moment; a time with
// no zone is Nigerian time; a date alone is that day. Day-first dates ("05/07/2026") are read as 5 July.
export function readWhen(c: Cell | undefined, timeCell?: Cell): { at: string | null; day: string | null } {
  if (c == null || c === '') return { at: null, day: null };
  const pad = (n: number) => String(n).padStart(2, '0');
  if (c instanceof Date) {
    // A spreadsheet date is wall time where it was typed: read it as Nigerian time.
    const day = `${c.getFullYear()}-${pad(c.getMonth() + 1)}-${pad(c.getDate())}`;
    const t = c.getHours() || c.getMinutes() || c.getSeconds() ? `${pad(c.getHours())}:${pad(c.getMinutes())}:${pad(c.getSeconds())}` : timeOf(timeCell);
    return { day, at: t ? `${day}T${t}+01:00` : null };
  }
  if (typeof c === 'number') {
    // An Excel serial day number.
    if (c < 20000 || c > 80000) return { at: null, day: null };
    const ms = Math.round((c - 25569) * 86400000);
    const d = new Date(ms);
    const day = `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`;
    const frac = c % 1;
    const t = frac > 0 ? `${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())}` : timeOf(timeCell);
    return { day, at: t ? `${day}T${t}+01:00` : null };
  }
  const s = String(c).trim();
  let m = /^(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?\s*(Z|[+-]\d{2}:?\d{2})?)?$/i.exec(s);
  if (m) {
    const day = `${m[1]}-${pad(+m[2])}-${pad(+m[3])}`;
    if (m[4] == null) { const t = timeOf(timeCell); return { day, at: t ? `${day}T${t}+01:00` : null }; }
    const zone = m[7] ? (m[7].toUpperCase() === 'Z' ? 'Z' : m[7].length === 5 ? `${m[7].slice(0, 3)}:${m[7].slice(3)}` : m[7]) : '+01:00';
    const at = `${day}T${pad(+m[4])}:${m[5]}:${m[6] ?? '00'}${zone}`;
    // The day follows the moment in Nigeria (a sale at 23:30 UTC is the next day in Lagos), worked out by the database.
    return { day: zone === '+01:00' ? day : null, at };
  }
  m = /^(\d{1,2})[/.-](\d{1,2})[/.-](\d{2,4})(?:\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([ap]m)?)?$/i.exec(s);
  if (m) {
    let y = +m[3]; if (y < 100) y += 2000;
    const d = +m[1], mo = +m[2];
    if (mo > 12 || d > 31) return { at: null, day: null };
    const day = `${y}-${pad(mo)}-${pad(d)}`;
    let t: string | null = null;
    if (m[4] != null) {
      let h = +m[4]; if (m[7]) { const pm = m[7].toLowerCase() === 'pm'; if (pm && h < 12) h += 12; if (!pm && h === 12) h = 0; }
      t = `${pad(h)}:${m[5]}:${m[6] ?? '00'}`;
    } else t = timeOf(timeCell);
    return { day, at: t ? `${day}T${t}+01:00` : null };
  }
  const p = Date.parse(s);
  if (!isNaN(p)) { const d = new Date(p); return { day: null, at: d.toISOString() }; }
  return { at: null, day: null };
}
function timeOf(c?: Cell): string | null {
  if (c == null || c === '') return null;
  const pad = (n: number) => String(n).padStart(2, '0');
  if (c instanceof Date) return `${pad(c.getHours())}:${pad(c.getMinutes())}:${pad(c.getSeconds())}`;
  if (typeof c === 'number' && c >= 0 && c < 1) { const s = Math.round(c * 86400); return `${pad(Math.floor(s / 3600))}:${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}`; }
  const m = /^(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([ap]m)?$/i.exec(String(c).trim());
  if (!m) return null;
  let h = +m[1]; if (m[4]) { const pm = m[4].toLowerCase() === 'pm'; if (pm && h < 12) h += 12; if (!pm && h === 12) h = 0; }
  return `${pad(h)}:${m[2]}:${m[3] ?? '00'}`;
}

// A short stable fingerprint (cyrb53), for rows without a receipt number.
function hash(s: string): string {
  let h1 = 0xdeadbeef, h2 = 0x41c6ce57;
  for (let i = 0; i < s.length; i++) { const c = s.charCodeAt(i); h1 = Math.imul(h1 ^ c, 2654435761); h2 = Math.imul(h2 ^ c, 1597334677); }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909);
  return (4294967296 * (2097151 & h2) + (h1 >>> 0)).toString(36);
}

export type ReadOptions = {
  layout: Layout; map: Record<string, number>;
  // The file's total is before its discount (Brooks: Total Amount 2,600, Discount 400, Cash 2,200 paid).
  totalBeforeDiscount: boolean;
};

const isReturnWord = (s: string) => /return|refund|credit note|reversal|void/i.test(s);
const unpaidWord = (s: string) => /unpaid|not paid|credit|due|pending|partial|part/i.test(s);

// The rows of the sheet below the header, as sales and returns.
export function readSales(rows: Cell[][], rowNo: number[] | undefined, headerIdx: number, o: ReadOptions): UpRow[] {
  const get = (r: Cell[], k: string): Cell | undefined => (o.map[k] != null ? r[o.map[k]] : undefined);
  const out: UpRow[] = [];
  const body = rows.slice(headerIdx + 1).map((r, i) => ({ r, n: rowNo?.[headerIdx + 1 + i] ?? headerIdx + 2 + i }));
  const blank = (r: Cell[]) => !r || r.every((c) => c == null || String(c).trim() === '');
  const isTotalRow = (r: Cell[]) => r.slice(0, 3).some((c) => /^(grand\s+)?(sub\s*)?totals?\b/i.test(text(c)));
  const base = (r: Cell[], n: number): UpRow => {
    const when = readWhen(get(r, 'date'), get(r, 'time'));
    const kindText = `${text(get(r, 'type'))} ${text(get(r, 'status'))}`;
    return {
      row: n, key: '', receipt: text(get(r, 'receipt')) || null, kind: isReturnWord(kindText) ? 'return' : 'sale', at: when.at, day: when.day,
      customer: { name: text(get(r, 'customer')) || null, phone: text(get(r, 'phone')) || null, email: text(get(r, 'email')) || null, tin: text(get(r, 'tin')) || null },
      branch: text(get(r, 'branch')) || null, total: null, discount: 0, lines: [], pay: [], owed: 0,
      original: text(get(r, 'original')) || null, sold_by: text(get(r, 'sold_by')) || null, note: text(get(r, 'note')) || null, problems: [],
    };
  };
  if (o.layout === 'per_sale') {
    for (const { r, n } of body) {
      if (blank(r) || isTotalRow(r)) continue;
      const u = base(r, n);
      const items = splitItems(text(get(r, 'items')));
      u.lines = items.map((i) => ({ name: i.name, key: productKey(i.name), qty: i.qty, unit_price: null, discount: 0, fixed: i.fixed }));
      let total = num(get(r, 'total'));
      const disc = Math.abs(num(get(r, 'discount')) ?? 0);
      if (total != null && total < 0) { u.kind = 'return'; total = -total; }
      if (total != null && o.totalBeforeDiscount) total = round2(total - disc);
      u.total = total; u.discount = disc;
      if (!u.day && !u.at) u.problems.push('No date');
      if (!u.lines.length) u.problems.push('No products');
      if (total == null || total <= 0) u.problems.push('No total');
      const owed = Math.max(num(get(r, 'owed')) ?? 0, 0);
      const status = text(get(r, 'status'));
      const paid = total == null ? 0 : round2(Math.max(total - (owed || (unpaidWord(status) && !/^paid$/i.test(status) && num(get(r, 'owed')) == null ? total : 0)), 0));
      u.owed = total == null ? 0 : round2(total - paid);
      const labels = splitMethods(text(get(r, 'method')));
      const cash = Math.max(num(get(r, 'cash_amount')) ?? 0, 0);
      if (paid > 0) {
        if (!labels.length) labels.push(cash > 0 ? 'cash' : 'other');
        const cashLabel = labels.find((l) => methodOf(l) === 'cash');
        const others = labels.filter((l) => methodOf(l) !== 'cash');
        if (cashLabel && others.length) {
          // Part cash, part another way: the cash part is the cash column (what was handed over, at most the sale).
          const c = Math.min(cash, paid);
          if (c > 0) u.pay.push({ label: cashLabel, method: 'cash', amount: round2(c) });
          if (paid - c > 0.004) u.pay.push({ label: others[0], method: methodOf(others[0]), amount: round2(paid - c) });
          if (others.length > 1) u.problems.push(`Paid ${others.join(' and ')}: all of it is put on ${others[0]}`);
        } else {
          if (labels.length > 1) u.problems.push(`Paid ${labels.join(' and ')}: all of it is put on ${labels[0]}`);
          u.pay.push({ label: labels[0], method: methodOf(labels[0]), amount: paid });
        }
      }
      out.push(u);
    }
  } else {
    // Rows sharing a receipt number are one sale; without receipt numbers each row is a sale of its own.
    const groups = new Map<string, { r: Cell[]; n: number }[]>();
    body.forEach((x, i) => {
      if (blank(x.r) || isTotalRow(x.r)) return;
      const rc = text(get(x.r, 'receipt'));
      const k = rc ? `r:${rc}` : `n:${i}`;
      const g = groups.get(k); if (g) g.push(x); else groups.set(k, [x]);
    });
    for (const g of groups.values()) {
      const first = g[0].r;
      const u = base(first, g[0].n);
      for (const { r } of g) {
        const name = text(get(r, 'item'));
        if (!name) continue;
        let qty = num(get(r, 'qty')) ?? 1;
        const kindText = `${text(get(r, 'type'))}`;
        if (qty < 0 || isReturnWord(kindText)) { u.kind = 'return'; qty = Math.abs(qty); }
        const price = num(get(r, 'unit_price'));
        u.lines.push({ name, key: productKey(name), qty, unit_price: price == null ? null : Math.abs(price), discount: Math.abs(num(get(r, 'line_discount')) ?? 0), fixed: true });
        if (!u.day && !u.at) { const w = readWhen(get(r, 'date'), get(r, 'time')); u.day = w.day; u.at = w.at; }
      }
      u.discount = Math.abs(num(get(first, 'discount')) ?? 0);
      const priced = u.lines.length > 0 && u.lines.every((l) => l.unit_price != null);
      u.total = priced ? round2(u.lines.reduce((a, l) => a + round2(l.qty * (l.unit_price ?? 0)) - l.discount, 0) - u.discount) : null;
      if (!u.day && !u.at) u.problems.push('No date');
      if (!u.lines.length) u.problems.push('No products');
      if (!priced) u.problems.push('A product has no unit price');
      const pc = Math.abs(num(get(first, 'paid_cash')) ?? 0), pk = Math.abs(num(get(first, 'paid_card')) ?? 0), pt = Math.abs(num(get(first, 'paid_transfer')) ?? 0);
      const owed = Math.max(num(get(first, 'owed')) ?? 0, 0);
      const label = splitMethods(text(get(first, 'method')))[0];
      if (pc) u.pay.push({ label: 'cash', method: 'cash', amount: round2(pc) });
      if (pk) u.pay.push({ label: 'card or POS', method: 'card', amount: round2(pk) });
      if (pt) u.pay.push({ label: 'transfer', method: 'transfer', amount: round2(pt) });
      if (!u.pay.length && u.total != null && u.total - owed > 0.004) {
        // No amounts by way of paying: paid in full (less what is owed) the way the method column says.
        u.pay.push({ label: label || 'other', method: methodOf(label || 'other'), amount: round2(u.total - owed) });
      }
      const paid = u.pay.reduce((a, p) => a + p.amount, 0);
      u.owed = u.total == null ? owed : round2(Math.max(u.total - paid, 0));
      out.push(u);
    }
  }
  // Keys: the receipt number when there is one, else a fingerprint of what was sold, when and how, numbered when the same
  // fingerprint comes up more than once (two identical sales on one day are two sales).
  const seen = new Map<string, number>();
  for (const u of out) {
    if (u.receipt) { u.key = `r:${u.kind === 'return' ? 'ret:' : ''}${u.receipt}`; continue; }
    const f = hash([u.kind, u.at ?? u.day, u.total, u.discount, u.customer.name, u.branch, u.lines.map((l) => `${l.key}*${l.qty}`).join('|'),
      u.pay.map((p) => `${p.label}:${p.amount}`).join('|')].join('~'));
    const k = seen.get(f) ?? 0; seen.set(f, k + 1);
    u.key = `f:${f}#${k}`;
  }
  return out;
}

// What the file itself says one of each product sells for, from the sales with that product alone. Some POS exports list
// a product once whatever the quantity (four bars at ₦4,200 show as one bar for ₦16,800), so the price taken is the one
// that explains most of those sales as whole quantities, then the commonest, then the higher.
export function priceHints(rows: UpRow[]): Map<string, number> {
  const by = new Map<string, number[]>();
  for (const u of rows) {
    if (u.kind !== 'sale' || u.lines.length !== 1 || u.total == null) continue;
    const l = u.lines[0];
    const p = l.unit_price ?? (u.total + u.discount) / l.qty;
    if (!(p > 0)) continue;
    const a = by.get(l.key); if (a) a.push(round2(p)); else by.set(l.key, [round2(p)]);
  }
  const out = new Map<string, number>();
  for (const [k, a] of by) {
    let best = 0, bestFit = -1, bestCount = -1;
    for (const p of new Set(a)) {
      const fit = a.filter((t) => wholeMultiple(t, p) != null).length;
      const count = a.filter((t) => t === p).length;
      if (fit > bestFit || (fit === bestFit && (count > bestCount || (count === bestCount && p > best)))) { best = p; bestFit = fit; bestCount = count; }
    }
    out.set(k, best);
  }
  return out;
}
// Prices for products that only sold with others: in a sale where every other product's price is known, this one's is
// what is left, one of each assumed. Repeated while it finds more; each product takes the price most sales point to.
export function solvePrices(rows: UpRow[], known: Map<string, number>): Map<string, number> {
  const out = new Map(known);
  for (let pass = 0; pass < 6; pass++) {
    const cand = new Map<string, number[]>();
    for (const u of rows) {
      if (u.kind !== 'sale' || u.total == null || u.lines.length < 2) continue;
      const unknown = u.lines.filter((l) => l.unit_price == null && !out.has(l.key));
      if (unknown.length !== 1) continue;
      const rest = u.lines.reduce((a, l) => a + (l === unknown[0] ? 0 : (l.unit_price ?? out.get(l.key)!) * l.qty - l.discount), 0);
      const p = round2((u.total + u.discount - rest) / unknown[0].qty);
      if (!(p > 0)) continue;
      const c = cand.get(unknown[0].key); if (c) c.push(p); else cand.set(unknown[0].key, [p]);
    }
    if (!cand.size) break;
    for (const [k, a] of cand) {
      const count = new Map<number, number>(); a.forEach((p) => count.set(p, (count.get(p) ?? 0) + 1));
      const top = [...count.entries()].sort((x, y) => y[1] - x[1] || x[0] - y[0]);
      a.sort((x, y) => x - y);
      out.set(k, top[0][1] > 1 ? top[0][0] : a[Math.floor((a.length - 1) / 2)]);
    }
  }
  return out;
}

// n when t is n times p (to within half a percent), else null.
function wholeMultiple(t: number, p: number): number | null {
  if (!(p > 0) || !(t > 0)) return null;
  const n = Math.round(t / p);
  return n >= 1 && n <= 1000 && Math.abs(t - n * p) <= Math.max(0.01, t * 0.005) ? n : null;
}

// Quantities the file did not give, worked out from the prices: a product alone at a whole multiple of its price; several
// products whose prices add up to the sale in exactly one way (up to 12 of each, for up to 4 products). Returns how many
// sales changed and how many still have guessed quantities (one of each, the total shared by price).
export function inferQuantities(rows: UpRow[], priceOf: (key: string) => number | null): { worked: number; guessed: number } {
  let worked = 0, guessed = 0;
  for (const u of rows) {
    if (u.kind !== 'sale' || u.total == null || !u.lines.length || u.lines.every((l) => l.fixed || l.unit_price != null)) continue;
    const target = round2(u.total + u.discount);
    const prices = u.lines.map((l) => priceOf(l.key));
    if (prices.some((p) => !(p != null && p > 0))) { if (u.lines.length > 1) guessed++; continue; }
    if (u.lines.length === 1) {
      const n = wholeMultiple(target, prices[0]!);
      if (n != null && n !== u.lines[0].qty) { u.lines[0].qty = n; worked++; }
      continue;
    }
    if (u.lines.length > 4) { guessed++; continue; }
    const k = u.lines.length; const q = new Array(k).fill(1); let found: number[] | null = null; let many = false;
    const walk = (i: number, sum: number) => {
      if (many) return;
      if (i === k) {
        if (Math.abs(sum - target) <= 0.01) { if (found) many = true; else found = [...q]; }
        return;
      }
      for (let n = 1; n <= 12; n++) {
        const s2 = sum + n * prices[i]!;
        if (s2 > target + 0.01) break;
        q[i] = n; walk(i + 1, s2);
      }
    };
    walk(0, 0);
    if (found && !many) {
      if (u.lines.some((l, i) => l.qty !== found![i])) worked++;
      u.lines.forEach((l, i) => { l.qty = found![i]; });
    } else guessed++;
  }
  return { worked, guessed };
}

// Brooks' export gives the total before the discount: a cash-only sale with a discount whose cash equals the total less
// the discount says so. Without such a row the total is taken as what was paid.
export function totalLooksBeforeDiscount(rows: Cell[][], headerIdx: number, map: Record<string, number>): boolean | null {
  if (map.total == null || map.discount == null) return null;
  let before = 0, after = 0;
  for (const r of rows.slice(headerIdx + 1)) {
    const t = num(r[map.total]), d = num(r[map.discount]), c = map.cash_amount != null ? num(r[map.cash_amount]) : null;
    const m = map.method != null ? String(r[map.method] ?? '') : '';
    if (!t || !d || d <= 0 || c == null || splitMethods(m).some((x) => methodOf(x) !== 'cash')) continue;
    if (Math.abs(c - (t - d)) < 0.01) before++; else if (Math.abs(c - t) < 0.01) after++;
  }
  return before > after ? true : after > before ? false : null;
}

// The template: one row per product, the payment amounts on the receipt's first row.
export const TEMPLATE_COLUMNS: { h: string; w: number; note: string; fmt?: string; text?: boolean }[] = [
  { h: 'Receipt No*', w: 14, text: true, note: 'Your POS\'s receipt or sale number. Rows with the same number are one sale. Counta never posts the same receipt twice.' },
  { h: 'Date*', w: 12, fmt: 'dd/mm/yyyy', note: 'The day of the sale (day/month/year).' },
  { h: 'Time', w: 9, fmt: 'hh:mm', note: 'Optional. The time of the sale, Nigerian time.' },
  { h: 'Customer', w: 22, note: 'Leave empty, or write Walk-in, for a walk-in customer. A sale not paid in full needs the customer\'s name.' },
  { h: 'Phone', w: 15, text: true, note: 'Optional. Counta finds the customer by phone first.' },
  { h: 'Email', w: 22, note: 'Optional.' },
  { h: 'Customer Tax ID', w: 16, text: true, note: 'Optional. For a business customer.' },
  { h: 'Branch', w: 16, note: 'Optional when you have one branch. The branch\'s name as it is in Counta.' },
  { h: 'Product*', w: 30, note: 'The product\'s name. Counta matches it to your products, and remembers the match for next month.' },
  { h: 'Quantity*', w: 10, fmt: '#,##0.###', note: 'How many were sold (or returned).' },
  { h: 'Unit price*', w: 13, fmt: '#,##0.00', note: 'The price of one, as the customer paid it (VAT inside).' },
  { h: 'Discount on the product', w: 14, fmt: '#,##0.00', note: 'Optional. Naira off this product.' },
  { h: 'Discount on the sale', w: 14, fmt: '#,##0.00', note: 'Optional, on the receipt\'s first row. Naira off the whole sale.' },
  { h: 'Paid in cash', w: 13, fmt: '#,##0.00', note: 'On the receipt\'s first row. What was paid in cash (not counting change).' },
  { h: 'Paid by card or POS', w: 14, fmt: '#,##0.00', note: 'On the receipt\'s first row. What was paid by card or on a POS terminal.' },
  { h: 'Paid by transfer', w: 14, fmt: '#,##0.00', note: 'On the receipt\'s first row. What was paid by bank transfer.' },
  { h: 'Amount owed', w: 13, fmt: '#,##0.00', note: 'On the receipt\'s first row. What the customer still owes: the sale becomes an invoice to them.' },
  { h: 'Sale or return', w: 12, note: 'Sale, or Return for goods brought back. Leave empty for a sale.' },
  { h: 'Original receipt', w: 14, text: true, note: 'For a return: the receipt number of the sale the goods came from.' },
  { h: 'Sold by', w: 14, note: 'Optional. The staff member.' },
  { h: 'Note', w: 24, note: 'Optional.' },
];
