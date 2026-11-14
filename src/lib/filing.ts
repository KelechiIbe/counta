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
export type FilingYear = {
  year: number; kind: FilingKind | null; from: string; to: string; due: string;
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
