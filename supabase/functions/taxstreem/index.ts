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
//
// Flux (TaxStreem's filing engine) reporting on a companies income tax return Counta sent it (docs/flux-cit-handoff.md):
//   POST /taxstreem/flux/cit-status     body { counta_org_id, accounting_year, status: processing|sent|filed|rejected, ref,
//                                              message, acknowledgement_ref, filed_at, rev360_computation }
// and on the VAT, WHT and withholding VAT returns, and the payment Rev360 asks for after each return (docs/flux-tax-returns.md):
//   POST /taxstreem/flux/return-status  body { counta_org_id, tax: vat|wht|wvat, period: 'YYYY-MM', status, ref, message,
//                                              acknowledgement_ref, filed_at }
//   POST /taxstreem/flux/payment        body { counta_org_id, tax: vat|wht|wvat|cit, period | accounting_year, prn, amount,
//                                              breakdown: { tax, credit_applied, penalty, interest, late_filing_penalty, charges },
//                                              account: { number, bank_name, bank_code?, name }, expires_at, ref, message }
//                                       -> stored, reconciled with the return, checked with the bank and, when everything
//                                          agrees, paid from the tax wallet
//   POST /taxstreem/flux/payment-status body { counta_org_id, prn, status: confirmed|not_received|expired, receipt_ref, message }
//   Header: x-counta-signature, the same scheme signed with FLUX_SECRET.
// Each of the four can carry the files Rev360 gave (the filing acknowledgement or evidence, the PRN page, the payment
// receipt), which Counta keeps in the business's Documents:
//   documents: [{ kind: acknowledgement|filing_evidence|assessment|prn|payment_receipt|tax_clearance|other, name,
//                 content_type, url (https, on Flux's own host or FLUX_FILE_HOSTS) | content_base64 }]
//   up to 10 a call, 15 MB each and 40 MB together; PDF, PNG, JPEG, WebP, Excel, CSV or Word. The answer then says
//   { documents: { stored, failed: [{ name, why }] } }; a file that fails never undoes the status.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { SsoError, verifyBody, verifySsoToken } from './sso.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const admin = createClient(SUPABASE_URL, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } });

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-taxstreem-signature, x-counta-signature',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

const cache = new Map<string, { v: string; at: number }>();
// Keys set in the admin portal (Supabase Vault) come first; the Edge Function secrets are the fallback.
async function secret(name: string): Promise<string> {
  const hit = cache.get(name);
  if (hit && Date.now() - hit.at < 60_000) return hit.v;
  const { data } = await admin.rpc('svc_secret', { p_name: name });
  const v = (typeof data === 'string' ? data.trim() : '') || (Deno.env.get(name) || '').trim();
  cache.set(name, { v, at: Date.now() });
  return v;
}

async function sso(token: string) {
  const claims = await verifySsoToken(token, await secret('TAXSTREEM_SSO_SECRET'), { issuer: (await secret('TAXSTREEM_SSO_ISSUER')) || 'taxstreem' });
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
    // A bill sent back to the supplier is void here, with the reason and the note the supplier was sent.
    const { data: b } = await admin.from('bills').select('id, number, status, total, amount_paid, wht_withheld, due_date, returned_reason, returned_note, returned_at')
      .eq('org_id', org.id).eq('source', 'prism').eq('external_ref', String(body.prism_id || '')).maybeSingle();
    if (!b) return json({ ok: false, error: 'Bill not found.' }, 404);
    return json({ ok: true, bill: b });
  }
  return json({ ok: false, error: 'Unknown path.' }, 404);
}

// The database's hook secret, which the payments function takes from its own Edge Function secret first.
async function hookSecret(): Promise<string> {
  const env = (Deno.env.get('PUSH_HOOK_SECRET') || '').trim();
  if (env) return env;
  const v = await secret('PUSH_HOOK_SECRET');
  if (v) return v;
  const { data } = await admin.rpc('app_secret', { p_name: 'PUSH_HOOK_SECRET' });
  return typeof data === 'string' ? data.trim() : '';
}

