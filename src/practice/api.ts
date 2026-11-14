// The accountant portal's reads and calls. The database decides who sees what: partners and managers see every client,
// staff the clients they are assigned; a business sees its own accountants, their requests and the files they changed.
import { useInfiniteQuery, useQuery } from '@tanstack/react-query';
import { rpc, supabase } from '../lib/supabase';
import { type ActivityPage, edge } from '../lib/api';
import type { LetterBody, MergeValues } from '../../supabase/functions/_shared/letter.ts';

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
  // How the firm works for the business, the due-diligence intake the link carries (incomplete: the link is active and the
  // intake is not cleared), and a full mandate kept read-only after it ended, until its retention date.
  mode: IntakeMode; intake_id: string | null; dd_incomplete: boolean; read_only: boolean; retain_until: string | null;
};
export type Invitation = { id: string; business: string; services: string[]; billing: string; note: string | null; created_at: string };
export type Practice = {
  id: string; name: string; kind: 'firm' | 'sole'; email: string | null; phone: string | null; address: string | null; state: string | null; firm_reg: string | null; created_at: string;
  conflict_scan_books: boolean; mandate_suspended_at: string | null;
  // The firm's letterhead on its engagement letters (null: plain), who set it and when.
  letterhead: Letterhead | null; letterhead_set_at: string | null; letterhead_set_by: string | null;
};
// A letterhead file as the practice saved it: a PDF page (its size in points) or a picture (its size in pixels).
export type LetterheadFile = { path: string; sha256: string; kind: 'pdf' | 'png' | 'jpg'; w: number; h: number };
export type LetterheadMargins = { first_top: number; first_bottom: number; next_top: number; next_bottom: number; left: number; right: number };
export type LetterheadShow = { address: boolean; phone: boolean; email: boolean; firm_reg: boolean; website: boolean };
// As the database keeps it (private.letterhead_norm): the firm's own page laid under the letter, or one built here.
export type Letterhead = {
  mode: 'upload' | 'built'; font: 'helvetica' | 'times'; color: string; page: [number, number];
  first?: LetterheadFile; next?: LetterheadFile | null; next_mode?: 'same' | 'upload' | 'none'; margins?: LetterheadMargins;
  logo?: LetterheadFile | null; layout?: 'left' | 'center'; show?: LetterheadShow; website?: string | null; footer?: string | null;
};
export type Plan = { id: string; name: string; price_month: number; price_year: number | null; description?: string | null };
export type Home = {
  practice: Practice; me: Member; members: Member[]; clients: ClientRow[]; business_invitations: Invitation[];
  past_clients: { id: string; status: string; business_name: string | null; invite_email: string | null; ended_at: string | null }[];
  billing: { paying_for: number; card: { id: string; last4: string; brand: string; expiry: string } | null } | null; plans: Plan[];
  // Whether the firm may run full mandates: a partner whose licence TaxStreem verified, and TaxStreem has not paused them.
  can_full: boolean;
};

