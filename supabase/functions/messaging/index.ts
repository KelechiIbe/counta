// Counta messaging: invoices, receipts, orders, statements and payment reminders by email (Resend) and WhatsApp
// (WhatsApp Business Cloud API).
//
// Database (header x-counta-hook: <PUSH_HOOK_SECRET>):
//   { message_id }          -> sends one queued message
//   { action: 'retry' }     -> sends messages that are still queued or failed and can be tried again
// Signed-in callers (Authorization: Bearer <user JWT>):
//   { action: 'status' }    -> which channels are switched on
//   { action: 'wa_link', org_id }   -> links the business's own WhatsApp number on OpenWA (when TaxStreem allows it):
//                                      starts its session and answers the QR code to scan
//   { action: 'wa_status', org_id } -> the business's own number: its state, and the QR code while it waits for a scan
//   { action: 'wa_unlink', org_id } -> unlinks it; messages go from TaxStreem's number again
//   { action: 'practice_email', kind: 'member'|'client'|'accountant', id }
//                                   -> emails an accountant-portal invitation (to a practice's new staff, from a practice to a
//                                      business owner, or from a business to its accountant) with a fresh one-time link
// Meta (WhatsApp delivery and read receipts):
//   GET  /messaging/whatsapp   -> webhook verification (hub.verify_token must equal WHATSAPP_VERIFY_TOKEN)
//   POST /messaging/whatsapp   -> header X-Hub-Signature-256 must be the HMAC of the body with WHATSAPP_APP_SECRET
// OpenWA (delivery receipts and session changes):
//   POST /messaging/openwa     -> header X-OpenWA-Signature must be the HMAC of the body with OPENWA_WEBHOOK_SECRET
//
// Which WhatsApp sends: WHATSAPP_PROVIDER, openwa (TaxStreem's number on its OpenWA server, or the business's own linked
// number) or meta (the official API). Empty means openwa once OPENWA_URL and OPENWA_API_KEY are set, else meta.
// Secrets (Edge Function secrets or Vault): RESEND_API_KEY, RESEND_FROM ("Counta <billing@your-domain>"),
// WHATSAPP_TOKEN, WHATSAPP_PHONE_NUMBER_ID, WHATSAPP_APP_SECRET, WHATSAPP_VERIFY_TOKEN, OPENWA_URL, OPENWA_API_KEY,
// OPENWA_WEBHOOK_SECRET. Optional: WHATSAPP_TEMPLATE_LANG (default en), OPENWA_BUSINESS_NUMBERS (on lets businesses link
// their own number). Messages through the official API use approved templates (docs/messaging.md); through OpenWA they
// are plain text with the same wording.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { emailHtml, emailText, first, type Msg, wording } from './wording.ts';
import { ensureSession, type OpenWa, owa, owaError, RECEIPT_EVENTS, sendText, sessionState, setWebhooks, signatureOk, waDigits, waFormat } from './openwa.ts';

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
const CACHE_MS = Number(Deno.env.get('SECRET_CACHE_MS') || 60_000);
// Keys set in the admin portal (Supabase Vault) come first; the Edge Function secrets are the fallback.
async function secret(name: string): Promise<string> {
  // The database's hook secret keeps its old order: the Edge Function secret first.
  if (name === 'PUSH_HOOK_SECRET' && Deno.env.get(name)) return Deno.env.get(name)!.trim();
  const hit = cache.get(name);
  if (hit && Date.now() - hit.at < CACHE_MS) return hit.v;
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
  // Counta's own alerts to the owner come from Counta, with nowhere to reply to; customers' messages come from the business.
  const own = m.template === 'alert';
  const replyTo = own ? null : m.params?.reply_to || m.org?.reply_to_email || m.org?.email;
  const cc = (Array.isArray(m.params?.cc) ? m.params.cc : []).filter((e: unknown) => typeof e === 'string' && senderAddress(e as string)).slice(0, 5);
  m.org = { ...m.org, logo_url: storageUrl(m.org?.logo_path) };
  const res = await fetch(`${RESEND_URL}/emails`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json', 'Idempotency-Key': `counta-${m.id}` },
    body: JSON.stringify({ from: `${own ? 'Counta' : displayName(m.org?.name)} <${addr}>`, to: [m.to_address], ...(cc.length && !own ? { cc } : {}),
      subject: m.subject || wording(m).heading, html: emailHtml(m), text: emailText(m),
      ...(replyTo ? { reply_to: replyTo } : {}), tags: [{ name: 'template', value: m.template }] }),
    signal: AbortSignal.timeout(20_000),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`Resend: ${body?.message || body?.error || res.status}`);
  return String(body.id || '');
}

