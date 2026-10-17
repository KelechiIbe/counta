// Counta bank feeds through Mono Connect: a business links its bank account once, and the account's transactions flow
// into Banking the way an uploaded statement does (same duplicate checks, same matching to invoices and bills).
//
// Signed-in callers (Authorization: Bearer <user JWT>), POST { action, ... }:
//   config { org_id }                                   -> whether Mono is set up, the public key and the customer for the widget
//   link { org_id, code, bank_account_id? }             -> exchanges the widget's code, links the account, fetches its transactions
//   sync { bank_account_id }                            -> fetches new transactions now (asks the bank for fresh data)
//   reauthorised { bank_account_id }                    -> after the person signed in to their bank again in the widget
//   unlink { bank_account_id }                          -> stops the feed at Mono and in Counta (lines already in stay)
// Mono:
//   POST /mono/webhook                                  -> header mono-webhook-secret must equal MONO_WEBHOOK_SECRET
// Database cron (header x-counta-hook: <PUSH_HOOK_SECRET>):
//   { action: 'sync_all' }                              -> fetches for every linked account, oldest first, for up to ~45 seconds
//
// Nothing a webhook says is taken as a transaction: it only tells Counta to fetch from Mono.
// Secrets (Edge Function secrets): MONO_SECRET_KEY, MONO_PUBLIC_KEY, MONO_WEBHOOK_SECRET. MONO_BASE_URL is for tests.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const MONO = (Deno.env.get('MONO_BASE_URL') || 'https://api.withmono.com').replace(/\/$/, '');
const admin = createClient(SUPABASE_URL, SERVICE, { auth: { persistSession: false } });

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-counta-hook, mono-webhook-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

class UserError extends Error {}
class ReauthNeeded extends UserError {}

const secrets = new Map<string, { v: string; at: number }>();
async function secret(name: string): Promise<string> {
  const env = Deno.env.get(name);
  if (env) return env.trim();
  const hit = secrets.get(name);
  if (hit && Date.now() - hit.at < 60_000) return hit.v;
  let v = '';
  const { data } = await admin.rpc('app_secret', { p_name: name });
  if (typeof data === 'string') v = data.trim();
  secrets.set(name, { v, at: Date.now() });
  return v;
}

function sameSecret(a: string, b: string) {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let d = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) d |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return d === 0;
}

async function svc<T = any>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await admin.rpc(fn, args);
  if (error) throw new UserError(error.message);
  return data as T;
}

// ------------------------------------------------------------------ Mono API
type MonoResult = { body: any; headers: Headers };
async function mono(path: string, init: RequestInit = {}): Promise<MonoResult> {
  const key = await secret('MONO_SECRET_KEY');
  if (!key) throw new UserError('Bank feeds are not switched on yet. Add MONO_SECRET_KEY and MONO_PUBLIC_KEY to the Supabase Edge Function secrets.');
  const res = await fetch(MONO + path, {
    ...init,
    headers: { 'mono-sec-key': key, accept: 'application/json', 'Content-Type': 'application/json', ...(init.headers || {}) },
    signal: AbortSignal.timeout(40_000),
  });
  const text = await res.text();
  let body: any = text;
  try { body = JSON.parse(text); } catch { /* not json */ }
  if (!res.ok || body?.status === 'failed' || body?.status === 'error') {
    const msg = String((typeof body === 'string' ? body : body?.message || body?.error || JSON.stringify(body)) || res.statusText).slice(0, 300);
    if (/re-?auth|reauthori[sz]ation|mfa|otp|token.*expired|login.*required/i.test(msg) || res.status === 428) throw new ReauthNeeded(`The bank asks for the login again: ${msg}`);
    throw new UserError(`Mono: ${msg}`);
  }
  return { body, headers: res.headers };
}

const kobo = (v: unknown): number | null => {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? Math.round(n) / 100 : null;
};
const ddmmyyyy = (d: Date) => `${String(d.getUTCDate()).padStart(2, '0')}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${d.getUTCFullYear()}`;
const isoDay = (v: unknown) => {
  const s = String(v || '');
  if (/^\d{4}-\d{2}-\d{2}/.test(s)) {
    // Mono gives the time in UTC; the business day is Lagos time (UTC+1).
    const t = Date.parse(s);
    if (!Number.isNaN(t) && s.length > 10) return new Date(t + 3600_000).toISOString().slice(0, 10);
    return s.slice(0, 10);
  }
  const m = s.match(/^(\d{2})-(\d{2})-(\d{4})/);
  return m ? `${m[3]}-${m[2]}-${m[1]}` : null;
};