// Due diligence before a client is taken on (practice_intake*): partners and managers only.
export type IntakeMode = 'involved' | 'full';
export type EntityType = 'company' | 'business_name' | 'incorporated_trustees' | 'partnership' | 'individual';
export type IdType = 'nin' | 'bvn' | 'passport' | 'drivers_licence' | 'voters_card' | 'cac' | 'other';
export type ConflictStatus = 'pending' | 'none' | 'hits' | 'cleared' | 'refused';
export type LetterStatus = 'draft' | 'partner_signed' | 'sent' | 'completed' | 'uploaded' | 'void';
// An ID number is only ever its last 4 characters.
export type IntakePerson = {
  id?: string; kind: 'director' | 'beneficial_owner' | 'related'; name: string; role: string | null; ownership_pct: number | null; nationality: string | null;
  is_pep: boolean; id_type: IdType | null; id_last4: string | null;
};
export type IntakeRow = {
  id: string; status: 'draft' | 'engaged' | 'declined'; mode_requested: IntakeMode; legal_name: string; entity_type: EntityType | null; rc_number: string | null;
  tax_id: string | null; risk_rating: 'low' | 'medium' | 'high' | null; pep_present: boolean; dd_incomplete: boolean; conflict_status: ConflictStatus;
  checked_at: string | null; cleared: boolean; authority_declared: boolean; client_id: string | null; org_id: string | null; retain_until: string | null;
  created_at: string; updated_at: string;
};
// subject: what of the prospect matched (its name, number or one of its people); match_name: what it matched in the firm's records.
export type ConflictHit = {
  id: string; kind: 'client' | 'prospect' | 'related_party' | 'opposing_party' | 'books'; matched_on: 'rc_number' | 'tax_id' | 'name' | 'person';
  subject: string; match_name: string | null; score: number | null; source_client_id: string | null; source_intake_id: string | null; source_opposing_id: string | null;
};
export type IntakeDoc = { id: string; kind: 'cac' | 'id' | 'address' | 'other'; name: string; path: string; sha256: string; added_by_name: string | null; created_at: string };
export type IntakeDetail = Omit<IntakeRow, 'authority_declared'> & {
  practice_id: string; address: string | null; industry: string | null; risk_reason: string | null; conflict_note: string | null;
  conflict_decided_by: string | null; conflict_decided_at: string | null; conflict_decided_by_name: string | null; edited_at: string;
  authority_declared_by: string | null; authority_declared_at: string | null; authority_statement: string | null; authority_doc_path: string | null;
  authority_declared_by_name: string | null;
  people: IntakePerson[]; docs: IntakeDoc[]; hits: ConflictHit[]; letters: { id: string; status: LetterStatus; variant: IntakeMode }[];
  history?: IntakeHistory[];
};
// A client's intake as it was before a change (ongoing due diligence), newest first.
export type IntakeSnapshot = {
  legal_name: string; mode_requested: IntakeMode; entity_type: EntityType | null; rc_number: string | null; tax_id: string | null; address: string | null;
  industry: string | null; risk_rating: 'low' | 'medium' | 'high' | null; risk_reason: string | null; pep_present: boolean; conflict_status: ConflictStatus;
  conflict_note: string | null; checked_at: string | null; people: Omit<IntakePerson, 'id'>[];
};
export type IntakeHistory = { id: string; created_at: string; changed_by_name: string | null; snapshot: IntakeSnapshot };
// Each condition for setting a business up under full mandate, for the signed-in person; ok when all hold.
export type GateKey = 'partner_verified' | 'practice_can_full' | 'risk_rated' | 'rc_or_tax_id' | 'conflicts_cleared' | 'letter_completed' | 'authority_declared';
export type MandateGate = Record<GateKey | 'ok', boolean>;
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
// A business the firm runs under full mandate, or one kept read-only after that ended without a handover: how it sends its
// documents, where its alerts go, the director's confirmation of the wallets, the latest handover and engagement letter.
// The director's and the handover's contact details come to partners and managers only.
export type DirectorStatus = 'pending' | 'review' | 'confirmed' | 'declined' | 'cancelled';
export type Mandate = {
  send_mode: 'send' | 'download_only'; alert_email: string | null; engagement_partner_id: string | null;
  director_confirmed_at: string | null; read_only_at: string | null; retain_until: string | null; payments_open: boolean;
  director: { status: DirectorStatus; name: string | null; email: string | null; sent_at: string; confirmed_at: string | null } | null;
  handover: { id: string; email: string | null; status: 'pending' | 'accepted' | 'cancelled'; sent_at: string | null } | null;
  letter: { id: string; status: LetterStatus } | null;
};
export type ClientDetail = {
  // end_kind: how the work ended: 'ended' (a full mandate kept read-only) or 'handover' (handed to the owner).
  client: ClientRow & { ended_at: string | null; practice_id: string; end_kind: 'ended' | 'handover' | null };
  mandate: Mandate | null;
  business: { name: string; tin: string | null; rc_number: string | null; vat_registered: boolean; fiscal_year_start: number; books_start: string | null; address: string | null;
    phone: string | null; email: string | null; owner: { name: string; email: string | null } | null } | null;
  me: Member; my_seat: { member_id: string; status: string; role: string } | null; health: Health | null;
  team: { member: Member; assigned: boolean; seat: string | null }[]; requests: RequestRow[];
  notes: { id: string; text: string; created_at: string; author: string | null; mine: boolean }[]; files: FileBrief[]; can_lead: boolean;
  // The other side of the client's matters, for the conflicts check (partners and managers; empty for staff).
  opposing_parties?: { id: string; name: string; rc_number: string | null; note: string | null }[];
};
export type Billing = {
  clients: { client_id: string; org_id: string; business_name: string; billing: string; plan: { id: string; name: string } | null; filing_only?: boolean; managed?: boolean;
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
export const usePracticeIntakes = (pid: string, status?: string) => useQuery({ queryKey: ['practice-intakes', pid, status], enabled: !!pid,
  queryFn: () => rpc<IntakeRow[]>('practice_intakes', { p_practice: pid, p: status ? { status } : {} }) });
export const usePracticeIntake = (iid: string | null) => useQuery({ queryKey: ['practice-intake', iid], enabled: !!iid,
  queryFn: () => rpc<IntakeDetail>('practice_intake', { p_intake: iid }) });
// Engagement letters: the practice's templates (the improved default letter is always there) and one letter with its signer
// and its record of events.
export type LetterTemplate = {
  id: string; name: string; kind: 'blocks' | 'pdf'; body: LetterBody | null; pdf_path: string | null; is_default: boolean; archived: boolean;
  created_by_name: string | null; created_at: string; updated_at: string;
};
export type LetterSigner = {
  id: string; name: string; email: string; title: string | null; link_sent: boolean; token_expires: string | null; sends_today: number;
  otp_failures: number; locked: boolean; code_verified_at: string | null; typed_name: string | null; signed_at: string | null; created_at: string;
};
export type LetterEvent = { id: number; at: string; kind: string; actor: string | null; ip: string | null; ua: string | null; detail: Record<string, unknown> | null };
export type LetterDetail = {
  id: string; practice_id: string; intake_id: string; client_id: string | null; template_id: string | null; variant: 'full' | 'involved';
  source: 'template' | 'pdf' | 'signed_upload'; status: LetterStatus; title: string; blocks: LetterBody | null; merge: MergeValues;
  doc_path: string | null; doc_sha256: string | null; final_path: string | null; final_sha256: string | null; retention_years: number;
  partner_name: string | null; partner_email: string | null; partner_signed_at: string | null; white_label: boolean; void_reason: string | null;
  created_at: string; updated_at: string; template_name: string | null; intake_name: string | null; signers: LetterSigner[]; events: LetterEvent[];
};
export const useLetterTemplates = (pid: string) => useQuery({ queryKey: ['letter-templates', pid], enabled: !!pid,
  queryFn: () => rpc<LetterTemplate[]>('practice_letter_templates', { p_practice: pid }) });
export const useLetter = (lid: string | null) => useQuery({ queryKey: ['letter', lid], enabled: !!lid,
  queryFn: () => rpc<LetterDetail>('practice_letter', { p_letter: lid }) });

// Fee billing from the firm's own Counta business (practices.firm_org_id): each client's fee customer, what it owes, its
// fee invoices, its recurring schedules and, for a full-mandate client, the bills posted in its own books (the fee mirror).
// Wallet balances for partners only.
export type FeeBillStatus = 'posted' | 'failed' | 'voided' | 'skipped' | 'dismissed';
// A credit note on a fee invoice whose bill is in a full-mandate client's books: waiting for a lead to confirm it (pending),
// recorded against the bill (posted), or left out of the books by a partner (dismissed, note: why).
export type FeeCredit = {
  id: string; fee_bill_id: string; sale_id: string; invoice: string; credit_sale_id: string; credit_note: string; issue_date: string; amount: number;
  status: 'pending' | 'posted' | 'dismissed'; error: string | null; note: string | null; decided_at: string | null; decided_by_name: string | null; created_at: string;
};
export type PracticeFees = {
  firm_org: { id: string; name: string; identity_status: string } | null;
  clients: {
    client_id: string; business_name: string; mode: IntakeMode; fee_customer_id: string | null; outstanding: number;
    invoices: { id: string; number: string; issue_date: string; total: number; credited: number; balance: number; status: string }[];
    schedules: { id: string; frequency: 'monthly' | 'quarterly' | 'annually'; day_of_month: number; next_run: string; status: 'active' | 'paused' | 'ended'; total: number }[];
    fee_bills: { id: string; sale_id: string; status: FeeBillStatus; error: string | null; bill_id: string | null; dismiss_reason: string | null; credited: number; note: string | null }[];
    fee_credits?: FeeCredit[];
  }[];
  wallets?: { wallet: { status: string | null; balance: number }; tax_wallet: { status: string | null; balance: number } };
};
export const usePracticeFees = (pid: string) => useQuery({ queryKey: ['practice-fees', pid], enabled: !!pid, queryFn: () => rpc<PracticeFees>('practice_fees', { p_practice: pid }) });

// The practice's entries in a client business's activity log, a page at a time.
export const usePracticeActivity = (cid: string | null, enabled = true) => useInfiniteQuery({
  queryKey: ['practice-activity', cid], enabled: !!cid && enabled, initialPageParam: null as number | null,
  queryFn: ({ pageParam }) => rpc<ActivityPage>('practice_activity', { p_client: cid, p: pageParam ? { before: pageParam } : {} }),
  getNextPageParam: (last) => last.next_before,
});

export const useMandateGate = (iid: string | null) => useQuery({ queryKey: ['mandate-gate', iid], enabled: !!iid,
  queryFn: () => rpc<MandateGate>('practice_mandate_gate', { p_intake: iid }) });

// Emails an invitation made in the database (a fresh one-time link goes with it).
export async function sendInvite(kind: 'member' | 'client' | 'accountant' | 'handover', id: string): Promise<{ ok: boolean; sent_to?: string; error?: string; reason?: string }> {
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