// ------------------------------------------------------------------ WhatsApp: OpenWA or the official API
async function openwaCfg(): Promise<OpenWa | null> {
  const url = await secret('OPENWA_URL'), key = await secret('OPENWA_API_KEY');
  return url && key ? { url, key } : null;
}
async function provider(): Promise<'openwa' | 'meta'> {
  const p = (await secret('WHATSAPP_PROVIDER')).toLowerCase();
  if (p === 'meta' || p === 'openwa') return p;
  return (await openwaCfg()) ? 'openwa' : 'meta';
}
const NOT_ON = 'WhatsApp is not switched on yet. TaxStreem is setting it up; the message goes out once it is.';

// The same words as the email, as WhatsApp text.
export function waText(m: Msg): string {
  const w = wording(m) as ReturnType<typeof wording> & { greet?: string; footer?: string };
  const p = m.params || {};
  const hello = `Hello ${w.greet ?? first(p.customer_name)},`;
  const biz = p.business || m.org?.name || '';
  return waFormat(w.heading, [hello, '', ...w.lines], w.link, w.button, w.footer || (biz ? `Sent for ${biz} by Counta` : 'Sent by Counta'));
}

async function sendOpenWa(m: Msg): Promise<string> {
  const cfg = await openwaCfg();
  if (!cfg) throw new Error(NOT_ON);
  const { data: s } = await admin.rpc('svc_wa_sender', { p_org: m.org_id || null });
  if (!s?.session || s.status !== 'ready') throw new Error(NOT_ON.replace('yet. TaxStreem is setting it up', 'at the moment: the WhatsApp number is not connected'));
  const phone = waDigits(m.to_address);
  if (!phone) throw new Error('That phone number does not look right for WhatsApp.');
  return await sendText(cfg, String(s.session), phone, waText(m));
}

async function sendWhatsApp(m: Msg): Promise<string> {
  if ((await provider()) === 'openwa') return await sendOpenWa(m);
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
        components: [{ type: 'body', parameters: w.wa.params.map((t: unknown) => ({ type: 'text', text: String(t ?? '').replace(/\s+/g, ' ').slice(0, 900) || '-' })) }] },
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

// ------------------------------------------------------------------ OpenWA webhook: receipts and session changes
const OWA_STATUS: Record<string, string> = { sent: 'sent', delivered: 'delivered', read: 'read', failed: 'failed', played: 'read' };

