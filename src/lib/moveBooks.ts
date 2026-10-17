// Moving the books from QuickBooks, Zoho Books, Xero or Sage: where each report lives in the old system, and how
// their columns read. Menu names change a little between versions; any Excel or CSV export of the same report works.
import type { SheetField } from '../components/SheetRows';
import { parseDate, parseNum, cellText, type Cell } from './sheet';
import { COUNTRIES } from './countries';

export type BooksSource = 'quickbooks' | 'zoho' | 'xero' | 'sage' | 'other';
export interface BooksGuide { id: BooksSource; name: string; tb: string; ar: string; ap: string; customers: string; suppliers: string; items: string; tip?: string }

export const BOOK_SYSTEMS: BooksGuide[] = [
  {
    id: 'quickbooks', name: 'QuickBooks',
    tb: 'Reports → search "Trial Balance" → Report period: Custom, From the first day of your financial year To the cut-over date → Run report → the export icon → Export to Excel. In QuickBooks Desktop: Reports → Accountant & Taxes → Trial Balance → Excel.',
    ar: 'Reports → "A/R Ageing Detail" → Report date: the cut-over date → Run report → Export to Excel. It lists each unpaid invoice with its open balance.',
    ap: 'Reports → "A/P Ageing Detail" → Report date: the cut-over date → Run report → Export to Excel.',
    customers: 'Sales → Customers → the export icon above the list (Export to Excel).',
    suppliers: 'Expenses → Suppliers (or Vendors) → the export icon above the list.',
    items: 'Sales → Products and services → the export icon. For stock, run Inventory Valuation Summary as at the cut-over date.',
    tip: 'QuickBooks puts the account number in front of the name when account numbers are switched on ("1010 Bank"). Counta reads it either way.',
  },
  {
    id: 'xero', name: 'Xero',
    tb: 'Accounting → Reports → Trial Balance → Date: the cut-over date → Update → Export → Excel.',
    ar: 'Accounting → Reports → Aged Receivables Detail → Date: the cut-over date → Update → Export → Excel.',
    ap: 'Accounting → Reports → Aged Payables Detail → Date: the cut-over date → Update → Export → Excel.',
    customers: 'Contacts → Customers → Export (the CSV has name, email, phone, address and tax number).',
    suppliers: 'Contacts → Suppliers → Export.',
    items: 'Accounting → Products and services → Export. Tracked inventory shows quantity on hand and average cost.',
    tip: 'Xero\'s Trial Balance can carry more than one pair of Debit and Credit columns. Pick the pair that shows each account\'s balance at the cut-over date; Counta checks that the two sides agree.',
  },
  {
    id: 'zoho', name: 'Zoho Books',
    tb: 'Reports → Accountant → Trial Balance → Date range ending on the cut-over date → Run report → Export → XLSX.',
    ar: 'Reports → Receivables → AR Aging Details → As of: the cut-over date → Export. (Or Invoice Details filtered to unpaid and overdue.)',
    ap: 'Reports → Payables → AP Aging Details → As of: the cut-over date → Export.',
    customers: 'Sales → Customers → the menu beside New → Export Customers.',
    suppliers: 'Purchases → Vendors → the menu → Export Vendors.',
    items: 'Items → the menu → Export Items. Stock on hand is in Inventory Valuation Summary.',
  },
  {
    id: 'sage', name: 'Sage',
    tb: 'Sage Business Cloud Accounting: Reporting → Trial Balance → To date: the cut-over date → Run → Export CSV. Sage 50: Nominal → Reports → Trial Balance → Preview → export to Excel.',
    ar: 'Reporting → Aged Debtors (detailed) at the cut-over date → Export. Sage 50: Customers → Reports → Aged Debtors Analysis (Detailed).',
    ap: 'Reporting → Aged Creditors (detailed) at the cut-over date → Export. Sage 50: Suppliers → Reports → Aged Creditors Analysis (Detailed).',
    customers: 'Contacts → Customers → Export. Sage 50: Customers → Customer List → Export.',
    suppliers: 'Contacts → Suppliers → Export.',
    items: 'Products & Services → Export, or Stock Valuation at the cut-over date.',
  },
  {
    id: 'other', name: 'Another system or a spreadsheet',
    tb: 'Any trial balance at the cut-over date with each account\'s name and its debit and credit (or one balance column, debit positive). Codes are optional.',
    ar: 'A list of unpaid customer invoices at the cut-over date: customer, invoice number, date, due date and the amount still unpaid.',
    ap: 'A list of unpaid supplier bills at the cut-over date: supplier, bill number, date, due date and the amount still unpaid.',
    customers: 'A list of customers with name, phone, email, address and tax ID.',
    suppliers: 'A list of suppliers with name, phone, email, address and tax ID.',
    items: 'A list of items with cost, price and quantity on hand.',
  },
];
export const bookSystem = (id?: string | null) => BOOK_SYSTEMS.find((s) => s.id === id) || BOOK_SYSTEMS[BOOK_SYSTEMS.length - 1];

