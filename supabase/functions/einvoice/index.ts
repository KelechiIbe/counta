// Counta e-invoicing: TaxStreem as System Integrator and Access Point Provider on the NRS Merchant Buyer Solution (MBS).
// See docs/e-invoicing.md.
//
// TaxStreem's admins, signed in with the authenticator code (Authorization: Bearer <user JWT>), POST { action, ... }:
//   platform_check { what: 'nrs' }  -> asks the NRS sandbox (or production) what its answers look like: the health check,
//                                      every code list (copied into nrs_codes), the dashboard's key on TaxStreem's
//                                      business (its entity record where NRS allows it, its invoices, and a test IRN made
//                                      with the Service ID), and whether crypto_keys.txt can make a QR code. What it
//                                      found goes to einvoice_checks, with numbers cut to their last four and no key or
//                                      secret.
//   platform_check { what: 'kms' }  -> checks the Google Cloud HSM keys with only the roles Counta is given: a value
//                                      encrypts and decrypts with nrs-credentials in the HSM, and a signature from
//                                      invoice-signing (EC P-256, SHA-256, in the HSM) verifies with its public key.
// The admin portal's Test buttons for NRS e-invoicing and Google Cloud HSM call these.
//
// Whoever changes a business's settings (manage_settings), signed in, POSTs:
//   settings_keys { org_id, api_key?, api_secret?, crypto_keys? } -> saves the business's own NRS keys: each is wrapped
//                                      with nrs-credentials in the HSM, bound to the business and the field, and only its
//                                      last four characters are kept in the clear. An empty value removes it. New keys
//                                      are tested with NRS straight away (as settings_check).
//   settings_check { org_id }       -> tests the business's keys: NRS lets the key read the business's invoices, accepts
//                                      a test IRN made with its Service ID (and keeps nothing), and crypto_keys.txt
//                                      encrypts a QR code. While NRS is in test mode, a business TaxStreem has put on its
//                                      own provider keys is tested with those.
//
// The database (x-counta-hook: <PUSH_HOOK_SECRET>) POSTs:
//   send { sale_id }                -> a sale just issued: one to a business or government is validated and signed by
//                                      NRS at once; one to anyone else gets its IRN and QR code and waits for the batch.
//   send {}                         -> every five minutes: the sales due (oldest first, paced), and payments to tell NRS.
// See invoice.ts for how a sale is written for NRS, and docs/e-invoicing.md.
//
// Keys are read from Supabase Vault (set in the admin portal) first, then from the Edge Function secrets. NRS_BASE_URL is
// the address on the NRS dashboard; KMS_BASE_URL is for tests.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { publicEncrypt, constants } from 'node:crypto';
import { Buffer } from 'node:buffer';
import { CredentialError, geminiConfig, type GeminiConfig } from './google.ts';
import * as K from './kms.ts';
import { codeRow, entityName, firstList, holds, mask, MAYBE_LISTS, nrsBase, nrsCall, nrsWhy, readCryptoKeys, RESOURCE_LISTS, shape, valuesUnder, type NrsAnswer } from './nrs.ts';
import { buildInvoice, type Claim, missing, missingNow, refusalInWords } from './invoice.ts';

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
// What NRS answered, kept for support: the shape of the body, and its reason in full (shape() cuts long strings).
const answer = (r: NrsAnswer) => ({ status: r.status, ms: r.ms, body: shape(r.body), why: mask(nrsWhy(r)) });

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

  // TaxStreem on the MBS, with the dashboard's key. GET /entity/{id} takes an entity's own id, which is not the Business
  // ID, so the entities this key can see are listed first, the one holding the Business ID is found among them, and its
  // record is read for the Business ID and Service ID NRS has. The sandbox keeps entity records from a provider's key
  // (403, "user does not have access to this resource"), so the key is then proved on the business itself: its invoices
  // (a read that takes the Business ID) and a test IRN made with the Service ID, which NRS validates without keeping.
  const SEARCH = '/api/v1/entity?size=20&page=1&sort_by=created_at&sort_direction_desc=true&reference=';
  const SVC_KEY = /^service_?id$/i;
  let nrsServiceIds: string[] = [];
  let keyRefused = false;
  if (key && sec) {
    if (GAP_MS) await sleep(GAP_MS);
    const r = await nrsCall({ base, key, secret: sec }, SEARCH);
    results.entities = answer(r);
    if (r.status === 401) { ok = false; keyRefused = true; said.push(`NRS refused the API key and secret (401): ${nrsWhy(r)}.`); }
    else if (r.status === 403) said.push(`NRS keeps entity records from this key (403: ${nrsWhy(r)}), so it was tried on the business itself.`);
    else if (!r.ok) said.push(`The list of entities did not come back (${r.status || 'no answer'}: ${nrsWhy(r)}), so the key was tried on the business itself.`);
    else {
      const list = (firstList(r.body) || []) as any[];
      const names = list.map(entityName).filter(Boolean);
      const hit = biz ? list.find((e) => holds(e, biz)) : undefined;
      if (!list.length) { ok = false; said.push('The key works, but NRS lists no entity for it.'); }
      else said.push(`The key works and sees ${list.length === 1 ? 'one entity' : `${list.length} entities`}${names.length ? ` (${names.slice(0, 3).join(', ')}${names.length > 3 ? ', …' : ''})` : ''}.`);
      // The full record of the entity with the Business ID (or the only one), for its businesses and Service IDs.
      const target = hit || (list.length === 1 ? list[0] : undefined);
      const eid = target ? String(target.id || target.entity_id || '') : '';
      let record: unknown = target;
      if (eid) {
        if (GAP_MS) await sleep(GAP_MS);
        const er = await nrsCall({ base, key, secret: sec }, `/api/v1/entity/${encodeURIComponent(eid)}`);
        results.entity = answer(er);
        if (er.ok) record = er.body?.data && typeof er.body.data === 'object' ? er.body.data : er.body;
      }
      const inRecord = biz ? holds(record, biz) || Boolean(hit) : false;
      nrsServiceIds = [...new Set(valuesUnder(record, SVC_KEY).map((x) => x.toUpperCase()))];
      results.entity_match = { visible: list.length, business_found: inRecord, service_ids_found: nrsServiceIds.length };
      if (biz && list.length && inRecord) said.push('The Business ID is one of its businesses.');
      else if (biz && list.length) { ok = false; said.push('The Business ID is not among the businesses this key can see. Copy it again from the NRS dashboard.'); }
    }
    if (!keyRefused && !biz) { ok = false; said.push('Add the Business ID.'); }
    if (!keyRefused && biz) {
      // The business's invoices: proves the key may act for the Business ID.
      if (GAP_MS) await sleep(GAP_MS);
      const inv = await nrsCall({ base, key, secret: sec }, `/api/v1/invoice/${encodeURIComponent(biz)}?size=1&page=1&sort_by=created_at&sort_direction_desc=true`);
      results.invoices = answer(inv);
      if (inv.ok) said.push('The key may act for the Business ID.');
      else {
        ok = false;
        said.push(inv.status === 401 ? `NRS refused the API key and secret (401): ${nrsWhy(inv)}.`
          : inv.status === 403 || inv.status === 404 ? `NRS would not let the key reach the Business ID's invoices (${inv.status}: ${nrsWhy(inv)}). Check that the Business ID and the key come from the same NRS account.`
          : `The Business ID's invoices did not come back (${inv.status || 'no answer'}: ${nrsWhy(inv)}).`);
      }
      // A test IRN with the Service ID and today's date in Lagos, validated and not kept.
      if (inv.ok && /^[A-Z0-9]{8}$/.test(svc)) {
        const day = new Date(Date.now() + 3600_000).toISOString().slice(0, 10).replace(/-/g, '');
        const irn = `CNTCHK1-${svc}-${day}`;
        if (GAP_MS) await sleep(GAP_MS);
        const v = await nrsCall({ base, key, secret: sec }, '/api/v1/invoice/irn/validate', { method: 'POST', body: { invoice_reference: 'CNTCHK1', business_id: biz, irn } });
        results.irn_validate = { ...answer(v), irn };
        const code = Number(v.body?.code);
        if (v.ok && !(code >= 400)) said.push(`NRS accepted ${irn} as an IRN for the business, so the Service ID is right.`);
        else { ok = false; said.push(`NRS did not accept the test IRN ${irn} (${v.status || 'no answer'}: ${nrsWhy(v)}).`); }
      }
    }
  } else {
    ok = false;
    said.push(`Add the ${[!key && 'API key', !sec && 'API secret'].filter(Boolean).join(' and ')} to check TaxStreem's record with NRS.`);
  }
  // The APP key pair, when the dashboard gives one: tried on the business's invoices like the main key.
  if (appKey && appSec) {
    if (GAP_MS) await sleep(GAP_MS);
    const r = await nrsCall({ base, key: appKey, secret: appSec }, biz ? `/api/v1/invoice/${encodeURIComponent(biz)}?size=1&page=1&sort_by=created_at&sort_direction_desc=true` : SEARCH);
    results.app_check = answer(r);
    said.push(r.ok ? 'The APP key works too.' : `NRS refused the APP key (${r.status || 'no answer'}): ${nrsWhy(r)}.`);
    if (!r.ok) ok = false;
  }

  // The Service ID: 8 letters and numbers, and the one NRS has for the business when its record shows it. What was
  // entered is described, never repeated, in case something else was pasted there.
  const svcOk = /^[A-Z0-9]{8}$/.test(svc);
  const uuidLike = /^[0-9A-F]{8}-[0-9A-F]{4}-/.test(svc);
  results.service_id = { looks_right: svcOk, length: svc.length, looks_like_uuid: uuidLike, matches_nrs: nrsServiceIds.length ? nrsServiceIds.includes(svc) : null };
  const nrsHas = nrsServiceIds.length ? ` NRS has TaxStreem's Service ID as ${nrsServiceIds.join(' or ')}.` : '';
  if (!svc) { ok = false; said.push(`Add TaxStreem's Service ID.${nrsHas}`); }
  else if (!svcOk) {
    ok = false;
    said.push(`The Service ID should be 8 letters and numbers; the one entered is ${svc.length} characters long${uuidLike ? ' and looks like a Business ID' : ''}.${nrsHas}`);
  } else if (nrsServiceIds.length && !nrsServiceIds.includes(svc)) { ok = false; said.push(`The Service ID differs from NRS's record.${nrsHas}`); }
  else if (nrsServiceIds.length) said.push('The Service ID matches NRS\'s record.');

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

  // 1. nrs-credentials: a value encrypts and decrypts, and KMS says the version that did it is in the HSM. Only the two
  // roles Counta is given are used: reading a key's settings would take another.
  try {
    const plain = crypto.getRandomValues(new Uint8Array(32));
    const enc = await K.encryptDetail(cfg, ring, plain, 'counta-kms-check');
    results.credentials_key = { version: enc.version.split('/').pop() || null, protection: enc.protectionLevel || null };
    if (enc.protectionLevel && enc.protectionLevel !== 'HSM') {
      said.push(`${K.CREDENTIALS_KEY} has protection level ${enc.protectionLevel}; NRS wants HSM. Make a new key with protection level HSM.`);
      return done(false);
    }
    const back = await K.decrypt(cfg, ring, enc.ciphertext, 'counta-kms-check');
    const same = back.length === plain.length && back.every((b, i) => b === plain[i]);
    results.round_trip = same;
    if (!same) { said.push(`${K.CREDENTIALS_KEY} gave back something different from what it encrypted.`); return done(false); }
    said.push(`${K.CREDENTIALS_KEY} is an HSM key and encrypts and decrypts.`);
  } catch (e) {
    said.push(kmsProblem(e, cfg, `encrypt with ${K.CREDENTIALS_KEY}`, ring, K.CREDENTIALS_KEY, ENC_ROLE));
    return done(false);
  }

  // 2. invoice-signing: its public key says EC P-256 with SHA-256 in the HSM, and a signature made with it verifies.
  try {
    const v = await K.signingVersion(cfg, ring);
    const pk = await K.publicKey(cfg, v.name);
    const ver = v.name.split('/').pop();
    results.signing_key = { version: ver, listed: v.listed, algorithm: pk.algorithm || null, protection: pk.protectionLevel || null };
    if (pk.algorithm && pk.algorithm !== 'EC_SIGN_P256_SHA256') {
      said.push(`${K.SIGNING_KEY} uses ${pk.algorithm}; it should be asymmetric signing with Elliptic Curve P-256 and a SHA-256 digest.`);
      return done(false);
    }
    if (pk.protectionLevel && pk.protectionLevel !== 'HSM') { said.push(`${K.SIGNING_KEY} has protection level ${pk.protectionLevel}; NRS wants HSM.`); return done(false); }
    const data = new TextEncoder().encode(`counta-kms-check ${new Date().toISOString()}`);
    const sig = await K.sign(cfg, v.name, data);
    const good = await K.verify(pk.pem, data, sig);
    results.signature = { version: ver, verified: good };
    if (!good) { said.push(`A signature from ${K.SIGNING_KEY} did not verify with its own public key.`); return done(false); }
    said.push(`${K.SIGNING_KEY} is an HSM key, and a test signature from version ${ver} verified.`);
  } catch (e) {
    said.push(kmsProblem(e, cfg, `sign with ${K.SIGNING_KEY}`, ring, K.SIGNING_KEY, SIGN_ROLE));
    return done(false);
  }
  return done(true);
}

