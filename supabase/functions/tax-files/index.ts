// Tax files: the official templates filled from the books, and the hand-off to TaxStreem Flux, which files them on Rev360.
//
// Signed-in callers (the database checks who may see tax returns):
//   { action: 'cit_file', org_id, year }  -> the Rev360 CIT template for that year. A draft carries _DRAFT in its name and is
//                                           made fresh each time; an approved return is written once, from the approved
//                                           snapshot, and kept. Answers { ok, url, file_name, draft, sha256, ties }.
//   { action: 'cit_send', org_id, year }  -> sends an approved return to Flux: the template and the audited financial
//                                           statements as signed links, the fixed-asset declaration and the computation.
//   { action: 'wht_files', org_id, period: 'YYYY-MM', authority: 'NRS' | 'SIRS:LA' ... }
//                                        -> the month's WHT schedule on the NRS template (130 rows a file) or the state template.
//   { action: 'vat_file', org_id, period: 'YYYY-MM' }
//                                        -> the month's NRS VAT return (Form VAT 002, schedules A to F) and how each line of the
//                                           form ties to Counta's VAT for the month.
//   { action: 'flux_send', org_id, tax: 'vat'|'wht'|'wvat', period: 'YYYY-MM' }
//                                        -> sends a month's VAT return (filed in Counta), WHT schedule for the NRS or withholding
//                                           VAT schedule to Flux, which files it on Rev360 and sends back the payment reference
//                                           (PRN) and the account to pay (docs/flux-tax-returns.md).
//   { action: 'flux_new_account', instruction_id }
//                                        -> asks Flux for a new payment account for a PRN whose account expired.
//   { action: 'accountant_upload', org_id, kind: 'vat'|'wht'|'cit'|'fs', period, authority?, path, file_name, note? }
//                                        -> an accountant's changed return or statements, uploaded by the app to path (under
//                                           <org>/tax/accountant/): Counta reads its figures, compares them with its own (or
//                                           with the version in use) and keeps it for review (docs/accountant-portal.md).
// While an accountant's version of a return is in use, the files above are that version (pass original: true for Counta's
// own), and Flux is told who changed it and that they take responsibility.
// Flux settings (admin portal, or Edge Function secrets): FLUX_URL (base URL) and FLUX_SECRET (shared HMAC secret). Requests carry
//   x-counta-signature: t=<unix seconds>,v1=<hex HMAC-SHA256 of "<t>.<raw body>">; Flux reports back on
//   /functions/v1/taxstreem/flux/... with the same signature (docs/flux-cit-handoff.md, docs/flux-tax-returns.md).
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { type CitPack, fillCit } from './cit.ts';
import { sha256Hex, template, TEMPLATES, templatesBase } from './templates.ts';
import { fillVat, type VatSchedule } from './vat.ts';
import { nrsFiles, stateFile, type WhtSchedule } from './wht.ts';
import { citFigures, type Figures, FileProblem, fromVersion, fsCounta, fsFigures, safeName, sideBySide, vatCounta, vatFigures, whtCounta, whtFigures } from './accountant.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const admin = createClient(SUPABASE_URL, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } });
// Keys set in the admin portal (Supabase Vault) come first; the Edge Function secrets are the fallback.
async function vaultFirst(name: string): Promise<string> {
  const { data } = await admin.rpc('svc_secret', { p_name: name });
  return (typeof data === 'string' ? data.trim() : '') || (Deno.env.get(name) || '').trim();
}
const XLSX = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
class UserError extends Error {}

async function svc<T = any>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await admin.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data as T;
}

async function pack(sb: SupabaseClient, orgId: string, year: number): Promise<CitPack> {
  const { data, error } = await sb.rpc('cit_pack', { p_org: orgId, p_year: year });
  if (error) throw new UserError(error.message);
  return data as CitPack;
}

function folder(p: CitPack) { return `${p.org_id}/tax/cit/${p.year}`; }

