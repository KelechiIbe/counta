// Counta's connected tools (docs/integrations.md). Paid sales from Paystack, Flutterwave, Selar, WooCommerce, Shopify, Zapier
// or Make, and Bumpa (its API, or its exported orders) become paid sales in the books; Counta's alerts post to Slack; Bujeti's
// payments, fees, receipts, balances, vendors and invoices come into the books from its API.
//
// Signed-in callers (Authorization: Bearer <user JWT>; the database checks they manage the business's settings):
//   { action: 'connect', org_id, provider, key?, secret?, site?, shop?, url?, bumpa_location? } -> checks the key with the tool, keeps it in Vault
//                                                     and answers the webhook address (and secret hash) to paste into the tool
//   { action: 'sync', id }          -> asks the tool for new payments or orders now
//   { action: 'test', id }          -> checks the key still works (Slack: posts a hello)
//   { action: 'new_address', id }   -> a new webhook address (the old one stops working)
//   { action: 'bumpa_import', org_id, path } -> records the paid orders in a CSV exported from Bumpa, uploaded to <org>/imports/
// Webhooks (no sign-in; checked as each tool signs them):
//   POST /integrations/hook/paystack/<token>     x-paystack-signature: HMAC-SHA512 of the body with the business's key
//   POST /integrations/hook/flutterwave/<token>  verif-hash: the secret hash Counta made; the payment is then checked with Flutterwave
//   POST /integrations/hook/selar/<token>, /hook/zapier/<token>  the token in the address is the secret
// Database (x-counta-hook: <PUSH_HOOK_SECRET>): { action: 'poll' } every five minutes (Bujeti every fifteen).
import { createClient } from 'npm:@supabase/supabase-js@2';
import { bumpaOrders } from './csv.ts';
import {
  bujetiAssets, bujetiBalance, bujetiCategories, bujetiCheck, bujetiFile, bujetiInvoice, bujetiKeyOk, bujetiList, bujetiPayment, bujetiTransaction, bujetiVendor,
  fileName, scopeRefused,
} from './bujeti.ts';
import {
  bumpaCheck, bumpaKeyOk, bumpaLocationOk, bumpaSince, flwCheck, flwKeyOk, flwSale, flwSince, flwVerify, genericSale, hint, paystackCheck, paystackKeyOk,
  paystackSale, paystackSigned, paystackSince,
  same, type Sale, shopifyCheck, shopifySince, shopOk, slackHookOk, slackPost, token, ToolError, wooCheck, wooKeysOk, wooSince,
} from './providers.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const APP_URL = (Deno.env.get('APP_URL') || 'https://counta-taxstreem.netlify.app').replace(/\/+$/, '');
const admin = createClient(SUPABASE_URL, SERVICE, { auth: { persistSession: false } });
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
class UserError extends Error {}

async function svc<T = any>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await admin.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data as T;
}
async function hookSecret(): Promise<string> {
  const env = (Deno.env.get('PUSH_HOOK_SECRET') || '').trim();
  if (env) return env;
  // app_secret, as in the other functions: svc_secret only hands out the providers' keys, so it answers nothing for this one.
  const { data } = await admin.rpc('app_secret', { p_name: 'PUSH_HOOK_SECRET' });
  return typeof data === 'string' ? data.trim() : '';
}
const hookUrl = (provider: string, tok: string) => `${SUPABASE_URL}/functions/v1/integrations/hook/${provider}/${tok}`;

// ------------------------------------------------------------------ recording
async function record(id: string, sales: Sale[]) {
  const out = { recorded: 0, duplicate: 0, skipped: 0, failed: 0, messages: [] as string[] };
  for (const s of sales.slice(0, 200)) {
    const r = await svc<any>('svc_integration_sale', { p_integration: id, p: s });
    const k = (r?.status || 'failed') as keyof typeof out;
    if (k in out && typeof out[k] === 'number') (out[k] as number)++;
    if (r?.message && out.messages.length < 5) out.messages.push(`${s.reference || s.external_id}: ${r.message}`);
  }
  return out;
}

