// Gemini's context cache for Martina (cache.ts), against a stand-in for the Gemini API and Vertex AI.
// deno test --no-config -A cache_test.ts
import { assert, assertEquals } from 'jsr:@std/assert@1';
import { cacheFor, deps, drop, type Fixed, forgetAll, generateCached, TTL_S } from './cache.ts';
import type { GeminiConfig } from './google.ts';

type Seen = { method: string; path: string; body: any; auth: string | null; key: string | null };
const seen: Seen[] = [];
const caches = new Map<string, any>();
let refuseCreate = 0, missingRegion = false, n = 0;

const server = Deno.serve({ port: 0, hostname: '127.0.0.1', onListen() {} }, async (req) => {
  const u = new URL(req.url);
  const body = req.method === 'GET' ? null : await req.json().catch(() => null);
  seen.push({ method: req.method, path: u.pathname + u.search, body, auth: req.headers.get('authorization'), key: req.headers.get('x-goog-api-key') });
  const j = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { 'Content-Type': 'application/json' } });
  if (u.pathname.endsWith('/cachedContents') && req.method === 'GET') {
    const loc = u.pathname.match(/locations\/([^/]+)\//)?.[1] || null;
    return j({ cachedContents: [...caches.values()].filter((c) => !loc || c.name.includes(`/locations/${loc}/`)) });
  }
  if (u.pathname.endsWith('/cachedContents') && req.method === 'POST') {
    if (refuseCreate) return j({ error: { code: refuseCreate, message: 'Cached content is too small. total_token_count=3900, min_total_token_count=4096' } }, refuseCreate);
    const loc = u.pathname.match(/locations\/([^/]+)\//)?.[1] || null;
    if (missingRegion && loc && loc !== 'global') return j({ error: { code: 404, message: 'Publisher model not found' } }, 404);
    const name = loc ? `projects/123456/locations/${loc}/cachedContents/c${++n}` : `cachedContents/c${++n}`;
    const c = { name, displayName: body.displayName, model: body.model, expireTime: new Date(deps.now() + TTL_S * 1000).toISOString(), usageMetadata: { totalTokenCount: 5000 } };
    caches.set(name, c);
    return j(c);
  }
  if (req.method === 'PATCH') {
    const name = u.pathname.replace(/^\/(v1|v1beta)\//, '');
    const c = caches.get(name);
    if (!c) return j({ error: { code: 404 } }, 404);
    assertEquals(u.searchParams.get('updateMask'), 'ttl');
    c.expireTime = new Date(deps.now() + Number(String(body.ttl).replace('s', '')) * 1000).toISOString();
    return j(c);
  }
  if (u.pathname.endsWith(':generateContent')) return j({ candidates: [{ content: { role: 'model', parts: [{ text: 'ok' }] } }] });
  return j({ error: 'unexpected' }, 500);
});
const base = `http://127.0.0.1:${(server.addr as Deno.NetAddr).port}`;
Deno.env.set('GEMINI_BASE_URL', base + '/v1beta');
Deno.env.set('VERTEX_BASE_URL', base);

const FIXED: Fixed = { systemInstruction: { parts: [{ text: 'You are Martina.' }] }, tools: [{ functionDeclarations: [{ name: 'get_overview', description: 'Numbers' }] }] };
const KEY: GeminiConfig = { mode: 'api_key', key: 'k-test' };
const VERTEX: GeminiConfig = { mode: 'vertex', project: 'counta-ai', location: 'us-central1', credType: 'service_account', adc: { type: 'service_account' } };
let clock = Date.parse('2026-11-22T12:00:00Z');
deps.now = () => clock;
deps.token = () => Promise.resolve('tok-test');

function fresh() { forgetAll(); seen.length = 0; caches.clear(); refuseCreate = 0; missingRegion = false; clock = Date.parse('2026-11-22T12:00:00Z'); }
const costs: [string, number][] = [];
const note = (kind: string, _m: string, q: number) => { costs.push([kind, q]); };

Deno.test('makes one cache, records what it costs, then reuses it without asking Google', async () => {
  fresh(); costs.length = 0;
  const c = await cacheFor(KEY, 'gemini-3.8-flash', FIXED, note);
  assert(c);
  assertEquals(seen.map((s) => `${s.method} ${s.path}`), ['GET /v1beta/cachedContents?pageSize=100', 'POST /v1beta/cachedContents']);
  const made = seen[1].body;
  assertEquals(made.model, 'models/gemini-3.8-flash');
  assertEquals(made.ttl, `${TTL_S}s`);
  assertEquals(made.systemInstruction, FIXED.systemInstruction);
  assertEquals(made.tools, FIXED.tools);
  assert(String(made.displayName).startsWith('martina-'));
  assertEquals(seen[1].key, 'k-test');
  // 5,000 tokens made, kept a quarter of an hour.
  assertEquals(costs, [['context_cache', 5000], ['storage', 1250]]);
  seen.length = 0;
  const again = await cacheFor(KEY, 'gemini-3.8-flash', FIXED, note);
  assertEquals(again?.name, c.name);
  assertEquals(seen.length, 0);
});

Deno.test("another isolate's cache is found on Google's list, not made again", async () => {
  fresh();
  const c = await cacheFor(KEY, 'gemini-3.8-flash', FIXED);
  forgetAll(); seen.length = 0;
  const found = await cacheFor(KEY, 'gemini-3.8-flash', FIXED);
  assertEquals(found?.name, c?.name);
  assertEquals(seen.map((s) => s.method), ['GET']);
});

Deno.test('a cache in use is extended before it lapses, and the added storage is recorded', async () => {
  fresh(); costs.length = 0;
  const c = await cacheFor(KEY, 'gemini-3.8-flash', FIXED, note);
  costs.length = 0; seen.length = 0;
  clock += 11 * 60_000; // four minutes left
  const same = await cacheFor(KEY, 'gemini-3.8-flash', FIXED, note);
  assertEquals(same?.name, c?.name);
  assertEquals(seen.map((s) => s.method), ['PATCH']);
  assertEquals(seen[0].body, { ttl: `${TTL_S}s` });
  // eleven more minutes of 5,000 tokens
  assertEquals(costs.length, 1);
  assertEquals(costs[0][0], 'storage');
  assertEquals(Math.round(costs[0][1] * 100) / 100, Math.round(5000 * 11 / 60 * 100) / 100);
  seen.length = 0;
  clock += 60_000;
  await cacheFor(KEY, 'gemini-3.8-flash', FIXED, note);
  assertEquals(seen.length, 0, 'fourteen minutes left: nothing to do');
});

Deno.test('a lapsed cache is replaced', async () => {
  fresh();
  const c = await cacheFor(KEY, 'gemini-3.8-flash', FIXED);
  clock += TTL_S * 1000 + 1000;
  caches.clear();
  const next = await cacheFor(KEY, 'gemini-3.8-flash', FIXED);
  assert(next && next.name !== c?.name);
});

Deno.test('a cache Google refuses is not asked for again for six hours, and calls go out in full', async () => {
  fresh(); refuseCreate = 400;
  assertEquals(await cacheFor(KEY, 'gemini-3.8-flash', FIXED), null);
  seen.length = 0;
  clock += 5 * 3600_000;
  assertEquals(await cacheFor(KEY, 'gemini-3.8-flash', FIXED), null);
  assertEquals(seen.length, 0);
  refuseCreate = 0;
  clock += 2 * 3600_000;
  assert(await cacheFor(KEY, 'gemini-3.8-flash', FIXED));
});

Deno.test('a cache that failed in use is set aside for ten minutes', async () => {
  fresh();
  const c = await cacheFor(KEY, 'gemini-3.8-flash', FIXED);
  drop(c!);
  assertEquals(await cacheFor(KEY, 'gemini-3.8-flash', FIXED), null);
  clock += 11 * 60_000;
  assert(await cacheFor(KEY, 'gemini-3.8-flash', FIXED));
});

Deno.test('another model or other instructions get their own cache', async () => {
  fresh();
  const a = await cacheFor(KEY, 'gemini-3.8-flash', FIXED);
  const b = await cacheFor(KEY, 'gemini-3.6-flash', FIXED);
  const c = await cacheFor(KEY, 'gemini-3.8-flash', { ...FIXED, systemInstruction: { parts: [{ text: 'You are Martina, changed.' }] } });
  assertEquals(new Set([a?.name, b?.name, c?.name]).size, 3);
  assertEquals(new Set([a?.key, b?.key, c?.key]).size, 3);
});

Deno.test('Vertex AI: signed in, made where the model runs (global when the region lacks it), and called there with the cache only', async () => {
  fresh(); missingRegion = true;
  const c = await cacheFor(VERTEX, 'gemini-3.8-flash', FIXED);
  assert(c);
  assertEquals(c.location, 'global');
  const posts = seen.filter((s) => s.method === 'POST');
  assertEquals(posts.map((s) => s.path), ['/v1/projects/counta-ai/locations/us-central1/cachedContents', '/v1/projects/counta-ai/locations/global/cachedContents']);
  assertEquals(posts[1].body.model, 'projects/counta-ai/locations/global/publishers/google/models/gemini-3.8-flash');
  assertEquals(posts[1].auth, 'Bearer tok-test');
  seen.length = 0;
  const res = await generateCached(VERTEX, c, { contents: [{ role: 'user', parts: [{ text: 'hi' }] }] }, 5000);
  assertEquals(res.status, 200);
  await res.body?.cancel();
  assertEquals(seen[0].path, '/v1/projects/counta-ai/locations/global/publishers/google/models/gemini-3.8-flash:generateContent');
  assertEquals(seen[0].body.cachedContent, c.name);
  assertEquals(Object.keys(seen[0].body).sort(), ['cachedContent', 'contents']);
  // A fresh isolate looks in the region, then in global, and finds it.
  forgetAll(); seen.length = 0;
  const found = await cacheFor(VERTEX, 'gemini-3.8-flash', FIXED);
  assertEquals(found?.name, c.name);
  assertEquals(seen.map((s) => `${s.method} ${s.path.split('?')[0]}`), ['GET /v1/projects/counta-ai/locations/us-central1/cachedContents',
    'GET /v1/projects/counta-ai/locations/global/cachedContents']);
});

Deno.test('no Gemini set up: no cache', async () => {
  fresh();
  assertEquals(await cacheFor({ mode: 'none' }, 'gemini-3.8-flash', FIXED), null);
  assertEquals(seen.length, 0);
});

Deno.test('Google out of reach: no cache, no error', async () => {
  fresh();
  Deno.env.set('GEMINI_BASE_URL', 'http://127.0.0.1:9/v1beta');
  try { assertEquals(await cacheFor(KEY, 'gemini-3.8-flash', FIXED), null); }
  finally { Deno.env.set('GEMINI_BASE_URL', base + '/v1beta'); }
});

Deno.test({ name: 'stop the stand-in', sanitizeResources: false, sanitizeOps: false, fn: async () => { await server.shutdown(); } });
