// Per-device, append-only queue. Movements captured offline post in the order they were made, with the
// original timestamp and a client UUID so a retried sync can never post twice.
import { useEffect, useState, useSyncExternalStore } from 'react';
import { del, get, set } from 'idb-keyval';
import { rpc } from '../lib/supabase';
import { readInvoice, startReceipt, uploadDocument, type Source } from '../lib/receive';
import { uuid } from '../lib/format';

export type OpKind = 'sale' | 'till' | 'quick_sale' | 'count' | 'receipt' | 'transfer_receive' | 'issue';
export interface Op {
  id: string; org: string; kind: OpKind; label: string; detail: string; created_at: string; queued_offline: boolean;
  status: 'queued' | 'posting' | 'posted' | 'failed'; error?: string; result?: string; payload: any; author: string;
}

const KEY = 'counta.queue.v1';
const listeners = new Set<() => void>();
let cache: Op[] = [];
let loaded = false;
let syncing = false;
// Set when something is queued while a sync is posting, so that sync goes round again instead of leaving it for the next tick.
let again = false;
let lastSync: { at: number; n: number } | null = null;

export function deviceId(): string {
  try {
    let d = localStorage.getItem('counta.device');
    if (!d) { d = 'web-' + uuid().slice(0, 8); localStorage.setItem('counta.device', d); }
    return d;
  } catch { return 'web-unknown'; }
}

function emit() { listeners.forEach((f) => f()); }
async function load() {
  if (loaded) return cache;
  try { cache = (await get(KEY)) || []; } catch { cache = []; }
  loaded = true; emit();
  return cache;
}
async function persist(ops: Op[]) {
  cache = ops;
  try { await set(KEY, ops.filter((o, i) => o.status !== 'posted' || i >= ops.length - 60)); } catch { /* storage full: keep in memory */ }
  emit();
}
async function patch(id: string, p: Partial<Op>) { await persist(cache.map((o) => (o.id === id ? { ...o, ...p } : o))); }

export async function enqueue(op: Omit<Op, 'id' | 'created_at' | 'status' | 'queued_offline'> & { id?: string }, blob?: Blob): Promise<Op> {
  await load();
  const full: Op = { ...op, id: op.id || uuid(), created_at: new Date().toISOString(), status: 'queued', queued_offline: !navigator.onLine } as Op;
  if (blob) await set('counta.blob.' + full.id, blob);
  await persist([...cache, full]);
  if (navigator.onLine) void syncAll();
  return full;
}

export async function discard(id: string) {
  await del('counta.blob.' + id).catch(() => {});
  await persist(cache.filter((o) => o.id !== id));
}
export async function retry(id: string) { await patch(id, { status: 'queued', error: undefined }); void syncAll(); }

const isNetwork = (e: any) => !navigator.onLine || /Failed to fetch|NetworkError|Load failed|No connection|network/i.test(String(e?.message || e));

