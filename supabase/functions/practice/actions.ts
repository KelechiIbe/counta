// The practice function's actions (index.ts serves them). POST JSON {action, ...} -> {ok: true, ...} or {ok: false, error}
// (with reason when the database gave one). See index.ts for the list.
//
// Public actions (the signing page /sign and the director's page /confirm, no account): the token is checked for its form
// before anything else, the caller's IP address and browser go to the database with each call, the token is never logged,
// and every answer carries Referrer-Policy: no-referrer. Files are written with the service role, write-once (upsert
// false); a file written by a step that then fails is removed again so the step can be retried.
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { deriveMerge, type LetterBody, renderModel } from '../_shared/letter.ts';
import { appendCompletion, pngDrawable, renderLetterPdf } from './pdf.ts';
import { buildExport } from './export.ts';
import { clientIp, pngFromDataUrl, sha256Hex, tokenOk, userAgent, UserError } from './util.ts';
import { PDFDocument } from 'npm:pdf-lib@1.17.1';

export type Deps = {
  admin: SupabaseClient; // service role
  asUser: (authorization: string) => SupabaseClient; // the caller's own token
  secret: (name: string) => Promise<string>; // Vault first, then the Edge Function secret
  monoUrl: string;
  fetch?: typeof fetch; // Mono (tests pass a mock)
  now?: () => Date;
};
type User = { id: string; email?: string };
type Body = Record<string, unknown>;
type Result = Record<string, unknown>;

const BUCKET = 'documents';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Referrer-Policy': 'no-referrer',
  'Cache-Control': 'no-store',
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...HEADERS, 'Content-Type': 'application/json' } });

// What the signing and confirmation pages say when the database gives a reason instead of going ahead. No Counta
// name: a full-mandate client sees only the firm.
export const REASONS: Record<string, string> = {
  invalid: 'This link is not valid. Ask the firm to send it again.',
  expired: 'This link has expired. Ask the firm to send it again.',
  void: 'The firm has withdrawn this letter.',
  signed: 'This letter is signed already.',
  closed: 'Nothing more is needed on this link.',
  locked: 'Too many wrong codes were entered. Ask the firm to send the link again.',
  too_many_today: 'That is five codes today. Try again tomorrow.',
  wrong_code: 'That code is not right. Check the latest email and try again.',
  used_up: 'That code has been tried five times. Ask for a new code.',
  not_verified: 'Enter a new code: the last one was confirmed more than 15 minutes ago.',
  review: 'This confirmation is being checked by TaxStreem.',
  confirmed: 'This confirmation is done already.',
  declined: 'This request was declined.',
};
const refusal = (reason: unknown): Result => {
  const r = typeof reason === 'string' && reason ? reason : 'invalid';
  return { ok: false, reason: r, error: REASONS[r] || 'This link cannot be used now.' };
};

// Tokens never reach the logs, whatever an error message says.
const scrub = (s: string) => s.replace(/\b[a-z]{2}_[0-9a-f]{48}\b/g, '[token]');

async function rpc<T = any>(c: SupabaseClient, fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await c.rpc(fn, args);
  if (error) throw new UserError(error.message);
  return data as T;
}
const uuid = (v: unknown, what: string): string => {
  if (typeof v !== 'string' || !UUID.test(v)) throw new UserError(`Choose the ${what}.`);
  return v.toLowerCase();
};

// ------------------------------------------------------------------ files
async function upload(d: Deps, path: string, bytes: Uint8Array, contentType: string, taken: string) {
  const { error } = await d.admin.storage.from(BUCKET).upload(path, bytes, { contentType, upsert: false });
  if (!error) return;
  if (/exist|duplicate/i.test(error.message) || String((error as { statusCode?: unknown }).statusCode) === '409') throw new UserError(taken);
  throw new Error(`Storing ${path}: ${error.message}`);
}
async function download(d: Deps, path: string, missing: string): Promise<Uint8Array> {
  const { data, error } = await d.admin.storage.from(BUCKET).download(path);
  if (error || !data) throw new UserError(missing);
  return new Uint8Array(await data.arrayBuffer());
}
async function remove(d: Deps, paths: string[]) {
  if (!paths.length) return;
  try {
    const { error } = await d.admin.storage.from(BUCKET).remove(paths);
    if (error) console.error('practice: could not remove', paths.join(', '), error.message);
  } catch (e) {
    console.error('practice: could not remove', paths.join(', '), (e as Error).message);
  }
}
async function signedUrl(d: Deps, path: string, seconds: number, download = false): Promise<string | null> {
  const { data, error } = await d.admin.storage.from(BUCKET).createSignedUrl(path, seconds, download ? { download: true } : undefined);
  return error ? null : data?.signedUrl || null;
}

