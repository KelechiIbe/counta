import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { must, rpc, supabase } from './supabase';
import { useSession, useToast } from '../state/session';
import type { CountSession, LedgerRow, PurchaseOrder, Proposal, Receipt, Transfer } from './types';
import type { DayImplied, DayRecorded, VendorStats } from './domain';

export function useLedger(loc: string, limit = 12) {
  const { orgId } = useSession();
  return useQuery({
    queryKey: ['ledger', orgId, loc, limit],
    enabled: !!orgId,
    queryFn: () => rpc<LedgerRow[]>('get_ledger', { p_org: orgId, p_limit: limit, p_location: loc === 'ALL' ? null : loc, p_grouped: true }),
  });
}
export function useActivity(limit = 40) {
  const { orgId } = useSession();
  return useQuery({
    queryKey: ['activity', orgId, limit],
    enabled: !!orgId,
    queryFn: () => rpc<LedgerRow[]>('get_ledger', { p_org: orgId, p_limit: limit, p_grouped: false }),
  });
}
export function useItemMoves(itemId: string | null) {
  const { orgId } = useSession();
  return useQuery({
    queryKey: ['itemMoves', orgId, itemId],
    enabled: !!orgId && !!itemId,
    queryFn: () => rpc<LedgerRow[]>('get_ledger', { p_org: orgId, p_limit: 40, p_item: itemId, p_grouped: false }),
  });
}
// A period (Lagos days) narrows a list to records made in it; without one the latest come back.
const dayStart = (d: string) => `${d}T00:00:00+01:00`;
const dayEnd = (d: string) => `${d}T23:59:59.999+01:00`;
type Range = { from: string; to: string } | null | undefined;

export function useReceipts(enabled = true, range?: Range) {
  const { orgId } = useSession();
  return useQuery({
    queryKey: ['receipts', orgId, range?.from || null, range?.to || null],
    enabled: !!orgId && enabled,
    queryFn: () => {
      let x = supabase.from('receipts').select('*, receipt_lines(id, confidence, confirmed)').eq('org_id', orgId!).neq('status', 'discarded');
      if (range) x = x.gte('created_at', dayStart(range.from)).lte('created_at', dayEnd(range.to));
      return must<Receipt[]>(x.order('created_at', { ascending: false }).limit(range ? 500 : 60));
    },
  });
}
export function useReceipt(id: string | null) {
  return useQuery({
    queryKey: ['receipt', id],
    enabled: !!id,
    queryFn: () => must<Receipt>(supabase.from('receipts').select('*, receipt_lines(*)').eq('id', id!).single()),
  });
}
export function useCounts(range?: Range) {
  const { orgId } = useSession();
  return useQuery({
    queryKey: ['counts', orgId, range?.from || null, range?.to || null],
    enabled: !!orgId,
    queryFn: () => {
      let x = supabase.from('count_sessions').select('*, count_lines(item_id, counted, expected, reason, note)').eq('org_id', orgId!);
      if (range) x = x.gte('created_at', dayStart(range.from)).lte('created_at', dayEnd(range.to));
      return must<CountSession[]>(x.order('created_at', { ascending: false }).limit(range ? 500 : 60));
    },
  });
}
export function useCountLines(sessionId: string | null, enabled: boolean) {
  return useQuery({
    queryKey: ['countLines', sessionId],
    enabled: !!sessionId && enabled,
    queryFn: () => must<any[]>(supabase.from('count_lines').select('*').eq('session_id', sessionId!)),
  });
}
export function useCountSheet(sessionId: string | null) {
  return useQuery({
    queryKey: ['countSheet', sessionId],
    enabled: !!sessionId,
    queryFn: () => rpc<any>('get_count_sheet', { p_session: sessionId }),
  });
}
export function useProposals() {
  const { orgId } = useSession();
  return useQuery({ queryKey: ['proposals', orgId], enabled: !!orgId, queryFn: () => rpc<Proposal[]>('get_price_proposals', { p_org: orgId }) });
}
export function usePOs(enabled = true) {
  const { orgId } = useSession();
  return useQuery({
    queryKey: ['pos', orgId],
    enabled: !!orgId && enabled,
    queryFn: () => must<PurchaseOrder[]>(supabase.from('purchase_orders').select('*, po_lines(*)').eq('org_id', orgId!).order('created_at', { ascending: false }).limit(40)),
  });
}
export function useTransfers() {
  const { orgId } = useSession();
  return useQuery({
    queryKey: ['transfers', orgId],
    enabled: !!orgId,
    queryFn: () => must<Transfer[]>(supabase.from('transfers').select('*').eq('org_id', orgId!).order('created_at', { ascending: false }).limit(40)),
  });
}
export function useCashVsStock(enabled = true) {
  const { orgId } = useSession();
  return useQuery({
    queryKey: ['cash', orgId],
    enabled: !!orgId && enabled,
    queryFn: () => rpc<{ implied: DayImplied[]; recorded: DayRecorded[] }>('get_cash_vs_stock', { p_org: orgId, p_days: 42 }),
  });
}
export function useVendorStats(enabled = true) {
  const { orgId } = useSession();
  return useQuery({ queryKey: ['vstats', orgId], enabled: !!orgId && enabled, queryFn: () => rpc<Record<string, VendorStats>>('get_vendor_stats', { p_org: orgId }) });
}
export function useFx() {
  return useQuery({
    queryKey: ['fx'],
    staleTime: 60 * 60 * 1000,
    queryFn: async () => {
      let rows = await must<{ day: string; usd_ngn: number }[]>(supabase.from('fx_rates').select('day, usd_ngn').order('day', { ascending: false }).limit(30));
      const latest = rows[0]?.day;
      const today = new Date().toISOString().slice(0, 10);
      if (!latest || latest < today) {
        try {
          await supabase.functions.invoke('fx', { body: {} });
          rows = await must(supabase.from('fx_rates').select('day, usd_ngn').order('day', { ascending: false }).limit(30));
        } catch { /* keep what we have */ }
      }
      return rows;
    },
  });
}

// Run an RPC/mutation, toast the result and refresh what it touched.
export function useAction() {
  const qc = useQueryClient();
  const toast = useToast();
  const m = useMutation({ mutationFn: async (fn: () => Promise<any>) => fn() });
  async function run<T>(fn: () => Promise<T>, opts: { ok?: string | ((r: T) => string); invalidate?: string[]; silent?: boolean; rethrow?: boolean } = {}): Promise<T | undefined> {
    try {
      const r = await m.mutateAsync(fn);
      if (opts.ok) toast(typeof opts.ok === 'function' ? opts.ok(r) : opts.ok);
      const keys = opts.invalidate ?? ['inv', 'ledger', 'activity'];
      await Promise.all(keys.map((k) => qc.invalidateQueries({ queryKey: [k] })));
      return r;
    } catch (e: any) {
      if (!opts.silent) toast(e?.message || 'Something went wrong.', 'err');
      if (opts.rethrow) throw e;
      return undefined;
    }
  }
  return { run, busy: m.isPending };
}