async function runOp(op: Op): Promise<string> {
  const p = op.payload;
  switch (op.kind) {
    case 'sale': {
      const r = await rpc<any>('record_sale', {
        p_org: op.org, p_item: p.item_id, p_location: p.location_id, p_qty: p.qty, p_unit_price: p.unit_price ?? null, p_channel: p.channel || 'Phone app',
        p_voice: !!p.voice, p_note: p.note ?? null, p_voice_clean: p.voice_clean ?? true, p_client_uuid: op.id, p_device: deviceId(),
        p_offline: op.queued_offline, p_recorded_at: op.created_at,
      });
      return r?.journal_ref ? `Posted · ${r.journal_ref}${r.review_status === 'pending' ? ' · owner will review' : ''}` : 'Posted';
    }
    case 'till': {
      // A basket scanned at the phone till: one receipt, paid in full by one method. The client UUID keeps a retry from posting twice.
      const r = await rpc<any>('till_checkout', { p_org: op.org, p_sale: {
        client_uuid: op.id, location_id: p.location_id, channel: 'phone', recorded_at: op.created_at, device: deviceId(), offline: op.queued_offline,
        lines: p.lines, pay_in_full: p.method, notes: p.note ?? null,
      } });
      return r?.number ? `Posted · ${r.number}${p.method === 'cash' ? '' : ' · payment to confirm'}` : 'Posted';
    }
    case 'quick_sale': {
      // One sale of one or more products, with the customer's name when given, paid now or to settle later in Sales.
      const r = await rpc<any>('record_quick_sale', { p_org: op.org, p: { ...p, client_uuid: op.id, device: deviceId(), offline: op.queued_offline, recorded_at: op.created_at } });
      if (r?.duplicate) return `Already posted · ${r.number}`;
      return `Posted · ${r.number}${r.settle_later ? ' · to settle in Sales' : p.pay && p.pay !== 'cash' ? ' · payment to confirm' : ''}${r.review_status === 'pending' ? ' · owner will review' : ''}`;
    }
    case 'count': {
      const r = await rpc<any>('submit_count', { p_session: p.session_id, p_lines: p.lines, p_device: deviceId(), p_offline: op.queued_offline, p_client_uuid: op.id });
      const n = (r?.variances || []).length;
      return r?.duplicate ? 'Already submitted' : n ? `Submitted · ${n} difference${n === 1 ? '' : 's'} for the owner` : 'Submitted · no differences';
    }
    case 'issue': {
      const r = await rpc<any>('issue_materials', { p_job: p.job_id, p_lines: p.lines, p_return: false, p_client_uuid: op.id, p_device: deviceId(),
        p_offline: op.queued_offline, p_recorded_at: op.created_at });
      if (r?.duplicate) return 'Already posted';
      return `Posted · ${r.journal_ref}${r.warnings?.length ? ' · below zero on the books, count soon' : ''}`;
    }
    case 'transfer_receive': {
      try { const ref = await rpc<string>('receive_transfer', { p_transfer: p.transfer_id }); return `Received · ${ref}`; }
      catch (e: any) { if (/already received/i.test(e.message)) return 'Already received'; throw e; }
    }
    case 'receipt': {
      let path: string | null = p.path || null; let mime: string | null = p.mime || null;
      if (!path) {
        const blob = await get<Blob>('counta.blob.' + op.id);
        if (!blob) throw new Error('The photo is no longer on this phone. Take it again.');
        const up = await uploadDocument(op.org, blob, p.name || 'invoice.jpg');
        path = up.path; mime = up.mime;
        await patch(op.id, { payload: { ...p, path, mime } });
      }
      const r = await startReceipt({ orgId: op.org, mode: p.mode as Source, path, mime, location: p.location_id, clientUuid: op.id, device: deviceId(), offline: op.queued_offline });
      if (r.status === 'reading') await readInvoice(r.id);
      await del('counta.blob.' + op.id).catch(() => {});
      return `${r.ref} · waiting for review in Receive stock`;
    }
  }
}

export async function syncAll(): Promise<void> {
  await load();
  if (!navigator.onLine) return;
  if (syncing) { again = true; return; }
  const todo = cache.filter((o) => o.status === 'queued').sort((a, b) => a.created_at.localeCompare(b.created_at));
  if (!todo.length) return;
  syncing = true; again = false; emit();
  let n = 0, offline = false;
  try {
    for (const op of todo) {
      await patch(op.id, { status: 'posting' });
      try {
        const result = await runOp(op);
        await patch(op.id, { status: 'posted', result, error: undefined });
        n++;
      } catch (e: any) {
        if (isNetwork(e)) { await patch(op.id, { status: 'queued' }); offline = true; break; }
        await patch(op.id, { status: 'failed', error: String(e?.message || e) });
      }
    }
  } finally {
    syncing = false;
    if (n) lastSync = { at: Date.now(), n };
    emit();
  }
  // Several sales recorded at once arrive while the first is posting; they go now, in order, not at the next tick.
  if (again && !offline) { again = false; await syncAll(); }
}

function snapshot() { return { ops: cache, syncing, lastSync }; }
let snap = snapshot();
listeners.add(() => { snap = snapshot(); });
function subscribe(f: () => void) { listeners.add(f); return () => { listeners.delete(f); }; }

export function useQueue(org: string | null) {
  const s = useSyncExternalStore(subscribe, () => snap);
  const [online, setOnline] = useState(typeof navigator === 'undefined' ? true : navigator.onLine);
  useEffect(() => {
    void load().then(() => { if (navigator.onLine) void syncAll(); });
    const on = () => { setOnline(true); void syncAll(); };
    const off = () => setOnline(false);
    window.addEventListener('online', on); window.addEventListener('offline', off);
    const t = window.setInterval(() => { if (navigator.onLine) void syncAll(); }, 30_000);
    return () => { window.removeEventListener('online', on); window.removeEventListener('offline', off); window.clearInterval(t); };
  }, []);
  const ops = s.ops.filter((o) => !org || o.org === org);
  const pending = ops.filter((o) => o.status === 'queued' || o.status === 'posting');
  const failed = ops.filter((o) => o.status === 'failed');
  return { ops, pending, failed, syncing: s.syncing, lastSync: s.lastSync, online, sync: syncAll };
}