// ------------------------------------------------------------------ signed in: the firm
// A partner signs a draft letter for the firm: the letter as prepared for them (practice_letter_prepare, as themselves)
// rendered to a PDF and stored write-once in the letter's folder, or a PDF letter's own file as it stands; its SHA-256;
// then svc_letter_frozen records the signature (the partner's name and email as they are now, IP, browser).
async function letterFreeze(req: Request, b: Body, d: Deps, sb: SupabaseClient, user: User): Promise<Result> {
  const letterId = uuid(b.letter_id, 'letter');
  const signature = String(b.signature_name ?? '').replace(/\s+/g, ' ').trim();
  if (signature && (signature.length < 2 || signature.length > 120)) throw new UserError('Type your name to sign (2 to 120 characters).');
  const prep = await rpc(sb, 'practice_letter_prepare', { p_letter: letterId });
  if (!UUID.test(String(prep?.practice_id)) || String(prep?.letter_id).toLowerCase() !== letterId) throw new Error('practice_letter_prepare: unexpected answer');
  const ip = clientIp(req), ua = userAgent(req);

  let path: string, bytes: Uint8Array, written = false;
  if (prep.source === 'pdf') {
    path = String(prep.doc_path || '');
    bytes = await download(d, path, 'The letter\'s PDF could not be read. Upload it again as a new template.');
    try {
      if (new TextDecoder().decode(bytes.slice(0, 5)) !== '%PDF-') throw new Error('not a PDF');
      await PDFDocument.load(bytes);
    } catch {
      throw new UserError('The letter\'s file is not a PDF that can be signed (it may be protected by a password). Upload an unprotected PDF.');
    }
  } else {
    let blocks;
    try {
      blocks = renderModel(prep.blocks as LetterBody, deriveMerge(prep.merge || {}), prep.variant === 'full' ? 'full' : 'involved');
    } catch (e) {
      throw new UserError((e as Error).message);
    }
    bytes = await renderLetterPdf(blocks, { title: String(prep.title || 'Letter of engagement'), firmName: String(prep.firm?.name || ''),
      partnerName: String(prep.partner?.name || ''), partnerTitle: String(prep.partner?.title || 'Partner'),
      partnerSignature: signature || String(prep.partner?.name || '') });
    path = `practice/${prep.practice_id}/letters/${letterId}/letter.pdf`;
    await upload(d, path, bytes, 'application/pdf',
      'This letter already has a signed file in its folder. Void it and draft the letter again.');
    written = true;
  }
  try {
    const letter = await rpc(d.admin, 'svc_letter_frozen', { p_letter: letterId,
      p: { doc_path: path, doc_sha256: await sha256Hex(bytes), by_user: user.id, signature_name: signature || null, ip, ua } });
    return { ok: true, letter };
  } catch (e) {
    if (written) await remove(d, [path]);
    throw e;
  }
}

// A partner exports a client's records (practice_export_begin, as themselves): the zip, and a link to it for 10 minutes.
async function exportRecords(_req: Request, b: Body, d: Deps, sb: SupabaseClient): Promise<Result> {
  const begin = await rpc(sb, 'practice_export_begin', { p_client: uuid(b.client_id, 'client') });
  const out = await buildExport(d.admin, begin, d.now?.() ?? new Date());
  const url = await signedUrl(d, out.path, 600, true);
  if (!url) throw new Error('The export was stored, but no link could be made to it.');
  return { ok: true, url, sha256: out.sha256, bytes: out.bytes };
}

