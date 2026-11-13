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
  admin.files.set(docPath, new TextEncoder().encode('%PDF-1.7 something else'));
  admin.rpcs.svc_sign_verify = () => ({ ok: true, letter });
  const r = await call(deps(admin, new Fake()), { action: 'sign_submit', token: ES, code: '123 456', typed_name: 'Ada Obi', signature_png: PNG_URL });
  assertEquals(r.body, { ok: false, reason: 'changed', error: 'The letter has changed since it was signed by the firm.' });
  assertEquals(admin.uploads.length, 0);
  assert(!admin.calls.some((c) => c.fn === 'svc_sign_complete'));
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
    firm: { name: 'Ṣọlá & Co' }, partner: { id: USER, name: 'Ṣọlá Ìyá', email: 'sola@firm.example.test', title: 'Partner' } });
  admin.rpcs.svc_letter_frozen = (a) => ({ id: LID, status: 'partner_signed', doc_sha256: a.p.doc_sha256 });
  const r = await call(deps(admin, user), { action: 'letter_freeze', letter_id: LID, signature_name: 'Ṣọlá Ìyá' });
  assertEquals(r.body.ok, true);
  const path = `practice/${PID}/letters/${LID}/letter.pdf`;
  assertEquals(admin.uploads.map((u) => [u.path, u.upsert, u.contentType]), [[path, false, 'application/pdf']]);
  const frozen = admin.calls.find((c) => c.fn === 'svc_letter_frozen')!;
  assertEquals(frozen.args.p, { doc_path: path, doc_sha256: await sha256Hex(admin.files.get(path)!), by_user: USER, signature_name: 'Ṣọlá Ìyá',
    ip: '203.0.113.9', ua: 'TestBrowser/1.0' });
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
