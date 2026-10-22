// The Counta Partner programme: accountants earn a share of what the businesses they bring pay for Counta. These are the
// reads the business side, the accountant portal and the link page share.
import { useQuery } from '@tanstack/react-query';
import { rpc } from './supabase';

export type Tier = { code: string; name: string; clients: number; rate: number; months: number };
export type TierNow = Tier & { paying: number; next: Tier | null };
export type PartnerPublic = {
  id: string; name: string; kind: 'firm' | 'sole'; state: string | null; blurb: string | null; code: string; tier: { code: string; name: string }; verified: boolean;
  licences: string[];
};
export type Offer = { percent: number; payments: number; practice?: string };
export type Preview = PartnerPublic & { offer: Offer | null };
export type OrgPartner = { offer: Offer | null; partners: PartnerPublic[]; directory: boolean };
export type Listing = PartnerPublic & { connected: boolean; requested: boolean };

export type PartnerHome = {
  enabled: boolean; me: { role: 'partner' | 'manager' | 'staff' }; code: string; verified: boolean;
  listing: { listed: boolean; blurb: string | null; state: string | null; directory: boolean; min_clients: number };
  tier: TierNow; tiers: Tier[];
  milestones: { clients: number; bonus: number; reached: boolean; paid: boolean }[];
  terms: { hold_days: number; min_payout: number; payout_day: number; wht_rate: number; welcome: { on: boolean; percent: number; payments: number } };
  totals: { earned: number; waiting: number; ready: number; in_payout: number; paid: number };
  bank: { bank_name: string; bank_code: string; last4: string; account_name: string; name_match: boolean; set_at: string; set_by: string | null } | null;
  referrals: { id: string; business: string; source: 'link' | 'invite' | 'request' | 'directory'; status: 'waiting' | 'earning' | 'completed' | 'void';
    void_reason: 'self' | 'ended' | null; connected_at: string; first_paid_at: string | null; window_ends: string | null; months: number | null; earned: number;
    client_id: string | null }[];
  commissions: { id: string; kind: 'commission' | 'bonus'; note: string | null; base: number | null; rate: number | null; amount: number;
    status: 'waiting' | 'ready' | 'in_payout' | 'paid' | 'void'; available_at: string; created_at: string }[];
  payouts: { id: string; period: string; gross: number; wht_rate: number; wht: number; net: number; status: 'processing' | 'paid' | 'failed';
    bank_name: string | null; last4: string | null; paid_at: string | null; created_at: string }[];
  requests: { client_id: string; business: string; note: string | null; services: string[]; billing: string; created_at: string }[];
};

export type PayoutNote = {
  payer: { name: string; tin: string | null; address: string | null };
  payee: { name: string; address: string | null; firm_reg: string | null; state: string | null };
  payout: { reference: string; period: string; paid_at: string; gross: number; wht_rate: number; wht: number; net: number; bank_name: string; last4: string };
  lines: { note: string | null; kind: string; amount: number }[];
};

export const REF_RE = /^[A-Za-z]{4}-[A-Za-z0-9]{4}$/;
const KEY = 'counta-ref';
// The practice whose link someone followed, kept until they connect it or say no.
export const refCode = {
  get(): string | null { try { const v = localStorage.getItem(KEY); return v && REF_RE.test(v) ? v.toUpperCase() : null; } catch { return null; } },
  set(code: string) { try { if (REF_RE.test(code)) localStorage.setItem(KEY, code.toUpperCase()); } catch { /* private mode */ } },
  clear() { try { localStorage.removeItem(KEY); } catch { /* private mode */ } },
};

// 0.175 reads as 17.5%.
export const pct = (r: number | string | null | undefined) => `${Math.round(Number(r || 0) * 1000) / 10}%`;

export const TIER_TONE: Record<string, { fg: string; bg: string; ring: string }> = {
  bronze: { fg: '#9A3412', bg: '#FFEDD5', ring: '#FDBA74' },
  silver: { fg: '#334155', bg: '#F1F5F9', ring: '#CBD5E1' },
  gold: { fg: '#854D0E', bg: '#FEF9C3', ring: '#FACC15' },
};
export const tierTone = (code?: string | null) => TIER_TONE[code || ''] || { fg: '#1E40AF', bg: '#EFF6FF', ring: '#BFDBFE' };

export const SOURCE_TEXT: Record<string, string> = { link: 'Your link', invite: 'Your invitation', request: 'They invited you', directory: 'The directory' };

export const useOrgPartner = (orgId: string | null) =>
  useQuery({ queryKey: ['org-partner', orgId], enabled: !!orgId, staleTime: 60_000, queryFn: () => rpc<OrgPartner>('org_partner', { p_org: orgId }) });
export const usePracticePartner = (pid: string | null, enabled = true) =>
  useQuery({ queryKey: ['practice-partner', pid], enabled: !!pid && enabled, queryFn: () => rpc<PartnerHome>('practice_partner', { p_practice: pid }) });
