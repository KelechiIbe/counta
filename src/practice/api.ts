// The accountant portal's reads and calls. The database decides who sees what: partners and managers see every client,
// staff the clients they are assigned; a business sees its own accountants, their requests and the files they changed.
import { useQuery } from '@tanstack/react-query';
import { rpc, supabase } from '../lib/supabase';
import { edge } from '../lib/api';

export type PracticeRole = 'partner' | 'manager' | 'staff';
export type LicenceBody = 'ICAN' | 'ANAN' | 'CITN';
export type Member = {
  id: string; display_name: string; role: PracticeRole; status: 'active' | 'invited' | 'disabled'; joined: boolean; email?: string; licence_body: LicenceBody | null;
  licence_no: string | null; licence_status: 'none' | 'pending' | 'verified' | 'rejected'; licence_text: string; licence_note?: string | null; clients: number;
  sent_at?: string | null; created_at?: string;
};
export type Deadline = { tax: string; label: string; period: string; due: string; amount: number | null; url: string; overdue: boolean };
export type Health = {
  deadlines: Deadline[]; overdue: number; due_soon: number; bank_lines: number; proposals: number; invoices_overdue: number; bills_overdue: number; files_review: number;
  closed_through: string | null; last_entry: string | null;
  plan: { name: string; status: string; period_end: string | null; paid_by: string | null; cancel_at_period_end: boolean; billing: string; price: number };
};
export type ClientRow = {
  id: string; status: 'active' | 'invited' | 'requested' | 'ended' | 'declined'; initiated_by: 'practice' | 'business'; org_id: string | null; business_name: string | null;
  invite_email: string | null; invite_name: string | null; services: string[]; billing: 'business' | 'practice'; note: string | null; created_at: string; started_at: string | null;
  sent_at: string | null; tin: string | null; vat_registered: boolean | null; assigned: string[]; requests_open: number; answered: number; health: Health | null;
};
export type Invitation = { id: string; business: string; services: string[]; billing: string; note: string | null; created_at: string };
export type Practice = { id: string; name: string; kind: 'firm' | 'sole'; email: string | null; phone: string | null; address: string | null; state: string | null; firm_reg: string | null; created_at: string };
export type Plan = { id: string; name: string; price_month: number; price_year: number | null; description?: string | null };
export type Home = {
  practice: Practice; me: Member; members: Member[]; clients: ClientRow[]; business_invitations: Invitation[];
  past_clients: { id: string; status: string; business_name: string | null; invite_email: string | null; ended_at: string | null }[];
  billing: { paying_for: number; card: { id: string; last4: string; brand: string; expiry: string } | null } | null; plans: Plan[];
};
export type RequestRow = {
  id: string; client_id: string; org_id: string; kind: 'document' | 'question' | 'approval'; title: string; detail: string | null; due_date: string | null;
  status: 'open' | 'answered' | 'done' | 'cancelled'; answer: string | null; file_path: string | null; file_name: string | null; created_at: string; answered_at: string | null;
  closed_at: string | null; asked_by: string | null; practice: string | null; answered_by: string | null;
};
export type FileBrief = {
  id: string; kind: 'vat' | 'wht' | 'cit' | 'fs'; period: string; authority: string | null; label: string; version: number; status: 'review' | 'in_use' | 'replaced' | 'withdrawn';
  file_name: string; uploader_name: string | null; practice_name: string | null; accepted_name: string | null; accepted_licence: string | null; accepted_at: string | null;
  created_at: string; changes: number; payable_difference: number | null; statement: string | null; journal_ref: string | null; withdrawn_at: string | null; withdrawn_reason: string | null;
};
export type ChangeRow = { key: string; label: string; counta: number | null; uploaded: number | null; difference?: number; bookable?: boolean };
export type JournalLine = { code: string | null; debit?: number | string; credit?: number | string; memo?: string };
export type LinesCheck = { lines: number; debit: number; credit: number; balanced: boolean; problems: string[]; remaining: { label: string; file: number; journal: number; left: number }[] };
export type FileVersion = Omit<FileBrief, 'changes'> & {
  org_id: string; figures: ChangeRow[]; changes: ChangeRow[]; checks: string[]; proposal: JournalLine[]; proposal_check: LinesCheck | null; note: string | null; file_path: string;
  sha256: string; no_journal_reason: string | null; locked: string | null; base: { id: string; version: number; accepted_name: string | null } | null; can_apply: boolean;
  can_withdraw: boolean; statement_preview: string | null; accounts: { code: string; name: string; line: string | null; statement: string }[] | null;
};
export type ClientDetail = {
  client: ClientRow & { ended_at: string | null; practice_id: string };
  business: { name: string; tin: string | null; rc_number: string | null; vat_registered: boolean; fiscal_year_start: number; books_start: string | null; address: string | null;
    phone: string | null; email: string | null; owner: { name: string; email: string | null } | null } | null;
  me: Member; my_seat: { member_id: string; status: string; role: string } | null; health: Health | null;
  team: { member: Member; assigned: boolean; seat: string | null }[]; requests: RequestRow[];
  notes: { id: string; text: string; created_at: string; author: string | null; mine: boolean }[]; files: FileBrief[]; can_lead: boolean;
};
export type Billing = {
  clients: { client_id: string; org_id: string; business_name: string; billing: string; plan: { id: string; name: string } | null;
    subscription: { status: string; billing: string; period_end: string | null; cancel_at_period_end: boolean; paid_by_us: boolean; paid_by_other: boolean } | null }[];
  cards: { id: string; last4: string; brand: string; expiry: string; created_at: string }[];
  charges: { id: string; tx_ref: string; business_name: string; plan: string; billing: string; amount: number; kind: string; status: string; error: string | null; paid_at: string | null; created_at: string }[];
  plans: Plan[];
};

