// Gemini's context cache for Martina on WhatsApp and Siri. Her fixed instructions (RULES in martina.ts) and her tool list are
// the same for every business, so they are stored once with Google, and each call sends only Counta's note and the
// conversation. Google bills cached tokens at a tenth of the input price, the cache's own tokens once at the input price when
// it is made, and storage for each hour it is kept.
//
// A cache is made when a message comes and none is live, kept fifteen minutes, and extended while messages keep coming; with
// no traffic it lapses by itself. Another isolate's cache is found through Google's own list, by its display name, which is a
// hash of the model and the instructions (a change to either makes a new cache). A cache Google refuses (too small for the
// model, no permission) is not asked for again for six hours, and a call made with a cache that fails goes out again in full.
import { accessToken, CredentialError, type GeminiConfig } from './google.ts';

export type Fixed = { systemInstruction: { parts: { text: string }[] }; tools: unknown[]; toolConfig?: unknown };
export type Cache = { name: string; key: string; model: string; location: string | null; expires: number; tokens: number };
// What a cache cost: its tokens when made (kind context_cache, at the input price) and the token-hours it is kept (storage).
export type CostNote = (kind: 'context_cache' | 'storage', model: string, qty: number) => void;

export const TTL_S = 900;
const EXTEND_BELOW_MS = 5 * 60_000;
const MIN_LEFT_MS = 60_000;
const REFUSED_MS = 6 * 3600_000;
const held = new Map<string, Cache>();
const refused = new Map<string, number>();

// Swapped in tests.
export const deps = { token: accessToken as (cfg: GeminiConfig) => Promise<string>, now: () => Date.now() };
export function forgetAll() { held.clear(); refused.clear(); }

const geminiBase = () => (Deno.env.get('GEMINI_BASE_URL') || 'https://generativelanguage.googleapis.com/v1beta').replace(/\/$/, '');
const vertexHost = (loc: string) => (Deno.env.get('VERTEX_BASE_URL') || (loc === 'global' ? 'https://aiplatform.googleapis.com' : `https://${loc}-aiplatform.googleapis.com`)).replace(/\/$/, '');

async function hash(s: string) {
  return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)))).map((x) => x.toString(16).padStart(2, '0')).join('');
}

async function headers(cfg: GeminiConfig): Promise<Record<string, string>> {
  if (cfg.mode !== 'vertex') return { 'Content-Type': 'application/json', 'x-goog-api-key': cfg.key || '' };
  const h: Record<string, string> = { 'Content-Type': 'application/json', Authorization: `Bearer ${await deps.token(cfg)}` };
  if (cfg.credType === 'authorized_user') h['x-goog-user-project'] = cfg.adc?.quota_project_id || cfg.project || '';
  return h;
}

// Where caches live (a Vertex AI location, or the Gemini API), and the addresses there.
function place(cfg: GeminiConfig, loc: string | null) {
  if (cfg.mode === 'vertex') {
    const l = loc || 'global', parent = `projects/${encodeURIComponent(cfg.project || '')}/locations/${encodeURIComponent(l)}`;
    return {
      list: `${vertexHost(l)}/v1/${parent}/cachedContents`,
      model: (m: string) => `projects/${cfg.project}/locations/${l}/publishers/google/models/${m}`,
      item: (name: string) => `${vertexHost(l)}/v1/${name}`,
      generate: (m: string) => `${vertexHost(l)}/v1/${parent}/publishers/google/models/${encodeURIComponent(m)}:generateContent`,
    };
  }
  const b = geminiBase();
  return { list: `${b}/cachedContents`, model: (m: string) => `models/${m}`, item: (name: string) => `${b}/${name}`, generate: (m: string) => `${b}/models/${m}:generateContent` };
}

const ask = async (cfg: GeminiConfig, url: string, method: string, body?: unknown) =>
  await fetch(url, { method, headers: await headers(cfg), ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: AbortSignal.timeout(15_000) });

function asCache(x: any, key: string, model: string, loc: string | null): Cache | null {
  const expires = Date.parse(String(x?.expireTime || ''));
  if (!x?.name || !Number.isFinite(expires)) return null;
  return { name: String(x.name), key, model, location: loc, expires, tokens: Number(x?.usageMetadata?.totalTokenCount) || 0 };
}

