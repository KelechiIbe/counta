// Gemini through Vertex AI, signed in with Application Default Credentials (ADC). The same file lives in
// supabase/functions/ai and supabase/functions/atlas; keep the two identical.
//
// ADC on Supabase. An Edge Function has no Google metadata server and no credentials file, so the JSON that ADC would read
// from the file named in GOOGLE_APPLICATION_CREDENTIALS is stored as the Edge Function secret
// GOOGLE_APPLICATION_CREDENTIALS_JSON (the JSON itself, or the same text base64-encoded). The credential types Google's
// tools write are supported:
//   service_account                that service account's JSON key (the right choice for a server)
//   authorized_user                `gcloud auth application-default login`
//   impersonated_service_account   `gcloud auth application-default login --impersonate-service-account=<email>`
// GOOGLE_CLOUD_PROJECT (default: the credential's project) and GOOGLE_CLOUD_LOCATION (default us-central1) say where
// Vertex AI runs. The account needs the Vertex AI User role (roles/aiplatform.user) in that project, and the Vertex AI API
// must be enabled there.
//
// Without an ADC credential, GEMINI_API_KEY (the Gemini API in Google AI Studio) is used if it is set.

export type GeminiConfig = {
  mode: 'vertex' | 'api_key' | 'none';
  project?: string; location?: string; principal?: string; credType?: string; key?: string; problem?: string;
  adc?: Record<string, any>;
};

const SCOPE = 'https://www.googleapis.com/auth/cloud-platform';
const TOKEN_URI = 'https://oauth2.googleapis.com/token';
const GEMINI_API = Deno.env.get('GEMINI_BASE_URL') || 'https://generativelanguage.googleapis.com/v1beta';
// Tests point this at a stand-in; normally the regional (or global) Vertex AI host is used.
const VERTEX_BASE = Deno.env.get('VERTEX_BASE_URL') || '';

// A problem with the credential itself: no other model or retry fixes it.
export class CredentialError extends Error {}

const b64url = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const utf8 = (s: string) => new TextEncoder().encode(s);

function readAdc(raw: string): Record<string, any> {
  let text = raw.trim();
  if (!text.startsWith('{')) {
    try { text = new TextDecoder().decode(Uint8Array.from(atob(text.replace(/\s+/g, '')), (c) => c.charCodeAt(0))); }
    catch { throw new CredentialError('GOOGLE_APPLICATION_CREDENTIALS_JSON is neither JSON nor base64-encoded JSON.'); }
  }
  let j: any;
  try { j = JSON.parse(text); } catch { throw new CredentialError('GOOGLE_APPLICATION_CREDENTIALS_JSON is not valid JSON. Paste the whole credential file.'); }
  if (!j || typeof j.type !== 'string') throw new CredentialError('GOOGLE_APPLICATION_CREDENTIALS_JSON has no "type". Paste the whole credential file.');
  return j;
}

// Which way to reach Gemini, from the secrets. `secret` reads Edge Function secrets (and Vault, where the caller allows it).
export async function geminiConfig(secret: (name: string) => Promise<string>): Promise<GeminiConfig> {
  let raw = await secret('GOOGLE_APPLICATION_CREDENTIALS_JSON');
  // Some people put the JSON itself in GOOGLE_APPLICATION_CREDENTIALS; a file path means nothing here.
  if (!raw) { const g = Deno.env.get('GOOGLE_APPLICATION_CREDENTIALS') || ''; if (g.trim().startsWith('{')) raw = g; }
  if (raw) {
    let adc: Record<string, any>;
    try { adc = readAdc(raw); } catch (e) { return { mode: 'none', problem: (e as Error).message }; }
    const src = adc.type === 'impersonated_service_account' ? adc.source_credentials || {} : adc;
    const project = (await secret('GOOGLE_CLOUD_PROJECT')) || adc.project_id || adc.quota_project_id || src.project_id || src.quota_project_id || '';
    const location = (await secret('GOOGLE_CLOUD_LOCATION')) || 'us-central1';
    const principal = adc.client_email
      || (adc.service_account_impersonation_url ? String(adc.service_account_impersonation_url).match(/serviceAccounts\/([^:]+):/)?.[1] : '')
      || (adc.type === 'authorized_user' ? 'a Google user account' : '');
    if (!project) return { mode: 'none', problem: 'Set GOOGLE_CLOUD_PROJECT to the Google Cloud project that runs Vertex AI.', credType: adc.type };
    return { mode: 'vertex', adc, project, location, principal, credType: adc.type };
  }
  const key = await secret('GEMINI_API_KEY');
  if (key) return { mode: 'api_key', key };
  return { mode: 'none' };
}

