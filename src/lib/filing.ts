// Filing-only: a business that wants only its yearly income tax return. Each year has a one-time fee, worked out from the
// number of transactions on the year's bank statements and paid before anything is read by AI or shown.
import { useQuery } from '@tanstack/react-query';
import { rpc } from './supabase';
import { edge } from './api';

export type FilingKind = 'cit' | 'pit';
export type FilingScan = { id: string; file_name: string | null; pages: number; status: 'held' | 'read'; path: string; bank_account_id: string | null;
  account: string | null; lines_found: number | null; created_at: string };
export type FilingOrder = { id: string; status: 'open' | 'paid'; amount: number | null; counted: number | null; lines: number | null; estimate: number | null;
  band_up_to: number | null; paid_at: string | null; payer: 'business' | 'practice' | null; practice: string | null; true_count: number | null;
  extra_due: number; extra_paid: number };
// Where a year starts: the year before in Counta (approved first), the business beginning in the year, books moved in, last
// year's figures entered, or the owner's word that there was nothing but the bank balances (or that no figures exist).
export type OpeningSource = 'began' | 'previous_year' | 'moved' | 'figures' | 'bank_only' | 'no_figures';
export type FilingOpening = { as_of: string; needed: boolean; done: boolean; source: OpeningSource | null; previous_year?: number;
  by_name?: string | null; at?: string | null; journal_ref?: string | null; assets?: number; lines?: { key: string; amount: number }[] | null;
  asset_rows?: { class_account: string; name: string; cost: number; accumulated: number; in_use_from: string | null }[] };
export type FilingYear = {
  year: number; kind: FilingKind | null; from: string; to: string; due: string; late?: boolean; opening?: FilingOpening;
  lines: number; scan_pages: number; estimate: number; counted: number; band_up_to: number | null; price: number | null;
  order: FilingOrder | null; scans: FilingScan[];
  statements: { file_name: string | null; account: string; from: string | null; to: string | null; lines: number | null; at: string }[];
  return: { status: string; approved_at: string | null; filed_at: string | null; flux_status?: string | null } | null;
  pending: { tx_ref: string; amount: number; payer: 'business' | 'practice'; status: string; at: string } | null;
};
export type FilingState = {
  filing_only: boolean; hold: boolean; is_sample: boolean; managed: boolean; kind: FilingKind | null; legal_form: string | null; vat_registered: boolean;
  years: FilingYear[]; prices: { kind: FilingKind; up_to: number | null; price: number }[];
  accounts: { id: string; name: string; kind: string; bank_name: string | null; last4: string }[];
  can_upload: boolean; can_pay: boolean; card: { last4: string | null; brand: string | null } | null;
  practice: { id: string; name: string; client_id: string; card: { last4: string | null; brand: string | null } | null } | null;
};

export const RETURN_NAME: Record<FilingKind, string> = { cit: 'Companies income tax return', pit: 'Personal income tax return' };
export const LINES_PER_PAGE = 35;

export const useFiling = (orgId: string | null | undefined, enabled = true) =>
  useQuery({ queryKey: ['filing', orgId], enabled: !!orgId && enabled, queryFn: () => rpc<FilingState>('filing_state', { p_org: orgId }) });

// What a band covers, in words: "up to 5,000 transactions", or "more than 10,000" for the band with no upper end.
export function bandWords(prices: FilingState['prices'], kind: FilingKind, upTo: number | null): string {
  if (upTo != null) return `up to ${upTo.toLocaleString('en-NG')} transactions`;
  const below = prices.filter((p) => p.kind === kind && p.up_to != null).map((p) => p.up_to as number);
  return below.length ? `more than ${Math.max(...below).toLocaleString('en-NG')} transactions` : 'any number of transactions';
}

