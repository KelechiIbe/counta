// Counta bank feeds through Mono Connect: a business links its bank account once, and the account's transactions flow
// into Banking the way an uploaded statement does (same duplicate checks, same matching to invoices and bills).
//
// Signed-in callers (Authorization: Bearer <user JWT>), POST { action, ... }:
//   config { org_id }                                   -> whether Mono is set up, the public key and the customer for the widget
//   link { org_id, code, bank_account_id? }             -> exchanges the widget's code, links the account, fetches its transactions
//   sync { bank_account_id }                            -> fetches new transactions now (asks the bank for fresh data)
//   reauthorised { bank_account_id }                    -> after the person signed in to their bank again in the widget
//   unlink { bank_account_id }                          -> stops the feed at Mono and in Counta (lines already in stay)
//   cac_config {}                                       -> whether the business lookup is switched on
//   cac_search { query }                                -> businesses on the CAC register by name or RC number (kept on the person's profile)
//   cac_select { cac_id }                               -> one of those: its profile, directors, shareholders, persons with significant
//                                                          control, secretary and its Tax ID from the NRS, written to the profile
//   cac_status_report { org_id }                        -> the owner's latest CAC status report (PDF) into the business's CAC folder
//   nin_check { org_id, nin, conversation_id? }         -> the owner's NIN looked up and compared with the directors; only the outcome
//                                                          and the last four digits are kept
// Mono:
//   POST /mono/webhook                                  -> header mono-webhook-secret must equal MONO_WEBHOOK_SECRET
// Database cron (header x-counta-hook: <PUSH_HOOK_SECRET>):
//   { action: 'sync_all' }                              -> fetches for every linked account, oldest first, for up to ~45 seconds
//
// Nothing a webhook says is taken as a transaction: it only tells Counta to fetch from Mono.
// Secrets (Edge Function secrets): MONO_SECRET_KEY, MONO_PUBLIC_KEY, MONO_WEBHOOK_SECRET. MONO_BASE_URL is for tests.
// The lookups use MONO_LOOKUP_SECRET_KEY when the lookups sit on a different Mono app, otherwise MONO_SECRET_KEY.
// Each paid lookup is counted per person per day in the database (svc_kyc_take), and only the server writes what CAC
// and the NRS return (svc_kyc_store), so nobody can type in a registry record. Directors' dates of birth, ID numbers,
// phone numbers, emails and home addresses are dropped before anything is kept.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const MONO = (Deno.env.get('MONO_BASE_URL') || 'https://api.withmono.com').replace(/\/$/, '');
const admin = createClient(SUPABASE_URL, SERVICE, { auth: { persistSession: false } });

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-counta-hook, mono-webhook-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

class UserError extends Error {}
class ReauthNeeded extends UserError {}

const secrets = new Map<string, { v: string; at: number }>();
// Keys set in the admin portal (Supabase Vault) come first; the Edge Function secrets are the fallback.
async function secret(name: string): Promise<string> {
  // The database's hook secret keeps its old order: the Edge Function secret first.
  if (name === 'PUSH_HOOK_SECRET' && Deno.env.get(name)) return Deno.env.get(name)!.trim();
  const hit = secrets.get(name);
  if (hit && Date.now() - hit.at < 60_000) return hit.v;
  const { data } = await admin.rpc('app_secret', { p_name: name });
  const v = (typeof data === 'string' ? data.trim() : '') || (Deno.env.get(name) || '').trim();
  secrets.set(name, { v, at: Date.now() });
  return v;
}

function sameSecret(a: string, b: string) {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let d = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) d |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return d === 0;
}

async function svc<T = any>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await admin.rpc(fn, args);
  if (error) throw new UserError(error.message);
  return data as T;
}

// ------------------------------------------------------------------ Mono API
type MonoResult = { body: any; headers: Headers };
async function mono(path: string, init: RequestInit = {}): Promise<MonoResult> {
  const key = await secret('MONO_SECRET_KEY');
  if (!key) throw new UserError('Bank feeds are not switched on yet. TaxStreem is setting them up; upload a bank statement for now.');
  const res = await fetch(MONO + path, {
    ...init,
    headers: { 'mono-sec-key': key, accept: 'application/json', 'Content-Type': 'application/json', ...(init.headers || {}) },
    signal: AbortSignal.timeout(40_000),
  });
  const text = await res.text();
  let body: any = text;
  try { body = JSON.parse(text); } catch { /* not json */ }
  if (!res.ok || body?.status === 'failed' || body?.status === 'error') {
    const msg = String((typeof body === 'string' ? body : body?.message || body?.error || JSON.stringify(body)) || res.statusText).slice(0, 300);
    if (/re-?auth|reauthori[sz]ation|mfa|otp|token.*expired|login.*required/i.test(msg) || res.status === 428) throw new ReauthNeeded(`The bank asks for the login again: ${msg}`);
    throw new UserError(`Mono: ${msg}`);
  }
  return { body, headers: res.headers };
}