async function signedJson(raw: string, sig: string | null): Promise<{ body: any } | Response> {
  if (!(await verifyBody(raw, sig, await secret('FLUX_SECRET')))) return json({ ok: false, error: 'Bad signature.' }, 401);
  try { return { body: JSON.parse(raw) }; } catch { return json({ ok: false, error: 'Invalid JSON.' }, 400); }
}
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// ------------------------------------------------------------------ files Flux sends back
const DOC_KINDS = ['acknowledgement', 'filing_evidence', 'assessment', 'prn', 'payment_receipt', 'tax_clearance', 'other'];
const DOC_TYPES: Record<string, string> = {
  'application/pdf': 'pdf', 'image/png': 'png', 'image/jpeg': 'jpg', 'image/webp': 'webp', 'text/csv': 'csv',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': 'xlsx', 'application/vnd.ms-excel': 'xls',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'docx',
};
const ONE_MB = 1024 * 1024, PER_FILE = 15 * ONE_MB, PER_CALL = 40 * ONE_MB;
const startsWith = (b: Uint8Array, sig: number[], at = 0) => sig.every((x, i) => b[at + i] === x);
// The bytes are what the type says: a page of HTML called a PDF is refused.
function looksLike(type: string, b: Uint8Array): boolean {
  switch (DOC_TYPES[type]) {
    case 'pdf': return startsWith(b, [0x25, 0x50, 0x44, 0x46]);
    case 'png': return startsWith(b, [0x89, 0x50, 0x4e, 0x47]);
    case 'jpg': return startsWith(b, [0xff, 0xd8, 0xff]);
    case 'webp': return startsWith(b, [0x52, 0x49, 0x46, 0x46]) && startsWith(b, [0x57, 0x45, 0x42, 0x50], 8);
    case 'xlsx': case 'docx': return startsWith(b, [0x50, 0x4b, 0x03, 0x04]);
    case 'xls': return startsWith(b, [0xd0, 0xcf, 0x11, 0xe0]);
    case 'csv': return !/^\s*</.test(new TextDecoder().decode(b.slice(0, 64)));
    default: return false;
  }
}
const storageSafe = (name: string) => name.normalize('NFKD').replace(/[^\w.\-() ]+/g, '_').replace(/\s+/g, ' ').trim().slice(-120) || 'file';
// Where Flux's links may point: Flux's own address, and any hosts named in FLUX_FILE_HOSTS (comma separated).
async function fileOrigins(): Promise<Set<string>> {
  const out = new Set<string>();
  for (const raw of [await secret('FLUX_URL'), ...(await secret('FLUX_FILE_HOSTS')).split(',')]) {
    const v = raw.trim();
    if (!v) continue;
    try { out.add(new URL(/^https?:\/\//i.test(v) ? v : `https://${v}`).origin); } catch { /* not an address */ }
  }
  return out;
}
async function readCapped(res: Response, cap: number): Promise<Uint8Array> {
  const len = Number(res.headers.get('content-length') || 0);
  if (len > cap) { await res.body?.cancel(); throw new Error(`larger than ${cap / ONE_MB} MB`); }
  const reader = res.body?.getReader();
  if (!reader) return new Uint8Array();
  const parts: Uint8Array[] = []; let n = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    n += value.length;
    if (n > cap) { await reader.cancel(); throw new Error(`larger than ${cap / ONE_MB} MB`); }
    parts.push(value);
  }
  const all = new Uint8Array(n); let at = 0;
  for (const p of parts) { all.set(p, at); at += p.length; }
  return all;
}

type Where = { tax: string; period?: string | null; year?: number | null; prn?: string | null };
async function keepDocuments(org: string, list: unknown, where: Where) {
  const out = { stored: 0, failed: [] as { name: string; why: string }[] };
  if (!Array.isArray(list) || !list.length) return null;
  if (!['vat', 'wht', 'wvat', 'cit'].includes(where.tax)) return { stored: 0, failed: [{ name: 'documents', why: 'Counta could not tell which return they belong to.' }] };
  if (list.length > 10) out.failed.push({ name: `${list.length - 10} more`, why: 'At most 10 files a call.' });
  const origins = await fileOrigins();
  let used = 0;
  for (const d of list.slice(0, 10)) {
    const kind = DOC_KINDS.includes(String(d?.kind)) ? String(d.kind) : 'other';
    let type = String(d?.content_type || '').split(';')[0].trim().toLowerCase();
    let name = String(d?.name || '').replace(/[\\/]+/g, '-').replace(/\s+/g, ' ').trim().slice(0, 160);
    try {
      let bytes: Uint8Array;
      if (typeof d?.content_base64 === 'string' && d.content_base64) {
        const b64 = d.content_base64.replace(/^data:[^,]*,/, '').replace(/\s+/g, '');
        if (b64.length * 0.75 > PER_FILE) throw new Error('larger than 15 MB');
        try { bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0)); } catch { throw new Error('content_base64 is not base64'); }
      } else if (typeof d?.url === 'string' && d.url) {
        let u: URL;
        try { u = new URL(d.url); } catch { throw new Error('the url is not an address'); }
        if (u.protocol !== 'https:' && !origins.has(u.origin)) throw new Error('the url must be https');
        if (!origins.has(u.origin)) throw new Error(`${u.host} is not one of Flux's file hosts`);
        const res = await fetch(u, { redirect: 'manual', signal: AbortSignal.timeout(20_000) });
        if (!res.ok) { await res.body?.cancel(); throw new Error(`the link answered ${res.status}`); }
        if (!type) type = String(res.headers.get('content-type') || '').split(';')[0].trim().toLowerCase();
        bytes = await readCapped(res, PER_FILE);
      } else throw new Error('send url or content_base64');
      if (!bytes.length) throw new Error('the file is empty');
      if (!DOC_TYPES[type]) throw new Error(`${type || 'a file with no type'} is not a type Counta keeps`);
      if (!looksLike(type, bytes)) throw new Error(`the file is not a ${DOC_TYPES[type].toUpperCase()}`);
      if (used + bytes.length > PER_CALL) throw new Error('the files in one call add up to more than 40 MB');
      used += bytes.length;
      if (!name) name = `${kind.replace(/_/g, ' ')}.${DOC_TYPES[type]}`;
      if (!/\.[a-z0-9]{2,5}$/i.test(name)) name += `.${DOC_TYPES[type]}`;
      const folder = where.tax === 'cit' ? String(where.year || 'year') : String(where.period || 'month');
      const path = `${org}/tax/flux/${where.tax}/${folder}/${crypto.randomUUID()}-${storageSafe(name)}`;
      const up = await admin.storage.from('documents').upload(path, bytes, { contentType: type, upsert: false });
      if (up.error) throw new Error(`storage: ${up.error.message}`);
      const { error } = await admin.rpc('svc_document_add', { p: { org_id: org, tax: where.tax, period: where.tax === 'cit' ? null : where.period, year: where.year ?? null,
        prn: where.prn ?? null, kind, name, path, mime: type, size: bytes.length } });
      if (error) { await admin.storage.from('documents').remove([path]); throw new Error(error.message); }
      out.stored++;
    } catch (e) {
      out.failed.push({ name: name || kind, why: (e as Error).message.slice(0, 200) });
    }
  }
  return out;
}