// Where a year stands, for the chip on the Filing page.
export function yearStage(y: FilingYear): { label: string; tone: string } {
  if (y.return?.filed_at || y.return?.status === 'filed' || y.return?.status === 'filed_outside') return { label: 'Filed', tone: 't-green' };
  if (y.return?.status === 'approved') return { label: 'Return approved', tone: 't-blue' };
  if (y.order?.status === 'paid') return Number(y.order.extra_due) > 0 ? { label: 'Balance to pay', tone: 't-amber' } : { label: 'Being prepared', tone: 't-blue' };
  if (y.order) return { label: 'Gathering statements', tone: 't-grey' };
  return { label: 'Not started', tone: 't-grey' };
}

export type PayResult = { ok?: boolean; error?: string; action?: string; link?: string; tx_ref?: string; result?: { status?: string; error?: string }; state?: FilingState };
export const filingPay = (orgId: string, year: number, payer: 'business' | 'practice') =>
  edge<PayResult>('payments', { action: 'filing_pay', org_id: orgId, year, payer, use_saved: true });
export const filingVerify = (orgId: string, txRef: string) => edge<PayResult>('payments', { action: 'filing_verify', org_id: orgId, tx_ref: txRef });

// The lines of last year's statement of financial position the Filing page asks for, in the order shown; bank balances come
// from the bank accounts themselves. Retained earnings alone can be below zero (accumulated losses).
export const OPENING_LINES: { group: 'owned' | 'owed' | 'capital'; key: string; label: string; hint?: string }[] = [
  { group: 'owned', key: 'inventory', label: 'Stock (inventories)' },
  { group: 'owned', key: 'trade_receivables', label: 'Customers who owed the business', hint: 'Trade receivables' },
  { group: 'owned', key: 'other_receivables', label: 'Other money owed to the business', hint: 'Deposits, staff loans, other receivables' },
  { group: 'owned', key: 'prepayments', label: 'Prepayments', hint: 'Rent or insurance paid ahead' },
  { group: 'owned', key: 'director_receivable', label: 'Owed by directors' },
  { group: 'owned', key: 'investments', label: 'Investments' },
  { group: 'owed', key: 'trade_payables', label: 'Suppliers the business owed', hint: 'Trade payables' },
  { group: 'owed', key: 'accruals', label: 'Expenses owed but not yet paid', hint: 'Accruals' },
  { group: 'owed', key: 'other_payables', label: 'Other money the business owed' },
  { group: 'owed', key: 'director_payable', label: 'Owed to directors', hint: "Directors' current account" },
  { group: 'owed', key: 'tax_payable', label: 'Income tax still to pay' },
  { group: 'owed', key: 'loans_short', label: 'Short-term loans' },
  { group: 'owed', key: 'loans_long', label: 'Long-term bank loans' },
  { group: 'owed', key: 'shareholder_loans', label: 'Loans from shareholders' },
  { group: 'capital', key: 'share_capital', label: 'Share capital', hint: "Or the proprietor's capital" },
  { group: 'capital', key: 'share_premium', label: 'Share premium' },
  { group: 'capital', key: 'deposit_for_shares', label: 'Deposit for shares' },
  { group: 'capital', key: 'retained_earnings', label: 'Retained earnings', hint: 'Put a minus sign for accumulated losses' },
];
export const OWNED_KEYS = OPENING_LINES.filter((l) => l.group === 'owned').map((l) => l.key);

export type OpeningAsset = { class_account: string; name: string; cost: string; accumulated: string; in_use_from: string };
// What the figures leave over after the bank balances: assets less what was owed and the capital. When the figures are
// complete it equals the bank balances at the start of the year.
export function openingLeftOver(lines: Record<string, string>, assets: OpeningAsset[], num: (v: string) => number | null): number {
  let left = 0;
  for (const l of OPENING_LINES) {
    const v = num(lines[l.key] || '') || 0;
    left += l.group === 'owned' ? v : -v;
  }
  for (const a of assets) left += (num(a.cost) || 0) - (num(a.accumulated) || 0);
  return Math.round(left * 100) / 100;
}

export const saveOpening = (orgId: string, year: number, p: Record<string, unknown>) =>
  rpc<FilingState>('filing_opening_save', { p_org: orgId, p_year: year, p });