// The accountant's version in use for a return, if there is one (asked as the person, so the database checks they may see it).
async function inUse(sb: SupabaseClient, orgId: string, kind: string, period: string, authority: string | null = null): Promise<any | null> {
  const { data, error } = await sb.rpc('filing_version_current', { p_org: orgId, p_kind: kind, p_period: period, p_authority: authority });
  if (error) throw new UserError(error.message);
  return data || null;
}
// What the app and Flux are told about an accountant's version.
const accountantOf = (v: any) => v ? { version_id: v.id, version: v.version, name: v.accepted_name, licence: v.accepted_licence, practice: v.practice_name,
  accepted_at: v.accepted_at, statement: v.statement, changes: v.changes, journal_ref: v.journal_ref } : null;

// Writes the file (a draft each time; an approved return once) and answers where it is.
async function citFile(p: CitPack, regenerate = false) {
  if (!p.draft && p.template_path && !regenerate) {
    const { data: blob } = await admin.storage.from('documents').download(p.template_path);
    if (blob) return { path: p.template_path, sha256: await sha256Hex(new Uint8Array(await blob.arrayBuffer())), ties: null, reused: true };
  }
  if (!p.cell_map?.length) throw new UserError(`There is nothing to file for ${p.year} yet.`);
  const { bytes, ties } = fillCit(await template('cit'), p);
  const broken = ties.filter((t) => !t.ok);
  if (broken.length && !p.draft) {
    throw new Error(`The template does not agree with the approved computation: ${broken.map((t) => `${t.label} ${t.template} against ${t.counta}`).join('; ')}`);
  }
  const path = `${folder(p)}/${p.file_name}`;
  const { error } = await admin.storage.from('documents').upload(path, bytes, { contentType: XLSX, upsert: true });
  if (error) throw new Error(`Could not store the file: ${error.message}`);
  if (!p.draft) await svc('svc_cit_flux_update', { p_org: p.org_id, p_year: p.year, p: { template_path: path } });
  return { path, sha256: await sha256Hex(bytes), ties, reused: false };
}

async function signed(path: string, seconds: number, download?: string) {
  const { data, error } = await admin.storage.from('documents').createSignedUrl(path, seconds, download ? { download } : undefined);
  if (error || !data?.signedUrl) throw new Error(`Could not make a link to ${path}: ${error?.message || 'no link'}`);
  return data.signedUrl;
}

async function sign(raw: string, secret: string) {
  const t = Math.floor(Date.now() / 1000);
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`${t}.${raw}`)));
  return `t=${t},v1=${Array.from(sig).map((x) => x.toString(16).padStart(2, '0')).join('')}`;
}

async function citSend(p: CitPack, acc: any = null) {
  if (!p.can_send) {
    if (p.draft) throw new UserError(`Approve the ${p.year} return before sending it to Flux.`);
    if (!p.afs_path) throw new UserError('Attach the audited financial statements before sending the return.');
    if (p.status === 'sent' || p.status === 'filed') throw new UserError(`The ${p.year} return is already ${p.status}.`);
    throw new UserError('Only the owner or someone who approves adjustments sends a tax return.');
  }
  const url = (await vaultFirst('FLUX_URL')).replace(/\/$/, '');
  const secret = await vaultFirst('FLUX_SECRET');
  if (!url || !secret) return { ok: false, reason: 'not_configured', error: 'TaxStreem Flux is not connected yet. Download the file and file it on Rev360, or ask TaxStreem to connect Flux.' };
  const file = acc ? { path: acc.file_path as string, sha256: acc.sha256 as string } : await citFile(p);
  const fileName = acc ? acc.file_name as string : p.file_name;
  const week = 7 * 24 * 3600;
  const afsName = p.afs_path!.split('/').pop()!;
  const body = {
    event: 'cit.return.approved',
    counta_org_id: p.org_id, taxstreem_org_id: p.org?.taxstreem_org_id ?? null,
    company: { name: p.org?.name, tin: p.org?.tin, rc_number: p.org?.rc_number, address: p.org?.address },
    accounting_year: p.year, year_of_assessment: p.yoa, period: { from: p.from, to: p.to }, regime: p.regime, due: p.due,
    approved: { by: p.approved_by ?? null, at: p.approved_at ?? null },
    files: {
      template: { name: fileName, url: await signed(file.path, week), sha256: file.sha256, content_type: XLSX, expires_in: week },
      financial_statements: { name: afsName, url: await signed(p.afs_path!, week), expires_in: week },
    },
    fixed_asset_declaration: p.declaration,
    computation: { rows: p.rows, figures: p.figures },
    prepared_by_accountant: accountantOf(acc),
    callback_url: `${SUPABASE_URL}/functions/v1/taxstreem/flux/cit-status`,
  };
  const raw = JSON.stringify(body);
  let res: Response;
  try {
    res = await fetch(`${url}/counta/cit-returns`, { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-counta-signature': await sign(raw, secret) }, body: raw,
      signal: AbortSignal.timeout(30_000) });
  } catch (e) {
    await svc('svc_cit_flux_update', { p_org: p.org_id, p_year: p.year, p: { flux_status: 'send_failed', message: `Flux did not answer: ${(e as Error).message}` } });
    return { ok: false, reason: 'flux_unreachable', error: 'Flux did not answer. Try again in a few minutes.' };
  }
  const out = await res.json().catch(() => ({}));
  if (!res.ok || out.ok === false) {
    const message = String(out.error || out.message || `Flux answered ${res.status}`).slice(0, 500);
    await svc('svc_cit_flux_update', { p_org: p.org_id, p_year: p.year, p: { flux_status: 'send_failed', message } });
    return { ok: false, reason: 'flux_refused', error: message };
  }
  const row = await svc('svc_cit_flux_update', { p_org: p.org_id, p_year: p.year,
    p: { status: 'sent', ref: String(out.ref || out.id || ''), message: out.message ? String(out.message) : 'Received by Flux' } });
  return { ok: true, status: row.status, flux_ref: row.flux_ref };
}

