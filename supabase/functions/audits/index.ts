// Counta audits: a partner firm's Flutterwave split, and a business's checkout for its audit fee with TaxStreem's referral
// fee split off at payment.
//
// Signed-in callers (Authorization: Bearer <user JWT>), POST { action, ... }:
//   subaccount { practice_id }  -> a partner sets up the firm's split on its confirmed payout account, or moves it to a new one
//   pay { engagement_id }        -> the business's owner or an admin pays an accepted audit: a Flutterwave checkout link
//   verify { tx_ref }            -> after the checkout: asks Flutterwave and records what it says
// Database cron (header x-counta-hook: <PUSH_HOOK_SECRET>):
//   { action: 'poll' }           -> asks Flutterwave about each checkout still open; gives one up after a day
//
// What a checkout costs, the bill and the withholding tax are the database's (audit_pay_start). Nothing the browser says
// about a payment is trusted: Counta asks Flutterwave for the transaction by its reference.
// Secrets: FLW_SECRET_KEY (Supabase Vault from the admin portal, else an Edge Function secret), APP_URL. Subaccounts and
// checkouts are not transfers, so they go to Flutterwave directly, not through the transfer relay.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { type ChargeCtx, checkoutBody, readVerify, type SubCtx, subaccountBody, subaccountPlan } from './flw.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const FLW = Deno.env.get('FLW_BASE_URL') || 'https://api.flutterwave.com/v3';
const admin = createClient(SUPABASE_URL, SERVICE, { auth: { persistSession: false } });

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-counta-hook',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

class UserError extends Error {}
class NotConfigured extends UserError {}

const cache = new Map<string, { v: string; at: number }>();
// Keys set in the admin portal (Supabase Vault) come first; the Edge Function secrets are the fallback.
async function secret(name: string): Promise<string> {
  if (name === 'PUSH_HOOK_SECRET' && Deno.env.get(name)) return Deno.env.get(name)!.trim();
  const hit = cache.get(name);
  if (hit && Date.now() - hit.at < 60_000) return hit.v;
  let v = '';
  const a = await admin.rpc('svc_secret', { p_name: name });
  if (typeof a.data === 'string') v = a.data.trim();
  if (!v) {
    const b = await admin.rpc('app_secret', { p_name: name });
    if (typeof b.data === 'string') v = b.data.trim();
  }
  if (!v) v = (Deno.env.get(name) || '').trim();
  cache.set(name, { v, at: Date.now() });
  return v;
}
const appUrl = async () => ((await secret('APP_URL')) || 'https://counta-taxstreem.netlify.app').replace(/\/$/, '');

async function svc<T = any>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await admin.rpc(fn, args);
  if (error) throw new UserError(error.message);
  return data as T;
}
async function asUser<T = any>(sb: SupabaseClient, fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await sb.rpc(fn, args);
  if (error) throw new UserError(error.message);
  return data as T;
}

function same(a: string, b: string) {
  const ea = new TextEncoder().encode(a), eb = new TextEncoder().encode(b);
  if (ea.length !== eb.length) return false;
  let r = 0;
  for (let i = 0; i < ea.length; i++) r |= ea[i] ^ eb[i];
  return r === 0;
}

async function flw(path: string, init: RequestInit = {}): Promise<any> {
  const key = await secret('FLW_SECRET_KEY');
  if (!key) throw new NotConfigured('Payments are not switched on yet. TaxStreem is setting them up.');
  const res = await fetch(FLW + path, { ...init, headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json', ...(init.headers || {}) },
    signal: AbortSignal.timeout(30_000) });
  const text = await res.text();
  let body: any = text;
  try { body = JSON.parse(text); } catch { /* not json */ }
  if (!res.ok || (body && body.status === 'error')) {
    const msg = typeof body === 'string' ? body : body?.message || JSON.stringify(body);
    throw new UserError(`Flutterwave: ${String(msg).slice(0, 300)}`);
  }
  return body;
}

// ------------------------------------------------------------------ the firm's split
async function setUpSubaccount(sb: SupabaseClient, practiceId: string, user: { email?: string; phone?: string }) {
  await asUser(sb, 'practice_audit_flutterwave_check', { p_practice: practiceId });
  const ctx = await svc<SubCtx | null>('svc_audit_subaccount', { p_practice: practiceId });
  if (!ctx) throw new UserError('Add the bank account first, under Earnings.');
  const plan = subaccountPlan(ctx);
  if (plan !== 'keep') {
    let body: ReturnType<typeof subaccountBody>;
    try { body = subaccountBody(ctx, user); } catch (e) { throw new UserError((e as Error).message); }
    try {
      let d: any;
      if (plan === 'update') {
        d = (await flw(`/subaccounts/${encodeURIComponent(String(ctx.subaccount.num))}`, { method: 'PUT', body: JSON.stringify({
          business_name: body.business_name, business_email: body.business_email, account_bank: body.account_bank, account_number: body.account_number,
          split_type: body.split_type, split_value: body.split_value }) }))?.data;
      } else {
        try {
          d = (await flw('/subaccounts', { method: 'POST', body: JSON.stringify(body) }))?.data;
        } catch (e) {
          // Flutterwave keeps one split per bank account: an earlier one for this account is used again.
          if (!/already exists|already been used|exists/i.test((e as Error).message)) throw e;
          const list = await flw(`/subaccounts?account_bank=${encodeURIComponent(body.account_bank)}&account_number=${encodeURIComponent(body.account_number)}`);
          d = (list?.data || []).find((x: any) => String(x.account_number) === body.account_number && String(x.account_bank) === body.account_bank);
          if (!d) throw e;
        }
      }
      if (!d?.subaccount_id || !d?.id) throw new UserError('Flutterwave did not return the split. Try again in a minute.');
      await svc('svc_audit_subaccount_save', { p_practice: practiceId, p: { status: 'ready', ref: String(d.subaccount_id), num: Number(d.id),
        bank: ctx.bank.bank_code, account: ctx.bank.account_number } });
    } catch (e) {
      if (e instanceof NotConfigured) throw e;
      await svc('svc_audit_subaccount_save', { p_practice: practiceId, p: { status: 'failed', error: (e as Error).message.replace(/^Flutterwave: /, '') } });
    }
  }
  return await asUser(sb, 'practice_audit', { p_practice: practiceId });
}

