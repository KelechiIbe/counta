// Tax files: the official templates filled from the books, and the hand-off to TaxStreem Flux, which files them on Rev360.
//
// Signed-in callers (the database checks who may see tax returns):
//   { action: 'cit_file', org_id, year }  -> the Rev360 CIT template for that year. A draft carries _DRAFT in its name and is
//                                           made fresh each time; an approved return is written once, from the approved
//                                           snapshot, and kept. Answers { ok, url, file_name, draft, sha256, ties }.
//   { action: 'cit_send', org_id, year }  -> sends an approved return to Flux: the template and the audited financial
//                                           statements as signed links, the fixed-asset declaration and the computation.
//   { action: 'pit_send', org_id, year, person_id? }
//                                        -> sends the approved personal income tax returns of a business name or partnership
//                                           to Flux, one per person, for the states Flux files (Lagos first): the person's
//                                           computation, the business's, the partners and the statement of accounts as a
//                                           signed link (docs/flux-pit-handoff.md). Other states' returns are filed by the
//                                           business and marked filed in Counta. Each return also carries what the state
//                                           portal's screens ask for: the statement of income, the accommodation, the
//                                           reliefs with their documents, the staff and the fixed assets, the person's
//                                           computation (made by the app as a PDF) and Flux's reference to the business's
//                                           login for that portal.
//                                           A person whose state Counta's own bot files (LIRS e-Tax, bots/lirs) is not sent
//                                           to Flux: their return is queued for the bot, which signs in with the person's
//                                           own e-Tax login and files it as them (docs/lirs-etax-bot.md), and the bot is woken.
//   { action: 'pit_etax_login_save', org_id, person_id, payer_id, password }
//   { action: 'pit_etax_login_remove', org_id, person_id }
//                                        -> the person, or whoever files the business's tax, saves or removes the person's
//                                           own LIRS e-Tax login. The password goes into Supabase Vault for the bot alone;
//                                           it is never stored elsewhere, logged or sent back. On saving, the bot is woken
//                                           to check it at once: it signs in, notes whose account it is and the tax
//                                           station, and signs out without changing anything on e-Tax.
//   { action: 'pit_bill', org_id, year, person_id }
//                                        -> asks the bot to raise the person's bill on e-Tax again (after a bill failed).
//   { action: 'pit_pay', org_id, year, person_id, pay_with: 'transfer' }
//                                        -> asks the bot for a one-time account to pay the person's bill by transfer (e-Tax's
//                                           Flutterwave channel); the app shows it when the bot reports back.
//   { action: 'pit_tcc_request', org_id, year, person_id }
//                                        -> asks Flux to apply for the person's tax clearance certificate once the return is
//                                           filed and paid: the profile picture, the three years' returns and the authority to
//                                           file any outstanding one.
//   { action: 'portal_login_save', org_id, authority: 'NRS' | 'SIRS:LA' ..., username, password, tax_office? }
//   { action: 'portal_login_remove', org_id, authority }
//                                        -> the owner (signed in with two-step) saves or removes the business's login to a
//                                           tax portal. The login goes straight to Flux, which keeps it; Counta keeps only
//                                           Flux's reference, a hint of the username and the tax office. The password is
//                                           never stored, logged or sent back.
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

// A signed link to a file the return needs, or a plain reason when it is not in storage.
async function linkTo(path: string, seconds: number, name: string, what: string) {
  try { return await signed(path, seconds, name); } catch { throw new UserError(`${what} is missing from Counta's storage. Attach it again.`); }
}
const fileName = (path: string) => String(path).split('/').pop()!.replace(/^\d+-/, '');
const listOf = (names: string[]) => (names.length < 2 ? names.join('') : `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}`);

