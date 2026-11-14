// Audits: a company above the small company limits has its accounts audited. It asks a TaxStreem partner firm (priced by
// turnover band), the firm answers, and the business pays the fee and its VAT less withholding tax at Flutterwave's checkout,
// with TaxStreem's referral fee split off. Or it names an auditor of its own.
import { useQuery } from '@tanstack/react-query';
import { rpc } from './supabase';
import { edge } from './api';

export type AuditBand = { key: string; from: number; up_to: number | null; label: string };
export type AuditNeed = { year: number; from: string; to: string; company: boolean; ended: boolean; turnover: number | null; fixed_assets: number | null;
  turnover_max: number; fixed_assets_max: number; over_turnover: boolean; over_assets: boolean; required: boolean; band: AuditBand };
export type AuditSigner = { id: string; name: string; body: 'ICAN' | 'ANAN'; licence_no: string; frc_no: string };
export type AuditFirm = { id: string; name: string; kind: string; state: string | null; note: string | null; entity_type: string; vat_registered: boolean;
  price: number; vat: number; signers: AuditSigner[]; keeps_books: boolean };
export type AuditStatus = 'requested' | 'accepted' | 'paid' | 'declined' | 'lapsed' | 'cancelled' | 'recorded';
export type AuditEngagement = {
  id: string; year: number; kind: 'partner' | 'own'; status: AuditStatus; own_name: string | null; own_email: string | null; band: AuditBand | null;
  turnover: number | null; fixed_assets: number | null; price: number | null; vat_registered: boolean | null; vat: number; wht: number; wvat: number;
  amount: number | null; keeps_books: boolean; note: string | null; answer_note: string | null; bill: { id: string; number: string; status: string } | null;
  bill_error: string | null; requested_at: string; answered_at: string | null; paid_at: string | null; ended_at: string | null; lapses_at: string | null;
  business: { id: string; name: string; tin: string | null; rc_number: string | null };
  firm: Omit<AuditFirm, 'price' | 'vat' | 'keeps_books'> | null;
  charge: { tx_ref: string; status: string; amount: number; paid_amount: number | null; at: string; paid_at: string | null } | null;
  referral_rate?: number; referral?: number;
};
export type AuditState = { year: number; enabled: boolean; need: AuditNeed; audit_exempt: boolean; auditors: string | null; can_act: boolean;
  engagement: AuditEngagement | null };

export const useAuditState = (orgId: string | null | undefined, year: number) =>
  useQuery({ queryKey: ['audit', orgId, year], enabled: !!orgId, queryFn: () => rpc<AuditState>('audit_state', { p_org: orgId, p_year: year }) });
export const useAuditFirms = (orgId: string | null | undefined, year: number, enabled: boolean) =>
  useQuery({ queryKey: ['audit-firms', orgId, year], enabled: !!orgId && enabled,
    queryFn: () => rpc<{ band: AuditBand; firms: AuditFirm[] }>('audit_firms', { p_org: orgId, p_year: year }) });

type EdgeResult = { ok?: boolean; error?: string; reason?: string };
export const auditPay = (engagementId: string) =>
  edge<EdgeResult & { link?: string; tx_ref?: string; amount?: number }>('audits', { action: 'pay', engagement_id: engagementId });
export const auditVerify = (txRef: string) => edge<EdgeResult & { status?: string; state?: AuditState }>('audits', { action: 'verify', tx_ref: txRef });

export const ENTITY_WORD: Record<string, string> = { partnership: 'Partnership', llp: 'Limited liability partnership', company: 'Company',
  sole_proprietor: 'Sole practitioner' };
export const pct = (r: number | null | undefined) => `${Math.round(Number(r || 0) * 1000) / 10}%`;
