// The books' report catalogue: every report accounting_report() produces, with its columns and how to export it.
import type { ColType, RCol } from './reports';

export type APeriod = 'range' | 'asAt';
export type AGroup = 'Ledgers' | 'Statements' | 'Customers & vendors' | 'Analysis' | 'Tax';
export interface ADef {
  id: string; group: AGroup; title: string; blurb: string; period: APeriod; statement?: boolean; costs?: boolean;
  accounts?: boolean; by?: string[]; cols: (extra: Record<string, any>) => RCol[];
}
const c = (key: string, label: string, type: ColType = 'text', extra: Partial<RCol> = {}): RCol => ({ key, label, type, ...extra });
const m = (key: string, label: string, extra: Partial<RCol> = {}) => c(key, label, 'money', extra);
const stmt = (extra: Record<string, any>) => [c('line', 'Line'), c('note', 'Note', 'text', { width: 6 }),
  m('current', periodLabel(extra.from, extra.to, true)), m('prior', periodLabel(extra.prior_from, extra.prior_to, true))];

export function periodLabel(from?: string | null, to?: string | null, short = false): string {
  if (!to) return '';
  const f = (d: string) => new Date(d + 'T12:00:00Z').toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' });
  if (short) return f(to);
  return from ? `${f(from)} to ${f(to)}` : `As at ${f(to)}`;
}

