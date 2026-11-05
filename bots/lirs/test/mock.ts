// A stand-in for LIRS e-Tax, the Lagos State payments page and Flutterwave's checkout, built from what the live
// portal did on 4 November 2026 and from e-Tax's own screen code. It is strict where e-Tax was strict: one session per
// account, NO_AUTH (and the end of the session) for a call the taxpayer screens do not make, unencoded params, PDFs only
// for the return's documents, "0.00" for an owner's rent, every relief field required.
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { randomBytes } from 'node:crypto';

type Acc = { payerId: string; password: string; tp: number; ind: number; first: string; last: string; office: number | null; reset?: boolean; corporate?: boolean };
export type State = ReturnType<typeof fresh>;
function fresh() {
  return {
    accounts: [] as Acc[],
    sessions: new Map<string, { tp: number; at: number }>(),
    current: new Map<number, string>(), // taxpayer -> the one live session
    csrf: new Map<string, string>(), // _csrf cookie -> token
    logins: 0,
    calls: [] as { resource: string; method: string; tp?: number }[],
    returns: [] as any[],
    docs: [] as any[], // relief files kept on "S3"
    relations: [] as any[],
    links: [] as any[],
    bills: [] as any[],
    invoices: new Map<string, any>(), // LASG invoices by bill reference
    charges: [] as any[],
    faults: {} as { killAfter?: number; internal?: string; offices?: Record<string, any>; chooser?: boolean },
    ids: 1000,
  };
}
export const AGENCIES = [
  { AgencyRef: '01', FullName: 'Lekki I Tax Station', orcAgency2: '13085', HeadRef: 'H1' },
  { AgencyRef: '02', FullName: 'Lekki II Tax Stattion', orcAgency2: '13086', HeadRef: 'H2' },
  { AgencyRef: '03', FullName: 'Ikeja Tax Station', orcAgency2: '13001', HeadRef: 'H3' },
  { AgencyRef: '04', FullName: 'Ikeja GRA Tax Station', orcAgency2: '13002', HeadRef: 'H4' },
];
const REVENUES = [{ RevCode: '4010001', RevName: 'PAYE', orcRev: '32101' }, { RevCode: '4010002', RevName: 'Direct Assessment', orcRev: '32102' }];
const OFFICES: Record<string, any> = { 501: { id: 501, name: 'Lekki II' }, 502: { id: 502, name: 'Ikeja' }, 503: { id: 503, name: 'Badagry' } };
const ok = (res: ServerResponse, body: unknown, status = 200, headers: Record<string, string> = {}) => {
  res.writeHead(status, { 'Content-Type': 'application/json', ...headers }); res.end(JSON.stringify(body));
};
const err = (res: ServerResponse, code: string, message: string) => ok(res, { status: 'error', code, message, error: true });
const html = (res: ServerResponse, body: string) => { res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' }); res.end(body); };
const cookies = (req: IncomingMessage) => Object.fromEntries(String(req.headers.cookie || '').split(';').map((c) => c.trim().split('=')).filter((x) => x[0]).map(([k, ...v]) => [k, v.join('=')]));
async function bodyOf(req: IncomingMessage) { const c: Buffer[] = []; for await (const x of req) c.push(x as Buffer); return Buffer.concat(c); }

// multipart/form-data, by hand (fields as text, the file as bytes).
function multipart(raw: Buffer, type: string) {
  const b = type.match(/boundary=(?:"([^"]+)"|([^;]+))/); if (!b) return null;
  const boundary = Buffer.from('--' + (b[1] || b[2]));
  const out: { fields: Record<string, string>; order: string[]; file?: { name: string; type: string; bytes: Buffer } } = { fields: {}, order: [] };
  let at = raw.indexOf(boundary);
  while (at >= 0) {
    const next = raw.indexOf(boundary, at + boundary.length);
    if (next < 0) break;
    const part = raw.subarray(at + boundary.length + 2, next - 2);
    const sep = part.indexOf('\r\n\r\n');
    const head = part.subarray(0, sep).toString('utf8'), data = part.subarray(sep + 4);
    const name = head.match(/name="([^"]*)"/)?.[1] || '';
    const filename = head.match(/filename="([^"]*)"/)?.[1];
    out.order.push(name);
    if (filename !== undefined) out.file = { name: filename, type: head.match(/Content-Type:\s*([^\r\n]+)/i)?.[1] || '', bytes: Buffer.from(data) };
    else out.fields[name] = data.toString('utf8');
    at = next;
  }
  return out;
}
function parseParams(p: string) {
  const out: Record<string, any> = {};
  for (const part of String(p || '').split('&')) {
    if (!part) continue;
    const i = part.indexOf('='); const k = part.slice(0, i), v = part.slice(i + 1);
    try { out[k] = ['filters', 'embeds'].includes(k) ? JSON.parse(v) : v; } catch { out[k] = v; }
  }
  return out;
}
const filterVal = (filters: any[], field: string) => (filters || []).find((f) => f.field === field)?.value;
const money = (v: unknown) => Number(String(v ?? '').replace(/,/g, ''));

