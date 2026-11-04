// Filing a person's return on e-Tax, in the order of the taxpayer screens: the documents, the statement of income,
// the accommodation, the support staff, the assets, the reliefs, then Confirm. Every step first reads what e-Tax
// already has, so a job that stopped part way picks up where it was without adding anything twice.
import { Etax, listOf } from './etax.js';
import { Refused } from './errors.js';
import { kindOf, mergeToPdf, typeOf, extOf } from './pdf.js';

export type Reporter = { step(step: string, note?: string): Promise<void>; portal(p: Record<string, unknown>): Promise<void> };
export type FileStore = { get(path: string): Promise<{ bytes: Buffer; type: string }> };

const CONFIRMED = '7', ACTIVE = 1, REMOVED = 3;
const HOME: Record<string, string> = { flat: 'Flat or apartment', room: 'Room or self-contained', bungalow: 'Bungalow', duplex: 'Duplex',
  terrace: 'Terrace house', detached: 'Detached house', other: 'Other' };
const n = (v: unknown) => { const x = Number(typeof v === 'string' ? v.replace(/,/g, '') : v); return Number.isFinite(x) ? x : 0; };
// Rounded to kobo the way a person would (2500.555 is 2500.56).
export const r2 = (v: unknown) => Number(Math.round(Number(`${n(v)}e2`)) + 'e-2');
const money = (v: unknown) => r2(v).toFixed(2);
const field = (v: unknown) => (n(v) > 0 ? money(v) : 0);
const isActive = (x: any) => x && Number(x.status_id ?? ACTIVE) !== REMOVED;
const same = (a: unknown, b: unknown) => String(a ?? '').trim().toLowerCase() === String(b ?? '').trim().toLowerCase();
const payerLike = (s: unknown) => /^[NC]-\d{4,12}$/i.test(String(s ?? '').trim());

export async function findReturn(et: Etax, tp: number, year: number) {
  const params = `filters=[{"field": "tax_payer_id", "value" : ${tp}}, {"field": "year", "value" : ${year}}]`
    + '&embeds=["individual", "accommodations", "returnDocuments.document", "status", "individual.otherBreakdowns"]&page_size=1&page=1';
  return listOf(await et.get('tax/returns', params)).find((r) => Number(r.year) === year) || null;
}

// The day a date falls on, kept inside the year e-Tax is looking at.
function inYear(d: unknown, year: number, end: boolean) {
  const s = String(d ?? '').slice(0, 10);
  if (/^\d{4}-\d{2}-\d{2}$/.test(s) && Number(s.slice(0, 4)) === year) return s;
  return end ? `${year}-12-31` : `${year}-01-01`;
}

export function accommodationBody(c: any, me: { individualId: number; payerId: string; name: string }, returnId: number) {
  const a = c.return?.accommodation || {};
  const year = Number(c.year);
  const occ = String(a.occupancy || '');
  let started = inYear(a.started_on && String(a.started_on) < `${year}-01-01` ? `${year}-01-01` : a.started_on, year, false);
  let ended = inYear(a.ended_on, year, true);
  if (ended <= started) { started = `${year}-01-01`; ended = `${year}-12-31`; }
  const body: Record<string, unknown> = {
    individual_id: me.individualId, return_id: returnId, address: String(a.address || '').trim(), accommodation_type: HOME[a.type] || String(a.type || 'Other'),
    started_at: started, ended_at: ended, rent_paid_by_employer: field(a.rent_paid_by_employer),
    owner_tax_payer_number: '', owner_name: '', owner_address: '',
  };
  if (occ === 'tenant') {
    Object.assign(body, { accommodation_user_type_id: 1, rent_paid: money(a.rent_paid), owner_name: String(a.landlord_name || '').trim(),
      owner_address: String(a.landlord_address || '').trim(), owner_tax_payer_number: payerLike(a.landlord_id) ? String(a.landlord_id).trim().toUpperCase() : '' });
  } else if (occ === 'owner') {
    // The person's own home: e-Tax fills the owner with the taxpayer, and takes the rent as "0.00" (0 is refused).
    Object.assign(body, { accommodation_user_type_id: 2, rent_paid: '0.00', owner_name: me.name || c.taxpayer?.name || '', owner_tax_payer_number: me.payerId,
      owner_address: String(a.address || '').trim() });
  } else {
    // Provided by an employer, or living with family: e-Tax's "Others".
    Object.assign(body, { accommodation_user_type_id: 3, rent_paid: occ === 'employer' && n(a.rent_paid_by_employer) > 0 ? money(a.rent_paid_by_employer) : '0.00' });
  }
  if (!body.address) throw new Refused('The home address is missing from the return. Enter where they lived under People, approve again, then send.');
  return body;
}