// Personal income tax: each person's approved return to Flux, for the states it files.
type SendResult = { person_id: string; name: string; ok: boolean; flux_ref?: string; error?: string; bot?: boolean; job_id?: string };
async function pitSend(sb: SupabaseClient, orgId: string, year: number, personId: string | null) {
  const { data: pk, error } = await sb.rpc('pit_pack', { p_org: orgId, p_year: year });
  if (error) throw new UserError(error.message);
  const all = (pk.people || []) as any[];
  const bots: string[] = pk.bot_authorities || [];
  const isBot = (p: any) => bots.includes(p.authority);
  const open = all.filter((p) => (p.flux || isBot(p)) && (!personId || p.person_id === personId) && ['approved', 'rejected'].includes(p.status));
  const botPeople = open.filter(isBot), fluxPeople = open.filter((p) => !isBot(p));
  if (!open.length) {
    return { ok: false, reason: 'nothing_to_send', error: personId ? 'That return is not one Counta or Flux files, or it is already on its way.' : 'None of these returns is for a state Counta or Flux files yet, or they are already on their way.' };
  }
  const results: SendResult[] = [];
  // LIRS e-Tax: Counta's own bot, signing in as each person with their own login.
  for (const p of botPeople) {
    const { data, error: qe } = await sb.rpc('pit_lirs_queue', { p_org: orgId, p_year: year, p_person: p.person_id, p_kind: 'file', p_request: {} });
    if (qe) results.push({ person_id: p.person_id, name: p.name, ok: false, bot: true, error: qe.message });
    else results.push({ person_id: p.person_id, name: p.name, ok: true, bot: true, job_id: data?.job?.id });
  }
  const woke = results.some((r) => r.ok) ? await wakeBot('pit_send') : false;
  if (fluxPeople.length) {
    try { results.push(...await pitSendFlux(sb, pk, orgId, year, fluxPeople)); }
    catch (e) {
      if (!botPeople.length) throw e;
      const msg = e instanceof UserError ? e.message : 'Flux could not take it.';
      for (const p of fluxPeople) results.push({ person_id: p.person_id, name: p.name, ok: false, error: msg });
    }
  }
  const sent = results.filter((x) => x.ok).length;
  return { ok: sent > 0, sent, failed: results.length - sent, results, bot: results.filter((x) => x.bot && x.ok).length, woke,
    error: sent ? undefined : results.map((x) => `${x.name}: ${x.error}`).join(' ') };
}

// Counta's LIRS bot: told there is work, so a job seldom waits for the database's next round (every five minutes while a
// job is due). The bot answers at once and works on. Set LIRS_BOT_URL (the Cloud Run address) and LIRS_BOT_SECRET (shared
// with the bot) in the admin portal or as Edge Function secrets.
async function wakeBot(reason: string): Promise<boolean> {
  const url = (await vaultFirst('LIRS_BOT_URL')).replace(/\/+$/, '');
  const secret = await vaultFirst('LIRS_BOT_SECRET');
  if (!url || !secret) return false;
  const raw = JSON.stringify({ reason, at: new Date().toISOString() });
  const call = (async () => {
    try {
      const r = await fetch(`${url}/tick`, { method: 'POST', body: raw, signal: AbortSignal.timeout(15_000),
        headers: { 'Content-Type': 'application/json', 'x-counta-signature': await sign(raw, secret) } });
      await r.body?.cancel();
    } catch { /* the bot's scheduled round picks the job up */ }
  })();
  // The answer goes back at once; the call to the bot carries on after it.
  const rt = (globalThis as any).EdgeRuntime;
  if (rt?.waitUntil) rt.waitUntil(call);
  return true;
}

