// The practice function's flows against an in-memory stand-in for Supabase (database calls, storage, tables) and a mocked
// Mono: no network, no real email, nothing stored anywhere.
import { assert, assertEquals, assertMatch, assertRejects } from 'jsr:@std/assert@1';
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { PDFDocument } from 'npm:pdf-lib@1.17.1';
import { unzipSync, zlibSync } from 'npm:fflate@0.8.3';
import { type Deps, handle } from './actions.ts';
import { buildExport } from './export.ts';
import { pngDrawable, renderLetterPdf } from './pdf.ts';
import { pngFromDataUrl, sha256Hex } from './util.ts';
import bodyJson from '../_shared/default_letter.json' with { type: 'json' };

const PID = '11111111-1111-4111-8111-111111111111', LID = '22222222-2222-4222-8222-222222222222', SID = '33333333-3333-4333-8333-333333333333';
const ORG = '44444444-4444-4444-8444-444444444444', CLIENT = '55555555-5555-4555-8555-555555555555', USER = '66666666-6666-4666-8666-666666666666';
const ES = 'es_' + 'ab'.repeat(24), DC = 'dc_' + 'cd'.repeat(24);
const PNG_URL = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

type Row = Record<string, any>;
class Query {
  filters: [string, unknown][] = [];
  patch: Row | null = null;
  constructor(private f: Fake, private table: string) {}
  select(_cols: string) { return this; }
  update(p: Row) { this.patch = p; return this; }
  eq(c: string, v: unknown) { this.filters.push([c, v]); return this; }
  private rows() { return (this.f.tables[this.table] || []).filter((r) => this.filters.every(([c, v]) => r[c] === v)); }
  maybeSingle() { return Promise.resolve({ data: this.rows()[0] ?? null, error: null }); }
  then<A, B>(ok: (v: { data: Row[] | null; error: null }) => A, ko?: (e: unknown) => B) {
    if (this.patch) for (const r of this.rows()) Object.assign(r, this.patch);
    return Promise.resolve({ data: this.patch ? null : this.rows(), error: null }).then(ok, ko);
  }
}
class Fake {
  rpcs: Record<string, (a: Row) => unknown> = {};
  calls: { fn: string; args: Row }[] = [];
  files = new Map<string, Uint8Array>();
  uploads: { path: string; upsert: unknown; contentType: unknown }[] = [];
  removed: string[] = [];
  listed: string[] = [];
  sizes = new Map<string, unknown>(); // a listed size other than the file's own
  tables: Record<string, Row[]> = {};
  user: { id: string; email?: string } | null = { id: USER, email: 'partner@firm.example.test' };
  // A handler that throws is the SQL raising (P0001 unless the error carries another code; code '' is a lost answer, as
  // supabase-js reports a failed fetch).
  rpc = async (fn: string, args: Row) => {
    this.calls.push({ fn, args });
    const h = this.rpcs[fn];
    if (!h) return { data: null, error: { message: `Could not find the function public.${fn}`, code: 'PGRST202' } };
    try {
      return { data: await h(args), error: null };
    } catch (e) {
      return { data: null, error: { message: (e as Error).message, code: (e as { code?: string }).code ?? 'P0001' } };
    }
  };
  auth = { getUser: async () => ({ data: { user: this.user }, error: null }) };
  from = (table: string) => new Query(this, table);
  storage = {
    from: (_bucket: string) => ({
      upload: async (path: string, bytes: Uint8Array, o: { upsert?: boolean; contentType?: string }) => {
        this.uploads.push({ path, upsert: o?.upsert, contentType: o?.contentType });
        if (this.files.has(path) && !o?.upsert) return { data: null, error: { message: 'The resource already exists', statusCode: '409' } };
        this.files.set(path, bytes);
        return { data: { path }, error: null };
      },
      download: async (path: string) => this.files.has(path) ? { data: new Blob([this.files.get(path)!.slice()]), error: null } : { data: null, error: { message: 'Object not found' } },
      remove: async (paths: string[]) => { for (const p of paths) { this.files.delete(p); this.removed.push(p); } return { data: [], error: null }; },
      createSignedUrl: async (path: string, s: number) => ({ data: { signedUrl: `https://files.example.test/${path}?expires=${s}` }, error: null }),
      list: async (prefix: string) => {
        this.listed.push(prefix);
        const seen = new Map<string, Row>();
        for (const [p, b] of this.files) {
          if (!p.startsWith(prefix + '/')) continue;
          const rest = p.slice(prefix.length + 1).split('/');
          if (!seen.has(rest[0])) {
            seen.set(rest[0], rest.length > 1 ? { name: rest[0], id: null, metadata: null }
              : { name: rest[0], id: p, metadata: { size: this.sizes.has(p) ? this.sizes.get(p) : b.length } });
          }
        }
        return { data: [...seen.values()], error: null };
      },
    }),
  };
}

const deps = (admin: Fake, user: Fake, extra: Partial<Deps> = {}): Deps => ({
  admin: admin as unknown as SupabaseClient, asUser: () => user as unknown as SupabaseClient, secret: async () => 'mono-test-key',
  monoUrl: 'https://mono.example.test', fetch: () => { throw new Error('no network in tests'); }, ...extra,
});
const post = (body: Row, headers: Record<string, string> = {}) => new Request('https://fn.example.test/practice', { method: 'POST',
  headers: { 'Content-Type': 'application/json', 'x-forwarded-for': '203.0.113.9, 10.0.0.1', 'user-agent': 'TestBrowser/1.0', ...headers }, body: JSON.stringify(body) });
const call = async (d: Deps, body: Row) => { const r = await handle(post(body), d); return { status: r.status, body: await r.json(), headers: r.headers }; };