async function whtFiles(sb: SupabaseClient, orgId: string, period: string, authority: string, original = false) {
  const { data, error } = await sb.rpc('wht_schedule', { p_org: orgId, p_period: `${period}-01`, p_authority: authority, p_kind: 'wht' });
  if (error) throw new UserError(error.message);
  const s = data as WhtSchedule;
  const acc = original ? null : await inUse(sb, orgId, 'wht', period, authority);
  if (acc) {
    const fig = (k: string) => Number((acc.figures || []).find((x: any) => x.key === k)?.uploaded ?? 0);
    return { ok: true, authority, period, accountant: accountantOf(acc), checks: [],
      files: [{ name: acc.file_name, path: acc.file_path, url: await signed(acc.file_path, 1800, acc.file_name), rows: fig('rows'), total: fig('wht_total'),
        template_total: fig('wht_total'), mismatches: [] }] };
  }
  if (!s.rows?.length) return { ok: false, error: `Nothing was deducted for ${s.authority_name || authority} in ${period}.` };
  const blocks = (s.checks || []).filter((c) => c.severity === 'block');
  if (blocks.length) return { ok: false, error: blocks.map((c) => c.text).join(' '), checks: s.checks };
  const tin = (s.org?.tin || '').replace(/[^0-9A-Za-z-]/g, '') || 'NO-TIN';
  const files = authority === 'NRS'
    ? nrsFiles(await template('nrs_wht'), s, `${period}_WHT_NRS_${tin}.xlsx`)
    : [stateFile(await template('sirs_wht'), s, `${period}_WHT_${authority.replace(':', '_')}_${tin}.xlsx`)];
  const out = [];
  for (const f of files) {
    const path = `${orgId}/tax/wht/${period}/${f.name}`;
    const { error: up } = await admin.storage.from('documents').upload(path, f.bytes, { contentType: XLSX, upsert: true });
    if (up) throw new Error(`Could not store ${f.name}: ${up.message}`);
    out.push({ name: f.name, path, url: await signed(path, 1800, f.name), rows: f.rows, total: f.total, template_total: f.template_total, mismatches: f.mismatches });
  }
  return { ok: true, authority, period, files: out, checks: s.checks };
}

