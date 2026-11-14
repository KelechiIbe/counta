// Stand-ins for Supabase (port 54401) and Flutterwave (port 54402) for relay/test/audits_e2e.sh. Like the live account, the
// Flutterwave stand-in refuses subaccount calls from any address but the relay's (scenario flwDirect "blocked").
import http from 'node:http';
const SECRETS = { FLW_SECRET_KEY: 'FLWSECK_TEST-abc123', FLW_RELAY_URL: 'http://127.0.0.1:54403', FLW_RELAY_SECRET: 'b'.repeat(64) };
let scen = { sub: 'new', flwDirect: 'blocked', flwPost: 'ok' };
let saves = [], flwLog = [];
const read = (req) => new Promise((r) => { const p = []; req.on('data', (c) => p.push(c)); req.on('end', () => r(Buffer.concat(p).toString())); });
const send = (res, s, b) => { const t = JSON.stringify(b); res.writeHead(s, { 'Content-Type': 'application/json' }); res.end(t); };
const ctx = () => ({
  practice: { id: '11111111-1111-1111-1111-111111111111', name: 'Okafor & Co', email: 'firm@example.test', phone: '0803 555 0142' },
  bank: { bank_code: '058', account_number: '0011223344', account_name: 'OKAFOR AND CO', name_match: true },
  subaccount: scen.sub === 'move' ? { ref: 'RS_OLD', num: 2181, bank: '058', account: '0099887766', status: 'ready' } : { status: 'none' },
  referral_rate: 0.1,
});
http.createServer(async (req, res) => {
  const body = await read(req);
  if (req.url === '/__scenario') { scen = { ...scen, ...JSON.parse(body) }; saves = []; flwLog = []; return send(res, 200, scen); }
  if (req.url === '/__log') return send(res, 200, { saves, flw: flwLog });
  if (req.url.startsWith('/auth/v1/user')) return send(res, 200, { id: 'u1', aud: 'authenticated', email: 'partner@example.test', phone: '' });
  const m = req.url.match(/^\/rest\/v1\/rpc\/(\w+)/);
  if (!m) return send(res, 404, { message: 'nope' });
  const a = body ? JSON.parse(body) : {};
  switch (m[1]) {
    case 'svc_secret': return send(res, 200, SECRETS[a.p_name] ?? null);
    case 'app_secret': return send(res, 200, null);
    case 'practice_audit_flutterwave_check': return send(res, 200, null);
    case 'svc_audit_subaccount': return send(res, 200, ctx());
    case 'svc_audit_subaccount_save': saves.push(a.p); return send(res, 200, null);
    case 'practice_audit': return send(res, 200, { ok: true });
    default: return send(res, 404, { message: 'unknown rpc ' + m[1] });
  }
}).listen(54401, '127.0.0.1');
http.createServer(async (req, res) => {
  const body = await read(req);
  const via = String(req.headers['user-agent'] || '').startsWith('counta-relay/') ? 'relay' : 'direct';
  flwLog.push({ via, method: req.method, path: req.url, auth: req.headers.authorization, body: body ? JSON.parse(body) : null });
  if (via === 'direct' && scen.flwDirect === 'blocked') return send(res, 400, { status: 'error', message: 'Please enable IP Whitelisting to access this service', data: null });
  const u = new URL(req.url, 'http://x');
  if (req.method === 'POST' && u.pathname === '/v3/subaccounts') {
    if (scen.flwPost === 'exists') return send(res, 400, { status: 'error', message: 'A subaccount with the account number and bank already exists', data: null });
    return send(res, 200, { status: 'success', data: { id: 3001, subaccount_id: 'RS_NEW' } });
  }
  if (req.method === 'GET' && u.pathname === '/v3/subaccounts') return send(res, 200, { status: 'success',
    data: [{ id: 2999, subaccount_id: 'RS_EARLIER', account_bank: u.searchParams.get('account_bank'), account_number: u.searchParams.get('account_number') }] });
  if (req.method === 'PUT' && u.pathname === '/v3/subaccounts/2181') return send(res, 200, { status: 'success', data: { id: 2181, subaccount_id: 'RS_OLD' } });
  return send(res, 404, { status: 'error', message: 'No such route' });
}).listen(54402, '127.0.0.1');
console.log('fakes up');