export function statementOfIncome(c: any, tp: number) {
  const f = c.return?.income?.fields || {};
  const lines = (c.return?.income?.other_lines || []) as any[];
  return {
    data: { salary: field(f.salary), commission: field(f.commission), trade_income: field(Math.max(n(f.trade_income), 0)), allowance: field(f.allowance),
      pension: field(f.pension), annuity: field(f.annuity), gratuities: field(f.gratuities), foreign_income: field(f.foreign_income), dividend: field(f.dividend),
      interest: field(f.interest), rent: field(f.rent), others: field(f.other_income) },
    tax_payer_id: tp, year: Number(c.year),
    breakdowns: lines.filter((l) => n(l.amount) > 0).map((l) => ({ name: String(l.label || 'Other income').slice(0, 120), amount: r2(l.amount) })),
  };
}

// The form of each relief, as e-Tax's relief types ask for it (file fields are added from the documents).
export function reliefData(r: any): Record<string, unknown> {
  const d = r.details || {}, amt = r2(r.amount);
  switch (Number(r.portal_type)) {
    case 1: return { nameOfCompany: String(d.life_company || ''), policyName: String(d.life_policy || ''), premiumPayment: amt };
    case 2: case 5: return { amount: amt };
    case 3: case 4: return { retirementSavingsAccount: String(d.rsa_number || ''), pensionFundAdministrator: String(d.pfa || ''), totalContribution: amt };
    case 6: return { primaryMortgageInstitution: String(d.mortgage_institution || ''), capitalSumonMortgage: r2(d.mortgage_capital), totalInterestPaidInYear: amt };
    default: throw new Refused(`Counta does not know e-Tax's form for ${r.label || r.relief}.`);
  }
}

export function assetBody(a: any, address: string) {
  const cls = String(a.class || '');
  const date = /^\d{4}-\d{2}-\d{2}/.test(String(a.acquired_on || '')) ? String(a.acquired_on).slice(0, 10) : `${n(a.first_year) || new Date().getFullYear()}-01-01`;
  const cost = r2(a.cost);
  // Land and buildings go as real estate; everything else as "Others" (Counta's register has no make or model for a
  // vehicle, and the bot does not make them up).
  if (['1501', '1502', '1503'].includes(cls) || /land|building/i.test(String(a.category || ''))) {
    return { type_id: 3, data: { address, dateOfAcquisition: date, valueOfProperty: cost } };
  }
  return { type_id: 5, data: { dateOfPurchase: date, address, costOfAcquisition: cost } };
}

async function documentFor(files: FileStore, paths: string[], what: string): Promise<{ name: string; type: string; bytes: Buffer }> {
  if (!paths.length) throw new Refused(`${what} is missing. Attach it under People, approve again, then send.`);
  const got: Buffer[] = [];
  for (const p of paths) {
    try { got.push((await files.get(p)).bytes); } catch { throw new Refused(`${what} could not be read from Counta's storage. Attach it again.`); }
  }
  const one = got.length === 1 ? got[0] : await mergeToPdf(got).catch(() => { throw new Refused(`${what}: one of the files is not a PDF, JPEG or PNG.`); });
  const k = kindOf(one);
  if (k === 'other') throw new Refused(`${what} is not a PDF, JPEG or PNG.`);
  return { name: `${what.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 60) || 'document'}.${extOf(k)}`, type: typeOf(k), bytes: one };
}

