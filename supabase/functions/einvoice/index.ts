// Counta e-invoicing: TaxStreem as System Integrator and Access Point Provider on the NRS Merchant Buyer Solution (MBS).
// See docs/e-invoicing.md.
//
// TaxStreem's admins, signed in with the authenticator code (Authorization: Bearer <user JWT>), POST { action, ... }:
//   platform_check { what: 'nrs' }  -> asks the NRS sandbox (or production) what its answers look like: the health check,
//                                      every code list (copied into nrs_codes), TaxStreem's own entity record with the
//                                      dashboard's key, and whether crypto_keys.txt can make a QR code. What it found goes
//                                      to einvoice_checks, with numbers cut to their last four and no key or secret.
//   platform_check { what: 'kms' }  -> checks the Google Cloud HSM key ring: both keys exist with protection level HSM,
//                                      a value encrypts and decrypts, and a signature from invoice-signing verifies with
//                                      its public key.
// The admin portal's Test buttons for NRS e-invoicing and Google Cloud HSM call these.
//
// Keys are read from Supabase Vault (set in the admin portal) first, then from the Edge Function secrets. NRS_BASE_URL is
// the address on the NRS dashboard; KMS_BASE_URL is for tests.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { publicEncrypt, constants } from 'node:crypto';
import { Buffer } from 'node:buffer';
import { CredentialError, geminiConfig, type GeminiConfig } from './google.ts';
import * as K from './kms.ts';
import { codeRow, firstList, MAYBE_LISTS, nrsBase, nrsCall, nrsWhy, readCryptoKeys, RESOURCE_LISTS, shape, type NrsAnswer } from './nrs.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const admin = createClient(SUPABASE_URL, SERVICE, { auth: { persistSession: false } });
// A pause between NRS calls, so a test never looks like a flood. Tests set it to 0.
const GAP_MS = Number(Deno.env.get('NRS_GAP_MS') ?? 400);

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const secs = (ms: number) => `${(ms / 1000).toFixed(1)}s`;
const plural = (n: number, w: string) => `${n.toLocaleString('en-NG')} ${w}${n === 1 ? '' : 's'}`;

// Vault first, then the Edge Function secret. Read fresh each time, so a key just changed is the one tested.
async function secret(name: string): Promise<string> {
  const { data } = await admin.rpc('svc_secret', { p_name: name });
  return (typeof data === 'string' ? data.trim() : '') || (Deno.env.get(name) || '').trim();
}

async function saveCheck(kind: 'nrs' | 'kms', userId: string, ok: boolean, note: string, results: Record<string, unknown>) {
  const { error } = await admin.rpc('svc_einvoice_check_save', { p: { kind, by_user: userId, ok, note, results } });
  if (error) console.error('einvoice: could not save the check', error.message);
}

const LIST_WORDS: Record<string, (n: number) => string> = {
  'countries': (n) => plural(n, 'country').replace(/countrys$/, 'countries'), 'currencies': (n) => plural(n, 'currency').replace(/currencys$/, 'currencies'),
  'tax-categories': (n) => plural(n, 'tax category').replace(/categorys$/, 'categories'), 'payment-means': (n) => `${n.toLocaleString('en-NG')} payment means`,
  'invoice-types': (n) => plural(n, 'invoice type'), 'services-codes': (n) => plural(n, 'service code'), 'vat-exemptions': (n) => plural(n, 'VAT exemption'),
  'hs-codes': (n) => plural(n, 'HS code'), 'states': (n) => plural(n, 'state'), 'lgas': (n) => plural(n, 'LGA'),
};
const answer = (r: NrsAnswer) => ({ status: r.status, ms: r.ms, body: shape(r.body) });

