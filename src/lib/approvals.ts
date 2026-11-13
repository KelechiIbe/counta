// Approvals (Release 2): what the firm that keeps a business's books asks for waits for the director who confirmed the
// wallets (full mandate, by a link and a code) or for the owner or an admin (a client who is involved); a credit note by
// anyone else, an invoice whose discounts pass the business's limit and an invoice someone else marked exempt wait for the
// owner or an admin. The database decides; these are the words and the reads the screens share.
import { useQuery } from '@tanstack/react-query';
import { rpc } from './supabase';
import { N2, when } from './format';
import type { Inventory } from './types';

export type ApprovalKind = 'invoice' | 'credit_note' | 'refund' | 'payout' | 'payout_batch' | 'recurring';
export type ApprovalReason = 'firm' | 'discount' | 'credit_note' | 'vat_relief';
export type ApprovalStatus = 'pending' | 'approved' | 'rejected' | 'cancelled' | 'failed';
export interface Approval {
  id: string; org_id?: string; kind: ApprovalKind; approver: 'director' | 'owner'; reasons: ApprovalReason[]; status: ApprovalStatus;
  sale_id: string | null; payout_id: string | null; batch_id: string | null; recurring_id: string | null; summary: Record<string, any>;
  requested_by?: string | null; requested_by_name: string | null; decided_name: string | null; decided_at: string | null; note: string | null; error: string | null;
  created_at: string; director_name?: string | null; can_decide?: boolean;
}
export interface ApprovalList {
  owner_or_admin: boolean; firm: boolean; limit_pct: number; items: Approval[];
  director: { name: string; email: string | null; phone: string | null; last_link: string | null } | null;
}
// What a document carries about its approvals (sale_json).
export interface SaleApproval {
  id: string; kind: ApprovalKind; status: ApprovalStatus; approver: 'director' | 'owner'; reasons: ApprovalReason[]; title: string | null; note: string | null;
  error: string | null; decided_name: string | null; decided_at: string | null; created_at: string; requested_by_name: string | null;
}

export const useApprovals = (orgId: string | null, enabled = true) => useQuery({ queryKey: ['approvals', orgId], enabled: !!orgId && enabled,
  queryFn: () => rpc<ApprovalList>('approvals_list', { p_org: orgId }), refetchInterval: 60_000 });

export const KIND_LABEL: Record<ApprovalKind, string> = {
  invoice: 'Invoice', credit_note: 'Credit note', refund: 'Refund', payout: 'Payment', payout_batch: 'Bulk payment', recurring: 'Recurring invoice',
};
export const REASON_LABEL: Record<ApprovalReason, string> = {
  firm: 'Asked by the firm that keeps the books',
  discount: 'Discounts over the limit',
  credit_note: 'A credit note by someone other than the owner or an admin',
  vat_relief: 'Marked exempt from VAT by someone other than the owner or an admin',
};
export const STATUS_LABEL: Record<ApprovalStatus, string> = {
  pending: 'Waiting', approved: 'Approved', rejected: 'Not approved', cancelled: 'Withdrawn', failed: 'Approved, not carried out',
};
export const STATUS_TONE: Record<ApprovalStatus, string> = { pending: 't-amber', approved: 't-green', rejected: 't-red', cancelled: 't-grey', failed: 't-red' };

// Who it waits for, in words.
export const waitsFor = (a: { approver: 'director' | 'owner'; director_name?: string | null }) =>
  a.approver === 'director' ? (a.director_name ? `${titleName(a.director_name)}, the director who confirmed the wallets` : 'the director who confirmed the wallets')
    : 'the owner or an admin';
// "DAYO ADE" as NIMC holds it reads better as "Dayo Ade".
export const titleName = (s: string) => s.replace(/^[^(]+/, (n) => (n === n.toUpperCase() ? n.toLowerCase().replace(/(^|[\s'-])\p{L}/gu, (c) => c.toUpperCase()) : n));

// The person may decide what waits for the owner or an admin (and is not the firm, for what the firm asked).
export const decidesApprovals = (inv: Inventory | undefined) => !!inv && ['owner', 'admin'].includes(inv.me.role);

// The toast after a call the database may have sent for approval instead of carrying out.
export function pendingNote(r: any, what: string): string | null {
  const a = r?.approval || (Array.isArray(r?.approvals) ? r.approvals.find((x: SaleApproval) => x.status === 'pending') : null);
  if (!(r?.pending_approval || (a && a.status === 'pending'))) return null;
  return `${what} sent for approval. It waits for ${waitsFor(a || { approver: 'owner' })}.`;
}

// What a waiting request is about, in one line.
export function approvalLine(a: Approval): string {
  const s = a.summary || {};
  switch (a.kind) {
    case 'invoice': return `${s.customer || ''} · ${N2(s.total)}${Number(s.discount) > 0 ? ` · ${s.discount_pct}% off` : ''}${s.relief ? ' · exempt from VAT' : ''}`;
    case 'credit_note': return `${s.customer || ''} · ${N2(s.total)}${s.reason ? ` · ${s.reason}` : ''}`;
    case 'refund': return `${s.customer || ''} · ${N2(s.amount)} by ${s.method || 'cash'}${s.reason ? ` · ${s.reason}` : ''}`;
    case 'payout': return `${s.account_name || ''} · ${s.bank_name || ''} ${s.account_number || ''} · ${N2(s.amount)}${s.narration ? ` · ${s.narration}` : ''}`;
    case 'payout_batch': return `${s.rows} payment${Number(s.rows) === 1 ? '' : 's'} · ${N2(s.total)}${s.name ? ` · ${s.name}` : ''}`;
    case 'recurring': return `${s.customer || ''} · ${s.frequency || ''} on day ${s.day_of_month} · ${N2(s.amount_before_vat)} before VAT`;
  }
  return '';
}

export const decidedText = (a: { status: ApprovalStatus; decided_name: string | null; decided_at: string | null; note: string | null; error?: string | null }) =>
  a.status === 'approved' ? `Approved by ${a.decided_name ? titleName(a.decided_name) : 'the approver'} ${when(a.decided_at)}`
    : a.status === 'rejected' ? `Not approved by ${a.decided_name ? titleName(a.decided_name) : 'the approver'}${a.note ? `: ${a.note}` : ''}`
    : a.status === 'failed' ? `Approved, but it did not go through: ${a.error || 'it could not be carried out.'}`
    : a.status === 'cancelled' ? `Withdrawn${a.note ? `: ${a.note}` : ''}` : 'Waiting';

// ---------------------------------------------------------------- VAT relief for exempt buyers
export type Relief = 'diplomatic' | 'free_zone' | 'humanitarian';
export const RELIEF: Record<Relief, { label: string; ref: string; words: string }> = {
  diplomatic: { label: 'Diplomatic mission or diplomat', ref: 'Accreditation or note verbale number', words: 'a diplomatic mission or diplomat' },
  free_zone: { label: 'Free trade zone entity', ref: 'Zone licence number', words: 'an approved free trade zone entity' },
  humanitarian: { label: 'Humanitarian donor-funded project', ref: 'Project or grant reference', words: 'a humanitarian donor-funded project' },
};
export const RELIEFS = Object.keys(RELIEF) as Relief[];