// ------------------------------------------------------------------ a business's own keys
// Each key is wrapped with nrs-credentials in the HSM, bound to the business and the field: a value copied to another
// business, or from the key to the secret, does not decrypt.
const aad = (orgId: string, field: string) => `counta:einvoice:${orgId}:${field}`;
const FIELD_WORDS: Record<string, string> = { api_key: 'API key', api_secret: 'API secret', crypto_keys: 'crypto_keys.txt' };
const enc = new TextEncoder(), dec = new TextDecoder();

class Refusal extends Error {
  constructor(message: string, public status = 400) { super(message); }
}

async function kmsSetup(): Promise<{ cfg: GeminiConfig; ring: string }> {
  const cfg = await geminiConfig(secret);
  if (cfg.mode !== 'vertex') throw new Refusal('TaxStreem has not connected the Google Cloud HSM yet, so keys cannot be saved. Try again later.', 503);
  return { cfg, ring: K.keyRing(cfg, await secret('GOOGLE_KMS_KEY_RING')) };
}

// Only someone who changes the business's settings manages its NRS keys (the database decides, as the signed-in person).
async function settingsEditor(sb: SupabaseClient, orgId: string): Promise<Response | null> {
  if (!/^[0-9a-f-]{36}$/i.test(orgId)) return json({ ok: false, error: 'Choose the business.' }, 400);
  const { data, error } = await sb.rpc('einvoice_settings_get', { p_org: orgId });
  if (error) return json({ ok: false, error: error.message }, 403);
  if (!data?.can?.edit) return json({ ok: false, error: 'Only someone who changes the business\'s settings manages its NRS keys.' }, 403);
  return null;
}