export const SERVICES: [string, string][] = [['bookkeeping', 'Bookkeeping'], ['vat', 'VAT'], ['wht', 'WHT'], ['cit', 'Companies income tax'], ['statements', 'Financial statements'],
  ['payroll', 'Payroll'], ['advisory', 'Advisory']];
export const serviceLabel = (s: string) => SERVICES.find(([k]) => k === s)?.[1] || s;
// The services in a sentence: "bookkeeping, VAT, WHT and financial statements".
export const serviceList = (list: string[]) => [...list].sort((a, b) => SERVICES.findIndex(([k]) => k === a) - SERVICES.findIndex(([k]) => k === b)).map(serviceLabel).join(', ');
export function servicesText(list: string[]) {
  const words = [...list].sort((a, b) => SERVICES.findIndex(([k]) => k === a) - SERVICES.findIndex(([k]) => k === b)).map((x) => { const l = serviceLabel(x); return /^[A-Z]{2,}$/.test(l) ? l : l.charAt(0).toLowerCase() + l.slice(1); });
  return words.length > 1 ? `${words.slice(0, -1).join(', ')} and ${words[words.length - 1]}` : words.join('');
}
export const ROLE_WORD: Record<PracticeRole, string> = { partner: 'Partner', manager: 'Manager', staff: 'Staff' };
export const KIND_LABEL: Record<FileBrief['kind'], string> = { vat: 'VAT return', wht: 'WHT schedule', cit: 'CIT return', fs: 'Financial statements' };
export const STATUS_CHIP: Record<FileBrief['status'], [string, string]> = {
  review: ['Waiting for you to book it', 't-amber'], in_use: ['In use', 't-green'], replaced: ['Replaced', 't-grey'], withdrawn: ['Withdrawn', 't-red'],
};

const KEY = 'counta.practice';
export const savedPractice = () => { try { return localStorage.getItem(KEY); } catch { return null; } };
export const savePractice = (id: string) => { try { localStorage.setItem(KEY, id); } catch { /* private mode */ } };

export const usePracticesMine = (enabled = true) => useQuery({ queryKey: ['practices-mine'], enabled, staleTime: 60_000,
  queryFn: () => rpc<{ practices: { id: string; name: string; role: PracticeRole; clients: number }[]; business_invitations: Invitation[] }>('practices_mine') });
export const usePracticeHome = (id: string | null) => useQuery({ queryKey: ['practice-home', id], enabled: !!id, queryFn: () => rpc<Home>('practice_home', { p_practice: id }) });
export const usePracticeClient = (id: string | null) => useQuery({ queryKey: ['practice-client', id], enabled: !!id, queryFn: () => rpc<ClientDetail>('practice_client', { p_client: id }) });
export const usePracticeBilling = (id: string | null) => useQuery({ queryKey: ['practice-billing', id], enabled: !!id, queryFn: () => rpc<Billing>('practice_billing', { p_practice: id }) });
export const useFileVersion = (id: string | null) => useQuery({ queryKey: ['filing-version', id], enabled: !!id, queryFn: () => rpc<FileVersion>('filing_version', { p_version: id }) });

// Emails an invitation made in the database (a fresh one-time link goes with it).
export async function sendInvite(kind: 'member' | 'client' | 'accountant', id: string): Promise<{ ok: boolean; sent_to?: string; error?: string; reason?: string }> {
  return edge('messaging', { action: 'practice_email', kind, id });
}

export async function openDoc(path: string, download?: string) {
  const { data, error } = await supabase.storage.from('documents').createSignedUrl(path, 300, download ? { download } : undefined);
  if (error || !data?.signedUrl) throw new Error('The file could not be opened just now.');
  window.open(data.signedUrl, '_blank', 'noopener');
}

// A period as people say it: "September 2026", "2025", "the year to 31 Dec 2025".
export function periodText(kind: FileBrief['kind'], period: string) {
  if (kind === 'vat' || kind === 'wht') return new Date(period + '-01T12:00:00Z').toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' });
  if (kind === 'cit') return period;
  const to = period.split(':')[1];
  return `the period to ${new Date(to + 'T12:00:00Z').toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' })}`;
}
