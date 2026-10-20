// Counta admin: the parts of TaxStreem's admin portal that need a server. Every call is from a signed-in TaxStreem admin
// whose session was confirmed with an authenticator code (the database checks both on every admin_* call made here with
// the person's own token).
//
//   { action: 'status' }                   -> each key: set in the portal (Vault), set as an Edge Function secret, or neither;
//                                             the webhook addresses providers must call and when each last called
//   { action: 'set_key', name, value }     -> writes a key or setting to Vault (admin_set_secret) and emails every admin
//   { action: 'clear_key', name }          -> clears it in Vault, so the Edge Function secret (if any) applies again
//   { action: 'test', group }              -> one harmless request to the provider with the key Counta will use
//
// Keys are read Vault first, then the Edge Function secret, exactly as the other functions read them; the value of a
// secret never leaves this function.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const XI = (Deno.env.get('ELEVENLABS_BASE_URL') || 'https://api.elevenlabs.io').replace(/\/$/, '');
const FLW = (Deno.env.get('FLW_BASE_URL') || 'https://api.flutterwave.com/v3').replace(/\/$/, '');
const RESEND = (Deno.env.get('RESEND_BASE_URL') || 'https://api.resend.com').replace(/\/$/, '');
const GRAPH = (Deno.env.get('WHATSAPP_GRAPH_URL') || 'https://graph.facebook.com/v21.0').replace(/\/$/, '');
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

async function call(url: string, init: RequestInit = {}) {
  try {
    const res = await fetch(url, { ...init, signal: AbortSignal.timeout(20_000) });
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
    default:
      return { ok: false, note: 'Nothing to test for this group.' };
  }
}

// ------------------------------------------------------------------ alerts
// Every admin hears about every key change, by email, when email is set up.
async function alert(actor: string, label: string, what: string) {
  const k = await key('RESEND_API_KEY'), from = senderAddress(await key('RESEND_FROM'));
  if (!k || !from) return false;
  const { data: to } = await admin.rpc('svc_admin_emails');
  const list = (Array.isArray(to) ? to : []).filter((e: unknown) => typeof e === 'string').slice(0, 20);
  if (!list.length) return false;
  const when = new Date().toLocaleString('en-GB', { timeZone: 'Africa/Lagos', dateStyle: 'medium', timeStyle: 'short' });
  const text = `${actor} ${what} in the Counta admin portal on ${when} (Lagos time).\n\n${label}\n\nIf this was not you or someone you expected, sign in to the admin portal, check Keys and services, and change the key at the provider.`;
  const r = await call(`${RESEND}/emails`, { method: 'POST', headers: { Authorization: `Bearer ${k}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from: `Counta admin <${from}>`, to: list, subject: `Counta admin: ${label.split('\n')[0]}`, text }) });
  return r.ok;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405);
  const auth = req.headers.get('Authorization') || '';
  const sb: SupabaseClient = createClient(SUPABASE_URL, ANON, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  let body: any;
  try { body = await req.json(); } catch { return json({ ok: false, error: 'Invalid request.' }, 400); }
  try {
    const { data: u } = await sb.auth.getUser();
    if (!u?.user) return json({ ok: false, error: 'Sign in first.' }, 401);
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
        } });
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
      default:
        return json({ ok: false, error: 'Unknown action.' }, 400);
    }
  } catch (e) {
    console.error('admin', e);
    return json({ ok: false, error: (e as Error).message }, 500);
  }
});
