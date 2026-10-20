// Counta payments: business wallets, pay-by-transfer at checkout, payment links, NQR, payouts, provider webhooks,
// polling for missed webhooks and nightly wallet reconciliation.
//
// Signed-in callers (Authorization: Bearer <user JWT>), POST { action, ... }:
//   status { org_id }                              -> is the rail switched on, the wallet
//   open_wallet { org_id }                         -> opens the business wallet at the rail (payout subaccount on Flutterwave)
//   request { org_id, sale_id | customer_id, method: 'account'|'link'|'qr', amount? }  -> a live way to pay
//   activate { request_id }                        -> fills in a request the till opened (account number, link or QR)
//   check { request_id }                           -> asks the rail whether it has been paid
//   send_payout { payout_id }                      -> sends an approved payout
//   send_batch { batch_id }                        -> sends an approved bulk payment (as much as fits in ~40 seconds; the
//                                                     five-minute poll carries on with the rest), returns the batch
//   balance { org_id }                             -> the rail's balance for the wallet, compared with the books
//   open_tax_wallet { org_id }                     -> opens the business's tax wallet (a second payout subaccount) next to its wallet
//   tax_wallet_balance { org_id }                  -> the rail's balance for the tax wallet
//   send_tax_payment { payment_id }                -> sends an approved tax payment from the tax wallet
//   banks {}                                       -> Nigerian banks for payouts
//   resolve_account { account_number, bank_code }  -> the account name the bank holds
// Anyone holding a document link (no sign-in):
//   public_pay { token, method }                   -> a way to pay a shared invoice, receipt or order
//   public_check { token }                         -> has it been paid
// Rails:
//   POST /payments/webhook/flutterwave             -> header verif-hash must equal FLW_WEBHOOK_HASH
//   POST /payments/webhook/rail/<code>             -> header x-counta-signature: sha256=<HMAC of the body with the rail's webhook secret>
// Database cron (header x-counta-hook: <PUSH_HOOK_SECRET>):
//   { action: 'poll' }       -> re-checks unpaid requests, retries sweeps, re-checks payouts in progress, carries on
//                               sending bulk payments and reads Flutterwave bulk transfers' results; checks and pays the
//                               tax payments Flux posted and tells Flux of each one made
//   { action: 'tax_instruction', instruction_id } -> (from the taxstreem function) checks one payment request from Flux
//   { action: 'reconcile' }  -> compares every wallet with the books
//
// Nothing a webhook says is trusted on its own: Counta asks the rail for the transaction before recording money.
// Secrets: FLW_SECRET_KEY, FLW_WEBHOOK_HASH (Edge Function secrets or Supabase Vault); partner rail keys are named on payment_rails.
// Transfers: Flutterwave takes transfer requests only from IP addresses whitelisted on TaxStreem's account, and Supabase's
// servers have no fixed address. FLW_RELAY_URL and FLW_RELAY_SECRET name TaxStreem's relay (relay/ in the repository): a small
// server with one fixed address that forwards the signed requests. Without it, transfers (sweeps, payouts, bulk payments,
// moves into the tax wallet and tax payments) wait. FLW_DIRECT_TRANSFERS=1 sends them straight, for an account that needs no
// whitelisting (an Edge Function secret, set only for tests or a Flutterwave account set up otherwise).
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';

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

const secrets = new Map<string, { v: string; at: number }>();
const SECRET_CACHE_MS = Number(Deno.env.get('SECRET_CACHE_MS') || 60_000);
// Keys set in the admin portal (Supabase Vault) come first; the Edge Function secrets are the fallback.
async function secret(name: string): Promise<string> {
  // The database's hook secret keeps its old order: the Edge Function secret first.
  if (name === 'PUSH_HOOK_SECRET' && Deno.env.get(name)) return Deno.env.get(name)!.trim();
  const hit = secrets.get(name);
  if (hit && Date.now() - hit.at < SECRET_CACHE_MS) return hit.v;
  let v = '';
  const a = await admin.rpc('svc_secret', { p_name: name });
  if (typeof a.data === 'string') v = a.data.trim();
  if (!v) {
    const b = await admin.rpc('app_secret', { p_name: name });
    if (typeof b.data === 'string') v = b.data.trim();
  }
  if (!v) v = (Deno.env.get(name) || '').trim();
  secrets.set(name, { v, at: Date.now() });
  return v;
}
// Counta's web address, for the page a payer returns to.
const appUrl = async () => ((await secret('APP_URL')) || 'https://counta-taxstreem.netlify.app').replace(/\/$/, '');

async function svc<T = any>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await admin.rpc(fn, args);
  if (error) throw new UserError(error.message);
  return data as T;
}

function timingSafeEqual(a: string, b: string) {
  const ea = new TextEncoder().encode(a), eb = new TextEncoder().encode(b);
  if (ea.length !== eb.length) return false;
  let r = 0;
  for (let i = 0; i < ea.length; i++) r |= ea[i] ^ eb[i];
  return r === 0;
}

async function hmacHex(key: string, body: string) {
  const k = await crypto.subtle.importKey('raw', new TextEncoder().encode(key), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(body)));
  return Array.from(sig).map((x) => x.toString(16).padStart(2, '0')).join('');
}

const num = (v: unknown) => { const n = Number(v); return Number.isFinite(n) ? n : 0; };
const splitName = (n: string) => { const p = (n || 'Customer').trim().split(/\s+/); return { first: p[0] || 'Customer', last: p.slice(1).join(' ') || p[0] || 'Customer' }; };

// ------------------------------------------------------------------ rails
type Collected = { provider_ref?: string; account_number?: string; bank_name?: string; account_name?: string; link_url?: string; qr_image?: string; expires_at?: string };
type Verified = { status: 'paid' | 'pending' | 'failed'; amount: number; fee: number; provider_ref?: string; payer?: Record<string, unknown>; paid_at?: string };
type PayoutResult = { status: 'processing' | 'successful' | 'failed'; provider_ref?: string; fee?: number; error?: string; raw?: unknown };
type Credit = { reference: string; amount: number; at?: string; narration?: string; sender?: Record<string, unknown> };
interface Rail {
  configured(): Promise<boolean>;
  openWallet(org: { id: string; name: string; email?: string; phone?: string; purpose?: string }): Promise<{ account_ref: string; barter_id?: string; account_number: string; bank_name: string; account_name: string }>;
  collect(ctx: any, method: string): Promise<Collected>;
  verifyCollection(txRef: string): Promise<Verified | null>;
  payout(p: any, wallet: { account_ref?: string }): Promise<PayoutResult>;
  verifyPayout(reference: string, providerRef?: string): Promise<PayoutResult | null>;
  // Many payouts in one request (Flutterwave bulk transfers). Used only when the rail lists 'bulk_payout'.
  bulkPayout?(rows: any[], wallet: { account_ref?: string }, title: string): Promise<{ provider_batch_id: string }>;
  batchResults?(providerBatchId: string): Promise<(PayoutResult & { reference: string })[]>;
  balance(accountRef: string): Promise<{ available: number; ledger: number }>;
  sweep?(barterId: string, amount: number, reference: string, narration: string): Promise<'sent' | 'done' | 'failed'>;
  // Money that reached the wallet, as the rail's own statement shows it (used when a webhook cannot say which wallet).
  credits?(accountRef: string, from: string, to: string): Promise<Credit[]>;
  // Moves money between the business wallet and its tax wallet.
  moveFunds(fromRef: string, to: { barter_id?: string; account_ref?: string }, amount: number, reference: string, narration: string): Promise<{ status: 'sent' | 'failed'; provider_ref?: string; error?: string }>;
  banks(): Promise<{ code: string; name: string }[]>;
  resolveAccount(accountNumber: string, bankCode: string): Promise<string>;
}

class TransfersOff extends NotConfigured {}
const TRANSFERS_OFF = 'Transfers are not switched on yet: TaxStreem is setting up the server Flutterwave accepts them from. Nothing has left the wallet.';
const TRANSFER_PATH = /^\/(transfers|bulk-transfers)(\/|\?|$)/;
const WHITELIST = /whitelist/i;

async function relayConfig(): Promise<{ url: string; key: string } | null> {
  const url = await secret('FLW_RELAY_URL'), key = await secret('FLW_RELAY_SECRET');
  return url && key ? { url: url.replace(/\/$/, ''), key } : null;
}
// Whether Counta can send transfers now: through the relay, or straight when the account needs no whitelisting. Partner
// rails take transfers from anywhere.
async function transfersReady(kind = 'flutterwave'): Promise<boolean> {
  if (kind !== 'flutterwave') return true;
  return Boolean(await relayConfig()) || Deno.env.get('FLW_DIRECT_TRANSFERS') === '1';
}

async function readFlw(res: Response) {
  const text = await res.text();
  let body: any = text;
  try { body = JSON.parse(text); } catch { /* not json */ }
  if (!res.ok || (body && body.status === 'error')) {
    const msg = typeof body === 'string' ? body : body?.message || JSON.stringify(body);
    if (WHITELIST.test(String(msg))) throw new TransfersOff(TRANSFERS_OFF);
    throw new UserError(`Flutterwave: ${String(msg).slice(0, 300)}`);
  }
  return body;
}

