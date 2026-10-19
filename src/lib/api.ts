// Reads and calls for selling, payments, payables and the books (Atlas).
import { useQuery } from '@tanstack/react-query';
import { cleanError, rpc, supabase } from './supabase';
import { useSession } from '../state/session';
import { vatPct } from './vat';

// ---------------------------------------------------------------- edge functions
export async function edge<T = any>(name: string, body: Record<string, unknown>): Promise<T & { ok?: boolean; reason?: string; error?: string }> {
  const { data, error } = await supabase.functions.invoke(name, { body });
  if (error) {
    let b: any = null;
    try { b = await (error as any).context?.json?.(); } catch { /* not json */ }
    if (b) return b;
    return { ok: false, reason: 'error', error: cleanError(error) } as any;
  }
  return data as any;
}
// Throws when the function says it did not work, so callers can use useAction().
export async function edgeOk<T = any>(name: string, body: Record<string, unknown>): Promise<T> {
  const r = await edge<T>(name, body);
  if (r && (r as any).ok === false) throw new Error((r as any).error || 'Something went wrong.');
  return r as T;
}

// ---------------------------------------------------------------- types
export type DocType = 'receipt' | 'invoice' | 'quote' | 'order' | 'credit_note';
export interface SaleRow {
  id: string; number: string; doc_type: DocType; status: string; customer_id: string | null; customer_name: string | null; total: number; balance: number;
  amount_paid: number; credited: number; vat_total: number; subtotal: number; issue_date: string; due_date: string | null; channel: string; created_at: string;
  overdue_days: number; pending: number; confirmed: boolean; public_token: string; sent_at: string | null; viewed_at: string | null; location_id: string | null;
  cost_total?: number; created_by_name?: string; shift_id?: string | null; reference?: string | null;
  export?: boolean; customer_country?: string | null; pay_later?: boolean; vat_statuses?: number[];
}
export interface SaleLine {
  id: string; item_id: string | null; description: string; kind: 'goods' | 'service' | 'delivery'; qty: number; unit_label: string; unit_price: number; list_price: number | null;
  discount: number; vat_treatment: string; vat_rate: number; net: number; vat: number; gross: number; cost?: number | null; returned_qty: number; revenue_account?: string;
  vat_status?: 0 | 1 | 2; item_vat_treatment?: string | null;
}
// VAT status codes as the NRS schedules use them.
export const VAT_STATUS: Record<number, { label: string; short: string; tone: string }> = {
  0: { label: 'VATable', get short() { return `VATable ${vatPct()}`; }, tone: 't-blue' }, 1: { label: 'Exempt', short: 'Exempt', tone: 't-grey' }, 2: { label: 'Zero-rated', short: 'Zero-rated', tone: 't-green' },
};
export const vatStatusOf = (treatment?: string | null): 0 | 1 | 2 => (treatment === 'exempt' ? 1 : treatment === 'zero' ? 2 : 0);
export interface Sale extends SaleRow {
  lines: SaleLine[]; payments: any[]; refunds: any[]; credits: any[]; applied_to: any[]; credit_notes: any[]; requests: PayRequest[]; deliveries: any[];
  org: Record<string, any>; customer: Record<string, any> | null; customer_phone: string | null; customer_email: string | null; customer_credit?: number;
  prices_include_vat: boolean; vat_registered: boolean; notes: string | null; terms: string | null; delivery_method: string | null; delivery_address: string | null;
  delivery_fee?: number; discount_total?: number; export_note?: string | null; journal_ref?: string | null; journal_id?: string | null; location_name?: string | null; original_sale_id?: string | null; converted_to?: string | null; change?: number;
}
export interface PayRequest {
  id: string; tx_ref?: string; method: 'account' | 'link' | 'qr'; rail?: string; amount: number; status: string; account_number: string | null; bank_name: string | null;
  account_name: string | null; link_url: string | null; qr_image: string | null; expires_at: string | null; paid_amount?: number | null; paid_at?: string | null;
  error?: string | null; sale_id?: string | null; sale_number?: string | null; sale_status?: string | null; payer?: string | null; customer_name?: string | null; created_at?: string;
  created_by_name?: string; sweep_status?: string | null; fee?: number | null;
}
export interface Customer {
  id: string; name: string; kind: string; phone: string | null; email: string | null; address: string | null; tin: string | null; is_walk_in: boolean; archived: boolean;
  credit_limit: number; terms_days: number; price_list_id: string | null; price_list_name: string | null; balance: number; receivable: number; advance: number;
  overdue: number; oldest_due: string | null; open_count: number; sales_12m: number; last_sale: string | null; whatsapp_opt_in: boolean; tags: string[]; notes: string | null;
  credit_notes: number; city?: string | null; state?: string | null; country?: string | null; contact_person?: string | null; cc_emails?: string[];
}
export interface PriceList { id: string; name: string; kind: 'wholesale' | 'distributor' | 'custom' | 'staff'; rule: 'fixed' | 'discount_on_retail' | 'markup_on_cost'; pct: number; active?: boolean; items: { item_id: string; price: number; min_qty: number }[] }
export interface Shift {
  id: string; number: string; status: 'open' | 'closed'; location_id: string; location_name: string; register: string; cash_account_id: string; cash_account_name: string;
  opened_at: string; opened_by: string; opened_by_name: string; closed_at: string | null; closed_by_name: string | null; opening_count: number; opening_expected: number;
  counted_cash: number | null; expected_cash: number | null; difference: number | null; sales_count: number; sales_total: number; credit_sales: number; voids: number;
  by_method: Record<string, number>; movements: any[]; cash_balance: number; notes: string | null;
}
export interface BankAccountLite { id: string; kind: 'bank' | 'cash' | 'wallet' | 'card' | 'clearing'; name: string; bank_name: string | null; account_number: string | null; account_name: string | null; location_id: string | null; provider?: string }
export interface Till { shift: Shift | null; accounts: BankAccountLite[]; settings: Record<string, any>; price_lists: PriceList[] }
export interface Bill {
  id: string; number: string; vendor_id: string; vendor_name: string; vendor_ref: string | null; source: string; bill_date: string; due_date: string; status: string;
  subtotal: number; vat_total: number; total: number; wht_expected: number; amount_paid: number; balance: number; in_progress: number; overdue_days: number | null;
  created_at: string; ai_confidence: number | null;
}
export interface Report { rows: Record<string, any>[]; extra: Record<string, any> }
export interface AiProposal {
  id: string; agent: string; kind: string; title: string; question: string | null; proposal: Record<string, any>; confidence: number; rationale: string | null;
  stage: string | null; status: string; amount: number | null; created_at: string; source_type: string; source_id: string | null; journal_id?: string | null;
  line?: Record<string, any> | null; model?: string | null; account_name?: string | null; journal_ref?: string | null;
}