const kobo = (v: unknown): number | null => {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? Math.round(n) / 100 : null;
};
const ddmmyyyy = (d: Date) => `${String(d.getUTCDate()).padStart(2, '0')}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${d.getUTCFullYear()}`;
const isoDay = (v: unknown) => {
  const s = String(v || '');
  if (/^\d{4}-\d{2}-\d{2}/.test(s)) {
    // Mono gives the time in UTC; the business day is Lagos time (UTC+1).
    const t = Date.parse(s);
    if (!Number.isNaN(t) && s.length > 10) return new Date(t + 3600_000).toISOString().slice(0, 10);
    return s.slice(0, 10);
  }
  const m = s.match(/^(\d{2})-(\d{2})-(\d{4})/);
  return m ? `${m[3]}-${m[2]}-${m[1]}` : null;
};

async function accountDetails(monoId: string) {
  const { body } = await mono(`/v2/accounts/${encodeURIComponent(monoId)}`);
  const d = body?.data || {};
  const a = d.account || d;
  return {
    mono_id: monoId,
    account_number: String(a.account_number || a.accountNumber || ''),
    account_name: a.name || a.account_name || null,
    currency: String(a.currency || 'NGN').toUpperCase(),
    balance: kobo(a.balance),
    institution: { name: a.institution?.name || null, bank_code: a.institution?.bank_code || a.institution?.bankCode || null, type: a.institution?.type || null },
    data_status: d.meta?.data_status || a.meta?.data_status || null,
    auth_method: d.meta?.auth_method || a.meta?.auth_method || null,
  };
}

type FeedLine = { id: string; date: string; amount: number; narration: string; balance: number | null; category: string | null };
function toLine(t: any): FeedLine | null {
  const id = String(t.id || t._id || '');
  const amount = kobo(t.amount);
  const date = isoDay(t.date);
  if (!id || amount === null || !date) return null;
  const out = String(t.type || '').toLowerCase().startsWith('d');
  return { id, date, amount: out ? -Math.abs(amount) : Math.abs(amount), narration: String(t.narration || t.description || '').trim(), balance: kobo(t.balance),
    category: t.category && t.category !== 'unknown' ? String(t.category) : null };
}

// Pages of transactions between two days; Mono pages with meta.next (a full URL) or a page number.
async function transactions(monoId: string, from: Date, to: Date, realtime: boolean): Promise<{ lines: FeedLine[]; fresh: string | null }> {
  const lines: FeedLine[] = [];
  let fresh: string | null = null;
  let page = 1;
  for (let guard = 0; guard < 40; guard++) {
    const q = new URLSearchParams({ start: ddmmyyyy(from), end: ddmmyyyy(to), paginate: 'true', limit: '200', page: String(page) });
    const { body, headers } = await mono(`/v2/accounts/${encodeURIComponent(monoId)}/transactions?${q}`, { headers: realtime && page === 1 ? { 'x-realtime': 'true' } : {} });
    if (page === 1) fresh = headers.get('x-job-status');
    const rows: any[] = Array.isArray(body?.data) ? body.data : Array.isArray(body?.data?.transactions) ? body.data.transactions : [];
    for (const r of rows) { const l = toLine(r); if (l) lines.push(l); }
    const meta = body?.meta || body?.data?.meta || {};
    const next = meta.next || meta.next_page;
    if (!rows.length || !next) break;
    const n = typeof next === 'number' ? next : Number(new URL(String(next), MONO).searchParams.get('page'));
    if (!n || n <= page) break;
    page = n;
  }
  return { lines, fresh };
}

async function balance(monoId: string): Promise<number | null> {
  try {
    const { body } = await mono(`/v2/accounts/${encodeURIComponent(monoId)}/balance`);
    return kobo(body?.data?.balance ?? body?.data?.available_balance);
  } catch (e) {
    if (e instanceof ReauthNeeded) throw e;
    return null;
  }
}

