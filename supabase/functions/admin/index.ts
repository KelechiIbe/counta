// Counta admin: the parts of TaxStreem's admin portal that need a server. Every call is from a signed-in TaxStreem admin
// whose session was confirmed with an authenticator code (the database checks both on every admin_* call made here with
// the person's own token).
//
//   { action: 'status' }                   -> each key: set in the portal (Vault), set as an Edge Function secret, or neither;
//                                             the webhook addresses providers must call and when each last called
//   { action: 'set_key', name, value }     -> writes a key or setting to Vault (admin_set_secret) and emails every admin
//   { action: 'clear_key', name }          -> clears it in Vault, so the Edge Function secret (if any) applies again
//   { action: 'test', group }              -> one harmless request to the provider with the key Counta will use (for NRS
//                                             e-invoicing and Google Cloud HSM, the einvoice function's own checks)
//   { action: 'openwa_connect' }           -> TaxStreem's WhatsApp number on OpenWA: makes (or finds) the session, gives
//                                             OpenWA a fresh webhook secret and Counta's webhook addresses, and answers the
//                                             session's state with the QR code to scan while it waits for one
//   { action: 'openwa_status' }            -> the same state, without changing anything
//   { action: 'openwa_unlink' }            -> logs the number out of WhatsApp on the server
//   { action: 'delete_business', org_id, confirm } -> deletes a business for good. The database part (admin_business_delete)
//                                             checks the typed name, that no wallet holds money and nothing is on its
//                                             way, and removes every record in one go; then this removes its files, the
//                                             logins of people in no other business, its bank feeds at Mono and any
//                                             WhatsApp number it linked on OpenWA, and emails every admin
//   { action: 'delete_business_finish', audit_id } -> tries again whatever a deletion could not finish
//   { action: 'add_staff', email, role }   -> Admin team, Add (admin_add_staff): someone with a Counta account gets the role
//                                             and the welcome email; anyone else gets an invitation email. Every other admin
//                                             is told
//   { action: 'resend_staff_invite', id }  -> the invitation again, with a fresh link (the old one stops working)
//   { action: 'resend_staff_welcome', user_id, role } -> the welcome again, for someone who has not opened the portal yet
//   { action: 'accept_staff_invite', token } -> the invitation's link, accepted by the person it was for (signed in with that
//                                             address; no authenticator code yet, since they have not set one up). Every
//                                             admin is told
//   x-counta-hook { action: 'welcome_pending' } -> the welcome, once, to people added before these emails existed who have
//                                             not opened the portal (asked for by the database once, in the hand-over)
//
// Keys are read Vault first, then the Edge Function secret, exactly as the other functions read them; the value of a
// secret never leaves this function.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { COUNTA_SESSION, ensureSession, INBOUND_EVENTS, type OpenWa, owa, owaError, RECEIPT_EVENTS, sessionState, setWebhooks } from './openwa.ts';
import { staffHtml, staffText, type StaffWords } from './mail.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const XI = (Deno.env.get('ELEVENLABS_BASE_URL') || 'https://api.elevenlabs.io').replace(/\/$/, '');
const FLW = (Deno.env.get('FLW_BASE_URL') || 'https://api.flutterwave.com/v3').replace(/\/$/, '');
const RESEND = (Deno.env.get('RESEND_BASE_URL') || 'https://api.resend.com').replace(/\/$/, '');
const GRAPH = (Deno.env.get('WHATSAPP_GRAPH_URL') || 'https://graph.facebook.com/v21.0').replace(/\/$/, '');
const MONO = (Deno.env.get('MONO_BASE_URL') || 'https://api.withmono.com').replace(/\/$/, '');
const admin = createClient(SUPABASE_URL, SERVICE, { auth: { persistSession: false } });

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

// Vault first, then the Edge Function secret. Read fresh each time, so a key just changed is the one tested.
async function key(name: string): Promise<string> {
  const { data } = await admin.rpc('svc_secret', { p_name: name });
  return (typeof data === 'string' ? data.trim() : '') || (Deno.env.get(name) || '').trim();
}