// What was pasted, checked before anything is sent to the HSM. An empty value removes the key.
function keyInput(field: string, raw: unknown): { plain: string | null; hint: string | null } {
  const v = String(raw ?? '').trim();
  if (!v) return { plain: null, hint: null };
  if (field === 'crypto_keys') {
    const ck = readCryptoKeys(v);
    if ('problem' in ck) throw new Refusal(ck.problem.replace('NRS_CRYPTO_KEYS', 'crypto_keys.txt'));
    const j = JSON.parse(v);
    return { plain: JSON.stringify({ public_key: String(j.public_key).trim(), certificate: ck.certificate }), hint: `certificate •••• ${ck.certificate.slice(-4)}` };
  }
  if (v.length < 8 || v.length > 512 || /\s/.test(v)) throw new Refusal(`That does not look like the ${FIELD_WORDS[field]} from the NRS dashboard.`);
  return { plain: v, hint: `•••• ${v.slice(-4)}` };
}

async function settingsKeys(sb: SupabaseClient, orgId: string, userId: string, body: any) {
  const no = await settingsEditor(sb, orgId);
  if (no) return no;
  const given = Object.keys(FIELD_WORDS).filter((f) => body[f] !== undefined && body[f] !== null);
  if (!given.length) return json({ ok: false, error: 'Paste the key, the secret or crypto_keys.txt to save.' }, 400);
  const p: Record<string, { ct: string; hint: string } | null> = {};
  try {
    const inputs = given.map((f) => [f, keyInput(f, body[f])] as const);
    const needKms = inputs.some(([, x]) => x.plain);
    const { cfg, ring } = needKms ? await kmsSetup() : { cfg: null, ring: '' };
    for (const [f, x] of inputs) {
      if (!x.plain) { p[f] = null; continue; }
      try { p[f] = { ct: await K.encrypt(cfg!, ring, enc.encode(x.plain), aad(orgId, f)), hint: x.hint! }; }
      catch (e) { throw new Refusal(kmsProblem(e, cfg!, `wrap the ${FIELD_WORDS[f]} with ${K.CREDENTIALS_KEY}`, ring, K.CREDENTIALS_KEY, 'Cloud KMS CryptoKey Encrypter/Decrypter'), 502); }
    }
  } catch (e) {
    if (e instanceof Refusal) return json({ ok: false, error: e.message }, e.status);
    throw e;
  }
  const { data: saved, error } = await admin.rpc('svc_einvoice_keys_save', { p_org: orgId, p_user: userId, p });
  if (error) return json({ ok: false, error: error.message }, 400);
  // New keys are tested straight away, unless the business runs on TaxStreem's keys (which these do not change).
  const check = saved?.platform_keys ? null : await businessCheck(orgId, userId);
  return json({ ok: true, keys: saved?.keys, check });
}

