// The NRS Merchant Buyer Solution (MBS) API, version 1.1: einvoice.nrs.gov.ng and the "E-Invoice Collection" on Postman.
// Every call goes to <base>/api/v1/... with x-api-key and x-api-secret headers; the code lists under
// /api/v1/invoice/resources/* need no keys. Answers come as JSON when Accept says so.

export type NrsKeys = { base: string; key: string; secret: string };
export type NrsAnswer = { status: number; ok: boolean; ms: number; body: any; text: string };

// The base address as it was pasted, cut back to the host: the paths below add /api/v1.
export const nrsBase = (raw: string) => String(raw || '').trim().replace(/\/+(api(\/v1)?\/?)?$/, '').replace(/\/+$/, '');

export async function nrsCall(k: Pick<NrsKeys, 'base'> & Partial<NrsKeys>, path: string, init: { method?: string; body?: unknown; auth?: boolean; timeoutMs?: number } = {}): Promise<NrsAnswer> {
  const t0 = Date.now();
  const headers: Record<string, string> = { Accept: 'application/json' };
  if (init.body !== undefined) headers['Content-Type'] = 'application/json';
  if (init.auth !== false && k.key && k.secret) { headers['x-api-key'] = k.key; headers['x-api-secret'] = k.secret; }
  try {
    const res = await fetch(`${nrsBase(k.base)}${path}`, { method: init.method || 'GET', headers, body: init.body === undefined ? undefined : JSON.stringify(init.body),
      signal: AbortSignal.timeout(init.timeoutMs || 20_000) });
    const text = await res.text();
    let body: any = text;
    try { body = JSON.parse(text); } catch { /* not JSON */ }
    return { status: res.status, ok: res.ok, ms: Date.now() - t0, body, text };
  } catch (e) {
    const timedOut = (e as Error).name === 'TimeoutError';
    return { status: 0, ok: false, ms: Date.now() - t0, body: { message: timedOut ? 'no answer in time' : (e as Error).message }, text: '' };
  }
}

const short = (v: unknown, n = 300) => String(v ?? '').replace(/\s+/g, ' ').trim().slice(0, n);
// NRS's own words for a refusal, wherever in the answer they are.
// The sandbox puts its general words in message ("error has occurred") and the reason in error.public_message.
export function nrsWhy(r: NrsAnswer): string {
  const b = r.body;
  const words = (x: unknown) => (typeof x === 'string' && x.trim() ? x : '');
  const e = b && typeof b === 'object' ? b.error : null;
  const pick = b && typeof b === 'object'
    ? words(e?.public_message) || words(e?.message) || words(e?.details) || words(e) || words(b.detail) || words(b.data?.message)
      || (Array.isArray(b.errors) ? b.errors.map((x: any) => x?.message || x).join('; ') : '') || words(b.message)
    : b;
  return short(pick || (r.status ? `HTTP ${r.status}` : 'no answer'));
}

// Numbers of five or more digits keep their last four; email addresses go. Used on everything kept from an answer.
export const mask = (s: string) => String(s ?? '').replace(/[A-Z0-9._%+-]+@[A-Z0-9-]+(\.[A-Z0-9-]+)+/gi, '[email]')
  .replace(/\d{5,}/g, (d) => '•••' + d.slice(-4));

// The shape of an answer, for working out the mapping: every key, with short masked samples of the values.
export function shape(v: unknown, depth = 0): unknown {
  if (v === null || v === undefined) return v ?? null;
  if (Array.isArray(v)) return depth > 4 ? `[${v.length}]` : { length: v.length, first: v.slice(0, 2).map((x) => shape(x, depth + 1)) };
  if (typeof v === 'object') {
    if (depth > 4) return '{…}';
    const out: Record<string, unknown> = {};
    for (const [k, x] of Object.entries(v as Record<string, unknown>).slice(0, 60)) out[k] = shape(x, depth + 1);
    return out;
  }
  if (typeof v === 'string') return mask(v).slice(0, 120);
  return v;
}

// The first list in an answer: the answer itself, or under data, items, results and the like.
export function firstList(b: unknown, depth = 0): unknown[] | null {
  if (Array.isArray(b)) return b;
  if (!b || typeof b !== 'object' || depth > 3) return null;
  for (const k of ['data', 'items', 'results', 'result', 'records', 'content', 'list']) {
    const x = (b as Record<string, unknown>)[k];
    const l = firstList(x, depth + 1);
    if (l) return l;
  }
  for (const x of Object.values(b as Record<string, unknown>)) {
    const l = firstList(x, depth + 1);
    if (l) return l;
  }
  return null;
}

