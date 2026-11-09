// Counta POS terminals (docs/pos-terminals.md): a business's Moniepoint account and its terminals. The till sends a sale's amount
// to a terminal, the customer pays there by card or transfer, and Moniepoint's own record of the payment closes the sale.
// Payments keyed on a terminal by hand reach Counta through the same webhook and are matched in the database.
//
// Signed-in callers (Authorization: Bearer <user JWT>), POST { action, ... }:
//   connect { org_id, key, business_id?, bank_account_id?, account_number? } -> checks the key with Moniepoint (the owner only), subscribes
//                     Counta to the terminals' payments and keeps the key and the webhook secret in Vault. With a key for several
//                     businesses and none chosen, answers { choose: [{ id, name }] }.
//   test_key { connection_id }      -> asks Moniepoint whether the key still works
//   disconnect { connection_id }    -> removes the webhook at Moniepoint and wipes the keys
//   push { request_id }             -> sends a request the till opened to its terminal (once)
//   check { request_id }            -> asks Moniepoint how a request went and records the payment when it is approved
// Moniepoint (no sign-in): POST /pos/webhook/moniepoint/<token>, with Basic auth when set and the moniepoint-webhook-signature header
// Database cron (x-counta-hook: <PUSH_HOOK_SECRET>): { action: 'poll' } every two minutes: requests still waiting on a terminal,
//                     and each account's event history every six hours (anything a webhook missed).
//
// Money is recorded from Moniepoint's own answer for a sale Counta sent (GET /v1/transactions/merchants/{reference}); a payment keyed
// by hand is recorded on the strength of its HMAC signature, and its event is then looked up at Moniepoint for the record.
import { createClient } from 'npm:@supabase/supabase-js@2';
import * as mp from './moniepoint.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
// Sandbox keys see no real payments; only the test harness accepts them.
const ALLOW_SANDBOX = Deno.env.get('POS_ALLOW_SANDBOX') === '1';
const admin = createClient(SUPABASE_URL, SERVICE, { auth: { persistSession: false } });
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-counta-hook',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
class UserError extends Error {}

async function svc<T = any>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await admin.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data as T;
}
async function asUser<T = any>(sb: any, fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await sb.rpc(fn, args);
  if (error) throw new UserError(error.message);
  return data as T;
}
async function hookSecret(): Promise<string> {
  const env = (Deno.env.get('PUSH_HOOK_SECRET') || '').trim();
  if (env) return env;
  const { data } = await admin.rpc('app_secret', { p_name: 'PUSH_HOOK_SECRET' });
  return typeof data === 'string' ? data.trim() : '';
}
function same(a: string, b: string) {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  if (x.length !== y.length) return false;
  let r = 0;
  for (let i = 0; i < x.length; i++) r |= x[i] ^ y[i];
  return r === 0;
}
const randomHex = (n: number) => Array.from(crypto.getRandomValues(new Uint8Array(n))).map((b) => b.toString(16).padStart(2, '0')).join('');
const hookUrl = (tok: string) => `${SUPABASE_URL}/functions/v1/pos/webhook/moniepoint/${tok}`;
// Work that should not hold up a webhook reply.
function later(p: Promise<unknown>) {
  const rt = (globalThis as any).EdgeRuntime;
  const guarded = p.catch((e) => console.log('pos background', (e as Error).message));
  if (rt?.waitUntil) rt.waitUntil(guarded);
  return guarded;
}
const lagosDay = (d: Date) => new Date(d.getTime() + 3600_000).toISOString().slice(0, 10);

// A refused key needs the owner now; anything else is noted, and becomes a warning only if it keeps happening.
async function noteError(connectionId: string, e: unknown) {
  const err = e as mp.MpError;
  await svc('svc_pos_note', { p_connection: connectionId, p: { error: err.message, hard: Boolean(err.hard) } }).catch(() => {});
}