// The business's keys with NRS: only a key of that business may read its invoices, and NRS validates a test IRN made
// with its Service ID without keeping it. crypto_keys.txt must encrypt a QR code. On TaxStreem's test keys, TaxStreem's
// are used. The note says what was found and never repeats a key or an ID.
async function businessCheck(orgId: string, userId: string): Promise<{ ok: boolean; note: string; saved: boolean }> {
  const { data: b, error } = await admin.rpc('svc_einvoice_check_begin', { p_org: orgId });
  if (error) throw new Error(error.message);
  if (!b?.ok) return { ok: false, saved: false, note: b?.reason === 'too_soon' ? 'NRS was asked a moment ago. Try again in a few seconds.' : 'Set up e-invoicing first.' };
  const base = nrsBase(await secret('NRS_BASE_URL'));
  if (!base) return { ok: false, saved: false, note: 'TaxStreem has not connected Counta to NRS yet. Try again later.' };
  const said: string[] = [];
  const done = async (ok: boolean) => {
    const note = said.join(' ');
    const { data: r } = await admin.rpc('svc_einvoice_check_done', { p_org: orgId, p_version: b.version, p_user: userId, p_ok: ok, p_note: note });
    return { ok, note, saved: Boolean(r?.saved) };
  };
  let key = '', sec = '', cryptoRaw = '';
  let biz = String(b.business_id || ''), svc = String(b.service_id || '');
  if (b.platform_keys) {
    key = await secret('NRS_API_KEY'); sec = await secret('NRS_API_SECRET'); cryptoRaw = await secret('NRS_CRYPTO_KEYS');
    biz = (await secret('NRS_BUSINESS_ID')).toLowerCase(); svc = (await secret('NRS_SERVICE_ID')).toUpperCase();
    said.push('On TaxStreem\'s test keys:');
    if (!key || !sec || !biz || !svc) { said.push('TaxStreem\'s own keys are not all set yet.'); return done(false); }
  } else {
    const missing = [!biz && 'Business ID', !svc && 'Service ID', !b.api_key_ct && 'API key', !b.api_secret_ct && 'API secret', !b.crypto_ct && 'crypto_keys.txt'].filter(Boolean);
    if (missing.length) return { ok: false, saved: false, note: `Add the ${missing.join(', ')} first.` };
    let cfg: GeminiConfig | null = null, ring = '';
    try {
      ({ cfg, ring } = await kmsSetup());
      key = dec.decode(await K.decrypt(cfg, ring, b.api_key_ct, aad(orgId, 'api_key')));
      sec = dec.decode(await K.decrypt(cfg, ring, b.api_secret_ct, aad(orgId, 'api_secret')));
      cryptoRaw = dec.decode(await K.decrypt(cfg, ring, b.crypto_ct, aad(orgId, 'crypto_keys')));
    } catch (e) {
      if (e instanceof Refusal) return { ok: false, saved: false, note: e.message };
      said.push(`The saved keys could not be read back from the HSM (${cfg ? kmsProblem(e, cfg, 'unwrap them', ring, K.CREDENTIALS_KEY, 'Cloud KMS CryptoKey Encrypter/Decrypter') : (e as Error).message}). Save them again.`);
      return done(false);
    }
  }
  const auth = { base, key, secret: sec };
  const inv = await nrsCall(auth, `/api/v1/invoice/${encodeURIComponent(biz)}?size=1&page=1&sort_by=created_at&sort_direction_desc=true`);
  let ok = inv.ok;
  if (inv.ok) said.push('NRS let the key act for the Business ID.');
  else said.push(inv.status === 401 ? `NRS refused the API key and secret (401): ${nrsWhy(inv)}.`
    : inv.status === 403 || inv.status === 404 ? `NRS would not let the key reach the Business ID's invoices (${inv.status}: ${nrsWhy(inv)}). Check that the Business ID and the keys come from the same NRS account.`
    : `NRS did not answer as expected (${inv.status || 'no answer'}: ${nrsWhy(inv)}). Try again later.`);
  if (inv.ok) {
    const day = new Date(Date.now() + 3600_000).toISOString().slice(0, 10).replace(/-/g, '');
    const irn = `CNTCHK1-${svc}-${day}`;
    if (GAP_MS) await sleep(GAP_MS);
    const v = await nrsCall(auth, '/api/v1/invoice/irn/validate', { method: 'POST', body: { invoice_reference: 'CNTCHK1', business_id: biz, irn } });
    if (v.ok && !(Number(v.body?.code) >= 400)) said.push('NRS accepted a test IRN made with the Service ID.');
    else { ok = false; said.push(`NRS did not accept a test IRN made with the Service ID (${v.status || 'no answer'}: ${nrsWhy(v)}). Copy the Service ID again from the NRS dashboard.`); }
  }
  const ck = cryptoRaw ? readCryptoKeys(cryptoRaw) : { problem: b.platform_keys ? 'TaxStreem\'s crypto_keys.txt is not set yet.' : 'crypto_keys.txt is missing.' };
  if ('problem' in ck) { ok = false; said.push(ck.problem.replace('NRS_CRYPTO_KEYS', 'crypto_keys.txt')); }
  else {
    try {
      publicEncrypt({ key: ck.pem, padding: constants.RSA_PKCS1_PADDING }, Buffer.from(JSON.stringify({ irn: `CNTCHK1-${svc}-20260101.${Math.floor(Date.now() / 1000)}`, certificate: ck.certificate })));
      said.push('crypto_keys.txt makes a QR code.');
    } catch (e) { ok = false; said.push(`The public key in crypto_keys.txt could not encrypt: ${String((e as Error).message).slice(0, 120)}.`); }
  }
  return done(ok);
}