// The relay forwards one request to Flutterwave from its fixed address. Each request is signed with the relay secret
// (timestamp, method, path and body), so nobody else can use it, and a copy cannot be replayed after five minutes.
async function viaRelay(relay: { url: string; key: string }, path: string, init: RequestInit, key: string) {
  const method = String(init.method || 'GET').toUpperCase();
  const body = typeof init.body === 'string' ? init.body : '';
  const ts = String(Math.floor(Date.now() / 1000));
  const sig = await hmacHex(relay.key, `${ts}\n${method}\n${path}\n${body}`);
  let res: Response;
  try {
    res = await fetch(`${relay.url}/forward${path}`, { method, body: method === 'GET' ? undefined : body,
      headers: { 'Content-Type': 'application/json', 'X-Relay-Timestamp': ts, 'X-Relay-Signature': sig, 'X-Flw-Authorization': `Bearer ${key}` },
      signal: AbortSignal.timeout(35_000) });
  } catch (e) {
    // Could not connect at all: nothing reached Flutterwave. A timeout is different: the transfer may have gone.
    const name = (e as Error).name;
    if (name !== 'TimeoutError' && name !== 'AbortError') throw new TransfersOff(`The transfer relay is not reachable: ${(e as Error).message}`);
    throw new Error(`The transfer relay did not answer in time: ${(e as Error).message}`);
  }
  const text = await res.text();
  let msg = '';
  try { msg = String(JSON.parse(text)?.message || ''); } catch { /* not json */ }
  // The relay's own answers start "Relay:". It could not reach Flutterwave in time: the transfer may have gone.
  if (msg.startsWith('Relay:') && res.status === 504) throw new Error(`The transfer relay got no answer from Flutterwave: ${msg}`);
  // It refused the request itself (signature, path, size): nothing was sent.
  if (msg.startsWith('Relay:')) {
    throw new TransfersOff(/signature|unsigned|stale|replayed/.test(msg)
      ? 'The transfer relay refused Counta\'s signature. Check FLW_RELAY_SECRET in the admin portal and the clock on the relay server.'
      : `The transfer relay refused the request (${msg.slice(7).trim()}).`);
  }
  return readFlw(new Response(text, { status: res.status }));
}

// The admin portal's check that the relay answers and that Counta's secret matches it.
async function relayCheck() {
  const relay = await relayConfig();
  if (!relay) return { ok: false, error: 'FLW_RELAY_URL and FLW_RELAY_SECRET are not both set.' };
  const ts = String(Math.floor(Date.now() / 1000)), body = '{}';
  const sig = await hmacHex(relay.key, `${ts}\nPOST\n/check\n${body}`);
  try {
    const r = await fetch(`${relay.url}/check`, { method: 'POST', body, headers: { 'Content-Type': 'application/json', 'X-Relay-Timestamp': ts, 'X-Relay-Signature': sig },
      signal: AbortSignal.timeout(10_000) });
    const j = await r.json().catch(() => ({}));
    return r.ok && j.ok ? { ok: true, version: j.version, upstream: j.upstream } : { ok: false, error: String(j.message || `The relay answered ${r.status}.`) };
  } catch (e) { return { ok: false, error: `The relay is not reachable: ${(e as Error).message}` }; }
}

async function flw(path: string, init: RequestInit = {}): Promise<any> {
  const key = await secret('FLW_SECRET_KEY');
  if (!key) throw new NotConfigured('Payments are not switched on yet. TaxStreem is setting them up.');
  const relay = await relayConfig();
  if (relay && TRANSFER_PATH.test(path)) return viaRelay(relay, path, init, key);
  const res = await fetch(FLW + path, { ...init, headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json', ...(init.headers || {}) },
    signal: AbortSignal.timeout(30_000) });
  try {
    return await readFlw(res);
  } catch (e) {
    // Another service turned out to need the whitelisted address too: the relay carries it.
    if (e instanceof TransfersOff && relay) return viaRelay(relay, path, init, key);
    throw e;
  }
}

// Flutterwave returns dates such as "2026-10-17 06:12:00 AM" (Lagos time) or ISO strings.
function flwDate(v: unknown, fallbackMinutes = 60): string {
  if (typeof v === 'string' && v && v !== 'N/A') {
    const iso = Date.parse(v);
    if (!Number.isNaN(iso)) return new Date(iso).toISOString();
    const m = v.match(/^(\d{4})-(\d{2})-(\d{2})[ T](\d{1,2}):(\d{2})(?::(\d{2}))?\s*(AM|PM)?/i);
    if (m) {
      let h = Number(m[4]);
      if (m[7]) { const pm = m[7].toUpperCase() === 'PM'; if (pm && h < 12) h += 12; if (!pm && h === 12) h = 0; }
      return new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]), h - 1, Number(m[5]), Number(m[6] || 0))).toISOString();
    }
  }
  return new Date(Date.now() + fallbackMinutes * 60_000).toISOString();
}

let bankCache: { at: number; list: { code: string; name: string }[] } | null = null;

// Flutterwave accepts phone numbers as digits only. "+234 803 555 0142", "0803-555-0142" and "2348035550142" all become
// "08035550142"; anything that is not a plausible number is left out (the phone is optional on every call that takes it).
function ngPhone(p?: string | null): string | undefined {
  const d = String(p || '').replace(/\D/g, '');
  const n = d.startsWith('234') && d.length >= 12 ? '0' + d.slice(3) : d;
  return n.length >= 10 && n.length <= 14 ? n : undefined;
}