// A letter as the firm signed it, stored where the database says it is.
async function signedLetter(admin: Fake) {
  const doc = await renderLetterPdf([{ id: 'p', kind: 'paragraph', level: 1, number: null, ref: null, text: 'We act for Ọlá Àdé Foods Ltd.' }],
    { title: 'Letter of engagement', firmName: 'Ṣọlá & Co', partnerName: 'Ṣọlá Ìyá', partnerTitle: 'Partner', partnerSignature: 'Ṣọlá Ìyá' });
  const docPath = `practice/${PID}/letters/${LID}/letter.pdf`;
  admin.files.set(docPath, doc);
  const letter = { letter_id: LID, signer_id: SID, practice_id: PID, doc_path: docPath, doc_sha256: await sha256Hex(doc), title: 'Letter of engagement',
    partner_name: 'Ṣọlá Ìyá', partner_signature: 'Ṣọlá Ìyá', partner_email: 'sola@firm.example.test', partner_signed_at: '2026-11-12T09:30:00+00:00',
    partner_ip: '198.51.100.7', partner_ua: 'PartnerBrowser/2.0', signer_name: 'Ada Obi', signer_email: 'ada@client.example.test', signer_title: 'Director',
    code_verified_at: '2026-11-13T10:00:00+00:00', white_label: true };
  admin.tables.practices = [{ id: PID, name: 'Ṣọlá & Co' }];
  return { doc, docPath, letter };
}

Deno.test('public_actions_check_the_token_first', async () => {
  const admin = new Fake();
  const d = deps(admin, new Fake());
  for (const body of [{ action: 'sign_open', token: 'es_123' }, { action: 'sign_code', token: DC }, { action: 'sign_submit', token: DC, code: '123456' },
    { action: 'director_open', token: ES }, { action: 'director_confirm', token: 'dc_' + 'A'.repeat(48), code: '123456' }, { action: 'director_decline', token: '' }]) {
    const r = await call(d, body);
    assertEquals([r.body.ok, r.body.reason], [false, 'invalid'], body.action);
  }
  assertEquals(admin.calls.length, 0);
  const r = await call(d, { action: 'sign_open', token: ES });
  assertEquals(r.headers.get('referrer-policy'), 'no-referrer');
  for (const action of ['constructor', 'toString', '__proto__']) assertEquals((await call(d, { action })).status, 400, action);
});

Deno.test('sign_open_gives_a_five_minute_link', async () => {
  const admin = new Fake();
  admin.rpcs.svc_sign_open = () => ({ ok: true, letter_id: LID, title: 'Letter', firm_name: 'Ṣọlá & Co', signer_name: 'Ada Obi', status: 'sent', white_label: true,
    doc_path: `practice/${PID}/letters/${LID}/letter.pdf` });
  const r = await call(deps(admin, new Fake()), { action: 'sign_open', token: ES });
  assertEquals(r.body.ok, true);
  assertMatch(r.body.doc_url, /letter\.pdf\?expires=300$/);
  assert(!('doc_path' in r.body), 'the storage path stays on the server');
  assertEquals(admin.calls[0].args, { p_token: ES, p_ip: '203.0.113.9', p_ua: 'TestBrowser/1.0' });
});

Deno.test('sign_submit_checks_what_was_sent_before_using_the_code', async () => {
  const admin = new Fake();
  const d = deps(admin, new Fake());
  const bad = await call(d, { action: 'sign_submit', token: ES, code: '123456', typed_name: 'Ada Obi', signature_png: 'data:image/jpeg;base64,AAAA' });
  assertEquals(bad.body.ok, false);
  const noName = await call(d, { action: 'sign_submit', token: ES, code: '123456', typed_name: ' A ', signature_png: PNG_URL });
  assertEquals(noName.body.ok, false);
  const noCode = await call(d, { action: 'sign_submit', token: ES, code: 'abc', typed_name: 'Ada Obi', signature_png: PNG_URL });
  assertEquals(noCode.body.reason, 'wrong_code');
  assertEquals(admin.calls.length, 0);
});

Deno.test('sign_submit_refuses_a_changed_letter', async () => {
  const admin = new Fake();
  const { docPath, letter } = await signedLetter(admin);
  const changed = new TextEncoder().encode('%PDF-1.7 something else');
  admin.files.set(docPath, changed);
  admin.rpcs.svc_sign_verify = () => ({ ok: true, letter });
  admin.rpcs.svc_letter_changed = () => ({ ok: true });
  const r = await call(deps(admin, new Fake()), { action: 'sign_submit', token: ES, code: '123 456', typed_name: 'Ada Obi', signature_png: PNG_URL });
  assertEquals(r.body, { ok: false, reason: 'changed', error: 'The letter has changed since it was signed by the firm.' });
  assertEquals(admin.uploads.length, 0);
  assert(!admin.calls.some((c) => c.fn === 'svc_sign_complete'));
  // Recorded on the letter, with the fingerprint found and the signer's address.
  const rec = admin.calls.find((c) => c.fn === 'svc_letter_changed');
  assertEquals(rec?.args.p_letter, letter.letter_id);
  assertEquals(rec?.args.p_found, await sha256Hex(changed));
  assert('p_ip' in (rec?.args || {}) && 'p_ua' in (rec?.args || {}));
});

Deno.test('sign_submit_refuses_a_changed_letter_when_recording_fails', async () => {
  const admin = new Fake();
  const { docPath, letter } = await signedLetter(admin);
  admin.files.set(docPath, new TextEncoder().encode('%PDF-1.7 something else'));
  admin.rpcs.svc_sign_verify = () => ({ ok: true, letter });
  admin.rpcs.svc_letter_changed = () => { throw new Error('connection reset'); };
  const r = await call(deps(admin, new Fake()), { action: 'sign_submit', token: ES, code: '123 456', typed_name: 'Ada Obi', signature_png: PNG_URL });
  assertEquals(r.body, { ok: false, reason: 'changed', error: 'The letter has changed since it was signed by the firm.' });
});