async function accountDetails(monoId: string) {
  const { body } = await mono(`/v2/accounts/${encodeURIComponent(monoId)}`);
  const d = body?.data || {};
  const a = d.account || d;
  return {
    mono_id: monoId,
    account_number: String(a.account_number || a.accountNumber || ''),
    account_name: a.name || a.account_name || null,
    currency: String(a.currency || 'NGN').toUpperCase(),
    balance: kobo(a.balance),
    institution: { name: a.institution?.name || null, bank_code: a.institution?.bank_code || a.institution?.bankCode || null, type: a.institution?.type || null },
    data_status: d.meta?.data_status || a.meta?.data_status || null,
    auth_method: d.meta?.auth_method || a.meta?.auth_method || null,
  };
}

type FeedLine = { id: string; date: string; amount: number; narration: string; balance: number | null; category: string | null };
function toLine(t: any): FeedLine | null {
  const id = String(t.id || t._id || '');
  const amount = kobo(t.amount);
  const date = isoDay(t.date);
  if (!id || amount === null || !date) return null;
  const out = String(t.type || '').toLowerCase().startsWith('d');
  return { id, date, amount: out ? -Math.abs(amount) : Math.abs(amount), narration: String(t.narration || t.description || '').trim(), balance: kobo(t.balance),
    category: t.category && t.category !== 'unknown' ? String(t.category) : null };
}

// Pages of transactions between two days; Mono pages with meta.next (a full URL) or a page number.
async function transactions(monoId: string, from: Date, to: Date, realtime: boolean): Promise<{ lines: FeedLine[]; fresh: string | null }> {
  const lines: FeedLine[] = [];
  let fresh: string | null = null;
  let page = 1;
  for (let guard = 0; guard < 40; guard++) {
    const q = new URLSearchParams({ start: ddmmyyyy(from), end: ddmmyyyy(to), paginate: 'true', limit: '200', page: String(page) });
    const { body, headers } = await mono(`/v2/accounts/${encodeURIComponent(monoId)}/transactions?${q}`, { headers: realtime && page === 1 ? { 'x-realtime': 'true' } : {} });
    if (page === 1) fresh = headers.get('x-job-status');
    const rows: any[] = Array.isArray(body?.data) ? body.data : Array.isArray(body?.data?.transactions) ? body.data.transactions : [];
    for (const r of rows) { const l = toLine(r); if (l) lines.push(l); }
    const meta = body?.meta || body?.data?.meta || {};
    const next = meta.next || meta.next_page;
    if (!rows.length || !next) break;
    const n = typeof next === 'number' ? next : Number(new URL(String(next), MONO).searchParams.get('page'));
    if (!n || n <= page) break;
    page = n;
  }
  return { lines, fresh };
}

async function balance(monoId: string): Promise<number | null> {
  try {
    const { body } = await mono(`/v2/accounts/${encodeURIComponent(monoId)}/balance`);
    return kobo(body?.data?.balance ?? body?.data?.available_balance);
  } catch (e) {
    if (e instanceof ReauthNeeded) throw e;
    return null;
  }
}

type FeedAccount = { id: string; org_id: string; mono_id: string; last_line_date?: string | null; linked_at?: string | null; books_start?: string | null };
// Fetches from three days before the last line seen (banks post late), or, on the first fetch, from the start of the
// books or 90 days back, whichever is later, and at most a year back.
async function syncAccount(a: FeedAccount, realtime: boolean) {
  const to = new Date();
  const yearBack = new Date(Date.now() - 365 * 86400_000);
  let from: Date;
  if (a.last_line_date) from = new Date(Date.parse(a.last_line_date) - 3 * 86400_000);
  else {
    const ninety = new Date(Date.now() - 90 * 86400_000);
    const books = a.books_start ? new Date(Date.parse(a.books_start)) : null;
    from = books && books > ninety ? books : ninety;
  }
  if (from < yearBack) from = yearBack;
  try {
    const { lines, fresh } = await transactions(a.mono_id, from, to, realtime);
    const bal = await balance(a.mono_id);
    const res = await svc('svc_feed_import', { p_bank_account: a.id, p_lines: lines, p_meta: { balance: bal, data_status: null } });
    return { ...res, fetched: lines.length, fresh_data: fresh };
  } catch (e) {
    if (e instanceof ReauthNeeded) {
      await svc('svc_feed_status', { p_mono_id: a.mono_id, d: { reauth_required: true, data_status: 'REAUTHORISATION_REQUIRED', last_error: (e as Error).message } });
    } else {
      await svc('svc_feed_status', { p_mono_id: a.mono_id, d: { last_error: (e as Error).message, last_error_at: new Date().toISOString() } }).catch(() => null);
    }
    throw e;
  }
}