export async function fileReturn(et: Etax, c: any, files: FileStore, rep: Reporter) {
  const me = et.me, tp = me.taxPayerId, year = Number(c.year);
  const portal = c.portal || {};
  await rep.portal({ tax_payer_id: String(tp) });
  let ret = await findReturn(et, tp, year);
  if (ret && String(ret.status_id) === CONFIRMED) {
    if (portal.return_id && String(portal.return_id) === String(ret.id)) return { return_id: String(ret.id), tax_payer_id: String(tp), confirmed_at: portal.confirmed_at || null };
    throw new Refused(`The ${year} return on e-Tax is already confirmed (return ${ret.id}), and Counta did not confirm it. A confirmed return cannot be changed: ask LIRS to reopen it, or record it as filed.`);
  }

  // 1. The statement of accounts and Counta's computation, as the return's documents (e-Tax takes PDFs only).
  const docs = [
    { path: c.return?.files?.statement_of_accounts, label: `Statement of accounts ${year}`, name: `statement-of-accounts-${year}.pdf` },
    { path: c.return?.files?.computation, label: `Income tax computation ${year}`, name: `income-tax-computation-${year}.pdf` },
  ];
  const have = (r: any) => ((r?.return_documents || r?.returnDocuments || []) as any[]).filter(isActive).map((d) => String(d.label || ''));
  for (const d of docs) {
    if (!d.path) throw new Refused(`The ${d.label.toLowerCase()} is missing. Send again from the app, which attaches it.`);
    if (ret && have(ret).some((l) => same(l, d.label))) continue;
    const f = await documentFor(files, [d.path], d.label);
    if (kindOf(f.bytes) !== 'pdf') throw new Refused(`The ${d.label.toLowerCase()} must be a PDF for e-Tax.`);
    const out = await et.upload('tax/returns/documents', { type_code: 'statement_account', year, tax_payer_id: tp, file: '', label: d.label }, { ...f, name: d.name });
    if (out?.id && Number(out.year) === year) ret = out;
  }
  await rep.step('documents', 'The statement of accounts and the computation are on the return.');

  // 2. The statement of income: Counta's taxable figures, so the tax e-Tax works out is Counta's.
  const soi = statementOfIncome(c, tp);
  const saved = await et.post('tax/returns/individual/extract', soi);
  const returnId = Number(saved?.id ?? ret?.id);
  if (!returnId) throw new Refused('e-Tax did not say which return it saved the statement of income on.');
  await et.post(`drafts/soi-${year}-${tp}/remove`).catch(() => {});
  await rep.portal({ return_id: String(returnId), steps: { statement_of_income: new Date().toISOString() } });
  await rep.step('statement_of_income', `Income lines on return ${returnId}.`);

  // 3. The accommodation (one active record per return).
  ret = (await findReturn(et, tp, year)) || ret;
  const acc = accommodationBody(c, me, returnId);
  const current = ((ret?.accommodations || []) as any[]).filter(isActive);
  if (current.length) {
    await et.put(`accommodations/${current[0].id}`, acc);
    for (const extra of current.slice(1)) await et.put(`accommodations/${extra.id}`, { status_id: REMOVED });
  } else {
    await et.post('accommodations', acc);
  }
  await et.post(`drafts/accommodation-${year}-${tp}/remove`).catch(() => {});
  await rep.step('accommodation', 'Where they lived in the year.');

  // 4. The person's own household staff (kept on the e-Tax profile). The business's employees are not sent.
  const roles = c.return?.staff_roles || {};
  const staff = (c.return?.household_staff || []) as any[];
  const seen: Record<string, any[]> = {};
  const listed = async (kind: 'relations' | 'links', type: number) => {
    const key = `${kind}:${type}`;
    if (!seen[key]) {
      const params = kind === 'relations'
        ? `embeds=["formData", "type"]&filters=[{"field" : "tax_payer_id", "value" : ${tp}}, {"field" : "type_id", "value" : ${type}}]`
        : `embeds=["taxPayer", "relationTaxPayer.entity", "type"]&filters=[{"field" : "tax_payer_id", "value" : ${tp}}, {"field" : "type_id", "value" : ${type}}]`;
      seen[key] = listOf(await et.get(kind === 'relations' ? 'tax/payers/relations' : 'tax/payers/relations/links', params)).filter(isActive);
    }
    return seen[key];
  };
  let added = 0;
  for (const s of staff) {
    const type = Number(roles[s.role]?.type_id || 18);
    const pay = r2(s.income_paid);
    if (s.registered && payerLike(s.payer_id)) {
      const pid = String(s.payer_id).toUpperCase();
      if ((await listed('links', type)).some((x) => same(x.relation_tax_payer?.reg_no ?? x.relation_tax_payer_number, pid))) continue;
      await et.post(`tax/payers/${tp}/relations/links`, { type_id: type, relation_tax_payer_number: pid, incomePaid: pay });
    } else {
      if ((await listed('relations', type)).some((x) => same(x.form_data?.data?.fullName ?? x.data?.fullName, s.name))) continue;
      await et.post(`tax/payers/${tp}/relations`, { type_id: type, data: { fullName: String(s.name || '').trim(), address: String(s.address || '').trim(), incomePaid: pay } });
    }
    added++;
  }
  await rep.step('support_staff', staff.length ? `${staff.length} household staff (${added} added now).` : 'No household staff.');

  // 5. Assets: the business's fixed assets on an owner's own return. A partnership's assets are the partnership's, so
  //    a partner's return leaves them out.
  const assets = ((c.return?.assets || []) as any[]).filter((a) => !a.disposed && n(a.cost) > 0);
  const address = String(c.org?.address || '').trim();
  if (c.taxpayer?.role === 'proprietor' && assets.length && address) {
    const onReturn = listOf(await et.get('tax/returns/assets', `embeds=["formData"]&filters=[{"field": "return_id", "value": ${returnId}}, {"field": "status_id", "value": ${ACTIVE}}]&no_pages=1`)).filter(isActive);
    for (const a of assets) {
      const b = assetBody(a, address);
      const dateKey = (b.data as any).dateOfAcquisition || (b.data as any).dateOfPurchase;
      const costKey = n((b.data as any).valueOfProperty ?? (b.data as any).costOfAcquisition);
      const there = onReturn.some((x) => Number(x.asset_type_id ?? x.type_id) === b.type_id
        && String(x.form_data?.data?.dateOfAcquisition || x.form_data?.data?.dateOfPurchase || '').slice(0, 10) === dateKey
        && n(x.form_data?.data?.valueOfProperty ?? x.form_data?.data?.costOfAcquisition) === costKey);
      if (!there) await et.post(`tax/returns/${returnId}/assets`, b);
    }
    await rep.step('assets', `${assets.length} business assets.`);
  } else {
    await rep.step('assets', c.taxpayer?.role === 'proprietor' ? (assets.length ? 'No business address to list the assets with.' : 'No assets to list.') : 'A partner\'s return leaves out the partnership\'s assets.');
  }

  // 6. Reliefs, each with its evidence (e-Tax denies a relief without it). Gratuity and rent relief have no section on
  //    e-Tax: Counta counts them in its computation, which is attached, and posts nothing for them.
  const want = ((c.return?.reliefs || []) as any[]).filter((r) => typeof r.portal_type === 'number' && n(r.amount) > 0);
  const onReturn = listOf(await et.get('tax/returns/relief', `embeds=["formData"]&filters=[{"field": "return_id", "value": ${returnId}}, {"field": "status_id", "value": ${ACTIVE}}]&no_pages=1`)).filter(isActive);
  const typeOfRelief = (x: any) => Number(x.relief_type_id ?? x.type_id);
  for (const r of want) {
    const data: Record<string, unknown> = reliefData(r);
    for (const [k, v] of Object.entries(data)) if (v === '' || v === null) throw new Refused(`${r.label}: ${k} is missing. Enter it under People, approve again, then send.`);
    const fileFields = ((r.files || []) as any[]).filter((f) => f.portal_field);
    const there = onReturn.find((x) => typeOfRelief(x) === Number(r.portal_type));
    const old = there?.form_data?.data || {};
    const unchanged = there && Object.entries(data).every(([k, v]) => (typeof v === 'number' ? n(old[k]) === v : same(old[k], v)))
      && fileFields.every((f) => /^https?:\/\//.test(String(old[f.portal_field] || '')));
    if (unchanged) continue;
    for (const f of fileFields) {
      const doc = await documentFor(files, (f.paths || []) as string[], `${r.label}: ${f.label}`);
      const up = await et.upload('documents', { type_code: 'taxpayer.doc', entity_type_id: '9', entity_id: tp, name: 'Relief', file: '' }, doc);
      if (!up?.url) throw new Refused(`e-Tax did not keep the ${String(f.label).toLowerCase()} for ${r.label}.`);
      data[f.portal_field] = up.url;
    }
    if (there) await et.put(`tax/returns/relief/${there.id}`, { type_id: Number(r.portal_type), data });
    else await et.post(`tax/returns/${returnId}/relief`, { type_id: Number(r.portal_type), data });
  }
  // A relief on the return that Counta does not claim would change the tax: it comes off.
  const wanted = new Set(want.map((r) => Number(r.portal_type)));
  let removed = 0;
  for (const x of onReturn) if (!wanted.has(typeOfRelief(x))) { await et.put(`tax/returns/relief/${x.id}`, { status_id: REMOVED }); removed++; }
  const onRecord = ((c.return?.reliefs_on_record || []) as any[]).map((r) => r.label).filter(Boolean);
  await rep.step('reliefs', [want.length ? `${want.length} reliefs with their documents.` : 'No reliefs to post.', removed ? `${removed} relief Counta does not claim taken off.` : '',
    onRecord.length ? `${onRecord.join(' and ')} counted in Counta's computation (no e-Tax section).` : ''].filter(Boolean).join(' '));

  // 7. A last look, then Confirm (the declaration under s.124 NTA 2025 that the return is true).
  const check = await findReturn(et, tp, year);
  if (!check || Number(check.id) !== returnId) throw new Refused('e-Tax does not show the return Counta just prepared. Nothing was confirmed.');
  if (String(check.status_id) !== CONFIRMED) {
    await et.post(`tax/returns/${returnId}/status/complete`);
    const after = await findReturn(et, tp, year);
    if (!after || String(after.status_id) !== CONFIRMED) throw new Refused('e-Tax did not confirm the return. It is saved there, not confirmed.');
  }
  const at = new Date().toISOString();
  await rep.portal({ confirmed_at: at, steps: { confirmed: at } });
  await rep.step('confirmed', `Return ${returnId} confirmed on e-Tax.`);
  return { return_id: String(returnId), tax_payer_id: String(tp), confirmed_at: at };
}
