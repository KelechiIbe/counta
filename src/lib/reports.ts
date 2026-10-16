// The report catalogue for the Reports page. Most reports come from inventory_report() in the database;
// a few (reorder, dead stock, item list) are worked out in the browser from the inventory already loaded.
import type { Inventory } from './types';
import { buildItems, deadStock, type Suggestion } from './domain';
import { typeLabel, fieldsFor, formatAttr, ALL_FIELDS } from './industries';

export type ColType = 'text' | 'date' | 'money' | 'num' | 'qty' | 'pct' | 'int';
export interface RCol { key: string; label: string; type?: ColType; total?: boolean; cost?: boolean; pdf?: boolean; width?: number }
export type Group = 'Stock' | 'Books' | 'Purchases' | 'Sales' | 'Controls';
export interface ReportDef {
  id: string; group: Group; title: string; blurb: string; period: 'range' | 'asAt' | 'none';
  item?: boolean; location?: boolean; accounts?: boolean; needsCosts?: boolean;
  source: 'rpc' | 'reorder' | 'dead' | 'items'; cols: RCol[];
}

const c = (key: string, label: string, type: ColType = 'text', extra: Partial<RCol> = {}): RCol => ({ key, label, type, ...extra });
const money = (key: string, label: string, extra: Partial<RCol> = {}) => c(key, label, 'money', { total: true, ...extra });

