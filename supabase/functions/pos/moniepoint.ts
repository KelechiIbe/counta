// Moniepoint POS API (https://docs.pos.moniepoint.com, OpenAPI at https://api.pos.moniepoint.com/v3/api-docs): the calls Counta
// makes with a business's API key, how its webhooks are checked, and how its answers become one shape for the database.
//
// The key is created by the business owner in the Moniepoint Business app (POS Terminal Configuration, ERP Integration, POS App
// Developers) and is scoped to the businesses and the environment (sandbox or production) it was made for.
// Webhooks: headers moniepoint-webhook-id, moniepoint-webhook-timestamp and moniepoint-webhook-signature, the signature being the
// Base64 HMAC-SHA256 of "<id>__<timestamp>__<raw body>" with the subscription's secret.

export const MP_BASE = (Deno.env.get('MONIEPOINT_POS_BASE_URL') || 'https://api.pos.moniepoint.com').replace(/\/+$/, '');
// Sales only: card purchases and transfers taken on a terminal. Withdrawals, airtime, bills and the other agency services are
// not sales, so Counta does not subscribe to them.
export const MP_EVENTS = ['V1_POS_PURCHASE_TRANSACTION', 'V1_POS_TRANSFER_TRANSACTION'];
export const MP_SCOPES = ['transaction:push', 'transaction:read', 'webhook:read', 'webhook:write'];

export class MpError extends Error {
  constructor(message: string, public status = 0, public hard = false) { super(message); }
}

type Answer = { status: number; data: any };

async function call(key: string, method: string, path: string, body?: unknown, timeoutMs = 15_000): Promise<Answer> {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const res = await fetch(MP_BASE + path, {
      method,
      headers: { Authorization: `Bearer ${key}`, Accept: 'application/json', ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}) },
      body: body !== undefined ? JSON.stringify(body) : undefined,
      signal: ctl.signal,
    });
    const text = await res.text();
    let data: any = null;
    try { data = text ? JSON.parse(text) : null; } catch { data = { message: text.slice(0, 200) }; }
    return { status: res.status, data };
  } catch (e) {
    throw new MpError((e as Error).name === 'AbortError' ? 'Moniepoint did not answer in time.' : 'Counta could not reach Moniepoint.', 0);
  } finally {
    clearTimeout(timer);
  }
}

function said(a: Answer) {
  const d = a.data || {};
  const parts = [d.message, d.error, Array.isArray(d.errors) ? d.errors.join('; ') : null].filter((x) => typeof x === 'string' && x.trim());
  return parts.length ? parts.join(' · ').slice(0, 200) : `HTTP ${a.status}`;
}

function refused(a: Answer, what: string): never {
  if (a.status === 401) throw new MpError('Moniepoint did not accept the API key. Create a new one in the Moniepoint Business app and connect again.', 401, true);
  if (a.status === 403) throw new MpError(`The API key may not ${what}. Give it the permissions Counta lists and connect again.`, 403, true);
  throw new MpError(`Moniepoint refused to ${what}: ${said(a)}`, a.status);
}

export type Business = { id: string; name: string };
export async function introspect(key: string): Promise<{ environment: 'sandbox' | 'production'; scopes: string[]; businesses: Business[] }> {
  const a = await call(key, 'GET', '/v1/introspect');
  if (a.status !== 200) refused(a, 'check the key');
  const d = a.data || {};
  return {
    environment: String(d.environment || '').toUpperCase() === 'SANDBOX' ? 'sandbox' : 'production',
    scopes: Array.isArray(d.scopes) ? d.scopes.map(String) : [],
    businesses: (Array.isArray(d.businesses) ? d.businesses : []).map((b: any) => ({ id: String(b.id), name: String(b.businessName || b.name || '') }))
      .filter((b: Business) => b.id && b.id !== 'undefined'),
  };
}

export async function createSubscription(key: string, businessId: string, endpointUrl: string): Promise<string> {
  const a = await call(key, 'POST', '/v1/webhook-subscriptions', { endpointUrl, eventTypes: MP_EVENTS, businessId: Number(businessId) });
  if (a.status !== 200 && a.status !== 201) refused(a, 'send Counta the terminals\' payments');
  const id = String(a.data?.id || '');
  if (!id) throw new MpError('Moniepoint did not say which subscription it made.');
  return id;
}

export async function subscriptionSecret(key: string, subscriptionId: string): Promise<string> {
  const a = await call(key, 'GET', `/v1/webhook-subscriptions/${encodeURIComponent(subscriptionId)}/secret`);
  if (a.status !== 200) refused(a, 'give Counta the webhook secret');
  const s = String(a.data?.secret || '');
  if (!s) throw new MpError('Moniepoint gave no webhook secret.');
  return s;
}