async function syncAll() {
  const started = Date.now();
  const accounts = await svc<any[]>('svc_feed_accounts', { p_org: null });
  const out = { accounts: accounts.length, synced: 0, added: 0, failed: 0, skipped: 0 };
  for (const a of accounts) {
    if (Date.now() - started > 45_000) break;
    if (a.reauth_required) { out.skipped++; continue; }
    try {
      const r: any = await syncAccount(a, false);
      out.synced++; out.added += Number(r.added || 0);
    } catch { out.failed++; }
  }
  return out;
}

// ------------------------------------------------------------------ webhook
async function webhook(req: Request) {
  const expected = await secret('MONO_WEBHOOK_SECRET');
  const got = req.headers.get('mono-webhook-secret') || '';
  if (!expected || !got || !sameSecret(expected, got)) return json({ ok: false, error: 'Not allowed.' }, 401);
  let b: any;
  try { b = await req.json(); } catch { return json({ ok: false, error: 'Invalid body.' }, 400); }
  const event = String(b.event || '');
  const d = b.data || {};
  const monoId = String(d.account?._id || d.account?.id || d.id || d.account || '');
  if (!monoId || typeof monoId !== 'string') return json({ ok: true, ignored: 'no account' });
  const acc = await svc<FeedAccount | null>('svc_feed_account', { p_mono_id: monoId });
  if (!acc) return json({ ok: true, ignored: 'not linked here' });
  const meta = d.meta || {};
  const status = String(meta.sync_status || meta.data_status || '').toUpperCase();
  if (/reauthori[sz]ation_required/i.test(event) || status === 'REAUTHORISATION_REQUIRED') {
    await svc('svc_feed_status', { p_mono_id: monoId, d: { reauth_required: true, data_status: 'REAUTHORISATION_REQUIRED' } });
    return json({ ok: true, reauth: true });
  }
  if (/unlinked/i.test(event)) {
    await svc('svc_feed_unlink', { p_bank_account: acc.id, p_reason: 'Unlinked at the bank or at Mono' });
    return json({ ok: true, unlinked: true });
  }
  if (/reauthori[sz]ed/i.test(event)) await svc('svc_feed_status', { p_mono_id: monoId, d: { reauth_required: false } });
  const ready = /account_updated|account_connected|reauthori[sz]ed/i.test(event) && (!status || ['AVAILABLE', 'PARTIAL', 'SUCCESSFUL'].includes(status))
    || (/jobs\.update/i.test(event) && /finished/i.test(String(d.status || meta.status || '')));
  if (!ready) {
    if (status) await svc('svc_feed_status', { p_mono_id: monoId, d: { data_status: status } });
    return json({ ok: true, waiting: status || event });
  }
  try {
    const r = await syncAccount(acc, false);
    return json({ ok: true, synced: r });
  } catch (e) {
    // Mono retries webhooks that fail; a fetch that failed is recorded on the account and picked up by the schedule.
    return json({ ok: true, error: (e as Error).message });
  }
}

