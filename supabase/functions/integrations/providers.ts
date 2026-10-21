// The tools a business connects, each turned into the same thing: a paid sale Counta records (svc_integration_sale).
// Every call to a tool carries the business's own key; nothing here keeps it.

export type Sale = {
  external_id: string; occurred_at: string | null; amount: number; fee: number; currency: string; reference?: string | null; method?: 'card' | 'transfer' | 'other';
  note?: string | null; customer?: { name?: string | null; email?: string | null; phone?: string | null }; lines?: { name: string; sku?: string | null; qty: number; unit_price: number }[];
};
export class ToolError extends Error { constructor(msg: string, public status = 0) { super(msg); } }

const env = (k: string, d: string) => (Deno.env.get(k) || d).replace(/\/+$/, '');
export const PAYSTACK = () => env('PAYSTACK_BASE_URL', 'https://api.paystack.co');
export const FLW = () => env('FLW_BASE_URL', 'https://api.flutterwave.com/v3');
// Shops and sites the business names: only real public https addresses (tests may allow their own host).
const TEST_HOSTS = () => (Deno.env.get('INTEGRATIONS_TEST_HOSTS') || '').split(',').map((s) => s.trim()).filter(Boolean);
export function publicUrl(raw: string): URL {
  let u: URL;
  try { u = new URL(raw.trim()); } catch { throw new ToolError('That address is not complete. Copy it from the browser, starting https://'); }
  if (TEST_HOSTS().includes(u.origin)) return u;
  if (u.protocol !== 'https:') throw new ToolError('Use the https:// address of the site.');
  const h = u.hostname.toLowerCase();
  if (/^(localhost|.*\.local|.*\.internal)$/.test(h) || /^[\d.]+$/.test(h) || h.includes(':') || !h.includes('.')) throw new ToolError('Use the public address of the site.');
  if (u.username || u.password) throw new ToolError('Leave the user name and password out of the address.');
  return u;
}

async function getJson(url: string, init: RequestInit = {}, timeout = 20_000): Promise<any> {
  let res: Response;
  try { res = await fetch(url, { ...init, redirect: 'manual', signal: AbortSignal.timeout(timeout) }); }
  catch (e) { throw new ToolError((e as Error).name === 'TimeoutError' ? 'The tool did not answer in time.' : 'Counta could not reach the tool.'); }
  const text = await res.text();
  let body: any = null;
  try { body = text ? JSON.parse(text) : null; } catch { body = null; }
  if (res.status >= 300 && res.status < 400) throw new ToolError('The address moved. Use the address the site shows now.', res.status);
  if (!res.ok) {
    const msg = body?.message || body?.errors?.[0]?.message || body?.errors || body?.error || `answered ${res.status}`;
    throw new ToolError(typeof msg === 'string' ? msg.slice(0, 200) : `answered ${res.status}`, res.status);
  }
  return body;
}
const n = (v: unknown) => { const x = Number(v); return Number.isFinite(x) ? x : 0; };
const r2 = (v: number) => Math.round(v * 100) / 100;

// ------------------------------------------------------------------ Paystack (the business's own account)
export const paystackKeyOk = (k: string) => /^sk_(live|test)_[0-9A-Za-z]{20,}$/.test(k);
export async function paystackCheck(key: string) {
  const b = await getJson(`${PAYSTACK()}/balance`, { headers: { Authorization: `Bearer ${key}` } });
  if (b?.status !== true) throw new ToolError('Paystack did not accept the key.');
  return { live: key.startsWith('sk_live_') };
}
export function paystackSale(d: any): Sale {
  const c = d?.customer || {};
  return { external_id: `ps:${d.id}`, occurred_at: d.paid_at || d.paidAt || d.created_at || null, amount: r2(n(d.amount) / 100), fee: r2(n(d.fees) / 100),
    currency: String(d.currency || 'NGN'), reference: d.reference || null, method: d.channel === 'bank_transfer' || d.channel === 'bank' ? 'transfer' : 'card',
    customer: { name: [c.first_name, c.last_name].filter(Boolean).join(' ') || null, email: c.email || null, phone: c.phone || null },
    note: d.metadata?.custom_fields?.[0]?.value ? String(d.metadata.custom_fields[0].value).slice(0, 120) : null };
}
export async function paystackSince(key: string, since: string | null) {
  const from = since || new Date(Date.now() - 2 * 86400_000).toISOString();
  const b = await getJson(`${PAYSTACK()}/transaction?status=success&perPage=100&from=${encodeURIComponent(from)}`, { headers: { Authorization: `Bearer ${key}` } });
  const rows: any[] = Array.isArray(b?.data) ? b.data : [];
  return rows.map(paystackSale);
}
// x-paystack-signature: HMAC-SHA512 of the raw body with the secret key.
export async function paystackSigned(raw: string, header: string | null, key: string) {
  const k = await crypto.subtle.importKey('raw', new TextEncoder().encode(key), { name: 'HMAC', hash: 'SHA-512' }, false, ['sign']);
  const want = hex(new Uint8Array(await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(raw))));
  return same(want, String(header || '').toLowerCase());
}