const senderAddress = (raw: string) => String(raw || '').match(/[A-Z0-9._%+-]+@[A-Z0-9-]+(?:\.[A-Z0-9-]+)*\.[A-Z]{2,}/i)?.[0]?.toLowerCase() || '';
const short = (v: unknown, n = 300) => String(v ?? '').replace(/\s+/g, ' ').trim().slice(0, n);

async function call(url: string, init: RequestInit = {}, timeoutMs = 20_000) {
  try {
    const res = await fetch(url, { ...init, signal: AbortSignal.timeout(timeoutMs) });
    const text = await res.text();
    let body: any = text;
    try { body = JSON.parse(text); } catch { /* not json */ }
    return { status: res.status, ok: res.ok, body };
  } catch (e) {
    return { status: 0, ok: false, body: { message: (e as Error).message } };
  }
}
const why = (r: { status: number; body: any }) => short(r.body?.message || r.body?.detail?.message || r.body?.detail || r.body?.error?.message
  || r.body?.error_description || r.body?.error || (typeof r.body === 'string' ? r.body : '') || `HTTP ${r.status}`);

// ------------------------------------------------------------------ tests, one per service
async function test(group: string, auth: string) {
  switch (group) {
    case 'gemini': {
      // The ai function's own check, so the answer reflects exactly how Counta reaches Gemini.
      const r = await call(`${SUPABASE_URL}/functions/v1/ai`, { method: 'POST', headers: { Authorization: auth, apikey: ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'check' }) });
      if (r.body?.ok) return { ok: true, note: `Gemini ${r.body.model} answered ${r.body.auth === 'vertex' ? `on Vertex AI in ${r.body.location || 'us-central1'}` : 'through the Gemini API key'} in ${((r.body.ms || 0) / 1000).toFixed(1)}s.` };
      return { ok: false, note: short(r.body?.error || why(r)) };
    }
    case 'elevenlabs': {
      const k = await key('ELEVENLABS_API_KEY');
      if (!k) return { ok: false, note: 'No API key yet.' };
      const r = await call(`${XI}/v1/convai/phone-numbers`, { headers: { 'xi-api-key': k } });
      if (!r.ok) return { ok: false, note: `ElevenLabs refused the key (${r.status}): ${why(r)}` };
      const nums: any[] = Array.isArray(r.body) ? r.body : r.body?.phone_numbers || [];
      const wanted = await key('ELEVENLABS_PHONE_NUMBER_ID');
      const used = (wanted && nums.find((n) => n.phone_number_id === wanted)) || nums.find((n) => n.provider === 'twilio' || n.provider === 'sip_trunk') || nums[0];
      return { ok: true, note: nums.length ? `The key works. Calls go out from ${used?.label ? `${used.label}, ` : ''}${used?.phone_number || 'the connected number'}.`
        : 'The key works, but no phone number is connected yet. Voices and Martina work; phone calls need a number.' };
    }
    case 'flutterwave': {
      const k = await key('FLW_SECRET_KEY');
      if (!k) return { ok: false, note: 'No secret key yet.' };
      const r = await call(`${FLW}/balances/NGN`, { headers: { Authorization: `Bearer ${k}` } });
      if (!r.ok) return { ok: false, note: `Flutterwave refused the key (${r.status}): ${why(r)}` };
      const bal = Number(r.body?.data?.available_balance);
      // Transfers (payouts, sweeps, the tax wallet) go through the relay with the fixed IP address: the payments function's own check.
      const rc = await call(`${SUPABASE_URL}/functions/v1/payments`, { method: 'POST', headers: { Authorization: auth, apikey: ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'relay_check' }) });
      const relay = rc.body?.relay;
      const transfers = relay?.ok ? ` Transfers go through the relay (version ${relay.version}) to ${relay.upstream}.`
        : rc.body?.transfers_ready ? ' Transfers go straight to Flutterwave (FLW_DIRECT_TRANSFERS is on).'
        : ` Transfers are off: ${short(relay?.error || rc.body?.error || 'the relay did not answer')} Payouts, sweeps and tax wallet moves wait until it works.`;
      return { ok: true, note: `The key works${Number.isFinite(bal) ? `. Available naira balance: ₦${bal.toLocaleString('en-NG', { minimumFractionDigits: 2 })}` : ''}.${/TEST/i.test(k) ? ' This is a test key.' : ''}${transfers}`,
        relay_ok: Boolean(relay?.ok) };
    }
    case 'email': {
      const k = await key('RESEND_API_KEY'), from = await key('RESEND_FROM');
      if (!k) return { ok: false, note: 'No Resend API key yet.' };
      const r = await call(`${RESEND}/domains`, { headers: { Authorization: `Bearer ${k}` } });
      if (!r.ok) return { ok: false, note: `Resend refused the key (${r.status}): ${why(r)}` };
      const domains: any[] = Array.isArray(r.body?.data) ? r.body.data : [];
      const addr = senderAddress(from);
      if (!addr) return { ok: false, note: 'The key works, but the sending address is missing or has no email address in it.' };
      const d = domains.find((x) => addr.endsWith('@' + String(x.name).toLowerCase()));
      if (!d) return { ok: false, note: `The key works, but ${addr.split('@')[1]} is not a domain in this Resend account.` };
      return { ok: d.status === 'verified', note: d.status === 'verified' ? `The key works and ${d.name} is verified. Emails go out from ${addr}.`
        : `The key works, but ${d.name} is ${d.status} in Resend. Finish verifying it there.` };
    }
    case 'whatsapp': {
      const t = await key('WHATSAPP_TOKEN'), id = await key('WHATSAPP_PHONE_NUMBER_ID');
      if (!t || !id) return { ok: false, note: 'Add the access token and the phone number id.' };
      const r = await call(`${GRAPH}/${encodeURIComponent(id)}?fields=display_phone_number,verified_name,quality_rating`, { headers: { Authorization: `Bearer ${t}` } });
      if (!r.ok) return { ok: false, note: `Meta refused (${r.status}): ${why(r)}` };
      return { ok: true, note: `Connected to ${r.body?.verified_name || 'the business'} on ${r.body?.display_phone_number || 'its number'}${r.body?.quality_rating ? `, quality ${String(r.body.quality_rating).toLowerCase()}` : ''}.` };
    }
    case 'openwa': {
      const cfg = await openwaCfg();
      if (!cfg) return { ok: false, note: 'Add the server address and the API key.' };
      const h = await owa(cfg, '/health');
      if (!h.ok) return { ok: false, note: `The OpenWA server did not answer at ${cfg.url} (${owaError(h)}).` };
      const k = await owa(cfg, '/sessions');
      if (!k.ok) return { ok: false, note: `The server answered, but refused the API key (${owaError(k)}). Use an Operator key from the OpenWA dashboard.` };
      const { data: row } = await admin.from('whatsapp_sessions').select('id').eq('kind', 'counta').maybeSingle();
      if (!row) return { ok: true, note: 'The server and the key work. Press Connect to link TaxStreem\'s number.' };
      const st = await sessionState(cfg, row.id);
      return { ok: st.status === 'ready', note: st.status === 'ready' ? `The server and the key work, and WhatsApp is connected on +${st.phone || 'the number'}.`
        : `The server and the key work, but WhatsApp is ${st.status.replace(/_/g, ' ')}. Press Connect to see what it needs.` };
    }
    case 'numens': {
      const url = await key('NUMENS_API_URL'), k = await key('NUMENS_API_KEY');
      if (!url || !k) return { ok: false, note: 'Add the address and the key.' };
      const r = await call(`${url.replace(/\/$/, '')}/vat/classify`, { method: 'POST', headers: { Authorization: `Bearer ${k}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ country: 'NG', law: 'NTA2025', items: [{ id: 'check', name: 'White bread 500g', kind: 'merchandise' }] }) });
      return r.ok ? { ok: true, note: `Numens answered${r.body?.results?.[0]?.treatment ? `: white bread is ${r.body.results[0].treatment}` : ''}.` }
        : { ok: false, note: `Numens refused (${r.status}): ${why(r)}` };
    }
    case 'mono': {
      const s = await key('MONO_SECRET_KEY'), p = await key('MONO_PUBLIC_KEY'), w = await key('MONO_WEBHOOK_SECRET');
      return { ok: Boolean(s && p), note: s && p ? `Keys are in place${w ? ' with the webhook secret' : ', but the webhook secret is missing, so new transactions arrive only on the four-hourly sync'}. Mono is checked when a business links a bank.`
        : 'Add the secret and public keys.' };
    }
    case 'taxstreem': {
      const s = await key('TAXSTREEM_SSO_SECRET'), f = await key('FLUX_URL'), fs = await key('FLUX_SECRET');
      return { ok: Boolean(s), note: [s ? 'Single sign-on is set.' : 'Single sign-on has no secret yet.',
        f && fs ? 'Flux is connected.' : 'Flux is not connected: returns are downloaded and filed by hand.'].join(' ') };
    }
    case 'nrs': case 'kms': {
      // The einvoice function's own checks: the NRS sandbox (code lists, TaxStreem's entity record, the QR keys) or the
      // Google Cloud HSM key ring. The NRS check makes about a dozen calls with a pause between them.
      const r = await call(`${SUPABASE_URL}/functions/v1/einvoice`, { method: 'POST', headers: { Authorization: auth, apikey: ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'platform_check', what: group }) }, 120_000);
      if (r.status === 0) return { ok: false, note: `The einvoice function did not answer: ${why(r)}` };
      return { ok: Boolean(r.body?.ok), note: short(r.body?.note || r.body?.error || why(r), 1500) };
    }
    default:
      return { ok: false, note: 'Nothing to test for this group.' };
  }
}

// ------------------------------------------------------------------ OpenWA: TaxStreem's WhatsApp number
async function openwaCfg(): Promise<OpenWa | null> {
  const url = await key('OPENWA_URL'), k = await key('OPENWA_API_KEY');
  return url && k ? { url, key: k } : null;
}
const hex = (n: number) => Array.from(crypto.getRandomValues(new Uint8Array(n))).map((x) => x.toString(16).padStart(2, '0')).join('');

async function openwa(sb: SupabaseClient, action: string, userId: string) {
  const cfg = await openwaCfg();
  if (!cfg) return { ok: false, error: 'Add the OpenWA server address and API key first.' };
  const base = `${SUPABASE_URL}/functions/v1/`;
  if (action === 'openwa_connect') {
    const h = await owa(cfg, '/health');
    if (!h.ok) return { ok: false, error: `The OpenWA server did not answer at ${cfg.url} (${owaError(h)}).` };
    let s: any;
    try { s = await ensureSession(cfg, COUNTA_SESSION); } catch (e) { return { ok: false, error: `OpenWA would not start the session: ${(e as Error).message}` }; }
    // A fresh secret each time Connect is pressed: OpenWA signs every delivery with it, and Counta checks it.
    const secret = hex(32);
    const { error } = await sb.rpc('admin_set_secret', { p_name: 'OPENWA_WEBHOOK_SECRET', p_value: secret });
    if (error) return { ok: false, error: error.message };
    try {
      await setWebhooks(cfg, String(s.id), base, secret, [
        { url: `${base}messaging/openwa`, events: RECEIPT_EVENTS }, { url: `${base}chat/openwa`, events: INBOUND_EVENTS }]);
    } catch (e) { return { ok: false, error: (e as Error).message }; }
    await admin.rpc('svc_wa_session_save', { p: { id: String(s.id), kind: 'counta', name: String(s.name || COUNTA_SESSION), status: String(s.status || 'created'), created_by: userId } });
  }
  const { data: row } = await admin.from('whatsapp_sessions').select('id').eq('kind', 'counta').maybeSingle();
  if (!row) return { ok: true, status: 'none' };
  if (action === 'openwa_unlink') {
    const r = await owa(cfg, `/sessions/${encodeURIComponent(row.id)}/logout`, { method: 'POST', body: {} });
    if (!r.ok && r.status !== 404) return { ok: false, error: `OpenWA did not log out: ${owaError(r)}` };
  }
  const st = await sessionState(cfg, row.id);
  if (!['unreachable'].includes(st.status)) {
    await admin.rpc('svc_wa_session_save', { p: { id: row.id, status: st.status === 'missing' ? 'missing' : st.status, phone: st.phone, push_name: st.push_name,
      last_error: st.error || null } });
  }
  return { ok: true, status: st.status, phone: st.phone, push_name: st.push_name, qr: st.qr || null, error: st.error };
}

// ------------------------------------------------------------------ alerts
// Every admin hears about every key change, by email, when email is set up. skip: addresses the alert is about, who get
// their own email instead.
async function alert(actor: string, label: string, what: string, tail = 'If this was not you or someone you expected, sign in to the admin portal, check Keys and services, and change the key at the provider.', skip: string[] = []) {
  const k = await key('RESEND_API_KEY'), from = senderAddress(await key('RESEND_FROM'));
  if (!k || !from) return false;
  const { data: to } = await admin.rpc('svc_admin_emails');
  const left = new Set(skip.map((e) => String(e || '').toLowerCase()));
  const list = (Array.isArray(to) ? to : []).filter((e: unknown) => typeof e === 'string' && !left.has(e.toLowerCase())).slice(0, 20);
  if (!list.length) return false;
  const when = new Date().toLocaleString('en-GB', { timeZone: 'Africa/Lagos', dateStyle: 'medium', timeStyle: 'short' });
  const text = `${actor} ${what} in the Counta admin portal on ${when} (Lagos time).\n\n${label}\n\n${tail}`;
  const r = await call(`${RESEND}/emails`, { method: 'POST', headers: { Authorization: `Bearer ${k}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from: `Counta admin <${from}>`, to: list, subject: `Counta admin: ${label.split('\n')[0]}`, text }) });
  return r.ok;
}