type FeedAccount = { id: string; org_id: string; mono_id: string; last_line_date?: string | null; linked_at?: string | null; books_start?: string | null };
// Fetches from three days before the last line seen (banks post late), or, on the first fetch, from the start of the
// books or 90 days back, whichever is later, and at most a year back.
async function syncAccount(a: FeedAccount, realtime: boolean) {
  const to = new Date();
  const yearBack = new Date(Date.now() - 365 * 86400_000);
  let from: Date;
  if (a.last_line_date) from = new Date(Date.parse(a.last_line_date) - 3 * 86400_000);
  else {
    const ninety = new Date(Date.now() - 90 * 86400_000);
    const books = a.books_start ? new Date(Date.parse(a.books_start)) : null;
    from = books && books > ninety ? books : ninety;
  }
  if (from < yearBack) from = yearBack;
  try {
    const { lines, fresh } = await transactions(a.mono_id, from, to, realtime);
    const bal = await balance(a.mono_id);
    const res = await svc('svc_feed_import', { p_bank_account: a.id, p_lines: lines, p_meta: { balance: bal, data_status: null } });
    return { ...res, fetched: lines.length, fresh_data: fresh };
  } catch (e) {
    if (e instanceof ReauthNeeded) {
      await svc('svc_feed_status', { p_mono_id: a.mono_id, d: { reauth_required: true, data_status: 'REAUTHORISATION_REQUIRED', last_error: (e as Error).message } });
    } else {
      await svc('svc_feed_status', { p_mono_id: a.mono_id, d: { last_error: (e as Error).message, last_error_at: new Date().toISOString() } }).catch(() => null);
    }
    throw e;
  }
}

async function syncAll() {
  const started = Date.now();
  const accounts = await svc<any[]>('svc_feed_accounts', { p_org: null });
  const out = { accounts: accounts.length, synced: 0, added: 0, failed: 0, skipped: 0 };
  for (const a of accounts) {
    if (Date.now() - started > 45_000) break;
    if (a.reauth_required) { out.skipped++; continue; }
    try {
      const r: any = await syncAccount(a, false);
      out.synced++; out.added += Number(r.added || 0);
    } catch { out.failed++; }
  }
  return out;
}

// ------------------------------------------------------------------ CAC and Tax ID lookups
async function lookupKey() {
  return (await secret('MONO_LOOKUP_SECRET_KEY')) || (await secret('MONO_SECRET_KEY'));
}
type LookupResult = { status: number; body: any };
async function lookup(path: string, init: RequestInit = {}): Promise<LookupResult> {
  const key = await lookupKey();
  if (!key) throw new UserError('The CAC lookup is not switched on yet. Type the business details in yourself for now.');
  const res = await fetch(MONO + path, {
    ...init,
    headers: { 'mono-sec-key': key, accept: 'application/json', 'Content-Type': 'application/json', ...(init.headers || {}) },
    signal: AbortSignal.timeout(30_000),
  });
  const text = await res.text();
  let body: any = text;
  try { body = JSON.parse(text); } catch { /* not json */ }
  if (res.status === 404) return { status: 404, body };
  if (!res.ok || body?.status === 'failed' || body?.status === 'error') {
    const msg = String((typeof body === 'string' ? body : body?.message || body?.error || '') || res.statusText).slice(0, 200);
    throw new UserError(`The CAC lookup failed: ${msg || 'no reason given'}.`);
  }
  return { status: res.status, body };
}
const rows = (b: any): any[] => Array.isArray(b?.data) ? b.data : Array.isArray(b?.data?.data) ? b.data.data : Array.isArray(b) ? b : [];

const filled = (v: unknown) => v !== undefined && v !== null && !(typeof v === 'string' && v.trim() === '');
const pick = (o: any, ...keys: string[]) => { for (const k of keys) if (o && filled(o[k])) return o[k]; return null; };
const text = (v: unknown, n = 300): string | null => {
  if (!filled(v)) return null;
  const t = (typeof v === 'object' ? String((v as any).name ?? (v as any).description ?? '') : String(v)).replace(/\s+/g, ' ').trim();
  return t ? t.slice(0, n) : null;
};
const amount = (v: unknown): number | null => {
  if (!filled(v)) return null;
  const n = typeof v === 'number' ? v : Number(String(v).replace(/[^0-9.]/g, ''));
  return Number.isFinite(n) && n > 0 ? n : null;
};
const tidy = (o: Record<string, unknown>) => Object.fromEntries(Object.entries(o).filter(([, v]) => v !== null && v !== undefined));
const digits = (v: unknown) => String(v ?? '').replace(/\D/g, '');