// The tool's new payments or orders since the last look; the cursor moves to the latest seen.
async function syncOne(id: string, quick = false) {
  const c = await svc<any>('svc_integration', { p_integration: id });
  if (!c || c.status === 'paused') return { skipped: true };
  const since: string | null = c.cursor?.since || null;
  const started = new Date().toISOString();
  try {
    if (c.provider === 'bujeti') {
      if (!c.secret) return { skipped: true };
      const r = await bujetiSync(c, quick);
      await svc('svc_integration_note', { p_integration: id, p: { cursor: r.cursor, error: null, synced: true } });
      return { ok: true, ...r.out };
    }
    let sales: Sale[] = [];
    if (c.provider === 'paystack') sales = await paystackSince(c.secret, since);
    else if (c.provider === 'flutterwave') sales = await flwSince(c.secret, since);
    else if (c.provider === 'woocommerce') sales = await wooSince(c.settings.site, c.settings.consumer_key, c.secret, since);
    else if (c.provider === 'shopify') sales = await shopifySince(c.settings.shop, c.secret, since);
    else if (c.provider === 'bumpa' && c.secret) sales = await bumpaSince(c.secret, c.settings?.bumpa_location || null, since);
    else if (c.provider === 'slack') return await slackSend(c);
    else return { skipped: true };
    const r = await record(id, sales);
    // A minute of overlap, so nothing paid at the edge is missed; what was recorded already is seen as a duplicate.
    const next = new Date(Date.parse(started) - 60_000).toISOString();
    await svc('svc_integration_note', { p_integration: id, p: { cursor: { since: next }, error: null, synced: true } });
    return { ok: true, found: sales.length, ...r };
  } catch (e) {
    const hard = refused(e);
    const st = e instanceof ToolError ? e.status : 0;
    const msg = [401, 403].includes(st) ? `${c.name} refused the key. Connect it again with a current key.`
      : st === 429 ? `${c.name} asked Counta to slow down. Counta tries again in a few minutes.`
      : st >= 500 ? `${c.name} is having trouble (it answered ${st}). Counta keeps trying every few minutes.` : (e as Error).message;
    await svc('svc_integration_note', { p_integration: id, p: { error: msg, hard, synced: true } });
    return { ok: false, error: msg };
  }
}