async function fluxReturn(raw: string, sig: string | null) {
  const v = await signedJson(raw, sig);
  if (v instanceof Response) return v;
  const b = v.body;
  const period = String(b.period || '').slice(0, 7);
  if (!UUID.test(String(b.counta_org_id || '')) || !['vat', 'wht', 'wvat'].includes(String(b.tax)) || !/^\d{4}-(0[1-9]|1[0-2])$/.test(period)) {
    return json({ ok: false, error: 'counta_org_id, tax (vat, wht or wvat) and period (YYYY-MM) are required.' }, 400);
  }
  const status = String(b.status || '');
  if (!['processing', 'sent', 'filed', 'rejected'].includes(status)) return json({ ok: false, error: 'status must be processing, sent, filed or rejected.' }, 400);
  const p: Record<string, unknown> = { status };
  for (const k of ['ref', 'message', 'acknowledgement_ref', 'filed_at']) if (b[k] != null && b[k] !== '') p[k] = String(b[k]);
  if (Array.isArray(b.files)) p.files = b.files.slice(0, 20);
  const { data, error } = await admin.rpc('svc_flux_return_update', { p_org: b.counta_org_id, p_tax: b.tax, p_period: `${period}-01`, p_authority: 'NRS', p });
  if (error) return json({ ok: false, error: error.message }, 422);
  const documents = await keepDocuments(b.counta_org_id, b.documents, { tax: b.tax, period, year: Number(period.slice(0, 4)) });
  return json({ ok: true, status: data.status, ...(documents ? { documents } : {}) });
}