// ------------------------------------------------------------------ connecting
async function connect(sb: any, b: any) {
  const check = await asUser<any>(sb, 'pos_connect_check', { p_org: b.org_id });
  const key = String(b.key || '').trim();
  if (key.length < 16 || key.length > 600 || /\s/.test(key)) throw new UserError('Paste the API key exactly as the Moniepoint Business app showed it.');
  const intro = await mp.introspect(key);
  if (intro.environment === 'sandbox' && !ALLOW_SANDBOX) {
    throw new UserError('This is a sandbox key, which sees no real payments. Create a key for the live environment in the Moniepoint Business app.');
  }
  const missing = mp.MP_SCOPES.filter((s) => !intro.scopes.includes(s));
  if (missing.length) {
    throw new UserError(`The key is missing ${missing.length === 1 ? 'a permission' : 'permissions'} Counta needs: ${missing.join(', ')}. Create a new key with them ticked.`);
  }
  if (!intro.businesses.length) throw new UserError('The key is not linked to a business. Link it to your business in the Moniepoint Business app.');
  let biz = intro.businesses.find((x) => x.id === String(b.business_id || ''));
  if (!biz && intro.businesses.length === 1) biz = intro.businesses[0];
  if (!biz) return { ok: true, choose: intro.businesses };
  const old = (check.connections || []).find((c: any) => c.provider === 'moniepoint' && String(c.business_ref || '') === biz!.id) || null;
  const oldFull = old ? await svc<any>('svc_pos_connection', { p_connection: old.id }) : null;
  const token = randomHex(24), password = randomHex(18);
  const subId = await mp.createSubscription(key, biz.id, hookUrl(token));
  let secret: string;
  let usePassword = true;
  try {
    secret = await mp.subscriptionSecret(key, subId);
  } catch (e) {
    await mp.deleteSubscription(key, subId).catch(() => {});
    throw e;
  }
  // Basic auth on the webhook is a second lock; the signature is the first. If Moniepoint will not set it, the signature alone guards it.
  try { await mp.setBasicAuth(key, subId, 'counta', password); } catch (e) { usePassword = false; console.log('pos basic auth', (e as Error).message); }
  const saved = await svc<any>('svc_pos_connection_save', { p: {
    org_id: b.org_id, member_id: check.member_id, provider: 'moniepoint', label: 'Moniepoint', environment: intro.environment, business_ref: biz.id,
    business_name: biz.name, scopes: intro.scopes, key, key_hint: key.slice(-4), hook_token: token, hook_secret: secret,
    hook_password: usePassword ? password : '', subscription_ref: subId, bank_account_id: b.bank_account_id || null,
    account_number: b.account_number ? String(b.account_number).replace(/\D/g, '').slice(0, 10) : null } });
  // The subscription the old key made stops, so Moniepoint does not send every payment twice.
  if (oldFull?.subscription_ref && oldFull.subscription_ref !== subId) {
    await mp.deleteSubscription(key, oldFull.subscription_ref).catch((e) => console.log('pos old subscription', (e as Error).message));
  }
  return { ok: true, connection: saved };
}

async function disconnect(sb: any, b: any) {
  const c = await asUser<any>(sb, 'pos_connection_manage', { p_connection: b.connection_id });
  const full = await svc<any>('svc_pos_connection', { p_connection: c.id });
  let warning: string | null = null;
  if (full?.key && full.subscription_ref) {
    try { await mp.deleteSubscription(full.key, full.subscription_ref); }
    catch { warning = 'Moniepoint did not confirm it stopped sending payments; Counta ignores them from now on.'; }
  }
  await svc('svc_pos_remove', { p_connection: c.id });
  return { ok: true, warning };
}