const flutterwave: Rail = {
  async configured() { return Boolean(await secret('FLW_SECRET_KEY')); },
  async openWallet(org) {
    // The tax wallet is a second payout subaccount; Flutterwave keeps one per email, so it takes a tagged address.
    const base = (org.email || `wallet-${org.id.slice(0, 8)}@counta.ng`).toLowerCase();
    const email = org.purpose === 'tax' ? base.replace('@', `+tax${org.id.slice(0, 6)}@`) : base;
    const payload = (e: string) => JSON.stringify({ account_name: org.name.slice(0, 60), email: e, mobilenumber: ngPhone(org.phone), country: 'NG' });
    let r: any;
    try { r = await flw('/payout-subaccounts', { method: 'POST', body: payload(email) }); }
    catch (e) {
      // Flutterwave keeps one wallet per email: a business sharing an email with another gets a tagged address.
      if (!/email/i.test((e as Error).message)) throw e;
      const [local, domain] = email.split('@');
      r = await flw('/payout-subaccounts', { method: 'POST', body: payload(`${local}+counta${org.purpose === 'tax' ? 't' : ''}${org.id.slice(0, 6)}@${domain}`) });
    }
    const d = r.data || {};
    let nuban = d.nuban, bank = d.bank_name;
    if (!nuban) {
      const s = await flw(`/payout-subaccounts/${encodeURIComponent(d.account_reference)}/static-account?currency=NGN`);
      nuban = s.data?.static_account; bank = s.data?.bank_name || bank;
    }
    return { account_ref: d.account_reference, barter_id: d.barter_id, account_number: nuban, bank_name: bank || 'Flutterwave MFB', account_name: d.account_name || org.name };
  },
  async collect(ctx, method) {
    const r = ctx.request, c = ctx.customer || {};
    const email = c.email || ctx.org_email || `payments+${String(ctx.org_id).slice(0, 8)}@counta.ng`;
    const nm = splitName(c.walk_in ? ctx.org_name : c.name);
    if (method === 'account') {
      const v = await flw('/virtual-account-numbers', { method: 'POST', body: JSON.stringify({
        email, amount: r.amount, tx_ref: r.tx_ref, firstname: nm.first, lastname: nm.last, phonenumber: ngPhone(c.phone),
        narration: String(ctx.narration || ctx.org_name).slice(0, 50), is_permanent: false }) });
      const d = v.data || {};
      return { provider_ref: d.flw_ref || d.order_ref, account_number: d.account_number, bank_name: d.bank_name, account_name: ctx.org_name,
        expires_at: flwDate(d.expiry_date) };
    }
    if (method === 'qr') {
      try {
        const q = await flw('/charges?type=qr', { method: 'POST', body: JSON.stringify({ tx_ref: r.tx_ref, amount: r.amount, currency: 'NGN', email,
          phone_number: ngPhone(c.phone), fullname: c.name || ctx.org_name, is_nqr: '1' }) });
        const img = q?.meta?.authorization?.qr_image || q?.data?.meta?.authorization?.qr_image;
        if (img) return { provider_ref: q.data?.flw_ref, qr_image: img, expires_at: new Date(Date.now() + 30 * 60_000).toISOString() };
      } catch (e) { console.log('nqr unavailable, falling back to a link QR', (e as Error).message); }
      // No NQR on this account: the QR carries the payment link instead (the till draws it).
    }
    const l = await flw('/payments', { method: 'POST', body: JSON.stringify({
      tx_ref: r.tx_ref, amount: r.amount, currency: 'NGN',
      redirect_url: ctx.public_token ? `${await appUrl()}/p/${ctx.public_token}?paid=1` : `${await appUrl()}/paid`,
      customer: { email, name: c.walk_in ? ctx.org_name : (c.name || 'Customer'), phonenumber: ngPhone(c.phone) },
      customizations: { title: String(ctx.org_name).slice(0, 60), description: String(ctx.narration || '').slice(0, 100) },
      payment_options: 'banktransfer,card,ussd,account', meta: { org_id: ctx.org_id, request_id: r.id } }) });
    return { link_url: l.data?.link, expires_at: new Date(Date.now() + 3 * 24 * 3600_000).toISOString() };
  },
  async verifyCollection(txRef) {
    let v: any;
    try { v = await flw(`/transactions/verify_by_reference?tx_ref=${encodeURIComponent(txRef)}`); }
    catch (e) { if (/no transaction|not found/i.test((e as Error).message)) return null; throw e; }
    const d = v.data;
    if (!d) return null;
    if (d.tx_ref !== txRef || (d.currency && d.currency !== 'NGN')) return null;
    const status = String(d.status).toLowerCase();
    if (status !== 'successful') return { status: status === 'failed' ? 'failed' : 'pending', amount: 0, fee: 0 };
    const amount = num(d.amount), charged = num(d.charged_amount) || amount, appFee = num(d.app_fee);
    // Who paid the fee: when the customer was charged it on top, the business receives the full amount.
    const fee = Math.max(Math.round((amount - (charged - appFee)) * 100) / 100, 0);
    return { status: 'paid', amount, fee, provider_ref: String(d.flw_ref || d.id), paid_at: d.created_at,
      payer: { name: d.meta?.originatorname || d.customer?.name, account: d.meta?.originatoraccountnumber, bank: d.meta?.bankname, email: d.customer?.email } };
  },
  async payout(p, wallet) {
    const r = await flw('/transfers', { method: 'POST', body: JSON.stringify({
      account_bank: p.bank_code, account_number: p.account_number, amount: num(p.amount), currency: 'NGN', narration: String(p.narration).slice(0, 80),
      reference: p.reference, debit_currency: 'NGN', ...(wallet.account_ref ? { debit_subaccount: wallet.account_ref } : {}) }) });
    const d = r.data || {};
    return { status: 'processing', provider_ref: String(d.id || ''), fee: num(d.fee), raw: d };
  },
  async verifyPayout(_reference, providerRef) {
    if (!providerRef) return null;
    const r = await flw(`/transfers/${encodeURIComponent(providerRef)}`);
    const d = r.data || {};
    const s = String(d.status || '').toUpperCase();
    return { status: s === 'SUCCESSFUL' ? 'successful' : s === 'FAILED' ? 'failed' : 'processing', provider_ref: String(d.id), fee: num(d.fee), error: d.complete_message, raw: d };
  },
  // Flutterwave bulk transfer: one request, one transfer per row with our own reference, each debited from the business's
  // payout subaccount. Results come back per transfer (webhook transfer.completed, or the list for the batch id).
  async bulkPayout(rows, wallet, title) {
    const r = await flw('/bulk-transfers', { method: 'POST', body: JSON.stringify({
      title: title.slice(0, 60),
      bulk_data: rows.map((p) => ({ bank_code: p.bank_code, account_number: p.account_number, amount: num(p.amount), currency: 'NGN',
        narration: String(p.narration).slice(0, 80), reference: p.reference, debit_currency: 'NGN',
        ...(wallet.account_ref ? { debit_subaccount: wallet.account_ref } : {}) })) }) });
    const id = r.data?.id;
    if (!id) throw new UserError('Flutterwave did not return a bulk transfer id.');
    return { provider_batch_id: String(id) };
  },
  async batchResults(providerBatchId) {
    const out: (PayoutResult & { reference: string })[] = [];
    for (let page = 1; page <= 20; page++) {
      const r = await flw(`/transfers?batch_id=${encodeURIComponent(providerBatchId)}&page=${page}`);
      for (const d of r.data || []) {
        const s = String(d.status || '').toUpperCase();
        out.push({ reference: String(d.reference || ''), status: s === 'SUCCESSFUL' ? 'successful' : s === 'FAILED' ? 'failed' : 'processing',
          provider_ref: String(d.id || ''), fee: num(d.fee), error: d.complete_message, raw: d });
      }
      const info = r.meta?.page_info;
      if (!info || num(info.current_page) >= num(info.total_pages)) break;
    }
    return out;
  },
  async balance(accountRef) {
    const r = await flw(`/payout-subaccounts/${encodeURIComponent(accountRef)}/balances?currency=NGN`);
    return { available: num(r.data?.available_balance), ledger: num(r.data?.ledger_balance ?? r.data?.available_balance) };
  },
  async sweep(barterId, amount, reference, narration) {
    try {
      await flw('/transfers', { method: 'POST', body: JSON.stringify({ account_bank: 'flutterwave', account_number: barterId, amount: Math.round(amount * 100) / 100,
        currency: 'NGN', debit_currency: 'NGN', narration: narration.slice(0, 80), reference }) });
      return 'sent';
    } catch (e) {
      if (e instanceof NotConfigured) throw e;
      // No answer: the transfer may have gone, so it counts as sent and the wallet statement or the webhook settles it.
      // Sending again blind could pay the wallet twice out of TaxStreem's balance.
      if (!(e instanceof UserError)) { console.log('sweep without an answer', reference, (e as Error).message); return 'sent'; }
      if (/duplicate|already exist/i.test(e.message)) return 'sent';
      console.log('sweep refused', reference, e.message);
      return 'failed';
    }
  },
  async credits(accountRef, from, to) {
    const out: Credit[] = [];
    for (let page = 1; page <= 10; page++) {
      const r = await flw(`/payout-subaccounts/${encodeURIComponent(accountRef)}/transactions?from=${from}&to=${to}&page=${page}`);
      const list: any[] = r.data?.transactions || [];
      for (const t of list) {
        if (String(t.type).toUpperCase() !== 'C' || (t.currency && t.currency !== 'NGN') || !t.reference) continue;
        out.push({ reference: String(t.reference), amount: num(t.amount), at: t.date ? flwDate(t.date, 0) : undefined, narration: t.remarks || '' });
      }
      const info = r.data?.page_info;
      if (!info || num(info.current_page) >= num(info.total_pages)) break;
    }
    return out;
  },
  async moveFunds(fromRef, to, amount, reference, narration) {
    if (!to.barter_id) return { status: 'failed', error: 'The receiving wallet has no Flutterwave id.' };
    try {
      const r = await flw('/transfers', { method: 'POST', body: JSON.stringify({ account_bank: 'flutterwave', account_number: to.barter_id, amount: Math.round(amount * 100) / 100,
        currency: 'NGN', debit_currency: 'NGN', debit_subaccount: fromRef, narration: narration.slice(0, 80), reference }) });
      return { status: 'sent', provider_ref: String(r?.data?.id || '') };
    } catch (e) {
      if (e instanceof NotConfigured) throw e;
      // No answer: it may have gone. Counted as sent; the wallet's statement or the webhook settles it, and sending it again
      // blind could move it twice.
      if (!(e instanceof UserError)) { console.log('wallet move without an answer', reference, (e as Error).message); return { status: 'sent' }; }
      if (/duplicate|already exist/i.test(e.message)) return { status: 'sent' };
      return { status: 'failed', error: e.message };
    }
  },
  async banks() {
    if (bankCache && Date.now() - bankCache.at < 24 * 3600_000) return bankCache.list;
    const r = await flw('/banks/NG');
    const list = (r.data || []).map((b: any) => ({ code: String(b.code), name: String(b.name) })).sort((a: any, b: any) => a.name.localeCompare(b.name));
    bankCache = { at: Date.now(), list };
    return list;
  },
  async resolveAccount(accountNumber, bankCode) {
    const r = await flw('/accounts/resolve', { method: 'POST', body: JSON.stringify({ account_number: accountNumber, account_bank: bankCode }) });
    return String(r.data?.account_name || '');
  },
};