async function pitSendFlux(sb: SupabaseClient, pk: any, orgId: string, year: number, people: any[]): Promise<SendResult[]> {
  const all = (pk.people || []) as any[];
  const cfg = await fluxConfig();
  if (!cfg) throw new UserError('TaxStreem Flux is not connected yet. Download the computation and file each return with the state, or ask TaxStreem to connect Flux.');
  if (!pk.portal_ready) throw new UserError(`Reopen the ${year} return and approve it again: the state portal now asks for each relief's documents, the accommodation and the staff.`);
  if (!pk.soa_path) throw new UserError('Attach the statement of accounts first.');
  const logins = pk.logins || {};
  const noLogin = Array.from(new Set(people.filter((p) => !logins[p.authority]?.flux_ref).map((p) => p.authority_short || p.authority_name || p.authority)));
  if (noLogin.length) throw new UserError(`Save the business's ${listOf(noLogin)} login under Settings, Tax portal logins, so Flux can sign in and file.`);
  const noComp = people.filter((p) => !p.computation_path).map((p) => p.name);
  if (noComp.length) throw new UserError(`The computation for ${listOf(noComp)} is not ready yet. Send again from the app, which makes it.`);
  const week = 7 * 24 * 3600;
  const soaName = fileName(pk.soa_path);
  const soaUrl = await linkTo(pk.soa_path, week, soaName, 'The statement of accounts');
  const needs = pk.relief_needs || {};
  const partners = pk.kind === 'partnership'
    ? all.map((p) => ({ person_id: p.person_id, name: p.name, tin: p.tin ?? null, share_pct: p.share_pct, role: p.role, authority: p.authority })) : [];
  const results: SendResult[] = [];
  for (const p of people) {
    // The reliefs Counta counted, each with the documents the portal asks for (a relief without them was left out).
    const reliefs = [];
    for (const [k, amount] of Object.entries(p.reliefs_claimed || {})) {
      const docs = [];
      for (const d of ((p.relief_docs || {})[k] || []) as any[]) {
        const label = (needs[k]?.docs || []).find((x: any) => x.id === d.doc)?.label || d.doc;
        docs.push({ doc: d.doc, label, name: d.name, url: await linkTo(d.path, week, d.name, `${p.name}'s ${String(label).toLowerCase()}`), expires_in: week });
      }
      reliefs.push({ relief: k, label: needs[k]?.label || k, amount,
        ...(k === 'pension' ? { rsa_number: p.pension_details?.rsa_number ?? null, pfa: p.pension_details?.pfa ?? null, total_contribution: amount } : {}),
        documents: docs });
    }
    const compName = `${p.name} income tax computation ${year}.pdf`;
    const login = logins[p.authority];
    const body = {
      event: 'pit.return.approved',
      counta_org_id: orgId, taxstreem_org_id: pk.org?.taxstreem_org_id ?? null,
      business: { name: pk.org?.name, kind: pk.kind === 'sole' ? 'sole_proprietor' : 'partnership', legal_form: pk.org?.legal_form ?? null,
        tin: pk.org?.tin ?? null, registration_number: pk.org?.rc_number ?? null, address: pk.org?.address ?? null },
      accounting_year: pk.year, year_of_assessment: pk.yoa, period: { from: pk.from, to: pk.to }, regime: pk.regime, due: pk.due,
      approved: { by: pk.approved_by ?? null, at: pk.approved_at ?? null }, attested: pk.attested ?? null,
      taxpayer: { person_id: p.person_id, name: p.name, tin: p.tin ?? null, role: p.role, share_pct: p.share_pct, resident: p.resident !== false,
        authority: p.authority, authority_name: p.authority_name ?? null, state: p.authority_state ?? null, office: p.office ?? null },
      computation: { rows: p.computation?.rows, figures: p.computation?.figures, bands: p.computation?.bands, other_income: p.computation?.other_income },
      reliefs: p.reliefs_claimed ?? {},
      business_computation: { rows: pk.business, figures: pk.business_figures },
      partners,
      // What the portal's screens ask for, in their order: the statement of income (Counta's taxable figures, so the tax
      // the portal works out is Counta's), the accommodation, the support staff, the assets, then each relief.
      return_form: {
        statement_of_income: p.income_fields?.fields ?? null,
        income_total: p.income_fields?.total ?? null,
        other_income_lines: p.income_fields?.other_lines ?? [],
        left_out_of_income: p.income_fields?.left_out ?? [],
        accommodation: p.accommodation ?? null,
        support_staff: pk.staff ?? [],
        assets: pk.assets ?? [],
        reliefs,
        reliefs_left_out: p.reliefs_held ?? [],
      },
      portal: { authority: p.authority, login_ref: login.flux_ref, tax_office: login.tax_office ?? null },
      payment: { mode: 'pay_link', note: 'Generate the pay bill after filing and send it back as bill, with its payment link. The partner or the business pays through it; report the payment as paid.' },
      files: {
        statement_of_accounts: { name: soaName, url: soaUrl, content_type: 'application/pdf', expires_in: week },
        tax_computation: { name: compName, url: await linkTo(p.computation_path, week, compName, `${p.name}'s computation`), content_type: 'application/pdf', expires_in: week },
      },
      rulebook: pk.rulebook,
      callback_url: `${SUPABASE_URL}/functions/v1/taxstreem/flux/pit-status`,
    };
    const r = await postFlux(cfg, '/counta/pit-returns', body);
    if (!r.ok) {
      const message = r.reason === 'flux_unreachable' ? 'Flux did not answer. Try again in a few minutes.' : r.error;
      await svc('svc_pit_flux_update', { p_org: orgId, p_year: year, p_person: p.person_id, p: { status: 'send_failed', message } });
      results.push({ person_id: p.person_id, name: p.name, ok: false, error: message });
      continue;
    }
    const row = await svc('svc_pit_flux_update', { p_org: orgId, p_year: year, p_person: p.person_id,
      p: { status: 'sent', ref: String(r.out.ref || r.out.id || ''), message: r.out.message ? String(r.out.message) : 'Received by Flux' } });
    results.push({ person_id: p.person_id, name: p.name, ok: true, flux_ref: row.flux_ref });
  }
  return results;
}