// ------------------------------------------------------------------ checkout and confirmation
async function verify(txRef: string, ageMinutes = 0) {
  const ctx = await svc<ChargeCtx | null>('svc_audit_charge', { p_tx_ref: txRef });
  if (!ctx) throw new UserError('Unknown payment.');
  if (ctx.charge.status !== 'pending') return { status: ctx.charge.status, ctx };
  let d: any = null;
  try { d = (await flw(`/transactions/verify_by_reference?tx_ref=${encodeURIComponent(txRef)}`))?.data; }
  catch (e) { if (e instanceof NotConfigured || !/no transaction|not found/i.test((e as Error).message)) throw e; }
  const v = readVerify(d, txRef, Number(ctx.charge.amount));
  if (v.status === 'pending') {
    if (ageMinutes > 24 * 60) {
      await svc('svc_audit_charge_update', { p_tx_ref: txRef, p: { status: 'cancelled', error: 'Not paid within a day.' } });
      return { status: 'cancelled', ctx };
    }
    return { status: 'pending', ctx };
  }
  const r = await svc('svc_audit_charge_update', { p_tx_ref: txRef, p: v });
  return { status: v.status, ctx, result: r };
}

async function poll() {
  const out = { checked: 0, paid: 0, errors: 0 };
  if (!(await secret('FLW_SECRET_KEY'))) return out;
  for (const c of (await svc<any[]>('svc_audit_open', {})) || []) {
    try {
      const r = await verify(String(c.tx_ref), Number(c.age_minutes) || 0);
      out.checked++;
      if (r.status === 'successful') out.paid++;
    } catch (e) { out.errors++; console.log('audit poll', c.tx_ref, (e as Error).message); }
  }
  return out;
}

// ------------------------------------------------------------------ entry
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405);
  let body: any;
  try { body = await req.json(); } catch { return json({ ok: false, error: 'Invalid request.' }, 400); }
  try {
    const hook = req.headers.get('x-counta-hook') || '';
    if (hook) {
      if (!same(hook, await secret('PUSH_HOOK_SECRET'))) return json({ ok: false, error: 'Not allowed.' }, 401);
      if (body.action === 'poll') return json({ ok: true, result: await poll() });
      return json({ ok: false, error: 'Unknown action.' }, 400);
    }
    const sb = createClient(SUPABASE_URL, ANON, { global: { headers: { Authorization: req.headers.get('Authorization') || '' } }, auth: { persistSession: false } });
    const { data: u } = await sb.auth.getUser();
    if (!u?.user) return json({ ok: false, error: 'Sign in first.' }, 401);
    switch (body.action) {
      case 'subaccount': {
        const practiceId = String(body.practice_id || '');
        if (!/^[0-9a-f-]{36}$/i.test(practiceId)) throw new UserError('Choose the practice.');
        return json({ ok: true, state: await setUpSubaccount(sb, practiceId, { email: u.user.email, phone: u.user.phone }) });
      }
      case 'pay': {
        const id = String(body.engagement_id || '');
        if (!/^[0-9a-f-]{36}$/i.test(id)) throw new UserError('Choose the audit to pay for.');
        if (!(await secret('FLW_SECRET_KEY'))) throw new NotConfigured('Card payments are not switched on yet. TaxStreem is setting them up.');
        const r = await asUser<any>(sb, 'audit_pay_start', { p_engagement: id });
        const ctx = await svc<ChargeCtx>('svc_audit_charge', { p_tx_ref: r.tx_ref });
        const l = await flw('/payments', { method: 'POST', body: JSON.stringify(checkoutBody(ctx, await appUrl())) });
        if (!l?.data?.link) throw new UserError('Flutterwave did not return a payment page. Try again in a minute.');
        return json({ ok: true, link: String(l.data.link), tx_ref: r.tx_ref, amount: r.amount });
      }
      case 'verify': {
        const txRef = String(body.tx_ref || '');
        if (!/^AUD-[0-9A-F]{16}$/.test(txRef)) throw new UserError('Unknown payment.');
        const ctx = await svc<ChargeCtx | null>('svc_audit_charge', { p_tx_ref: txRef });
        if (!ctx) throw new UserError('Unknown payment.');
        // Anyone in the business may ask: it only asks Flutterwave what happened.
        await asUser(sb, 'audit_state', { p_org: ctx.org.id, p_year: ctx.engagement.year });
        const r = await verify(txRef);
        const state = await asUser(sb, 'audit_state', { p_org: ctx.org.id, p_year: ctx.engagement.year });
        return json({ ok: true, status: r.status, state });
      }
      default: return json({ ok: false, error: 'Unknown action.' }, 400);
    }
  } catch (e) {
    const user = e instanceof UserError;
    if (!user) console.error('audits', e);
    return json({ ok: false, reason: e instanceof NotConfigured ? 'not_configured' : user ? 'error' : 'server', error: (e as Error).message }, user ? 200 : 500);
  }
});
