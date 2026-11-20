// Tests for moniepoint.ts against a stand-in for Moniepoint: api.pos.moniepoint.com under /api and channel.moniepoint.com under /channel.
// Run: cd supabase/functions && deno test --allow-all --node-modules-dir=none --no-lock pos/moniepoint_test.ts
import { assert, assertEquals, assertRejects } from 'jsr:@std/assert@1';

type World = {
  apiKeys: Set<string>; clients: Map<string, string>; tokensOnApi: boolean; live: Set<string>; calls: string[]; issued: number;
};
const world: World = { apiKeys: new Set(), clients: new Map(), tokensOnApi: false, live: new Set(), calls: [], issued: 0 };
function reset() {
  world.apiKeys = new Set(); world.clients = new Map(); world.tokensOnApi = false; world.live = new Set(); world.calls = []; world.issued = 0;
}
const INTRO = { scopes: ['transaction:push', 'transaction:read', 'webhook:read', 'webhook:write'], businesses: [{ id: 77, businessName: 'Ada Stores' }],
  authMethod: 'API_KEY', environment: 'PROD' };
const j = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { 'content-type': 'application/json' } });

const server = Deno.serve({ port: 0, hostname: '127.0.0.1', onListen() {} }, async (req) => {
  const u = new URL(req.url);
  const bearer = (req.headers.get('authorization') || '').replace(/^Bearer /, '');
  world.calls.push(`${req.method} ${u.pathname} ${bearer ? 'bearer:' + bearer : 'none'}`);
  if (u.pathname.startsWith('/api/')) {
    const ok = world.apiKeys.has(bearer) || (world.tokensOnApi && world.live.has(bearer));
    if (!ok) return j({ error: 'Unauthorized', message: 'Invalid key provided.' }, 401);
    if (u.pathname === '/api/v1/introspect') return j(INTRO);
    if (u.pathname === '/api/v1/transactions' && req.method === 'POST') return new Response(null, { status: 202 });
    if (u.pathname.startsWith('/api/v1/transactions/merchants/')) return j({ message: 'Transaction does not exist' }, 404);
    if (u.pathname === '/api/v1/webhook-subscriptions' && req.method === 'POST') return j({ id: 'sub-1' }, 201);
    return j({ message: 'not here' }, 404);
  }
  if (u.pathname === '/channel/v1/auth' && req.method === 'POST') {
    const b = await req.json().catch(() => ({}));
    if (world.clients.get(b.clientId) !== b.clientSecret) return j({ message: 'Invalid credentials', errors: ['Invalid credentials'], status: 'UNAUTHORIZED' }, 401);
    const t = `tok-${++world.issued}`;
    world.live.add(t);
    return j({ accessToken: t, tokenType: { value: 'bearer' }, expiresIn: 8699, scope: 'profile', jti: 'x' });
  }
  if (u.pathname.startsWith('/channel/v1/transactions')) {
    if (!world.live.has(bearer)) return j({ status: 401, error: 'Unauthorized' }, 401);
    if (req.method === 'POST') return new Response(null, { status: 202 });
    if (u.pathname.endsWith('/CNPKNOWN000000000001')) return j({ transactionReference: 'MP-1', merchantReference: 'CNPKNOWN000000000001', processingStatus: 'PROCESSED', responseCode: '20000', actualAmount: 250000, transactionType: 'PURCHASE' });
    return j({ message: 'Transaction does not exist' }, 404);
  }
  return new Response('<html>blocked</html>', { status: 403 });
});
const port = (server.addr as Deno.NetAddr).port;
Deno.env.set('MONIEPOINT_POS_BASE_URL', `http://127.0.0.1:${port}/api`);
Deno.env.set('MONIEPOINT_CHANNEL_BASE_URL', `http://127.0.0.1:${port}/channel`);
const mp = await import('./moniepoint.ts');

const KEY = 'mpk_live_0123456789abcdef', CID = 'client-7f3a', SECRET = 'sec_live_abcdef0123456789';
const authCalls = () => world.calls.filter((c) => c.startsWith('POST /channel/v1/auth')).length;

