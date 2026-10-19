// Counta messaging: invoices, receipts, orders, statements and payment reminders by email (Resend) and WhatsApp
// (WhatsApp Business Cloud API).
//
// Database (header x-counta-hook: <PUSH_HOOK_SECRET>):
//   { message_id }          -> sends one queued message
//   { action: 'retry' }     -> sends messages that are still queued or failed and can be tried again
// Signed-in callers (Authorization: Bearer <user JWT>):
//   { action: 'status' }    -> which channels are switched on
// Meta (WhatsApp delivery and read receipts):
//   GET  /messaging/whatsapp   -> webhook verification (hub.verify_token must equal WHATSAPP_VERIFY_TOKEN)
//   POST /messaging/whatsapp   -> header X-Hub-Signature-256 must be the HMAC of the body with WHATSAPP_APP_SECRET
//
// Secrets (Edge Function secrets or Vault): RESEND_API_KEY, RESEND_FROM ("Counta <billing@your-domain>"),
// WHATSAPP_TOKEN, WHATSAPP_PHONE_NUMBER_ID, WHATSAPP_APP_SECRET, WHATSAPP_VERIFY_TOKEN. Optional: WHATSAPP_TEMPLATE_LANG (default en).
// WhatsApp messages to customers use approved templates; their wording is in docs/messaging.md.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { emailHtml, emailText, type Msg, wording } from './wording.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const RESEND_URL = Deno.env.get('RESEND_BASE_URL') || 'https://api.resend.com';
const GRAPH_URL = Deno.env.get('WHATSAPP_GRAPH_URL') || 'https://graph.facebook.com/v21.0';
const admin = createClient(SUPABASE_URL, SERVICE, { auth: { persistSession: false } });

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-counta-hook',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

const cache = new Map<string, { v: string; at: number }>();
// Keys set in the admin portal (Supabase Vault) come first; the Edge Function secrets are the fallback.
async function secret(name: string): Promise<string> {
  // The database's hook secret keeps its old order: the Edge Function secret first.
  if (name === 'PUSH_HOOK_SECRET' && Deno.env.get(name)) return Deno.env.get(name)!.trim();
  const hit = cache.get(name);
  if (hit && Date.now() - hit.at < 60_000) return hit.v;
  let v = '';
  for (const fn of ['svc_secret', 'app_secret']) {
    const { data } = await admin.rpc(fn, { p_name: name });
    if (typeof data === 'string' && data.trim()) { v = data.trim(); break; }
  }
  if (!v) v = (Deno.env.get(name) || '').trim();
  cache.set(name, { v, at: Date.now() });
  return v;
}
// A channel TaxStreem has paused, for everyone or for one business.
async function channelOn(orgId: string | null, channel: string) {
  const { data } = await admin.rpc('svc_feature', { p_org: orgId, p_feature: channel === 'whatsapp' ? 'whatsapp' : 'email' });
  return data !== false;
}

function same(a: string, b: string) {
  const ea = new TextEncoder().encode(a), eb = new TextEncoder().encode(b);
  if (ea.length !== eb.length) return false;
  let r = 0;
  for (let i = 0; i < ea.length; i++) r |= ea[i] ^ eb[i];
  return r === 0;
}

async function hmacHex(key: string, body: string) {
  const k = await crypto.subtle.importKey('raw', new TextEncoder().encode(key), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return Array.from(new Uint8Array(await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(body)))).map((x) => x.toString(16).padStart(2, '0')).join('');
}

// ------------------------------------------------------------------ senders
// The address inside RESEND_FROM, whatever surrounds it: "billing@x.ng", "TaxStreem <billing@x.ng>", or either wrapped in quotes or spaces.
export function senderAddress(raw: string): string {
  const m = String(raw || '').match(/[A-Z0-9._%+-]+@[A-Z0-9-]+(?:\.[A-Z0-9-]+)*\.[A-Z]{2,}/i);
  return m ? m[0].toLowerCase() : '';
}
// A display name Resend accepts without quoting: no commas, quotes, brackets or @.
export function displayName(name: string): string {
  return `${String(name || 'Counta').replace(/[",;:<>()[\]\\@]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 60) || 'Counta'} via Counta`;
}
const storageUrl = (path?: string | null) => (path ? `${SUPABASE_URL}/storage/v1/object/public/item-photos/${path.split('/').map(encodeURIComponent).join('/')}` : null);