// A director, shareholder, secretary or person with significant control: names, roles, dates and shares only.
function person(p: any) {
  return tidy({
    firstname: text(pick(p, 'firstname', 'first_name'), 60),
    other_name: text(pick(p, 'other_name', 'othername', 'middle_name'), 60),
    surname: text(pick(p, 'surname', 'last_name'), 60),
    corporation_name: text(pick(p, 'corporation_name', 'corporate_name', 'company_name'), 160),
    rc_number: text(pick(p, 'rc_number', 'corporation_rc_number'), 20),
    date_of_appointment: text(pick(p, 'date_of_appointment', 'appointment_date'), 30),
    is_chairman: typeof p?.is_chairman === 'boolean' ? p.is_chairman : null,
    status: text(p?.status, 30),
    role: text(pick(p, 'affiliate_type', 'affiliate_type_fk', 'designation'), 60),
    nationality: text(pick(p, 'nationality'), 40),
    num_shares_alloted: amount(pick(p, 'num_shares_alloted', 'num_shares_allotted', 'number_of_shares', 'shares')),
    type_of_shares: text(p?.type_of_shares, 40),
  });
}
const people = (list: unknown) => (Array.isArray(list) ? list : []).slice(0, 50).map(person).filter((x) => Object.keys(x).length);

function candidate(r: any) {
  return tidy({
    id: pick(r, 'id', 'company_id', 'cac_id'),
    name: text(pick(r, 'approved_name', 'company_name', 'name', 'business_name'), 160),
    rc_number: text(pick(r, 'rc_number', 'rcNumber', 'registration_number'), 20),
    classification: text(r?.classification, 30),
    active: typeof r?.active === 'boolean' ? r.active : null,
    registered_on: text(pick(r, 'registration_date', 'date_of_registration'), 10),
    address: text(pick(r, 'address', 'business_address', 'head_office_address'), 200),
    state: text(r?.state, 40),
    city: text(r?.city, 60),
  });
}

// The company record as CAC holds it: every plain field Mono returns about the business, with the fields Counta uses
// under fixed names, and the people reduced to what Counta shows.
const PERSONAL = /phone|mobile|email|birth|dob|identity|id_number|nin|bvn|passport|residential|home_address|signature|photo|image/i;
function companyProfile(raw: any, c: any, extra: { directors?: unknown; shareholders?: unknown }) {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(raw || {})) {
    if (Array.isArray(v)) continue;
    if (v && typeof v === 'object') { const t = text(v, 200); if (t) out[`${k}_name`] = t; continue; }
    if (filled(v) && !(PERSONAL.test(k) && !/business|company|head_office/i.test(k))) out[k] = typeof v === 'string' ? v.trim().slice(0, 2000) : v;
  }
  const directors = people(Array.isArray(raw?.directors) && raw.directors.length ? raw.directors : extra.directors);
  const shareholders = people(Array.isArray(raw?.shareholders) && raw.shareholders.length ? raw.shareholders : extra.shareholders);
  return tidy({
    ...out,
    approved_name: text(pick(raw, 'approved_name', 'company_name', 'name', 'business_name') ?? c.name, 160),
    rc_number: text(pick(raw, 'rc_number', 'rcNumber', 'registration_number') ?? c.rc_number, 20),
    classification: text(pick(raw, 'classification') ?? c.classification, 30),
    company_type_name: text(pick(raw, 'company_type_name', 'company_type', 'type_of_company'), 80),
    registration_date: text(pick(raw, 'registration_date', 'date_of_registration') ?? c.registered_on, 30),
    business_commencement_date: text(pick(raw, 'business_commencement_date', 'commencement_date', 'date_of_commencement'), 30),
    active: typeof raw?.active === 'boolean' ? raw.active : (c.active ?? null),
    objectives: text(pick(raw, 'objectives', 'business_objectives', 'nature_of_business', 'principal_activity'), 2000),
    nature_of_business_name: text(pick(raw, 'nature_of_business_name', 'nature_of_business', 'business_nature'), 200),
    address: text(pick(raw, 'address', 'registered_address', 'head_office_address') ?? c.address, 300),
    business_address: text(pick(raw, 'business_address'), 300),
    branch_address: text(pick(raw, 'branch_address'), 300),
    head_office_address: text(pick(raw, 'head_office_address'), 300),
    state: text(pick(raw, 'state') ?? c.state, 40),
    city: text(pick(raw, 'city') ?? c.city, 60),
    lga: text(pick(raw, 'lga'), 60),
    email: text(pick(raw, 'email', 'business_email', 'company_email'), 120),
    tax_id: text(pick(raw, 'tax_id', 'tin'), 20),
    share_capital: amount(pick(raw, 'share_capital', 'issued_share_capital', 'paid_up_share_capital', 'authorised_share_capital', 'authorized_share_capital')),
    directors, shareholders,
  });
}