// ------------------------------------------------------------------ access tokens
const tokens = new Map<string, { token: string; exp: number }>();

async function postForm(url: string, form: Record<string, string>) {
  const res = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams(form),
    signal: AbortSignal.timeout(20_000) });
  const body = await res.json().catch(() => ({}));
  if (!res.ok || !body.access_token) {
    const why = body.error_description || body.error || `HTTP ${res.status}`;
    throw new CredentialError(`Google refused the credential: ${String(why).slice(0, 200)}`);
  }
  return { token: String(body.access_token), exp: Date.now() + Math.max(Number(body.expires_in) || 3600, 120) * 1000 };
}

function pemToDer(pem: string): ArrayBuffer {
  const b64 = String(pem).replace(/\\n/g, '\n').replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0)).buffer;
}

// Service account: a signed JWT exchanged for an access token (what the Google auth libraries do with a key file).
async function serviceAccountToken(c: Record<string, any>) {
  if (!c.client_email || !c.private_key) throw new CredentialError('The service account credential has no client_email or private_key.');
  const now = Math.floor(Date.now() / 1000);
  const aud = c.token_uri || TOKEN_URI;
  const head = b64url(utf8(JSON.stringify({ alg: 'RS256', typ: 'JWT', ...(c.private_key_id ? { kid: c.private_key_id } : {}) })));
  const claims = b64url(utf8(JSON.stringify({ iss: c.client_email, scope: SCOPE, aud, iat: now, exp: now + 3600 })));
  let key: CryptoKey;
  try { key = await crypto.subtle.importKey('pkcs8', pemToDer(c.private_key), { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']); }
  catch { throw new CredentialError('The service account private_key could not be read. Paste the key file exactly as downloaded.'); }
  const sig = new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, utf8(`${head}.${claims}`)));
  return postForm(aud, { grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: `${head}.${claims}.${b64url(sig)}` });
}

async function mint(c: Record<string, any>): Promise<{ token: string; exp: number }> {
  if (c.type === 'service_account') return serviceAccountToken(c);
  if (c.type === 'authorized_user') {
    if (!c.refresh_token || !c.client_id) throw new CredentialError('The user credential has no refresh_token. Run gcloud auth application-default login again.');
    return postForm(c.token_uri || TOKEN_URI, { grant_type: 'refresh_token', client_id: c.client_id, client_secret: c.client_secret || '', refresh_token: c.refresh_token });
  }
  if (c.type === 'impersonated_service_account') {
    const source = await mint(c.source_credentials || {});
    const res = await fetch(c.service_account_impersonation_url, {
      method: 'POST', headers: { Authorization: `Bearer ${source.token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ scope: [SCOPE], lifetime: '3600s', delegates: c.delegates || [] }), signal: AbortSignal.timeout(20_000),
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok || !body.accessToken) throw new CredentialError(`Google refused to impersonate the service account: ${String(body?.error?.message || res.status).slice(0, 200)}`);
    return { token: String(body.accessToken), exp: Date.parse(body.expireTime) || Date.now() + 3300_000 };
  }
  if (c.type === 'external_account') {
    throw new CredentialError('Workload identity federation (external_account) needs a token source that Supabase Edge Functions do not have. Use a service account key, or gcloud application-default login with service account impersonation.');
  }
  throw new CredentialError(`Credential type "${c.type}" is not supported. Use a service account key.`);
}

// A cached access token for the ADC credential, renewed a few minutes before it expires.
export async function accessToken(cfg: GeminiConfig): Promise<string> {
  const id = `${cfg.credType}:${cfg.adc?.client_email || cfg.adc?.client_id || cfg.adc?.service_account_impersonation_url || ''}`;
  const hit = tokens.get(id);
  if (hit && hit.exp - Date.now() > 300_000) return hit.token;
  const t = await mint(cfg.adc || {});
  tokens.set(id, t);
  return t.token;
}

// ------------------------------------------------------------------ calls
export const thinkingLevel = (cfg: GeminiConfig, level: 'low' | 'high') => (cfg.mode === 'vertex' ? level.toUpperCase() : level);
// Gemini 2.5 takes a thinking budget rather than a level; "low" turns its thinking off, which keeps reading jobs quick.
export const thinkingConfig = (cfg: GeminiConfig, model: string, level: 'low' | 'high') =>
  (/^gemini-2\./.test(model) ? { thinkingBudget: level === 'low' ? 0 : -1 } : { thinkingLevel: thinkingLevel(cfg, level) });

// Newer Gemini models are served on Vertex AI's global endpoint and not in every region. A model the region does not
// have is asked for on the global endpoint, and remembered.
const globalOnly = new Set<string>();

// POSTs a generateContent request to Vertex AI (ADC) or the Gemini API (key). The request and response bodies are the same.
export async function generateContent(cfg: GeminiConfig, model: string, body: unknown, timeoutMs: number): Promise<Response> {
  if (cfg.mode === 'vertex') {
    const headers: Record<string, string> = { 'Content-Type': 'application/json', Authorization: `Bearer ${await accessToken(cfg)}` };
    // A user's own credential bills the project it is told to.
    if (cfg.credType === 'authorized_user') headers['x-goog-user-project'] = cfg.adc?.quota_project_id || cfg.project || '';
    const call = (loc: string) => {
      const host = VERTEX_BASE || (loc === 'global' ? 'https://aiplatform.googleapis.com' : `https://${loc}-aiplatform.googleapis.com`);
      return fetch(`${host}/v1/projects/${encodeURIComponent(cfg.project || '')}/locations/${encodeURIComponent(loc)}/publishers/google/models/${encodeURIComponent(model)}:generateContent`,
        { method: 'POST', headers, body: JSON.stringify(body), signal: AbortSignal.timeout(timeoutMs) });
    };
    const loc = cfg.location || 'us-central1';
    if (loc === 'global' || globalOnly.has(model)) return call('global');
    const res = await call(loc);
    if (res.status !== 404) return res;
    await res.body?.cancel();
    globalOnly.add(model);
    return call('global');
  }
  if (cfg.mode === 'api_key') {
    return fetch(`${GEMINI_API}/models/${model}:generateContent`, { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-goog-api-key': cfg.key || '' },
      body: JSON.stringify(body), signal: AbortSignal.timeout(timeoutMs) });
  }
  throw new CredentialError(cfg.problem || 'Gemini is not connected. Add GOOGLE_APPLICATION_CREDENTIALS_JSON to the Supabase Edge Function secrets.');
}

// Models to try after the chosen one when it is busy or not offered where Vertex AI runs.
export const fallbackModels = (cfg: GeminiConfig) => (cfg.mode === 'vertex' ? ['gemini-3.6-flash', 'gemini-3.5-flash', 'gemini-2.5-flash'] : ['gemini-3.6-flash', 'gemini-3.5-flash', 'gemini-flash-latest']);

// A refusal no other model would fix (the credential or the project's permissions), worded for the person fixing it.
export function accessProblem(cfg: GeminiConfig, status: number, text: string): string | null {
  if (status !== 401 && status !== 403) return null;
  let msg = text;
  try { msg = JSON.parse(text)?.error?.message || text; } catch { /* not json */ }
  if (cfg.mode !== 'vertex') return `The Gemini API refused the key (${status}): ${String(msg).slice(0, 200)}`;
  const who = cfg.principal ? ` and that ${cfg.principal} has the Vertex AI User role there` : ' and that the account has the Vertex AI User role there';
  return `Vertex AI refused the request (${status}): ${String(msg).slice(0, 200)}. Check that the Vertex AI API is enabled in project ${cfg.project}${who}.`;
}

export const quotaMessage = (cfg: GeminiConfig) => (cfg.mode === 'vertex'
  ? `Vertex AI is at its quota for this model in ${cfg.location}. Try again shortly, or ask for more quota in the Google Cloud console.`
  : 'The Gemini key has used up its quota. Turn on billing for it in Google AI Studio, or try again once the quota resets.');