// ------------------------------------------------------------------ sales to NRS (part 2b)
// The database asks (x-counta-hook) when a sale is issued, { action: 'send', sale_id }, and every five minutes, { action:
// 'send' }. A sale to a business or government is validated and signed at once (cleared); a sale to anyone else gets its
// QR code at once and is sent with the next batch (reported). Each try's outcome goes back to the database
// (svc_einvoice_done): signed, refused (a person puts it right), or tried again later (NRS down or busy). Payments in
// full are told to NRS for signed sales (PATCH update/{irn}).
type Keys = { key: string; secret: string; business: string; crypto: { pem: string; certificate: string } | null; problem?: string };

// The keys a sale goes with: TaxStreem's while the business is on TaxStreem's test keys, else its own, unwrapped in the HSM.
async function keysFor(orgId: string, creds: any, cache: Map<string, Keys>): Promise<Keys> {
  const id = `${orgId}:${creds.platform_keys ? 'platform' : 'own'}`;
  const hit = cache.get(id);
  if (hit) return hit;
  let k: Keys;
  if (creds.platform_keys) {
    const raw = await secret('NRS_CRYPTO_KEYS');
    const ck = raw ? readCryptoKeys(raw) : null;
    k = { key: await secret('NRS_API_KEY'), secret: await secret('NRS_API_SECRET'), business: (await secret('NRS_BUSINESS_ID')).toLowerCase(),
      crypto: ck && !('problem' in ck) ? ck : null };
    if (!k.key || !k.secret || !k.business) k.problem = 'TaxStreem\'s own NRS keys are not all set yet.';
  } else {
    try {
      const { cfg, ring } = await kmsSetup();
      const raw = creds.crypto_ct ? dec.decode(await K.decrypt(cfg, ring, creds.crypto_ct, aad(orgId, 'crypto_keys'))) : '';
      const ck = raw ? readCryptoKeys(raw) : null;
      k = { key: creds.api_key_ct ? dec.decode(await K.decrypt(cfg, ring, creds.api_key_ct, aad(orgId, 'api_key'))) : '',
        secret: creds.api_secret_ct ? dec.decode(await K.decrypt(cfg, ring, creds.api_secret_ct, aad(orgId, 'api_secret'))) : '',
        business: String(creds.business_id || ''), crypto: ck && !('problem' in ck) ? ck : null };
      if (!k.key || !k.secret || !k.business) k.problem = 'The business\'s NRS keys are not all saved. Add them in Settings, E-invoicing.';
    } catch (e) {
      k = { key: '', secret: '', business: '', crypto: null, problem: e instanceof Refusal ? e.message : `The saved keys could not be read back from the HSM: ${(e as Error).message.slice(0, 160)}` };
    }
  }
  cache.set(id, k);
  return k;
}

