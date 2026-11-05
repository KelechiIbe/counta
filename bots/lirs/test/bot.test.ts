// The bot against the stand-in e-Tax, payments page and checkout, with a stand-in Counta handing out jobs.
// node --test dist/test/
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { PDFDocument } from 'pdf-lib';
import { startMock, type State } from './mock.js';

const SECRET = 'test-secret-0123456789abcdefghijklmnopqrstuvwxyz';
const PASSWORD = 'Pa55-word!quiet';
let mock: Awaited<ReturnType<typeof startMock>>;
let st: State;
let counta: { url: string; close: () => void; jobs: any[]; reports: any[]; files: Map<string, Buffer>; badSig: number; busy: { next: number; report: number } };
let runner: typeof import('../src/runner.js');
let sign: typeof import('../src/sign.js');

async function pdf(text: string) {
  const d = await PDFDocument.create(); const p = d.addPage([200, 200]); p.drawText(text, { x: 20, y: 100, size: 12 });
  return Buffer.from(await d.save());
}
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');

function startCounta() {
  const jobs: any[] = [], reports: any[] = [], files = new Map<string, Buffer>();
  // Counta busy for a moment: the next few claims or reports are answered with an error, as a cancelled statement is.
  const busy = { next: 0, report: 0 };
  let badSig = 0;
  const srv = createServer(async (req, res) => {
    const chunks: Buffer[] = []; for await (const c of req) chunks.push(c as Buffer);
    const raw = Buffer.concat(chunks).toString('utf8');
    const url = new URL(req.url || '/', 'http://x');
    if (url.pathname === '/file') { const b = files.get(url.searchParams.get('path') || ''); res.writeHead(b ? 200 : 404, { 'Content-Type': 'application/octet-stream' }); return res.end(b || ''); }
    if (!sign.verify(raw, req.headers['x-counta-signature'] as string, SECRET)) { badSig++; res.writeHead(401); return res.end('{"ok":false,"error":"Bad signature."}'); }
    const b = JSON.parse(raw || '{}');
    res.setHeader('Content-Type', 'application/json');
    if (url.pathname === '/lirs/next' && busy.next > 0) { busy.next--; res.writeHead(422); return res.end('{"ok":false,"error":"canceling statement due to statement timeout"}'); }
    if (url.pathname === '/lirs/report' && busy.report > 0) { busy.report--; res.writeHead(422); return res.end('{"ok":false,"error":"canceling statement due to statement timeout"}'); }
    if (url.pathname === '/lirs/next') {
      const j = jobs.find((x) => x.status === 'queued');
      if (!j) return res.end(JSON.stringify({ ok: true, job: null }));
      j.status = 'running'; j.attempt = (j.attempt || 0) + 1;
      const paths: string[] = [];
      const walk = (x: any) => { if (!x || typeof x !== 'object') return; for (const [k, v] of Object.entries(x)) { if (typeof v === 'string' && files.has(v)) paths.push(v); else walk(v); } };
      walk(j.context);
      return res.end(JSON.stringify({ ok: true, job: { id: j.id, kind: j.kind, attempt: j.attempt, max_attempts: 3, org_id: 'org1', year: j.context.year, person_id: j.person },
        context: j.context, files: Object.fromEntries(paths.map((p) => [p, `${counta.url}/file?path=${encodeURIComponent(p)}`])) }));
    }
    if (url.pathname === '/lirs/report') {
      reports.push(b);
      const j = jobs.find((x) => x.id === b.job_id);
      if (j && b.done) { j.status = 'done'; j.result = b.result; }
      if (j && b.failed) { j.status = b.retry ? 'retry' : 'failed'; j.error = b.error; j.retry = b.retry; }
      if (j && b.portal) j.context.portal = { ...j.context.portal, ...b.portal };
      return res.end(JSON.stringify({ ok: true, job_id: b.job_id }));
    }
    res.writeHead(404); res.end('{}');
  });
  return new Promise<typeof counta>((resolve) => srv.listen(0, '127.0.0.1', () => {
    const c = { url: `http://127.0.0.1:${(srv.address() as any).port}`, close: () => srv.close(), jobs, reports, files, busy, get badSig() { return badSig; } } as any;
    resolve(c);
  }));
}