async function testKey(sb: any, b: any) {
  const c = await asUser<any>(sb, 'pos_connection_manage', { p_connection: b.connection_id });
  const full = await svc<any>('svc_pos_connection', { p_connection: c.id });
  try {
    const intro = await mp.introspect(full.key);
    const missing = mp.MP_SCOPES.filter((s) => !intro.scopes.includes(s));
    const known = intro.businesses.some((x) => x.id === String(full.business_ref || ''));
    const problem = !known ? 'The key no longer covers this business.' : missing.length ? `The key lost permissions: ${missing.join(', ')}.` : null;
    await svc('svc_pos_note', { p_connection: c.id, p: { error: problem, hard: Boolean(problem) } });
    return { ok: !problem, error: problem, environment: intro.environment };
  } catch (e) {
    await noteError(c.id, e);
    return { ok: false, error: (e as Error).message };
  }
}

// ------------------------------------------------------------------ the till
async function pushRequest(requestId: string) {
  const ctx = await svc<any>('svc_pos_request_context', { p_request: requestId });
  if (!ctx) throw new UserError('Request not found.');
  if (ctx.status !== 'creating') return ctx;
  const conn = await svc<any>('svc_pos_connection', { p_connection: ctx.connection_id });
  if (!conn?.key) {
    return await svc('svc_pos_request_update', { p_request: requestId, d: { status: 'failed', error: 'The terminal is not connected any more.' } });
  }
  const unit = conn.amount_unit === 'naira' ? 'naira' : 'kobo';
  try {
    await mp.push(conn.key, { terminalSerial: ctx.terminal_serial, amount: mp.minor(Number(ctx.amount), unit), merchantReference: ctx.reference,
      paymentMethod: mp.METHOD[(ctx.pay_method || 'any') as keyof typeof mp.METHOD] || 'ANY' });
    return await svc('svc_pos_request_update', { p_request: requestId, d: { status: 'sent', error: null } });
  } catch (e) {
    const err = e as mp.MpError;
    if (err.hard) await noteError(ctx.connection_id, e);
    // No answer: the amount may have reached the terminal. Moniepoint is asked before the request is given up.
    if (!err.status || err.status >= 500) {
      const s = await mp.status(conn.key, ctx.reference).catch(() => null);
      if (s) return await svc('svc_pos_request_update', { p_request: requestId, d: { status: 'sent', error: null } });
    }
    return await svc('svc_pos_request_update', { p_request: requestId, d: { status: 'failed', error: err.message } });
  }
}

const lastCheck = new Map<string, number>();
// Asks Moniepoint about a request and records what it says. The till asks every few seconds; Moniepoint is asked at most every 3.
async function checkRequest(requestId: string) {
  const ctx = await svc<any>('svc_pos_request_context', { p_request: requestId });
  if (!ctx || ctx.status !== 'sent') return ctx;
  const seen = lastCheck.get(requestId) || 0;
  if (Date.now() - seen < 3000) return ctx;
  lastCheck.set(requestId, Date.now());
  if (lastCheck.size > 5000) lastCheck.clear();
  const conn = await svc<any>('svc_pos_connection', { p_connection: ctx.connection_id });
  if (!conn?.key) return ctx;
  const unit = conn.amount_unit === 'naira' ? 'naira' : 'kobo';
  let s: any;
  try { s = await mp.status(conn.key, ctx.reference); }
  catch (e) {
    if ((e as mp.MpError).hard) await noteError(ctx.connection_id, e);
    return await svc('svc_pos_request_update', { p_request: requestId, d: { checked: true } });
  }
  if (!s) return await svc('svc_pos_request_update', { p_request: requestId, d: { checked: true } });
  const t = mp.fromStatus(s, unit);
  if (t.transaction_ref && t.status !== 'pending') {
    await svc('svc_pos_transaction', { p_connection: ctx.connection_id, d: { ...t, merchant_reference: ctx.reference, verified: 'status_api' } });
  } else if (t.status === 'declined') {
    await svc('svc_pos_request_update', { p_request: requestId, d: { status: 'declined', response_code: t.response_code, response_message: t.response_message,
      checked: true } });
  } else {
    await svc('svc_pos_request_update', { p_request: requestId, d: { checked: true } });
  }
  return await svc('svc_pos_request_context', { p_request: requestId });
}