// A live cache another isolate made, from Google's list.
async function find(cfg: GeminiConfig, key: string, model: string, locs: (string | null)[]): Promise<Cache | null> {
  for (const loc of locs) {
    const r = await ask(cfg, `${place(cfg, loc).list}?pageSize=100`, 'GET');
    if (!r.ok) { await r.body?.cancel(); continue; }
    const all: any[] = (await r.json().catch(() => ({})))?.cachedContents || [];
    const hit = all.find((x) => x?.displayName === key && String(x?.model || '').endsWith(`models/${model}`) && Date.parse(x?.expireTime) - deps.now() > MIN_LEFT_MS);
    if (hit) return asCache(hit, key, model, loc);
  }
  return null;
}

async function make(cfg: GeminiConfig, key: string, model: string, locs: (string | null)[], fixed: Fixed, cost?: CostNote): Promise<Cache | null> {
  for (const loc of locs) {
    const p = place(cfg, loc);
    const r = await ask(cfg, p.list, 'POST', { model: p.model(model), displayName: key, systemInstruction: fixed.systemInstruction, tools: fixed.tools,
      ...(fixed.toolConfig ? { toolConfig: fixed.toolConfig } : {}), ttl: `${TTL_S}s` });
    // The model is not offered in this region: try the global location.
    if (r.status === 404) { await r.body?.cancel(); continue; }
    if (!r.ok) {
      console.warn('martina cache refused', r.status, (await r.text()).replace(/\s+/g, ' ').slice(0, 300));
      refused.set(key, deps.now() + REFUSED_MS);
      return null;
    }
    const c = asCache(await r.json().catch(() => null), key, model, loc);
    if (c) {
      cost?.('context_cache', model, c.tokens);
      cost?.('storage', model, c.tokens * Math.max(0, c.expires - deps.now()) / 3600_000);
    }
    return c;
  }
  refused.set(key, deps.now() + REFUSED_MS);
  return null;
}

// Fifteen more minutes for a cache in use. False when Google no longer has it.
async function extend(cfg: GeminiConfig, c: Cache, cost?: CostNote): Promise<boolean> {
  const r = await ask(cfg, `${place(cfg, c.location).item(c.name)}?updateMask=ttl`, 'PATCH', { ttl: `${TTL_S}s` });
  if (r.status === 404) { await r.body?.cancel(); return false; }
  if (!r.ok) { await r.body?.cancel(); return true; }
  const until = Date.parse(String((await r.json().catch(() => ({})))?.expireTime || '')) || deps.now() + TTL_S * 1000;
  if (until > c.expires) cost?.('storage', c.model, c.tokens * (until - c.expires) / 3600_000);
  c.expires = Math.max(c.expires, until);
  return true;
}

// The cache for this model and these instructions: the one this isolate holds, one another made, or a new one. Null when
// there is none to use (caching refused lately, or Google could not be reached); the call then goes out in full.
export async function cacheFor(cfg: GeminiConfig, model: string, fixed: Fixed, cost?: CostNote): Promise<Cache | null> {
  if (cfg.mode !== 'vertex' && cfg.mode !== 'api_key') return null;
  const loc = cfg.mode === 'vertex' ? cfg.location || 'us-central1' : null;
  const locs = cfg.mode === 'vertex' && loc !== 'global' ? [loc, 'global'] : [loc];
  const key = 'martina-' + (await hash(JSON.stringify([cfg.mode, cfg.project || '', loc, model, fixed]))).slice(0, 32);
  if ((refused.get(key) || 0) > deps.now()) return null;
  try {
    let c = held.get(key) || null;
    if (c && c.expires - deps.now() < MIN_LEFT_MS) { held.delete(key); c = null; }
    if (!c) c = (await find(cfg, key, model, locs)) || (await make(cfg, key, model, locs, fixed, cost));
    if (!c) return null;
    if (c.expires - deps.now() < EXTEND_BELOW_MS && !(await extend(cfg, c, cost))) { held.delete(key); return null; }
    held.set(key, c);
    return c;
  } catch (e) {
    if (e instanceof CredentialError) throw e;
    console.warn('martina cache', (e as Error).message);
    return null;
  }
}

// A generateContent call that takes the instructions and tools from the cache: the request carries only the conversation.
export async function generateCached(cfg: GeminiConfig, c: Cache, body: Record<string, unknown>, timeoutMs: number): Promise<Response> {
  return await fetch(place(cfg, c.location).generate(c.model), { method: 'POST', headers: await headers(cfg),
    body: JSON.stringify({ ...body, cachedContent: c.name }), signal: AbortSignal.timeout(timeoutMs) });
}

// A cache that failed in use: not used again for ten minutes (calls go out in full meanwhile).
export function drop(c: Cache) {
  held.delete(c.key);
  refused.set(c.key, deps.now() + 10 * 60_000);
}