// Bank feeds of a business whose mandate ended: the database unlinked them in Counta (provider manual, the Mono account
// kept as former_feed); here they are unlinked at Mono too, as the mono function's own unlink does. Each outcome is kept
// on the account (mono_unlinked_at, or mono_unlink_error to try again).
export async function unlinkFormerFeeds(d: Deps, orgId: string): Promise<{ unlinked: number; failed: number }> {
  const { data, error } = await d.admin.from('bank_accounts').select('id, provider, provider_meta').eq('org_id', orgId);
  if (error) throw new Error(`bank_accounts: ${error.message}`);
  const todo = ((data || []) as { id: string; provider: string; provider_meta: Record<string, unknown> | null }[])
    .filter((r) => r.provider === 'manual' && r.provider_meta?.unlinked_reason === 'engagement ended'
      && typeof r.provider_meta?.former_feed === 'string' && r.provider_meta.former_feed && !r.provider_meta?.mono_unlinked_at);
  if (!todo.length) return { unlinked: 0, failed: 0 };
  const key = await d.secret('MONO_SECRET_KEY');
  const call = d.fetch ?? fetch;
  let unlinked = 0, failed = 0;
  for (const r of todo) {
    const meta = r.provider_meta || {};
    let err: string | null = null;
    if (!key) {
      err = 'Bank feeds are not switched on (no Mono key).';
    } else {
      try {
        const res = await call(`${d.monoUrl}/v2/accounts/${encodeURIComponent(String(meta.former_feed))}/unlink`, {
          method: 'POST', headers: { 'mono-sec-key': key, accept: 'application/json', 'Content-Type': 'application/json' }, signal: AbortSignal.timeout(20_000) });
        const text = await res.text();
        let body: any = null;
        try { body = JSON.parse(text); } catch { /* not json */ }
        if (!res.ok || body?.status === 'failed' || body?.status === 'error') err = `Mono: ${String(body?.message || text || res.status).slice(0, 200)}`;
      } catch (e) {
        err = `Mono: ${(e as Error).message}`.slice(0, 200);
      }
    }
    const at = (d.now?.() ?? new Date()).toISOString();
    const next = err ? { ...meta, mono_unlink_error: err, mono_unlink_tried_at: at } : { ...meta, mono_unlinked_at: at, mono_unlink_error: null };
    const { error: ue } = await d.admin.from('bank_accounts').update({ provider_meta: next }).eq('id', r.id);
    if (ue) console.error('practice: could not record the Mono unlink of', r.id, ue.message);
    if (err) failed++; else unlinked++;
  }
  return { unlinked, failed };
}

// A partner ends a full mandate without a handover (practice_end_mandate, as themselves), then its bank feeds are
// unlinked at Mono.
async function endMandate(_req: Request, b: Body, d: Deps, sb: SupabaseClient): Promise<Result> {
  const res = await rpc(sb, 'practice_end_mandate', { p_client: uuid(b.client_id, 'client'), p: { reason: String(b.reason ?? '') } });
  let feeds: Result;
  try {
    feeds = await unlinkFormerFeeds(d, String(res.org_id));
  } catch (e) {
    console.error('practice: Mono unlink after the mandate ended', (e as Error).message);
    feeds = { unlinked: 0, failed: null, error: 'The bank feeds could not be unlinked at the bank feed provider. Try again from the client.' };
  }
  return { ok: true, ...res, feeds };
}

// The bank feeds of an ended mandate that could not be unlinked at Mono, tried again (a partner who may export the
// client's records may do this too).
async function unlinkFeeds(_req: Request, b: Body, d: Deps, sb: SupabaseClient): Promise<Result> {
  const begin = await rpc(sb, 'practice_export_begin', { p_client: uuid(b.client_id, 'client') });
  return { ok: true, feeds: await unlinkFormerFeeds(d, String(begin.org_id)) };
}

// ------------------------------------------------------------------ public: the client's signer
const ask = (req: Request, token: string) => ({ p_token: token, p_ip: clientIp(req), p_ua: userAgent(req) });
const codeShape = (v: unknown) => typeof v === 'string' && /^\d{6}$/.test(v.replace(/\s/g, ''));

async function signOpen(req: Request, b: Body, d: Deps): Promise<Result> {
  const token = String(b.token ?? '');
  if (!tokenOk(token, 'es')) return refusal('invalid');
  const r = await rpc(d.admin, 'svc_sign_open', ask(req, token));
  if (!r?.ok) return refusal(r?.reason);
  return { ...r, doc_url: r.doc_path ? await signedUrl(d, String(r.doc_path), 300) : null };
}

