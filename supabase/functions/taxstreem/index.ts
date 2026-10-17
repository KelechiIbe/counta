// Counta ⇄ TaxStreem.
//
// Single sign-on (no Counta password needed):
//   TaxStreem sends the person to  https://<counta>/sso?token=<JWT>  (HS256, signed with TAXSTREEM_SSO_SECRET; claims in docs/taxstreem-sso.md).
//   The /sso page posts { action: 'sso', token } here. Counta checks the token, makes sure the person and the business exist,
//   and answers with a one-time token_hash the page exchanges for a session (supabase.auth.verifyOtp).
//
// Prism (TaxStreem's payables) sending a supplier bill into the books, signed with the same secret:
//   POST /taxstreem/prism/bills         body { org_id: <TaxStreem business id>, bill: {...} }
//   POST /taxstreem/prism/bill-status   body { org_id, prism_id }
//   Header: x-taxstreem-signature: t=<unix seconds>,v1=<hex HMAC-SHA256 of "<t>.<raw body>">
import { createClient } from 'npm:@supabase/supabase-js@2';
import { SsoError, verifyBody, verifySsoToken } from './sso.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const admin = createClient(SUPABASE_URL, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } });

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-taxstreem-signature',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

const cache = new Map<string, { v: string; at: number }>();
async function secret(name: string): Promise<string> {
  const env = Deno.env.get(name);
  if (env) return env.trim();
  const hit = cache.get(name);
  if (hit && Date.now() - hit.at < 60_000) return hit.v;
  const { data } = await admin.rpc('svc_secret', { p_name: name });
  const v = typeof data === 'string' ? data.trim() : '';
  cache.set(name, { v, at: Date.now() });
  return v;
}

async function sso(token: string) {
  const claims = await verifySsoToken(token, await secret('TAXSTREEM_SSO_SECRET'), { issuer: Deno.env.get('TAXSTREEM_SSO_ISSUER') || 'taxstreem' });
  // The person: created the first time (email already confirmed by TaxStreem), found every time after.
  const created = await admin.auth.admin.createUser({ email: claims.email, email_confirm: true,
    user_metadata: { name: claims.name, taxstreem_user_id: claims.sub, signed_up_with: 'taxstreem' } });
  if (created.error && !/already|exists|registered/i.test(created.error.message)) throw new Error(created.error.message);
  const link = await admin.auth.admin.generateLink({ type: 'magiclink', email: claims.email });
  if (link.error || !link.data?.user || !link.data.properties?.hashed_token) throw new Error(link.error?.message || 'Could not start the session.');
  const { data, error } = await admin.rpc('svc_sso_login', { c: claims, p_user: link.data.user.id });
  if (error) throw new SsoError(error.message);
  return { ok: true, token_hash: link.data.properties.hashed_token, type: 'magiclink', email: claims.email, org_id: data.org_id,
    new_business: data.new_business, next: claims.next || null };
}

async function prism(path: string, raw: string, sig: string | null) {
  if (!(await verifyBody(raw, sig, await secret('TAXSTREEM_SSO_SECRET')))) return json({ ok: false, error: 'Bad signature.' }, 401);
  let body: any;
  try { body = JSON.parse(raw); } catch { return json({ ok: false, error: 'Invalid JSON.' }, 400); }
  const { data: org } = await admin.from('orgs').select('id').eq('taxstreem_org_id', String(body.org_id || '')).maybeSingle();
  if (!org) return json({ ok: false, error: 'This business has not opened Counta yet.' }, 404);
  if (path.endsWith('/bills')) {
    if (!body.bill || typeof body.bill !== 'object') return json({ ok: false, error: 'bill is required.' }, 400);
    const { data, error } = await admin.rpc('svc_prism_bill', { p_org: org.id, p_bill: body.bill });
    if (error) return json({ ok: false, error: error.message }, 422);
    const b = data.bill;
    return json({ ok: true, duplicate: data.duplicate, bill: { id: b.id, number: b.number, status: b.status, total: b.total, wht_expected: b.wht_expected } });
  }
  if (path.endsWith('/bill-status')) {
    const { data: b } = await admin.from('bills').select('id, number, status, total, amount_paid, wht_withheld, due_date')
      .eq('org_id', org.id).eq('source', 'prism').eq('external_ref', String(body.prism_id || '')).maybeSingle();
    if (!b) return json({ ok: false, error: 'Bill not found.' }, 404);
    return json({ ok: true, bill: b });
  }
  return json({ ok: false, error: 'Unknown path.' }, 404);
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405);
  const path = new URL(req.url).pathname.replace(/\/$/, '');
  try {
    if (/\/prism\/(bills|bill-status)$/.test(path)) return await prism(path, await req.text(), req.headers.get('x-taxstreem-signature'));
    let body: any;
    try { body = await req.json(); } catch { return json({ ok: false, error: 'Invalid request.' }, 400); }
    if (body.action === 'sso') return json(await sso(String(body.token || '')));
    if (body.action === 'status') return json({ ok: true, sso: Boolean(await secret('TAXSTREEM_SSO_SECRET')) });
    return json({ ok: false, error: 'Unknown action.' }, 400);
  } catch (e) {
    if (e instanceof SsoError) return json({ ok: false, error: e.message }, 200);
    console.error('taxstreem', e);
    return json({ ok: false, error: 'Something went wrong signing you in. Try again from TaxStreem.' }, 500);
  }
});