// A person's own LIRS e-Tax login, for Counta's bot. Asked first as the person signed in (the database checks that it is
// the person, or someone who files the business's tax, with two-step where the business asks for it), then saved by
// the service: the password goes into Supabase Vault and nowhere else.
async function etaxLoginSave(sb: SupabaseClient, orgId: string, body: any) {
  const person = String(body.person_id || '');
  if (!/^[0-9a-f-]{36}$/i.test(person)) throw new UserError('Choose the person.');
  const payer = String(body.payer_id ?? '').trim().toUpperCase().replace(/\s+/g, '');
  const password = String(body.password ?? '');
  if (!/^[NC]-\d{4,12}$/.test(payer)) throw new UserError('Enter the Payer ID as e-Tax shows it, with N- in front (for example N-1234567).');
  if (payer.startsWith('C-')) throw new UserError('That is a company\'s Payer ID. Each person files with their own, which starts with N-.');
  if (!password.trim() || password.length > 200) throw new UserError('Enter the e-Tax password (at most 200 characters).');
  if (password !== password.trim()) throw new UserError('e-Tax ignores spaces at the start and end of a password. Enter it without them.');
  const { data: b, error } = await sb.rpc('pit_etax_login_begin', { p_org: orgId, p_person: person });
  if (error) throw new UserError(error.message);
  const row = await svc('svc_pit_etax_login_save', { p_org: orgId, p_person: person, p: { payer_id: payer, password, member_id: b.member_id } });
  // The database queued a check of it: the bot signs in, notes whose account it is and the tax station, and signs out.
  const woke = await wakeBot('check');
  return { ok: true, login: row, woke };
}
async function etaxLoginRemove(sb: SupabaseClient, orgId: string, body: any) {
  const person = String(body.person_id || '');
  if (!/^[0-9a-f-]{36}$/i.test(person)) throw new UserError('Choose the person.');
  const { error } = await sb.rpc('pit_etax_login_begin', { p_org: orgId, p_person: person });
  if (error) throw new UserError(error.message);
  try { return { ok: true, ...(await svc('svc_pit_etax_login_remove', { p_org: orgId, p_person: person })) }; }
  catch (e) { throw new UserError(String((e as Error).message).replace(/^svc_pit_etax_login_remove: /, '')); }
}
// The bot again for a person's bill: raise it, or fetch an account to pay it by transfer.
async function pitBot(sb: SupabaseClient, orgId: string, year: number, body: any, kind: 'bill' | 'pay_account') {
  const person = String(body.person_id || '');
  if (!/^[0-9a-f-]{36}$/i.test(person)) throw new UserError('Choose the person.');
  const request = kind === 'pay_account' ? { pay_with: String(body.pay_with || 'transfer') } : {};
  const { data, error } = await sb.rpc('pit_lirs_queue', { p_org: orgId, p_year: year, p_person: person, p_kind: kind, p_request: request });
  if (error) throw new UserError(error.message);
  const woke = await wakeBot(kind);
  return { ok: true, job: data?.job ?? null, already: data?.already === true, woke };
}

