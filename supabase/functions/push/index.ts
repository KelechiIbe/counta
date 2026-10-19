// Counta push: delivers rows from public.notifications to the devices people registered.
//
// POST { action: 'config' }          -> { publicKey }  (VAPID public key; generated on first use)
// POST { notification_id } + header  -> sends one notification to every active device of its user
//   x-counta-hook: <PUSH_HOOK_SECRET>    (set by the database trigger through pg_net)
//
// Keys live in Supabase Vault and are read through public.app_secret with the service role.
import { createClient } from 'npm:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const admin = createClient(SUPABASE_URL, SERVICE, { auth: { persistSession: false } });

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-counta-hook',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

// Keys set in the admin portal (Supabase Vault) come first; the Edge Function secrets are the fallback.
async function secret(name: string): Promise<string> {
  // The database's hook secret keeps its old order: the Edge Function secret first.
  if (name === 'PUSH_HOOK_SECRET' && Deno.env.get(name)) return Deno.env.get(name)!.trim();
  const { data } = await admin.rpc('app_secret', { p_name: name });
  return (typeof data === 'string' ? data.trim() : '') || (Deno.env.get(name) || '').trim();
}

// The VAPID pair is generated here the first time and kept in Vault as one JSON value, so two
// instances racing on first use still end up with a matching public and private key.
let vapid: { publicKey: string; privateKey: string; subject: string } | null = null;
async function getVapid() {
  if (vapid) return vapid;
  const subject = (await secret('VAPID_SUBJECT')) || 'https://counta-taxstreem.netlify.app';
  let stored = await secret('VAPID_PRIVATE_KEY');
  if (!stored) {
    const k = webpush.generateVAPIDKeys();
    await admin.rpc('app_secret_init', { p_name: 'VAPID_PRIVATE_KEY', p_value: JSON.stringify(k) });
    await admin.rpc('app_secret_init', { p_name: 'VAPID_PUBLIC_KEY', p_value: k.publicKey });
    stored = await secret('VAPID_PRIVATE_KEY');
  }
  const k = JSON.parse(stored);
  vapid = { publicKey: k.publicKey, privateKey: k.privateKey, subject };
  return vapid;
}

type Sub = { id: string; endpoint: string; p256dh: string; auth: string; failures: number };

async function sendOne(sub: Sub, payload: string, v: NonNullable<typeof vapid>): Promise<'ok' | 'gone' | 'error'> {
  const det = webpush.generateRequestDetails(
    { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } }, payload,
    { TTL: 24 * 3600, urgency: 'high', vapidDetails: { subject: v.subject, publicKey: v.publicKey, privateKey: v.privateKey } });
  const headers = new Headers();
  for (const [k, val] of Object.entries(det.headers)) if (k.toLowerCase() !== 'content-length') headers.set(k, String(val));
  const res = await fetch(det.endpoint, { method: 'POST', headers, body: new Uint8Array(det.body as Uint8Array) });
  await res.body?.cancel();
  if (res.status >= 200 && res.status < 300) return 'ok';
  if (res.status === 404 || res.status === 410) return 'gone';
  console.log('push failed', res.status, sub.endpoint.slice(0, 60));
  return 'error';
}

async function deliver(id: string) {
  const { data: n } = await admin.from('notifications').select('*').eq('id', id).maybeSingle();
  if (!n) return { ok: false, error: 'not found' };
  if (n.pushed_at) return { ok: true, skipped: 'already pushed' };
  const { data: subs } = await admin.from('push_subscriptions').select('id, endpoint, p256dh, auth, failures').eq('user_id', n.user_id).eq('active', true);
  const v = await getVapid();
  const payload = JSON.stringify({ id: n.id, title: n.title, body: n.body, url: n.url, tag: n.tag || n.kind, kind: n.kind });
  let sent = 0;
  for (const s of (subs || []) as Sub[]) {
    let r: 'ok' | 'gone' | 'error' = 'error';
    try { r = await sendOne(s, payload, v); } catch (e) { console.log('push error', (e as Error).message); }
    if (r === 'ok') { sent++; await admin.from('push_subscriptions').update({ last_ok_at: new Date().toISOString(), failures: 0 }).eq('id', s.id); }
    else if (r === 'gone') await admin.from('push_subscriptions').update({ active: false }).eq('id', s.id);
    else await admin.from('push_subscriptions').update({ failures: s.failures + 1, active: s.failures + 1 < 5 }).eq('id', s.id);
  }
  const total = subs?.length || 0;
  await admin.from('notifications').update({ pushed_at: new Date().toISOString(), push_result: total ? `sent to ${sent} of ${total} devices` : 'no devices' }).eq('id', n.id);
  return { ok: true, sent, devices: total };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405);
  let body: any;
  try { body = await req.json(); } catch { return json({ ok: false, error: 'Invalid request.' }, 400); }
  try {
    if (body.action === 'config') return json({ ok: true, publicKey: (await getVapid()).publicKey });
    const hook = req.headers.get('x-counta-hook') || '';
    if (!hook || hook !== (await secret('PUSH_HOOK_SECRET'))) return json({ ok: false, error: 'Not allowed.' }, 401);
    if (body.notification_id) return json(await deliver(String(body.notification_id)));
    return json({ ok: false, error: 'Unknown action.' }, 400);
  } catch (e) {
    return json({ ok: false, error: (e as Error).message }, 500);
  }
});