// A PRN and the account Rev360's payment page gave. Stored first; then the payments function checks the account with the
// bank and pays it from the tax wallet when everything agrees. If that step does not answer in time, the five-minute
// work does it, so Flux gets its answer quickly either way.
async function fluxPayment(raw: string, sig: string | null) {
  const v = await signedJson(raw, sig);
  if (v instanceof Response) return v;
  const { documents: files, ...instruction } = v.body || {};
  const { data, error } = await admin.rpc('svc_flux_payment_instruction', { p: instruction });
  if (error) return json({ ok: false, error: error.message }, 422);
  const out: Record<string, unknown> = { ok: true, id: data.id, status: data.status, duplicate: data.duplicate };
  const documents = await keepDocuments(String(instruction.counta_org_id), files, instructionWhere(instruction));
  if (documents) out.documents = documents;
  if (data.duplicate || data.status !== 'received') return json(out);
  try {
    const res = await fetch(`${SUPABASE_URL}/functions/v1/payments`, { method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-counta-hook': await hookSecret(), Authorization: `Bearer ${SERVICE}` },
      body: JSON.stringify({ action: 'tax_instruction', instruction_id: data.id }), signal: AbortSignal.timeout(25_000) });
    const r = await res.json().catch(() => ({}));
    if (r?.ok && r.result) Object.assign(out, { status: r.result.status, decision: r.result.decision, reason: r.result.reason ?? undefined });
  } catch (e) { console.log('flux payment check later', data.id, (e as Error).message); }
  return json(out);
}

async function fluxPaymentStatus(raw: string, sig: string | null) {
  const v = await signedJson(raw, sig);
  if (v instanceof Response) return v;
  const { documents: files, ...p } = v.body || {};
  const { data, error } = await admin.rpc('svc_flux_payment_status', { p });
  if (error) return json({ ok: false, error: error.message }, 422);
  let documents = null;
  if (Array.isArray(files) && files.length) {
    const { data: i } = await admin.from('tax_payment_instructions').select('tax, period, accounting_year, prn').eq('id', data.id).maybeSingle();
    if (i) documents = await keepDocuments(String(p.counta_org_id), files, instructionWhere(i));
  }
  return json({ ok: true, status: data.status, ...(documents ? { documents } : {}) });
}
// Where a payment's files go: its tax, and its month (or its year for CIT).
function instructionWhere(i: any): Where {
  const tax = String(i.tax || '');
  const period = String(i.period || '').slice(0, 7);
  const year = Number(i.accounting_year) || Number(period.slice(0, 4)) || null;
  return { tax, period: /^\d{4}-\d{2}$/.test(period) ? period : null, year, prn: i.prn ? String(i.prn) : null };
}

async function flux(raw: string, sig: string | null) {
  if (!(await verifyBody(raw, sig, await secret('FLUX_SECRET')))) return json({ ok: false, error: 'Bad signature.' }, 401);
  let body: any;
  try { body = JSON.parse(raw); } catch { return json({ ok: false, error: 'Invalid JSON.' }, 400); }
  const org = String(body.counta_org_id || ''), year = Number(body.accounting_year);
  if (!/^[0-9a-f-]{36}$/i.test(org) || !Number.isInteger(year)) return json({ ok: false, error: 'counta_org_id and accounting_year are required.' }, 400);
  const status = String(body.status || '');
  if (!['processing', 'sent', 'filed', 'rejected'].includes(status)) return json({ ok: false, error: 'status must be processing, sent, filed or rejected.' }, 400);
  const p: Record<string, unknown> = { flux_status: status };
  if (status !== 'processing') p.status = status;
  for (const k of ['ref', 'message', 'acknowledgement_ref', 'filed_at']) if (body[k] != null && body[k] !== '') p[k] = String(body[k]);
  if (body.rev360_computation && typeof body.rev360_computation === 'object') p.rev360_computation = body.rev360_computation;
  const { data, error } = await admin.rpc('svc_cit_flux_update', { p_org: org, p_year: year, p });
  if (error) return json({ ok: false, error: error.message }, 422);
  const documents = await keepDocuments(org, body.documents, { tax: 'cit', year });
  return json({ ok: true, status: data.status, flux_status: status, ...(documents ? { documents } : {}) });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405);
  const path = new URL(req.url).pathname.replace(/\/$/, '');
  try {
    if (/\/prism\/(bills|bill-status)$/.test(path)) return await prism(path, await req.text(), req.headers.get('x-taxstreem-signature'));
    if (/\/flux\/cit-status$/.test(path)) return await flux(await req.text(), req.headers.get('x-counta-signature'));
    if (/\/flux\/return-status$/.test(path)) return await fluxReturn(await req.text(), req.headers.get('x-counta-signature'));
    if (/\/flux\/payment$/.test(path)) return await fluxPayment(await req.text(), req.headers.get('x-counta-signature'));
    if (/\/flux\/payment-status$/.test(path)) return await fluxPaymentStatus(await req.text(), req.headers.get('x-counta-signature'));
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