export const AREPORTS: ADef[] = [
  { id: 'sofp', group: 'Statements', title: 'Statement of financial position', period: 'asAt', statement: true,
    blurb: 'Assets, liabilities and equity at a date, beside the end of the previous financial year (IAS 1, IAS 34). Casts before it is shown.', cols: stmt },
  { id: 'sopl', group: 'Statements', title: 'Statement of profit or loss', period: 'range', statement: true,
    blurb: 'Revenue, cost of sales, operating expenses, finance costs and tax for the period, by function (IAS 1).', cols: stmt },
  { id: 'soce', group: 'Statements', title: 'Statement of changes in equity', period: 'range', statement: true,
    blurb: 'Opening equity, profit, capital, dividends and other movements to closing equity.',
    cols: () => [c('component', 'Component'), m('opening', 'Opening'), m('profit', 'Profit'), m('oci', 'Other comprehensive income'), m('capital', 'Capital'), m('dividends', 'Dividends'), m('other', 'Other'), m('closing', 'Closing')] },
  { id: 'cash_flow', group: 'Statements', title: 'Statement of cash flows', period: 'range', statement: true,
    blurb: 'Operating, investing and financing cash flows (IAS 7, indirect method), tied to the cash in the books.', cols: stmt },
  { id: 'notes', group: 'Statements', title: 'Notes to the financial statements', period: 'range', statement: true,
    blurb: 'Accounting policies and the notes behind each line: revenue, expenses, PPE, inventories, receivables, payables, tax, equity.',
    // Income notes compare with the same period last year; balance notes with the end of last financial year (note 2 says which).
    cols: (extra) => [c('line', 'Line'), c('note', 'Note', 'text', { width: 6 }), m('current', periodLabel(extra.from, extra.to, true)), m('prior', 'Comparative')] },
  { id: 'trial_balance', group: 'Ledgers', title: 'Trial balance', period: 'range',
    blurb: 'Opening, movement and closing balance of every account. Debits equal credits.',
    cols: () => [c('code', 'Code', 'text', { width: 10 }), c('name', 'Account'), c('ifrs_line', 'Statement line', 'text', { pdf: false }), m('opening', 'Opening'), m('debit', 'Debit', { total: true }), m('credit', 'Credit', { total: true }), m('closing_dr', 'Closing debit', { total: true }), m('closing_cr', 'Closing credit', { total: true })] },
  { id: 'gl', group: 'Ledgers', title: 'General ledger', period: 'range', accounts: true,
    blurb: 'Every line on each account with the opening and running balance. Pick accounts or leave it on all.',
    cols: () => [c('account', 'Account', 'text', { pdf: false }), c('date', 'Date', 'date'), c('ref', 'Journal', 'text', { width: 10 }), c('memo', 'Description'), c('party', 'Customer or vendor'), c('source', 'Source', 'text', { pdf: false }), m('debit', 'Debit'), m('credit', 'Credit'), m('balance', 'Balance')] },
  { id: 'journals', group: 'Ledgers', title: 'Journal register', period: 'range',
    blurb: 'Every journal line in the period: who posted it, who approved it, whether the AI did and how sure it was.',
    cols: () => [c('date', 'Date', 'date'), c('ref', 'Journal', 'text', { width: 10 }), c('memo', 'Description'), c('code', 'Code', 'text', { width: 10 }), c('account_name', 'Account'), c('party', 'Party', 'text', { pdf: false }), m('debit', 'Debit', { total: true }), m('credit', 'Credit', { total: true }), c('source', 'Source', 'text', { pdf: false }), c('origin', 'Origin', 'text', { pdf: false }), c('ai_confidence', 'AI confidence', 'num', { pdf: false }), c('posted_by', 'Posted by'), c('approved_by', 'Approved by', 'text', { pdf: false }), c('reversal_of', 'Reverses', 'text', { pdf: false })] },
  { id: 'coa', group: 'Ledgers', title: 'Chart of accounts', period: 'asAt',
    blurb: 'Every account with where it lands in the statements, its normal balance and its balance at the date.',
    cols: () => [c('code', 'Code', 'text', { width: 10 }), c('name', 'Account'), c('category', 'Category'), c('ifrs_line', 'Statement line'), c('statement', 'Statement', 'text', { pdf: false }), c('normal_balance', 'Normal balance', 'text', { pdf: false }), c('cash_flow', 'Cash flow class', 'text', { pdf: false }), m('balance', 'Balance')] },
  { id: 'fixed_assets', group: 'Ledgers', title: 'Fixed asset register', period: 'range',
    blurb: 'Cost, depreciation for the period, accumulated depreciation and carrying amount of every asset.',
    cols: () => [c('number', 'Asset', 'text', { width: 10 }), c('name', 'Description'), c('class', 'Class'), c('location', 'Branch', 'text', { pdf: false }), c('serial_no', 'Serial', 'text', { pdf: false }), c('available_date', 'In use from', 'date'), c('life_months', 'Life (months)', 'int'), m('cost', 'Cost', { total: true }), m('charge_period', 'Depreciation in period', { total: true }), m('accumulated', 'Accumulated', { total: true }), m('carrying_amount', 'Carrying amount', { total: true }), c('status', 'Status'), c('disposed_at', 'Disposed', 'date', { pdf: false }), m('proceeds', 'Proceeds', { pdf: false })] },
  { id: 'ar_ledger', group: 'Customers & vendors', title: 'Customer ledger (receivables)', period: 'range',
    blurb: 'Opening, invoiced, received and closing balance per customer, agreed to the receivables account.',
    cols: () => [c('party', 'Customer'), m('opening', 'Opening', { total: true }), m('debit', 'Invoiced', { total: true }), m('credit', 'Received and credited', { total: true }), m('closing', 'Closing', { total: true })] },
  { id: 'ap_ledger', group: 'Customers & vendors', title: 'Vendor ledger (payables)', period: 'range',
    blurb: 'Opening, billed, paid and closing balance per vendor, agreed to the payables account.',
    cols: () => [c('party', 'Vendor'), m('opening', 'Opening', { total: true }), m('debit', 'Paid', { total: true }), m('credit', 'Billed', { total: true }), m('closing', 'Closing', { total: true })] },
  { id: 'ar_aging', group: 'Customers & vendors', title: 'Receivables ageing', period: 'asAt',
    blurb: 'What each customer owes by how late it is, from due dates.',
    cols: () => [c('party', 'Customer'), m('current', 'Not yet due', { total: true }), m('d1_30', '1-30 days', { total: true }), m('d31_60', '31-60 days', { total: true }), m('d61_90', '61-90 days', { total: true }), m('d90_plus', 'Over 90 days', { total: true }), m('total', 'Total', { total: true }), m('credit_limit', 'Credit limit', { pdf: false })] },
  { id: 'ap_aging', group: 'Customers & vendors', title: 'Payables ageing', period: 'asAt',
    blurb: 'What the business owes each vendor by how late it is.',
    cols: () => [c('party', 'Vendor'), m('current', 'Not yet due', { total: true }), m('d1_30', '1-30 days', { total: true }), m('d31_60', '31-60 days', { total: true }), m('d61_90', '61-90 days', { total: true }), m('d90_plus', 'Over 90 days', { total: true }), m('total', 'Total', { total: true })] },
  { id: 'management_accounts', group: 'Analysis', title: 'Management accounts by month', period: 'range',
    blurb: 'Every income and expense account month by month, for the board pack.',
    cols: (x) => [c('code', 'Code', 'text', { width: 10 }), c('account', 'Account'), c('ifrs_line', 'Line', 'text', { pdf: false }),
      ...((x.columns || []) as { key: string; label: string }[]).map((k) => m(k.key, k.label, { total: true })), m('total', 'Total', { total: true })] },
  { id: 'ratios', group: 'Analysis', title: 'Financial ratios', period: 'range',
    blurb: 'Liquidity, efficiency, profitability and leverage, with the formula and how to read each.',
    cols: () => [c('group', 'Group'), c('ratio', 'Ratio'), c('current', 'This period', 'num'), c('prior', 'Last year', 'num'), c('unit', 'Unit', 'text', { width: 6 }), c('formula', 'Formula', 'text', { pdf: false }), c('reading', 'How to read it')] },
  { id: 'trends', group: 'Analysis', title: 'Twelve-month trends', period: 'asAt',
    blurb: 'Revenue, gross profit, margin, expenses, profit, cash, receivables, payables and stock, month by month.',
    cols: () => [c('month', 'Month'), m('revenue', 'Revenue'), m('gross_profit', 'Gross profit'), c('gross_margin', 'Margin %', 'pct'), m('opex', 'Expenses'), m('profit', 'Profit'), m('cash', 'Cash'), m('receivables', 'Receivables'), m('payables', 'Payables'), m('inventories', 'Stock')] },
  { id: 'budget_vs_actual', group: 'Analysis', title: 'Budget against actual', period: 'range',
    blurb: 'Each account against its budget for the period, with the variance.',
    cols: () => [c('code', 'Code', 'text', { width: 10 }), c('account', 'Account'), m('budget', 'Budget', { total: true }), m('actual', 'Actual', { total: true }), m('variance', 'Variance', { total: true }), c('variance_pct', 'Variance %', 'pct')] },
  { id: 'cash_forecast', group: 'Analysis', title: '13-week cash forecast', period: 'asAt',
    blurb: 'Cash week by week from what customers owe, bills due, VAT and the usual run of other receipts and payments.',
    cols: () => [c('week', 'Week', 'int', { width: 6 }), c('from', 'From', 'date'), c('to', 'To', 'date'), m('opening', 'Opening'), m('customers', 'From customers'), m('other_receipts', 'Other receipts'), m('bills', 'Bills'), m('vat', 'VAT'), m('other_payments', 'Other payments'), m('closing', 'Closing')] },
  { id: 'sales_analysis', group: 'Analysis', title: 'Sales analysis', period: 'range', by: ['item', 'customer', 'channel', 'branch', 'cashier', 'month', 'day', 'vat_status'],
    blurb: 'Sales, VAT, cost and margin by item, customer, channel, branch, cashier, month, day or VAT status (0 VATable, 1 exempt, 2 zero-rated).',
    cols: () => [c('key', 'Name'), c('documents', 'Documents', 'int'), c('qty', 'Quantity', 'qty'), m('net', 'Net sales', { total: true }), m('vat', 'VAT', { total: true }), m('gross', 'Gross', { total: true }), m('cost', 'Cost', { total: true, cost: true }), m('margin', 'Margin', { total: true, cost: true }), c('margin_pct', 'Margin %', 'pct', { cost: true })] },
  { id: 'vat_return', group: 'Tax', title: 'VAT return', period: 'range', statement: true,
    blurb: 'Output VAT, input VAT and the amount to pay for the month, agreed to the ledger. Due by the 21st of the next month.',
    cols: (x) => [c('line', 'Line'), m('current', periodLabel(x.from, x.to))] },
  { id: 'wht_schedule', group: 'Tax', title: 'Withholding tax schedule', period: 'range',
    blurb: 'WHT deducted from vendors (to pay to NRS) and WHT credit notes received from customers.',
    cols: () => [c('date', 'Date', 'date'), c('kind', 'Kind'), c('party', 'Party'), c('tin', 'Tax ID'), c('category', 'Category', 'text', { pdf: false }), c('document', 'Document'), m('base', 'Base', { total: true }), c('rate', 'Rate', 'pct'), m('wht', 'WHT', { total: true })] },
];
export const areport = (id: string) => AREPORTS.find((r) => r.id === id)!;

// Rates arrive as fractions (0.05); the pct column shows 5.0%.
export function prepRows(def: ADef, rows: Record<string, any>[]) {
  if (def.id === 'wht_schedule') return rows.map((r) => ({ ...r, rate: r.rate == null ? null : Number(r.rate) * 100 }));
  return rows;
}
