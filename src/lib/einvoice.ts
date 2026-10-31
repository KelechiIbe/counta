// E-invoicing with the NRS (MBS): a business's settings, its readiness and NRS's code lists. See docs/e-invoicing.md.
import { useQuery } from '@tanstack/react-query';
import { rpc, supabase } from './supabase';

export type EinvReady = {
  id: 'tin' | 'contact' | 'address' | 'keys' | 'check' | 'service' | 'items' | 'customers';
  ok: boolean; blocking: boolean; title: string; detail: string; link?: string;
  counts?: { items: number; coded: number; waiting: number; review: number };
};
export type EinvSettings = {
  started: boolean; enabled: boolean; enabled_at: string | null; platform_keys: boolean;
  business_id: string | null; service_id: string | null;
  keys: { api_key: string | null; api_secret: string | null; crypto_keys: string | null };
  service: { code: string; label: string | null; source: 'gemini' | 'manual' | null; reason: string | null; confidence: number | null; review: boolean } | null;
  service_waiting: boolean;
  check: { at: string; ok: boolean; note: string; current: boolean } | null;
  readiness: EinvReady[]; ready: boolean; can: { edit: boolean };
  queue: EinvQueue | null;
};
// How the sending is going: sales waiting for NRS, signed, refused, and the ones that need a person.
export type EinvQueue = {
  waiting: number; oldest_at: string | null; signed_today: number; signed: number; refused: number; pay_waiting: number;
  attention: { sale_id: string; number: string; doc_type: string; customer_name: string | null; total: number; state: string; held: boolean; note: string | null; tries: number; at: string }[];
};
export type NrsCode = { code: string; label: string | null };
export type HsBasis = { source?: 'gemini' | 'manual'; code?: string | null; reason?: string | null; confidence?: number; by?: string; at?: string };
export type ItemHs = { hs_code: string | null; hs_basis: HsBasis | null; hs_review: boolean; hs_checked_at: string | null };

// Only people who change settings, keep the books or file tax see e-invoicing; for anyone else this stays empty.
export function useEinvoice(orgId: string | null | undefined) {
  return useQuery({ queryKey: ['einvoice', orgId], enabled: !!orgId, retry: false, staleTime: 15_000,
    queryFn: () => rpc<EinvSettings>('einvoice_settings_get', { p_org: orgId }) });
}

export function useNrsCodes(list: 'hs-codes' | 'services-codes', q: string) {
  const term = q.trim();
  return useQuery({ queryKey: ['nrs-codes', list, term], enabled: term.length >= 2, staleTime: 60_000, placeholderData: (prev) => prev,
    queryFn: () => rpc<NrsCode[]>('nrs_code_search', { p_list: list, p_q: term, p_limit: 20 }) });
}

// An item's HS code, straight from the item (members read their own items).
export function useItemHs(itemId: string) {
  return useQuery({ queryKey: ['item-hs', itemId], queryFn: async () => {
    const { data, error } = await supabase.from('items').select('hs_code, hs_basis, hs_review, hs_checked_at').eq('id', itemId).single();
    if (error) throw error;
    return data as ItemHs;
  } });
}

// NRS's words for one code.
export function useNrsLabel(list: 'hs-codes' | 'services-codes', code: string | null | undefined) {
  return useQuery({ queryKey: ['nrs-label', list, code], enabled: !!code, staleTime: 300_000, queryFn: async () => {
    const { data } = await supabase.from('nrs_codes').select('label').eq('list', list).eq('code', code!).maybeSingle();
    return (data?.label as string | null) ?? null;
  } });
}