// The QR code NRS asks for: the IRN with the Unix time after a full stop, and the certificate, encrypted with NRS's public
// key from crypto_keys.txt (RSA, PKCS #1 v1.5), base64-encoded.
function makeQr(irn: string, crypto: { pem: string; certificate: string }): string {
  const data = JSON.stringify({ irn: `${irn}.${Math.floor(Date.now() / 1000)}`, certificate: crypto.certificate });
  return publicEncrypt({ key: crypto.pem, padding: constants.RSA_PKCS1_PADDING }, Buffer.from(data)).toString('base64');
}

const nrsOk = (r: NrsAnswer) => r.ok && !(Number(r.body?.code) >= 400);
// What kind of no it was: NRS refusing the invoice as written (a person puts it right), refusing the keys, or not
// answering (tried again later).
function verdict(r: NrsAnswer): 'refused' | 'keys' | 'retry' {
  if (r.status === 401 || r.status === 403) return 'keys';
  if (r.status === 0 || r.status === 408 || r.status === 429 || r.status >= 500) return 'retry';
  if (r.status >= 400 || Number(r.body?.code) >= 400) return 'refused';
  return 'retry';
}
const dupe = (r: NrsAnswer) => /already|duplicate|exist/i.test(nrsWhy(r));

async function done(saleId: string, p: Record<string, unknown>) {
  const { data, error } = await admin.rpc('svc_einvoice_done', { p_sale: saleId, p });
  if (error) console.error('einvoice: could not record the answer', saleId, error.message);
  return data;
}