function context(over: any = {}) {
  return {
    login: { payer_id: 'N-16000001', password: PASSWORD, tax_station: null, tax_station_name: null },
    taxpayer: { person_id: 'p1', name: 'Ada Obi', tin: null, authority: 'SIRS:LA', role: 'proprietor', share_pct: 100 },
    year: 2025, yoa: 2026,
    org: { name: 'Obi & Co', address: '12 Admiralty Way, Lekki', email: 'books@obi.test', phone: '08031234567' },
    portal: {},
    return: {
      income: { fields: { salary: 2400000, commission: 1500000, trade_income: 5000000, allowance: 0, pension: 0, annuity: 0, gratuities: 800000, foreign_income: 0, dividend: 120000, interest: 0, rent: 0, other_income: 300000 },
        total: 10120000, other_lines: [{ label: 'Royalties, Book', amount: 300000 }], left_out: [] },
      accommodation: { address: '4 Palm Close, Lekki', type: 'flat', occupancy: 'tenant', landlord_name: 'Mr Landlord', landlord_id: 'N-12345678', landlord_address: '9 Park View', rent_paid: 1800000, rent_paid_by_employer: 0, started_on: '2023-05-01', ended_on: '' },
      household_staff: [{ role: 'driver', registered: false, name: 'Musa Bello', address: '3 Ajah Road', income_paid: 720000 },
        { role: 'cook', registered: true, payer_id: 'N-22223333', income_paid: 600000 }],
      staff_roles: { other: { type_id: 18 }, driver: { type_id: 19 }, cook: { type_id: 20 }, security: { type_id: 21 }, cleaner: { type_id: 22 }, gardener: { type_id: 23 } },
      reliefs: [
        { relief: 'pension', label: 'Pension contributions', amount: 240000, portal_type: 3, details: { rsa_number: 'PEN100012345678', pfa: 'Stanbic IBTC Pensions' },
          files: [{ doc: 'rsa_statement', label: 'RSA statement', portal_field: 'rsaStatementForYear', paths: ['o/p1/rsa.pdf'] }] },
        { relief: 'life_insurance', label: 'Life insurance or deferred annuity', amount: 150000, portal_type: 1, details: { life_company: 'Leadway Assurance', life_policy: 'Whole Life' },
          files: [{ doc: 'policy', label: 'Life insurance policy', portal_field: 'policyDocument', paths: ['o/p1/policy1.pdf', 'o/p1/policy2.png'] },
            { doc: 'premium_certificate', label: 'Certificate of premium', portal_field: 'certificateOfPremium', paths: ['o/p1/cert.png'] },
            { doc: 'receipt', label: 'Receipt of payment', portal_field: 'receiptOfPayment', paths: ['o/p1/receipt.pdf'] }] },
      ],
      reliefs_on_record: [{ relief: 'gratuity', label: 'Gratuity', amount: 50000 }, { relief: 'rent_paid', label: 'Rent relief', amount: 360000 }],
      assets: [{ number: 'FA-1', name: 'Toyota Corolla', category: 'Motor vehicles', class: '1511', cost: 9500000, first_year: 2024, acquired_on: '2024-03-02', disposed: false },
        { number: 'FA-2', name: 'Office building', category: 'Buildings', class: '1502', cost: 40000000, first_year: 2023, acquired_on: '2023-01-15', disposed: false }],
      files: { statement_of_accounts: 'o/soa.pdf', computation: 'o/p1/comp.pdf' },
    },
    bill: { amount: 500, existing: null, revenue_code: '32102', start_date: '2025-01-01', end_date: '2025-12-31', remark: 'Obi & Co 2025 personal income tax (direct assessment)' },
    request: {},
    ...over,
  };
}
let seq = 0;
function queue(kind: string, ctx: any, person = "p1"): any { const j = { id: `job-${++seq}`, kind, status: 'queued', context: ctx, person }; counta.jobs.push(j); return j; }
const run = () => runner.tick({ budgetMs: 120_000 });
const reportsOf = (j: any) => counta.reports.filter((r) => r.job_id === j.id);