// ------------------------------------------------------------------ entry
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405);
  const path = new URL(req.url).pathname;
  try {
    if (/\/webhook\/?$/.test(path)) return await webhook(req);
    let body: any;
    try { body = await req.json(); } catch { return json({ ok: false, error: 'Invalid request.' }, 400); }
    const action = String(body.action || '');

    if (action === 'sync_all') {
      const hook = req.headers.get('x-counta-hook') || '';
      const expected = await secret('PUSH_HOOK_SECRET');
      if (!hook || !expected || !sameSecret(hook, expected)) return json({ ok: false, error: 'Not allowed.' }, 401);
      return json({ ok: true, result: await syncAll() });
    }

    const sb: SupabaseClient = createClient(SUPABASE_URL, ANON, { global: { headers: { Authorization: req.headers.get('Authorization') || '' } }, auth: { persistSession: false } });
    const { data: u } = await sb.auth.getUser();
    if (!u?.user) return json({ ok: false, error: 'Sign in first.' }, 401);
    const mine = async <T = any>(fn: string, args: Record<string, unknown>): Promise<T> => {
      const { data, error } = await sb.rpc(fn, args);
      if (error) throw new UserError(error.message);
      return data as T;
    };

    switch (action) {
      case 'config': {
        const ctx = await mine('bank_feed_context', { p_org: body.org_id });
        const pub = await secret('MONO_PUBLIC_KEY');
        const sec = await secret('MONO_SECRET_KEY');
        return json({ ok: true, configured: Boolean(pub && sec), public_key: pub || null,
          customer: { name: ctx.org_name, email: ctx.email }, accounts: ctx.accounts, webhook_url: `${SUPABASE_URL}/functions/v1/mono/webhook`,
          webhook_secret_set: Boolean(await secret('MONO_WEBHOOK_SECRET')) });
      }
      case 'link': {
        const ctx = await mine('bank_feed_context', { p_org: body.org_id });
        const code = String(body.code || '');
        if (!code || code.length > 500) throw new UserError('The bank did not finish linking. Try again.');
        const { body: ex } = await mono('/v2/accounts/auth', { method: 'POST', body: JSON.stringify({ code }) });
        const monoId = String(ex?.data?.id || ex?.id || '');
        if (!monoId) throw new UserError('Mono did not return the account. Try linking again.');
        const det = await accountDetails(monoId);
        const linked: any = await svc('svc_feed_link', { p_org: body.org_id, p_member: ctx.member_id, p_bank_account: body.bank_account_id || null, d: det });
        let sync: unknown = null; let syncError: string | null = null;
        try {
          const acc = await svc<FeedAccount>('svc_feed_account', { p_mono_id: monoId });
          sync = await syncAccount({ ...acc, books_start: (await mine('bank_feed_account', { p_bank_account: acc.id })).books_start }, false);
        } catch (e) { syncError = (e as Error).message; }
        return json({ ok: true, account: linked, sync, sync_error: syncError,
          note: det.data_status && det.data_status !== 'AVAILABLE' ? 'The bank is still sending the history to Mono. Counta fetches it as soon as it arrives.' : null });
      }
      case 'sync': {
        const acc = await mine<any>('bank_feed_account', { p_bank_account: body.bank_account_id });
        if (acc.provider !== 'mono' || !acc.mono_id) throw new UserError('That account is not linked to a bank feed.');
        try {
          return json({ ok: true, sync: await syncAccount({ id: acc.id, org_id: acc.org_id, mono_id: acc.mono_id, last_line_date: acc.last_line_date, books_start: acc.books_start }, true) });
        } catch (e) {
          if (e instanceof ReauthNeeded) return json({ ok: false, reason: 'reauth', mono_id: acc.mono_id, error: 'The bank asks you to sign in again before it shares new transactions.' });
          throw e;
        }
      }
      case 'reauthorised': {
        const acc = await mine<any>('bank_feed_account', { p_bank_account: body.bank_account_id });
        if (acc.provider !== 'mono' || !acc.mono_id) throw new UserError('That account is not linked to a bank feed.');
        await svc('svc_feed_status', { p_mono_id: acc.mono_id, d: { reauth_required: false, data_status: 'AVAILABLE' } });
        try {
          return json({ ok: true, sync: await syncAccount({ id: acc.id, org_id: acc.org_id, mono_id: acc.mono_id, last_line_date: acc.last_line_date, books_start: acc.books_start }, false) });
        } catch (e) { return json({ ok: true, sync: null, sync_error: (e as Error).message }); }
      }
      case 'unlink': {
        const acc = await mine<any>('bank_feed_account', { p_bank_account: body.bank_account_id });
        if (acc.provider !== 'mono' || !acc.mono_id) throw new UserError('That account is not linked to a bank feed.');
        let atMono = true;
        try { await mono(`/v2/accounts/${encodeURIComponent(acc.mono_id)}/unlink`, { method: 'POST' }); } catch { atMono = false; }
        const res = await svc('svc_feed_unlink', { p_bank_account: acc.id, p_reason: `Unlinked by ${u.user.email || 'a member'}` });
        return json({ ok: true, account: res, unlinked_at_mono: atMono });
      }
      default: return json({ ok: false, error: 'Unknown action.' }, 400);
    }
  } catch (e) {
    if (e instanceof UserError) return json({ ok: false, error: e.message });
    console.error(e);
    return json({ ok: false, error: 'Something went wrong. Try again.' }, 500);
  }
});