async function vatFile(sb: SupabaseClient, orgId: string, period: string, original = false) {
  const { data, error } = await sb.rpc('vat_schedule', { p_org: orgId, p_period: `${period}-01` });
  if (error) throw new UserError(error.message);
  const s = data as VatSchedule;
  const acc = original ? null : await inUse(sb, orgId, 'vat', period);
  if (acc) {
    // The accountant's return is the one of record: its form lines, and Counta's own figures beside them.
    const lines: Record<string, number> = {};
    for (const x of acc.figures || []) if (/^line_\d+$/.test(x.key)) lines[x.key.slice(5)] = Number(x.uploaded ?? 0);
    return { ok: true, period, file_name: acc.file_name as string, path: acc.file_path as string, url: await signed(acc.file_path, 1800, acc.file_name), ties: null,
      rows: null, checks: (s.checks || []).filter((c) => c.severity !== 'block'), lines, counta: s.counta, difference: null, tolerance: s.tolerance,
      accountant: accountantOf(acc) };
  }
  if (s.blocked) return { ok: false, error: s.checks.filter((c) => c.severity === 'block').map((c) => c.text).join(' '), checks: s.checks };
  const { bytes, ties, rows } = fillVat(await template('nrs_vat'), s);
  const path = `${orgId}/tax/vat/${period}/${s.file_name}`;
  const { error: up } = await admin.storage.from('documents').upload(path, bytes, { contentType: XLSX, upsert: true });
  if (up) throw new Error(`Could not store ${s.file_name}: ${up.message}`);
  return { ok: true, period, file_name: s.file_name, path, url: await signed(path, 1800, s.file_name), ties, rows, checks: s.checks,
    lines: s.lines, counta: s.counta, difference: s.difference, tolerance: s.tolerance };
}

// ------------------------------------------------------------------ an accountant's changed file
const KINDS = ['vat', 'wht', 'cit', 'fs'];
async function accountantUpload(sb: SupabaseClient, userId: string, orgId: string, body: any) {
  const kind = String(body.kind || ''), period = String(body.period || ''), authority = kind === 'wht' ? String(body.authority || 'NRS') : null;
  const path = String(body.path || '');
  if (!KINDS.includes(kind)) throw new UserError('Choose the return.');
  if (!path.startsWith(`${orgId}/tax/accountant/`) || path.includes('..') || !/\.xlsx$/i.test(path)) throw new UserError('Upload the file through Counta.');
  // As the accountant: may they, and what is the upload compared with?
  const { data: st, error } = await sb.rpc('filing_version_start', { p_org: orgId, p_kind: kind, p_period: period, p_authority: authority });
  if (error) throw new UserError(error.message);
  const { data: blob, error: de } = await admin.storage.from('documents').download(path);
  if (de || !blob) throw new UserError('Counta could not find the uploaded file. Upload it again.');
  const bytes = new Uint8Array(await blob.arrayBuffer());
  if (bytes.length > 15_000_000) throw new UserError('The file is larger than 15 MB.');
  if (bytes[0] !== 0x50 || bytes[1] !== 0x4b) throw new UserError('That is not an Excel workbook (.xlsx).');

  let up: Figures, base: Figures['rows'] | null = st.current ? fromVersion(st.current.figures) : null;
  try {
    if (kind === 'vat') {
      up = vatFigures(bytes);
      if (!base) {
        const { data: s, error: e } = await sb.rpc('vat_schedule', { p_org: orgId, p_period: `${period}-01` });
        if (e) throw new UserError(e.message);
        base = vatCounta(s as VatSchedule).rows;
      }
    } else if (kind === 'wht') {
      up = whtFigures(bytes, authority!);
      if (!base) {
        const { data: s, error: e } = await sb.rpc('wht_schedule', { p_org: orgId, p_period: `${period}-01`, p_authority: authority, p_kind: 'wht' });
        if (e) throw new UserError(e.message);
        if (authority === 'NRS' && (s as WhtSchedule).rows.length > 130) {
          throw new UserError(`The NRS schedule for ${period} runs to ${Math.ceil((s as WhtSchedule).rows.length / 130)} files. Changed schedules can be uploaded when they fit one file of 130 rows.`);
        }
        base = whtCounta(s as WhtSchedule).rows;
      }
    } else if (kind === 'cit') {
      up = citFigures(bytes);
      if (!base) {
        const p = await pack(sb, orgId, Number(period));
        if (!p.cell_map?.length) throw new UserError(`Counta has no ${period} return to compare with yet. Open the year under Tax, CIT first.`);
        const { bytes: mine } = fillCit(await template('cit'), p);
        base = citFigures(mine).rows;
      }
    } else {
      up = fsFigures(bytes);
      if (!base) {
        const [from, to] = period.split(':');
        const get = async (report: string) => {
          const { data, error: e } = await sb.rpc('accounting_report', { p_org: orgId, p_report: report, p_from: from, p_to: to, p_options: {} });
          if (e) throw new UserError(e.message);
          return (data as any)?.rows || [];
        };
        base = fsCounta(await get('sopl'), await get('sofp')).rows;
      }
    }
  } catch (e) {
    if (e instanceof FileProblem) throw new UserError(e.message);
    throw e;
  }
  const rows = sideBySide(base!, up.rows);
  const { data: saved, error: se } = await admin.rpc('svc_filing_version_save', { p: {
    org_id: orgId, kind, period, authority, file_path: path, file_name: String(body.file_name || '').slice(0, 160) || safeName(path), sha256: await sha256Hex(bytes),
    size: bytes.length, user_id: userId, member_id: st.member_id, base_version: st.current?.id ?? null, rows, checks: up.checks,
    note: typeof body.note === 'string' ? body.note.slice(0, 1500) : null } });
  if (se) throw new UserError(se.message);
  return { ok: true, version: saved, compared_with: st.current ? 'version' : 'counta' };
}