async function signCode(req: Request, b: Body, d: Deps): Promise<Result> {
  const token = String(b.token ?? '');
  if (!tokenOk(token, 'es')) return refusal('invalid');
  const r = await rpc(d.admin, 'svc_sign_code', ask(req, token));
  return r?.ok ? r : refusal(r?.reason);
}

// The signer signs: everything that can be wrong with what they sent is checked before their code is used. Then the
// code (svc_sign_verify), the stored letter re-read and its SHA-256 compared with the one recorded when the firm signed
// (refused if they differ), the signature page and completion certificate added, the signature image and the signed
// letter stored write-once, and the letter completed (svc_sign_complete). The answer holds nothing of the firm's
// partner beyond what the certificate shows, and a 5-minute link to the signed letter.
async function signSubmit(req: Request, b: Body, d: Deps): Promise<Result> {
  const token = String(b.token ?? '');
  if (!tokenOk(token, 'es')) return refusal('invalid');
  const typed = String(b.typed_name ?? '').replace(/\s+/g, ' ').trim();
  if (typed.length < 2 || typed.length > 120) throw new UserError('Type your full name (2 to 120 characters).');
  const png = pngFromDataUrl(String(b.signature_png ?? ''));
  if (!png || !(await pngDrawable(png))) throw new UserError('Sign again: the signature must be a PNG image of at most 300 KB.');
  if (!codeShape(b.code)) return { ok: false, reason: 'wrong_code', error: 'Enter the 6-digit code from the email.' };
  const ip = clientIp(req), ua = userAgent(req);

  const v = await rpc(d.admin, 'svc_sign_verify', { ...ask(req, token), p_code: String(b.code) });
  if (!v?.ok) return { ...refusal(v?.reason), tries_left: Number(v?.tries_left ?? 0), locked: v?.locked === true };
  const l = v.letter || {};
  if (!UUID.test(String(l.practice_id)) || !UUID.test(String(l.letter_id)) || !UUID.test(String(l.signer_id))) throw new Error('svc_sign_verify: unexpected answer');

  const doc = await download(d, String(l.doc_path || ''), 'The letter could not be read. Ask the firm to send it again.');
  if ((await sha256Hex(doc)) !== String(l.doc_sha256 || '').toLowerCase()) {
    console.error('practice: the stored letter does not match the fingerprint recorded when the firm signed it', l.letter_id);
    return { ok: false, reason: 'changed', error: 'The letter has changed since it was signed by the firm.' };
  }
  const { data: pr } = await d.admin.from('practices').select('name').eq('id', l.practice_id).maybeSingle();
  let final: Uint8Array;
  try {
    final = await appendCompletion(doc, {
      title: String(l.title || 'Letter of engagement'), originalSha256: String(l.doc_sha256).toLowerCase(),
      firm: { name: String(pr?.name || ''), partnerName: String(l.partner_name || ''), partnerEmail: String(l.partner_email || ''),
        signedAt: String(l.partner_signed_at || ''), ip: l.partner_ip ?? null, ua: l.partner_ua ?? null },
      client: { name: String(l.signer_name || typed), email: String(l.signer_email || ''), title: l.signer_title ?? null, signedAt: d.now?.() ?? new Date(),
        ip, ua, typedName: typed, signaturePng: png },
    });
  } catch (e) {
    console.error('practice: the signed letter could not be put together', l.letter_id, (e as Error).message);
    throw new UserError('The signed letter could not be put together. Ask the firm to send the letter again.');
  }

  const dir = `practice/${l.practice_id}/letters/${l.letter_id}`;
  const sigPath = `${dir}/signature-${l.signer_id}.png`, finalPath = `${dir}/final.pdf`;
  const written: string[] = [];
  let done: any;
  try {
    await upload(d, sigPath, png, 'image/png', 'This letter is being signed already. Open the link again in a minute.');
    written.push(sigPath);
    await upload(d, finalPath, final, 'application/pdf', 'This letter is being signed already. Open the link again in a minute.');
    written.push(finalPath);
    done = await rpc(d.admin, 'svc_sign_complete', { p_token: token,
      p: { signature_path: sigPath, final_path: finalPath, final_sha256: await sha256Hex(final), typed_name: typed, ip, ua } });
  } catch (e) {
    await remove(d, written);
    throw e;
  }
  if (!done?.ok) {
    await remove(d, written);
    return refusal(done?.reason);
  }
  return { ok: true, status: done.status, doc_url: await signedUrl(d, finalPath, 300) };
}