// ------------------------------------------------------------------ the NRS sandbox
async function nrsCheck(userId: string) {
  const base = nrsBase(await secret('NRS_BASE_URL'));
  if (!base) return { ok: false, note: 'Add the NRS e-invoicing address first.' };
  let host = '';
  try { host = new URL(base).host; } catch { return { ok: false, note: 'The NRS e-invoicing address is not a web address.' }; }
  const key = await secret('NRS_API_KEY'), sec = await secret('NRS_API_SECRET');
  const biz = await secret('NRS_BUSINESS_ID'), svc = (await secret('NRS_SERVICE_ID')).toUpperCase();
  const appKey = await secret('NRS_APP_API_KEY'), appSec = await secret('NRS_APP_API_SECRET');
  const cryptoRaw = await secret('NRS_CRYPTO_KEYS');
  const results: Record<string, any> = { host, at: new Date().toISOString(), lists: {} };
  const said: string[] = [];
  let ok = true;

  const health = await nrsCall({ base }, '/api', { auth: false });
  results.health = answer(health);
  if (health.status === 0) {
    const note = `NRS did not answer at ${host} (${nrsWhy(health)}).`;
    await saveCheck('nrs', userId, false, note, results);
    return { ok: false, note };
  }
  said.push(`NRS answered at ${host} in ${secs(health.ms)}${health.ok ? '' : ` (the health check said ${health.status})`}.`);

  // The code lists: no keys needed. Each is copied into nrs_codes; an empty or failed one leaves the copy as it was.
  const copied: string[] = [], failed: string[] = [];
  for (const name of [...RESOURCE_LISTS, ...MAYBE_LISTS]) {
    if (GAP_MS) await sleep(GAP_MS);
    let r = await nrsCall({ base }, `/api/v1/invoice/resources/${name}`, { auth: false, timeoutMs: 30_000 });
    // The documentation says the code lists need no keys; if this NRS environment wants them anyway, ask again with them.
    let withKey = false;
    if ((r.status === 401 || r.status === 403) && key && sec) {
      if (GAP_MS) await sleep(GAP_MS);
      r = await nrsCall({ base, key, secret: sec }, `/api/v1/invoice/resources/${name}`, { timeoutMs: 30_000 });
      withKey = true;
    }
    const list = r.ok ? firstList(r.body) : null;
    const rows = (list || []).map(codeRow).filter((x): x is NonNullable<ReturnType<typeof codeRow>> => !!x);
    const entry: Record<string, unknown> = { status: r.status, ms: r.ms, with_key: withKey || undefined, count: list ? list.length : null, coded: rows.length,
      sample: shape((list || []).slice(0, 3)), around: list ? undefined : shape(r.body) };
    if (rows.length) {
      const { data, error } = await admin.rpc('svc_nrs_codes_sync', { p_list: name, p_rows: rows });
      entry.sync = error ? { error: error.message } : data;
      if (!error) copied.push(LIST_WORDS[name](rows.length));
      else failed.push(name);
    } else if ((RESOURCE_LISTS as readonly string[]).includes(name)) failed.push(`${name} (${r.ok ? (list ? 'no codes in it' : 'no list in the answer') : r.status || 'no answer'})`);
    results.lists[name] = entry;
  }
  if (copied.length) said.push(`Copied ${copied.join(', ')}.`);
  if (failed.length) { ok = false; said.push(`Not copied: ${failed.join(', ')}.`); }

  // TaxStreem's own entity record, with the dashboard's key: proves the key, the secret and the Business ID together.
  if (key && sec && biz) {
    if (GAP_MS) await sleep(GAP_MS);
    const r = await nrsCall({ base, key, secret: sec }, `/api/v1/entity/${encodeURIComponent(biz)}`);
    results.entity = answer(r);
    if (r.ok) {
      const e = r.body?.data && typeof r.body.data === 'object' ? r.body.data : r.body;
      const name = String(e?.name || e?.business_name || e?.registered_name || e?.entity_name || e?.legal_name || '').trim();
      said.push(`TaxStreem's entity record came back${name ? ` for ${name}` : ''}.`);
    } else {
      ok = false;
      said.push(r.status === 401 || r.status === 403 ? `NRS refused the API key and secret (${r.status}): ${nrsWhy(r)}.`
        : r.status === 404 ? `NRS has no entity with that Business ID (${nrsWhy(r)}).` : `The entity record did not come back (${r.status || 'no answer'}): ${nrsWhy(r)}.`);
    }
  } else {
    ok = false;
    said.push(`Add the ${[!key && 'API key', !sec && 'API secret', !biz && 'Business ID'].filter(Boolean).join(', ')} to check TaxStreem's entity record.`);
  }
  if (appKey && appSec && biz) {
    if (GAP_MS) await sleep(GAP_MS);
    const r = await nrsCall({ base, key: appKey, secret: appSec }, `/api/v1/entity/${encodeURIComponent(biz)}`);
    results.app_entity = answer(r);
    said.push(r.ok ? 'The APP key works too.' : `NRS refused the APP key (${r.status || 'no answer'}): ${nrsWhy(r)}.`);
    if (!r.ok) ok = false;
  }

  if (svc) {
    results.service_id = { looks_right: /^[A-Z0-9]{8}$/.test(svc) };
    if (!/^[A-Z0-9]{8}$/.test(svc)) { ok = false; said.push('The Service ID should be 8 letters and numbers.'); }
  } else { ok = false; said.push('Add TaxStreem\'s Service ID.'); }

  // crypto_keys.txt: the QR code is the IRN (with a timestamp) and the certificate, encrypted with NRS's public key.
  if (cryptoRaw) {
    const ck = readCryptoKeys(cryptoRaw);
    if ('problem' in ck) { ok = false; results.crypto_keys = { ok: false }; said.push(ck.problem); }
    else {
      try {
        const sample = JSON.stringify({ irn: `CHECK1-${svc || 'XXXXXXXX'}-20260101.${Math.floor(Date.now() / 1000)}`, certificate: ck.certificate });
        const out = publicEncrypt({ key: ck.pem, padding: constants.RSA_PKCS1_PADDING }, Buffer.from(sample));
        results.crypto_keys = { ok: true, encrypted_bytes: out.length };
        said.push('crypto_keys.txt makes a QR code.');
      } catch (e) {
        ok = false; results.crypto_keys = { ok: false, error: String((e as Error).message).slice(0, 200) };
        said.push(`The public key in crypto_keys.txt could not encrypt: ${String((e as Error).message).slice(0, 120)}.`);
      }
    }
  } else { ok = false; said.push('Add crypto_keys.txt for the QR code.'); }

  const note = said.join(' ');
  await saveCheck('nrs', userId, ok, note, results);
  return { ok, note };
}