// ---------------------------------------------------------------- reads
// keep: while a new period loads, the figures already on screen stay (for the same business).
function useOrgQuery<T>(key: unknown[], fn: (org: string) => Promise<T>, enabled = true, refetchInterval?: number, keep = false) {
  const { orgId } = useSession();
  return useQuery<T>({ queryKey: [...key, orgId], enabled: !!orgId && enabled, queryFn: () => fn(orgId!), refetchInterval,
    ...(keep ? { placeholderData: ((prev: T | undefined, q: any) => (q?.queryKey?.[q.queryKey.length - 1] === orgId ? prev : undefined)) as any } : {}) });
}
export const useTill = (loc: string | null) => useOrgQuery<Till>(['till', loc], (o) => rpc('get_till', { p_org: o, p_location: loc }), !!loc);
export const useSales = (filter: Record<string, unknown>) => useOrgQuery<{ rows: SaleRow[]; pending_payments: any[]; orders_waiting: number }>(['sales', JSON.stringify(filter)], (o) => rpc('get_sales', { p_org: o, p_filter: filter }));
export const useSale = (id: string | null) => useQuery({ queryKey: ['sale', id], enabled: !!id, queryFn: () => rpc<Sale>('get_sale', { p_sale: id }) });
export const useCustomers = () => useOrgQuery<{ customers: Customer[]; price_lists: PriceList[] }>(['customers'], (o) => rpc('get_customers', { p_org: o }));
export const useShifts = (days = 14) => useOrgQuery<Shift[]>(['shifts', days], (o) => rpc('get_shifts', { p_org: o, p_days: days }));
export const useDeliveries = (days = 30) => useOrgQuery<any[]>(['deliveries', days], (o) => rpc('get_deliveries', { p_org: o, p_days: days }));
export const usePayments = (enabled = true, period?: { from: string; to: string } | null) => useOrgQuery<any>(['payments', period?.from || null, period?.to || null],
  (o) => rpc('get_payments', period ? { p_org: o, p_filter: { from: period.from, to: period.to } } : { p_org: o }), enabled, undefined, true);
