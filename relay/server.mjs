// Counta transfer relay: forwards Counta's Flutterwave transfer requests from one fixed IP address.
//
// Flutterwave takes transfer requests (payouts, bulk payments, sweeps and moves between a business's wallets) only from IP
// addresses whitelisted on TaxStreem's account. Counta's server functions run on Supabase, which has no fixed address, so
// they send those requests here and this server, on a machine with a fixed address, passes them on.
//
// Nothing is kept here: no keys at rest (unless RELAY_FLW_KEY is set), no data, no logs of request bodies. Each request is
// signed by Counta with the shared RELAY_SECRET over its time, method, path and body; an unsigned, wrongly signed, stale
// (over five minutes) or repeated request is refused. Only the Flutterwave paths in RELAY_ALLOW are passed on.
//
// Environment:
//   RELAY_SECRET         required; at least 32 characters; the same value as FLW_RELAY_SECRET in Counta's admin portal
//   PORT                 default 8787 (put Caddy or nginx in front for https)
//   HOST                 default 127.0.0.1
//   RELAY_UPSTREAM       default https://api.flutterwave.com/v3
//   RELAY_ALLOW          default ^/(transfers|bulk-transfers)(/|\?|$)   (a regular expression on the path)
//   RELAY_FLW_KEY        optional: Flutterwave's secret key kept here instead of travelling with each request
//   RELAY_LOCAL_ADDRESS  optional: the local address to send from, on a machine with several
//   RELAY_IP_FAMILY      default 4: connect to Flutterwave over IPv4, so requests leave from the whitelisted IPv4 address
//                        (0 lets the system choose, 6 forces IPv6)
//
// Run: node server.mjs   (Node 18 or later, no packages needed)
import http from 'node:http';
import https from 'node:https';
import crypto from 'node:crypto';

const SECRET = process.env.RELAY_SECRET || '';
const PORT = Number(process.env.PORT || 8787);
const HOST = process.env.HOST || '127.0.0.1';
const UPSTREAM = new URL((process.env.RELAY_UPSTREAM || 'https://api.flutterwave.com/v3').replace(/\/$/, ''));
const ALLOW = new RegExp(process.env.RELAY_ALLOW || '^/(transfers|bulk-transfers)(/|\\?|$)');
const OWN_KEY = process.env.RELAY_FLW_KEY || '';
const LOCAL_ADDRESS = process.env.RELAY_LOCAL_ADDRESS || undefined;
const FAMILY = [0, 4, 6].includes(Number(process.env.RELAY_IP_FAMILY ?? 4)) ? Number(process.env.RELAY_IP_FAMILY ?? 4) : 4;
const VERSION = '1';
const MAX_BODY = 1024 * 1024;
const WINDOW_S = 300;

if (SECRET.length < 32) {
  console.error('RELAY_SECRET must be set, at least 32 characters.');
  process.exit(1);
}

// Signatures seen in the last window, so a copied request cannot be sent twice.
const seen = new Map();
function remember(sig) {
  const now = Date.now();
  if (seen.size > 20000) for (const [k, t] of seen) if (now - t > WINDOW_S * 2000) seen.delete(k);
  if (seen.has(sig)) return false;
  seen.set(sig, now);
  return true;
}

function send(res, status, body) {
  const text = JSON.stringify(body);
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(text), 'Cache-Control': 'no-store' });
  res.end(text);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const parts = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > MAX_BODY) { reject(new Error('too_large')); req.destroy(); return; }
      parts.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(parts).toString('utf8')));
    req.on('error', reject);
  });
}