// ------------------------------------------------------------------ Flutterwave (the business's own account)
export const flwKeyOk = (k: string) => /^FLWSECK(_TEST)?-[0-9A-Za-z]{20,}-X$/.test(k);
export async function flwCheck(key: string) {
  const b = await getJson(`${FLW()}/balances`, { headers: { Authorization: `Bearer ${key}` } });
  if (b?.status !== 'success') throw new ToolError('Flutterwave did not accept the key.');
  return { live: !key.includes('_TEST') };
}
export function flwSale(d: any): Sale {
  const c = d?.customer || {};
  return { external_id: `flw:${d.id}`, occurred_at: d.created_at || null, amount: r2(n(d.amount)), fee: r2(n(d.app_fee)), currency: String(d.currency || 'NGN'),
    reference: d.tx_ref || d.flw_ref || null, method: d.payment_type === 'bank_transfer' ? 'transfer' : 'card',
    customer: { name: c.name || null, email: c.email || null, phone: c.phone_number || null }, note: d.narration ? String(d.narration).slice(0, 120) : null };
}
export async function flwVerify(key: string, id: string) {
  const b = await getJson(`${FLW()}/transactions/${encodeURIComponent(id)}/verify`, { headers: { Authorization: `Bearer ${key}` } });
  return b?.data || null;
}
export async function flwSince(key: string, since: string | null) {
  const from = (since || new Date(Date.now() - 2 * 86400_000).toISOString()).slice(0, 10);
  const b = await getJson(`${FLW()}/transactions?status=successful&from=${from}&page=1`, { headers: { Authorization: `Bearer ${key}` } });
  const rows: any[] = Array.isArray(b?.data) ? b.data : [];
  return rows.filter((d) => String(d.status).toLowerCase() === 'successful').map(flwSale);
}

// ------------------------------------------------------------------ WooCommerce
export const wooKeysOk = (k: string, s: string) => /^ck_[0-9a-f]{40}$/.test(k) && /^cs_[0-9a-f]{40}$/.test(s);
const wooAuth = (k: string, s: string) => ({ Authorization: `Basic ${btoa(`${k}:${s}`)}` });
export async function wooCheck(site: string, k: string, s: string) {
  const u = publicUrl(site);
  const b = await getJson(`${u.origin}${u.pathname.replace(/\/+$/, '')}/wp-json/wc/v3/orders?per_page=1`, { headers: wooAuth(k, s) });
  if (!Array.isArray(b)) throw new ToolError('The site did not answer as a WooCommerce store.');
  return { site: `${u.origin}${u.pathname.replace(/\/+$/, '')}` };
}
export function wooSale(o: any, site: string): Sale {
  const b = o?.billing || {};
  return { external_id: `woo:${o.id}`, occurred_at: o.date_paid_gmt ? `${o.date_paid_gmt}Z` : o.date_created_gmt ? `${o.date_created_gmt}Z` : null,
    amount: r2(n(o.total)), fee: 0, currency: String(o.currency || 'NGN'), reference: `#${o.number || o.id}`, method: 'other',
    customer: { name: [b.first_name, b.last_name].filter(Boolean).join(' ') || null, email: b.email || null, phone: b.phone || null },
    lines: (o.line_items || []).map((l: any) => ({ name: String(l.name || 'Item'), sku: l.sku || null, qty: n(l.quantity) || 1,
      unit_price: r2((n(l.total) + n(l.total_tax)) / (n(l.quantity) || 1)) })).concat(n(o.shipping_total) > 0
      ? [{ name: 'Delivery', sku: null, qty: 1, unit_price: r2(n(o.shipping_total) + n(o.shipping_tax)) }] : []),
    note: `Order ${o.number || o.id} on ${site.replace(/^https?:\/\//, '')}` };
}
export async function wooSince(site: string, k: string, s: string, since: string | null) {
  const after = (since || new Date(Date.now() - 2 * 86400_000).toISOString()).slice(0, 19);
  const b = await getJson(`${site}/wp-json/wc/v3/orders?status=processing,completed&per_page=50&orderby=date&order=asc&after=${encodeURIComponent(after)}`, { headers: wooAuth(k, s) });
  return (Array.isArray(b) ? b : []).filter((o) => o.date_paid_gmt || o.status === 'completed').map((o) => wooSale(o, site));
}

