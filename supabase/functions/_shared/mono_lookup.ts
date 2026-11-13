// Mono's NIN and CAC lookups as the identity checks use them (a director confirming wallets in the practice function, a
// director recovering a business and an intake's NIN in the mono function).
//
// Only what the database compares is passed on: the names NIMC holds for a NIN and the phone number it holds (the code goes
// there), the NIN's last four digits, and for each person on the CAC record their names and the email and phone CAC holds.
// The NIN itself, its photo, date of birth and address stop here, and nothing is logged. The phone on a NIN record is not
// verified by NIMC, so the database sends the code to the CAC email as well.

export type LookupAnswer = { status: number; body: unknown; secs: number };
export type Lookup = (path: string, init?: RequestInit) => Promise<LookupAnswer>;

// A lookup Mono did not answer properly: its HTTP status (null when it did not answer), its message and the time it took.
export class LookupError extends Error {
  constructor(msg: string, readonly status: number | null, readonly reason: string, readonly secs: number) { super(msg); }
}

const since = (t0: number) => Math.round((Date.now() - t0) / 100) / 10;
const reasonOf = (body: unknown, fallback: string) =>
  String((typeof body === 'string' ? body.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim()
    : (body as any)?.message || (body as any)?.error || '') || fallback).slice(0, 200);

// The lookup over HTTP, for a function with no lookup of its own: the key in the mono-sec-key header, 30 seconds at most.
// A 404 comes back as an answer (no record); any other failure throws LookupError.
export function lookupWith(call: typeof fetch, base: string, key: string): Lookup {
  return async (path, init = {}) => {
    const t0 = Date.now();
    let res: Response;
    try {
      res = await call(base.replace(/\/$/, '') + path, {
        ...init,
        headers: { 'mono-sec-key': key, accept: 'application/json', 'Content-Type': 'application/json', ...(init.headers || {}) },
        signal: AbortSignal.timeout(30_000),
      });
    } catch (e) {
      const why = (e as Error).name === 'TimeoutError' ? 'No answer within 30 seconds' : `No answer (${(e as Error).name})`;
      throw new LookupError(`The lookup failed: ${why.toLowerCase()}.`, null, why, since(t0));
    }
    const text = await res.text();
    let body: unknown = text;
    try { body = JSON.parse(text); } catch { /* not json */ }
    const secs = since(t0);
    if (res.status === 404) return { status: 404, body, secs };
    if (!res.ok || (body as any)?.status === 'failed' || (body as any)?.status === 'error') {
      const msg = reasonOf(body, res.statusText);
      throw new LookupError(`The lookup failed: ${msg || 'no reason given'}.`, res.status, msg || 'no reason given', secs);
    }
    return { status: res.status, body, secs };
  };
}

const filled = (v: unknown) => v !== undefined && v !== null && !(typeof v === 'string' && v.trim() === '');
const pick = (o: any, ...keys: string[]) => { for (const k of keys) if (o && filled(o[k])) return o[k]; return null; };
const text = (v: unknown, n: number): string | null => {
  if (!filled(v) || typeof v === 'object') return null;
  const t = String(v).replace(/\s+/g, ' ').trim();
  return t ? t.slice(0, n) : null;
};
const rows = (b: any): any[] => Array.isArray(b?.data) ? b.data : Array.isArray(b?.data?.data) ? b.data.data : Array.isArray(b) ? b : [];
const record = (b: any) => (b?.data && typeof b.data === 'object' && !Array.isArray(b.data) ? b.data : b);

// A Nigerian mobile number as the database takes it (0XXXXXXXXXX), or null.
export function localPhone(v: unknown): string | null {
  let d = String(v ?? '').replace(/\D/g, '');
  if (d.startsWith('234') && d.length === 13) d = '0' + d.slice(3);
  else if (d.length === 10 && /^[789]/.test(d)) d = '0' + d;
  return /^0[789][01]\d{8}$/.test(d) ? d : null;
}

export type NinPerson = { first: string | null; middle: string | null; last: string | null; phone: string | null };

// The names and phone on a NIN record, from Mono's answer.
export function ninPerson(body: unknown): NinPerson {
  const d = record(body);
  return {
    first: text(pick(d, 'firstname', 'first_name', 'firstName'), 80),
    middle: text(pick(d, 'middlename', 'middle_name', 'middleName', 'othername', 'other_names'), 80),
    last: text(pick(d, 'surname', 'lastname', 'last_name', 'lastName'), 80),
    phone: localPhone(pick(d, 'telephoneno', 'telephone_no', 'telephoneNo', 'phone', 'phone_number', 'phoneNumber', 'mobile', 'telephone')),
  };
}

export type NinResult = { found: false } | ({ found: true } & NinPerson);

// The NIN looked up: found (with the names and the phone) or not on NIMC's register. LookupError when Mono did not answer.
export async function ninLookup(lookup: Lookup, nin: string): Promise<NinResult> {
  const r = await lookup('/v3/lookup/nin', { method: 'POST', body: JSON.stringify({ nin }) });
  if (r.status === 404) return { found: false };
  const p = ninPerson(r.body);
  if (!p.last || (!p.first && !p.middle)) return { found: false };
  return { found: true, ...p };
}

// An NIN typed in: its 11 digits, or null.
export const ninDigits = (v: unknown): string | null => {
  const d = String(v ?? '').replace(/\D/g, '');
  return d.length === 11 ? d : null;
};

export type Contact = { surname: string; given: string; email: string | null; phone: string | null };

// A person on the CAC record as the database matches them: surname and given names in capitals, and their email and
// phone as CAC holds them (or null). People without a surname or given name are left out.
export function contact(p: any): Contact | null {
  const surname = text(pick(p, 'surname', 'last_name', 'lastname'), 80);
  const given = [pick(p, 'firstname', 'first_name'), pick(p, 'other_name', 'othername', 'middle_name')]
    .map((x) => text(x, 80)).filter(Boolean).join(' ');
  if (!surname || !given) return null;
  const email = text(pick(p, 'email', 'email_address', 'emailAddress'), 254);
  return {
    surname: surname.toUpperCase(), given: given.toUpperCase(),
    email: email && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) ? email.toLowerCase() : null,
    phone: localPhone(pick(p, 'phone_number', 'phoneNumber', 'phone', 'mobile', 'telephone')),
  };
}

// The contacts of the people on the company's CAC record: its directors, and for anything but a company (a business
// name's proprietors) its shareholders and people with significant control too. A lookup that fails gives no contacts
// for that list: the database then routes the code as it can, or to TaxStreem.
export async function cacContacts(lookup: Lookup, cacId: string, classification: string | null): Promise<Contact[]> {
  const id = encodeURIComponent(cacId);
  const soft = (path: string) => lookup(path).then((r) => (r.status === 404 ? [] : rows(r.body))).catch(() => [] as any[]);
  const company = /^COMPANY/i.test(classification || 'COMPANY');
  const lists = await Promise.all([
    soft(`/v3/lookup/cac/company/${id}/directors`),
    ...(company ? [] : [soft(`/v3/lookup/cac/company/${id}`), soft(`/v3/lookup/cac/company/${id}/psc`)]),
  ]);
  const out: Contact[] = [];
  const seen = new Set<string>();
  for (const p of lists.flat().slice(0, 100)) {
    const c = contact(p);
    if (!c) continue;
    const key = `${c.surname}|${c.given}|${c.email}|${c.phone}`;
    if (!seen.has(key)) { seen.add(key); out.push(c); }
  }
  return out;
}