// The director's NIN. Mono looks it up; only the names on the record and the last four digits go on to the database, which
// compares them with the directors on the CAC record. The NIN itself, the photo, date of birth and address stop here.
async function ninCheck(sb: SupabaseClient, user: string, orgId: string, nin: unknown, conversation: unknown) {
  const { data: st, error } = await sb.rpc('identity_state', { p_org: orgId });
  if (error) throw new UserError(error.message);
  if (!st?.can_check) throw new UserError('Only the owner confirms a director\'s identity.');
  const conv = typeof conversation === 'string' && /^[A-Za-z0-9_-]{6,80}$/.test(conversation) ? conversation : null;
  // A conversation in which the NIN was said is deleted from ElevenLabs once the check is done, whatever the outcome.
  if (conv) await svc('svc_forget_add', { p_user: user, p_conversation: conv });
  if (['verified', 'approved', 'not_required'].includes(st.status)) return { verified: true, already: true, matched: st.matched };
  const n = digits(nin);
  if (n.length !== 11) throw new UserError('An NIN has 11 digits. Check it and try again.');
  if (!(await svc<boolean>('svc_kyc_take', { p_user: user, p_kind: 'nin' }))) {
    throw new UserError('That is enough NIN checks for today. Try again tomorrow, or add the NIN slip instead.');
  }
  let r: LookupResult;
  try {
    r = await lookup('/v3/lookup/nin', { method: 'POST', body: JSON.stringify({ nin: n }) });
  } catch (e) {
    const msg = (e as Error).message;
    if (/not switched on/i.test(msg)) throw new UserError('The NIN check is not switched on yet. Add the NIN slip instead.');
    throw new UserError(/not found|invalid|no record|does not exist/i.test(msg) ? 'NIMC has no record of that NIN. Check the 11 digits.'
      : 'The NIN check did not go through just now. Try again in a minute, or add the NIN slip instead.');
  }
  if (r.status === 404) throw new UserError('NIMC has no record of that NIN. Check the 11 digits.');
  const d = r.body?.data && typeof r.body.data === 'object' && !Array.isArray(r.body.data) ? r.body.data : r.body;
  const first = text(pick(d, 'firstname', 'first_name', 'firstName'), 80);
  const middle = text(pick(d, 'middlename', 'middle_name', 'middleName', 'othername', 'other_names'), 80);
  const last = text(pick(d, 'surname', 'lastname', 'last_name', 'lastName'), 80);
  if (!last || (!first && !middle)) throw new UserError('The NIN record came back without a full name. Add the NIN slip instead.');
  return await svc('svc_identity_nin', { p_user: user, p_org: orgId, p_last4: n.slice(-4), p_first: first, p_middle: middle, p_last: last,
    p_conversation: conv });
}

function taxRecord(b: any) {
  const d = b?.data && typeof b.data === 'object' && !Array.isArray(b.data) ? b.data : b;
  const nrs = digits(pick(d, 'nrs_tin', 'tin'));
  return tidy({
    taxpayer_name: text(d?.taxpayer_name, 160),
    nrs_tin: nrs.length === 13 ? nrs : null,
    firstin: text(d?.firstin, 20),
    jittin: text(d?.jittin, 20),
    tax_office: text(d?.tax_office, 120),
    tin_type: text(d?.tin_type, 20)?.toUpperCase() ?? null,
    cac_reg_number: text(d?.cac_reg_number, 20),
    address: text(d?.address, 300),
    at: new Date().toISOString(),
  });
}

async function cacSearch(user: string, query: unknown) {
  const q = String(query ?? '').replace(/\s+/g, ' ').trim();
  if (q.length < 2 || q.length > 100) throw new UserError('Type at least two letters of the business name, or its RC number.');
  if (!(await svc<boolean>('svc_kyc_take', { p_user: user, p_kind: 'search' }))) {
    throw new UserError('That is a lot of searching for one day. Type the business details in yourself, or try again tomorrow.');
  }
  // "RC 1234567", "rc1234567" and "BN 1234567" search by the number.
  const rc = q.match(/^(?:rc|bn|it)?\s*-?\s*(\d{3,9})$/i);
  const { status, body } = await lookup(`/v3/lookup/cac?${new URLSearchParams({ search: rc ? rc[1] : q })}`);
  const found = status === 404 ? [] : rows(body).map(candidate).filter((c) => c.id !== null && c.name);
  // Exact and active matches first, then the rest as CAC returned them.
  const want = q.toLowerCase();
  found.sort((a: any, b: any) => (Number(b.name?.toLowerCase() === want || b.rc_number === rc?.[1]) - Number(a.name?.toLowerCase() === want || a.rc_number === rc?.[1]))
    || (Number(b.active !== false) - Number(a.active !== false)));
  return await svc('svc_kyc_store', { p_user: user, p_part: 'search', p_data: { query: q, candidates: found.slice(0, 10), at: new Date().toISOString() } });
}