async function sendEmail(m: Msg): Promise<string> {
  const key = await secret('RESEND_API_KEY');
  const from = await secret('RESEND_FROM');
  if (!key || !from) throw new Error('Email is not switched on yet. TaxStreem is setting it up; the message goes out once it is.');
  // Shown as "Business name via Counta <billing@...>", replies go to the business.
  const addr = senderAddress(from);
  if (!addr) throw new Error('Email is not switched on yet: the sending address TaxStreem set has no email address in it.');
  const replyTo = m.params?.reply_to || m.org?.reply_to_email || m.org?.email;
  const cc = (Array.isArray(m.params?.cc) ? m.params.cc : []).filter((e: unknown) => typeof e === 'string' && senderAddress(e as string)).slice(0, 5);
  m.org = { ...m.org, logo_url: storageUrl(m.org?.logo_path) };
  const res = await fetch(`${RESEND_URL}/emails`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json', 'Idempotency-Key': `counta-${m.id}` },
    body: JSON.stringify({ from: `${displayName(m.org?.name)} <${addr}>`, to: [m.to_address], ...(cc.length ? { cc } : {}),
      subject: m.subject || wording(m).heading, html: emailHtml(m), text: emailText(m),
      ...(replyTo ? { reply_to: replyTo } : {}), tags: [{ name: 'template', value: m.template }] }),
    signal: AbortSignal.timeout(20_000),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`Resend: ${body?.message || body?.error || res.status}`);
  return String(body.id || '');
}

async function sendWhatsApp(m: Msg): Promise<string> {
  const token = await secret('WHATSAPP_TOKEN');
  const phoneId = await secret('WHATSAPP_PHONE_NUMBER_ID');
  if (!token || !phoneId) throw new Error('WhatsApp is not switched on yet. TaxStreem is setting it up; the message goes out once it is.');
  const w = wording(m);
  if (!w.wa) throw new Error('This message can only go by email.');
  const lang = (await secret('WHATSAPP_TEMPLATE_LANG')) || 'en';
  const res = await fetch(`${GRAPH_URL}/${phoneId}/messages`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      messaging_product: 'whatsapp', recipient_type: 'individual', to: m.to_address.replace(/[^0-9]/g, ''), type: 'template',
      template: { name: w.wa.name, language: { code: lang },
        components: [{ type: 'body', parameters: w.wa.params.map((t) => ({ type: 'text', text: String(t ?? '').replace(/\s+/g, ' ').slice(0, 900) || '-' })) }] },
    }),
    signal: AbortSignal.timeout(20_000),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    const e = body?.error;
    throw new Error(`WhatsApp: ${e?.error_user_msg || e?.message || res.status}${e?.code ? ` (code ${e.code})` : ''}`);
  }
  return String(body?.messages?.[0]?.id || '');
}

async function deliver(id: string) {
  // Customers' messages wait, untouched, while TaxStreem has paused the channel; invitations to the team still go.
  const { data: head } = await admin.from('messages').select('org_id, channel, template, status').eq('id', id).maybeSingle();
  if (head && head.template !== 'invite' && ['queued', 'failed'].includes(head.status) && !(await channelOn(head.org_id, head.channel))) {
    await admin.from('messages').update({ status: 'queued', error: `${head.channel === 'whatsapp' ? 'WhatsApp' : 'Email'} is paused for now by TaxStreem. The message goes out once it is back on.` }).eq('id', id);
    return { id, status: 'queued', paused: true };
  }
  const { data: m, error } = await admin.rpc('svc_message', { p_id: id });
  if (error) throw new Error(error.message);
  if (!m) return { id, skipped: true };
  // An invitation gets its one-time link now, so no usable link rests in the database.
  if (m.template === 'invite') {
    const { data: inv, error: ie } = await admin.rpc('svc_invite', { p_member: m.params?.member_id });
    if (ie || !inv) {
      await admin.rpc('svc_message_update', { p_id: id, p_status: 'failed', p_provider_id: null, p_error: ie?.message || 'This person has already joined or was removed.' });
      return { id, status: 'failed' };
    }
    m.params = { ...m.params, ...inv, customer_name: inv.name };
  }
  try {
    const providerId = m.channel === 'email' ? await sendEmail(m) : await sendWhatsApp(m);
    await admin.rpc('svc_message_update', { p_id: id, p_status: 'sent', p_provider_id: providerId || null, p_error: null });
    return { id, status: 'sent' };
  } catch (e) {
    const msg = (e as Error).message;
    // Not configured yet: leave it queued so it goes out once the keys are added.
    const status = /not switched on/.test(msg) ? 'queued' : 'failed';
    await admin.rpc('svc_message_update', { p_id: id, p_status: status, p_provider_id: null, p_error: msg });
    return { id, status, error: msg };
  }
}