export const useBills = (filter: Record<string, unknown> = {}, enabled = true) => useOrgQuery<{ bills: Bill[]; vendors: any[]; [k: string]: any }>(['bills', JSON.stringify(filter)], (o) => rpc('get_bills', { p_org: o, p_filter: filter }), enabled);
export const useBill = (id: string | null) => useQuery({ queryKey: ['bill', id], enabled: !!id, queryFn: () => rpc<any>('get_bill', { p_bill: id }) });
export const useBanking = (enabled = true, period?: { from: string; to: string } | null) => useOrgQuery<any>(['banking', period?.from || null, period?.to || null],
  (o) => rpc('get_banking', period ? { p_org: o, p_filter: { from: period.from, to: period.to } } : { p_org: o }), enabled, undefined, true);
export const useInbox = (enabled = true) => useOrgQuery<any>(['inbox'], (o) => rpc('get_books_inbox', { p_org: o }), enabled, 60_000);
export const useAssets = (enabled = true) => useOrgQuery<any>(['assets'], (o) => rpc('get_assets', { p_org: o }), enabled);
// Home's figures for a period (this month when none is given) and the balances at its end.
export const useOverview = (enabled = true, from?: string | null, to?: string | null) => useOrgQuery<any>(['overview', from || null, to || null],
  (o) => rpc('get_finance_overview', from || to ? { p_org: o, p_from: from || null, p_to: to || null } : { p_org: o }), enabled, undefined, true);
export const useMessages = (sale: string | null = null) => useOrgQuery<any>(['messages', sale], (o) => rpc('get_messages', { p_org: o, p_sale: sale }));
export const useChart = (enabled = true) => useOrgQuery<any>(['chart'], (o) => rpc('get_chart', { p_org: o }), enabled);
export function useReport(report: string, from: string | null, to: string | null, options: Record<string, unknown> = {}, enabled = true) {
  return useOrgQuery<Report>(['report', report, from, to, JSON.stringify(options)],
    (o) => rpc('accounting_report', { p_org: o, p_report: report, p_from: from, p_to: to, p_options: options }), enabled);
}
export const useChecklist = (end: string | null) => useOrgQuery<any>(['checklist', end], (o) => rpc('close_checklist', { p_org: o, p_period_end: end }), !!end);

// ---------------------------------------------------------------- helpers
export const DOC_LABEL: Record<DocType, string> = { receipt: 'Receipt', invoice: 'Invoice', quote: 'Quote', order: 'Order', credit_note: 'Credit note' };
export const STATUS_TONE: Record<string, string> = {
  paid: 't-green', open: 't-blue', partially_paid: 't-amber', pending: 't-amber', draft: 't-grey', void: 't-grey', cancelled: 't-grey', converted: 't-purple',
  expired: 't-grey', credited: 't-purple', approved: 't-blue', processing: 't-amber', successful: 't-green', failed: 't-red', reversed: 't-red',
  pending_approval: 't-amber', confirmed: 't-green', rejected: 't-red', creating: 't-grey', active: 't-green', closed: 't-grey',
  sending: 't-amber', completed: 't-green', partly_failed: 't-red', returned: 't-red',
};
export const statusLabel = (s: string) => s.replace(/_/g, ' ').replace(/^\w/, (c) => c.toUpperCase());
export const METHOD_LABEL: Record<string, string> = {
  cash: 'Cash', transfer: 'Bank transfer', card: 'Card', pos: 'POS', flutterwave: 'Pay by transfer', rail: 'Pay by transfer', cheque: 'Cheque', wht_credit: 'WHT credit note',
  advance: 'Customer credit', other: 'Other', account: 'Pay by transfer', link: 'Payment link', qr: 'QR code', credit: 'On account',
};
export function money(v: string | number | null | undefined): number | null {
  if (v == null || v === '') return null;
  const n = Number(String(v).replace(/[₦,\s]/g, ''));
  return Number.isFinite(n) ? Math.round(n * 100) / 100 : null;
}
export const today = () => new Date().toLocaleDateString('en-CA', { timeZone: 'Africa/Lagos' });
export const monthStart = (d = today()) => d.slice(0, 8) + '01';
export const yearStart = (d = today(), fyStart = 1) => {
  const y = Number(d.slice(0, 4)), m = Number(d.slice(5, 7));
  const start = m >= fyStart ? y : y - 1;
  return `${start}-${String(fyStart).padStart(2, '0')}-01`;
};
export const lastMonthEnd = (d = today()) => { const x = new Date(d.slice(0, 8) + '01T12:00:00Z'); x.setUTCDate(0); return x.toISOString().slice(0, 10); };

// The business's cash drawers, bank accounts and wallets, for choosing where money goes or comes from. Unlike the till,
// this answers anyone who handles money (an accountant or a manager who does not sell).
export const moneyAccounts = (orgId: string) => rpc<any[]>('money_accounts', { p_org: orgId });