async function adminEmail(subject: string, text: string) {
  const k = await secret('RESEND_API_KEY'), from = senderAddress(await secret('RESEND_FROM'));
  if (!k || !from) return;
  const { data: to } = await admin.rpc('svc_admin_emails');
  const list = (Array.isArray(to) ? to : []).filter((e: unknown) => typeof e === 'string').slice(0, 20);
  if (!list.length) return;
  await fetch(`${RESEND_URL}/emails`, { method: 'POST', headers: { Authorization: `Bearer ${k}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from: `Counta admin <${from}>`, to: list, subject, text }), signal: AbortSignal.timeout(15_000) }).catch(() => null);
}

async function openwaWebhook(req: Request) {
  if (req.method !== 'POST') return new Response('POST only', { status: 405 });
  const raw = await req.text();
  if (!(await signatureOk(raw, req.headers.get('x-openwa-signature'), await secret('OPENWA_WEBHOOK_SECRET')))) return new Response('Forbidden', { status: 403 });
  let b: any;
  try { b = JSON.parse(raw); } catch { return new Response('Bad request', { status: 400 }); }
  // A delivery more than two days old is a replay; one already handled is a retry.
  if (b?.timestamp && Date.parse(b.timestamp) < Date.now() - 2 * 86400_000) return json({ ok: true, stale: true });
  const { data: fresh } = await admin.rpc('svc_openwa_seen', { p_id: String(req.headers.get('x-openwa-delivery-id') || b?.deliveryId || b?.idempotencyKey || '') });
  if (fresh === false) return json({ ok: true, duplicate: true });
  const event = String(b?.event || req.headers.get('x-openwa-event') || ''), d = b?.data || {}, session = String(b?.sessionId || d?.sessionId || '');
  if (event === 'message.ack' || event === 'message.failed') {
    const status = event === 'message.failed' ? 'failed' : OWA_STATUS[String(d.status || '')];
    if (status && (d.messageId || d.id)) {
      await admin.rpc('svc_message_status', { p_provider_id: String(d.messageId || d.id), p_status: status,
        p_error: status === 'failed' ? String(d.error || d.reason || 'WhatsApp could not deliver it.').slice(0, 300) : null });
    }
    return json({ ok: true });
  }
  if (event.startsWith('session.') && session) {
    const status = event === 'session.authenticated' ? 'ready' : event === 'session.disconnected' ? 'disconnected'
      : event === 'session.restriction' ? 'action_required' : String(d.status || '');
    const { data: saved } = await admin.rpc('svc_wa_session_save', { p: { id: session, status: status || null, phone: d.phone || null, push_name: d.pushName || null,
      ...(event === 'session.disconnected' || event === 'session.restriction' ? { last_error: String(d.reason || d.message || event).slice(0, 300) } : {}) } });
    const before = saved?.before, now = saved?.now;
    // TaxStreem's own number dropping stops Martina on WhatsApp and every message: every admin hears at once.
    if (now?.kind === 'counta' && before?.status === 'ready' && now.status !== 'ready') {
      await adminEmail('Counta: the WhatsApp number on OpenWA is not connected',
        `OpenWA reports the session for TaxStreem's WhatsApp number as "${now.status}"${now.last_error ? ` (${now.last_error})` : ''}.\n\nWhatsApp messages wait in Counta and Martina cannot answer on WhatsApp until it is connected again. Open the admin portal, Keys and services, WhatsApp through OpenWA, and press Connect to see what it needs (often a new QR code to scan).${event === 'session.restriction' ? '\n\nWhatsApp has restricted the number. Stop sending from it and check the phone it belongs to.' : ''}`);
    }
    return json({ ok: true });
  }
  return json({ ok: true, ignored: event });
}

// ------------------------------------------------------------------ a business's own number
async function businessNumber(sb: any, orgId: string, action: string) {
  const { data: who, error } = await sb.rpc('whatsapp_link_check', { p_org: orgId });
  if (error) return { ok: false, error: error.message };
  const cfg = await openwaCfg();
  if (!cfg || (await provider()) !== 'openwa') return { ok: false, reason: 'not_configured', error: 'Linking your own number is not available yet. Messages go from TaxStreem\'s WhatsApp number.' };
  const sess = who.session as any;
  if (action === 'wa_unlink') {
    if (sess?.id) {
      await owa(cfg, `/sessions/${encodeURIComponent(sess.id)}/logout`, { method: 'POST', body: {} });
      await admin.rpc('svc_wa_session_save', { p: { id: sess.id, status: 'unlinked', last_error: null } });
    }
    await admin.from('orgs').update({ whatsapp_sender: 'counta' }).eq('id', orgId);
    return { ok: true, status: 'unlinked' };
  }
  if (action === 'wa_link') {
    if ((await secret('OPENWA_BUSINESS_NUMBERS')).toLowerCase() !== 'on') {
      return { ok: false, reason: 'off', error: 'TaxStreem has not switched on linking your own number yet. Messages go from TaxStreem\'s WhatsApp number.' };
    }
    const hookSecret = await secret('OPENWA_WEBHOOK_SECRET');
    if (!hookSecret) return { ok: false, reason: 'not_configured', error: 'WhatsApp is still being set up by TaxStreem.' };
    let s: any;
    try {
      s = await ensureSession(cfg, `org-${orgId.slice(0, 8)}`);
      await setWebhooks(cfg, String(s.id), `${SUPABASE_URL}/functions/v1/`, hookSecret, [{ url: `${SUPABASE_URL}/functions/v1/messaging/openwa`, events: RECEIPT_EVENTS }]);
    } catch (e) { return { ok: false, error: `The WhatsApp server did not set up the link: ${(e as Error).message}` }; }
    await admin.rpc('svc_wa_session_save', { p: { id: String(s.id), kind: 'business', org_id: orgId, name: String(s.name || ''), status: String(s.status || 'created'),
      created_by: who.user_id } });
  }
  // The session just made (when linking), or the one already there.
  const id = action === 'wa_link'
    ? (await admin.from('whatsapp_sessions').select('id').eq('kind', 'business').eq('org_id', orgId).maybeSingle()).data?.id
    : sess?.id;
  if (!id) return { ok: true, status: 'none' };
  const st = await sessionState(cfg, String(id));
  if (!['unreachable', 'missing'].includes(st.status)) {
    await admin.rpc('svc_wa_session_save', { p: { id, status: st.status, phone: st.phone, push_name: st.push_name } });
  }
  return { ok: true, status: st.status, phone: st.phone, qr: st.qr || null, error: st.status === 'unreachable' ? st.error : undefined };
}

// ------------------------------------------------------------------ the accountant portal's invitations
// The person asking must be allowed to send it (the database checks, as them); the link is made only now, as the email goes.
async function practiceEmail(sb: any, kind: string, id: string) {
  if (!['member', 'client', 'accountant'].includes(kind) || !/^[0-9a-f-]{36}$/i.test(id)) return { ok: false, error: 'Unknown invitation.' };
  const { error: ce } = await sb.rpc('practice_invite_check', { p_kind: kind, p_id: id });
  if (ce) return { ok: false, error: ce.message };
  if (!(await channelOn(null, 'email'))) return { ok: false, error: 'Email is paused by TaxStreem for now. Try again later.' };
  if (!(await secret('RESEND_API_KEY')) || !senderAddress(await secret('RESEND_FROM'))) {
    return { ok: false, reason: 'not_configured', error: 'Email is not switched on yet. TaxStreem is setting it up.' };
  }
  const { data: inv, error } = await admin.rpc('svc_practice_invite_link', { p_kind: kind, p_id: id });
  if (error || !inv) return { ok: false, error: error?.message || 'That invitation was accepted or withdrawn.' };
  const m: Msg = { id: `practice-${kind}-${id}-${Date.now()}`, channel: 'email', to_address: String(inv.to), template: 'practice', subject: String(inv.subject || ''),
    params: { ...inv, business: inv.from_name || 'Counta' }, org: { name: String(inv.from_name || 'Counta'), reply_to_email: inv.reply_to || undefined } };
  try {
    await sendEmail(m);
    return { ok: true, sent_to: inv.to };
  } catch (e) {
    return { ok: false, error: (e as Error).message };
  }
}

// ------------------------------------------------------------------ entry
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  const path = new URL(req.url).pathname;
  try {
    if (/\/whatsapp\/?$/.test(path)) return await whatsappWebhook(req);
    if (/\/openwa\/?$/.test(path)) return await openwaWebhook(req);
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
        whatsapp: ((await provider()) === 'openwa' ? Boolean(await openwaCfg())
          : Boolean((await secret('WHATSAPP_TOKEN')) && (await secret('WHATSAPP_PHONE_NUMBER_ID')))) && waOn,
        whatsapp_provider: await provider(), own_numbers: (await secret('OPENWA_BUSINESS_NUMBERS')).toLowerCase() === 'on',
        paused: { email: !emailOn, whatsapp: !waOn } });
    }
    if (body.action === 'practice_email') return json(await practiceEmail(sb, String(body.kind || ''), String(body.id || '')));
    if (['wa_link', 'wa_status', 'wa_unlink'].includes(body.action)) {
      const orgId = typeof body.org_id === 'string' && /^[0-9a-f-]{36}$/i.test(body.org_id) ? body.org_id : '';
      if (!orgId) return json({ ok: false, error: 'Choose the business.' }, 400);
      return json(await businessNumber(sb, orgId, body.action));
    }
    return json({ ok: false, error: 'Unknown action.' }, 400);
  } catch (e) {
    console.error('messaging', e);
    return json({ ok: false, error: (e as Error).message }, 500);
  }
});