Deno.test('sign_submit_completes_with_certificate', async () => {
  const admin = new Fake();
  const { doc, letter } = await signedLetter(admin);
  admin.rpcs.svc_sign_verify = (a) => (a.p_code === '123 456' ? { ok: true, letter } : { ok: false, reason: 'wrong_code', tries_left: 4 });
  admin.rpcs.svc_sign_complete = () => ({ ok: true, letter_id: LID, status: 'completed' });
  const r = await call(deps(admin, new Fake()), { action: 'sign_submit', token: ES, code: '123 456', typed_name: '  Ada   Obi ', signature_png: PNG_URL });
  assertEquals(r.body.ok, true);
  // Nothing of the partner (IP, browser, email) goes back to the signer beyond the certificate itself.
  assertEquals(Object.keys(r.body).sort(), ['doc_url', 'ok', 'status']);
  const dir = `practice/${PID}/letters/${LID}`;
  assertEquals(admin.uploads.map((u) => [u.path, u.upsert]), [[`${dir}/signature-${SID}.png`, false], [`${dir}/final.pdf`, false]]);
  const final = admin.files.get(`${dir}/final.pdf`)!;
  assertEquals((await PDFDocument.load(final)).getPageCount(), (await PDFDocument.load(doc)).getPageCount() + 2);
  const done = admin.calls.find((c) => c.fn === 'svc_sign_complete')!;
  assertEquals(done.args, { p_token: ES, p: { signature_path: `${dir}/signature-${SID}.png`, final_path: `${dir}/final.pdf`, final_sha256: await sha256Hex(final),
    typed_name: 'Ada Obi', ip: '203.0.113.9', ua: 'TestBrowser/1.0' } });
  assertEquals(admin.calls.map((c) => c.fn), ['svc_sign_verify', 'svc_sign_complete']);
});

Deno.test('sign_submit_removes_its_files_when_not_completed', async () => {
  const admin = new Fake();
  const { letter } = await signedLetter(admin);
  admin.rpcs.svc_sign_verify = () => ({ ok: true, letter });
  admin.rpcs.svc_sign_complete = () => ({ ok: false, reason: 'not_verified' });
  const r = await call(deps(admin, new Fake()), { action: 'sign_submit', token: ES, code: '123456', typed_name: 'Ada Obi', signature_png: PNG_URL });
  assertEquals(r.body.reason, 'not_verified');
  assertEquals(admin.removed.length, 2);
  assert(![...admin.files.keys()].some((p) => /final\.pdf|signature-/.test(p)));
});

Deno.test('letter_freeze_renders_stores_once_and_freezes', async () => {
  const admin = new Fake(), user = new Fake();
  user.rpcs.practice_letter_prepare = () => ({ letter_id: LID, practice_id: PID, source: 'template', doc_path: null, title: 'Letter of engagement: Ọlá Àdé Foods Ltd',
    variant: 'full', blocks: bodyJson, merge: { 'client.name': 'Ọlá Àdé Foods Ltd', 'fees.amount': 250000, 'service.bookkeeping': true },
    firm: { name: 'Ṣọlá & Co' }, partner: { id: USER, name: 'Ṣọlá Ìyá', email: 'sola@firm.example.test', title: 'Partner' }, fingerprint: 'f'.repeat(64) });
  admin.rpcs.svc_letter_frozen = (a) => ({ id: LID, status: 'partner_signed', doc_sha256: a.p.doc_sha256 });
  const r = await call(deps(admin, user), { action: 'letter_freeze', letter_id: LID, signature_name: 'Ṣọlá Ìyá' });
  assertEquals(r.body.ok, true);
  const path = `practice/${PID}/letters/${LID}/letter.pdf`;
  assertEquals(admin.uploads.map((u) => [u.path, u.upsert, u.contentType]), [[path, false, 'application/pdf']]);
  const frozen = admin.calls.find((c) => c.fn === 'svc_letter_frozen')!;
  assertEquals(frozen.args.p, { doc_path: path, doc_sha256: await sha256Hex(admin.files.get(path)!), by_user: USER, signature_name: 'Ṣọlá Ìyá',
    ip: '203.0.113.9', ua: 'TestBrowser/1.0', fingerprint: 'f'.repeat(64) });
  assertEquals(user.calls.map((c) => c.fn), ['practice_letter_prepare']);
});

Deno.test('letter_freeze_removes_the_file_when_refused', async () => {
  const admin = new Fake(), user = new Fake();
  user.rpcs.practice_letter_prepare = () => ({ letter_id: LID, practice_id: PID, source: 'template', title: 'Letter', variant: 'involved', blocks: bodyJson, merge: {},
    firm: { name: 'Ṣọlá & Co' }, partner: { name: 'Ṣọlá Ìyá', title: 'Partner' } });
  admin.rpcs.svc_letter_frozen = () => { throw new Error('Only a partner of the practice signs its letters.'); };
  const r = await call(deps(admin, user), { action: 'letter_freeze', letter_id: LID });
  assertEquals(r.body, { ok: false, error: 'Only a partner of the practice signs its letters.' });
  assertEquals(admin.files.size, 0);
  // No fingerprint in the answer: none is passed on (the database refuses the letter as changed), and the file goes.
  assertEquals(admin.calls.find((c) => c.fn === 'svc_letter_frozen')!.args.p.fingerprint, null);
  admin.rpcs.svc_letter_frozen = () => { throw new Error('The letter changed while it was being signed. Sign it again.'); };
  const changed = await call(deps(admin, user), { action: 'letter_freeze', letter_id: LID });
  assertEquals(changed.body, { ok: false, error: 'The letter changed while it was being signed. Sign it again.' });
  assertEquals(admin.files.size, 0);
  user.user = null;
  assertEquals((await call(deps(admin, user), { action: 'letter_freeze', letter_id: LID })).status, 401);
});