// ------------------------------------------------------------------ the Google Cloud HSM keys
function kmsProblem(e: unknown, cfg: GeminiConfig, what: string, ring: string, key: string, role: string): string {
  if (e instanceof CredentialError) return e.message;
  if (e instanceof K.KmsError) {
    if (e.status === 403) return `Google refused to ${what} (${e.message}). Give ${cfg.principal || 'the service account'} the ${role} role on ${key}, and check that the Cloud Key Management Service API is on.`;
    if (e.status === 404) return `There is no key ${key} in ${ring}.`;
    return `Google could not ${what}: ${e.message}`;
  }
  return `Could not ${what}: ${(e as Error).message}`;
}

async function kmsCheck(userId: string) {
  const cfg = await geminiConfig(secret);
  if (cfg.mode !== 'vertex') {
    return { ok: false, note: cfg.problem || 'Add the service account key under Google Gemini first: the HSM keys are reached with it.' };
  }
  const ring = K.keyRing(cfg, await secret('GOOGLE_KMS_KEY_RING'));
  const results: Record<string, any> = { ring, principal: cfg.principal };
  const said: string[] = [];
  const done = async (ok: boolean) => { const note = said.join(' '); await saveCheck('kms', userId, ok, note, results); return { ok, note }; };
  const ENC_ROLE = 'Cloud KMS CryptoKey Encrypter/Decrypter', SIGN_ROLE = 'Cloud KMS CryptoKey Signer/Verifier';

  // 1. nrs-credentials: symmetric, in the HSM, and a round trip works.
  try {
    const k = await K.getKey(cfg, ring, K.CREDENTIALS_KEY);
    const level = k.versionTemplate?.protectionLevel || k.primary?.protectionLevel || '';
    results.credentials_key = { purpose: k.purpose, protection: level, primary: k.primary?.state || null };
    if (k.purpose !== 'ENCRYPT_DECRYPT') { said.push(`${K.CREDENTIALS_KEY} is for ${k.purpose}; it should be symmetric encrypt and decrypt.`); return done(false); }
    if (level !== 'HSM') { said.push(`${K.CREDENTIALS_KEY} has protection level ${level || 'unknown'}; NRS wants HSM. Make a new key with protection level HSM.`); return done(false); }
  } catch (e) {
    said.push(kmsProblem(e, cfg, `read ${K.CREDENTIALS_KEY}`, ring, K.CREDENTIALS_KEY, ENC_ROLE));
    return done(false);
  }
  try {
    const plain = crypto.getRandomValues(new Uint8Array(32));
    const ct = await K.encrypt(cfg, ring, plain, 'counta-kms-check');
    const back = await K.decrypt(cfg, ring, ct, 'counta-kms-check');
    const same = back.length === plain.length && back.every((b, i) => b === plain[i]);
    results.round_trip = same;
    if (!same) { said.push(`${K.CREDENTIALS_KEY} gave back something different from what it encrypted.`); return done(false); }
    said.push(`${K.CREDENTIALS_KEY} is an HSM key and encrypts and decrypts.`);
  } catch (e) {
    said.push(kmsProblem(e, cfg, `encrypt with ${K.CREDENTIALS_KEY}`, ring, K.CREDENTIALS_KEY, ENC_ROLE));
    return done(false);
  }

  // 2. invoice-signing: EC P-256 with SHA-256, in the HSM, and its signature verifies with its public key.
  try {
    const k = await K.getKey(cfg, ring, K.SIGNING_KEY);
    const level = k.versionTemplate?.protectionLevel || '';
    const alg = k.versionTemplate?.algorithm || '';
    results.signing_key = { purpose: k.purpose, protection: level, algorithm: alg };
    if (k.purpose !== 'ASYMMETRIC_SIGN' || alg !== 'EC_SIGN_P256_SHA256') {
      said.push(`${K.SIGNING_KEY} is ${k.purpose} ${alg}; it should be asymmetric signing with Elliptic Curve P-256 and a SHA-256 digest.`);
      return done(false);
    }
    if (level !== 'HSM') { said.push(`${K.SIGNING_KEY} has protection level ${level || 'unknown'}; NRS wants HSM.`); return done(false); }
    const v = await K.signingVersion(cfg, ring);
    const pem = await K.publicKeyPem(cfg, v.name);
    const data = new TextEncoder().encode(`counta-kms-check ${new Date().toISOString()}`);
    const sig = await K.sign(cfg, v.name, data);
    const good = await K.verify(pem, data, sig);
    results.signature = { version: v.name.split('/').pop(), verified: good };
    if (!good) { said.push(`A signature from ${K.SIGNING_KEY} did not verify with its own public key.`); return done(false); }
    said.push(`${K.SIGNING_KEY} is an HSM key, and a test signature from version ${v.name.split('/').pop()} verified.`);
  } catch (e) {
    said.push(kmsProblem(e, cfg, `sign with ${K.SIGNING_KEY}`, ring, K.SIGNING_KEY, SIGN_ROLE));
    return done(false);
  }
  return done(true);
}