// ------------------------------------------------------------------ VAT, WHT and withholding VAT through Flux
async function fluxConfig() {
  const url = (await vaultFirst('FLUX_URL')).replace(/\/$/, '');
  const secret = await vaultFirst('FLUX_SECRET');
  return url && secret ? { url, secret } : null;
}
const NOT_CONNECTED = { ok: false, reason: 'not_configured', error: 'TaxStreem Flux is not connected yet. Download the file and file it on Rev360, or ask TaxStreem to connect Flux.' };

async function postFlux(cfg: { url: string; secret: string }, path: string, body: unknown): Promise<{ ok: true; out: any } | { ok: false; error: string; reason: string }> {
  const raw = JSON.stringify(body);
  let res: Response;
  try {
    res = await fetch(`${cfg.url}${path}`, { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-counta-signature': await sign(raw, cfg.secret) }, body: raw,
      signal: AbortSignal.timeout(30_000) });
  } catch (e) {
    return { ok: false, reason: 'flux_unreachable', error: `Flux did not answer: ${(e as Error).message}` };
  }
  const out = await res.json().catch(() => ({}));
  // Flux or the network in front of it is down: the same as no answer.
  if (res.status >= 500 && !out.error) return { ok: false, reason: 'flux_unreachable', error: `Flux answered ${res.status}` };
  if (!res.ok || out.ok === false) return { ok: false, reason: 'flux_refused', error: String(out.error || out.message || `Flux answered ${res.status}`).slice(0, 500) };
  return { ok: true, out };
}

const TAX_NAMES: Record<string, string> = { vat: 'VAT return', wht: 'WHT schedule', wvat: 'withholding VAT schedule' };

