// Orders exported from Bumpa (or any store that exports a CSV of orders): one row per order, or one row per product with
// the order number repeated. Columns are found by their headings, whatever order they come in.
import type { Sale } from './providers.ts';

export function parseCsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [], cell = '', quoted = false;
  const t = text.replace(/^﻿/, '');
  for (let i = 0; i < t.length; i++) {
    const ch = t[i];
    if (quoted) {
      if (ch === '"') { if (t[i + 1] === '"') { cell += '"'; i++; } else quoted = false; }
      else cell += ch;
    } else if (ch === '"') quoted = true;
    else if (ch === ',') { row.push(cell); cell = ''; }
    else if (ch === '\n' || ch === '\r') {
      if (ch === '\r' && t[i + 1] === '\n') i++;
      row.push(cell); cell = '';
      if (row.some((c) => c.trim() !== '')) rows.push(row);
      row = [];
    } else cell += ch;
  }
  row.push(cell);
  if (row.some((c) => c.trim() !== '')) rows.push(row);
  return rows;
}

const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
const FIND: Record<string, RegExp> = {
  id: /^(order (id|no|number|ref(erence)?)|order|invoice (no|number)|reference|ref|id)$/,
  date: /^(date|order date|created( at)?|date created|paid (at|on)|payment date)$/,
  name: /^(customer( name)?|name|buyer( name)?|client( name)?|full name)$/,
  email: /^(customer )?e ?mail( address)?$/,
  phone: /^((customer )?phone( number)?|mobile|whatsapp( number)?|phone no)$/,
  product: /^(product( name)?|item( name)?|products|items|description|product title)$/,
  sku: /^(sku|product code|item code)$/,
  qty: /^(qty|quantity|units)$/,
  amount: /^(total|amount|total amount|order total|grand total|amount paid|total paid|price)$/,
  status: /^(payment status|status|order status|paid)$/,
  currency: /^currency$/,
};

export type Parsed = { sales: Sale[]; rows: number; skipped: { row: number; reason: string }[]; columns: Record<string, string | null> };

// Rows become paid sales: a row whose payment status says it was not paid is left out.
export function bumpaOrders(text: string, prefix = 'bumpa'): Parsed {
  const all = parseCsv(text);
  if (all.length < 2) return { sales: [], rows: 0, skipped: [], columns: {} };
  const head = all[0].map(norm);
  const col: Record<string, number> = {};
  for (const [k, re] of Object.entries(FIND)) { const i = head.findIndex((h) => re.test(h)); if (i >= 0) col[k] = i; }
  const columns = Object.fromEntries(Object.keys(FIND).map((k) => [k, col[k] != null ? all[0][col[k]] : null]));
  const skipped: Parsed['skipped'] = [];
  if (col.amount == null) return { sales: [], rows: all.length - 1, skipped: [{ row: 1, reason: 'No column for the amount (Total or Amount).' }], columns };
  const get = (r: string[], k: string) => (col[k] != null ? String(r[col[k]] ?? '').trim() : '');
  const money = (s: string) => { const v = Number(s.replace(/[₦,\s]|NGN/gi, '')); return Number.isFinite(v) ? Math.round(v * 100) / 100 : NaN; };
  const byOrder = new Map<string, Sale>();
  const first = new Map<string, number>(), summed = new Set<string>(), repeated = new Set<string>();
  all.slice(1).forEach((r, i) => {
    const line = i + 2;
    const status = get(r, 'status').toLowerCase();
    if (status && /(unpaid|pending|not paid|cancel|refund|failed|abandon)/.test(status)) { skipped.push({ row: line, reason: `Not paid (${get(r, 'status')})` }); return; }
    const amount = money(get(r, 'amount'));
    if (!(amount > 0)) { skipped.push({ row: line, reason: 'No amount' }); return; }
    const id = get(r, 'id') || `row-${line}`;
    const qty = Number(get(r, 'qty').replace(/,/g, '')) || 1;
    const product = get(r, 'product');
    const when = get(r, 'date');
    const d = when ? new Date(/^\d{1,2}\/\d{1,2}\/\d{4}/.test(when) ? when.replace(/^(\d{1,2})\/(\d{1,2})\/(\d{4})/, '$3-$2-$1') : when) : null;
    const prev = byOrder.get(id);
    // The same order on more rows: either each row carries that product's amount (the order is their sum), or each repeats
    // the order's total (the order is that total, its products named on one line).
    if (prev) {
      if (Math.abs(amount - (first.get(id) ?? -1)) < 0.005 && !summed.has(id)) {
        const l = prev.lines![0];
        l.name = `${l.name}, ${product || 'item'}`.slice(0, 200); l.qty = 1; l.unit_price = prev.amount; l.sku = null;
        repeated.add(id);
      } else if (!repeated.has(id)) {
        summed.add(id);
        prev.amount = Math.round((prev.amount + amount) * 100) / 100;
        if (product) prev.lines!.push({ name: product, sku: get(r, 'sku') || null, qty, unit_price: Math.round((amount / qty) * 100) / 100 });
      } else skipped.push({ row: line, reason: `Order ${id} appears again with a different total` });
      return;
    }
    first.set(id, amount);
    byOrder.set(id, { external_id: `${prefix}:${id}`.slice(0, 200), occurred_at: d && !Number.isNaN(d.getTime()) ? d.toISOString() : null, amount, fee: 0,
      currency: get(r, 'currency') || 'NGN', reference: id, method: 'other',
      customer: { name: get(r, 'name') || null, email: get(r, 'email') || null, phone: get(r, 'phone') || null },
      lines: [{ name: product || 'Bumpa order', sku: get(r, 'sku') || null, qty, unit_price: Math.round((amount / qty) * 100) / 100 }], note: `Bumpa order ${id}` });
  });
  return { sales: [...byOrder.values()], rows: all.length - 1, skipped, columns };
}