export async function setBasicAuth(key: string, subscriptionId: string, username: string, password: string) {
  const a = await call(key, 'PUT', `/v1/webhook-subscriptions/${encodeURIComponent(subscriptionId)}/authentication`,
    { authenticationMethod: 'BASIC', username, password });
  if (a.status !== 200 && a.status !== 201 && a.status !== 204) refused(a, 'set the webhook password');
}

export async function deleteSubscription(key: string, subscriptionId: string) {
  const a = await call(key, 'DELETE', `/v1/webhook-subscriptions/${encodeURIComponent(subscriptionId)}`);
  if (a.status !== 200 && a.status !== 204 && a.status !== 404) refused(a, 'remove the webhook');
}

export const METHOD = { any: 'ANY', card: 'CARD_PURCHASE', transfer: 'POS_TRANSFER' } as const;

// Sends an amount to a terminal. A reference Moniepoint has seen already means the earlier send reached it: that counts as sent.
export async function push(key: string, p: { terminalSerial: string; amount: number; merchantReference: string; paymentMethod: string }) {
  const a = await call(key, 'POST', '/v1/transactions', { terminalSerial: p.terminalSerial, amount: p.amount, merchantReference: p.merchantReference,
    transactionType: 'PURCHASE', paymentMethod: p.paymentMethod }, 20_000);
  if (a.status === 200 || a.status === 201 || a.status === 202) return;
  if (a.status === 400 && /exist/i.test(said(a))) return;
  if (a.status === 401 || a.status === 403) refused(a, 'send amounts to the terminals');
  throw new MpError(plainPushError(said(a)), a.status);
}

function plainPushError(s: string) {
  if (/terminal|serial|device/i.test(s)) return `Moniepoint could not reach that terminal (${s}). Check it is on, online and has ERP Integration switched on.`;
  return `Moniepoint did not send the amount to the terminal: ${s}`;
}

// The transaction for a reference Counta sent, or null when Moniepoint has none.
export async function status(key: string, merchantReference: string): Promise<any | null> {
  const a = await call(key, 'GET', `/v1/transactions/merchants/${encodeURIComponent(merchantReference)}`);
  if (a.status === 404) return null;
  if (a.status !== 200) refused(a, 'say how the payment went');
  return a.data || null;
}

// One page of the subscription's events between two days (Lagos dates, inclusive).
export async function events(key: string, subscriptionId: string, from: string, to: string, page: number): Promise<{ content: any[]; last: boolean }> {
  const q = new URLSearchParams({ subscriptionId, from, to, page: String(page), size: '100' });
  const a = await call(key, 'GET', `/v1/webhook-subscription-events?${q}`);
  if (a.status !== 200) refused(a, 'show the terminals\' payments');
  const d = a.data || {};
  return { content: Array.isArray(d.content) ? d.content : [], last: d.last !== false || !Array.isArray(d.content) || d.content.length === 0 };
}

// One event by its id; the API answers a page of one.
export async function eventById(key: string, id: string): Promise<any | null> {
  const a = await call(key, 'GET', `/v1/webhook-subscription-events/${encodeURIComponent(id)}`);
  if (a.status === 404 || a.status === 400) return null;
  if (a.status !== 200) return null;
  const d = a.data || {};
  return Array.isArray(d.content) ? d.content[0] || null : d.id ? d : null;
}

function b64(bytes: Uint8Array) { let s = ''; for (const b of bytes) s += String.fromCharCode(b); return btoa(s); }
function same(a: string, b: string) {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  if (x.length !== y.length) return false;
  let r = 0;
  for (let i = 0; i < x.length; i++) r |= x[i] ^ y[i];
  return r === 0;
}
export async function signature(secret: string, id: string, timestamp: string, raw: string) {
  const k = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return b64(new Uint8Array(await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(`${id}__${timestamp}__${raw}`))));
}
export async function signatureOk(secret: string, id: string, timestamp: string, raw: string, got: string) {
  if (!secret || !id || !timestamp || !got) return false;
  return same(await signature(secret, id, timestamp, raw), got.trim());
}

// ------------------------------------------------------------------ one shape for the database
export type Txn = {
  transaction_ref: string; event_id?: string; event_type?: string; kind: 'card' | 'transfer' | 'other'; terminal_serial?: string; merchant_reference?: string;
  amount: number; fee: number; status: 'approved' | 'pending' | 'declined'; response_code?: string; response_message?: string; occurred_at?: string;
  payer: Record<string, string>; raw?: unknown; business_id?: string;
};

const APPROVED = ['APPROVED', 'SUCCESSFUL', 'SUCCESS', 'COMPLETED'];
const FAILED = ['DECLINED', 'FAILED', 'CANCELLED', 'CANCELED', 'REJECTED', 'EXPIRED', 'REVERSED'];