async function cacSelect(user: string, draft: any, cacId: unknown) {
  const c = (draft?.search?.candidates || []).find((x: any) => String(x.id) === String(cacId ?? ''));
  if (!c) throw new UserError('Search for the business again and pick it from the list.');
  if (!(await svc<boolean>('svc_kyc_take', { p_user: user, p_kind: 'profile' }))) {
    throw new UserError('That is a lot of company lookups for one day. Type the business details in yourself, or try again tomorrow.');
  }
  const id = encodeURIComponent(String(c.id));
  const soft = (p: Promise<LookupResult>) => p.then((r) => (r.status === 404 ? null : r.body)).catch(() => null);
  const [profile, psc, secretary] = await Promise.all([
    c.rc_number ? soft(lookup(`/v3/lookup/cac/profile/${encodeURIComponent(digits(c.rc_number) || c.rc_number)}`)) : Promise.resolve(null),
    soft(lookup(`/v3/lookup/cac/company/${id}/psc`)),
    soft(lookup(`/v3/lookup/cac/company/${id}/secretary`)),
  ]);
  const raw = profile?.data && !Array.isArray(profile.data) ? profile.data : rows(profile)[0] || null;
  // The directors and shareholders have their own lookups when the profile leaves them out.
  const [directors, shareholders] = await Promise.all([
    raw && Array.isArray(raw.directors) && raw.directors.length ? null : soft(lookup(`/v3/lookup/cac/company/${id}/directors`)),
    raw && Array.isArray(raw.shareholders) && raw.shareholders.length ? null : soft(lookup(`/v3/lookup/cac/company/${id}`)),
  ]);
  const record = {
    cac_id: c.id,
    profile: companyProfile(raw || {}, c, { directors: rows(directors), shareholders: rows(shareholders) }),
    psc: people(rows(psc)),
    secretary: people(rows(secretary)),
    found_profile: Boolean(raw),
    at: new Date().toISOString(),
  };
  let kyc = await svc('svc_kyc_store', { p_user: user, p_part: 'cac', p_data: record });

  // The Tax ID the NRS holds for the RC number. A business name or a company the NRS does not know is not an error here.
  let taxNote: string | null = null;
  const rcDigits = digits(record.profile.rc_number);
  if (rcDigits && await svc<boolean>('svc_kyc_take', { p_user: user, p_kind: 'tin' })) {
    try {
      const { status, body } = await lookup('/v3/lookup/tin', { method: 'POST', body: JSON.stringify({ number: rcDigits, channel: 'cac' }) });
      const t = status === 404 ? null : taxRecord(body);
      if (t && (t.nrs_tin || t.firstin || t.jittin)) kyc = await svc('svc_kyc_store', { p_user: user, p_part: 'tin', p_data: t });
      else taxNote = 'The NRS did not return a Tax ID for this RC number.';
    } catch (e) { taxNote = (e as Error).message; }
  }
  return { kyc, tax_note: taxNote };
}

async function cacStatusReport(user: string, orgId: string, draft: any) {
  const cacId = draft?.business?.cac_id;
  if (!cacId) throw new UserError('This business was not found on CAC through Counta, so upload the status report yourself.');
  if (!(await svc<boolean>('svc_kyc_take', { p_user: user, p_kind: 'status_report' }))) {
    throw new UserError('Counta has fetched the status report a few times today already. Try again tomorrow, or upload it yourself.');
  }
  const key = await lookupKey();
  if (!key) throw new UserError('The CAC lookup is not switched on yet. Upload the status report yourself for now.');
  const res = await fetch(`${MONO}/v3/lookup/cac/company/${encodeURIComponent(String(cacId))}/status-report`, {
    headers: { 'mono-sec-key': key, accept: 'application/pdf' }, signal: AbortSignal.timeout(45_000),
  });
  const bytes = new Uint8Array(await res.arrayBuffer());
  const isPdf = bytes.length > 4 && bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46;
  if (!res.ok || !isPdf) {
    if (res.status === 404) throw new UserError('CAC has no status report for this business yet. Upload the one you have, or the application for registration.');
    throw new UserError('CAC did not send the status report just now. Try again in a few minutes, or upload it yourself.');
  }
  if (bytes.length > 10 * 1024 * 1024) throw new UserError('The status report CAC sent is too large to keep. Upload a copy yourself.');
  const day = new Date(Date.now() + 3600_000).toISOString().slice(0, 10);
  const path = `${orgId}/kyc/cac-status-report-${day}.pdf`;
  const up = await admin.storage.from('documents').upload(path, bytes, { contentType: 'application/pdf', upsert: true });
  if (up.error) throw new UserError('Counta could not save the status report. Try again.');
  return { path, file_name: `CAC status report ${day}.pdf`, bytes: bytes.length };
}