// With the chooser (as e-Tax shows now), the page signs in as the login type ticked, a tax agent's unless Taxpayer is chosen.
const CHOOSER = `<div class="md-radio md-checked"><div class="md-radio-container"><input type="radio" id="lt-agent" name="lt" value="agents" checked
  style="position:absolute;opacity:0;width:0;height:0"></div><label for="lt-agent" class="md-radio-label">Tax Agent</label></div>
<div class="md-radio"><div class="md-radio-container"><input type="radio" id="lt-payer" name="lt" value="payers" style="position:absolute;opacity:0;width:0;height:0"></div>
<label for="lt-payer" class="md-radio-label">Taxpayer</label></div>`;
const LOGIN_PAGE = (api: string, chooser = false) => `<!doctype html><html><head><title>e-Tax | LIRS</title></head><body><div id="app">
<form id="f">${chooser ? CHOOSER : ''}<input type="text" placeholder="There should be a prefix 'N-' or 'C-'" id="identifier"><input type="password" id="password">
<button type="submit" class="md-button md-success">Login</button></form><div id="msg"></div></div>
<script>
let token = '';
document.cookie = '_csrf=;';
setTimeout(() => fetch('${api}get_csrf').then(r => r.json()).then(j => { token = j.csrfToken; }), 300);
document.getElementById('f').addEventListener('submit', async (e) => {
  e.preventDefault();
  const lt = document.querySelector('input[name="lt"]:checked');
  const r = await fetch('${api}auth/local/' + (lt ? lt.value : 'payers') + '/authenticate', { method: 'POST', credentials: 'include',
    headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest', 'x-csrf-token': token },
    body: JSON.stringify({ method: 'POST', body: { identifier: document.getElementById('identifier').value.trim(), password: document.getElementById('password').value.trim() } }) });
  const j = await r.json();
  if (j.error) { document.getElementById('msg').textContent = j.message; return; }
  sessionStorage.setItem('user', JSON.stringify(j));
  history.pushState({}, '', '/user/profile');
  document.getElementById('app').innerHTML = '<h1>Profile</h1>';
});
</script></body></html>`;

const LASG_PAGE = `<!doctype html><html><head><title>LASG Payments</title></head><body><div id="root">Loading</div>
<script>
const q = new URLSearchParams(location.search); const ref = q.get('bill_type') || '';
let inv = null;
async function load() { const r = await fetch('/api/get-invoice?reference=' + encodeURIComponent(ref)); const j = await r.json(); inv = j && j.data; render(); }
function render() {
  const root = document.getElementById('root');
  if (!inv || inv.error) { root.innerHTML = '<h1>Error</h1><p>This bill cannot be processed on this platform at the moment</p>'; return; }
  const head = '<h1>Lagos State Government</h1><span>TAX PAYMENT</span><div>Bill Reference</div><div>' + inv.bill_reference + '</div><div>Name</div><div>' + inv.payer_name + '</div>';
  if (inv.status === 'paid') { root.innerHTML = head + '<h2>Payment successfully completed</h2><button>Download receipt</button><button>Send receipt</button>'; return; }
  if (inv.status === 'pending-payment') { root.innerHTML = head + '<div>Status</div><div>pending-payment</div><button id="reset">Reset Payment</button>';
    document.getElementById('reset').onclick = async () => { await fetch('/api/requery-charge', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({ reference: ref, reset: true }) }); await load(); }; return; }
  root.innerHTML = head + '<div>Amount to pay</div><input name="amount" value="' + inv.amount_to_pay.toFixed(2) + '" readonly>'
    + '<input name="email" placeholder="Email address"><div>+234<input name="phone_number" placeholder="Phone Number"></div><button id="pay">Make Payment</button><div id="modal"></div>';
  document.getElementById('pay').onclick = () => {
    const email = document.querySelector('input[name=email]').value; if (!email) return;
    const fee = inv.fee.provider_fee.card_fee;
    document.getElementById('modal').innerHTML = '<h3>Payment Options</h3><label><input type="radio" name="opt" value="card" checked>Card</label>'
      + '<label><input type="radio" name="opt" value="banktransfer"><span>Bank transfer</span></label><label><input type="radio" name="opt" value="ussd">USSD</label>'
      + '<div>Payment Amount</div><div>₦' + inv.amount_to_pay.toFixed(2) + '</div><div>Processing fee</div><div>+₦' + fee.toFixed(2) + '</div>'
      + '<div>Total Amount</div><div>+₦' + (inv.amount_to_pay + fee).toFixed(2) + '</div><button id="go">Proceed to pay</button>';
    document.getElementById('go').onclick = async () => {
      const opt = document.querySelector('input[name=opt]:checked').value;
      const phone = document.querySelector('input[name=phone_number]').value;
      const r = await fetch('/api/create-charge', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({ invoice_id: inv.id, amount: inv.amount_to_pay, email,
        payment_method: opt === 'banktransfer' ? 'bank-transfer' : opt, ...(phone ? { phone_number: '+234' + phone } : {}) }) });
      const c = await r.json();
      const f = document.createElement('iframe'); f.src = FLW + '/checkout?tx_ref=' + c.reference + '&amount=' + c.charge_amount + '&options=' + opt; f.style.width = '420px'; f.style.height = '600px';
      document.body.appendChild(f);
    };
  };
}
load();
</script></body></html>`;