// A partner rail speaking the Counta Rail API (docs/payment-rails.md).
function httpRail(rail: any): Rail {
  async function call(path: string, init: RequestInit = {}) {
    const key = rail.api_key_secret ? await secret(rail.api_key_secret) : '';
    if (!key) throw new NotConfigured(`The ${rail.name} payment rail has no API key yet.`);
    const res = await fetch(String(rail.base_url).replace(/\/$/, '') + path, { ...init,
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json', 'X-Counta-Version': '1', ...(init.headers || {}) }, signal: AbortSignal.timeout(30_000) });
    const text = await res.text();
    let body: any = text;
    try { body = JSON.parse(text); } catch { /* not json */ }
    if (res.status === 404) return null;
    if (!res.ok) throw new UserError(`${rail.name}: ${String(body?.error || body?.message || text).slice(0, 300)}`);
    return body;
  }
  return {
    async configured() { return Boolean(rail.api_key_secret && (await secret(rail.api_key_secret))); },
    async openWallet(org) {
      const r = await call('/accounts', { method: 'POST', body: JSON.stringify({ business_id: org.id, name: org.name, email: org.email, phone: org.phone, purpose: org.purpose || 'main' }) });
      return { account_ref: r.account_ref, account_number: r.account_number, bank_name: r.bank_name, account_name: r.account_name || org.name };
    },
    async collect(ctx, method) {
      const r = await call('/collections', { method: 'POST', body: JSON.stringify({ tx_ref: ctx.request.tx_ref, amount: ctx.request.amount, currency: 'NGN', method,
        account_ref: ctx.wallet?.account_ref, customer: ctx.customer, narration: ctx.narration, expires_in: 3600,
        redirect_url: ctx.public_token ? `${await appUrl()}/p/${ctx.public_token}?paid=1` : undefined }) });
      return { provider_ref: r.provider_ref, account_number: r.account_number, bank_name: r.bank_name, account_name: r.account_name, link_url: r.link_url,
        qr_image: r.qr_image, expires_at: r.expires_at };
    },
    async verifyCollection(txRef) {
      const r = await call(`/collections/${encodeURIComponent(txRef)}`);
      if (!r) return null;
      return { status: r.status === 'paid' ? 'paid' : r.status === 'failed' ? 'failed' : 'pending', amount: num(r.amount_paid), fee: num(r.fee),
        provider_ref: r.provider_ref, payer: r.payer, paid_at: r.paid_at };
    },
    async payout(p, wallet) {
      const r = await call('/payouts', { method: 'POST', body: JSON.stringify({ reference: p.reference, amount: num(p.amount), currency: 'NGN', bank_code: p.bank_code,
        account_number: p.account_number, account_name: p.account_name, narration: p.narration, account_ref: wallet.account_ref }) });
      return { status: r.status === 'successful' ? 'successful' : r.status === 'failed' ? 'failed' : 'processing', provider_ref: r.provider_ref, fee: num(r.fee), raw: r };
    },
    async verifyPayout(reference) {
      const r = await call(`/payouts/${encodeURIComponent(reference)}`);
      if (!r) return null;
      return { status: r.status === 'successful' ? 'successful' : r.status === 'failed' ? 'failed' : 'processing', provider_ref: r.provider_ref, fee: num(r.fee), error: r.error, raw: r };
    },
    async balance(accountRef) {
      const r = await call(`/accounts/${encodeURIComponent(accountRef)}/balance`);
      return { available: num(r?.available), ledger: num(r?.ledger ?? r?.available) };
    },
    async moveFunds(fromRef, to, amount, reference, narration) {
      try {
        const r = await call(`/accounts/${encodeURIComponent(fromRef)}/move`, { method: 'POST', body: JSON.stringify({ to_account_ref: to.account_ref, amount, reference, narration }) });
        if (!r) return { status: 'failed', error: `${rail.name} cannot move money between a business's accounts yet.` };
        return { status: r.status === 'failed' ? 'failed' : 'sent', provider_ref: r.provider_ref, error: r.error };
      } catch (e) {
        if (!(e instanceof UserError)) return { status: 'sent' };
        return { status: 'failed', error: (e as Error).message };
      }
    },
    async banks() { return (await call('/banks')) || []; },
    async resolveAccount(accountNumber, bankCode) {
      const r = await call(`/accounts/resolve?account_number=${encodeURIComponent(accountNumber)}&bank_code=${encodeURIComponent(bankCode)}`);
      return String(r?.account_name || '');
    },
  };
}

const railCache = new Map<string, { at: number; rail: Rail; row: any }>();
async function railFor(code: string): Promise<{ rail: Rail; row: any }> {
  const hit = railCache.get(code);
  if (hit && Date.now() - hit.at < 60_000) return hit;
  const row = await svc('svc_rail', { p_code: code });
  if (!row) throw new UserError('Unknown payment rail.');
  const rail = row.kind === 'flutterwave' ? flutterwave : httpRail(row);
  const v = { at: Date.now(), rail, row };
  railCache.set(code, v);
  return v;
}

// ------------------------------------------------------------------ flows
// Asks the rail for a way to pay a request the database has opened, and stores it.
async function fillRequest(ctx: any) {
  const r = ctx.request;
  if (r.status !== 'creating') return r;
  const { rail } = await railFor(ctx.rail);
  try {
    const c = await rail.collect(ctx, r.method);
    return await svc('svc_request_update', { p_request: r.id, d: { status: 'pending', ...c } });
  } catch (e) {
    await svc('svc_request_update', { p_request: r.id, d: { status: 'failed', error: (e as Error).message } });
    throw e;
  }
}

// Asks the rail about a request; records the money when it has arrived and sweeps it into the business's wallet.
// Only the rail's own answer counts: a webhook merely says "go and look".
async function settle(txRef: string, railCode: string, eventPayer?: Record<string, unknown>, requestId?: string) {
  const { rail } = await railFor(railCode);
  const v = await rail.verifyCollection(txRef);
  if (!v || v.status !== 'paid' || v.amount <= 0) {
    if (requestId) await svc('svc_request_update', { p_request: requestId, d: {} });
    return { paid: false, status: v?.status || 'pending' };
  }
  const res = await svc('svc_payment_confirmed', { p_tx_ref: txRef, d: { amount: v.amount, fee: v.fee, provider_ref: v.provider_ref, paid_at: v.paid_at,
    payer: { ...(eventPayer || {}), ...(v.payer || {}) } } });
  if (res?.sweep && rail.sweep && (await transfersReady())) {
    // The money is recorded either way; a sweep that cannot go now waits for the poll.
    try {
      const s = await rail.sweep(res.sweep.barter_id, num(res.sweep.amount), res.sweep.reference, `Counta ${res.sweep.reference}`);
      await svc('svc_sweep_update', { p_tx_ref: txRef, p_status: s, p_error: s === 'failed' ? 'Sweep failed; retried by the poll' : null });
    } catch (e) { console.log('sweep after payment', txRef, (e as Error).message); }
  }
  return { paid: Boolean(res?.ok), request: res?.request, duplicate: Boolean(res?.duplicate) };
}

async function sendPayout(sb: SupabaseClient, payoutId: string) {
  // Checked first, so a payout waiting for transfers to be switched on stays approved instead of failing.
  const { data: pre } = await admin.from('payouts').select('wallet:wallets(rail)').eq('id', payoutId).maybeSingle();
  const railCode = (pre as any)?.wallet?.rail;
  if (railCode && !(await transfersReady((await railFor(railCode)).row.kind))) throw new TransfersOff(TRANSFERS_OFF);
  const { data, error } = await sb.rpc('payout_to_send', { p_payout: payoutId });
  if (error) throw new UserError(error.message);
  const p = data.payout;
  const { rail } = await railFor(data.rail);
  try {
    const r = await rail.payout(p, data.wallet || {});
    return await svc('svc_payout_update', { p_reference: p.reference, d: { status: r.status, provider_ref: r.provider_ref, fee: r.fee, raw: r.raw, error: r.error } });
  } catch (e) {
    // The rail refused it: nothing left the wallet. No answer at all: it may have gone, so it stays "processing" until the
    // rail's webhook or the poll says otherwise. Marking it failed here could let someone pay the same person twice.
    if (e instanceof UserError) {
      await svc('svc_payout_update', { p_reference: p.reference, d: { status: 'failed', error: e.message } });
      throw e;
    }
    console.log('payout sent without an answer', p.reference, (e as Error).message);
    return { ok: true, status: 'processing', number: p.number, note: 'The bank has not answered yet. Counta will update this payout when it does.' };
  }
}

// Sends the approved rows of a bulk payment that is "sending". Rows are claimed one at a time (or 100 at a time for a
// Flutterwave bulk transfer) and each moves to "processing" before it goes, so the page and the poll can both push the
// same batch without paying anyone twice. Stops after budgetMs; whatever is left goes on the next push.
async function pushBatch(b: { id: string; rail: string; bulk?: boolean; title?: string; wallet: { account_ref?: string } }, budgetMs: number) {
  const { rail, row } = await railFor(b.rail);
  if (!(await rail.configured())) throw new NotConfigured(row.kind === 'flutterwave' ? 'Payments are not switched on yet. TaxStreem is setting them up.' : `The ${row.name} payment rail has no API key yet.`);
  if (!(await transfersReady(row.kind))) throw new TransfersOff(TRANSFERS_OFF);
  const bulk = Boolean(b.bulk && rail.bulkPayout);
  const start = Date.now();
  let sent = 0, failed = 0;
  while (Date.now() - start < budgetMs) {
    const rows = await svc<any[]>('svc_batch_claim', { p_batch: b.id, p_limit: bulk ? 100 : 1 });
    if (!rows?.length) break;
    if (bulk) {
      try {
        const r = await rail.bulkPayout!(rows, b.wallet, b.title || 'Counta bulk payment');
        await svc('svc_batch_update', { p_batch: b.id, d: { provider_batch_id: r.provider_batch_id } });
        sent += rows.length;
      } catch (e) {
        if (!(e instanceof UserError)) { console.log('bulk transfer without an answer', b.id, (e as Error).message); sent += rows.length; break; }
        for (const p of rows) await svc('svc_payout_update', { p_reference: p.reference, d: { status: 'failed', error: e.message } });
        failed += rows.length;
      }
      continue;
    }
    const p = rows[0];
    try {
      const r = await rail.payout(p, b.wallet);
      await svc('svc_payout_update', { p_reference: p.reference, d: { status: r.status, provider_ref: r.provider_ref, fee: r.fee, raw: r.raw, error: r.error } });
      sent++;
    } catch (e) {
      // Refused: nothing left the wallet. No answer: it may have gone, so it stays "processing" for the poll to settle.
      if (e instanceof UserError) { await svc('svc_payout_update', { p_reference: p.reference, d: { status: 'failed', error: e.message } }); failed++; }
      else { console.log('batch payout without an answer', p.reference, (e as Error).message); sent++; }
    }
  }
  return { sent, failed };
}

async function sendBatch(sb: SupabaseClient, batchId: string) {
  const { data, error } = await sb.rpc('payout_batch_to_send', { p_batch: batchId });
  if (error) throw new UserError(error.message);
  const res = await pushBatch({ id: batchId, rail: data.rail, bulk: data.batch?.bulk, title: data.batch?.title, wallet: data.wallet || {} }, 40_000);
  const { data: batch, error: e2 } = await sb.rpc('get_payout_batch', { p_batch: batchId });
  if (e2) throw new UserError(e2.message);
  return { ...res, batch };
}

const day = (d: Date) => d.toISOString().slice(0, 10);

// Reads each wallet's statement at the rail and records money that came in directly (customers paying the business's own
// account number, owner top-ups, sweeps landing). Each credit is recorded once, by the rail's reference.
// which: 'all' (every business wallet), 'direct' (wallets with a sale waiting for a transfer to the business's number),
// 'tax' (the tax wallets).
async function syncWallets(days = 2, only?: string, which: 'all' | 'direct' | 'tax' | 'all_and_tax' = 'all') {
  const out = { wallets: 0, credits: 0, recorded: 0 };
  const to = new Date(), from = new Date(Date.now() - days * 86400_000);
  const kinds = which === 'all_and_tax' ? ['wallets', 'tax_wallets'] : which === 'direct' ? ['direct_wallets'] : which === 'tax' ? ['tax_wallets'] : ['wallets'];
  const list: any[] = [];
  for (const k of kinds) list.push(...((await svc<any[]>('svc_work', { p_kind: k })) || []));
  for (const w of list) {
    if (only && w.id !== only) continue;
    try {
      const { rail } = await railFor(w.rail);
      if (!rail.credits || !w.account_ref || !(await rail.configured())) continue;
      out.wallets++;
      for (const c of await rail.credits(w.account_ref, day(from), day(to))) {
        out.credits++;
        const r = await svc('svc_wallet_inflow', { p_rail: w.rail, p_account_ref: w.account_ref, d: { amount: c.amount, reference: c.reference,
          provider_ref: c.reference, narration: c.narration, sender: c.sender || {}, at: c.at } });
        if (r?.ok && r.bank_line) out.recorded++;
      }
    } catch (e) { console.log('wallet sync', w.id, (e as Error).message); }
  }
  return out;
}

const walletChecks = new Map<string, number>();
async function syncOneWallet(walletId: string, everyMs = 12_000) {
  const last = walletChecks.get(walletId) || 0;
  if (Date.now() - last < everyMs) return null;
  walletChecks.set(walletId, Date.now());
  if (walletChecks.size > 5000) walletChecks.clear();
  return syncWallets(1, walletId);
}

// Moves the tax waiting in business wallets to their tax wallets (and back what is released), in one transfer each way.
async function sendTaxTransfers() {
  const out = { sent: 0, failed: 0, waiting: 0 };
  const due = (await svc<any[]>('svc_work', { p_kind: 'tax_transfers' })) || [];
  for (const t of due) {
    if (!(await transfersReady((await railFor(t.rail)).row.kind))) {
      await svc('svc_tax_transfer_update', { p_reference: t.reference, p_status: 'waiting', p_error: TRANSFERS_OFF });
      out.waiting++;
      continue;
    }
    // A failed attempt used up its reference at the rail; a retry gets a new one that still starts with the transfer's own.
    const ref = num(t.attempts) > 0 ? `${t.reference}-${Date.now().toString(36).toUpperCase()}` : t.reference;
    try {
      const { rail } = await railFor(t.rail);
      const r = await rail.moveFunds(String(t.from_ref), { barter_id: t.to_barter, account_ref: t.to_account_ref }, num(t.amount), ref, `Counta ${ref}`);
      await svc('svc_tax_transfer_update', { p_reference: ref, p_status: r.status, p_error: r.error || null, p_provider_ref: r.provider_ref || null });
      if (r.status === 'sent') out.sent++; else out.failed++;
    } catch (e) {
      if (e instanceof NotConfigured) {
        await svc('svc_tax_transfer_update', { p_reference: t.reference, p_status: 'waiting', p_error: (e as Error).message });
        out.waiting++;
        if (e instanceof TransfersOff) break;
      } else console.log('tax transfer', t.reference, (e as Error).message);
    }
  }
  return out;
}

// Tax payments sent from tax wallets: what the rail says became of them.
async function checkTaxPayments() {
  let n = 0;
  for (const p of (await svc<any[]>('svc_work', { p_kind: 'tax_payments' })) || []) {
    try {
      const { rail } = await railFor(p.rail);
      const v = await rail.verifyPayout(p.reference, p.provider_ref);
      if (v && v.status !== 'processing') { await svc('svc_tax_payment_update', { p_reference: p.reference, d: v }); n++; }
    } catch (e) { console.log('tax payment check', p.reference, (e as Error).message); }
  }
  return n;
}

// ------------------------------------------------------------------ tax payments Rev360 asks for, through Flux
// Rev360's payment page (through Flutterwave) gives an account for each payment. Flux's RPA copies it and posts it with the
// PRN; Counta checks the account with the bank, then pays it from the tax wallet when the amount agrees with the return,
// the wallet holds enough and the names match. Anything else waits for the owner (svc_tax_instruction_decide says which).
const BANK_WORDS = /\b(bank|plc|limited|ltd|nigeria|nig|of|the|microfinance|mfb|mfbank|international|intl|and|&)\b/g;
const BANK_ALIASES: Record<string, string[]> = {
  'gtbank': ['guaranty trust', 'gtb', 'gt'], 'uba': ['united africa', 'united for africa'], 'fcmb': ['first city monument'],
  'first': ['firstbank', 'fbn'], 'stanbic ibtc': ['stanbic'], 'access': ['access diamond', 'diamond'], 'polaris': ['skye'],
  'union': ['union nigeria'], 'ecobank': ['eco'], 'wema': ['alat'], 'keystone': [], 'providus': [], 'sterling': [], 'zenith': [], 'fidelity': [],
};
function bankKey(name: string) {
  return name.toLowerCase().replace(/[^a-z0-9& ]/g, ' ').replace(BANK_WORDS, ' ').replace(/\s+/g, ' ').trim();
}
// The bank code for the bank Flux names (or the code it gave, when the rail knows it). Null when it is not one clear bank.
export function bankCodeFor(banks: { code: string; name: string }[], name: string, code?: string | null): string | null {
  if (code && banks.some((b) => b.code === code)) return code;
  const want = bankKey(name || '');
  if (!want) return null;
  const keyed = banks.map((b) => ({ ...b, key: bankKey(b.name) }));
  const exact = keyed.filter((b) => b.key === want);
  if (exact.length === 1) return exact[0].code;
  for (const [k, alts] of Object.entries(BANK_ALIASES)) {
    if (want === k || alts.includes(want)) {
      const hit = keyed.filter((b) => b.key === k || alts.includes(b.key) || b.key.startsWith(k + ' '));
      if (hit.length === 1) return hit[0].code;
    }
  }
  const part = keyed.filter((b) => b.key.startsWith(want + ' ') || want.startsWith(b.key + ' '));
  return part.length === 1 ? part[0].code : null;
}
const NAME_WORDS = /\b(ltd|limited|plc|nig|nigeria|the|of|and|flw|account|acct|collection|collections)\b/g;
function nameTokens(n: string) {
  return n.toUpperCase().replace(/[^A-Z0-9 ]/g, ' ').toLowerCase().replace(NAME_WORDS, ' ').split(/\s+/).filter((t) => t.length > 1);
}
// Whether the name the bank holds is the name Flux read off the payment page: the same words, one inside the other, or most
// of the shorter name's words in the longer.
export function namesMatch(a: string, b: string): boolean {
  const x = nameTokens(a), y = nameTokens(b);
  if (!x.length || !y.length) return false;
  const jx = x.join(''), jy = y.join('');
  if (jx === jy || jx.includes(jy) || jy.includes(jx)) return true;
  const [short, long] = x.length <= y.length ? [x, new Set(y)] : [y, new Set(x)];
  return short.filter((t) => long.has(t)).length / short.length >= 0.75;
}

async function checkInstruction(id: string) {
  const ctx = await svc('svc_tax_instruction_context', { p_id: id });
  const i = ctx?.instruction;
  if (!i || !['received', 'needs_approval'].includes(i.status)) return { id, status: i?.status ?? 'unknown', decision: 'none' };
  const { rail } = await railFor(ctx.tax_wallet?.rail || 'flutterwave');
  let bankCode: string | null = null, resolved = '', nameOk: boolean | null = null;
  try { bankCode = bankCodeFor(await rail.banks(), i.bank_name, i.bank_code); } catch (e) { console.log('banks', (e as Error).message); }
  if (bankCode) {
    try {
      resolved = (await rail.resolveAccount(i.account_number, bankCode)).trim();
      nameOk = resolved ? namesMatch(i.account_name, resolved) : false;
    } catch (e) {
      // The bank said it has no such account: a misread number, so the owner checks it. No answer: it cannot be checked.
      if (e instanceof UserError && /invalid|not found|could not resolve|unable to resolve|does not exist/i.test(e.message)) nameOk = false;
      console.log('resolve tax account', id, (e as Error).message);
    }
  }
  const d = await svc('svc_tax_instruction_decide', { p_id: id, p: { bank_code: bankCode, resolved_name: resolved, ...(nameOk === null ? {} : { name_ok: nameOk }) } });
  if (d.decision === 'pay' && d.payment_id) {
    const sent = await sendTaxPaymentAuto(String(d.payment_id));
    return { id, ...d, status: sent.status === 'failed' ? 'needs_approval' : d.status, payment: sent };
  }
  return { id, ...d };
}

// Sends a tax payment Counta approved by itself (or one a person approved while transfers were off). Without transfers it
// stays approved and the five-minute work sends it once they are on.
async function sendTaxPaymentAuto(paymentId: string): Promise<{ status: string; error?: string }> {
  const { data: pre } = await admin.from('tax_payments').select('wallet:tax_wallets(rail)').eq('id', paymentId).maybeSingle();
  const railCode = (pre as any)?.wallet?.rail || 'flutterwave';
  if (!(await transfersReady((await railFor(railCode)).row.kind))) return { status: 'approved', error: TRANSFERS_OFF };
  const data = await svc('svc_tax_payment_to_send', { p_payment: paymentId });
  const p = data.payment;
  const { rail } = await railFor(data.rail);
  try {
    const r = await rail.payout({ ...p, purpose: 'tax' }, data.tax_wallet || {});
    const u = await svc('svc_tax_payment_update', { p_reference: p.reference, d: { status: r.status, provider_ref: r.provider_ref, fee: r.fee, error: r.error } });
    return { status: u.status };
  } catch (e) {
    if (e instanceof UserError || e instanceof NotConfigured) {
      await svc('svc_tax_payment_update', { p_reference: p.reference, d: { status: 'failed', error: (e as Error).message } });
      return { status: 'failed', error: (e as Error).message };
    }
    // No answer: it stays "processing" until the rail says what happened.
    return { status: 'processing', error: (e as Error).message };
  }
}

async function fluxConfig() {
  const url = (await secret('FLUX_URL')).replace(/\/$/, ''), key = await secret('FLUX_SECRET');
  return url && key ? { url, key } : null;
}

// The five-minute work: requests not yet checked, payments to send, and Flux told of each payment made.
async function taxInstructionWork() {
  const out = { checked: 0, sent: 0, told: 0 };
  const w = await svc('svc_tax_instruction_work', {});
  for (const id of w.to_check || []) {
    try { await checkInstruction(String(id)); out.checked++; } catch (e) { console.log('tax instruction check', id, (e as Error).message); }
  }
  for (const p of w.to_send || []) {
    try { if ((await sendTaxPaymentAuto(String(p.payment_id))).status !== 'approved') out.sent++; else break; }
    catch (e) { console.log('tax instruction send', p.payment_id, (e as Error).message); }
  }
  const cfg = (w.to_notify || []).length ? await fluxConfig() : null;
  for (const n of cfg ? w.to_notify : []) {
    try {
      const raw = JSON.stringify({ event: 'tax.payment.made', instruction_id: n.id, counta_org_id: n.counta_org_id, prn: n.prn, tax: n.tax, amount: n.amount,
        paid_at: n.paid_at, from: n.from, transfer_reference: n.transfer_reference ?? null, provider_ref: n.provider_ref ?? null });
      const t = Math.floor(Date.now() / 1000);
      const res = await fetch(`${cfg!.url}/counta/tax-payments`, { method: 'POST', body: raw, signal: AbortSignal.timeout(15_000),
        headers: { 'Content-Type': 'application/json', 'x-counta-signature': `t=${t},v1=${await hmacHex(cfg!.key, `${t}.${raw}`)}` } });
      if (res.ok) { await svc('svc_tax_instruction_notified', { p_id: n.id }); out.told++; }
      else console.log('flux tax payment notice', n.prn, res.status);
    } catch (e) { console.log('flux tax payment notice', n.prn, (e as Error).message); }
  }
  return out;
}

// Opens a business's tax wallet at its rail (after its business wallet).
async function openTaxWallet(orgId: string, memberId: string) {
  const t = await svc('svc_tax_wallet_to_open', { p_org: orgId, p_member: memberId });
  if (t.ready) return t.tax_wallet;
  const { rail } = await railFor(t.rail.code);
  try {
    return await svc('svc_tax_wallet_ready', { p_wallet: t.tax_wallet.id, d: await rail.openWallet(t.org) });
  } catch (e) {
    await svc('svc_tax_wallet_ready', { p_wallet: t.tax_wallet.id, d: { error: (e as Error).message } });
    throw e;
  }
}

async function memberOf(sb: SupabaseClient, orgId: string, userId: string) {
  const { data: m } = await sb.from('members').select('id').eq('org_id', orgId).eq('user_id', userId).eq('status', 'active').maybeSingle();
  if (!m) throw new UserError('You are not a member of this business.');
  return m.id as string;
}

// Work that should not hold up a webhook reply.
function later(p: Promise<unknown>) {
  const rt = (globalThis as any).EdgeRuntime;
  const guarded = p.catch((e) => console.log('background', (e as Error).message));
  if (rt?.waitUntil) rt.waitUntil(guarded);
  return guarded;
}

async function poll() {
  const out: Record<string, unknown> = { checked: 0, paid: 0, sweeps: 0, payouts: 0 };
  for (const r of (await svc<any[]>('svc_work', { p_kind: 'requests' })) || []) {
    try {
      out.checked = (out.checked as number) + 1;
      if ((await settle(r.tx_ref, r.rail, undefined, r.id)).paid) out.paid = (out.paid as number) + 1;
    } catch (e) { console.log('poll request', r.tx_ref, (e as Error).message); }
  }
  // Card, USSD and QR payments land in TaxStreem's Flutterwave balance and are swept to the business wallet. Sweeps are
  // transfers: without the relay (or another route Flutterwave accepts) they wait, and nothing is lost.
  if (await transfersReady()) {
    for (const s of (await svc<any[]>('svc_work', { p_kind: 'sweeps' })) || []) {
      if (s.status === 'sent') continue;
      try {
        const { rail } = await railFor('flutterwave');
        if (!rail.sweep) continue;
        // A failed attempt used up its reference at the rail; each retry gets a new one that still carries the request's tx_ref.
        const ref = s.status === 'failed' ? `${s.reference}-${Date.now().toString(36).toUpperCase()}` : s.reference;
        const st = await rail.sweep(s.barter_id, num(s.amount), ref, `Counta ${ref}`);
        await svc('svc_sweep_update', { p_tx_ref: s.tx_ref, p_status: st, p_error: st === 'failed' ? 'Sweep failed again' : null, p_ref: ref });
        out.sweeps = (out.sweeps as number) + 1;
      } catch (e) {
        console.log('sweep', s.tx_ref, (e as Error).message);
        if (e instanceof NotConfigured) break;
      }
    }
  }
  for (const p of (await svc<any[]>('svc_work', { p_kind: 'payouts' })) || []) {
    try {
      const { rail } = await railFor(p.rail);
      const v = await rail.verifyPayout(p.reference, p.provider_ref);
      if (v && v.status !== 'processing') { await svc('svc_payout_update', { p_reference: p.reference, d: v }); out.payouts = (out.payouts as number) + 1; }
    } catch (e) { console.log('poll payout', p.reference, (e as Error).message); }
  }
  // Bulk payments someone started: send what is left, and read Flutterwave bulk transfers' results.
  out.batches = 0;
  let batches: any[] = [];
  try { batches = (await svc<any[]>('svc_work', { p_kind: 'batches' })) || []; } catch (e) { console.log('poll batches', (e as Error).message); }
  for (const b of batches) {
    try {
      if (num(b.approved) > 0) await pushBatch({ id: b.id, rail: b.rail, bulk: b.bulk, title: b.title, wallet: { account_ref: b.account_ref } }, 20_000);
      const { rail } = await railFor(b.rail);
      if (rail.batchResults && num(b.processing) > 0) {
        for (const id of b.provider_batch_ids || []) {
          for (const v of await rail.batchResults(id)) {
            if (v.reference.startsWith('CNTP-') && v.status !== 'processing') await svc('svc_payout_update', { p_reference: v.reference, d: v });
          }
        }
      }
      out.batches = (out.batches as number) + 1;
    } catch (e) { console.log('poll batch', b.id, (e as Error).message); }
  }
  // Every run, the wallets with a sale waiting for a transfer to the business's number; twice an hour, every wallet and
  // tax wallet, for money paid straight into them.
  try { out.direct = await syncWallets(1, undefined, 'direct'); } catch (e) { console.log('poll direct', (e as Error).message); }
  if (new Date().getUTCMinutes() % 30 < 5) out.wallets = await syncWallets(1, undefined, 'all_and_tax');
  // The tax: moved into the tax wallets, and tax payments followed up.
  try { out.tax_transfers = await sendTaxTransfers(); } catch (e) { console.log('poll tax transfers', (e as Error).message); }
  try { out.tax_payments = await checkTaxPayments(); } catch (e) { console.log('poll tax payments', (e as Error).message); }
  try { out.tax_instructions = await taxInstructionWork(); } catch (e) { console.log('poll tax instructions', (e as Error).message); }
  return out;
}

async function reconcile() {
  const out: any[] = [];
  // Record everything the rail shows first, so the comparison is about real differences.
  await syncWallets(3, undefined, 'all_and_tax');
  for (const w of (await svc<any[]>('svc_work', { p_kind: 'wallets' })) || []) {
    try {
      const { rail } = await railFor(w.rail);
      if (!(await rail.configured())) continue;
      const b = await rail.balance(w.account_ref);
      const r = await svc('svc_wallet_balance', { p_wallet: w.id, p_available: b.available, p_ledger: b.ledger });
      out.push({ wallet: w.id, status: r.status, difference: r.difference });
    } catch (e) { out.push({ wallet: w.id, error: (e as Error).message }); }
  }
  for (const t of (await svc<any[]>('svc_work', { p_kind: 'tax_wallets' })) || []) {
    try {
      const { rail } = await railFor(t.rail);
      if (!(await rail.configured())) continue;
      const b = await rail.balance(t.account_ref);
      const r = await svc('svc_tax_wallet_balance', { p_wallet: t.id, p_available: b.available, p_ledger: b.ledger });
      out.push({ tax_wallet: t.id, difference: r.difference });
    } catch (e) { out.push({ tax_wallet: t.id, error: (e as Error).message }); }
  }
  return out;
}

// ------------------------------------------------------------------ webhooks
async function flutterwaveWebhook(req: Request) {
  const hash = await secret('FLW_WEBHOOK_HASH');
  const got = req.headers.get('verif-hash') || '';
  if (!hash || !got || !timingSafeEqual(hash, got)) return json({ ok: false }, 401);
  let body: any;
  try { body = await req.json(); } catch { return json({ ok: false }, 400); }
  const event = String(body?.event || body?.['event.type'] || 'unknown');
  const d = body?.data || {};
  const key = `${event}:${d.id ?? d.reference ?? d.tx_ref}:${d.status ?? ''}`;
  const fresh = await svc<boolean>('svc_event', { p_rail: 'flutterwave', p_event: event, p_key: key, p_payload: body });
  if (!fresh) return json({ ok: true, duplicate: true });
  let outcome = 'ignored', err: string | null = null;
  try {
    if (event === 'charge.completed' && String(d.tx_ref || '').startsWith('CNT-')) {
      const r = await settle(String(d.tx_ref), 'flutterwave', { name: d.customer?.name, email: d.customer?.email });
      outcome = r.paid ? 'paid' : `not_paid:${r.status}`;
    } else if (event === 'charge.completed') {
      // Not a Counta checkout: most likely a transfer into a wallet's own account. The wallets with a sale waiting for a
      // transfer are read first, so the till sees it at once; then the rest.
      later(syncWallets(1, undefined, 'direct').then(() => syncWallets(1, undefined, 'all_and_tax')));
      outcome = 'wallet_sync';
    } else if (event === 'transfer.completed') {
      const ref = String(d.reference || '');
      if (ref.startsWith('CNTP-')) {
        const { rail } = await railFor('flutterwave');
        const v = await rail.verifyPayout(ref, String(d.id || ''));
        if (v) await svc('svc_payout_update', { p_reference: ref, d: v });
        outcome = `payout:${v?.status}`;
      } else if (ref.startsWith('TAXB-')) {
        const ok = String(d.status).toUpperCase() === 'SUCCESSFUL';
        await svc('svc_tax_transfer_update', { p_reference: ref, p_status: ok ? 'done' : 'failed', p_error: ok ? null : d.complete_message || 'The transfer failed.',
          p_provider_ref: String(d.id || '') });
        outcome = 'tax_transfer';
      } else if (ref.startsWith('CNTX-')) {
        const { rail } = await railFor('flutterwave');
        const v = await rail.verifyPayout(ref, String(d.id || ''));
        if (v) await svc('svc_tax_payment_update', { p_reference: ref, d: v });
        outcome = `tax_payment:${v?.status}`;
      } else if (ref.startsWith('SWP-')) {
        const tx = ref.match(/^SWP-(CNT-[A-Z0-9]{16})/)?.[1];
        const ok = String(d.status).toUpperCase() === 'SUCCESSFUL';
        if (tx) await svc('svc_sweep_update', { p_tx_ref: tx, p_status: ok ? 'sent' : 'failed', p_error: ok ? null : d.complete_message, p_ref: ref });
        outcome = 'sweep';
      } else {
        // Money paid into a business wallet's own account number (reference PSA_...). The event does not say reliably which
        // wallet it reached, so Counta reads the wallets' statements at Flutterwave instead of trusting the event's fields.
        later(syncWallets(1, undefined, 'direct').then(() => syncWallets(1, undefined, 'all_and_tax')));
        outcome = 'wallet_sync';
      }
    }
  } catch (e) { err = (e as Error).message; outcome = 'error'; }
  await svc('svc_event_done', { p_rail: 'flutterwave', p_key: key, p_outcome: outcome, p_error: err, p_org: null });
  // Answer 200 even after an error: the poll re-checks with the rail, and a retry storm helps nobody.
  return json({ ok: true, outcome });
}

async function railWebhook(req: Request, code: string) {
  const { row, rail } = await railFor(code);
  if (row.kind !== 'http' || !row.webhook_secret) return json({ ok: false }, 404);
  const raw = await req.text();
  const key = await secret(row.webhook_secret);
  const sig = (req.headers.get('x-counta-signature') || '').replace(/^sha256=/, '');
  if (!key || !sig || !timingSafeEqual(await hmacHex(key, raw), sig)) return json({ ok: false }, 401);
  let body: any;
  try { body = JSON.parse(raw); } catch { return json({ ok: false }, 400); }
  const event = String(body.event || 'unknown'), d = body.data || {};
  const ek = `${event}:${d.tx_ref || d.reference || d.provider_ref}:${d.status || ''}`;
  if (!(await svc<boolean>('svc_event', { p_rail: code, p_event: event, p_key: ek, p_payload: body }))) return json({ ok: true, duplicate: true });
  let outcome = 'ignored', err: string | null = null;
  try {
    if (event === 'collection.paid' && d.tx_ref) outcome = (await settle(String(d.tx_ref), code)).paid ? 'paid' : 'not_paid';
    else if ((event === 'payout.completed' || event === 'payout.failed') && d.reference) {
      const v = await rail.verifyPayout(String(d.reference));
      if (v) await svc(String(d.reference).startsWith('CNTX-') ? 'svc_tax_payment_update' : 'svc_payout_update', { p_reference: d.reference, d: v });
      outcome = `payout:${v?.status}`;
    } else if ((event === 'move.completed' || event === 'move.failed') && String(d.reference || '').startsWith('TAXB-')) {
      await svc('svc_tax_transfer_update', { p_reference: String(d.reference), p_status: event === 'move.completed' ? 'done' : 'failed', p_error: d.error || null });
      outcome = 'tax_transfer';
    } else if (event === 'wallet.funded' && d.account_ref) {
      await svc('svc_wallet_inflow', { p_rail: code, p_account_ref: String(d.account_ref), d: { amount: num(d.amount), reference: d.reference,
        provider_ref: d.provider_ref || d.reference, narration: d.narration, sender: d.sender, at: d.at } });
      outcome = 'inflow';
    }
  } catch (e) { err = (e as Error).message; outcome = 'error'; }
  await svc('svc_event_done', { p_rail: code, p_key: ek, p_outcome: outcome, p_error: err, p_org: null });
  return json({ ok: true, outcome });
}

// ------------------------------------------------------------------ public payers
const publicChecks = new Map<string, number>();
function publicView(r: any) {
  if (!r) return null;
  return { method: r.method, status: r.status, amount: r.amount, account_number: r.account_number, bank_name: r.bank_name, account_name: r.account_name,
    link_url: r.link_url, qr_image: r.qr_image, expires_at: r.expires_at, direct: Boolean(r.direct), pay_ref: r.direct ? r.pay_ref : undefined,
    error: r.status === 'failed' ? 'This way of paying is not available right now.' : undefined };
}

// ------------------------------------------------------------------ entry
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405);
  const path = new URL(req.url).pathname;
  try {
    const wh = path.match(/\/webhook\/(flutterwave|rail\/([a-z0-9_]{2,32}))\/?$/);
    if (wh) return wh[1] === 'flutterwave' ? await flutterwaveWebhook(req) : await railWebhook(req, wh[2]);

    let body: any;
    try { body = await req.json(); } catch { return json({ ok: false, error: 'Invalid request.' }, 400); }
    const action = String(body.action || '');

    if (action === 'poll' || action === 'reconcile' || action === 'tax_instruction') {
      const hook = req.headers.get('x-counta-hook') || '';
      if (!hook || !timingSafeEqual(hook, await secret('PUSH_HOOK_SECRET'))) return json({ ok: false, error: 'Not allowed.' }, 401);
      // A payment request Flux has just posted (the taxstreem function passes it on): check it and pay it if everything agrees.
      if (action === 'tax_instruction') return json({ ok: true, result: await checkInstruction(String(body.instruction_id || '')) });
      return json({ ok: true, result: action === 'poll' ? await poll() : await reconcile() });
    }

    if (action === 'public_pay' || action === 'public_check') {
      const token = String(body.token || '');
      if (!/^[a-f0-9]{24,64}$/.test(token)) return json({ ok: false, error: 'Document not found.' }, 404);
      if (action === 'public_pay') {
        const ctx = await svc('svc_public_request', { p_token: token, p_method: String(body.method || 'account') });
        const r = await fillRequest(ctx);
        return json({ ok: true, request: publicView(r) });
      }
      const anon = createClient(SUPABASE_URL, ANON, { auth: { persistSession: false } });
      const { data: st } = await anon.rpc('public_payment_status', { p_token: token });
      // A payer's page checks every few seconds; the rail is asked at most every 15 seconds per document.
      const last = publicChecks.get(token) || 0;
      if (st?.request?.status === 'pending' && st.request.tx_ref && Date.now() - last > 15_000) {
        publicChecks.set(token, Date.now());
        if (publicChecks.size > 5000) publicChecks.clear();
        const ctx = await svc('svc_request_context', { p_request: st.request.id });
        if (ctx && st.request.direct) { if (ctx.wallet?.id) await syncOneWallet(ctx.wallet.id, 15_000); }
        else if (ctx) await settle(st.request.tx_ref, ctx.rail, undefined, st.request.id);
        const again = await anon.rpc('public_payment_status', { p_token: token });
        return json({ ok: true, status: again.data?.status, balance: again.data?.balance, request: publicView(again.data?.request) });
      }
      return json({ ok: true, status: st?.status, balance: st?.balance, request: publicView(st?.request) });
    }

    const authHeader = req.headers.get('Authorization') || '';
    const sb = createClient(SUPABASE_URL, ANON, { global: { headers: { Authorization: authHeader } }, auth: { persistSession: false } });
    const { data: u } = await sb.auth.getUser();
    if (!u?.user) return json({ ok: false, error: 'Sign in first.' }, 401);

    switch (action) {
      case 'status': {
        const { data, error } = await sb.rpc('get_payments', { p_org: body.org_id });
        if (error) throw new UserError(error.message);
        const { rail, row } = await railFor(data?.rail?.code || 'flutterwave');
        // Whether the rail can reach Counta: the shared webhook secret is set, and when the rail last sent a verified event.
        const webhookSecret = row.kind === 'flutterwave' ? 'FLW_WEBHOOK_HASH' : row.webhook_secret;
        const { data: last } = await admin.from('payment_events').select('received_at, event, outcome').eq('rail', row.code)
          .order('received_at', { ascending: false }).limit(1).maybeSingle();
        return json({ ok: true, configured: await rail.configured(), payments: data, webhook: {
          url: `${SUPABASE_URL}/functions/v1/payments/webhook/${row.kind === 'flutterwave' ? 'flutterwave' : `rail/${row.code}`}`,
          secret_set: Boolean(webhookSecret && (await secret(webhookSecret))), last_event: last || null } });
      }
      case 'open_wallet': {
        const mid = await memberOf(sb, body.org_id, u.user.id);
        const w = await svc('svc_wallet_to_open', { p_org: body.org_id, p_member: mid });
        let wallet = w.wallet;
        if (!w.ready) {
          const { rail } = await railFor(w.rail.code);
          try {
            wallet = await svc('svc_wallet_ready', { p_wallet: w.wallet.id, d: await rail.openWallet(w.org) });
          } catch (e) {
            await svc('svc_wallet_ready', { p_wallet: w.wallet.id, d: { error: (e as Error).message } });
            throw e;
          }
        }
        // Every business gets its tax wallet with its wallet. If that part fails, the wallet still works and the
        // Payments page offers to open the tax wallet again.
        let taxWallet: any = null, taxError: string | null = null;
        try { taxWallet = await openTaxWallet(body.org_id, mid); } catch (e) { taxError = (e as Error).message; }
        return json({ ok: true, wallet, tax_wallet: taxWallet, tax_error: taxError });
      }
      case 'open_tax_wallet': {
        const mid = await memberOf(sb, body.org_id, u.user.id);
        return json({ ok: true, tax_wallet: await openTaxWallet(body.org_id, mid) });
      }
      case 'tax_wallet_balance': {
        const { data, error } = await sb.rpc('get_tax_wallet', { p_org: body.org_id });
        if (error) throw new UserError(error.message);
        const t = data?.tax_wallet;
        if (!t || t.status !== 'active') throw new UserError('Open the tax wallet first.');
        const { rail } = await railFor(t.rail);
        const b = await rail.balance(t.account_ref);
        return json({ ok: true, balance: b, reconciliation: await svc('svc_tax_wallet_balance', { p_wallet: t.id, p_available: b.available, p_ledger: b.ledger }) });
      }
      case 'send_tax_payment': {
        // Checked before anything changes: without transfers switched on, the payment stays approved, ready to send later.
        const { data: pre } = await admin.from('tax_payments').select('wallet:tax_wallets(rail)').eq('id', body.payment_id).maybeSingle();
        const railCode = (pre as any)?.wallet?.rail;
        if (railCode && !(await transfersReady((await railFor(railCode)).row.kind))) throw new TransfersOff(TRANSFERS_OFF);
        const { data, error } = await sb.rpc('tax_payment_to_send', { p_payment: body.payment_id });
        if (error) throw new UserError(error.message);
        const p = data.payment;
        const { rail } = await railFor(data.rail);
        try {
          const r = await rail.payout({ ...p, purpose: 'tax' }, data.tax_wallet || {});
          return json({ ok: true, payment: await svc('svc_tax_payment_update', { p_reference: p.reference, d: { status: r.status, provider_ref: r.provider_ref, fee: r.fee, error: r.error } }) });
        } catch (e) {
          // Refused: nothing left the tax wallet. No answer: it stays "processing" until the rail says what happened.
          if (e instanceof UserError || e instanceof NotConfigured) {
            await svc('svc_tax_payment_update', { p_reference: p.reference, d: { status: 'failed', error: (e as Error).message } });
          }
          throw e;
        }
      }
      case 'request': {
        const { data: ctx, error } = await sb.rpc('create_payment_request', { p_org: body.org_id, p_request: {
          sale_id: body.sale_id, customer_id: body.customer_id, method: body.method, amount: body.amount, shift_id: body.shift_id } });
        if (error) throw new UserError(error.message);
        return json({ ok: true, request: await fillRequest(ctx) });
      }
      case 'activate': {
        const { error } = await sb.rpc('get_payment_request', { p_request: body.request_id });
        if (error) throw new UserError(error.message);
        const ctx = await svc('svc_request_context', { p_request: body.request_id });
        return json({ ok: true, request: await fillRequest(ctx) });
      }
      case 'check': {
        const { data: r, error } = await sb.rpc('get_payment_request', { p_request: body.request_id });
        if (error) throw new UserError(error.message);
        if (r.status === 'pending' && r.direct) {
          // A transfer to the business's own number: read the wallet's statement (at most every few seconds).
          const ctx = await svc('svc_request_context', { p_request: r.id });
          if (ctx?.wallet?.id) await syncOneWallet(ctx.wallet.id);
          const again = await sb.rpc('get_payment_request', { p_request: body.request_id });
          return json({ ok: true, request: again.data });
        }
        if (r.status === 'pending') {
          await settle(r.tx_ref, r.rail, undefined, r.id);
          const again = await sb.rpc('get_payment_request', { p_request: body.request_id });
          return json({ ok: true, request: again.data });
        }
        return json({ ok: true, request: r });
      }
      case 'send_payout': return json({ ok: true, payout: await sendPayout(sb, String(body.payout_id)) });
      case 'send_batch': return json({ ok: true, ...(await sendBatch(sb, String(body.batch_id))) });
      case 'balance': {
        const { data, error } = await sb.rpc('get_payments', { p_org: body.org_id });
        if (error) throw new UserError(error.message);
        if (!data?.wallet || data.wallet.status !== 'active') throw new UserError('Open the wallet first.');
        if (data.wallet.books_balance == null) throw new UserError('Your role does not see wallet balances.');
        const { rail } = await railFor(data.wallet.rail);
        const b = await rail.balance(data.wallet.account_ref);
        return json({ ok: true, balance: b, reconciliation: await svc('svc_wallet_balance', { p_wallet: data.wallet.id, p_available: b.available, p_ledger: b.ledger }) });
      }
      case 'relay_check': {
        // TaxStreem's staff only (the admin portal's Test button).
        const { data: me } = await sb.rpc('admin_me');
        if (!me?.admin || !me?.aal2) throw new UserError('This is only for TaxStreem\'s admins.');
        return json({ ok: true, relay: await relayCheck(), transfers_ready: await transfersReady() });
      }
      case 'banks': {
        const { rail } = await railFor(String(body.rail || 'flutterwave'));
        return json({ ok: true, banks: await rail.banks() });
      }
      case 'resolve_account': {
        if (!/^\d{10}$/.test(String(body.account_number || ''))) throw new UserError('Account numbers have 10 digits.');
        const { rail } = await railFor(String(body.rail || 'flutterwave'));
        return json({ ok: true, account_name: await rail.resolveAccount(String(body.account_number), String(body.bank_code)) });
      }
      default: return json({ ok: false, error: 'Unknown action.' }, 400);
    }
  } catch (e) {
    const user = e instanceof UserError;
    if (!user) console.error('payments', e);
    return json({ ok: false, reason: e instanceof NotConfigured ? 'not_configured' : user ? 'error' : 'server', error: (e as Error).message }, user ? 200 : 500);
  }
});