// ------------------------------------------------------------------ webhook
async function webhook(req: Request) {
  const expected = await secret('MONO_WEBHOOK_SECRET');
  const got = req.headers.get('mono-webhook-secret') || '';
  if (!expected || !got || !sameSecret(expected, got)) return json({ ok: false, error: 'Not allowed.' }, 401);
  let b: any;
  try { b = await req.json(); } catch { return json({ ok: false, error: 'Invalid body.' }, 400); }
  const event = String(b.event || '');
  const d = b.data || {};
  const monoId = String(d.account?._id || d.account?.id || d.id || d.account || '');
  if (!monoId || typeof monoId !== 'string') return json({ ok: true, ignored: 'no account' });
  const acc = await svc<FeedAccount | null>('svc_feed_account', { p_mono_id: monoId });
  if (!acc) return json({ ok: true, ignored: 'not linked here' });
  const meta = d.meta || {};
  const status = String(meta.sync_status || meta.data_status || '').toUpperCase();
  if (/reauthori[sz]ation_required/i.test(event) || status === 'REAUTHORISATION_REQUIRED') {
    await svc('svc_feed_status', { p_mono_id: monoId, d: { reauth_required: true, data_status: 'REAUTHORISATION_REQUIRED' } });
    return json({ ok: true, reauth: true });
  }
  if (/unlinked/i.test(event)) {
    await svc('svc_feed_unlink', { p_bank_account: acc.id, p_reason: 'Unlinked at the bank or at Mono' });
    return json({ ok: true, unlinked: true });
  }
  if (/reauthori[sz]ed/i.test(event)) await svc('svc_feed_status', { p_mono_id: monoId, d: { reauth_required: false } });
  const ready = /account_updated|account_connected|reauthori[sz]ed/i.test(event) && (!status || ['AVAILABLE', 'PARTIAL', 'SUCCESSFUL'].includes(status))
    || (/jobs[._]update/i.test(event) && /finished/i.test(String(d.status || meta.status || '')));
  if (!ready) {
    if (status) await svc('svc_feed_status', { p_mono_id: monoId, d: { data_status: status } });
    return json({ ok: true, waiting: status || event });
  }
  try {
    const r = await syncAccount(acc, false);
    return json({ ok: true, synced: r });
  } catch (e) {
    // Mono retries webhooks that fail; a fetch that failed is recorded on the account and picked up by the schedule.
    return json({ ok: true, error: (e as Error).message });
  }
}