// The tax clearance certificate for a person whose return is filed and paid: Flux applies for it on the portal.
async function pitTccRequest(sb: SupabaseClient, orgId: string, year: number, personId: string) {
  const { data: t, error } = await sb.rpc('pit_tcc_pack', { p_org: orgId, p_year: year, p_person: personId });
  if (error) throw new UserError(error.message);
  const cfg = await fluxConfig();
  if (!cfg) return { ok: false, reason: 'not_configured', error: 'TaxStreem Flux is not connected yet. Apply for the certificate on the state portal, or ask TaxStreem to connect Flux.' };
  if (!t.login?.flux_ref) throw new UserError(`Save the business's ${t.taxpayer?.authority_name || 'state'} login under Settings, Tax portal logins, first.`);
  const week = 7 * 24 * 3600;
  const photoName = t.photo_name || fileName(t.photo_path);
  const returns = [];
  for (const y of (t.years || []) as any[]) {
    returns.push(y.filed_in_counta
      ? { accounting_year: y.year, year_of_assessment: y.yoa, filed_in_counta: true, acknowledgement_ref: y.acknowledgement_ref ?? null }
      : { accounting_year: y.year, year_of_assessment: y.yoa, filed_in_counta: false,
          file: { name: y.name || fileName(y.path), url: await linkTo(y.path, week, y.name || fileName(y.path), `The ${y.year} return`), expires_in: week } });
  }
  const body = {
    event: 'pit.tcc.requested',
    counta_org_id: orgId, taxstreem_org_id: t.org?.taxstreem_org_id ?? null,
    business: { name: t.org?.name, tin: t.org?.tin ?? null, registration_number: t.org?.rc_number ?? null, address: t.org?.address ?? null },
    accounting_year: t.year, year_of_assessment: t.yoa, taxpayer: t.taxpayer,
    portal: { authority: t.taxpayer?.authority, login_ref: t.login.flux_ref, tax_office: t.login.tax_office ?? null },
    profile_picture: { name: photoName, url: await linkTo(t.photo_path, week, photoName, 'The profile picture'), expires_in: week },
    returns, authorise_outstanding: t.authorise_outstanding === true, payment: t.paid,
    callback_url: `${SUPABASE_URL}/functions/v1/taxstreem/flux/pit-status`,
  };
  const r = await postFlux(cfg, '/counta/pit-tcc', body);
  if (!r.ok) return { ok: false, reason: r.reason, error: r.reason === 'flux_unreachable' ? 'Flux did not answer. Try again in a few minutes.' : r.error };
  const row = await svc('svc_pit_flux_update', { p_org: orgId, p_year: year, p_person: personId,
    p: { tcc: { status: 'requested', ref: String(r.out.ref || r.out.id || ''), message: r.out.message ? String(r.out.message) : null } } });
  return { ok: true, tcc: row.tcc };
}