// ------------------------------------------------------------------ the admin team's emails
const STAFF_TAIL = 'If this was not you or someone you expected, sign in to the admin portal and remove them, or withdraw the invitation, on the Admin team page.';
const roleWords = (role: string) => (role === 'admin' ? 'an admin' : 'a reviewer');
// The database's hook secret, read the way the other functions read it: the Edge Function secret when one is set, else
// the copy in Vault (svc_secret answers only for the keys the portal manages; app_secret also answers for this one).
async function hookSecret(): Promise<string> {
  const env = (Deno.env.get('PUSH_HOOK_SECRET') || '').trim();
  if (env) return env;
  const { data } = await admin.rpc('app_secret', { p_name: 'PUSH_HOOK_SECRET' });
  return typeof data === 'string' ? data.trim() : '';
}
const same = (a: string, b: string) => {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  if (!x.length || x.length !== y.length) return false;
  let d = 0;
  for (let i = 0; i < x.length; i++) d |= x[i] ^ y[i];
  return d === 0;
};

// An invitation (a fresh one-time link each time) or the welcome, written by the database and sent through Resend. What
// became of it is written back: the welcome noted when it went, an invitation's error shown on the Admin team page.
async function staffMail(kind: 'invite' | 'welcome', id: string, role?: string): Promise<{ ok: boolean; error?: string }> {
  const k = await key('RESEND_API_KEY'), from = senderAddress(await key('RESEND_FROM'));
  if (!k || !from) {
    const error = 'Email is not set up yet: add the Resend API key and the sending address under Keys and services, then send it again.';
    await admin.rpc('svc_staff_mail_sent', { p_kind: kind, p_id: id, p_role: role || null, p_error: error });
    return { ok: false, error };
  }
  const { data, error } = await admin.rpc('svc_staff_mail', { p_kind: kind, p_id: id, p_role: role || null });
  if (error) return { ok: false, error: error.message };
  const w = data as StaffWords | null;
  if (!w?.to) return { ok: false, error: kind === 'invite' ? 'That invitation was already accepted or withdrawn.' : 'They are no longer on the admin team.' };
  const r = await call(`${RESEND}/emails`, { method: 'POST',
    headers: { Authorization: `Bearer ${k}`, 'Content-Type': 'application/json', 'Idempotency-Key': `counta-staff-${kind}-${id}-${hex(6)}` },
    body: JSON.stringify({ from: `Counta <${from}>`, to: [w.to], ...(senderAddress(w.reply_to || '') ? { reply_to: senderAddress(w.reply_to || '') } : {}),
      subject: w.subject, html: staffHtml(w), text: staffText(w), tags: [{ name: 'template', value: `staff_${kind}` }] }) });
  const err = r.ok ? null : `Resend: ${why(r)}`;
  await admin.rpc('svc_staff_mail_sent', { p_kind: kind, p_id: id, p_role: role || null, p_error: err });
  return err ? { ok: false, error: err } : { ok: true };
}