before(async () => {
  mock = await startMock();
  st = mock.state;
  sign = await import('../src/sign.js');
  counta = await startCounta();
  Object.assign(process.env, { COUNTA_BOT_URL: `${counta.url}/lirs`, LIRS_BOT_SECRET: SECRET, ETAX_BASE: mock.etaxUrl, LASG_BASE: mock.etaxUrl, ETAX_GAP_MS: '1', NAV_TIMEOUT_MS: '15000',
    COUNTA_RETRY_MS: '50' });
  runner = await import('../src/runner.js');
  st.accounts.push({ payerId: 'N-16000001', password: PASSWORD, tp: 9550001, ind: 10620001, first: 'Ada', last: 'Obi', office: 501 });
  st.accounts.push({ payerId: 'N-16000002', password: 'other-pass-1', tp: 9550002, ind: 10620002, first: 'Bayo', last: 'Ade', office: 502 });
  st.accounts.push({ payerId: 'N-16000003', password: 'reset-me-123', tp: 9550003, ind: 10620003, first: 'Chi', last: 'Eze', office: 501, reset: true });
  st.accounts.push({ payerId: 'N-16000004', password: 'no-office-123', tp: 9550004, ind: 10620004, first: 'Dan', last: 'Uzo', office: 503 });
  for (const [p, t] of [['o/soa.pdf', 'Statement of accounts'], ['o/p1/comp.pdf', 'Computation'], ['o/p1/rsa.pdf', 'RSA'], ['o/p1/policy1.pdf', 'Policy page 1'], ['o/p1/receipt.pdf', 'Receipt'], ['o/p2/comp.pdf', 'Comp 2']] as const) {
    counta.files.set(p, await pdf(t));
  }
  counta.files.set('o/p1/policy2.png', PNG); counta.files.set('o/p1/cert.png', PNG);
});
after(async () => { await mock.close(); counta.close(); });