// A login to a tax portal, handed to Flux at once. Counta keeps Flux's reference and a hint of the username only.
function usernameHint(u: string) {
  const at = u.indexOf('@');
  if (at > 0) return `${u.slice(0, Math.min(2, at))}•••@${u.slice(at + 1)}`.slice(0, 80);
  return u.length <= 4 ? `${u.slice(0, 1)}•••` : `${u.slice(0, 2)}•••${u.slice(-2)}`;
}
async function portalLoginSave(sb: SupabaseClient, orgId: string, body: any) {
  const authority = String(body.authority || '');
  const username = String(body.username ?? '').trim();
  const password = String(body.password ?? '');
  const office = String(body.tax_office ?? '').trim().slice(0, 120);
  if (!/^(NRS|SIRS:[A-Z]{2})$/.test(authority)) throw new UserError('Choose the tax authority.');
  if (!username || username.length > 120) throw new UserError('Enter the username (at most 120 characters).');
  if (!password || password.length > 200) throw new UserError('Enter the password (at most 200 characters).');
  const { data: b, error } = await sb.rpc('portal_login_begin', { p_org: orgId, p_authority: authority });
  if (error) throw new UserError(error.message);
  const cfg = await fluxConfig();
  if (!cfg) return { ok: false, reason: 'not_configured', error: 'TaxStreem Flux is not connected yet, so there is nowhere to keep the login. Nothing was saved.' };
  const r = await postFlux(cfg, '/counta/portal-credentials', {
    event: 'portal.credentials.saved',
    counta_org_id: orgId, taxstreem_org_id: b.org?.taxstreem_org_id ?? null,
    business: { name: b.org?.name, tin: b.org?.tin ?? null, registration_number: b.org?.rc_number ?? null },
    authority: b.authority, username, password, tax_office: office || null, replaces: b.existing?.flux_ref ?? null,
    callback_url: `${SUPABASE_URL}/functions/v1/taxstreem/flux/portal-login-status`,
  });
  // Flux's answer is passed on, never with the password in it.
  const clean = (s: string) => s.split(password).join('•••');
  if (!r.ok) return { ok: false, reason: r.reason, error: r.reason === 'flux_unreachable' ? 'Flux did not answer, so the login was not saved. Try again in a few minutes.' : clean(r.error) };
  const ref = String(r.out.ref || r.out.id || '').slice(0, 200);
  if (!ref) return { ok: false, reason: 'flux_refused', error: 'Flux did not confirm that it kept the login, so nothing was saved. Try again.' };
  const row = await svc('svc_portal_login_saved', { p_org: orgId, p_authority: authority,
    p: { username_hint: usernameHint(username), tax_office: office, flux_ref: ref, member_id: b.member_id } });
  return { ok: true, login: row };
}
async function portalLoginRemove(sb: SupabaseClient, orgId: string, body: any) {
  const authority = String(body.authority || '');
  if (!/^(NRS|SIRS:[A-Z]{2})$/.test(authority)) throw new UserError('Choose the tax authority.');
  const { data: b, error } = await sb.rpc('portal_login_begin', { p_org: orgId, p_authority: authority });
  if (error) throw new UserError(error.message);
  if (!b.existing) return { ok: true, removed: false };
  const cfg = await fluxConfig();
  if (cfg && b.existing.flux_ref) {
    const r = await postFlux(cfg, '/counta/portal-credentials', { event: 'portal.credentials.removed', counta_org_id: orgId, authority: b.authority, ref: b.existing.flux_ref });
    if (!r.ok) return { ok: false, reason: r.reason, error: r.reason === 'flux_unreachable' ? 'Flux did not answer, so the login is still saved. Try again in a few minutes.' : r.error };
  }
  await svc('svc_portal_login_removed', { p_org: orgId, p_authority: authority });
  return { ok: true, removed: true };
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
    if (body.action === 'portal_login_save') return json(await portalLoginSave(sb, orgId, body));
    if (body.action === 'portal_login_remove') return json(await portalLoginRemove(sb, orgId, body));
    if (body.action === 'pit_etax_login_save') return json(await etaxLoginSave(sb, orgId, body));
    if (body.action === 'pit_etax_login_remove') return json(await etaxLoginRemove(sb, orgId, body));
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
      case 'pit_send': {
        const person = body.person_id == null || body.person_id === '' ? null : String(body.person_id);
        if (person && !/^[0-9a-f-]{36}$/i.test(person)) return json({ ok: false, error: 'Choose the person.' }, 400);
        return json(await pitSend(sb, orgId, year, person));
      }
      case 'pit_bill': return json(await pitBot(sb, orgId, year, body, 'bill'));
      case 'pit_pay': return json(await pitBot(sb, orgId, year, body, 'pay_account'));
      case 'pit_tcc_request': {
        const person = String(body.person_id || '');
        if (!/^[0-9a-f-]{36}$/i.test(person)) return json({ ok: false, error: 'Choose the person.' }, 400);
        return json(await pitTccRequest(sb, orgId, year, person));
      }
      default: return json({ ok: false, error: 'Unknown action.' }, 400);
    }
  } catch (e) {
    if (e instanceof UserError) return json({ ok: false, error: e.message });
    console.error('tax-files', e);
    return json({ ok: false, error: (e as Error).message }, 500);
  }
});
