// Phone calls placed by Martina through ElevenLabs Agents (see supabase/functions/voice).
import { useEffect, useRef } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { cleanError, supabase } from './supabase';
import { useSession } from '../state/session';

export type CallStatus = 'queued' | 'ringing' | 'in_progress' | 'processing' | 'completed' | 'no_answer' | 'busy' | 'voicemail' | 'failed';
export type ReminderTopic = 'count_approval' | 'count_due' | 'receipts_review' | 'transfer_confirm' | 'price_proposals';

export interface VoiceCall {
  id: string; org_id: string; kind: 'vendor_order' | 'reminder'; po_id: string | null; vendor_id: string | null; member_id: string | null;
  topic: ReminderTopic | null; to_number: string; variables: Record<string, string>; status: CallStatus; conversation_id: string | null;
  outcome: Record<string, unknown>; summary: string | null; transcript: { role: 'agent' | 'user'; text: string; t?: number }[] | null;
  duration_secs: number | null; error: string | null; created_by: string | null; created_at: string; ended_at: string | null; synced_at: string | null;
}

export interface VoiceStatus {
  ok: boolean; configured: boolean; reason?: 'no_key' | 'no_number' | 'error' | null; message?: string;
  phone?: { label?: string; number?: string; provider?: string } | null;
}

export const ACTIVE: CallStatus[] = ['queued', 'ringing', 'in_progress', 'processing'];

export const CALL_STATUS: Record<CallStatus, { label: string; t: string }> = {
  queued: { label: 'Dialling', t: 't-blue' },
  ringing: { label: 'Ringing', t: 't-blue' },
  in_progress: { label: 'On the call', t: 't-purple' },
  processing: { label: 'Wrapping up', t: 't-purple' },
  completed: { label: 'Done', t: 't-green' },
  no_answer: { label: 'No answer', t: 't-amber' },
  busy: { label: 'Line busy', t: 't-amber' },
  voicemail: { label: 'Voicemail', t: 't-amber' },
  failed: { label: 'Failed', t: 't-red' },
};

export const TOPICS: { id: ReminderTopic; label: string; who: string }[] = [
  { id: 'count_approval', label: 'Counts waiting for approval', who: 'Owners and managers who approve adjustments' },
  { id: 'count_due', label: 'A stock count to finish', who: 'The person assigned to the count' },
  { id: 'receipts_review', label: 'Invoices to confirm', who: 'Whoever posts receipts' },
  { id: 'transfer_confirm', label: 'A transfer to receive', who: 'Staff at the receiving branch' },
  { id: 'price_proposals', label: 'Price checks to decide', who: 'Whoever sets prices' },
];

export async function voice<T = any>(action: string, payload: Record<string, unknown> = {}): Promise<T & { ok?: boolean; reason?: string; error?: string }> {
  const { data, error } = await supabase.functions.invoke('voice', { body: { action, ...payload } });
  if (error) {
    let body: any = null;
    try { body = await (error as any).context?.json?.(); } catch { /* ignore */ }
    if (body) return body;
    return { ok: false, reason: 'error', error: cleanError(error) } as any;
  }
  return data as any;
}

export function useVoiceStatus(enabled = true) {
  return useQuery({
    queryKey: ['voice-status'],
    queryFn: () => voice<VoiceStatus>('status') as Promise<VoiceStatus>,
    staleTime: 5 * 60_000,
    enabled,
  });
}

// Recent calls for the business, or for one order or person. Polls while a call is live and asks the
// server to refresh any live call it has not checked in the last 15 seconds.
export function useVoiceCalls(filter: { po_id?: string; member_id?: string; limit?: number } = {}, enabled = true) {
  const { orgId } = useSession();
  const qc = useQueryClient();
  const q = useQuery({
    queryKey: ['voice-calls', orgId, filter.po_id || null, filter.member_id || null, filter.limit || 20],
    enabled: enabled && !!orgId,
    queryFn: async () => {
      let s = supabase.from('voice_calls').select('*').eq('org_id', orgId!).order('created_at', { ascending: false }).limit(filter.limit || 20);
      if (filter.po_id) s = s.eq('po_id', filter.po_id);
      if (filter.member_id) s = s.eq('member_id', filter.member_id);
      const { data, error } = await s;
      if (error) throw new Error(cleanError(error));
      return (data || []) as VoiceCall[];
    },
    refetchInterval: (query) => ((query.state.data as VoiceCall[] | undefined) || []).some((c) => ACTIVE.includes(c.status)) ? 4000 : false,
  });
  const inflight = useRef(new Set<string>());
  useEffect(() => {
    const stale = (q.data || []).filter((c) => ACTIVE.includes(c.status) && c.conversation_id && !inflight.current.has(c.id)
      && (!c.synced_at || Date.now() - new Date(c.synced_at).getTime() > 15_000));
    for (const c of stale.slice(0, 3)) {
      inflight.current.add(c.id);
      voice('sync', { call_id: c.id })
        .finally(() => { inflight.current.delete(c.id); qc.invalidateQueries({ queryKey: ['voice-calls'] }); });
    }
  }, [q.dataUpdatedAt]); // eslint-disable-line react-hooks/exhaustive-deps
  return q;
}

export function callDuration(s: number | null): string {
  if (!s) return '';
  const m = Math.floor(s / 60);
  return m ? `${m} min ${s % 60 ? (s % 60) + ' s' : ''}`.trim() : `${s} s`;
}

const yes = (v: unknown) => v === true || /^(true|yes)$/i.test(String(v ?? ''));
const text = (v: unknown) => (v == null || v === '' || /^(null|none|n\/a)$/i.test(String(v)) ? '' : String(v));

// One line a busy owner can read in the list.
export function callHeadline(c: VoiceCall): string {
  const o = c.outcome || {};
  if (ACTIVE.includes(c.status)) return CALL_STATUS[c.status].label + '…';
  if (c.status === 'failed') return c.error || 'The call did not go through.';
  if (c.status !== 'completed') return CALL_STATUS[c.status].label + '. Try again later.';
  if (c.kind === 'vendor_order') {
    if (yes(o.order_confirmed)) return 'Order confirmed' + (text(o.delivery_date) ? `, delivery ${text(o.delivery_date)}` : '') + '.';
    if (text(o.callback_time)) return `Asked for a callback ${text(o.callback_time)}.`;
    return 'Vendor did not confirm the order.';
  }
  if (yes(o.will_act)) return 'Said they will do it' + (text(o.when) ? ` ${text(o.when)}` : '') + '.';
  return 'Did not commit to a time.';
}

export function callDetails(c: VoiceCall): { label: string; value: string }[] {
  const o = c.outcome || {};
  const rows: { label: string; value: string }[] = [];
  const add = (label: string, v: unknown) => { const t = text(v); if (t) rows.push({ label, value: t }); };
  if (c.kind === 'vendor_order') {
    add('Delivery', o.delivery_date);
    add('Not available', o.unavailable_items);
    add('Price changes', o.price_changes);
    add('Call back', o.callback_time);
  } else {
    add('When', o.when);
  }
  add('Notes', o.notes);
  return rows;
}