// ------------------------------------------------------------------ Shopify (a custom app's Admin API token)
export const shopOk = (shop: string) => /^[a-z0-9][a-z0-9-]{1,60}\.myshopify\.com$/.test(shop);
const shopBase = (shop: string) => (Deno.env.get('SHOPIFY_BASE_URL') || 'https://{shop}/admin/api/2026-07').replace('{shop}', shop).replace(/\/+$/, '');
export async function shopifyCheck(shop: string, token: string) {
  const b = await getJson(`${shopBase(shop)}/shop.json`, { headers: { 'X-Shopify-Access-Token': token } });
  if (!b?.shop) throw new ToolError('Shopify did not accept the token.');
  return { name: String(b.shop.name || shop), currency: String(b.shop.currency || 'NGN') };
}
export function shopifySale(o: any): Sale {
  const c = o?.customer || {};
  const ship = (o.shipping_lines || []).reduce((a: number, s: any) => a + n(s.price), 0);
  return { external_id: `shop:${o.id}`, occurred_at: o.processed_at || o.created_at || null, amount: r2(n(o.total_price)), fee: 0, currency: String(o.currency || 'NGN'),
    reference: o.name || null, method: 'other',
    customer: { name: [c.first_name, c.last_name].filter(Boolean).join(' ') || null, email: o.email || c.email || null, phone: o.phone || c.phone || null },
    lines: (o.line_items || []).map((l: any) => ({ name: String(l.title || 'Item'), sku: l.sku || null, qty: n(l.quantity) || 1,
      unit_price: r2(n(l.price) - n(l.total_discount) / (n(l.quantity) || 1)) })).concat(ship > 0 ? [{ name: 'Delivery', sku: null, qty: 1, unit_price: r2(ship) }] : []),
    note: o.name ? `Shopify order ${o.name}` : null };
}
export async function shopifySince(shop: string, token: string, since: string | null) {
  const min = since || new Date(Date.now() - 2 * 86400_000).toISOString();
  const b = await getJson(`${shopBase(shop)}/orders.json?status=any&financial_status=paid&limit=100&updated_at_min=${encodeURIComponent(min)}`,
    { headers: { 'X-Shopify-Access-Token': token } });
  return (b?.orders || []).filter((o: any) => o.financial_status === 'paid' && !o.cancelled_at).map(shopifySale);
}