export const REPORTS: ReportDef[] = [
  {
    id: 'valuation', group: 'Stock', title: 'Stock valuation', period: 'asAt', location: true, item: true, needsCosts: true, source: 'rpc',
    blurb: 'Quantity and value of every item at each branch on a date, at weighted average cost, agreed to the inventory accounts.',
    cols: [c('item', 'Item'), c('sku', 'SKU', 'text', { pdf: false }), c('category', 'Category'), c('account', 'Account', 'text', { pdf: false }), c('location', 'Branch'),
      c('qty', 'Qty', 'qty'), c('unit', 'Unit'), c('unit_cost', 'Unit cost', 'money', { cost: true }), money('value', 'Value at cost', { cost: true }),
      c('price', 'Price', 'money'), money('retail_value', 'Retail value'), c('margin_pct', 'Margin %', 'pct', { cost: true })],
  },
  {
    id: 'movement_summary', group: 'Stock', title: 'Stock movement summary', period: 'range', location: true, item: true, needsCosts: true, source: 'rpc',
    blurb: 'Opening stock, receipts, sales at cost, transfers, adjustments and closing stock per item, in quantity and value. The stock reconciliation for the period.',
    cols: [c('item', 'Item'), c('category', 'Category', 'text', { pdf: false }), c('unit', 'Unit'),
      c('opening_qty', 'Opening qty', 'qty'), money('opening_value', 'Opening value'),
      c('added_qty', 'Opening stock added', 'qty', { pdf: false }), money('added_value', 'Added value', { pdf: false }),
      c('received_qty', 'Received', 'qty'), money('received_value', 'Received value'),
      c('sold_qty', 'Sold', 'qty'), money('cogs', 'Cost of sales'), money('revenue', 'Sales', { pdf: false }),
      c('transfer_in_qty', 'Transfers in', 'qty', { pdf: false }), money('transfer_in_value', 'Transfers in value', { pdf: false }),
      c('transfer_out_qty', 'Transfers out', 'qty', { pdf: false }), money('transfer_out_value', 'Transfers out value', { pdf: false }),
      c('adjust_qty', 'Adjusted', 'qty'), money('adjust_value', 'Adjustment value'), money('cost_adjust', 'Cost changes', { pdf: false }),
      c('closing_qty', 'Closing qty', 'qty'), money('closing_value', 'Closing value')],
  },
  {
    id: 'stock_card', group: 'Stock', title: 'Stock card (item ledger)', period: 'range', location: true, item: true, source: 'rpc',
    blurb: 'Every movement of an item with the running balance, the journal it posted to and who recorded it. Pick an item, or leave it on all items.',
    cols: [c('item', 'Item'), c('location', 'Branch'), c('date', 'Date', 'date'), c('type', 'Movement'), c('journal', 'Journal'), c('document', 'Document', 'text', { pdf: false }),
      c('qty_in', 'In', 'qty'), c('qty_out', 'Out', 'qty'), c('balance', 'Balance', 'qty'),
      c('unit_cost', 'Unit cost', 'money', { cost: true }), c('value_in', 'Value in', 'money', { cost: true, total: true }), c('value_out', 'Value out', 'money', { cost: true, total: true }),
      c('by', 'By'), c('channel', 'Channel', 'text', { pdf: false }), c('note', 'Note', 'text', { pdf: false })],
  },
  {
    id: 'batches', group: 'Stock', title: 'Batches & expiry', period: 'none', location: true, item: true, source: 'rpc',
    blurb: 'Every batch on hand or quarantined, with days to expiry. For NAFDAC records and first-expiry-first-out.',
    cols: [c('item', 'Item'), c('nafdac_no', 'NAFDAC no.'), c('batch_no', 'Batch'), c('location', 'Branch'), c('expiry_date', 'Expiry', 'date'), c('days_left', 'Days left', 'int'),
      c('qty_remaining', 'Qty left', 'qty'), c('unit', 'Unit'), money('value', 'Value', { cost: true }), c('status', 'Status')],
  },
  {
    id: 'reorder', group: 'Stock', title: 'Reorder list', period: 'none', source: 'reorder',
    blurb: 'Items at or near their reorder floor, with the suggested order and vendor. The same list as the Reorder page.',
    cols: [c('item', 'Item'), c('category', 'Category'), c('on_hand', 'On hand', 'qty'), c('floor', 'Floor', 'qty'), c('cover_days', 'Days cover', 'num'),
      c('order_qty', 'Order qty', 'qty'), c('order_unit', 'Order unit'), c('vendor', 'Vendor'), money('est_cost', 'Est. cost', { cost: true }), c('reason', 'Why', 'text', { pdf: false })],
  },
  {
    id: 'dead', group: 'Stock', title: 'Slow & dead stock', period: 'none', source: 'dead',
    blurb: 'Stock with no sale in 90 days or more, the cash tied up in it and a suggested markdown.',
    cols: [c('item', 'Item'), c('category', 'Category'), c('qty', 'On hand', 'qty'), c('unit', 'Unit'), c('days', 'Days unsold', 'int'),
      money('carrying', 'Value at cost', { cost: true }), c('price', 'Price', 'money'), c('markdown', 'Suggested price', 'money')],
  },
  {
    id: 'items', group: 'Stock', title: 'Item list', period: 'none', source: 'items',
    blurb: 'Your item master with every field, in the import template layout. Edit it in Excel and upload it again to update items in bulk.',
    cols: [c('name', 'Product name'), c('sku', 'SKU'), c('barcode', 'Barcode'), c('category', 'Category'), c('brand', 'Brand'), c('kind', 'Kind'),
      c('purchase_unit', 'Buy by'), c('pack_size', 'Per pack', 'int'), c('selling_unit', 'Sell by'), c('price', 'Price', 'money'), c('cost', 'Avg cost', 'money', { cost: true }),
      c('on_hand', 'On hand', 'qty'), money('value', 'Value', { cost: true }), c('vat', 'VAT'), c('reorder_floor', 'Floor', 'qty', { pdf: false })],
  },
  {
    id: 'gl', group: 'Books', title: 'Inventory general ledger', period: 'range', location: true, accounts: true, needsCosts: true, source: 'rpc',
    blurb: 'Every journal line on the chosen accounts with opening and running balances. Defaults to the inventory and goods-in-transit accounts.',
    cols: [c('account', 'Account'), c('account_name', 'Account name', 'text', { pdf: false }), c('date', 'Date', 'date'), c('journal', 'Journal'), c('memo', 'Description'),
      c('source', 'Source', 'text', { pdf: false }), c('location', 'Branch'), c('item', 'Item', 'text', { pdf: false }),
      money('debit', 'Debit'), money('credit', 'Credit'), c('balance', 'Balance (Dr +)', 'money')],
  },
  {
    id: 'journals', group: 'Books', title: 'Journal register', period: 'range', location: true, needsCosts: true, source: 'rpc',
    blurb: 'All journals Counta posted in the period, line by line, ready for the accountant or to load into TaxStreem.',
    cols: [c('date', 'Date', 'date'), c('journal', 'Journal'), c('memo', 'Memo'), c('source', 'Source', 'text', { pdf: false }), c('account', 'Account'), c('account_name', 'Account name'),
      money('debit', 'Debit'), money('credit', 'Credit'), c('location', 'Branch', 'text', { pdf: false }), c('item', 'Item', 'text', { pdf: false }),
      c('posted_by', 'Posted by', 'text', { pdf: false }), c('approved_by', 'Approved by', 'text', { pdf: false })],
  },
  {
    id: 'trial_balance', group: 'Books', title: 'Trial balance (Counta accounts)', period: 'range', location: true, needsCosts: true, source: 'rpc',
    blurb: 'Opening balance, movements and closing balance of every account Counta posts to.',
    cols: [c('account', 'Account'), c('account_name', 'Account name'), c('kind', 'Type'), c('opening', 'Opening', 'money'),
      money('debit', 'Debits'), money('credit', 'Credits'), money('closing_dr', 'Closing Dr'), money('closing_cr', 'Closing Cr')],
  },
  {
    id: 'purchases', group: 'Purchases', title: 'Purchases register', period: 'range', location: true, needsCosts: true, source: 'rpc',
    blurb: 'Every posted receipt: vendor, invoice, net, input VAT, gross and landed charges.',
    cols: [c('date', 'Posted', 'date'), c('invoice_date', 'Invoice date', 'date', { pdf: false }), c('ref', 'Receipt'), c('vendor', 'Vendor'), c('invoice_no', 'Invoice no.'),
      c('location', 'Branch'), c('source', 'Captured from', 'text', { pdf: false }), c('lines', 'Lines', 'int', { pdf: false }),
      money('net', 'Net'), money('vat', 'Input VAT'), money('gross', 'Gross'), money('landed', 'Landed charges', { pdf: false }), c('journal', 'Journal')],
  },
  {
    id: 'purchase_lines', group: 'Purchases', title: 'Purchases by line', period: 'range', location: true, item: true, needsCosts: true, source: 'rpc',
    blurb: 'Each line of each posted receipt, with quantity, unit cost, VAT treatment and batch.',
    cols: [c('date', 'Date', 'date'), c('ref', 'Receipt'), c('vendor', 'Vendor'), c('invoice_no', 'Invoice no.', 'text', { pdf: false }), c('item', 'Item'),
      c('qty', 'Qty', 'qty'), c('unit', 'Unit'), c('unit_cost', 'Unit cost', 'money'), money('line_total', 'Line total'),
      c('vat_treatment', 'VAT'), c('batch_no', 'Batch', 'text', { pdf: false }), c('expiry_date', 'Expiry', 'date', { pdf: false })],
  },
  {
    id: 'input_vat', group: 'Purchases', title: 'Input VAT schedule', period: 'range', location: true, needsCosts: true, source: 'rpc',
    blurb: 'Purchases from VAT-registered vendors with taxable value and VAT, for the monthly VAT return.',
    cols: [c('date', 'Date', 'date'), c('invoice_date', 'Invoice date', 'date'), c('vendor', 'Vendor'), c('invoice_no', 'Invoice no.'), c('ref', 'Receipt'),
      money('taxable', 'Taxable value'), money('non_taxable', 'Exempt / zero-rated'), money('vat', 'VAT 7.5%'), money('gross', 'Invoice total'), c('journal', 'Journal', 'text', { pdf: false })],
  },
  {
    id: 'vendors', group: 'Purchases', title: 'Purchases by vendor', period: 'range', location: true, needsCosts: true, source: 'rpc',
    blurb: 'What you bought from each vendor in the period.',
    cols: [c('vendor', 'Vendor'), c('receipts', 'Receipts', 'int', { total: true }), c('items', 'Items', 'int'), money('net', 'Net'), money('vat', 'Input VAT'), money('gross', 'Gross'),
      c('last_receipt', 'Last receipt', 'date'), c('lead_time_days', 'Lead time (days)', 'int', { pdf: false }), c('credit_days', 'Credit days', 'int', { pdf: false })],
  },
  {
    id: 'purchase_orders', group: 'Purchases', title: 'Purchase orders', period: 'range', location: true, needsCosts: true, source: 'rpc',
    blurb: 'Orders raised in the period with their status.',
    cols: [c('date', 'Date', 'date'), c('ref', 'PO'), c('vendor', 'Vendor'), c('location', 'Branch', 'text', { pdf: false }), c('status', 'Status'), c('sent_via', 'Sent via', 'text', { pdf: false }),
      c('received', 'Received', 'date'), c('lines', 'Lines'), money('total', 'Total')],
  },
  {
    id: 'sales_by_item', group: 'Sales', title: 'Sales by item', period: 'range', location: true, item: true, source: 'rpc',
    blurb: 'Quantity, sales value, cost of sales and gross profit for each item.',
    cols: [c('item', 'Item'), c('category', 'Category'), c('unit', 'Unit', 'text', { pdf: false }), c('sales', 'Sales', 'int', { total: true }), c('qty', 'Qty sold', 'qty', { total: true }),
      money('revenue', 'Sales value'), c('avg_price', 'Avg price', 'money', { pdf: false }), money('cogs', 'Cost of sales', { cost: true }),
      money('gross_profit', 'Gross profit', { cost: true }), c('margin_pct', 'Margin %', 'pct', { cost: true })],
  },
  {
    id: 'sales_by_day', group: 'Sales', title: 'Sales by day', period: 'range', location: true, item: true, source: 'rpc',
    blurb: 'Daily sales per branch, with voice entries and gross profit.',
    cols: [c('date', 'Date', 'date'), c('location', 'Branch'), c('sales', 'Sales', 'int', { total: true }), c('voice', 'By voice', 'int', { total: true }),
      c('qty', 'Qty', 'qty', { total: true }), money('revenue', 'Sales value'), money('cogs', 'Cost of sales', { cost: true }), money('gross_profit', 'Gross profit', { cost: true })],
  },
  {
    id: 'sales_by_staff', group: 'Sales', title: 'Sales by staff', period: 'range', location: true, item: true, source: 'rpc',
    blurb: 'Who recorded which sales, including voice entries and sales recorded offline.',
    cols: [c('person', 'Person'), c('role', 'Role'), c('sales', 'Sales', 'int', { total: true }), c('voice', 'By voice', 'int', { total: true }),
      c('offline', 'Offline', 'int', { total: true }), money('revenue', 'Sales value'), c('first', 'First', 'date'), c('last', 'Last', 'date')],
  },
  {
    id: 'adjustments', group: 'Controls', title: 'Stock adjustments & write-offs', period: 'range', location: true, item: true, source: 'rpc',
    blurb: 'Count variances, write-offs and quarantined batches, with the reason, counter and approver.',
    cols: [c('date', 'Date', 'date'), c('journal', 'Journal'), c('count', 'Count', 'text', { pdf: false }), c('type', 'Type'), c('item', 'Item'), c('location', 'Branch'),
      c('qty', 'Qty', 'qty'), c('unit', 'Unit', 'text', { pdf: false }), money('value', 'Value', { cost: true }), c('reason', 'Reason'), c('by', 'Counted by'), c('approved_by', 'Approved by')],
  },
  {
    id: 'transfers', group: 'Controls', title: 'Transfers register', period: 'range', location: true, item: true, source: 'rpc',
    blurb: 'Stock moved between branches, what is still in transit and who confirmed it.',
    cols: [c('date', 'Sent', 'date'), c('ref', 'Ref'), c('item', 'Item'), c('qty', 'Qty', 'qty'), c('unit', 'Unit'), c('from', 'From'), c('to', 'To'),
      c('status', 'Status'), c('received', 'Received', 'date'), money('value', 'Value', { cost: true }), c('sent_by', 'Sent by', 'text', { pdf: false }), c('received_by', 'Received by', 'text', { pdf: false })],
  },
  {
    id: 'price_changes', group: 'Controls', title: 'Price changes', period: 'range', item: true, source: 'rpc',
    blurb: 'Every selling price change with its reason and who made it.',
    cols: [c('date', 'Date', 'date'), c('item', 'Item'), c('sku', 'SKU', 'text', { pdf: false }), c('old_price', 'Old price', 'money'), c('new_price', 'New price', 'money'),
      c('change_pct', 'Change %', 'pct'), c('reason', 'Reason'), c('by', 'By')],
  },
  {
    id: 'cash_vs_stock', group: 'Controls', title: 'Cash vs stock', period: 'range', location: true, needsCosts: true, source: 'rpc',
    blurb: 'Sales implied by stock movements against the cash, POS and transfers recorded for each day.',
    cols: [c('date', 'Date', 'date'), c('location', 'Branch'), money('implied', 'Implied by stock'), money('cash', 'Cash'), money('pos', 'POS'), money('transfers', 'Transfers'),
      money('recorded', 'Recorded'), money('gap', 'Gap')],
  },
];