Deno.test('end_mandate_unlinks_feeds_at_mono', async () => {
  const admin = new Fake(), user = new Fake();
  user.rpcs.practice_end_mandate = () => ({ client_id: CLIENT, org_id: ORG, read_only_at: '2026-11-13T10:00:00Z', retain_until: '2032-11-13' });
  admin.tables.bank_accounts = [
    { id: 'b1', org_id: ORG, provider: 'manual', provider_meta: { unlinked_reason: 'engagement ended', former_feed: 'mono_acc_1' } },
    { id: 'b2', org_id: ORG, provider: 'manual', provider_meta: { unlinked_reason: 'Unlinked by a member', former_feed: 'mono_acc_2' } },
    { id: 'b3', org_id: 'another-org', provider: 'manual', provider_meta: { unlinked_reason: 'engagement ended', former_feed: 'mono_acc_3' } },
  ];
  const seen: { url: string; key: string | null }[] = [];
  const fakeFetch = (async (url: string | URL | Request, init?: RequestInit) => {
    seen.push({ url: String(url), key: new Headers(init?.headers).get('mono-sec-key') });
    return new Response(JSON.stringify({ status: 'successful', message: 'Account unlinked' }), { status: 200 });
  }) as typeof fetch;
  const r = await call(deps(admin, user, { fetch: fakeFetch }), { action: 'end_mandate', client_id: CLIENT, reason: 'Client moved firms' });
  assertEquals(r.body.ok, true);
  assertEquals(r.body.feeds, { unlinked: 1, failed: 0 });
  assertEquals(seen, [{ url: 'https://mono.example.test/v2/accounts/mono_acc_1/unlink', key: 'mono-test-key' }]);
  assert(admin.tables.bank_accounts[0].provider_meta.mono_unlinked_at);
  assertEquals(user.calls[0].args, { p_client: CLIENT, p: { reason: 'Client moved firms' } });
  // Done once: asking again calls Mono no more.
  user.rpcs.practice_export_begin = () => ({ org_id: ORG, client_id: CLIENT, practice_id: PID, tables: [] });
  const again = await call(deps(admin, user, { fetch: fakeFetch }), { action: 'unlink_feeds', client_id: CLIENT });
  assertEquals([again.body.feeds, seen.length], [{ unlinked: 0, failed: 0 }, 1]);
});

Deno.test('export_pages_tables_and_skips_kyc', async () => {
  const admin = new Fake();
  const rows: Record<string, Row[][]> = { orgs: [[{ id: ORG, name: 'Ọlá Àdé Foods Ltd' }]], sales: [[{ id: 1 }, { id: 2 }], [{ id: 3 }]] };
  admin.rpcs.svc_export_rows = (a) => {
    const pages = rows[a.p_table];
    const i = a.p_after === null ? 0 : Number(JSON.parse(a.p_after)[0]);
    return { rows: pages[i], next: i + 1 < pages.length ? JSON.stringify([i + 1]) : null };
  };
  admin.rpcs.svc_export_ledger = () => ({ rows: [{ date: '2026-01-31', journal_ref: 'JE-1', account_code: '4000', account_name: 'Sales, local', debit: 0, credit: 100, memo: '=SUM(A1)' }], next: null });
  admin.rpcs.svc_export_activity = () => ({ rows: [{ id: 1, action: 'insert' }], next: null });
  admin.rpcs.svc_export_done = () => ({ ok: true });
  const enc = new TextEncoder();
  admin.files.set(`${ORG}/documents/receipt.pdf`, enc.encode('%PDF-receipt'));
  admin.files.set(`${ORG}/kyc/nin-slip-1.pdf`, enc.encode('%PDF-nin'));
  admin.files.set(`${ORG}/kyc/cac/cac.pdf`, enc.encode('%PDF-cac'));
  admin.files.set(`99999999-9999-4999-8999-999999999999/documents/x.pdf`, enc.encode('%PDF-other'));
  const out = await buildExport(admin as unknown as SupabaseClient, { org_id: ORG, client_id: CLIENT, practice_id: PID, tables: ['orgs', 'sales'] },
    new Date('2026-11-13T09:05:07Z'));
  assertEquals(out.path, `practice/${PID}/exports/${CLIENT}/20261113-100507.zip`);
  const zip = unzipSync(admin.files.get(out.path)!);
  assertEquals(Object.keys(zip).sort(), ['activity_log.json', `files/${ORG}/documents/receipt.pdf`, 'ledger.csv', 'tables/orgs.json', 'tables/sales.json']);
  assertEquals(JSON.parse(new TextDecoder().decode(zip['tables/sales.json'])).length, 3);
  assertEquals(new TextDecoder().decode(zip['ledger.csv']).split('\r\n')[1], `2026-01-31,JE-1,4000,"Sales, local",0,100,'=SUM(A1)`);
  assert(!admin.listed.some((p) => p.includes('/kyc')));
  assertEquals(admin.uploads.map((u) => u.upsert), [false]);
  assertEquals(admin.calls.find((c) => c.fn === 'svc_export_done')!.args, { p_client: CLIENT, p: { path: out.path, sha256: out.sha256, bytes: out.bytes } });
});