// ------------------------------------------------------------------ requests
async function staffOnly(sb: SupabaseClient): Promise<Response | null> {
  const { error } = await sb.rpc('admin_einvoice_allowed');
  if (!error) return null;
  return json({ ok: false, reason: /authenticator/i.test(error.message) ? 'aal2' : 'staff', error: error.message }, 403);
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405);
  const auth = req.headers.get('Authorization') || '';
  const sb = createClient(SUPABASE_URL, ANON, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  let body: any;
  try { body = await req.json(); } catch { return json({ ok: false, error: 'Invalid request.' }, 400); }
  const { data: u } = await sb.auth.getUser();
  if (!u?.user) return json({ ok: false, error: 'Sign in first.' }, 401);
  try {
    switch (body?.action) {
      case 'platform_check': {
        const no = await staffOnly(sb);
        if (no) return no;
        if (body.what === 'nrs') return json(await nrsCheck(u.user.id));
        if (body.what === 'kms') return json(await kmsCheck(u.user.id));
        return json({ ok: false, error: 'Check nrs or kms.' }, 400);
      }
      default:
        return json({ ok: false, error: 'Unknown action.' }, 400);
    }
  } catch (e) {
    console.error('einvoice', (e as Error).message);
    return json({ ok: false, error: (e as Error).message }, 500);
  }
});