// ------------------------------------------------------------------ entry
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405);
  const path = new URL(req.url).pathname;
  try {
    if (/\/webhook\/?$/.test(path)) return await webhook(req);
    let body: any;
    try { body = await req.json(); } catch { return json({ ok: false, error: 'Invalid request.' }, 400); }
    const action = String(body.action || '');

    if (action === 'sync_all') {
      const hook = req.headers.get('x-counta-hook') || '';
      const expected = await secret('PUSH_HOOK_SECRET');
      if (!hook || !expected || !sameSecret(hook, expected)) return json({ ok: false, error: 'Not allowed.' }, 401);
      return json({ ok: true, result: await syncAll() });
    }

    const sb: SupabaseClient = createClient(SUPABASE_URL, ANON, { global: { headers: { Authorization: req.headers.get('Authorization') || '' } }, auth: { persistSession: false } });
    const { data: u } = await sb.auth.getUser();
    if (!u?.user) return json({ ok: false, error: 'Sign in first.' }, 401);
    const mine = async <T = any>(fn: string, args: Record<string, unknown>): Promise<T> => {
      const { data, error } = await sb.rpc(fn, args);
      if (error) throw new UserError(error.message);
      return data as T;
    };

    switch (action) {
      case 'cac_config':
        return json({ ok: true, lookup: Boolean(await lookupKey()) });
      case 'cac_search':
        return json({ ok: true, kyc: await cacSearch(u.user.id, body.query) });
      case 'cac_select': {
        const draft = await mine('kyc_draft', {});
        return json({ ok: true, ...(await cacSelect(u.user.id, draft, body.cac_id)) });
      }
      case 'nin_check': {
        const orgId = String(body.org_id || '');
        if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(orgId)) throw new UserError('Choose the business first.');
        const result = await ninCheck(sb, u.user.id, orgId, body.nin, body.conversation_id);
        return json({ ok: true, result, identity: await mine('identity_state', { p_org: orgId }) });
      }
      case 'cac_status_report': {
        const orgId = String(body.org_id || '');
        if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(orgId)) throw new UserError('Choose the business first.');
        // kyc_draft for a business answers only to its owner.
        const draft = await mine('kyc_draft', { p_org: orgId });
        const doc = await cacStatusReport(u.user.id, orgId, draft);
        const kyc = await mine('kyc_doc', { p_org: orgId, p_path: doc.path, p_kind: 'status_report', p_file_name: doc.file_name });
        return json({ ok: true, kyc, document: doc });
      }
      case 'config': {
        const ctx = await mine('bank_feed_context', { p_org: body.org_id });
        const pub = await secret('MONO_PUBLIC_KEY');
        const sec = await secret('MONO_SECRET_KEY');
        return json({ ok: true, configured: Boolean(pub && sec), public_key: pub || null,
          customer: { name: ctx.org_name, email: ctx.email }, accounts: ctx.accounts, webhook_url: `${SUPABASE_URL}/functions/v1/mono/webhook`,
          webhook_secret_set: Boolean(await secret('MONO_WEBHOOK_SECRET')) });
      }
      case 'link': {
        const ctx = await mine('bank_feed_context', { p_org: body.org_id });
        const code = String(body.code || '');
        if (!code || code.length > 500) throw new UserError('The bank did not finish linking. Try again.');
        const { body: ex } = await mono('/v2/accounts/auth', { method: 'POST', body: JSON.stringify({ code }) });
        const monoId = String(ex?.data?.id || ex?.id || '');
        if (!monoId) throw new UserError('Mono did not return the account. Try linking again.');
        const det = await accountDetails(monoId);
        const linked: any = await svc('svc_feed_link', { p_org: body.org_id, p_member: ctx.member_id, p_bank_account: body.bank_account_id || null, d: det });
        let sync: unknown = null; let syncError: string | null = null;
        try {
          const acc = await svc<FeedAccount>('svc_feed_account', { p_mono_id: monoId });
          sync = await syncAccount({ ...acc, books_start: (await mine('bank_feed_account', { p_bank_account: acc.id })).books_start }, false);
        } catch (e) { syncError = (e as Error).message; }
        return json({ ok: true, account: linked, sync, sync_error: syncError,
          note: det.data_status && det.data_status !== 'AVAILABLE' ? 'The bank is still sending the history to Mono. Counta fetches it as soon as it arrives.' : null });
      }
      case 'sync': {
        const acc = await mine<any>('bank_feed_account', { p_bank_account: body.bank_account_id });
        if (acc.provider !== 'mono' || !acc.mono_id) throw new UserError('That account is not linked to a bank feed.');
        try {
          return json({ ok: true, sync: await syncAccount({ id: acc.id, org_id: acc.org_id, mono_id: acc.mono_id, last_line_date: acc.last_line_date, books_start: acc.books_start }, true) });
        } catch (e) {
          if (e instanceof ReauthNeeded) return json({ ok: false, reason: 'reauth', mono_id: acc.mono_id, error: 'The bank asks you to sign in again before it shares new transactions.' });
          throw e;
        }
      }
      case 'reauthorised': {
        const acc = await mine<any>('bank_feed_account', { p_bank_account: body.bank_account_id });
        if (acc.provider !== 'mono' || !acc.mono_id) throw new UserError('That account is not linked to a bank feed.');
        await svc('svc_feed_status', { p_mono_id: acc.mono_id, d: { reauth_required: false, data_status: 'AVAILABLE' } });
        try {
          return json({ ok: true, sync: await syncAccount({ id: acc.id, org_id: acc.org_id, mono_id: acc.mono_id, last_line_date: acc.last_line_date, books_start: acc.books_start }, false) });
        } catch (e) { return json({ ok: true, sync: null, sync_error: (e as Error).message }); }
      }
      case 'unlink': {
        const acc = await mine<any>('bank_feed_account', { p_bank_account: body.bank_account_id });
        if (acc.provider !== 'mono' || !acc.mono_id) throw new UserError('That account is not linked to a bank feed.');
        let atMono = true;
        try { await mono(`/v2/accounts/${encodeURIComponent(acc.mono_id)}/unlink`, { method: 'POST' }); } catch { atMono = false; }
        const res = await svc('svc_feed_unlink', { p_bank_account: acc.id, p_reason: `Unlinked by ${u.user.email || 'a member'}` });
        return json({ ok: true, account: res, unlinked_at_mono: atMono });
      }
      default: return json({ ok: false, error: 'Unknown action.' }, 400);
    }
  } catch (e) {
    if (e instanceof UserError) return json({ ok: false, error: e.message });
    console.error(e);
    return json({ ok: false, error: 'Something went wrong. Try again.' }, 500);
  }
});