// ------------------------------------------------------------------ Bujeti
// One look: the balances; the categories and vendors once a day; the payments of the last ten days (45 once a day, to see
// late reversals), then older months from the start until the books are complete, a month at a time; payments still
// pending a day later; receipts not yet kept; and the invoices once an hour. The database decides what each one means.
async function bujetiSync(c: any, quick: boolean) {
  const key: string = c.secret, id: string = c.id;
  const cur = c.cursor || {}, next: Record<string, unknown> = {};
  const scopes = c.settings?.scopes || {};
  const st = await svc<any>('svc_bujeti_state', { p_integration: id });
  const now = Date.now(), stop = now + (quick ? 25_000 : 75_000);
  const out = { recorded: 0, waiting: 0, pending: 0, skipped: 0, failed: 0, reversed: 0, invoices: 0, paid: 0, receipts: 0, categories: 0, vendors: 0 };
  const iso = (t: number) => new Date(t).toISOString();
  const start = Date.parse(`${st.start}T00:00:00+01:00`);
  const send = async (rows: any[]) => {
    for (let k = 0; k < rows.length; k += 200) {
      const r = await svc<any>('svc_bujeti_payments', { p_integration: id, p_list: rows.slice(k, k + 200).map(bujetiPayment).filter((x) => x.code) });
      for (const f of ['recorded', 'waiting', 'pending', 'skipped', 'failed', 'reversed'] as const) out[f] += Number(r?.[f] || 0);
    }
  };
  const optional = async (scope: string, work: () => Promise<void>) => {
    if (scopes[scope] === false) return;
    try { await work(); } catch (e) { if (!scopeRefused(e)) throw e; }
  };

  await optional('balances', async () => {
    const { rows } = await bujetiList(key, '/balances', 'balances', {}, 1, 2, 100);
    await svc('svc_bujeti_balances', { p_integration: id, p_list: rows.map(bujetiBalance) });
  });
  if (!cur.lists_at || now - Date.parse(cur.lists_at) > 86400_000) {
    await optional('categories', async () => {
      const cats = bujetiCategories((await bujetiList(key, '/categories', 'categories', {}, 1, 4, 500)).rows);
      for (let k = 0; k < cats.length; k += 500) out.categories += Number((await svc<any>('svc_bujeti_categories', { p_integration: id, p_list: cats.slice(k, k + 500) }))?.categories || 0);
    });
    await optional('vendors', async () => {
      const vs = (await bujetiList(key, '/vendors', 'vendors', {}, 1, 4, 500)).rows.map(bujetiVendor).filter((v) => v.code && v.name);
      for (let k = 0; k < vs.length; k += 500) out.vendors += Number((await svc<any>('svc_bujeti_vendors', { p_integration: id, p_list: vs.slice(k, k + 500) }))?.added || 0);
    });
    next.lists_at = iso(now);
  }

  // Payments: the recent days every time.
  const deep = !cur.deep_at || now - Date.parse(cur.deep_at) > 86400_000;
  const recentFrom = Math.max(start, now - (deep ? 45 : 10) * 86400_000);
  const recent = await bujetiList(key, '/transactions', 'transactions', { from: iso(recentFrom), to: iso(now + 60_000) }, 1, 10, 500);
  await send(recent.rows);
  if (deep && !recent.next) next.deep_at = iso(now);
  // Older months, from the start, until they meet the recent days.
  let bf = cur.bf ? Date.parse(cur.bf) : start, page = Number(cur.bf_page) || 1;
  while (!quick && bf < recentFrom && Date.now() < stop) {
    // To the first of the next month in Lagos (UTC+1).
    const d = new Date(bf + 3600_000), end = Math.min(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 1) - 3600_000, recentFrom);
    const got = await bujetiList(key, '/transactions', 'transactions', { from: iso(bf), to: iso(Math.max(end, bf + 1000)) }, page, 4, 500);
    await send(got.rows);
    if (got.next) { page = got.next; next.bf = iso(bf); next.bf_page = page; break; }
    bf = Math.max(end, bf + 1000); page = 1; next.bf = iso(bf); next.bf_page = null;
  }
  // Payments still pending a day later, one by one.
  if (!quick) {
    const again: any[] = [];
    for (const code of (st.recheck || []) as string[]) {
      if (Date.now() > stop) break;
      try { const t = await bujetiTransaction(key, code); if (t?.code) again.push(t); }
      catch (e) { if (!(e instanceof ToolError && e.status === 404)) throw e; }
    }
    if (again.length) await send(again);
  }
  // Receipts people attached in Bujeti, kept in Documents (asked for after the payments, so today's are among them).
  if (!quick && scopes.assets !== false) {
    const due = (await svc<any>('svc_bujeti_state', { p_integration: id }))?.receipts || [];
    for (const code of due as string[]) {
      if (Date.now() > stop) break;
      let assets: any[] = [];
      try { assets = await bujetiAssets(key, code); }
      catch (e) { if (scopeRefused(e)) break; await svc('svc_bujeti_receipt', { p_integration: id, p: { code, failed: true } }); continue; }
      let kept = 0;
      for (const a of assets.slice(0, 5)) {
        try {
          const f = a?.url ? await bujetiFile(String(a.url)) : null;
          if (!f) continue;
          const name = fileName(a.name, f.type);
          const path = `${st.org_id}/documents/bank/bujeti/${code}/${String(a.code || kept + 1).replace(/[^A-Za-z0-9_-]/g, '').slice(0, 40)}-${name}`;
          const { error } = await admin.storage.from('documents').upload(path, f.bytes, { contentType: f.type, upsert: true });
          if (error) throw new Error(error.message);
          await svc('svc_bujeti_receipt', { p_integration: id, p: { code, asset: a.code || null, name: a.name || name, path, mime: f.type, size: f.bytes.length } });
          kept++; out.receipts++;
        } catch { /* this one is tried again next time */ }
      }
      if (!kept) await svc('svc_bujeti_receipt', { p_integration: id, p: assets.length ? { code, failed: true } : { code, none: true } });
    }
  }
  // Invoices to customers, once an hour.
  if (!quick && (!cur.inv_at || now - Date.parse(cur.inv_at) > 3600_000)) {
    await optional('invoices', async () => {
      const inv = (await bujetiList(key, '/invoices', 'invoices', { from: iso(start - 31 * 86400_000) }, 1, 4, 500)).rows.map(bujetiInvoice).filter((v) => v.code);
      for (let k = 0; k < inv.length; k += 200) {
        const r = await svc<any>('svc_bujeti_invoices', { p_integration: id, p_list: inv.slice(k, k + 200) });
        out.invoices += Number(r?.recorded || 0); out.paid += Number(r?.paid || 0);
      }
      next.inv_at = iso(now);
    });
  }
  return { out, cursor: next };
}