test('files the return as the taxpayer, then raises the bill in the same session', async () => {
  const f = queue('file', context());
  const b = queue('bill', context());
  const out = await run();
  assert.equal(out.ran.length, 2, JSON.stringify(out));
  assert.equal(f.status, 'done', f.error);
  assert.equal(b.status, 'done', b.error);
  assert.equal(st.logins, 1, 'one sign-in for both jobs');
  const r = st.returns.find((x) => x.tax_payer_id === 9550001);
  assert.equal(r.status_id, '7');
  assert.equal(f.result.return_id, String(r.id));
  // The statement of income: Counta's figures as e-Tax's strings, other income adding up to its lines.
  assert.deepEqual(r.soi.data, { salary: '2400000.00', commission: '1500000.00', trade_income: '5000000.00', allowance: 0, pension: 0, annuity: 0, gratuities: '800000.00',
    foreign_income: 0, dividend: '120000.00', interest: 0, rent: 0, others: '300000.00' });
  assert.deepEqual(r.soi.breakdowns, [{ name: 'Royalties, Book', amount: 300000 }]);
  // Documents: both PDFs, labelled, with the label after the file as the screen sends it.
  assert.deepEqual(r.return_documents.map((d: any) => d.label), ['Statement of accounts 2025', 'Income tax computation 2025']);
  assert.equal(r.return_documents[0].order, 'type_code,year,tax_payer_id,file,label');
  // A tenant who moved in before the year: the year's dates, the landlord as owner.
  const a = r.accommodations[0];
  assert.equal(a.accommodation_user_type_id, 1); assert.equal(a.started_at, '2025-01-01'); assert.equal(a.ended_at, '2025-12-31');
  assert.equal(a.rent_paid, '1800000.00'); assert.equal(a.owner_name, 'Mr Landlord'); assert.equal(a.owner_tax_payer_number, 'N-12345678');
  assert.equal(a.individual_id, 10620001); assert.equal(a.accommodation_type, 'Flat or apartment');
  // Staff on the profile.
  assert.deepEqual(st.relations.filter((x) => x.tax_payer_id === 9550001).map((x) => [x.type_id, x.form_data.data.fullName, x.form_data.data.incomePaid]), [[19, 'Musa Bello', 720000]]);
  assert.deepEqual(st.links.filter((x) => x.tax_payer_id === 9550001).map((x) => [x.type_id, x.relation_tax_payer.reg_no]), [[20, 'N-22223333']]);
  // Assets: the building as real estate, the car as "Others" (no made-up make or model).
  assert.deepEqual(r.assets.map((x: any) => [x.asset_type_id, x.form_data.data]), [
    [5, { dateOfPurchase: '2024-03-02', address: '12 Admiralty Way, Lekki', costOfAcquisition: 9500000 }],
    [3, { address: '12 Admiralty Way, Lekki', dateOfAcquisition: '2023-01-15', valueOfProperty: 40000000 }]]);
  // Reliefs with their evidence; the two policy files went up as one PDF.
  const rel = Object.fromEntries(r.reliefs.map((x: any) => [x.type_id, x.data]));
  assert.equal(rel[3].retirementSavingsAccount, 'PEN100012345678'); assert.equal(rel[3].totalContribution, 240000);
  assert.match(rel[3].rsaStatementForYear, /^https:\/\/lirs-docs/);
  assert.equal(rel[1].nameOfCompany, 'Leadway Assurance'); assert.equal(rel[1].premiumPayment, 150000);
  const policy = st.docs.find((d) => d.url === rel[1].policyDocument);
  assert.equal(policy.kind, 'pdf', 'two files for one field become one PDF');
  assert.equal(st.docs.find((d) => d.url === rel[1].certificateOfPremium).type, 'image/png', 'a single picture goes as it is');
  // Steps reported, the login marked as working, gratuity and rent relief kept on record only.
  const steps = reportsOf(f).filter((x) => x.step).map((x) => x.step);
  assert.deepEqual(steps, ['signed_in', 'documents', 'statement_of_income', 'accommodation', 'support_staff', 'assets', 'reliefs', 'confirmed']);
  assert.equal(reportsOf(f).find((x) => x.step === 'signed_in').login, 'verified');
  assert.match(reportsOf(f).find((x) => x.step === 'reliefs').note, /Gratuity and Rent relief counted in Counta's computation/);
  // The bill: Lekki II from the profile, Direct Assessment, the person as recipient.
  const bill = st.bills.find((x) => x.tax_payer_id === 9550001);
  assert.equal(bill.agency_code, '13086'); assert.equal(bill.revenue_code, '32102'); assert.equal(bill.amount_due, 500);
  assert.equal(b.result.reference, bill.system_reference); assert.equal(b.result.agency, 'Lekki II Tax Stattion');
  assert.deepEqual(reportsOf(b).find((x) => x.done).tax_station, { code: '13086', name: 'Lekki II Tax Stattion' });
  // Signed out at the end.
  assert.equal(st.sessions.size, 0);
  // The password never left the bot.
  assert.ok(!JSON.stringify(counta.reports).includes(PASSWORD));
});

test('fetches the transfer account from the payments page, and sees the payment', async () => {
  const bill = st.bills.find((x) => x.tax_payer_id === 9550001);
  const ctx = context({ bill: { amount: 500, existing: { reference: bill.system_reference, amount: 500 } } });
  const p = queue('pay_account', ctx);
  await run();
  assert.equal(p.status, 'done', p.error);
  assert.equal(p.result.account_number, '9912345678');
  assert.equal(p.result.bank_name, 'Flutterwave MFB');
  assert.equal(p.result.amount, 505);
  assert.equal(p.result.fee, 5);
  assert.ok(p.result.expires_at && Date.parse(p.result.expires_at) > Date.now() + 30 * 60_000, p.result.expires_at);
  const c = st.charges.at(-1);
  assert.equal(c.payment_method, 'bank-transfer'); assert.equal(c.email, 'books@obi.test'); assert.equal(c.phone_number, '+2348031234567');
  assert.equal(st.logins, 1, 'the payments page needs no e-Tax sign-in');
  // Not paid yet.
  const s1 = queue('status', ctx); await run();
  assert.equal(s1.status, 'done'); assert.equal(s1.result.paid, false);
  // Asking again resets the payment the page holds and gives a fresh account.
  const p2 = queue('pay_account', ctx); await run();
  assert.equal(p2.status, 'done', p2.error); assert.equal(st.charges.length, 2);
  // Paid.
  st.invoices.get(bill.system_reference).status = 'paid';
  const s2 = queue('status', ctx); await run();
  assert.equal(s2.result.paid, true); assert.equal(s2.result.reference, bill.system_reference);
  const p3 = queue('pay_account', ctx); await run();
  assert.equal(p3.status, 'done'); assert.equal(p3.result.paid, true);
});

test('a second run changes nothing and adds nothing twice', async () => {
  // e-Tax shows the return confirmed, and Counta knows it as its own: done at once.
  const r = st.returns.find((x) => x.tax_payer_id === 9550001);
  const j = queue('file', context({ portal: { return_id: String(r.id) } }));
  const calls = st.calls.length;
  await run();
  assert.equal(j.status, 'done'); assert.equal(j.result.return_id, String(r.id));
  assert.ok(st.calls.length - calls <= 4, 'only reads');
  // Confirmed by someone else: refused, not retried.
  const k = queue('file', context());
  await run();
  assert.equal(k.status, 'failed'); assert.equal(k.retry, false); assert.match(k.error, /already confirmed/);
});

test('picks up where it stopped when e-Tax ends the session part way', async () => {
  st.accounts[1].password = 'other-pass-1';
  const ctx = context({ login: { payer_id: 'N-16000002', password: 'other-pass-1' }, taxpayer: { person_id: 'p2', name: 'Bayo Ade', role: 'active', authority: 'SIRS:LA' } });
  ctx.return.files.computation = 'o/p2/comp.pdf';
  ctx.return.accommodation = { address: '7 Allen Avenue, Ikeja', type: 'duplex', occupancy: 'owner', started_on: '2025-03-01', ended_on: '2025-10-31' };
  // A stray relief already on the draft return, which Counta does not claim.
  st.returns.push({ id: 77001, tax_payer_id: 9550002, year: 2025, status_id: '1', accommodations: [], return_documents: [], reliefs: [{ id: 77002, return_id: 77001, type_id: 2, status_id: 1, data: { amount: 1, policyDocument: 'x' } }] });
  st.faults.killAfter = 14; // e-Tax ends the session in the middle of the reliefs
  const j = queue('file', ctx, 'p2');
  await run();
  assert.equal(j.status, 'done', j.error);
  const r = st.returns.find((x) => x.id === 77001);
  assert.equal(r.status_id, '7');
  assert.equal(st.relations.filter((x) => x.tax_payer_id === 9550002).length, 1, 'staff not added twice');
  assert.equal(r.return_documents.length, 2, 'documents not added twice');
  assert.equal(r.reliefs.filter((x: any) => x.status_id === 1).length, 2, 'reliefs not added twice');
  assert.equal(r.reliefs.find((x: any) => x.id === 77002).status_id, 3, 'the relief Counta does not claim came off');
  // The owner's own home: Landlord, the person as owner, rent "0.00", the dates as entered.
  const a = r.accommodations[0];
  assert.deepEqual([a.accommodation_user_type_id, a.rent_paid, a.owner_name, a.owner_tax_payer_number, a.started_at, a.ended_at], [2, '0.00', 'Bayo Ade', 'N-16000002', '2025-03-01', '2025-10-31']);
  // A partner's return leaves out the partnership's assets.
  assert.equal((r.assets || []).length, 0);
  assert.ok(reportsOf(j).some((x) => x.step === 'signed_in_again'));
});

test('a wrong password or a password e-Tax wants changed stops at once', async () => {
  const j = queue('file', context({ login: { payer_id: 'N-16000001', password: 'wrong-one-123' } }));
  await run();
  assert.equal(j.status, 'failed'); assert.equal(j.retry, false);
  assert.equal(reportsOf(j).find((x) => x.login).login, 'failed');
  assert.match(reportsOf(j).find((x) => x.login).login_message, /Invalid Payer ID or password/);
  const k = queue('bill', context({ login: { payer_id: 'N-16000003', password: 'reset-me-123' } }));
  await run();
  assert.equal(k.status, 'failed'); assert.equal(k.retry, false); assert.match(k.error, /new password/);
  assert.ok(!JSON.stringify(counta.reports).includes('reset-me-123'));
});

test('a tax station it cannot place, and e-Tax errors worth another try', async () => {
  const j = queue('bill', context({ login: { payer_id: 'N-16000004', password: 'no-office-123' }, taxpayer: { name: 'Dan Uzo' } }));
  await run();
  assert.equal(j.status, 'failed'); assert.equal(j.retry, false); assert.match(j.error, /Badagry/);
  st.faults.internal = 'tax/bills';
  const k = queue('bill', context({ login: { payer_id: 'N-16000004', password: 'no-office-123', tax_station: '13001' } }));
  await run();
  assert.equal(k.status, 'retry'); assert.match(k.error, /internal error/);
  const k2 = queue('bill', context({ login: { payer_id: 'N-16000004', password: 'no-office-123', tax_station: '13001' } }));
  await run();
  assert.equal(k2.status, 'done', k2.error); assert.equal(k2.result.agency, 'Ikeja Tax Station');
  // A bill already raised is used again, not raised twice.
  const before = st.bills.length;
  const k3 = queue('bill', context({ login: { payer_id: 'N-16000004', password: 'no-office-123', tax_station: '13001' } }));
  await run();
  assert.equal(k3.status, 'done'); assert.equal(st.bills.length, before); assert.equal(k3.result.reference, k2.result.reference);
});

// A login checked when it is saved: no year, no return, only who the account is and where its tax station is.
const checkCtx = (login: any, name: string) => ({ login: { tax_station: null, tax_station_name: null, ...login }, taxpayer: { person_id: 'p9', name, authority: 'SIRS:LA' },
  year: null, yoa: null, org: { name: 'Obi & Co' }, portal: {}, return: null, bill: null, request: { login_saved_at: '2026-11-05T00:00:00Z' } });

test('checks a login as soon as it is saved, and changes nothing on e-Tax', async () => {
  const logins = st.logins, calls = st.calls.length, bills = st.bills.length, returns = st.returns.length, sessions = st.sessions.size;
  const j = queue('check', checkCtx({ payer_id: 'n-16000001', password: PASSWORD }, 'Ada Obi'));
  await run();
  assert.equal(j.status, 'done', j.error);
  assert.deepEqual(j.result, { payer_id: 'N-16000001', name: 'Ada Obi', name_matches: true, tax_station: { code: '13086', name: 'Lekki II Tax Stattion' }, warning: null });
  assert.equal(st.logins, logins + 1);
  assert.equal(reportsOf(j).find((x) => x.step === 'signed_in').login, 'verified');
  assert.deepEqual(reportsOf(j).find((x) => x.done).tax_station, { code: '13086', name: 'Lekki II Tax Stattion' });
  assert.match(reportsOf(j).find((x) => x.step === 'checked').note, /Ada Obi, tax station Lekki II Tax Stattion\. Nothing on e-Tax was changed/);
  const made = st.calls.slice(calls).filter((x) => x.resource !== 'auth/logout');
  assert.ok(made.length && made.every((x) => x.method === 'GET'), `only reads: ${JSON.stringify(made)}`);
  assert.equal(st.bills.length, bills); assert.equal(st.returns.length, returns);
  assert.equal(st.sessions.size, sessions, 'signed out');
  assert.ok(!JSON.stringify(counta.reports).includes(PASSWORD));
});

test('a login in another name, or with no tax station Counta can place, is kept with a warning', async () => {
  const j = queue('check', checkCtx({ payer_id: 'N-16000004', password: 'no-office-123' }, 'Ngozi Okafor'));
  await run();
  assert.equal(j.status, 'done', j.error);
  assert.equal(j.result.name, 'Dan Uzo'); assert.equal(j.result.name_matches, false); assert.equal(j.result.tax_station, null);
  assert.match(j.result.warning, /in the name Dan Uzo\. Make sure it is Ngozi Okafor's own login\./);
  assert.match(j.result.warning, /tax station "Badagry/);
  assert.equal(reportsOf(j).find((x) => x.login).login, 'verified');
  assert.ok(!reportsOf(j).find((x) => x.done).tax_station);
});

test('a login e-Tax refuses is marked as not working, and not tried again', async () => {
  const j = queue('check', checkCtx({ payer_id: 'N-16000002', password: 'not-the-password' }, 'Bayo Ade'));
  await run();
  assert.equal(j.status, 'failed'); assert.equal(j.retry, false);
  const l = reportsOf(j).find((x) => x.login);
  assert.equal(l.login, 'failed'); assert.match(l.login_message, /Invalid Payer ID or password/);
  // One report carries both, so the login is never left showing "checking" when one of two reports is lost.
  assert.equal(reportsOf(j).filter((x) => x.login).length, 1); assert.equal(l.failed, true); assert.equal(l.retry, false);
  assert.ok(!JSON.stringify(counta.reports).includes('not-the-password'));
});

test('Counta busy for a moment: the claim and the reports are tried again, and the result arrives', async () => {
  const j = queue('check', checkCtx({ payer_id: 'N-16000002', password: 'other-pass-1' }, 'Bayo Ade'));
  counta.busy.next = 1;
  const before = st.logins;
  await run();
  assert.equal(j.status, 'done', j.error);
  const k = queue('check', checkCtx({ payer_id: 'N-16000002', password: 'not-the-password' }, 'Bayo Ade'));
  counta.busy.report = 2;
  await run();
  assert.equal(k.status, 'failed'); assert.equal(reportsOf(k).find((x) => x.failed).login, 'failed');
  assert.equal(st.logins, before + 1, 'the refused password is tried once');
});

test('e-Tax asks which kind of login it is: the bot chooses Taxpayer', async () => {
  st.faults.chooser = true;
  try {
    const j = queue('check', checkCtx({ payer_id: 'N-16000002', password: 'other-pass-1' }, 'Bayo Ade'));
    await run();
    assert.equal(j.status, 'done', j.error);
    assert.equal(reportsOf(j).find((x) => x.login).login, 'verified');
  } finally { st.faults.chooser = false; }
});

test('the door: only signed calls start a tick', async () => {
  const { verify, sign: s } = sign;
  const raw = '{"reason":"test"}';
  assert.ok(verify(raw, s(raw, SECRET), SECRET));
  assert.ok(!verify(raw, s(raw, 'another-secret-0123456789abcdefghijkl'), SECRET));
  assert.ok(!verify(raw, s(raw, SECRET, Math.floor(Date.now() / 1000) - 600), SECRET), 'old signatures are refused');
  assert.ok(!verify(raw + ' ', s(raw, SECRET), SECRET));
});

test('the server: health, signatures, an answer at once, or the result when asked to wait', async () => {
  const port = 54000 + Math.floor(Math.random() * 900);
  const child = spawn(process.execPath, [new URL('../src/server.js', import.meta.url).pathname], {
    env: { ...process.env, PORT: String(port), COUNTA_BOT_URL: `${counta.url}/lirs`, LIRS_BOT_SECRET: SECRET, ETAX_BASE: mock.etaxUrl, LASG_BASE: mock.etaxUrl, ETAX_GAP_MS: '1' },
    stdio: ['ignore', 'pipe', 'pipe'] });
  try {
    const base = `http://127.0.0.1:${port}`;
    for (let i = 0; i < 50; i++) { try { if ((await fetch(`${base}/health`)).ok) break; } catch { /* starting */ } await new Promise((r) => setTimeout(r, 100)); }
    assert.deepEqual(await (await fetch(`${base}/health`)).json(), { ok: true, busy: false });
    assert.equal((await fetch(`${base}/tick`, { method: 'POST', body: '{}' })).status, 401);
    assert.equal((await fetch(`${base}/nothing`)).status, 404);
    const post = (body: unknown) => { const raw = JSON.stringify(body); return fetch(`${base}/tick`, { method: 'POST', body: raw, headers: { 'x-counta-signature': sign.sign(raw, SECRET) } }); };
    const a = await post({ reason: 'test' });
    assert.equal(a.status, 202); assert.deepEqual(await a.json(), { ok: true, started: true });
    await new Promise((r) => setTimeout(r, 500));
    const j = queue('status', context({ bill: { amount: 500, existing: { reference: st.bills[0].system_reference, amount: 500 } } }));
    const b = await (await post({ wait: true })).json();
    assert.equal(b.ok, true); assert.ok(b.ran.some((x: any) => x.job_id === j.id && x.status === 'done'), JSON.stringify(b));
  } finally { child.kill(); }
});