async function sendOne(saleId: string, what: 'kick' | 'send', platformSvc: string, cache: Map<string, Keys>, base: string): Promise<string> {
  const { data: c, error } = await admin.rpc('svc_einvoice_claim', { p_sale: saleId, p_what: what, p: { service_id: platformSvc } });
  if (error) { console.error('einvoice: claim', saleId, error.message); return 'error'; }
  if (c?.skip) return `skip:${c.skip}`;
  const keys = await keysFor(c.org_id, c.creds, cache);
  let qr: string | undefined;
  if (!c.has_qr && keys.crypto) {
    try { qr = makeQr(c.irn, keys.crypto); } catch (e) { console.warn('einvoice: QR', (e as Error).message); }
  }
  if (c.what === 'qr') { await done(saleId, { outcome: 'qr', qr }); return 'qr'; }
  if (keys.problem || !base) {
    await done(saleId, { outcome: 'retry', qr, note: keys.problem || 'TaxStreem has not connected Counta to NRS yet.' });
    return 'retry';
  }
  if (!keys.crypto) { await done(saleId, { outcome: 'retry', qr, note: 'crypto_keys.txt is missing, so the QR code cannot be made.' }); return 'retry'; }
  const claim = { ...c, creds: { ...c.creds, business_id: keys.business } } as Claim;
  // What NRS would refuse anyway is not sent. Codes Gemini is still choosing get a few tries' grace; anything else (the
  // address, the Tax ID) needs a person at once.
  const lacking = missing(claim);
  if (lacking.length) {
    const last = missingNow(claim).length > 0 || Number(c.tries) >= 4;
    await done(saleId, { outcome: last ? 'refused' : 'retry', qr,
      note: last ? `Not sent to NRS: add ${lacking.join('; ')}, then send it again.` : `Waiting for ${lacking.join('; ')} before it goes to NRS.` });
    return last ? 'refused' : 'retry';
  }
  const auth = { base, key: keys.key, secret: keys.secret };
  const irn = String(c.irn);
  // Tried before: NRS may have signed it then without Counta hearing the answer.
  if (Number(c.tries) > 1) {
    const seen = await nrsCall(auth, `/api/v1/invoice/confirm/${encodeURIComponent(irn)}`);
    if (nrsOk(seen) && seen.body && holds(seen.body, irn)) {
      await done(saleId, { outcome: 'signed', qr, note: 'NRS had signed it on an earlier try.', answer: shape(seen.body), pay_status: c.facts.sale.paid ? 'PAID' : 'PENDING' });
      return 'signed';
    }
    if (GAP_MS) await sleep(GAP_MS);
  }
  const payload = buildInvoice(claim);
  const tell = async (r: NrsAnswer, step: string): Promise<string> => {
    const v = verdict(r), why = nrsWhy(r);
    // The owner reads the note; the HTTP status stays in the answer kept for support.
    if (v === 'refused') {
      const plain = refusalInWords(why);
      await done(saleId, { outcome: 'refused', qr, note: `NRS refused it at ${step}: ${plain ? `${plain} NRS said: ${why}` : why}`, answer: answer(r) });
      return 'refused';
    }
    await done(saleId, { outcome: 'retry', qr, answer: answer(r),
      note: v === 'keys' ? `NRS refused the keys (${r.status}): ${why}. Check them in Settings, E-invoicing.` : `NRS did not answer (${r.status || 'no answer'}: ${why}). Counta tries again shortly.` });
    return 'retry';
  };
  const val = await nrsCall(auth, '/api/v1/invoice/validate', { method: 'POST', body: payload, timeoutMs: 30_000 });
  if (!nrsOk(val) && !(dupe(val) && Number(c.tries) > 1)) return await tell(val, 'validation');
  if (GAP_MS) await sleep(GAP_MS);
  const sig = await nrsCall(auth, '/api/v1/invoice/sign', { method: 'POST', body: payload, timeoutMs: 30_000 });
  if (!nrsOk(sig)) {
    if (dupe(sig)) {
      const seen = await nrsCall(auth, `/api/v1/invoice/confirm/${encodeURIComponent(irn)}`);
      if (nrsOk(seen)) {
        await done(saleId, { outcome: 'signed', qr, note: 'NRS had signed it already.', answer: shape(seen.body), pay_status: payload.payment_status });
        return 'signed';
      }
    }
    return await tell(sig, 'signing');
  }
  await done(saleId, { outcome: 'signed', qr, note: 'Signed by NRS.', answer: shape(sig.body), pay_status: payload.payment_status });
  return 'signed';
}