// The VAT exemption list keys its entries by harmonized_system_code, with the item's own name in tariff.
const CODE_KEYS = ['code', 'hs_code', 'hsn_code', 'hscode', 'harmonized_system_code', 'service_code', 'isic_code', 'isic', 'alpha_2', 'alpha2', 'iso_code', 'iso', 'id', 'value', 'key'];
const LABEL_KEYS = ['tariff', 'description', 'name', 'label', 'title', 'value', 'category', 'country_name', 'currency_name'];
// One entry of a code list as Counta keeps it: its code, its words, and everything NRS sent with it.
export function codeRow(x: unknown): { code: string; label: string | null; extra: Record<string, unknown> } | null {
  if (typeof x === 'string' || typeof x === 'number') return { code: String(x).trim(), label: null, extra: {} };
  if (!x || typeof x !== 'object') return null;
  const o = x as Record<string, unknown>;
  const lower = Object.fromEntries(Object.entries(o).map(([k, v]) => [k.toLowerCase(), v]));
  const ck = CODE_KEYS.find((k) => ['string', 'number'].includes(typeof lower[k]) && String(lower[k]).trim());
  if (!ck) return null;
  const code = String(lower[ck]).trim();
  const lk = LABEL_KEYS.find((k) => k !== ck && typeof lower[k] === 'string' && String(lower[k]).trim());
  return { code, label: lk ? String(lower[lk]).trim() : null, extra: o };
}

export const RESOURCE_LISTS = ['countries', 'currencies', 'tax-categories', 'payment-means', 'invoice-types', 'services-codes', 'vat-exemptions', 'hs-codes'] as const;
// Not in the Postman collection, but the invoice schema asks for state and LGA codes; asked for in case NRS serves them.
export const MAYBE_LISTS = ['states', 'lgas'] as const;

// crypto_keys.txt from the dashboard: { public_key: <PEM, base64-encoded>, certificate }.
export function readCryptoKeys(raw: string): { pem: string; certificate: string } | { problem: string } {
  let j: any;
  try { j = JSON.parse(String(raw || '').trim()); } catch { return { problem: 'NRS_CRYPTO_KEYS is not the JSON in crypto_keys.txt.' }; }
  if (!j?.public_key || !j?.certificate) return { problem: 'NRS_CRYPTO_KEYS has no public_key or no certificate.' };
  let pem = String(j.public_key).trim();
  if (!pem.includes('BEGIN')) {
    try { pem = new TextDecoder().decode(Uint8Array.from(atob(pem.replace(/\s+/g, '')), (c) => c.charCodeAt(0))); }
    catch { return { problem: 'The public_key in crypto_keys.txt is not base64.' }; }
  }
  if (!/-----BEGIN (RSA )?PUBLIC KEY-----/.test(pem)) return { problem: 'The public_key in crypto_keys.txt is not a PEM public key.' };
  return { pem, certificate: String(j.certificate).trim() };
}

// Every string value under keys whose name matches, anywhere in an answer (an entity's businesses and their Service IDs).
export function valuesUnder(v: unknown, key: RegExp, depth = 0, out: string[] = []): string[] {
  if (!v || typeof v !== 'object' || depth > 6) return out;
  for (const [k, x] of Object.entries(v as Record<string, unknown>)) {
    if (key.test(k) && (typeof x === 'string' || typeof x === 'number') && String(x).trim()) out.push(String(x).trim());
    else if (x && typeof x === 'object') valuesUnder(x, key, depth + 1, out);
  }
  return out;
}

// Whether a value (an ID) appears anywhere in an answer, ignoring case.
export function holds(v: unknown, want: string, depth = 0): boolean {
  if (typeof v === 'string' || typeof v === 'number') return String(v).trim().toLowerCase() === want.toLowerCase();
  if (!v || typeof v !== 'object' || depth > 6) return false;
  return Object.values(v as Record<string, unknown>).some((x) => holds(x, want, depth + 1));
}

// An entity's registered name, under whichever key NRS uses.
export const entityName = (e: any) => String(e?.name || e?.business_name || e?.registered_name || e?.entity_name || e?.legal_name || e?.company_name || '').trim();