// ------------------------------------------------------------------ deleting a business
// What the database could not do itself: the files (Storage), the logins (Auth), the bank feeds at Mono and the WhatsApp
// numbers on OpenWA. Each part is safe to run again; what is still left keeps the deletion open for Try again.
async function finishDeletion(auditId: number) {
  const done = { logins: 0, files: 0, mono: 0, whatsapp: 0 };
  const errors: string[] = [];
  const pending = async () => (await admin.rpc('svc_business_delete_pending', { p_audit: auditId })).data as
    { users: string[]; files: { bucket: string; name: string }[]; mono: string[]; whatsapp: string[] } | null;
  // Files, a thousand at a time, until none are left or a round removes nothing.
  for (let round = 0; round < 50; round++) {
    const files = (await pending())?.files || [];
    if (!files.length) break;
    let removed = 0;
    for (const bucket of [...new Set(files.map((f) => f.bucket))]) {
      const names = files.filter((f) => f.bucket === bucket).map((f) => f.name);
      for (let i = 0; i < names.length; i += 100) {
        const { data, error } = await admin.storage.from(bucket).remove(names.slice(i, i + 100));
        if (error) { errors.push(`Files: ${short(error.message, 160)}`); break; }
        removed += (data || []).length;
      }
    }
    done.files += removed;
    if (!removed) break;
  }
  const p = await pending();
  // Logins of people who are still in no business, not accountants and not TaxStreem staff (the database checks again).
  for (const id of p?.users || []) {
    const { error } = await admin.auth.admin.deleteUser(String(id));
    if (error && !/not.?found/i.test(error.message)) errors.push(`A login: ${short(error.message, 160)}`);
    else done.logins++;
  }
  // Bank feeds at Mono: Mono stops reading the bank (and billing for it). Without Mono keys there is no feed to stop.
  const monoKey = await key('MONO_SECRET_KEY');
  let monoLeft = false;
  for (const id of monoKey ? p?.mono || [] : []) {
    const r = await call(`${MONO}/v2/accounts/${encodeURIComponent(id)}/unlink`, { method: 'POST', headers: { 'mono-sec-key': monoKey, accept: 'application/json' } });
    if (r.ok || r.status === 404 || /already|not found|unlinked/i.test(why(r))) done.mono++;
    else { monoLeft = true; errors.push(`A bank feed at Mono: ${why(r)}`); }
  }
  // WhatsApp numbers the business linked on TaxStreem's OpenWA server: logged out, and the session removed.
  const cfg = await openwaCfg();
  let waLeft = false;
  for (const id of cfg ? p?.whatsapp || [] : []) {
    await owa(cfg!, `/sessions/${encodeURIComponent(id)}/logout`, { method: 'POST', body: {} });
    const r = await owa(cfg!, `/sessions/${encodeURIComponent(id)}`, { method: 'DELETE' });
    if (r.ok || r.status === 404) done.whatsapp++;
    else { waLeft = true; errors.push(`A WhatsApp number on OpenWA: ${owaError(r)}`); }
  }
  const after = await pending();
  const left = Boolean((after?.users || []).length || (after?.files || []).length || monoLeft || waLeft);
  await admin.rpc('svc_business_delete_done', { p_audit: auditId, p: { ...done, errors, pending: left } });
  return { finished: !left, ...done, errors };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405);
  const auth = req.headers.get('Authorization') || '';
  const sb: SupabaseClient = createClient(SUPABASE_URL, ANON, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  let body: any;
  try { body = await req.json(); } catch { return json({ ok: false, error: 'Invalid request.' }, 400); }
  try {
    // The database's own call: the welcome for people added before these emails existed, sent once.
    const hook = req.headers.get('x-counta-hook') || '';
    if (hook) {
      if (!same(hook, await hookSecret())) return json({ ok: false, error: 'Not allowed.' }, 401);
      if (body.action !== 'welcome_pending') return json({ ok: false, error: 'Unknown action.' }, 400);
      const { data: list, error } = await admin.rpc('svc_staff_welcome_pending');
      if (error) return json({ ok: false, error: error.message });
      const results = [];
      for (const x of ((list as { user_id: string; role: string }[]) || []).slice(0, 20)) {
        results.push({ user_id: x.user_id, role: x.role, ...(await staffMail('welcome', x.user_id, x.role)) });
      }
      return json({ ok: true, results });
    }
    const { data: u } = await sb.auth.getUser();
    if (!u?.user) return json({ ok: false, error: 'Sign in first.' }, 401);
    // The person an invitation was for: not an admin until the database accepts it, and without an authenticator yet.
    if (body.action === 'accept_staff_invite') {
      const { data, error } = await sb.rpc('admin_accept_staff_invite', { p_token: String(body.token || '') });
      if (error) return json({ ok: false, error: error.message });
      const alerted = await alert(u.user.email || data.email, `${data.email} accepted the invitation and is now ${roleWords(data.role)}`, 'joined the admin team',
        STAFF_TAIL, [data.email]);
      return json({ ok: true, role: data.role, email: data.email, alerted });
    }
    const { data: me } = await sb.rpc('admin_me');
    if (!me?.admin) return json({ ok: false, error: 'This is only for TaxStreem\'s admins.' }, 403);
    if (!me?.aal2) return json({ ok: false, reason: 'aal2', error: 'Enter the code from your authenticator app to open the admin portal.' }, 403);
    const actor = u.user.email || 'An admin';

    switch (body.action) {
      case 'status': {
        const { data: keys, error } = await sb.rpc('admin_integrations');
        if (error) return json({ ok: false, error: error.message });
        const out = (keys as any[] || []).map((k) => ({ ...k, env: Boolean((Deno.env.get(k.name) || '').trim()) }));
        const { data: events } = await admin.from('payment_events').select('rail, event, received_at, outcome, error').order('received_at', { ascending: false }).limit(1);
        const { data: wa } = await admin.from('messages').select('updated_at').eq('channel', 'whatsapp').in('status', ['delivered', 'read']).order('updated_at', { ascending: false }).limit(1);
        return json({ ok: true, keys: out, webhooks: {
          flutterwave: { url: `${SUPABASE_URL}/functions/v1/payments/webhook/flutterwave`, last: events?.[0] || null },
          mono: { url: `${SUPABASE_URL}/functions/v1/mono/webhook` },
          whatsapp: { url: `${SUPABASE_URL}/functions/v1/messaging/whatsapp`, last: wa?.[0]?.updated_at || null },
          flux: { url: `${SUPABASE_URL}/functions/v1/taxstreem/flux/cit-status` },
          openwa: { messaging: `${SUPABASE_URL}/functions/v1/messaging/openwa`, chat: `${SUPABASE_URL}/functions/v1/chat/openwa` },
        }, whatsapp: (await sb.rpc('admin_whatsapp')).data || null });
      }
      case 'set_key': {
        const name = String(body.name || '');
        const { data, error } = await sb.rpc('admin_set_secret', { p_name: name, p_value: String(body.value ?? '') });
        if (error) return json({ ok: false, error: error.message });
        const sent = await alert(actor, `${name} was changed${data?.secret ? ` (now ending ${String(data.shown || '').replace(/^•+\s*/, '')})` : ` to ${data?.shown}`}`, 'changed a key');
        return json({ ok: true, ...data, alerted: sent });
      }
      case 'clear_key': {
        const name = String(body.name || '');
        const { data, error } = await sb.rpc('admin_clear_secret', { p_name: name });
        if (error) return json({ ok: false, error: error.message });
        const sent = await alert(actor, `${name} was removed from the admin portal`, 'removed a key');
        return json({ ok: true, ...data, alerted: sent });
      }
      case 'test':
        return json({ group: String(body.group || ''), ...(await test(String(body.group || ''), auth)) });
      case 'openwa_connect': case 'openwa_status': case 'openwa_unlink': {
        const r = await openwa(sb, body.action, u.user.id);
        if (body.action !== 'openwa_status' && r.ok) await alert(actor, body.action === 'openwa_connect' ? 'WhatsApp on OpenWA was connected (a new webhook secret was made)' : 'TaxStreem\'s WhatsApp number was logged out of OpenWA', body.action === 'openwa_connect' ? 'connected WhatsApp' : 'logged out WhatsApp');
        return json(r);
      }
      case 'delete_business': {
        const { data, error } = await sb.rpc('admin_business_delete', { p_org: String(body.org_id || ''), p_confirm: String(body.confirm ?? '') });
        if (error) return json({ ok: false, error: error.message });
        const r = await finishDeletion(Number(data.audit_id));
        await alert(actor, `${data.name} was deleted from Counta, with ${data.logins} login${data.logins === 1 ? '' : 's'} of people in no other business.`,
          'deleted a business', 'If this was not you or someone you expected, sign in to the admin portal and check the record of changes on the Admin team page.');
        return json({ ok: true, name: data.name, audit_id: data.audit_id, ...r });
      }
      case 'delete_business_finish': {
        const { data: open, error } = await sb.rpc('admin_business_deletions');
        if (error) return json({ ok: false, error: error.message });
        const row = ((open as any[]) || []).find((d) => Number(d.id) === Number(body.audit_id));
        if (!row) return json({ ok: false, error: 'That deletion is already finished.' });
        return json({ ok: true, name: row.name, audit_id: row.id, ...(await finishDeletion(Number(row.id))) });
      }
      case 'add_staff': {
        const { data, error } = await sb.rpc('admin_add_staff', { p_email: String(body.email ?? ''), p_role: String(body.role ?? '') });
        if (error) return json({ ok: false, error: error.message });
        if (data.status === 'already') return json({ ok: true, ...data, sent: false });
        const added = data.status === 'added';
        const mail = added ? await staffMail('welcome', data.user_id, data.role) : await staffMail('invite', data.invite_id);
        const alerted = await alert(actor, added ? `${data.email} was made ${roleWords(data.role)}` : `${data.email} was invited to be ${roleWords(data.role)}`,
          added ? 'added someone to the admin team' : 'invited someone to the admin team', STAFF_TAIL, [data.email]);
        return json({ ok: true, ...data, sent: mail.ok, mail_error: mail.error, alerted });
      }
      case 'resend_staff_invite': {
        const { data, error } = await sb.rpc('admin_resend_staff_invite', { p_id: String(body.id || '') });
        if (error) return json({ ok: false, error: error.message });
        const mail = await staffMail('invite', data.invite_id);
        return json({ ok: mail.ok, sent: mail.ok, email: data.email, error: mail.error });
      }
      case 'resend_staff_welcome': {
        const { data, error } = await sb.rpc('admin_staff_resend_welcome', { p_user: String(body.user_id || ''), p_role: String(body.role || '') });
        if (error) return json({ ok: false, error: error.message });
        const mail = await staffMail('welcome', data.user_id, data.role);
        return json({ ok: mail.ok, sent: mail.ok, email: data.email, error: mail.error });
      }
      default:
        return json({ ok: false, error: 'Unknown action.' }, 400);
    }
  } catch (e) {
    console.error('admin', e);
    return json({ ok: false, error: (e as Error).message }, 500);
  }
});