async function payOne(saleId: string, cache: Map<string, Keys>, base: string): Promise<string> {
  const { data: c, error } = await admin.rpc('svc_einvoice_claim', { p_sale: saleId, p_what: 'pay', p: {} });
  if (error) { console.error('einvoice: claim pay', saleId, error.message); return 'error'; }
  if (c?.skip) return `skip:${c.skip}`;
  const keys = await keysFor(c.org_id, c.creds, cache);
  if (keys.problem || !base) {
    await admin.rpc('svc_einvoice_pay_done', { p_sale: saleId, p_ok: false, p_note: keys.problem || 'NRS is not connected.' });
    return 'retry';
  }
  const r = await nrsCall({ base, key: keys.key, secret: keys.secret }, `/api/v1/invoice/update/${encodeURIComponent(c.irn)}`,
    { method: 'PATCH', body: { payment_status: c.pay, reference: String(c.reference || '').slice(0, 100) } });
  await admin.rpc('svc_einvoice_pay_done', { p_sale: saleId, p_ok: nrsOk(r), p_note: nrsOk(r) ? null : `NRS said ${r.status || 'nothing'}: ${nrsWhy(r)}` });
  return nrsOk(r) ? 'paid' : 'retry';
}

// One sale (as it is issued) or the due batch, oldest first, paced and stopped after about two minutes; whatever is left
// waits for the next tick.
async function sendDue(saleId: string | null) {
  const base = nrsBase(await secret('NRS_BASE_URL'));
  const platformSvc = (await secret('NRS_SERVICE_ID')).toUpperCase();
  const cache = new Map<string, Keys>();
  const out: Record<string, number> = {};
  const count = (k: string) => { const key = k.split(':')[0]; out[key] = (out[key] || 0) + 1; };
  if (saleId) { count(await sendOne(saleId, 'kick', platformSvc, cache, base)); return out; }
  const stop = Date.now() + 110_000;
  const { data: due } = await admin.rpc('svc_einvoice_due', { p_limit: 300 });
  for (const d of (due as any[]) || []) {
    if (Date.now() > stop) { count('later'); continue; }
    try { count(d.what === 'pay' ? await payOne(d.sale_id, cache, base) : await sendOne(d.sale_id, 'send', platformSvc, cache, base)); }
    catch (e) { console.error('einvoice: send', d.sale_id, (e as Error).message); count('error'); }
    if (GAP_MS) await sleep(GAP_MS);
  }
  return out;
}

// The database's own calls carry the shared hook secret (Vault, or the Edge Function secret), never a user.
async function hookAllowed(hook: string): Promise<boolean> {
  let expected = (Deno.env.get('PUSH_HOOK_SECRET') || '').trim();
  if (!expected) {
    const { data } = await admin.rpc('app_secret', { p_name: 'PUSH_HOOK_SECRET' });
    expected = typeof data === 'string' ? data.trim() : '';
  }
  if (!expected || expected.length !== hook.length) return false;
  let d = 0;
  for (let i = 0; i < hook.length; i++) d |= hook.charCodeAt(i) ^ expected.charCodeAt(i);
  return d === 0;
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
  const hook = req.headers.get('x-counta-hook') || '';
  if (hook) {
    if (!(await hookAllowed(hook))) return json({ ok: false, error: 'Not allowed.' }, 401);
    if (body?.action !== 'send') return json({ ok: false, error: 'Unknown action.' }, 400);
    const saleId = /^[0-9a-f-]{36}$/i.test(String(body.sale_id || '')) ? String(body.sale_id) : null;
    // The database gives up waiting after 15 seconds, so on Supabase the work carries on after the answer.
    const work = sendDue(saleId).catch((e) => { console.error('einvoice: send', (e as Error).message); return { error: 1 }; });
    const rt = (globalThis as any).EdgeRuntime;
    if (rt?.waitUntil) { rt.waitUntil(work); return json({ ok: true, started: true }); }
    return json({ ok: true, ...(await work) });
  }
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
      case 'settings_keys': return await settingsKeys(sb, String(body.org_id || ''), u.user.id, body);
      case 'settings_check': {
        const orgId = String(body.org_id || '');
        const no = await settingsEditor(sb, orgId);
        if (no) return no;
        return json({ ok: true, check: await businessCheck(orgId, u.user.id) });
      }
      default:
        return json({ ok: false, error: 'Unknown action.' }, 400);
    }
  } catch (e) {
    console.error('einvoice', (e as Error).message);
    return json({ ok: false, error: (e as Error).message }, 500);
  }
});
