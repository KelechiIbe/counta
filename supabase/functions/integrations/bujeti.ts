// Bujeti, the business's spend tool, through its public API (developers.bujeti.com, OpenAPI 3.1, version 1.2.1). The key is
// the business's own, with read scopes; Counta never writes to Bujeti and never moves money with it.
// Every answer is {message, status, error, data}; lists carry data.<things> and data.meta {page, perPage, total, hasMore, nextPage}.
// Amounts are in kobo (minor units).
import { getJson, publicUrl, ToolError } from './providers.ts';

export const BUJETI = () => (Deno.env.get('BUJETI_BASE_URL') || 'https://api.bujeti.com/v1').replace(/\/+$/, '');
export const bujetiKeyOk = (k: string) => /^[A-Za-z0-9_\-.:]{20,200}$/.test(k);

export type BPayment = {
  code: string; amount: number; fee: number; currency: string; status: string; narration: string | null; description: string | null; at: string | null;
  category: { code: string; name: string; parent: string | null } | null;
  recipient: { kind: 'vendor' | 'user'; code: string | null; name: string; email: string | null; type: string | null; status: string | null } | null;
  payer: string | null; assets: number;
};

async function call(key: string, path: string, timeout = 25_000): Promise<any> {
  const b = await getJson(`${BUJETI()}${path}`, { headers: { Authorization: `Bearer ${key}`, Accept: 'application/json' } }, timeout);
  if (b && (b.status === false || b.error === true)) throw new ToolError(String(b.message || 'Bujeti said no.').slice(0, 200), 400);
  return b?.data ?? null;
}
const qs = (p: Record<string, string | number | null | undefined>) =>
  Object.entries(p).filter(([, v]) => v != null && v !== '').map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`).join('&');

// One list, page by page: what came back, and the page to ask for next (null when there is no more).
export async function bujetiList(key: string, path: string, prop: string, params: Record<string, string | null> = {}, startPage = 1, maxPages = 5, perPage = 500) {
  const rows: any[] = [];
  let page = startPage, next: number | null = null;
  for (let n = 0; n < maxPages; n++) {
    const d = await call(key, `${path}?${qs({ ...params, page, perPage })}`);
    const got: any[] = Array.isArray(d?.[prop]) ? d[prop] : Array.isArray(d) ? d : [];
    rows.push(...got);
    const meta = d?.meta || {};
    const more = typeof meta.hasMore === 'boolean' ? meta.hasMore : meta.nextPage != null ? true : got.length >= perPage;
    if (!more || !got.length) { next = null; break; }
    page = Number(meta.nextPage) > page ? Number(meta.nextPage) : page + 1;
    next = page;
  }
  return { rows, next };
}

// The key: transactions.read is needed; each other read scope widens what Counta keeps. Answers which ones the key has.
export async function bujetiCheck(key: string) {
  try { await call(key, '/transactions?perPage=1'); }
  catch (e) {
    if (e instanceof ToolError && e.status === 403) {
      throw new ToolError('The key cannot read transactions. In Bujeti, Settings, Developers, give it the transactions.read scope, with the other read scopes.', 422);
    }
    throw e;
  }
  const scopes: Record<string, boolean> = { transactions: true };
  for (const [name, path] of [['balances', '/balances'], ['categories', '/categories'], ['vendors', '/vendors'], ['invoices', '/invoices'], ['assets', '/assets']]) {
    try { await call(key, `${path}?perPage=1`); scopes[name] = true; }
    catch (e) { if (e instanceof ToolError && [401, 403].includes(e.status)) scopes[name] = false; else throw e; }
  }
  return scopes;
}
export const scopeRefused = (e: unknown) => e instanceof ToolError && e.status === 403;

// ------------------------------------------------------------------ reading Bujeti's things the way Counta keeps them
const kobo = (v: unknown) => { const x = Math.abs(Number(v)); return Number.isFinite(x) ? Math.round(x) / 100 : 0; };
// Bujeti gives the fee as a number: whole numbers are kobo like every other amount; one with a fraction can only be naira.
const fee = (v: unknown) => { const x = Math.abs(Number(v)); return !Number.isFinite(x) ? 0 : Number.isInteger(x) ? x / 100 : Math.round(x * 100) / 100; };
const str = (v: unknown, max = 300) => (v == null || v === '' ? null : String(v).slice(0, max));
const person = (u: any) => str(u?.name || [u?.firstName, u?.lastName].filter(Boolean).join(' '), 120);

export function bujetiPayment(t: any): BPayment {
  const r = t?.recipient || null;
  const rcode = str(r?.code, 60);
  const isUser = r && (/^usr_/.test(rcode || '') || (!/^vdr_/.test(rcode || '') && (r.firstName || r.lastName)));
  return {
    code: String(t?.code || ''), amount: kobo(t?.amount), fee: fee(t?.fee), currency: String(t?.currency || 'NGN').toUpperCase(), status: String(t?.status || ''),
    narration: str(t?.narration), description: str(t?.description), at: str(t?.created_at || t?.updated_at, 40),
    category: t?.category?.code ? { code: String(t.category.code), name: String(t.category.name || t.category.code).slice(0, 120), parent: str(t.category.parent?.name, 120) } : null,
    recipient: r ? { kind: isUser ? 'user' : 'vendor', code: rcode, name: person(r) || 'Unnamed', email: str(r.email, 200), type: str(r.type, 40), status: str(r.status, 40) } : null,
    payer: person(t?.payer), assets: Array.isArray(t?.assets) ? t.assets.length : 0,
  };
}
// Categories, each sub-category with its parent's name.
export function bujetiCategories(rows: any[]) {
  const out = new Map<string, { code: string; name: string; parent: string | null }>();
  const walk = (c: any, parent: string | null) => {
    if (!c?.code) return;
    out.set(String(c.code), { code: String(c.code), name: String(c.name || c.code).slice(0, 120), parent: str(c.parent?.name, 120) || parent });
    for (const k of Array.isArray(c.children) ? c.children : []) walk(k, String(c.name || '') || null);
  };
  for (const c of rows) walk(c, null);
  return [...out.values()];
}
export const bujetiVendor = (v: any) => ({ code: String(v?.code || ''), name: String(v?.name || '').slice(0, 120), email: str(v?.email, 200), type: str(v?.type, 40), status: str(v?.status, 40) });
export const bujetiBalance = (b: any) => ({ code: str(b?.code, 60), name: str(b?.name, 120), amount: kobo(b?.amount), currency: String(b?.currency || 'NGN').toUpperCase(),
  type: str(b?.type, 40), purpose: str(b?.purpose, 60), status: str(b?.status, 40) });
export const bujetiInvoice = (v: any) => ({
  code: String(v?.code || ''), number: str(v?.invoiceId, 60), title: str(v?.title, 200), description: str(v?.description, 300), amount: kobo(v?.amount),
  vat_amount: kobo(v?.vatAmount), currency: String(v?.currency || 'NGN').toUpperCase(), status: String(v?.status || ''),
  issued_at: str(v?.sent_at || v?.created_at, 40), due_date: str(v?.due_date, 40), paid_at: str(v?.paidOn, 40),
  customer: v?.customer ? { code: str(v.customer.code, 60), name: str(v.customer.name, 120), email: str(v.customer.email, 200) } : null,
});

export async function bujetiTransaction(key: string, code: string) {
  return await call(key, `/transactions/${encodeURIComponent(code)}`);
}
export async function bujetiAssets(key: string, code: string): Promise<any[]> {
  const d = await call(key, `/transactions/${encodeURIComponent(code)}/assets`);
  return Array.isArray(d?.assets) ? d.assets : Array.isArray(d) ? d : [];
}

// A receipt's file, from the short-lived address Bujeti signs: a public https address only, followed through at most two
// redirects, a PDF or a picture of at most 10 MB.
export async function bujetiFile(url: string): Promise<{ bytes: Uint8Array; type: string } | null> {
  let u = publicUrl(url);
  for (let hop = 0; hop < 3; hop++) {
    let res: Response;
    try { res = await fetch(u, { redirect: 'manual', signal: AbortSignal.timeout(20_000) }); }
    catch { throw new ToolError('Counta could not fetch a receipt from Bujeti.'); }
    if (res.status >= 300 && res.status < 400 && res.headers.get('location')) { await res.body?.cancel(); u = publicUrl(new URL(res.headers.get('location')!, u).toString()); continue; }
    if (!res.ok) { await res.body?.cancel(); throw new ToolError(`A receipt could not be fetched (${res.status}).`, res.status); }
    const type = (res.headers.get('content-type') || 'application/octet-stream').split(';')[0].trim().toLowerCase();
    if (!/^(application\/pdf|image\/(png|jpe?g|webp|heic|heif|gif))$/.test(type)) { await res.body?.cancel(); return null; }
    if (Number(res.headers.get('content-length') || 0) > 10_000_000) { await res.body?.cancel(); return null; }
    const bytes = new Uint8Array(await res.arrayBuffer());
    if (bytes.length > 10_000_000 || !bytes.length) return null;
    return { bytes, type };
  }
  return null;
}
export const fileName = (name: string | null | undefined, type: string) => {
  const base = String(name || 'receipt').replace(/\.[A-Za-z0-9]{1,5}$/, '').replace(/[^A-Za-z0-9_-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60) || 'receipt';
  const ext = type === 'application/pdf' ? 'pdf' : type.split('/')[1].replace('jpeg', 'jpg');
  return `${base}.${ext}`;
};