// ------------------------------------------------------------------ review fixes
const raise = (message: string, code: string) => Object.assign(new Error(message), { code });
const LOST = () => { throw raise(`TypeError: fetch failed (${ES})`, ''); }; // the answer never came back
const GENERIC = { ok: false, error: 'Something went wrong. Try again.' };
// console.error collected (and kept quiet) while f runs.
async function quietly<T>(f: () => Promise<T>): Promise<{ value: T; logged: string }> {
  const orig = console.error;
  let logged = '';
  console.error = (...a: unknown[]) => { logged += a.map(String).join(' ') + '\n'; };
  try { return { value: await f(), logged }; } finally { console.error = orig; }
}
function crc32(b: Uint8Array): number {
  let c = ~0;
  for (const x of b) { c ^= x; for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1)); }
  return ~c >>> 0;
}
// A PNG with the given header size (8-bit RGBA) and image data.
function png(width: number, height: number, idat: Uint8Array): Uint8Array {
  const chunk = (type: string, data: Uint8Array) => {
    const out = new Uint8Array(12 + data.length), v = new DataView(out.buffer);
    v.setUint32(0, data.length);
    out.set(new TextEncoder().encode(type), 4);
    out.set(data, 8);
    v.setUint32(8 + data.length, crc32(out.subarray(4, 8 + data.length)));
    return out;
  };
  const ihdr = new Uint8Array(13), hv = new DataView(ihdr.buffer);
  hv.setUint32(0, width); hv.setUint32(4, height); ihdr[8] = 8; ihdr[9] = 6;
  const parts = [new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', idat), chunk('IEND', new Uint8Array(0))];
  const out = new Uint8Array(parts.reduce((s, p) => s + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}
const dataUrl = (b: Uint8Array) => 'data:image/png;base64,' + btoa(Array.from(b, (x) => String.fromCharCode(x)).join(''));

Deno.test('signature_png_limits', async () => {
  assert(pngFromDataUrl(dataUrl(png(2000, 1000, zlibSync(new Uint8Array(10))))), '2000 x 1000 is accepted');
  assertEquals(pngFromDataUrl(dataUrl(png(5000, 5000, zlibSync(new Uint8Array(10))))), null);
  assertEquals(pngFromDataUrl(dataUrl(png(2001, 10, zlibSync(new Uint8Array(10))))), null);
  assertEquals(pngFromDataUrl(dataUrl(png(10, 1001, zlibSync(new Uint8Array(10))))), null);
  assert(await pngDrawable(pngFromDataUrl(PNG_URL)!));
  // A 1 x 1 image whose few kilobytes of data inflate to 5 MB: past its header's size, refused before it is decoded.
  const bomb = png(1, 1, zlibSync(new Uint8Array(5_000_000)));
  assert(pngFromDataUrl(dataUrl(bomb)), 'the header alone looks fine');
  assertEquals(await pngDrawable(bomb), false);
  const admin = new Fake();
  const r = await call(deps(admin, new Fake()), { action: 'sign_submit', token: ES, code: '123456', typed_name: 'Ada Obi', signature_png: dataUrl(bomb) });
  assertEquals(r.body.ok, false);
  assertEquals(admin.calls.length, 0, 'no code used');
});

Deno.test('sign_submit_keeps_files_when_the_answer_is_lost', async () => {
  const dir = `practice/${PID}/letters/${LID}`;
  const admin = new Fake();
  const { letter } = await signedLetter(admin);
  admin.rpcs.svc_sign_verify = () => ({ ok: true, letter });
  admin.rpcs.svc_sign_complete = LOST; // the letter may be completed on the files just stored
  const { value: r, logged } = await quietly(() => call(deps(admin, new Fake()), { action: 'sign_submit', token: ES, code: '123456', typed_name: 'Ada Obi', signature_png: PNG_URL }));
  assertEquals([r.status, r.body], [500, GENERIC]);
  assert(admin.files.has(`${dir}/final.pdf`) && admin.files.has(`${dir}/signature-${SID}.png`));
  assertEquals(admin.removed, []);
  assert(!logged.includes(ES) && logged.includes('[token]'), 'the token is not logged');
  // Refused for certain by the database (a SQLSTATE that is not for the person): the files go, and the text is not shown.
  const again = new Fake();
  const second = await signedLetter(again);
  again.rpcs.svc_sign_verify = () => ({ ok: true, letter: second.letter });
  again.rpcs.svc_sign_complete = () => { throw raise('new row for relation "engagement_letters" violates check constraint', '23514'); };
  const { value: r2 } = await quietly(() => call(deps(again, new Fake()), { action: 'sign_submit', token: ES, code: '123456', typed_name: 'Ada Obi', signature_png: PNG_URL }));
  assertEquals([r2.status, r2.body], [500, GENERIC]);
  assertEquals(again.removed.length, 2);
});

Deno.test('letter_freeze_keeps_the_file_when_the_answer_is_lost', async () => {
  const admin = new Fake(), user = new Fake();
  user.rpcs.practice_letter_prepare = () => ({ letter_id: LID, practice_id: PID, source: 'template', title: 'Letter', variant: 'involved', blocks: bodyJson, merge: {},
    firm: { name: 'Ṣọlá & Co' }, partner: { name: 'Ṣọlá Ìyá', title: 'Partner' } });
  admin.rpcs.svc_letter_frozen = LOST;
  const { value: r } = await quietly(() => call(deps(admin, user), { action: 'letter_freeze', letter_id: LID }));
  assertEquals([r.status, r.body], [500, GENERIC]);
  assert(admin.files.has(`practice/${PID}/letters/${LID}/letter.pdf`));
  assertEquals(admin.removed, []);
});

Deno.test('database_and_network_errors_are_not_shown', async () => {
  const admin = new Fake(), user = new Fake();
  admin.rpcs.svc_sign_open = LOST;
  const { value: lost, logged } = await quietly(() => call(deps(admin, user), { action: 'sign_open', token: ES }));
  assertEquals([lost.status, lost.body], [500, GENERIC]);
  assert(!logged.includes(ES));
  admin.rpcs.svc_director_open = () => { throw raise('permission denied for function svc_director_open', '42501'); };
  assertEquals((await quietly(() => call(deps(admin, user), { action: 'director_open', token: DC }))).value.body, GENERIC);
  user.rpcs.practice_export_begin = () => { throw raise('function private.export_tables() does not exist', '42883'); };
  assertEquals((await quietly(() => call(deps(admin, user), { action: 'export', client_id: CLIENT }))).value.body, GENERIC);
  // The SQL's own refusals are for the person.
  user.rpcs.practice_export_begin = () => { throw raise('Only a partner exports a client\'s records.', '42501'); };
  assertEquals((await call(deps(admin, user), { action: 'export', client_id: CLIENT })).body, { ok: false, error: 'Only a partner exports a client\'s records.' });
  user.rpcs.practice_export_begin = () => { throw new Error('Client not found.'); };
  assertEquals((await call(deps(admin, user), { action: 'export', client_id: CLIENT })).body, { ok: false, error: 'Client not found.' });
});

Deno.test('a_spent_code_asks_for_a_new_one', async () => {
  const admin = new Fake();
  const d = deps(admin, new Fake());
  const sign = { action: 'sign_submit', token: ES, code: '123456', typed_name: 'Ada Obi', signature_png: PNG_URL };
  admin.rpcs.svc_sign_verify = () => ({ ok: false, reason: 'expired', tries_left: 0, locked: false }); // the code's
  const spent = await call(d, sign);
  assertEquals([spent.body.reason, spent.body.error], ['code_expired', 'That code has expired or has been used already. Ask for a new code.']);
  admin.rpcs.svc_sign_verify = () => ({ ok: false, reason: 'expired', tries_left: 0 }); // the link's
  assertEquals((await call(d, sign)).body.reason, 'expired');
  admin.rpcs.svc_director_confirm = () => ({ ok: false, reason: 'expired', tries_left: 0, locked: false });
  assertEquals((await call(d, { action: 'director_confirm', token: DC, code: '123456' })).body.reason, 'code_expired');
});

Deno.test('director_actions_pass_ip_and_browser', async () => {
  const admin = new Fake();
  admin.rpcs.svc_director_open = () => ({ ok: true, firm_name: 'Ṣọlá & Co', business_name: 'Ada Foods Ltd', director_name: 'Ada Obi', status: 'pending' });
  admin.rpcs.svc_director_code = () => ({ ok: true, sends_left: 4 });
  admin.rpcs.svc_director_confirm = () => ({ ok: true, status: 'confirmed' });
  admin.rpcs.svc_director_decline = () => ({ ok: true, status: 'declined' });
  const d = deps(admin, new Fake());
  for (const body of [{ action: 'director_open', token: DC }, { action: 'director_code', token: DC }, { action: 'director_confirm', token: DC, code: '654 321' },
    { action: 'director_decline', token: DC, reason: '  Not   agreed ' }]) {
    assertEquals((await call(d, body)).body.ok, true, body.action);
  }
  const who = { p_token: DC, p_ip: '203.0.113.9', p_ua: 'TestBrowser/1.0' };
  assertEquals(admin.calls.map((c) => [c.fn, c.args]), [['svc_director_open', who], ['svc_director_code', who],
    ['svc_director_confirm', { ...who, p_code: '654 321' }], ['svc_director_decline', { ...who, p_reason: 'Not agreed' }]]);
});

Deno.test('mono_already_unlinked_counts_and_other_writes_stay', async () => {
  const admin = new Fake();
  admin.tables.bank_accounts = [
    { id: 'b1', org_id: ORG, provider: 'manual', provider_meta: { unlinked_reason: 'engagement ended', former_feed: 'mono_gone' } },
    { id: 'b2', org_id: ORG, provider: 'manual', provider_meta: { unlinked_reason: 'engagement ended', former_feed: 'mono_down' } },
  ];
  const fakeFetch = (async (url: string | URL | Request) => {
    // Meanwhile another writer changes the account's details.
    for (const r of admin.tables.bank_accounts) r.provider_meta = { ...r.provider_meta, note: 'kept' };
    return String(url).includes('mono_gone')
      ? new Response(JSON.stringify({ status: 'failed', message: 'Account not found' }), { status: 404 })
      : String(url).includes('mono_lost')
      ? new Response('<html><body>404 Not Found</body></html>', { status: 404 })
      : new Response('upstream error', { status: 502 });
  }) as typeof fetch;
  const { value: r } = await quietly(() => call(deps(admin, new Fake(), { fetch: fakeFetch }), { action: 'unlink_feeds', client_id: CLIENT }));
  assertEquals(r.body.ok, false); // no practice_export_begin given: refused before Mono
  const user = new Fake();
  user.rpcs.practice_export_begin = () => ({ org_id: ORG, client_id: CLIENT, practice_id: PID, tables: [] });
  const ok = await call(deps(admin, user, { fetch: fakeFetch }), { action: 'unlink_feeds', client_id: CLIENT });
  assertEquals(ok.body.feeds, { unlinked: 1, failed: 1 });
  const [b1, b2] = admin.tables.bank_accounts.map((x) => x.provider_meta);
  assert(b1.mono_unlinked_at && b1.note === 'kept' && b1.former_feed === 'mono_gone');
  assert(!b2.mono_unlinked_at && b2.mono_unlink_error === 'Mono: upstream error' && b2.mono_unlink_tried_at && b2.note === 'kept');
  // A 404 that is not Mono's own answer (a page from something in between) is a failure, not an account gone.
  admin.tables.bank_accounts.push({ id: 'b3', org_id: ORG, provider: 'manual', provider_meta: { unlinked_reason: 'engagement ended', former_feed: 'mono_lost' } });
  const lost = await call(deps(admin, user, { fetch: fakeFetch }), { action: 'unlink_feeds', client_id: CLIENT });
  const b3 = admin.tables.bank_accounts[2].provider_meta;
  assertEquals(lost.body.feeds.failed >= 1, true);
  assert(!b3.mono_unlinked_at && String(b3.mono_unlink_error).startsWith('Mono: <html>'));
});

Deno.test('export_limits_and_formula_guard', async () => {
  const setup = () => {
    const admin = new Fake();
    admin.rpcs.svc_export_rows = () => ({ rows: [{ id: ORG, name: 'Ada Foods Ltd', note: 'x'.repeat(300) }], next: null });
    admin.rpcs.svc_export_ledger = () => ({ rows: [{ date: '2026-01-31', journal_ref: 'JE-2', account_code: '1000', account_name: 'Bank', debit: -5, credit: 0, memo: '-refund' }], next: null });
    admin.rpcs.svc_export_activity = () => ({ rows: [], next: null });
    admin.rpcs.svc_export_done = () => ({ ok: true });
    admin.files.set(`${ORG}/documents/a.pdf`, new Uint8Array(1000));
    return admin;
  };
  const b = { org_id: ORG, client_id: CLIENT, practice_id: PID, tables: ['orgs'] };
  // The file alone fits 1,100 bytes; with the records it does not: the records count.
  await assertRejects(() => buildExport(setup() as unknown as SupabaseClient, b, new Date(), 1100), Error, 'Ask TaxStreem for a full copy.');
  // A table too large is refused while its pages come in, before the next page is asked for.
  const big = setup();
  let pages = 0;
  big.rpcs.svc_export_rows = () => { pages++; return { rows: [{ note: 'y'.repeat(600) }], next: `p${pages}` }; };
  await assertRejects(() => buildExport(big as unknown as SupabaseClient, b, new Date(), 2000), Error, 'Ask TaxStreem for a full copy.');
  assertEquals(pages, 4);
  // A file whose size is not listed is refused.
  const unknown = setup();
  unknown.sizes.set(`${ORG}/documents/a.pdf`, undefined);
  await assertRejects(() => buildExport(unknown as unknown as SupabaseClient, b, new Date(), 1 << 20), Error, 'could not be read');
  assertEquals(unknown.calls.some((c) => c.fn === 'svc_export_done'), false);
  // A text cell starting with - is guarded; an amount (a number) is not.
  const admin = setup();
  const out = await buildExport(admin as unknown as SupabaseClient, b, new Date(), 1 << 20);
  assertEquals(new TextDecoder().decode(unzipSync(admin.files.get(out.path)!)['ledger.csv']).split('\r\n')[1], `2026-01-31,JE-2,1000,Bank,-5,0,'-refund`);
});

Deno.test('export_keeps_the_file_when_the_log_answer_is_lost', async () => {
  const admin = new Fake();
  admin.rpcs.svc_export_rows = () => ({ rows: [], next: null });
  admin.rpcs.svc_export_ledger = () => ({ rows: [], next: null });
  admin.rpcs.svc_export_activity = () => ({ rows: [], next: null });
  admin.rpcs.svc_export_done = LOST;
  const b = { org_id: ORG, client_id: CLIENT, practice_id: PID, tables: ['orgs'] };
  await quietly(() => assertRejects(() => buildExport(admin as unknown as SupabaseClient, b)));
  assertEquals([admin.uploads.length, admin.removed.length], [1, 0]);
  // Refused for certain: removed, so no export outside the activity log is left for the partners to read.
  admin.rpcs.svc_export_done = () => { throw new Error('That is not an export path for this client.'); };
  await assertRejects(() => buildExport(admin as unknown as SupabaseClient, b, new Date(Date.now() + 5000)), Error, 'not an export path');
  assertEquals(admin.removed.length, 1);
});

// Mono's NIN and CAC answers, by path; each call recorded (the NIN's body too, to show where it went and nowhere else).
function monoFake(answers: Record<string, { status: number; body: unknown }>) {
  const asked: { path: string; key: string | null; body: string | null }[] = [];
  const f = (async (url: string | URL | Request, init?: RequestInit) => {
    const path = String(url).replace('https://mono.example.test', '');
    asked.push({ path, key: new Headers(init?.headers).get('mono-sec-key'), body: typeof init?.body === 'string' ? init.body : null });
    const a = answers[path] ?? { status: 404, body: { message: 'Not found' } };
    return new Response(JSON.stringify(a.body), { status: a.status, headers: { 'Content-Type': 'application/json' } });
  }) as typeof fetch;
  return { f, asked };
}
const NIN_OK = { status: 200, body: { status: 'successful', data: { firstname: 'ADA', middlename: 'GRACE', surname: 'OBI', telephoneno: '08031234567',
  birthdate: '01-01-1980', photo: 'base64…', residence_address: '1 Home Street', nin: '12345678901' } } };
const DIRECTORS = { status: 200, body: { data: [
  { firstname: 'ADA', other_name: 'GRACE', surname: 'OBI', email: 'Ada.Obi@Director.example.test', phone_number: '+234 803 999 8888', identity_number: 'A123' },
  { firstname: 'TUNDE', surname: 'BELLO', email: 'not an email', phone_number: '12' }] } };

Deno.test('director_nin_looks_up_matches_and_keeps_nothing_else', async () => {
  const admin = new Fake();
  admin.rpcs.svc_director_nin_begin = () => ({ ok: true, cac_id: '7701', classification: 'COMPANY', tries_left: 2 });
  admin.rpcs.svc_director_identity = () => ({ ok: true, step: 'code', route: 'code', sms: '+234 803 *** **67', email: 'a***@d***.test', matched: 'Ada Grace Obi' });
  const m = monoFake({ '/v3/lookup/nin': NIN_OK, '/v3/lookup/cac/company/7701/directors': DIRECTORS });
  const d = deps(admin, new Fake(), { fetch: m.f });
  const r = await call(d, { action: 'director_nin', token: DC, nin: '123 4567 8901' });
  assertEquals(r.body, { ok: true, step: 'code', route: 'code', sms: '+234 803 *** **67', email: 'a***@d***.test', matched: 'Ada Grace Obi' });
  assertEquals(m.asked.map((a) => a.path), ['/v3/lookup/nin', '/v3/lookup/cac/company/7701/directors']);
  assertEquals(m.asked[0].body, JSON.stringify({ nin: '12345678901' }));
  assert(m.asked.every((a) => a.key === 'mono-test-key'));
  const ident = admin.calls.find((c) => c.fn === 'svc_director_identity')!.args;
  assertEquals(ident, { p_token: DC, p_ip: '203.0.113.9', p_ua: 'TestBrowser/1.0', p: { first: 'ADA', middle: 'GRACE', last: 'OBI', last4: '8901',
    nin_phone: '08031234567', cac: [{ surname: 'OBI', given: 'ADA GRACE', email: 'ada.obi@director.example.test', phone: '08039998888' },
      { surname: 'BELLO', given: 'TUNDE', email: null, phone: null }] } });
  // The NIN itself, the photo, birth date and address go nowhere.
  const sent = JSON.stringify(admin.calls);
  assert(!sent.includes('12345678901') && !sent.includes('base64') && !sent.includes('1980') && !sent.includes('Home Street'));
});

Deno.test('director_nin_refusals', async () => {
  const admin = new Fake();
  const m = monoFake({});
  const d = deps(admin, new Fake(), { fetch: m.f });
  assertEquals((await call(d, { action: 'director_nin', token: DC, nin: '1234' })).body.reason, 'nin_shape');
  assertEquals((await call(d, { action: 'director_nin', token: ES, nin: '12345678901' })).body.reason, 'invalid');
  // No lookup key: the database is not asked, so no try is used.
  const off = await call(deps(admin, new Fake(), { secret: async () => '' }), { action: 'director_nin', token: DC, nin: '12345678901' });
  assertEquals(off.body.reason, 'lookup_off');
  assertEquals(admin.calls.length, 0);
  // Three a day: Mono is not asked.
  admin.rpcs.svc_director_nin_begin = () => ({ ok: false, reason: 'too_many_nin' });
  const many = await call(d, { action: 'director_nin', token: DC, nin: '12345678901' });
  assertEquals([many.body.reason, many.body.error], ['too_many_nin', 'That is three NIN checks today. Try again tomorrow.']);
  assertEquals(m.asked.length, 0);
  // Not on NIMC's register: the CAC record is not read.
  admin.rpcs.svc_director_nin_begin = () => ({ ok: true, cac_id: '7701', classification: 'COMPANY', tries_left: 1 });
  assertEquals((await call(d, { action: 'director_nin', token: DC, nin: '12345678901' })).body.reason, 'nin_not_found');
  assertEquals(m.asked.map((a) => a.path), ['/v3/lookup/nin']);
  // Mono failing: noted for TaxStreem (last four digits at most), and the director told to try again.
  const down = monoFake({ '/v3/lookup/nin': { status: 503, body: { message: 'Provider timed out for 12345678901' } } });
  admin.rpcs.svc_lookup_failure = () => null;
  const r = await call(deps(admin, new Fake(), { fetch: down.f }), { action: 'director_nin', token: DC, nin: '12345678901' });
  assertEquals(r.body.reason, 'nin_failed');
  const noted = admin.calls.find((c) => c.fn === 'svc_lookup_failure')!.args.p;
  assertEquals([noted.kind, noted.outcome, noted.http_status], ['nin', 'failed', 503]);
  assert(!JSON.stringify(noted).includes('12345678901') && JSON.stringify(noted).includes('8901'));
  // No match on the record.
  admin.rpcs.svc_director_identity = () => ({ ok: false, reason: 'no_match' });
  const ok = monoFake({ '/v3/lookup/nin': NIN_OK });
  const nm = await call(deps(admin, new Fake(), { fetch: ok.f }), { action: 'director_nin', token: DC, nin: '12345678901' });
  assertMatch(String(nm.body.error), /does not match a director/);
});

Deno.test('director_nin_reads_a_business_names_proprietors', async () => {
  const admin = new Fake();
  admin.rpcs.svc_director_nin_begin = () => ({ ok: true, cac_id: '88', classification: 'BUSINESS_NAME', tries_left: 2 });
  admin.rpcs.svc_director_identity = () => ({ ok: true, step: 'code' });
  const m = monoFake({ '/v3/lookup/nin': NIN_OK, '/v3/lookup/cac/company/88': { status: 200, body: { data: [{ firstname: 'ADA', surname: 'OBI', phone_number: '08031110000' }] } } });
  await call(deps(admin, new Fake(), { fetch: m.f }), { action: 'director_nin', token: DC, nin: '12345678901' });
  assertEquals(m.asked.map((a) => a.path).sort(), ['/v3/lookup/cac/company/88', '/v3/lookup/cac/company/88/directors', '/v3/lookup/cac/company/88/psc', '/v3/lookup/nin']);
  assertEquals(admin.calls.find((c) => c.fn === 'svc_director_identity')!.args.p.cac, [{ surname: 'OBI', given: 'ADA', email: null, phone: '08031110000' }]);
});

Deno.test('director_slip_stores_once_and_removes_a_refused_one', async () => {
  const admin = new Fake();
  const PDF = 'data:application/pdf;base64,' + btoa('%PDF-1.4 a NIN slip');
  const path = `${ORG}/kyc/director-slip-77777777-7777-4777-8777-777777777777.pdf`;
  admin.rpcs.svc_director_slip_target = (a) => a.p_ext === 'pdf' ? { ok: true, path } : { ok: false, reason: 'invalid' };
  admin.rpcs.svc_director_slip = () => ({ ok: true, status: 'review' });
  const d = deps(admin, new Fake());
  assertMatch(String((await call(d, { action: 'director_slip', token: DC, file: 'data:text/html;base64,' + btoa('<html>') })).body.error), /PDF or a photo/);
  assertMatch(String((await call(d, { action: 'director_slip', token: DC, file: 'data:application/pdf;base64,' + btoa('not a pdf at all') })).body.error), /PDF or a photo/);
  assertEquals(admin.calls.length, 0);
  const r = await call(d, { action: 'director_slip', token: DC, file: PDF });
  assertEquals(r.body, { ok: true, status: 'review' });
  assertEquals(admin.uploads, [{ path, upsert: false, contentType: 'application/pdf' }]);
  assertEquals(admin.calls.map((c) => c.fn), ['svc_director_slip_target', 'svc_director_slip']);
  assertEquals(admin.calls[1].args, { p_token: DC, p_ip: '203.0.113.9', p_ua: 'TestBrowser/1.0', p_path: path });
  // Refused by the database: the file goes again.
  const admin2 = new Fake();
  admin2.rpcs.svc_director_slip_target = () => ({ ok: true, path });
  admin2.rpcs.svc_director_slip = () => ({ ok: false, reason: 'nin_first' });
  const r2 = await call(deps(admin2, new Fake()), { action: 'director_slip', token: DC, file: PDF });
  assertEquals([r2.body.reason, admin2.removed], ['nin_first', [path]]);
  // Not at the slip step: nothing stored.
  const admin3 = new Fake();
  admin3.rpcs.svc_director_slip_target = () => ({ ok: false, reason: 'nin_first' });
  assertEquals((await call(deps(admin3, new Fake()), { action: 'director_slip', token: DC, file: PDF })).body.reason, 'nin_first');
  assertEquals(admin3.uploads.length, 0);
});