export function outcome(st: unknown, code: unknown): Txn['status'] {
  const s = String(st || '').toUpperCase(), c = String(code ?? '').trim();
  if (c === '00') return 'approved';
  if (FAILED.includes(s)) return 'declined';
  if (c === '09' || s === 'PENDING' || s === 'QUEUED') return 'pending';
  if (c && c !== '00') return 'declined';
  if (APPROVED.includes(s)) return 'approved';
  return 'pending';
}

export const naira = (minor: unknown, unit: 'kobo' | 'naira') => {
  const n = Number(minor);
  if (!Number.isFinite(n)) return 0;
  return unit === 'kobo' ? Math.round(n) / 100 : Math.round(n * 100) / 100;
};
export const minor = (amount: number, unit: 'kobo' | 'naira') => unit === 'kobo' ? Math.round(amount * 100) : Math.round(amount);

function kindOf(eventType: string, transactionType: string, method: string): Txn['kind'] | null {
  const e = (eventType || '').toUpperCase(), t = (transactionType || '').toUpperCase(), m = (method || '').toUpperCase();
  if (m === 'CARD_PURCHASE') return 'card';
  if (m === 'POS_TRANSFER') return 'transfer';
  if (e === 'V1_POS_PURCHASE_TRANSACTION' || t === 'PURCHASE') return 'card';
  if (e === 'V1_POS_TRANSFER_TRANSACTION' || t === 'POS_TRANSFER') return 'transfer';
  return null;
}

// A webhook body ({ data, eventId, eventType, createdAt, subject }), or an event from the history ({ eventType, payload }).
// Null when it is not a sale (agency services) or carries no reference.
export function fromEvent(body: any, unit: 'kobo' | 'naira'): Txn | null {
  const payload = typeof body?.payload === 'string' ? safeJson(body.payload) : body?.payload;
  const env = payload && payload.data ? payload : body;
  const d = env?.data || {};
  const eventType = String(env?.eventType || body?.eventType || '');
  const kind = kindOf(eventType, String(d.transactionType || ''), String(d.paymentMethod || d.actualPaymentMethod || ''));
  if (!kind) return null;
  const ref = String(d.transactionReference || '').trim();
  if (!ref) return null;
  return {
    transaction_ref: ref, event_id: String(env?.eventId || body?.idempotentId || body?.id || ''), event_type: eventType, kind,
    terminal_serial: d.terminalSerial ? String(d.terminalSerial) : undefined, merchant_reference: d.merchantReference ? String(d.merchantReference) : undefined,
    amount: naira(d.amount, unit), fee: 0, status: outcome(d.transactionStatus, d.responseCode), response_code: d.responseCode != null ? String(d.responseCode) : undefined,
    response_message: d.responseMessage ? String(d.responseMessage) : undefined, occurred_at: isoTime(d.transactionTime || env?.createdAt),
    payer: {}, raw: env, business_id: d.businessId != null ? String(d.businessId) : undefined,
  };
}

// The answer to GET /v1/transactions/merchants/{merchantReference}.
export function fromStatus(s: any, unit: 'kobo' | 'naira'): Txn & { processing: string } {
  const ps = String(s?.processingStatus || '').toUpperCase();
  const code = s?.responseCode != null ? String(s.responseCode) : '';
  let st: Txn['status'];
  if (code === '00') st = 'approved';
  else if (['CANCELLED', 'FAILED', 'REJECTED', 'EXPIRED'].includes(ps)) st = 'declined';
  else if (ps === 'PENDING' || code === '09' || (!code && !['SUCCESSFUL', 'COMPLETED'].includes(ps))) st = 'pending';
  else if (code) st = 'declined';
  else st = 'approved';
  const amt = s?.actualAmount != null ? s.actualAmount : s?.requestAmount;
  return {
    transaction_ref: String(s?.transactionReference || '').trim(), kind: kindOf('', String(s?.transactionType || ''), String(s?.actualPaymentMethod || '')) || 'other',
    terminal_serial: s?.terminalSerial ? String(s.terminalSerial) : undefined, merchant_reference: s?.merchantReference ? String(s.merchantReference) : undefined,
    amount: naira(amt, unit), fee: 0, status: st, response_code: code || undefined, response_message: s?.responseMessage ? String(s.responseMessage) : undefined,
    occurred_at: isoTime(s?.modifiedAt || s?.createdAt), payer: {}, raw: s, processing: ps,
  };
}

function safeJson(t: string) { try { return JSON.parse(t); } catch { return null; } }
function isoTime(v: unknown): string | undefined {
  if (!v) return undefined;
  const d = new Date(String(v));
  return Number.isNaN(d.getTime()) ? undefined : d.toISOString();
}