// ------------------------------------------------------------------ WhatsApp webhook
async function whatsappWebhook(req: Request) {
  if (req.method === 'GET') {
    const u = new URL(req.url);
    const verify = await secret('WHATSAPP_VERIFY_TOKEN');
    if (u.searchParams.get('hub.mode') === 'subscribe' && verify && same(u.searchParams.get('hub.verify_token') || '', verify)) {
      return new Response(u.searchParams.get('hub.challenge') || '', { status: 200 });
    }
    return new Response('Forbidden', { status: 403 });
  }
  const raw = await req.text();
  const appSecret = await secret('WHATSAPP_APP_SECRET');
  const sig = (req.headers.get('x-hub-signature-256') || '').replace(/^sha256=/, '');
  if (!appSecret || !sig || !same(await hmacHex(appSecret, raw), sig)) return new Response('Forbidden', { status: 403 });
  let body: any;
  try { body = JSON.parse(raw); } catch { return new Response('Bad request', { status: 400 }); }
  let n = 0;
  for (const entry of body?.entry || []) {
    for (const change of entry?.changes || []) {
      for (const s of change?.value?.statuses || []) {
        const err = (s.errors || [])[0];
        await admin.rpc('svc_message_status', { p_provider_id: String(s.id), p_status: String(s.status),
          p_error: err ? `${err.title || err.message || 'Error'}${err.code ? ` (code ${err.code})` : ''}` : null });
        n++;
      }
    }
  }
  return json({ ok: true, statuses: n });
}

// ------------------------------------------------------------------ entry
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  const path = new URL(req.url).pathname;
  try {
    if (/\/whatsapp\/?$/.test(path)) return await whatsappWebhook(req);
    if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405);
    let body: any;
    try { body = await req.json(); } catch { return json({ ok: false, error: 'Invalid request.' }, 400); }

    const hook = req.headers.get('x-counta-hook') || '';
    if (hook) {
      if (!same(hook, await secret('PUSH_HOOK_SECRET'))) return json({ ok: false, error: 'Not allowed.' }, 401);
      if (body.message_id) return json({ ok: true, result: await deliver(String(body.message_id)) });
      if (body.action === 'retry') {
        const { data: ids } = await admin.rpc('svc_messages_retry');
        const results = [];
        for (const id of (ids as string[]) || []) results.push(await deliver(id));
        return json({ ok: true, results });
      }
      return json({ ok: false, error: 'Unknown action.' }, 400);
    }

    const sb = createClient(SUPABASE_URL, ANON, { global: { headers: { Authorization: req.headers.get('Authorization') || '' } }, auth: { persistSession: false } });
    const { data: u } = await sb.auth.getUser();
    if (!u?.user) return json({ ok: false, error: 'Sign in first.' }, 401);
    if (body.action === 'status') {
      const orgId = typeof body.org_id === 'string' && /^[0-9a-f-]{36}$/i.test(body.org_id) ? body.org_id : null;
      const sender = senderAddress(await secret('RESEND_FROM'));
      const emailOn = await channelOn(orgId, 'email'), waOn = await channelOn(orgId, 'whatsapp');
      return json({ ok: true, email: Boolean((await secret('RESEND_API_KEY')) && sender) && emailOn, sender: sender || null,
        sender_set: Boolean(await secret('RESEND_FROM')), email_key: Boolean(await secret('RESEND_API_KEY')),
        whatsapp: Boolean((await secret('WHATSAPP_TOKEN')) && (await secret('WHATSAPP_PHONE_NUMBER_ID'))) && waOn,
        paused: { email: !emailOn, whatsapp: !waOn } });
    }
    return json({ ok: false, error: 'Unknown action.' }, 400);
  } catch (e) {
    console.error('messaging', e);
    return json({ ok: false, error: (e as Error).message }, 500);
  }
});