export const TB_FIELDS: SheetField[] = [
  { key: 'code', label: 'Account code', syn: ['account code', 'code', 'account no', 'account number', 'acc no', 'no', 'number', 'nominal code', 'gl code', 'ref'] },
  { key: 'name', label: 'Account name', required: true, syn: ['account name', 'account', 'name', 'description', 'nominal name', 'ledger', 'particulars', 'account description'] },
  { key: 'type', label: 'Account type', syn: ['account type', 'type', 'class', 'category', 'group', 'account class'] },
  { key: 'debit', label: 'Debit', syn: ['debit', 'dr', 'debits', 'debit balance', 'ytd debit', 'debit ngn'] },
  { key: 'credit', label: 'Credit', syn: ['credit', 'cr', 'credits', 'credit balance', 'ytd credit', 'credit ngn'] },
  { key: 'balance', label: 'Balance (debit positive)', syn: ['balance', 'net', 'amount', 'closing balance', 'net balance', 'total'] },
];
export const OPEN_FIELDS = (kind: 'invoice' | 'bill'): SheetField[] => [
  { key: 'party', label: kind === 'invoice' ? 'Customer' : 'Supplier', required: true,
    syn: kind === 'invoice' ? ['customer', 'customer name', 'name', 'contact', 'client', 'debtor', 'account name', 'customer full name'] : ['supplier', 'vendor', 'vendor name', 'supplier name', 'name', 'contact', 'creditor', 'payee'] },
  { key: 'number', label: kind === 'invoice' ? 'Invoice number' : 'Bill number', syn: ['num', 'number', 'invoice number', 'invoice no', 'invoice', 'bill number', 'bill no', 'reference', 'ref', 'transaction no', 'document no', 'doc no', 'no'] },
  { key: 'issue_date', label: 'Date', syn: ['date', 'invoice date', 'bill date', 'transaction date', 'txn date', 'document date'] },
  { key: 'due_date', label: 'Due date', syn: ['due date', 'due', 'payment due'] },
  { key: 'amount', label: 'Amount unpaid', required: true, syn: ['open balance', 'balance due', 'amount due', 'balance', 'outstanding', 'due amount', 'open amount', 'total outstanding', 'unpaid', 'amount'] },
];
export const CUSTOMER_FIELDS: SheetField[] = [
  { key: 'name', label: 'Name', required: true, syn: ['customer', 'customer name', 'name', 'display name', 'contact name', 'company name', 'company', 'client'] },
  { key: 'phone', label: 'Phone', syn: ['phone', 'mobile', 'phone number', 'telephone', 'work phone', 'mobile phone'] },
  { key: 'email', label: 'Email', syn: ['email', 'email address', 'e mail'] },
  { key: 'tin', label: 'Tax ID', syn: ['tin', 'tax id', 'tax number', 'tax registration number', 'vat number', 'tax identification number', 'trn'] },
  { key: 'address', label: 'Street address', syn: ['billing address', 'address', 'street', 'billing street', 'address line 1', 'postal address', 'sa address line 1', 'pobox'] },
  { key: 'city', label: 'City', syn: ['city', 'billing city', 'town', 'sa city'] },
  { key: 'state', label: 'State', syn: ['state', 'billing state', 'region', 'province', 'sa region'] },
  { key: 'country', label: 'Country', syn: ['country', 'billing country', 'sa country'] },
  { key: 'contact_person', label: 'Contact person', syn: ['contact person', 'attention', 'contact', 'first name', 'primary contact'] },
];

const text = (c: Cell | undefined) => cellText(c ?? null).trim();
export function tbRows(rows: Record<string, Cell>[]) {
  return rows.map((r) => {
    const out: Record<string, unknown> = { code: text(r.code) || null, name: text(r.name), type: text(r.type) || null };
    if (r.debit !== undefined || r.credit !== undefined) { out.debit = parseNum(r.debit ?? null) ?? 0; out.credit = parseNum(r.credit ?? null) ?? 0; }
    if (r.balance !== undefined && !(Number(out.debit) || Number(out.credit))) { out.balance = parseNum(r.balance ?? null) ?? 0; delete out.debit; delete out.credit; }
    return out;
  }).filter((r) => r.name);
}
export function openRows(rows: Record<string, Cell>[]) {
  return rows.map((r) => ({ party: text(r.party), number: text(r.number) || null, issue_date: parseDate(r.issue_date ?? null), due_date: parseDate(r.due_date ?? null),
    amount: parseNum(r.amount ?? null) ?? 0 })).filter((r) => r.party && r.amount > 0);
}
export function countryCode(v: string): string | null {
  const s = v.trim();
  if (!s) return null;
  if (/^[A-Za-z]{2}$/.test(s)) return s.toUpperCase();
  const hit = COUNTRIES.find((c) => c.name.toLowerCase() === s.toLowerCase());
  return hit ? hit.code : null;
}
export function customerRows(rows: Record<string, Cell>[]) {
  return rows.map((r) => {
    const o: Record<string, unknown> = {};
    for (const k of ['name', 'phone', 'email', 'tin', 'address', 'city', 'state', 'contact_person']) { const v = text(r[k]); if (v) o[k] = v; }
    const cc = countryCode(text(r.country)); if (cc) o.country = cc;
    return o;
  }).filter((o) => o.name);
}