export const reportById = (id: string) => REPORTS.find((r) => r.id === id) || REPORTS[0];
export const GROUPS: Group[] = ['Stock', 'Books', 'Purchases', 'Sales', 'Controls'];

// The month-end pack: one workbook, one sheet per report.
export const PACK = ['valuation', 'movement_summary', 'gl', 'trial_balance', 'purchases', 'input_vat', 'sales_by_item', 'adjustments', 'transfers'];

// ---------- reports worked out in the browser ----------
export function clientRows(def: ReportDef, inv: Inventory, suggestions: Suggestion[]): Record<string, unknown>[] {
  const costs = inv.can_see_costs;
  if (def.source === 'reorder') {
    return suggestions.map((s) => ({
      item: s.item.name, category: s.item.category, on_hand: s.onHand, floor: s.floor, cover_days: Math.round(s.cover * 10) / 10,
      order_qty: s.qtyPU, order_unit: s.item.purchase_unit, vendor: s.vendor?.name || '', est_cost: costs ? s.cost : null, reason: s.reason,
    }));
  }
  if (def.source === 'dead') {
    return deadStock(buildItems(inv, 'ALL')).map((d) => ({
      item: d.item.name, category: d.item.category, qty: d.item.q, unit: d.item.selling_unit, days: d.days,
      carrying: costs ? d.carrying : null, price: d.item.price, markdown: d.mark,
    }));
  }
  const vat = { standard: 'Standard', zero: 'Zero-rated', exempt: 'Exempt' } as const;
  return buildItems(inv, 'ALL').map((i) => ({
    name: i.name, sku: i.sku, barcode: i.barcode, category: i.category, brand: i.brand || '', kind: typeLabel(i.item_type),
    purchase_unit: i.purchase_unit, pack_size: i.pack_size, selling_unit: i.selling_unit, price: Number(i.price) > 0 ? i.price : null,
    cost: costs ? i.wac : null, on_hand: i.qAll, value: costs && i.wac != null ? Math.round(i.qAll * i.wac * 100) / 100 : null,
    vat: vat[i.vat_treatment], reorder_floor: Number(i.reorder_floor),
  }));
}