async function fluxSend(sb: SupabaseClient, orgId: string, tax: string, period: string) {
  const cfg = await fluxConfig();
  if (!cfg) return NOT_CONNECTED;
  const week = 7 * 24 * 3600;
  // The files first, made as the person asking (the database checks they may), so nothing is marked sent that cannot be filed.
  const files: { name: string; url: string; content_type: string; rows?: number; total?: number; expires_in: number }[] = [];
  let schedule: unknown = null, checks: unknown = null, accountant: unknown = null;
  if (tax === 'vat') {
    const f = await vatFile(sb, orgId, period);
    if (!f.ok) return f;
    files.push({ name: f.file_name!, url: await signed(f.path!, week, f.file_name), content_type: XLSX, expires_in: week });
    schedule = { lines: f.lines, counta: f.counta };
    checks = f.checks;
    accountant = (f as any).accountant ?? null;
  } else if (tax === 'wht') {
    const f = await whtFiles(sb, orgId, period, 'NRS');
    if (!f.ok) return f;
    accountant = (f as any).accountant ?? null;
    for (const x of f.files!) files.push({ name: x.name, url: await signed(x.path, week, x.name), content_type: XLSX, rows: x.rows, total: x.total, expires_in: week });
    const { data } = await sb.rpc('wht_schedule', { p_org: orgId, p_period: `${period}-01`, p_authority: 'NRS', p_kind: 'wht' });
    schedule = { rows: (data as WhtSchedule)?.rows || [], total: (data as WhtSchedule)?.total ?? null };
    checks = f.checks;
  } else {
    const { data, error } = await sb.rpc('wht_schedule', { p_org: orgId, p_period: `${period}-01`, p_authority: 'NRS', p_kind: 'wvat' });
    if (error) throw new UserError(error.message);
    const s = data as WhtSchedule;
    if (!s.rows?.length) return { ok: false, error: `No withholding VAT was deducted for the NRS in ${period}.` };
    const blocks = (s.checks || []).filter((c) => c.severity === 'block');
    if (blocks.length) return { ok: false, error: blocks.map((c) => c.text).join(' '), checks: s.checks };
    schedule = { rows: s.rows, total: s.total };
    checks = s.checks;
  }
  const { data: pk, error: pe } = await sb.rpc('flux_return_pack', { p_org: orgId, p_tax: tax, p_period: `${period}-01`, p_authority: 'NRS' });
  if (pe) throw new UserError(pe.message);
  const body = {
    event: 'tax.return.ready',
    counta_org_id: orgId, taxstreem_org_id: pk.org?.taxstreem_org_id ?? null,
    company: { name: pk.org?.name, tin: pk.org?.tin, rc_number: pk.org?.rc_number, address: pk.org?.address },
    tax, period, authority: 'NRS', amount: pk.amount, to_pay: pk.to_pay, due: pk.due, sent_by: pk.sent_by,
    summary: pk.summary, schedule, checks, files, prepared_by_accountant: accountant,
    callback_url: `${SUPABASE_URL}/functions/v1/taxstreem/flux/return-status`,
    payment_url: `${SUPABASE_URL}/functions/v1/taxstreem/flux/payment`,
    payment_status_url: `${SUPABASE_URL}/functions/v1/taxstreem/flux/payment-status`,
  };
  const r = await postFlux(cfg, '/counta/tax-returns', body);
  const fileList = files.map((f) => ({ name: f.name }));
  if (!r.ok) {
    await svc('svc_flux_return_update', { p_org: orgId, p_tax: tax, p_period: `${period}-01`, p_authority: 'NRS',
      p: { status: 'send_failed', message: r.reason === 'flux_unreachable' ? 'Flux did not answer. Try again in a few minutes.' : r.error, files: fileList } });
    return { ok: false, reason: r.reason, error: r.reason === 'flux_unreachable' ? 'Flux did not answer. Try again in a few minutes.' : r.error };
  }
  const row = await svc('svc_flux_return_update', { p_org: orgId, p_tax: tax, p_period: `${period}-01`, p_authority: 'NRS',
    p: { status: 'sent', ref: String(r.out.ref || r.out.id || ''), message: r.out.message ? String(r.out.message) : `Flux has the ${TAX_NAMES[tax]}.`, files: fileList } });
  return { ok: true, status: row.status, flux_ref: row.flux_ref, message: row.message };
}