// ------------------------------------------------------------------ Moniepoint's webhook
async function moniepointWebhook(req: Request, token: string) {
  const raw = await req.text();
  if (raw.length > 65_536) return json({ ok: false }, 413);
  const id = await svc<string | null>('svc_pos_by_token', { p_provider: 'moniepoint', p_token: token });
  if (!id) return json({ ok: false }, 404);
  const conn = await svc<any>('svc_pos_connection', { p_connection: id });
  if (!conn?.hook_secret) return json({ ok: false }, 404);
  if (conn.hook_password) {
    const want = 'Basic ' + btoa(`counta:${conn.hook_password}`);
    if (!same(req.headers.get('authorization') || '', want)) return json({ ok: false }, 401);
  }
  const hid = req.headers.get('moniepoint-webhook-id') || '', ts = req.headers.get('moniepoint-webhook-timestamp') || '';
  if (!(await mp.signatureOk(conn.hook_secret, hid, ts, raw, req.headers.get('moniepoint-webhook-signature') || ''))) return json({ ok: false }, 401);
  // A signed event weeks old is a replay, not news.
  if (Number(ts) && Math.abs(Date.now() - Number(ts)) > 7 * 86_400_000) return json({ ok: false, error: 'stale' }, 400);
  let body: any;
  try { body = JSON.parse(raw); } catch { return json({ ok: false }, 400); }
  await svc('svc_pos_note', { p_connection: id, p: { event: true } });
  const unit = conn.amount_unit === 'naira' ? 'naira' : 'kobo';
  const t = mp.fromEvent(body, unit);
  if (!t) return json({ ok: true, ignored: true });
  if (t.business_id && conn.business_ref && t.business_id !== String(conn.business_ref)) return json({ ok: true, ignored: 'another business' });
  if (!t.event_id) t.event_id = hid;
  // A sale Counta sent: Moniepoint's own record decides. Anything else: recorded now, and its event looked up for the record.
  const ours = t.merchant_reference && /^CNP[A-Z0-9]{16}$/.test(t.merchant_reference);
  if (ours) {
    later(confirmOurs(id, conn, t, unit));
    return json({ ok: true, queued: true });
  }
  const res = await svc<any>('svc_pos_transaction', { p_connection: id, d: { ...t, verified: 'signature' } });
  if (res?.ok && t.status === 'approved' && t.event_id) later(lookUpEvent(id, conn, t, unit));
  return json({ ok: true, outcome: res?.outcome || null });
}

async function confirmOurs(id: string, conn: any, t: mp.Txn, unit: 'kobo' | 'naira') {
  let s: any = null;
  try { s = await mp.status(conn.key, t.merchant_reference!); } catch (e) { console.log('pos confirm', (e as Error).message); }
  if (s) {
    const v = mp.fromStatus(s, unit);
    if (v.transaction_ref && v.status !== 'pending') {
      await svc('svc_pos_transaction', { p_connection: id, d: { ...v, merchant_reference: t.merchant_reference, event_id: t.event_id, event_type: t.event_type,
        verified: 'status_api' } });
      return;
    }
  }
  // Moniepoint has no record to read yet: what the signed event says is kept, and the poll asks again.
  if (t.status !== 'approved') await svc('svc_pos_transaction', { p_connection: id, d: { ...t, verified: 'signature' } });
}

async function lookUpEvent(id: string, conn: any, t: mp.Txn, unit: 'kobo' | 'naira') {
  const ev = await mp.eventById(conn.key, t.event_id!).catch(() => null);
  const v = ev ? mp.fromEvent(ev, unit) : null;
  if (v && v.transaction_ref === t.transaction_ref && Math.abs(v.amount - t.amount) < 0.005) {
    await svc('svc_pos_transaction', { p_connection: id, d: { ...t, verified: 'event_api' } });
  }
}

