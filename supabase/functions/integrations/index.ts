// Counta's connected tools (docs/integrations.md). Paid sales from Paystack, Flutterwave, Selar, WooCommerce, Shopify, Zapier
// or Make, and Bumpa's exported orders become paid sales in the books; Counta's alerts post to Slack.
//
// Signed-in callers (Authorization: Bearer <user JWT>; the database checks they manage the business's settings):
//   { action: 'connect', org_id, provider, key?, secret?, site?, shop?, url? } -> checks the key with the tool, keeps it in Vault
//                                                     and answers the webhook address (and secret hash) to paste into the tool
//   { action: 'sync', id }          -> asks the tool for new payments or orders now
//   { action: 'test', id }          -> checks the key still works (Slack: posts a hello)
//   { action: 'new_address', id }   -> a new webhook address (the old one stops working)
//   { action: 'bumpa_import', org_id, path } -> records the paid orders in a CSV exported from Bumpa, uploaded to <org>/imports/
// Webhooks (no sign-in; checked as each tool signs them):
//   POST /integrations/hook/paystack/<token>     x-paystack-signature: HMAC-SHA512 of the body with the business's key
//   POST /integrations/hook/flutterwave/<token>  verif-hash: the secret hash Counta made; the payment is then checked with Flutterwave
//   POST /integrations/hook/selar/<token>, /hook/zapier/<token>  the token in the address is the secret
// Database (x-counta-hook: <PUSH_HOOK_SECRET>): { action: 'poll' } every five minutes.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { bumpaOrders } from './csv.ts';
import {
  flwCheck, flwKeyOk, flwSale, flwSince, flwVerify, genericSale, hint, paystackCheck, paystackKeyOk, paystackSale, paystackSigned, paystackSince,
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
  const { data } = await admin.rpc('svc_secret', { p_name: 'PUSH_HOOK_SECRET' });
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
async function syncOne(id: string) {
  const c = await svc<any>('svc_integration', { p_integration: id });
  if (!c || c.status === 'paused') return { skipped: true };
  const since: string | null = c.cursor?.since || null;
  const started = new Date().toISOString();
  try {
    let sales: Sale[] = [];
    if (c.provider === 'paystack') sales = await paystackSince(c.secret, since);
    else if (c.provider === 'flutterwave') sales = await flwSince(c.secret, since);
    else if (c.provider === 'woocommerce') sales = await wooSince(c.settings.site, c.settings.consumer_key, c.secret, since);
    else if (c.provider === 'shopify') sales = await shopifySince(c.settings.shop, c.secret, since);
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
      : st >= 500 ? `${c.name} is having trouble (it answered ${st}). Counta keeps trying every few minutes.` : (e as Error).message;
    await svc('svc_integration_note', { p_integration: id, p: { error: msg, hard, synced: true } });
    return { ok: false, error: msg };
  }
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
    } else if (provider === 'bumpa') {
      // Nothing to check: orders come in as exported files.
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
  if (['paystack', 'flutterwave', 'woocommerce', 'shopify'].includes(provider)) first = await syncOne(saved.id);
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