// Attribute columns for the item list, from the business's industry plus anything already captured.
export function itemAttrCols(inv: Inventory): RCol[] {
  const fields = fieldsFor(inv.org.industry);
  const used = new Set(inv.items.flatMap((i) => Object.keys(i.attributes || {})));
  const keys = [...new Set([...fields.map((f) => f.key), ...used])];
  return keys.map((k) => ({ key: 'attr:' + k, label: ALL_FIELDS.find((f) => f.key === k)?.label || k, type: 'text' as ColType }));
}
export const attrValue = (row: Record<string, any>, key: string) => formatAttr(ALL_FIELDS.find((f) => f.key === key), row?.[key]);

// ---------- periods ----------
export type PresetId = 'this_month' | 'last_month' | 'this_quarter' | 'last_quarter' | 'ytd' | 'last_year' | 'last_30' | 'custom';
export const PRESETS: { id: PresetId; label: string }[] = [
  { id: 'this_month', label: 'This month' }, { id: 'last_month', label: 'Last month' }, { id: 'last_30', label: 'Last 30 days' },
  { id: 'this_quarter', label: 'This quarter' }, { id: 'last_quarter', label: 'Last quarter' }, { id: 'ytd', label: 'Year to date' },
  { id: 'last_year', label: 'Last year' }, { id: 'custom', label: 'Custom dates' },
];
const ymd = (y: number, m: number, d: number) => new Date(Date.UTC(y, m, d)).toISOString().slice(0, 10);
export function presetRange(id: PresetId, today: string): { from: string; to: string } {
  const [y, m] = today.split('-').map(Number); const mi = m - 1; const q = Math.floor(mi / 3);
  switch (id) {
    case 'last_month': return { from: ymd(y, mi - 1, 1), to: ymd(y, mi, 0) };
    case 'last_30': return { from: new Date(Date.parse(today + 'T00:00:00Z') - 29 * 86400_000).toISOString().slice(0, 10), to: today };
    case 'this_quarter': return { from: ymd(y, q * 3, 1), to: today };
    case 'last_quarter': return { from: ymd(y, q * 3 - 3, 1), to: ymd(y, q * 3, 0) };
    case 'ytd': return { from: ymd(y, 0, 1), to: today };
    case 'last_year': return { from: ymd(y - 1, 0, 1), to: ymd(y - 1, 11, 31) };
    default: return { from: ymd(y, mi, 1), to: today };
  }
}