async function slackSend(c: any) {
  const items: any[] = await svc('svc_slack_outbox', { p_integration: c.id });
  if (!items.length) { await svc('svc_integration_note', { p_integration: c.id, p: { synced: true } }); return { ok: true, posted: 0 }; }
  try {
    for (const x of items) {
      const link = x.url ? `${APP_URL}${String(x.url).startsWith('/') ? '' : '/'}${x.url}` : APP_URL;
      await slackPost(c.secret, `${x.title}${x.body ? `\n${x.body}` : ''}`, [
        { type: 'section', text: { type: 'mrkdwn', text: `*${esc(x.title)}*${x.body ? `\n${esc(x.body)}` : ''}` } },
        { type: 'context', elements: [{ type: 'mrkdwn', text: `<${link}|Open in Counta>` }] },
      ]);
    }
    await svc('svc_integration_note', { p_integration: c.id, p: { cursor: { since: items[items.length - 1].at }, error: null, synced: true } });
    return { ok: true, posted: items.length };
  } catch (e) {
    await svc('svc_integration_note', { p_integration: c.id, p: { error: (e as Error).message, hard: refused(e), synced: true } });
    return { ok: false, error: (e as Error).message };
  }
}
// The tool said the key or address is no good (not that it was down): the connection needs attention at once.
const refused = (e: unknown) => e instanceof ToolError && [401, 403, 404, 410].includes(e.status ?? 0);
const esc = (s: string) => String(s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

// ------------------------------------------------------------------ connecting
async function connect(sb: any, b: any) {
  const orgId = String(b.org_id || ''), provider = String(b.provider || '');
  const { data: who, error } = await sb.rpc('integration_check', { p_org: orgId, p_provider: provider });
  if (error) throw new UserError(error.message);
  const p: Record<string, unknown> = { org_id: orgId, provider, member_id: who.member_id };
  const answer: Record<string, unknown> = {};
  const keep = (k: string) => { p.secret = k; p.secret_hint = hint(k); };
  const newHook = (withSecret = false) => {
    const t = token(24); p.hook_token = t; answer.webhook_url = hookUrl(provider, t);
    if (withSecret) { const s = token(16); p.hook_secret = s; answer.secret_hash = s; }
  };
  try {
    if (provider === 'paystack') {
      const k = String(b.key || '').trim();
      if (!paystackKeyOk(k)) throw new UserError('Paste the secret key from Paystack, Settings, API keys. It starts sk_live_ (or sk_test_ to try it).');
      const r = await paystackCheck(k); keep(k); newHook();
      p.settings = { live: r.live };
    } else if (provider === 'flutterwave') {
      const k = String(b.key || '').trim();
      if (!flwKeyOk(k)) throw new UserError('Paste the secret key from Flutterwave, Settings, API keys. It starts FLWSECK- and ends -X.');
      const r = await flwCheck(k); keep(k); newHook(true);
      p.settings = { live: r.live };
    } else if (provider === 'woocommerce') {
      const ck = String(b.key || '').trim(), cs = String(b.secret || '').trim();
      if (!wooKeysOk(ck, cs)) throw new UserError('Paste the consumer key (ck_...) and consumer secret (cs_...) from WooCommerce, Settings, Advanced, REST API, with Read access.');
      const r = await wooCheck(String(b.site || ''), ck, cs); keep(cs);
      p.settings = { site: r.site, consumer_key: ck }; p.label = r.site.replace(/^https?:\/\//, '');
    } else if (provider === 'shopify') {
      const shop = String(b.shop || '').trim().toLowerCase().replace(/^https?:\/\//, '').replace(/\/.*$/, '');
      const t = String(b.key || '').trim();
      if (!shopOk(shop)) throw new UserError('Enter the shop\'s myshopify.com address, for example kelandellen.myshopify.com.');
      if (!/^shpat_[0-9a-f]{32}$/.test(t)) throw new UserError('Paste the Admin API access token of a custom app (it starts shpat_), with read_orders access.');
      const r = await shopifyCheck(shop, t); keep(t);
      p.settings = { shop, currency: r.currency }; p.label = r.name;
    } else if (provider === 'slack') {
      const u = String(b.url || '').trim();
      if (!slackHookOk(u)) throw new UserError('Paste the incoming webhook URL from Slack. It starts https://hooks.slack.com/services/.');
      await slackPost(u, `Counta is connected. ${who.org_name}'s alerts will post here.`);
      keep(u); p.settings = { kinds: Array.isArray(b.kinds) && b.kinds.length ? b.kinds : ['payments', 'tax'] };
    } else if (provider === 'selar' || provider === 'zapier') {
      newHook();
    } else if (provider === 'bujeti') {
      const k = String(b.key || '').trim();
      if (!bujetiKeyOk(k)) throw new UserError('Paste the API key from Bujeti (Settings, Developers), whole.');
      const scopes = await bujetiCheck(k); keep(k);
      p.settings = { scopes };
    } else if (provider === 'bumpa') {
      // With the store's secret key, paid orders come in every few minutes; without one, as exported files.
      const k = String(b.key || '').trim(), loc = String(b.bumpa_location || '').trim();
      if (k) {
        if (!bumpaKeyOk(k)) throw new UserError('Paste the secret API key you made in your Bumpa dashboard (app.getbumpa.com), whole.');
        if (loc && !bumpaLocationOk(loc)) throw new UserError('The Bumpa location ID has letters, digits, hyphens or underscores only. Leave it empty for the store\'s main location.');
        await bumpaCheck(k, loc || null); keep(k);
        p.settings = { api: true, ...(loc ? { bumpa_location: loc } : {}) };
      }
    } else {
      throw new UserError('Unknown tool.');
    }
  } catch (e) {
    if (e instanceof UserError) throw e;
    if (e instanceof ToolError) throw new UserError(e.status === 401 || e.status === 403 ? 'The tool refused that key. Copy it again, whole.' : e.message);
    throw e;
  }
  if (b.location_id) p.settings = { ...(p.settings as object || {}), location_id: String(b.location_id) };
  const saved = await svc<any>('svc_integration_save', { p });
  // A first look at what was paid in the last two days, so the connection shows its work at once.
  let first = null;
  if (['paystack', 'flutterwave', 'woocommerce', 'shopify'].includes(provider) || (provider === 'bumpa' && p.secret)) first = await syncOne(saved.id);
  // Bujeti: the balance, the categories and vendors, and the last few weeks of payments now; the older months and the
  // invoices follow within a few minutes.
  if (provider === 'bujeti') first = await syncOne(saved.id, true);
  return { ok: true, integration: saved, ...answer, first };
}

async function bumpaImport(sb: any, b: any) {
  const orgId = String(b.org_id || ''), path = String(b.path || '');
  const { data: who, error } = await sb.rpc('integration_check', { p_org: orgId, p_provider: 'bumpa' });
  if (error) throw new UserError(error.message);
  if (!path.startsWith(`${orgId}/imports/`) || path.includes('..') || !/\.csv$/i.test(path)) throw new UserError('Upload the CSV through Counta.');
  const { data: blob, error: de } = await admin.storage.from('documents').download(path);
  if (de || !blob) throw new UserError('Counta could not find the uploaded file. Upload it again.');
  if (blob.size > 5_000_000) throw new UserError('The file is larger than 5 MB. Export a shorter period.');
  const parsed = bumpaOrders(await blob.text());
  if (!parsed.sales.length) {
    throw new UserError(parsed.skipped[0]?.reason === 'No column for the amount (Total or Amount).'
      ? 'Counta could not find the order totals in that file. Export orders from Bumpa as CSV and upload that file.' : 'No paid orders in that file.');
  }
  const integ = who.existing || await svc<any>('svc_integration_save', { p: { org_id: orgId, provider: 'bumpa', member_id: who.member_id } });
  const r = await record(integ.id, parsed.sales);
  await svc('svc_integration_note', { p_integration: integ.id, p: { synced: true, error: null } });
  return { ok: true, orders: parsed.sales.length, rows: parsed.rows, skipped_rows: parsed.skipped.slice(0, 20), columns: parsed.columns, ...r };
}

// ------------------------------------------------------------------ webhooks
async function webhook(req: Request, provider: string, tok: string) {
  const raw = await req.text();
  if (raw.length > 256_000) return json({ ok: false }, 413);
  const id = await svc<string | null>('svc_integration_by_token', { p_provider: provider, p_token: tok });
  if (!id) return json({ ok: false }, 404);
  const c = await svc<any>('svc_integration', { p_integration: id });
  let body: any;
  try { body = JSON.parse(raw); } catch { return json({ ok: false, error: 'not json' }, 400); }
  let sale: Sale | null = null;
  if (provider === 'paystack') {
    if (!(await paystackSigned(raw, req.headers.get('x-paystack-signature'), c.secret))) return json({ ok: false }, 401);
    if (body?.event !== 'charge.success') return json({ ok: true, ignored: body?.event || 'unknown' });
    sale = paystackSale(body.data || {});
  } else if (provider === 'flutterwave') {
    if (!c.hook_secret || !same(String(req.headers.get('verif-hash') || ''), c.hook_secret)) return json({ ok: false }, 401);
    const d = body?.data || {};
    if (!['charge.completed'].includes(String(body?.event || body?.['event.type'] || '')) || String(d.status).toLowerCase() !== 'successful') return json({ ok: true, ignored: true });
    // Only what Flutterwave confirms, by the transaction's id, with the business's own key.
    const v = await flwVerify(c.secret, String(d.id)).catch(() => null);
    if (!v || String(v.status).toLowerCase() !== 'successful') return json({ ok: true, unconfirmed: true });
    sale = flwSale(v);
  } else {
    sale = genericSale(body, provider);
    if (!sale) return json({ ok: false, error: 'Send the payment\'s id and amount.' }, 422);
  }
  if (!sale) return json({ ok: true, ignored: true });
  const r = await svc<any>('svc_integration_sale', { p_integration: id, p: sale });
  return json({ ok: true, status: r?.status, number: r?.number || null, message: r?.message || null });
}

// ------------------------------------------------------------------ entry
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  const path = new URL(req.url).pathname;
  try {
    const hk = path.match(/\/hook\/(paystack|flutterwave|selar|zapier)\/([0-9a-f]{48})\/?$/);
    if (hk) return req.method === 'POST' ? await webhook(req, hk[1], hk[2]) : json({ ok: false }, 405);
    if (/\/hook\//.test(path)) return json({ ok: false }, 404);
    if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405);
    let body: any;
    try { body = await req.json(); } catch { return json({ ok: false, error: 'Invalid request.' }, 400); }
    const hook = req.headers.get('x-counta-hook') || '';
    if (hook) {
      if (!same(hook, await hookSecret())) return json({ ok: false, error: 'Not allowed.' }, 401);
      if (body.action !== 'poll') return json({ ok: false, error: 'Unknown action.' }, 400);
      const due: any[] = await svc('svc_integrations_due', {});
      const results: unknown[] = [];
      // The database's call gives up after 15 seconds, so on Supabase the looking carries on after the answer, for up to
      // two minutes; whatever is left waits for the next poll (the longest-waiting go first).
      const work = (async () => {
        const stop = Date.now() + 120_000;
        for (const d of due.slice(0, 40)) {
          if (Date.now() > stop) break;
          results.push({ id: d.id, provider: d.provider, ...(await syncOne(d.id).catch((e) => ({ ok: false, error: (e as Error).message }))) });
        }
      })();
      const rt = (globalThis as any).EdgeRuntime;
      if (rt?.waitUntil) { rt.waitUntil(work); return json({ ok: true, started: Math.min(due.length, 40) }); }
      await work;
      return json({ ok: true, results });
    }
    const sb = createClient(SUPABASE_URL, ANON, { global: { headers: { Authorization: req.headers.get('Authorization') || '' } }, auth: { persistSession: false } });
    const { data: u } = await sb.auth.getUser();
    if (!u?.user) return json({ ok: false, error: 'Sign in first.' }, 401);
    if (body.action === 'connect') return json(await connect(sb, body));
    if (body.action === 'bumpa_import') return json(await bumpaImport(sb, body));
    if (['sync', 'test', 'new_address'].includes(body.action)) {
      const { data: m, error } = await sb.rpc('integration_manage', { p_integration: String(body.id || '') });
      if (error) throw new UserError(error.message);
      if (body.action === 'sync') return json({ ok: true, ...(await syncOne(m.id)) });
      if (body.action === 'new_address') {
        if (!['paystack', 'flutterwave', 'selar', 'zapier'].includes(m.provider)) throw new UserError(`${m.name} has no webhook address.`);
        const t = token(24), s = m.provider === 'flutterwave' ? token(16) : undefined;
        const { data: who } = await sb.rpc('integration_check', { p_org: m.org_id, p_provider: m.provider });
        await svc('svc_integration_save', { p: { org_id: m.org_id, provider: m.provider, member_id: who.member_id, hook_token: t, ...(s ? { hook_secret: s } : {}) } });
        return json({ ok: true, webhook_url: hookUrl(m.provider, t), ...(s ? { secret_hash: s } : {}) });
      }
      const c = await svc<any>('svc_integration', { p_integration: m.id });
      try {
        if (c.provider === 'paystack') await paystackCheck(c.secret);
        else if (c.provider === 'flutterwave') await flwCheck(c.secret);
        else if (c.provider === 'woocommerce') await wooCheck(c.settings.site, c.settings.consumer_key, c.secret);
        else if (c.provider === 'shopify') await shopifyCheck(c.settings.shop, c.secret);
        else if (c.provider === 'bumpa' && c.secret) await bumpaCheck(c.secret, c.settings?.bumpa_location || null);
        else if (c.provider === 'bujeti') {
          // What the key may read now; the next look fetches the lists and invoices again, in case it may read more.
          await svc('svc_bujeti_state', { p_integration: m.id, p: { scopes: await bujetiCheck(c.secret) } });
          await svc('svc_integration_note', { p_integration: m.id, p: { cursor: { lists_at: null, inv_at: null } } });
        }
        else if (c.provider === 'slack') await slackPost(c.secret, 'A test from Counta. Alerts post here.');
        await svc('svc_integration_note', { p_integration: m.id, p: { error: null } });
        return json({ ok: true, working: true });
      } catch (e) {
        const msg = e instanceof ToolError ? e.message : (e as Error).message;
        await svc('svc_integration_note', { p_integration: m.id, p: { error: msg, hard: refused(e) } });
        return json({ ok: false, error: msg });
      }
    }
    return json({ ok: false, error: 'Unknown action.' }, 400);
  } catch (e) {
    if (e instanceof UserError) return json({ ok: false, error: e.message });
    if (e instanceof ToolError) return json({ ok: false, error: e.message });
    console.error('integrations', e);
    return json({ ok: false, error: (e as Error).message }, 500);
  }
});