Deno.test('credentials keep their shape in Vault', () => {
  assertEquals(mp.readCreds(KEY), { mode: 'key', key: KEY });
  const stored = mp.storeCreds({ mode: 'client', clientId: CID, secret: SECRET, host: 'channel' });
  assertEquals(mp.readCreds(stored), { mode: 'client', clientId: CID, secret: SECRET, host: 'channel' });
  assertEquals(mp.storeCreds(mp.readCreds(KEY)), KEY);
  assertEquals(mp.readCreds('{not json').mode, 'key');
  assertEquals(mp.readCreds('{"v":2,"client_id":"a","secret":"b"}').mode, 'key');
  assert(mp.handMadeWebhook(stored));
  assert(!mp.handMadeWebhook(KEY));
  assert(!mp.handMadeWebhook(mp.storeCreds({ mode: 'client', clientId: CID, secret: SECRET, host: 'api' })));
});

Deno.test('a key Moniepoint takes on its own is kept as it is', async () => {
  reset(); mp.forgetTokens(); world.apiKeys.add(KEY);
  const r = await mp.resolve(KEY, CID);
  assertEquals(r.stored, KEY);
  assertEquals(r.intro?.businesses, [{ id: '77', name: 'Ada Stores' }]);
  assertEquals(r.intro?.environment, 'production');
  assertEquals(authCalls(), 0);
});

Deno.test('a refused key with no client ID asks for the client ID', async () => {
  reset(); mp.forgetTokens();
  const e = await assertRejects(() => mp.resolve(KEY, null), mp.MpError);
  assert(e.message.includes('client ID'), e.message);
  assert(e.hard);
});

Deno.test('client ID and key traded for a token that api.pos takes', async () => {
  reset(); mp.forgetTokens(); world.clients.set(CID, SECRET); world.tokensOnApi = true;
  const r = await mp.resolve(SECRET, CID);
  assertEquals(mp.readCreds(r.stored), { mode: 'client', clientId: CID, secret: SECRET, host: 'api' });
  assertEquals(r.intro?.scopes.length, 4);
  // Later calls go to api.pos with the token, and Counta can make its own webhook.
  const sub = await mp.createSubscription(r.stored, '77', 'https://example.test/hook');
  assertEquals(sub, 'sub-1');
  assert(world.calls.some((c) => c.startsWith('POST /api/v1/webhook-subscriptions bearer:tok-')), world.calls.join('\n'));
});

Deno.test('client ID and key that only channel.moniepoint.com takes', async () => {
  reset(); mp.forgetTokens(); world.clients.set(CID, SECRET);
  const r = await mp.resolve(SECRET, CID);
  assertEquals(mp.readCreds(r.stored), { mode: 'client', clientId: CID, secret: SECRET, host: 'channel' });
  assertEquals(r.intro, null);
  // Sales go to channel.moniepoint.com with the token.
  world.calls = [];
  await mp.push(r.stored, { terminalSerial: 'P260ABC', amount: 250000, merchantReference: 'CNPAAAAAAAAAAAAAAAA1', paymentMethod: 'ANY' });
  assertEquals(await mp.status(r.stored, 'CNPNOTFOUND000000001'), null);
  const s = await mp.status(r.stored, 'CNPKNOWN000000000001');
  assertEquals(mp.fromStatus(s, 'kobo').status, 'approved');
  assertEquals(mp.fromStatus(s, 'kobo').amount, 2500);
  assert(world.calls.every((c) => c.startsWith('POST /channel/v1/transactions bearer:tok-') || c.startsWith('GET /channel/v1/transactions/merchants/')), world.calls.join('\n'));
  assertEquals(authCalls(), 0, 'the token from connecting is reused');
  // No webhook API there: Counta does not try it.
  await assertRejects(() => mp.createSubscription(r.stored, '77', 'https://example.test/hook'), mp.MpError);
  await assertRejects(() => mp.events(r.stored, 'sub-1', '2026-11-19', '2026-11-20', 0), mp.MpError);
  assertEquals(await mp.eventById(r.stored, 'ev-1'), null);
  assert(!world.calls.some((c) => c.includes('webhook')), world.calls.join('\n'));
});