function signedOk(req, method, path, body) {
  const ts = String(req.headers['x-relay-timestamp'] || '');
  const sig = String(req.headers['x-relay-signature'] || '');
  if (!/^\d{9,11}$/.test(ts) || !/^[0-9a-f]{64}$/.test(sig)) return 'unsigned';
  if (Math.abs(Date.now() / 1000 - Number(ts)) > WINDOW_S) return 'stale';
  const want = crypto.createHmac('sha256', SECRET).update(`${ts}\n${method}\n${path}\n${body}`).digest('hex');
  if (!crypto.timingSafeEqual(Buffer.from(want, 'hex'), Buffer.from(sig, 'hex'))) return 'bad_signature';
  if (!remember(sig)) return 'replayed';
  return null;
}

function forward(method, path, body, auth) {
  return new Promise((resolve, reject) => {
    const target = new URL(UPSTREAM.pathname.replace(/\/$/, '') + path, UPSTREAM.origin);
    const lib = target.protocol === 'https:' ? https : http;
    const headers = { Authorization: auth, 'Content-Type': 'application/json', Accept: 'application/json', 'User-Agent': 'counta-relay/' + VERSION };
    if (method !== 'GET') headers['Content-Length'] = Buffer.byteLength(body);
    const r = lib.request(target, { method, headers, localAddress: LOCAL_ADDRESS, family: FAMILY || undefined, timeout: 30000 }, (up) => {
      const parts = [];
      up.on('data', (c) => parts.push(c));
      up.on('end', () => resolve({ status: up.statusCode || 502, text: Buffer.concat(parts).toString('utf8') }));
      up.on('error', reject);
    });
    r.on('timeout', () => r.destroy(new Error('upstream_timeout')));
    r.on('error', reject);
    if (method !== 'GET') r.write(body);
    r.end();
  });
}

const server = http.createServer(async (req, res) => {
  const method = String(req.method || 'GET').toUpperCase();
  const url = req.url || '/';
  try {
    if (url === '/health' && method === 'GET') return send(res, 200, { ok: true, version: VERSION });
    let body = '';
    try { body = method === 'GET' ? '' : await readBody(req); } catch { return send(res, 413, { status: 'error', message: 'Request too large.' }); }
    // A signed check that Counta's secret matches, for the admin portal's "Test" button.
    if (url === '/check' && method === 'POST') {
      const why = signedOk(req, method, '/check', body);
      if (why) return send(res, 401, { status: 'error', message: 'Relay: ' + why });
      return send(res, 200, { ok: true, version: VERSION, upstream: UPSTREAM.host });
    }
    if (!url.startsWith('/forward/')) return send(res, 404, { status: 'error', message: 'Not found.' });
    const path = url.slice('/forward'.length);
    if (!ALLOW.test(path) || path.includes('..')) return send(res, 403, { status: 'error', message: 'Relay: this path is not forwarded.' });
    if (!['GET', 'POST', 'PUT'].includes(method)) return send(res, 405, { status: 'error', message: 'Relay: method not allowed.' });
    const why = signedOk(req, method, path, body);
    if (why) return send(res, 401, { status: 'error', message: 'Relay: ' + why });
    const auth = OWN_KEY ? `Bearer ${OWN_KEY}` : String(req.headers['x-flw-authorization'] || '');
    if (!/^Bearer FLWSECK[-_A-Za-z0-9]+$/.test(auth)) return send(res, 400, { status: 'error', message: 'Relay: no Flutterwave key.' });
    const up = await forward(method, path, body, auth);
    console.log(new Date().toISOString(), method, path.replace(/\?.*$/, ''), up.status);
    res.writeHead(up.status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    res.end(up.text);
  } catch (e) {
    console.log(new Date().toISOString(), method, url.replace(/\?.*$/, ''), 'error', e && e.message);
    // The request may have reached Flutterwave; Counta treats this as "no answer" and checks before sending again.
    send(res, 504, { status: 'error', message: 'Relay: Flutterwave did not answer.' });
  }
});
server.headersTimeout = 15000;
server.requestTimeout = 40000;
server.listen(PORT, HOST, () => console.log(`counta relay ${VERSION} on ${HOST}:${PORT} -> ${UPSTREAM.origin}${UPSTREAM.pathname}`));