// ------------------------------------------------------------------ the schedule
async function pull(id: string) {
  const conn = await svc<any>('svc_pos_connection', { p_connection: id });
  if (!conn?.key || !conn.subscription_ref) return { pulled: 0 };
  const unit = conn.amount_unit === 'naira' ? 'naira' : 'kobo';
  const to = lagosDay(new Date()), from = lagosDay(new Date(Date.now() - 86_400_000));
  let n = 0;
  try {
    for (let page = 0; page < 20; page++) {
      const r = await mp.events(conn.key, conn.subscription_ref, from, to, page);
      for (const ev of r.content) {
        const t = mp.fromEvent(ev, unit);
        if (!t) continue;
        if (t.business_id && conn.business_ref && t.business_id !== String(conn.business_ref)) continue;
        const ours = t.merchant_reference && /^CNP[A-Z0-9]{16}$/.test(t.merchant_reference);
        if (ours) await confirmOurs(id, conn, t, unit);
        else await svc('svc_pos_transaction', { p_connection: id, d: { ...t, verified: 'pull' } });
        n++;
      }
      if (r.last) break;
    }
    await svc('svc_pos_note', { p_connection: id, p: { pulled: true, error: null } });
  } catch (e) {
    await noteError(id, e);
  }
  return { pulled: n };
}

async function poll() {
  const due = await svc<any>('svc_pos_due', {});
  const out = { checked: 0, pulled: 0, errors: 0 };
  const started = Date.now();
  for (const rid of (due?.requests || []) as string[]) {
    if (Date.now() - started > 40_000) break;
    try { await checkRequest(rid); out.checked++; } catch (e) { out.errors++; console.log('pos poll check', (e as Error).message); }
  }
  for (const cid of (due?.pulls || []) as string[]) {
    if (Date.now() - started > 50_000) break;
    try { out.pulled += (await pull(cid)).pulled; } catch (e) { out.errors++; console.log('pos poll pull', (e as Error).message); }
  }
  return out;
}

// ------------------------------------------------------------------ entry
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405);
  const path = new URL(req.url).pathname;
  try {
    const wh = path.match(/\/webhook\/moniepoint\/([a-f0-9]{48})\/?$/);
    if (wh) return await moniepointWebhook(req, wh[1]);
    if (/\/webhook\//.test(path)) return json({ ok: false }, 404);

    let body: any;
    try { body = await req.json(); } catch { return json({ ok: false, error: 'Invalid request.' }, 400); }
    const action = String(body.action || '');
    if (action === 'poll') {
      const hook = req.headers.get('x-counta-hook') || '';
      const want = await hookSecret();
      if (!hook || !want || !same(hook, want)) return json({ ok: false, error: 'Not allowed.' }, 401);
      return json({ ok: true, result: await poll() });
    }

    const sb = createClient(SUPABASE_URL, ANON, { global: { headers: { Authorization: req.headers.get('Authorization') || '' } }, auth: { persistSession: false } });
    const { data: u } = await sb.auth.getUser();
    if (!u?.user) return json({ ok: false, error: 'Sign in first.' }, 401);

    switch (action) {
      case 'connect': return json(await connect(sb, body));
      case 'disconnect': return json(await disconnect(sb, body));
      case 'test_key': return json(await testKey(sb, body));
      case 'push': {
        await asUser(sb, 'get_pos_request', { p_request: body.request_id });
        await pushRequest(String(body.request_id));
        return json({ ok: true, request: await asUser(sb, 'get_pos_request', { p_request: body.request_id }) });
      }
      case 'check': {
        await asUser(sb, 'get_pos_request', { p_request: body.request_id });
        await checkRequest(String(body.request_id));
        return json({ ok: true, request: await asUser(sb, 'get_pos_request', { p_request: body.request_id }) });
      }
      default: return json({ ok: false, error: 'Unknown action.' }, 400);
    }
  } catch (e) {
    if (e instanceof UserError || e instanceof mp.MpError) return json({ ok: false, error: (e as Error).message });
    console.log('pos error', (e as Error).message);
    return json({ ok: false, error: 'Something went wrong. Try again.' }, 500);
  }
});