async function fluxNewAccount(sb: SupabaseClient, id: string) {
  const { data: p, error } = await sb.rpc('flux_instruction_renew', { p_id: id });
  if (error) throw new UserError(error.message);
  const cfg = await fluxConfig();
  if (!cfg) return NOT_CONNECTED;
  const r = await postFlux(cfg, '/counta/tax-payments', { event: 'tax.payment.account_requested', ...p, instruction_id: p.id,
    payment_url: `${SUPABASE_URL}/functions/v1/taxstreem/flux/payment` });
  if (!r.ok) {
    const msg = r.reason === 'flux_unreachable' ? 'Counta could not reach Flux to ask for a new account. Try again in a few minutes.' : `Flux could not give a new account: ${r.error}`;
    await svc('svc_tax_instruction_note', { p_id: id, p_status: null, p_reason: msg });
    return { ok: false, reason: r.reason, error: msg };
  }
  const when = new Date().toLocaleString('en-GB', { timeZone: 'Africa/Lagos', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
  await svc('svc_tax_instruction_note', { p_id: id, p_status: 'renewing', p_reason: `Asked Flux for a new account at ${when}. Counta pays it when it comes.` });
  return { ok: true, status: 'renewing' };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405);
  let body: any;
  try { body = await req.json(); } catch { return json({ ok: false, error: 'Invalid request.' }, 400); }
  try {
    const sb = createClient(SUPABASE_URL, ANON, { global: { headers: { Authorization: req.headers.get('Authorization') || '' } }, auth: { persistSession: false } });
    const { data: u } = await sb.auth.getUser();
    if (!u?.user) return json({ ok: false, error: 'Sign in first.' }, 401);
    // The official templates Counta fills, for TaxStreem's admin portal: which version of each, and where it is served from.
    if (body.action === 'templates') {
      return json({ ok: true, base: templatesBase(), templates: Object.entries(TEMPLATES).map(([id, t]) => ({ id, ...t, url: `${templatesBase()}/${t.file}` })) });
    }
    if (body.action === 'flux_new_account') {
      if (!/^[0-9a-f-]{36}$/i.test(String(body.instruction_id || ''))) return json({ ok: false, error: 'Choose the payment.' }, 400);
      return json(await fluxNewAccount(sb, String(body.instruction_id)));
    }
    const orgId = String(body.org_id || ''), year = Number(body.year);
    if (!/^[0-9a-f-]{36}$/i.test(orgId)) return json({ ok: false, error: 'Choose the business.' }, 400);
    if (body.action === 'accountant_upload') return json(await accountantUpload(sb, u.user.id, orgId, body));
    if (body.action === 'flux_send') {
      const period = String(body.period || '').slice(0, 7), tax = String(body.tax || '');
      if (!/^\d{4}-(0[1-9]|1[0-2])$/.test(period) || !['vat', 'wht', 'wvat'].includes(tax)) return json({ ok: false, error: 'Choose the tax and the month.' }, 400);
      return json(await fluxSend(sb, orgId, tax, period));
    }
    if (body.action === 'wht_files') {
      const period = String(body.period || '').slice(0, 7), authority = String(body.authority || '');
      if (!/^\d{4}-(0[1-9]|1[0-2])$/.test(period) || !/^(NRS|SIRS:[A-Z]{2})$/.test(authority)) return json({ ok: false, error: 'Choose the month and the tax authority.' }, 400);
      return json(await whtFiles(sb, orgId, period, authority, body.original === true));
    }
    if (body.action === 'vat_file') {
      const period = String(body.period || '').slice(0, 7);
      if (!/^\d{4}-(0[1-9]|1[0-2])$/.test(period)) return json({ ok: false, error: 'Choose the month.' }, 400);
      return json(await vatFile(sb, orgId, period, body.original === true));
    }
    if (!Number.isInteger(year)) return json({ ok: false, error: 'Choose the year.' }, 400);
    switch (body.action) {
      case 'cit_file': {
        const p = await pack(sb, orgId, year);
        const acc = body.original === true ? null : await inUse(sb, orgId, 'cit', String(year));
        if (acc) {
          return json({ ok: true, draft: p.draft, status: p.status, file_name: acc.file_name, url: await signed(acc.file_path, 1800, acc.file_name), sha256: acc.sha256,
            ties: null, checks: p.checks, accountant: accountantOf(acc) });
        }
        const f = await citFile(p);
        return json({ ok: true, draft: p.draft, status: p.status, file_name: p.file_name, url: await signed(f.path, 1800, p.file_name), sha256: f.sha256,
          ties: f.ties, checks: p.checks });
      }
      case 'cit_send': {
        const p = await pack(sb, orgId, year);
        return json(await citSend(p, await inUse(sb, orgId, 'cit', String(year))));
      }
      default: return json({ ok: false, error: 'Unknown action.' }, 400);
    }
  } catch (e) {
    if (e instanceof UserError) return json({ ok: false, error: e.message });
    console.error('tax-files', e);
    return json({ ok: false, error: (e as Error).message }, 500);
  }
});