const FLW_PAGE = `<!doctype html><html><body><div id="c">Loading checkout</div><script>
const q = new URLSearchParams(location.search);
fetch('/v3/sdkcheckout/charges?type=bank_transfer', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({ tx_ref: q.get('tx_ref'), amount: q.get('amount') }) })
 .then(r => r.json()).then(j => { const a = j.meta.authorization;
   document.getElementById('c').innerHTML = '<h3>LASG Collection</h3><p>Transfer NGN ' + Number(a.transfer_amount).toFixed(2) + ' to</p><div>Bank name</div><div>' + a.transfer_bank + '</div>'
     + '<div>Account number</div><div>' + a.transfer_account + '</div><div>Beneficiary</div><div>LASG Collection</div><p>Expires in 14:59</p><button>I have made this bank transfer</button>'; });
</script></body></html>`;

export function startMock(opts: { etaxPort?: number; flwPort?: number } = {}) {
  const st = fresh();
  const id = () => ++st.ids;
  let flwUrl = '';
  const relief = (rec: any) => ({ id: rec.id, return_id: rec.return_id, relief_type_id: rec.type_id, status_id: rec.status_id, form_data: { data: rec.data } });
  const RELIEF_FIELDS: Record<number, string[]> = {
    1: ['nameOfCompany', 'policyName', 'premiumPayment', 'policyDocument', 'certificateOfPremium', 'receiptOfPayment'], 2: ['amount', 'policyDocument'],
    3: ['retirementSavingsAccount', 'pensionFundAdministrator', 'totalContribution', 'rsaStatementForYear'], 4: ['retirementSavingsAccount', 'pensionFundAdministrator', 'totalContribution', 'rsaStatementForYear'],
    5: ['amount', 'policyDocument'], 6: ['primaryMortgageInstitution', 'capitalSumonMortgage', 'totalInterestPaidInYear', 'utilityBillForTheResidence', 'bankStatementsReflectingMortgageDeductions'],
  };
  const FILE_FIELDS = new Set(['policyDocument', 'certificateOfPremium', 'receiptOfPayment', 'rsaStatementForYear', 'utilityBillForTheResidence', 'bankStatementsReflectingMortgageDeductions']);
  const ASSET_FIELDS: Record<number, string[]> = { 2: ['dateOfPurchase', 'cost', 'brand', 'model', 'yearOfManufacture'], 3: ['address', 'dateOfAcquisition', 'valueOfProperty'],
    4: ['address', 'dateOfAcquisition', 'costOfAcquisition', 'valueOfLand', 'valueOfProduce'], 5: ['dateOfPurchase', 'address', 'costOfAcquisition'] };
  const view = (r: any) => ({ ...r, accommodations: r.accommodations.map((a: any) => ({ ...a })), return_documents: r.return_documents.map((d: any) => ({ ...d })) });

  async function api(req: IncomingMessage, res: ServerResponse, resource: string) {
    const ck = cookies(req);
    if (resource === 'get_csrf' && req.method === 'GET') {
      const secret = randomBytes(8).toString('hex'), token = 'tok-' + randomBytes(8).toString('hex');
      st.csrf.set(secret, token);
      return ok(res, { csrfToken: token }, 200, { 'Set-Cookie': `_csrf=${secret}; Path=/; HttpOnly` });
    }
    if (req.method !== 'POST') return ok(res, { message: 'Not found' }, 404);
    const raw = await bodyOf(req);
    const type = String(req.headers['content-type'] || '');
    if (req.headers['x-requested-with'] !== 'XMLHttpRequest') return err(res, 'INVALID_INPUT', 'Bad request');
    let w: any = null, mp: ReturnType<typeof multipart> = null;
    if (type.startsWith('multipart/form-data')) mp = multipart(raw, type);
    else { try { w = JSON.parse(raw.toString('utf8')); } catch { return err(res, 'INVALID_INPUT', 'Invalid JSON'); } }
    if (resource === 'auth/local/agents/authenticate') return err(res, 'INVALID_CRED', 'Invalid credentials provided. Please retry');
    if (resource === 'auth/local/payers/authenticate') {
      const tokenOk = ck._csrf && st.csrf.get(ck._csrf) === req.headers['x-csrf-token'];
      if (!tokenOk) return err(res, 'INVALID_INPUT', 'invalid csrf token');
      const b = w?.body || {};
      const a = st.accounts.find((x) => x.payerId.toUpperCase() === String(b.identifier || '').toUpperCase() && x.password === b.password);
      if (!a) return err(res, 'INVALID_CRED', 'Invalid Payer ID or password');
      st.logins++;
      const sid = randomBytes(12).toString('hex');
      const prev = st.current.get(a.tp); if (prev) st.sessions.delete(prev);
      st.sessions.set(sid, { tp: a.tp, at: Date.now() }); st.current.set(a.tp, sid);
      return ok(res, { user: { id: a.tp, entity_id: a.ind, entity_type_id: a.corporate ? 2 : 1, reg_no: a.payerId, entity: { id: a.ind, first_name: a.first, last_name: a.last, nin: '1' } },
        auth_data: { type: 'payers', permissions: a.reset ? { 'auth.updatepassword': true } : { 'returns.view': true }, extra_details: {} } }, 200, { 'Set-Cookie': `etax_sid=${sid}; Path=/; HttpOnly` });
    }
    const s = st.sessions.get(ck.etax_sid || '');
    if (!s) return err(res, 'NO_AUTH', 'Unauthorized');
    const acc = st.accounts.find((x) => x.tp === s.tp)!;
    st.calls.push({ resource, method: w?.method || 'MULTIPART', tp: s.tp });
    if (st.faults.killAfter !== undefined && --st.faults.killAfter < 0) { st.faults.killAfter = undefined; st.sessions.delete(ck.etax_sid); return err(res, 'NO_AUTH', 'Unauthorized'); }
    if (st.faults.internal && resource.startsWith(st.faults.internal)) { st.faults.internal = undefined; return err(res, 'INTERNAL_ERROR', 'Something went wrong'); }
    if (w && typeof w.params === 'string' && /%[0-9A-F]{2}/i.test(w.params)) return err(res, 'INTERNAL_ERROR', 'Internal error');
    const P = w?.method === 'GET' ? parseParams(w.params || '') : {};
    const B = w?.body || {};
    const mine = (r: any) => r && r.tax_payer_id === s.tp;
    const kill = () => { st.sessions.delete(ck.etax_sid); return err(res, 'NO_AUTH', 'Unauthorized'); };
    const refuseIfFiled = (r: any) => (r && r.status_id === '7' ? (err(res, 'INVALID_INPUT', 'Returns already filed'), true) : false);
    let m: RegExpMatchArray | null;

    if (resource === 'touch') return ok(res, { ok: true });
    if (resource === 'auth/logout') { st.sessions.delete(ck.etax_sid); st.current.delete(s.tp); return ok(res, { ok: true }); }
    if ((m = resource.match(/^tax\/payers\/individuals\/(\d+)$/)) && w?.method === 'GET') {
      if (Number(m[1]) !== acc.ind) return kill();
      return ok(res, { id: acc.ind, first_name: acc.first, last_name: acc.last, address: { line: '1 Test Road' }, tax_payer: { id: acc.tp, reg_no: acc.payerId, entity_type_id: acc.corporate ? 2 : 1, preferred_tax_office_id: acc.office } });
    }
    if ((m = resource.match(/^tax\/offices\/(\d+)$/)) && w?.method === 'GET') return ok(res, (st.faults.offices || OFFICES)[m[1]] || { status: 'error', code: 'INVALID_INPUT', message: 'Not found', error: true });
    if (resource === 'tax/returns' && w?.method === 'GET') {
      const tp = Number(filterVal(P.filters, 'tax_payer_id')), year = Number(filterVal(P.filters, 'year'));
      if (tp !== s.tp) return kill();
      return ok(res, { pagination: {}, list: st.returns.filter((r) => r.tax_payer_id === tp && (!year || r.year === year)).map(view) });
    }
    if (resource === 'tax/returns/documents' && mp) {
      const f = mp.fields;
      if (f.type_code !== 'statement_account' || Number(f.tax_payer_id) !== s.tp || !f.year || !f.label) return ok(res, { body: { status: 'error', code: 'INVALID_INPUT', data: { message: 'Missing fields' } } });
      if (!mp.file || mp.file.bytes.subarray(0, 5).toString('latin1') !== '%PDF-') return ok(res, { body: { status: 'error', code: 'INVALID_INPUT', data: { message: 'Only PDF files are allowed' } } });
      let r = st.returns.find((x) => x.tax_payer_id === s.tp && x.year === Number(f.year));
      if (refuseIfFiled(r)) return;
      if (!r) { r = { id: id(), tax_payer_id: s.tp, year: Number(f.year), status_id: '1', soi: null, accommodations: [], return_documents: [] }; st.returns.push(r); }
      r.return_documents.push({ id: id(), label: f.label, status_id: 1, document: { name: mp.file.name, size: mp.file.bytes.length }, order: mp.order.join(',') });
      return ok(res, view(r));
    }
    if (resource === 'tax/returns/individual/extract' && w?.method === 'POST') {
      const keys = ['salary', 'commission', 'trade_income', 'allowance', 'pension', 'annuity', 'gratuities', 'foreign_income', 'dividend', 'interest', 'rent', 'others'];
      if (B.tax_payer_id !== s.tp || !B.year || !B.data || keys.some((k) => !(k in B.data))) return err(res, 'INVALID_INPUT', 'Statement of income is incomplete');
      const others = (B.breakdowns || []).reduce((a: number, x: any) => a + Number(x.amount), 0);
      if (Math.abs(others - money(B.data.others)) > 0.01) return err(res, 'INVALID_INPUT', 'Other income does not add up');
      let r = st.returns.find((x) => x.tax_payer_id === s.tp && x.year === B.year);
      if (refuseIfFiled(r)) return;
      if (!r) { r = { id: id(), tax_payer_id: s.tp, year: B.year, status_id: '1', accommodations: [], return_documents: [] }; st.returns.push(r); }
      r.soi = { data: B.data, breakdowns: B.breakdowns };
      return ok(res, view(r));
    }
    if ((m = resource.match(/^drafts\/(soi|accommodation)-(\d{4})-(\d+)\/remove$/))) { if (Number(m[3]) !== s.tp) return kill(); return ok(res, { ok: true }); }
    if ((resource === 'accommodations' && w?.method === 'POST') || ((m = resource.match(/^accommodations\/(\d+)$/)) && w?.method === 'PUT')) {
      const r = st.returns.find((x) => x.id === B.return_id && mine(x)) || st.returns.find((x) => mine(x) && x.accommodations.some((a: any) => a.id === Number(m?.[1])));
      if (!r) return err(res, 'INVALID_INPUT', 'Unknown return');
      if (refuseIfFiled(r)) return;
      if (B.status_id === 3) { const a = r.accommodations.find((x: any) => x.id === Number(m![1])); if (a) a.status_id = 3; return ok(res, a || {}); }
      const need = ['accommodation_type', 'accommodation_user_type_id', 'address', 'rent_paid', 'started_at', 'ended_at'];
      if (B.accommodation_user_type_id === 2) need.push('owner_name', 'owner_tax_payer_number', 'owner_address');
      for (const k of need) if (!B[k] || !String(B[k]).trim().length) return err(res, 'INVALID_INPUT', `${k} is required`);
      const y = String(r.year);
      if (!String(B.started_at).startsWith(y) || !String(B.ended_at).startsWith(y) || !(B.ended_at > B.started_at)) return err(res, 'INVALID_INPUT', 'Date range is invalid');
      if (B.individual_id !== acc.ind) return err(res, 'INVALID_INPUT', 'Unknown individual');
      if (m) { const a = r.accommodations.find((x: any) => x.id === Number(m![1])); Object.assign(a, B); return ok(res, a); }
      const a = { id: id(), status_id: 1, ...B }; r.accommodations.push(a); return ok(res, a);
    }
    if ((resource === 'tax/payers/relations' || resource === 'tax/payers/relations/links') && w?.method === 'GET') {
      const tp = Number(filterVal(P.filters, 'tax_payer_id')), type = Number(filterVal(P.filters, 'type_id'));
      if (tp !== s.tp) return kill();
      const src = resource.endsWith('links') ? st.links : st.relations;
      return ok(res, { list: src.filter((x) => x.tax_payer_id === tp && (!type || x.type_id === type)) });
    }
    if ((m = resource.match(/^tax\/payers\/(\d+)\/relations(\/links)?$/)) && w?.method === 'POST') {
      if (Number(m[1]) !== s.tp) return kill();
      const t = Number(B.type_id); if (t < 18 || t > 23) return err(res, 'INVALID_INPUT', 'Unknown relation type');
      if (m[2]) {
        if (!/^[NC]-\d+$/.test(String(B.relation_tax_payer_number || ''))) return err(res, 'INVALID_INPUT', 'Payer ID not found');
        const x = { id: id(), tax_payer_id: s.tp, type_id: t, status_id: 1, relation_tax_payer: { reg_no: B.relation_tax_payer_number }, incomePaid: B.incomePaid }; st.links.push(x); return ok(res, x);
      }
      if (!B.data?.fullName || !B.data?.address || !(Number(B.data?.incomePaid) >= 0)) return err(res, 'INVALID_INPUT', 'All Fields are required');
      const x = { id: id(), tax_payer_id: s.tp, type_id: t, status_id: 1, form_data: { data: B.data } }; st.relations.push(x); return ok(res, x);
    }
    if (resource === 'tax/returns/assets' && w?.method === 'GET') {
      const rid = Number(filterVal(P.filters, 'return_id')); const r = st.returns.find((x) => x.id === rid); if (!mine(r)) return kill();
      return ok(res, { list: (r.assets || []).filter((a: any) => a.status_id === 1) });
    }
    if ((m = resource.match(/^tax\/returns\/(\d+)\/assets$/)) && w?.method === 'POST') {
      const r = st.returns.find((x) => x.id === Number(m![1])); if (!mine(r)) return kill(); if (refuseIfFiled(r)) return;
      const need = ASSET_FIELDS[Number(B.type_id)]; if (!need) return err(res, 'INVALID_INPUT', 'Unknown asset type');
      for (const k of need) if (B.data?.[k] === undefined || B.data?.[k] === null || B.data?.[k] === '') return err(res, 'INVALID_INPUT', 'All Fields are required');
      r.assets = r.assets || []; const a = { id: id(), asset_type_id: Number(B.type_id), status_id: 1, form_data: { data: B.data } }; r.assets.push(a); return ok(res, a);
    }
    if (resource === 'documents' && mp) {
      const f = mp.fields;
      if (f.type_code !== 'taxpayer.doc' || f.entity_type_id !== '9' || Number(f.entity_id) !== s.tp || !mp.file) return ok(res, { body: { status: 'error', code: 'INVALID_INPUT', data: { message: 'Bad document' } } });
      const d = { id: id(), url: `https://lirs-docs.s3.mock/${s.tp}/${Date.now()}-${mp.file.name}`, name: f.name, size: mp.file.bytes.length, type: mp.file.type, kind: mp.file.bytes.subarray(0, 5).toString('latin1') === '%PDF-' ? 'pdf' : 'image', tp: s.tp };
      st.docs.push(d); return ok(res, d);
    }
    if (resource === 'tax/returns/relief' && w?.method === 'GET') {
      const rid = Number(filterVal(P.filters, 'return_id')); const r = st.returns.find((x) => x.id === rid); if (!mine(r)) return kill();
      return ok(res, { list: (r.reliefs || []).filter((x: any) => x.status_id === 1).map(relief) });
    }
    const checkRelief = (B: any) => {
      const need = RELIEF_FIELDS[Number(B.type_id)]; if (!need) return 'Unknown relief type';
      for (const k of need) {
        const v = B.data?.[k];
        if (v === undefined || v === null || v === '') return 'All Fields are required';
        if (FILE_FIELDS.has(k) && !st.docs.some((d) => d.url === v && d.tp === s.tp)) return 'Upload the document first';
        if (!FILE_FIELDS.has(k) && ['premiumPayment', 'amount', 'totalContribution', 'capitalSumonMortgage', 'totalInterestPaidInYear'].includes(k) && typeof v !== 'number') return `${k} must be a number`;
      }
      return '';
    };
    if ((m = resource.match(/^tax\/returns\/(\d+)\/relief$/)) && w?.method === 'POST') {
      const r = st.returns.find((x) => x.id === Number(m![1])); if (!mine(r)) return kill(); if (refuseIfFiled(r)) return;
      const bad = checkRelief(B); if (bad) return err(res, 'INVALID_INPUT', bad);
      r.reliefs = r.reliefs || []; const x = { id: id(), return_id: r.id, type_id: Number(B.type_id), status_id: 1, data: B.data }; r.reliefs.push(x); return ok(res, relief(x));
    }
    if ((m = resource.match(/^tax\/returns\/relief\/(\d+)$/)) && w?.method === 'PUT') {
      const r = st.returns.find((x) => mine(x) && (x.reliefs || []).some((y: any) => y.id === Number(m![1]))); if (!r) return err(res, 'INVALID_INPUT', 'Unknown relief');
      if (refuseIfFiled(r)) return;
      const x = r.reliefs.find((y: any) => y.id === Number(m![1]));
      if (B.status_id === 3) { x.status_id = 3; return ok(res, relief(x)); }
      const bad = checkRelief(B); if (bad) return err(res, 'INVALID_INPUT', bad);
      x.type_id = Number(B.type_id); x.data = B.data; return ok(res, relief(x));
    }
    if ((m = resource.match(/^tax\/returns\/(\d+)\/status\/complete$/)) && w?.method === 'POST') {
      const r = st.returns.find((x) => x.id === Number(m![1])); if (!mine(r)) return kill();
      if (!r.soi || !r.accommodations.some((a: any) => a.status_id === 1)) return err(res, 'INVALID_INPUT', 'Statement of income and mandatory disclosure are required');
      r.status_id = '7'; r.confirmed_at = new Date().toISOString(); return ok(res, view(r));
    }
    if (resource === 'abc/agencies/internal' && w?.method === 'GET') return ok(res, AGENCIES);
    if ((m = resource.match(/^abc\/agencies\/revenues\?HeadRef=(.+)$/)) && w?.method === 'GET') return ok(res, AGENCIES.some((a) => a.HeadRef === m![1]) ? REVENUES : []);
    if (resource === 'tax/bills' && w?.method === 'GET') {
      const filters = P.filters || []; if (Number(filterVal(filters, 'tax_payer_id')) !== s.tp) return kill();
      return ok(res, { list: st.bills.filter((b) => b.tax_payer_id === s.tp).slice().reverse() });
    }
    if (resource === 'tax/bills' && w?.method === 'POST') {
      if (B.tax_payer_id !== s.tp || !AGENCIES.some((a) => a.orcAgency2 === B.agency_code) || !REVENUES.some((r) => r.orcRev === B.revenue_code)) return err(res, 'INVALID_INPUT', 'Agency or revenue is invalid');
      if (!B.start_date || !B.end_date || B.end_date < B.start_date) return err(res, 'INVALID_INPUT', 'Dates are invalid');
      if (!(money(B.amount) > 0) || !Array.isArray(B.recipients) || B.recipients[0]?.tax_payer_number !== acc.payerId || Math.abs(Number(B.recipients[0]?.amount) - money(B.amount)) > 0.001) return err(res, 'INVALID_INPUT', 'Recipients are invalid');
      const ref = `1602${String(s.tp).slice(-5)}-${5118000 + st.bills.length}-${600 + st.bills.length}`;
      const b = { id: id(), tax_payer_id: s.tp, system_reference: ref, agency_code: B.agency_code, revenue_code: B.revenue_code, amount_due: money(B.amount), amount_paid: 0, status_id: 25,
        start_date: B.start_date, end_date: B.end_date, remark: B.remark, created_at: new Date().toISOString() };
      st.bills.push(b);
      st.invoices.set(ref, { id: id(), bill_reference: ref, status: 'new', amount_to_pay: money(B.amount), bill_amount: money(B.amount), payer_name: `${acc.first} ${acc.last}`, fee: { provider_fee: { card_fee: 5, ussd_fee: 5 } } });
      return ok(res, b);
    }
    // Anything else is a call the taxpayer screens do not make: like the live portal, it ends the session.
    return kill();
  }

  async function lasg(req: IncomingMessage, res: ServerResponse, url: URL) {
    if (url.pathname === '/tax-confirm') return html(res, LASG_PAGE.replace('FLW + ', `'${flwUrl}' + `));
    if (url.pathname === '/api/get-invoice') { const inv = st.invoices.get(url.searchParams.get('reference') || ''); return inv ? ok(res, { status: true, data: inv }) : ok(res, { error: 'not found' }, 404); }
    const b = JSON.parse((await bodyOf(req)).toString('utf8') || '{}');
    if (url.pathname === '/api/create-charge') {
      const inv = [...st.invoices.values()].find((x) => x.id === b.invoice_id);
      if (!inv || !b.email) return ok(res, { message: 'invalid' }, 400);
      const c = { reference: 'LASG-' + randomBytes(4).toString('hex'), charge_amount: inv.amount_to_pay + 5, payment_method: b.payment_method, email: b.email, phone_number: b.phone_number, bill: inv.bill_reference };
      st.charges.push(c); inv.status = 'pending-payment'; return ok(res, c);
    }
    if (url.pathname === '/api/requery-charge') { const inv = st.invoices.get(b.reference); if (inv && b.reset) inv.status = 'new'; return ok(res, { ok: true }); }
    return ok(res, { message: 'Not found' }, 404);
  }

  const etax = createServer(async (req, res) => {
    try {
      const url = new URL(req.url || '/', 'http://x');
      const p = url.pathname;
      // For browser tests run against the stand-in: add a taxpayer, mark a bill paid on the payments page.
      if (p === '/__account' && req.method === 'POST') { const a = JSON.parse((await bodyOf(req)).toString('utf8')); st.accounts = st.accounts.filter((x) => x.payerId !== a.payerId); st.accounts.push(a); return ok(res, { ok: true }); }
      if (p === '/__pay' && req.method === 'POST') { const b = JSON.parse((await bodyOf(req)).toString('utf8')); const inv = st.invoices.get(b.reference); if (inv) inv.status = 'paid'; return ok(res, { ok: !!inv }); }
      if (p === '/__state') return ok(res, { logins: st.logins, calls: st.calls, returns: st.returns, docs: st.docs, relations: st.relations, links: st.links, bills: st.bills, charges: st.charges, invoices: [...st.invoices.values()], sessions: st.sessions.size });
      if (p.startsWith('/api/v1/')) return await api(req, res, decodeURIComponent(p.slice(8)) + (url.search && p.includes('revenues') ? url.search : ''));
      if (p === '/login') return html(res, LOGIN_PAGE('/api/v1/', !!st.faults.chooser));
      if (p === '/js/google-analytics.js') { res.writeHead(200, { 'Content-Type': 'application/javascript' }); return res.end('window.dataLayer = window.dataLayer || [];'); }
      if (p.startsWith('/user/')) return html(res, '<h1>Profile</h1>');
      if (p === '/tax-confirm' || p.startsWith('/api/')) return await lasg(req, res, url);
      res.writeHead(404); res.end();
    } catch (e) { res.writeHead(500); res.end(String((e as Error).stack)); }
  });
  // Flutterwave's checkout, on another origin as the real one is.
  const flw = createServer(async (req, res) => {
    const url = new URL(req.url || '/', 'http://x');
    if (url.pathname === '/checkout') return html(res, FLW_PAGE);
    if (url.pathname === '/v3/sdkcheckout/charges') {
      const b = JSON.parse((await bodyOf(req)).toString('utf8') || '{}');
      const exp = new Date(Date.now() + 60 * 60_000 + 3600_000).toISOString().slice(0, 19).replace('T', ' ');
      return ok(res, { status: 'success', message: 'Charge initiated', meta: { authorization: { transfer_reference: b.tx_ref, transfer_account: '9912345678', transfer_bank: 'Flutterwave MFB',
        account_expiration: exp, transfer_note: 'LASG Collection', transfer_amount: Number(b.amount), mode: 'banktransfer' } } });
    }
    res.writeHead(404); res.end();
  });
  return new Promise<{ state: State; etaxUrl: string; flwUrl: string; close: () => Promise<void> }>((resolve) => {
    etax.listen(opts.etaxPort || 0, '127.0.0.1', () => {
      flw.listen(opts.flwPort || 0, '127.0.0.1', () => {
        const ep = (etax.address() as any).port, fp = (flw.address() as any).port;
        flwUrl = `http://localhost:${fp}`;
        resolve({ state: st, etaxUrl: `http://127.0.0.1:${ep}`, flwUrl, close: () => new Promise((r) => { etax.close(() => flw.close(() => r())); }) });
      });
    });
  });
}