// ------------------------------------------------------------------ Bumpa (a store's secret key, Commerce API v1, in public beta)
// docs.bumpa.io gives the routes and filters but no sample answers yet, so an order is read by the names Bumpa uses in its
// exports and its Laravel paginator, with fallbacks. Orders carry the number the store sees, the same number the CSV export
// carries, so an order imported both ways is recorded once.
export const BUMPA = () => env('BUMPA_BASE_URL', 'https://api.getbumpa.com/api/commerce/v1');
export const bumpaKeyOk = (k: string) => /^[A-Za-z0-9][A-Za-z0-9_\-.:|]{19,199}$/.test(k);
export const bumpaLocationOk = (l: string) => /^[A-Za-z0-9_-]{1,64}$/.test(l);
const bumpaHead = (key: string) => ({ 'X-Api-Key': key, Accept: 'application/json' });
const bumpaLoc = (loc?: string | null) => (loc ? `&location_id=${encodeURIComponent(loc)}` : '');
const pick = (o: any, ...keys: string[]) => {
  for (const k of keys) { const v = k.split('.').reduce((x: any, p) => (x == null ? x : x[p]), o); if (v != null && v !== '') return v; }
  return null;
};
// The orders on one page of Bumpa's answer, and whether there is another page.
function bumpaPage(b: any): { orders: any[]; more: boolean } {
  const p = b?.orders ?? b?.data ?? null;
  if (Array.isArray(p)) return { orders: p, more: false };
  const orders = Array.isArray(p?.data) ? p.data : [];
  return { orders, more: Boolean(p?.next_page_url) || (n(p?.current_page) > 0 && n(p?.current_page) < n(p?.last_page)) };
}
export async function bumpaCheck(key: string, loc?: string | null) {
  const b = await getJson(`${BUMPA()}/orders?limit=1${bumpaLoc(loc)}`, { headers: bumpaHead(key) });
  if (!b || b.success === false || !(b.orders || b.data)) throw new ToolError('Bumpa did not accept the key.', 401);
  return { ok: true };
}
export const bumpaPaid = (o: any) => {
  const s = String(pick(o, 'payment_status', 'paymentStatus', 'payment.status') ?? (o?.is_paid === true || o?.paid === true ? 'paid' : '')).toLowerCase();
  const st = String(pick(o, 'status', 'order_status') ?? '').toLowerCase();
  return /^(paid|success(ful)?|complete(d)?)$/.test(s) && !/^(cancel+ed|refunded|voided?)$/.test(st);
};
export function bumpaSale(o: any): Sale {
  const no = String(pick(o, 'order_number', 'order_no', 'orderNumber', 'reference', 'code', 'id') ?? '').replace(/^#/, '');
  const c = o?.customer || {};
  const items: any[] = pick(o, 'items', 'order_items', 'products', 'line_items') || [];
  const ship = n(pick(o, 'shipping_fee', 'delivery_fee', 'shipping_cost', 'shipping.amount', 'shipping_amount'));
  const lines = (Array.isArray(items) ? items : []).map((l: any) => {
    const qty = n(pick(l, 'quantity', 'qty')) || 1;
    const unit = n(pick(l, 'price', 'unit_price', 'selling_price', 'amount')) || (n(pick(l, 'total', 'subtotal')) / qty);
    return { name: String(pick(l, 'product_name', 'name', 'title', 'product.name') || 'Item').slice(0, 200), sku: pick(l, 'sku', 'product.sku'), qty, unit_price: r2(unit) };
  }).concat(ship > 0 ? [{ name: 'Delivery', sku: null, qty: 1, unit_price: r2(ship) }] : []);
  return { external_id: `bumpa:${no}`.slice(0, 200), occurred_at: pick(o, 'paid_at', 'payment_date', 'created_at', 'order_date', 'date'),
    amount: r2(n(pick(o, 'total', 'total_amount', 'grand_total', 'amount', 'total_price'))), fee: 0, currency: String(pick(o, 'currency', 'currency_code') || 'NGN'),
    reference: no ? `#${no}` : null, method: 'other',
    customer: { name: pick(o, 'customer_name') || pick(c, 'name', 'full_name') || [c.first_name, c.last_name].filter(Boolean).join(' ') || null,
      email: pick(o, 'customer_email') || c.email || null, phone: pick(o, 'customer_phone') || c.phone || c.phone_number || null },
    lines: lines.length ? lines : undefined, note: no ? `Bumpa order ${no}` : 'Bumpa order' };
}
// Paid orders from the day before the last look, oldest first, up to five pages of 50.
export async function bumpaSince(key: string, loc: string | null | undefined, since: string | null) {
  const from = (since || new Date(Date.now() - 2 * 86400_000).toISOString()).slice(0, 10);
  const to = new Date(Date.now() + 86400_000).toISOString().slice(0, 10);
  const out: Sale[] = [];
  for (let page = 1; page <= 5; page++) {
    const b = await getJson(`${BUMPA()}/orders?payment_status=paid&from_date=${from}&to_date=${to}&orderByField=created_at&orderBy=asc&limit=50&page=${page}${bumpaLoc(loc)}`,
      { headers: bumpaHead(key) });
    const { orders, more } = bumpaPage(b);
    // Bumpa filters by day; orders already seen on an earlier look that day are left out here rather than recorded again.
    const after = since ? Date.parse(since) : 0;
    for (const o of orders) {
      if (!bumpaPaid(o) || !(n(pick(o, 'total', 'total_amount', 'grand_total', 'amount', 'total_price')) > 0)) continue;
      const sale = bumpaSale(o), at = Date.parse(String(sale.occurred_at || ''));
      if (after && Number.isFinite(at) && at < after) continue;
      out.push(sale);
    }
    if (!more || !orders.length) break;
  }
  return out;
}

// ------------------------------------------------------------------ Selar, Zapier and Make: a sale posted to Counta's address
// Selar's sale notifications and Zapier's or Make's webhooks differ in shape; the common names for the same things are read.
export function genericSale(b: any, prefix: string): Sale | null {
  const d = b?.data && typeof b.data === 'object' ? b.data : b;
  const pick = (...keys: string[]) => { for (const k of keys) { const v = k.split('.').reduce((o: any, p) => (o == null ? o : o[p]), d); if (v != null && v !== '') return v; } return null; };
  const id = pick('id', 'transaction_id', 'reference', 'order_id', 'sale_id', 'tx_ref', 'payment_reference');
  const amount = n(pick('amount', 'total', 'amount_paid', 'price', 'total_amount', 'value'));
  if (!id || !(amount > 0)) return null;
  const kobo = String(pick('amount_unit', 'unit') || '').toLowerCase() === 'kobo';
  const qty = n(pick('quantity', 'qty')) || 1;
  const product = pick('product_name', 'product.name', 'product', 'item_name', 'item', 'title', 'description');
  const amt = r2(kobo ? amount / 100 : amount);
  return { external_id: `${prefix}:${String(id).slice(0, 180)}`, occurred_at: pick('paid_at', 'created_at', 'date', 'timestamp'), amount: amt,
    fee: r2(n(pick('fee', 'fees', 'charges')) / (kobo ? 100 : 1)), currency: String(pick('currency') || 'NGN'), reference: String(pick('reference', 'order_id', 'id')).slice(0, 80),
    method: 'other', customer: { name: pick('customer_name', 'customer.name', 'buyer_name', 'name'), email: pick('customer_email', 'customer.email', 'buyer_email', 'email'),
      phone: pick('customer_phone', 'customer.phone', 'buyer_phone', 'phone') },
    lines: product && typeof product === 'string' ? [{ name: product.slice(0, 200), sku: pick('sku', 'product.sku'), qty, unit_price: r2(amt / qty) }] : undefined };
}

// ------------------------------------------------------------------ Slack (an incoming webhook)
export const slackHookOk = (u: string) => /^https:\/\/hooks\.slack\.com\/services\/[A-Za-z0-9_/-]{20,200}$/.test(u) || TEST_HOSTS().some((h) => u.startsWith(h + '/'));
export async function slackPost(hook: string, text: string, blocks?: unknown[]) {
  let res: Response;
  try { res = await fetch(hook, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ text, ...(blocks ? { blocks } : {}) }), redirect: 'manual', signal: AbortSignal.timeout(15_000) }); }
  catch { throw new ToolError('Counta could not reach Slack.'); }
  const t = await res.text();
  if (!res.ok) throw new ToolError(res.status === 404 || /no_service|invalid_token|channel_not_found/.test(t) ? 'Slack no longer takes posts at that address. Make a new incoming webhook.' : `Slack answered ${res.status}.`, res.status);
}

// ------------------------------------------------------------------ small helpers
export const hex = (b: Uint8Array) => Array.from(b).map((x) => x.toString(16).padStart(2, '0')).join('');
export function same(a: string, b: string) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
export const token = (bytes = 24) => hex(crypto.getRandomValues(new Uint8Array(bytes)));
export const hint = (s: string) => s.slice(-4);