// ------------------------------------------------------------------ public: the director's confirmation
async function directorOpen(req: Request, b: Body, d: Deps): Promise<Result> {
  const token = String(b.token ?? '');
  if (!tokenOk(token, 'dc')) return refusal('invalid');
  const r = await rpc(d.admin, 'svc_director_open', ask(req, token));
  return r?.ok ? r : refusal(r?.reason);
}
async function directorCode(req: Request, b: Body, d: Deps): Promise<Result> {
  const token = String(b.token ?? '');
  if (!tokenOk(token, 'dc')) return refusal('invalid');
  const r = await rpc(d.admin, 'svc_director_code', ask(req, token));
  return r?.ok ? r : refusal(r?.reason);
}
async function directorConfirm(req: Request, b: Body, d: Deps): Promise<Result> {
  const token = String(b.token ?? '');
  if (!tokenOk(token, 'dc')) return refusal('invalid');
  if (!codeShape(b.code)) return { ok: false, reason: 'wrong_code', error: 'Enter the 6-digit code from the email.' };
  const r = await rpc(d.admin, 'svc_director_confirm', { ...ask(req, token), p_code: String(b.code) });
  return r?.ok ? r : { ...refusal(r?.reason), tries_left: Number(r?.tries_left ?? 0), locked: r?.locked === true };
}
async function directorDecline(req: Request, b: Body, d: Deps): Promise<Result> {
  const token = String(b.token ?? '');
  if (!tokenOk(token, 'dc')) return refusal('invalid');
  const reason = String(b.reason ?? '').replace(/\s+/g, ' ').trim();
  if (reason.length > 500) throw new UserError('Keep the reason under 500 characters.');
  const r = await rpc(d.admin, 'svc_director_decline', { ...ask(req, token), p_reason: reason || null });
  return r?.ok ? r : refusal(r?.reason);
}

// ------------------------------------------------------------------ entry
// (Maps, so an action named after an object property, "constructor" say, is simply unknown.)
const PUBLIC = new Map<string, (req: Request, b: Body, d: Deps) => Promise<Result>>([
  ['sign_open', signOpen], ['sign_code', signCode], ['sign_submit', signSubmit],
  ['director_open', directorOpen], ['director_code', directorCode], ['director_confirm', directorConfirm], ['director_decline', directorDecline],
]);
const SIGNED_IN = new Map<string, (req: Request, b: Body, d: Deps, sb: SupabaseClient, user: User) => Promise<Result>>([
  ['letter_freeze', letterFreeze], ['export', exportRecords], ['end_mandate', endMandate], ['unlink_feeds', unlinkFeeds],
]);

export async function handle(req: Request, d: Deps): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: HEADERS });
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405);
  let body: Body;
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: 'Invalid request.' }, 400);
  }
  if (!body || typeof body !== 'object' || Array.isArray(body)) return json({ ok: false, error: 'Invalid request.' }, 400);
  const action = String(body.action ?? '');
  try {
    const pub = PUBLIC.get(action);
    if (pub) return json(await pub(req, body, d));
    const own = SIGNED_IN.get(action);
    if (!own) return json({ ok: false, error: 'Unknown action.' }, 400);
    const sb = d.asUser(req.headers.get('Authorization') || '');
    const { data: u } = await sb.auth.getUser();
    if (!u?.user) return json({ ok: false, error: 'Sign in first.' }, 401);
    return json(await own(req, body, d, sb, { id: u.user.id, email: u.user.email }));
  } catch (e) {
    if (e instanceof UserError) return json({ ok: false, error: e.message });
    console.error('practice', action, scrub(String((e as Error)?.message || e)));
    return json({ ok: false, error: 'Something went wrong. Try again.' }, 500);
  }
}