Deno.test('a client ID and key Moniepoint refuses together', async () => {
  reset(); mp.forgetTokens(); world.clients.set(CID, 'another-secret-entirely');
  const e = await assertRejects(() => mp.resolve(SECRET, CID), mp.MpError);
  assert(e.message.includes('client ID and API key together'), e.message);
  assert(e.hard);
});

Deno.test('a token that stops working is replaced once', async () => {
  reset(); mp.forgetTokens(); world.clients.set(CID, SECRET);
  const stored = mp.storeCreds({ mode: 'client', clientId: CID, secret: SECRET, host: 'channel' });
  await mp.push(stored, { terminalSerial: 'P260ABC', amount: 100, merchantReference: 'CNPAAAAAAAAAAAAAAAA2', paymentMethod: 'ANY' });
  await mp.push(stored, { terminalSerial: 'P260ABC', amount: 100, merchantReference: 'CNPAAAAAAAAAAAAAAAA3', paymentMethod: 'ANY' });
  assertEquals(authCalls(), 1, 'one token for both');
  world.live.clear(); // Moniepoint revoked it
  await mp.push(stored, { terminalSerial: 'P260ABC', amount: 100, merchantReference: 'CNPAAAAAAAAAAAAAAAA4', paymentMethod: 'ANY' });
  assertEquals(authCalls(), 2, 'a fresh token after the 401');
  // The client deleted in the app: the refusal is a hard one the owner must see.
  world.live.clear(); world.clients.clear();
  const e = await assertRejects(() => mp.push(stored, { terminalSerial: 'P260ABC', amount: 100, merchantReference: 'CNPAAAAAAAAAAAAAAAA5', paymentMethod: 'ANY' }), mp.MpError);
  assert(e.hard);
});

Deno.test('checking credentials later', async () => {
  reset(); mp.forgetTokens(); world.clients.set(CID, SECRET); world.apiKeys.add(KEY);
  assertEquals((await mp.check(KEY))?.businesses.length, 1);
  const stored = mp.storeCreds({ mode: 'client', clientId: CID, secret: SECRET, host: 'channel' });
  assertEquals(await mp.check(stored), null);
  world.clients.clear();
  await assertRejects(() => mp.check(stored), mp.MpError);
});

Deno.test('Moniepoint\'s success codes', () => {
  assertEquals(mp.outcome('COMPLETED', '20000'), 'approved');
  assertEquals(mp.outcome('SUCCESSFUL', '00'), 'approved');
  assertEquals(mp.outcome('', '00'), 'approved');
  assertEquals(mp.outcome('COMPLETED', ''), 'approved');
  assertEquals(mp.outcome('COMPLETED', '51'), 'declined');
  assertEquals(mp.outcome('FAILED', '20001'), 'declined');
  assertEquals(mp.outcome('PENDING', ''), 'pending');
  assertEquals(mp.outcome('', '09'), 'pending');
  assertEquals(mp.fromStatus({ transactionReference: 'R', processingStatus: 'PROCESSED', responseCode: '20000', actualAmount: 100 }, 'kobo').status, 'approved');
  assertEquals(mp.fromStatus({ transactionReference: 'R', processingStatus: 'CANCELLED', responseCode: '', requestAmount: 100 }, 'kobo').status, 'declined');
  // The example in Moniepoint's webhook documentation.
  const t = mp.fromEvent({ eventId: 'e1', eventType: 'V1_POS_TRANSFER_TRANSACTION', createdAt: '2026-11-20T09:00:00Z',
    data: { businessId: 77, terminalSerial: 'P260ABC', amount: 10000, transactionReference: 'MP-9', transactionType: 'POS_TRANSFER',
      transactionStatus: 'COMPLETED', responseCode: '20000', responseMessage: 'Successful', transactionTime: '2026-11-20T09:00:00Z' } }, 'kobo');
  assertEquals(t?.status, 'approved');
  assertEquals(t?.amount, 100);
  assertEquals(t?.kind, 'transfer');
});

Deno.test({ name: 'stop the stand-in', fn: async () => { await server.shutdown(); }, sanitizeOps: false, sanitizeResources: false });
