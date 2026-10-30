// Google Cloud KMS with HSM keys, signed in with the same Application Default Credentials Counta uses for Gemini.
// The key ring (GOOGLE_KMS_KEY_RING, default projects/<project>/locations/us-central1/keyRings/counta-einvoice) holds:
//   nrs-credentials   symmetric, ENCRYPT_DECRYPT, protection level HSM: wraps each business's NRS key and secret
//   invoice-signing   ASYMMETRIC_SIGN, EC_SIGN_P256_SHA256, protection level HSM: TaxStreem's own signatures
// The private halves never leave the HSM; Counta asks KMS to encrypt, decrypt and sign.
import { accessToken, type GeminiConfig } from './google.ts';

const KMS = (Deno.env.get('KMS_BASE_URL') || 'https://cloudkms.googleapis.com/v1').replace(/\/$/, '');
export const CREDENTIALS_KEY = 'nrs-credentials';
export const SIGNING_KEY = 'invoice-signing';

export class KmsError extends Error {
  constructor(message: string, public status = 0) { super(message); }
}

export const b64 = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes));
export const unb64 = (s: string) => Uint8Array.from(atob(String(s || '')), (c) => c.charCodeAt(0));

export function keyRing(cfg: GeminiConfig, configured: string): string {
  const v = String(configured || '').trim();
  return v || `projects/${cfg.project}/locations/us-central1/keyRings/counta-einvoice`;
}

async function kms(cfg: GeminiConfig, path: string, body?: unknown): Promise<any> {
  const token = await accessToken(cfg);
  let res: Response;
  try {
    res = await fetch(`${KMS}/${path}`, { method: body === undefined ? 'GET' : 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', ...(cfg.project ? { 'x-goog-user-project': cfg.project } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(20_000) });
  } catch (e) {
    throw new KmsError(`Cloud KMS did not answer: ${(e as Error).message}`);
  }
  const j = await res.json().catch(() => ({}));
  if (!res.ok) throw new KmsError(String(j?.error?.message || `HTTP ${res.status}`).slice(0, 300), res.status);
  return j;
}

export const getKey = (cfg: GeminiConfig, ring: string, name: string) => kms(cfg, `${ring}/cryptoKeys/${name}`);

// Each answer says which key version did the work and its protection level, so the two roles Counta is given (Encrypter/
// Decrypter and Signer/Verifier) are all it needs: reading a key's settings would take another role.
export async function encryptDetail(cfg: GeminiConfig, ring: string, plain: Uint8Array, aad?: string): Promise<{ ciphertext: string; version: string; protectionLevel: string }> {
  const j = await kms(cfg, `${ring}/cryptoKeys/${CREDENTIALS_KEY}:encrypt`, { plaintext: b64(plain), ...(aad ? { additionalAuthenticatedData: b64(new TextEncoder().encode(aad)) } : {}) });
  if (!j.ciphertext) throw new KmsError('Cloud KMS sent no ciphertext.');
  return { ciphertext: String(j.ciphertext), version: String(j.name || ''), protectionLevel: String(j.protectionLevel || '') };
}
export const encrypt = async (cfg: GeminiConfig, ring: string, plain: Uint8Array, aad?: string) => (await encryptDetail(cfg, ring, plain, aad)).ciphertext;

export async function decrypt(cfg: GeminiConfig, ring: string, ciphertext: string, aad?: string): Promise<Uint8Array> {
  const j = await kms(cfg, `${ring}/cryptoKeys/${CREDENTIALS_KEY}:decrypt`, { ciphertext, ...(aad ? { additionalAuthenticatedData: b64(new TextEncoder().encode(aad)) } : {}) });
  return unb64(String(j.plaintext || ''));
}

// The newest enabled version of the signing key (asymmetric keys have no primary version). Listing versions takes a role
// Counta is not given (Cloud KMS Viewer); without it, version 1, which is the version a new key starts with.
export async function signingVersion(cfg: GeminiConfig, ring: string): Promise<{ name: string; listed: boolean }> {
  try {
    const j = await kms(cfg, `${ring}/cryptoKeys/${SIGNING_KEY}/cryptoKeyVersions?filter=${encodeURIComponent('state=ENABLED')}`);
    const list: any[] = (j.cryptoKeyVersions || []).filter((v: any) => v.state === 'ENABLED');
    if (!list.length) throw new KmsError(`${SIGNING_KEY} has no enabled version.`);
    list.sort((a, b) => Number(String(b.name).split('/').pop()) - Number(String(a.name).split('/').pop()));
    return { name: String(list[0].name), listed: true };
  } catch (e) {
    if (e instanceof KmsError && e.status === 403) return { name: `${ring}/cryptoKeys/${SIGNING_KEY}/cryptoKeyVersions/1`, listed: false };
    throw e;
  }
}

export async function publicKey(cfg: GeminiConfig, version: string): Promise<{ pem: string; algorithm: string; protectionLevel: string }> {
  const j = await kms(cfg, `${version}/publicKey`);
  if (!j.pem) throw new KmsError('Cloud KMS sent no public key.');
  return { pem: String(j.pem), algorithm: String(j.algorithm || ''), protectionLevel: String(j.protectionLevel || '') };
}
export const publicKeyPem = async (cfg: GeminiConfig, version: string) => (await publicKey(cfg, version)).pem;

// An ECDSA P-256 signature over SHA-256(data), made inside the HSM. KMS answers in DER.
export async function sign(cfg: GeminiConfig, version: string, data: Uint8Array): Promise<Uint8Array> {
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', data as BufferSource));
  const j = await kms(cfg, `${version}:asymmetricSign`, { digest: { sha256: b64(digest) } });
  if (!j.signature) throw new KmsError('Cloud KMS sent no signature.');
  return unb64(String(j.signature));
}

// DER (SEQUENCE of two INTEGERs) to the 64-byte r||s form WebCrypto and JWS use.
export function derToRaw(der: Uint8Array, size = 32): Uint8Array {
  let i = 0;
  if (der[i++] !== 0x30) throw new Error('not a DER signature');
  const len = der[i++];
  if (len & 0x80) i += len & 0x7f;
  const int = () => {
    if (der[i++] !== 0x02) throw new Error('not a DER integer');
    const n = der[i++];
    let v = der.slice(i, i + n); i += n;
    while (v.length > size && v[0] === 0) v = v.slice(1);
    if (v.length > size) throw new Error('integer too long');
    const out = new Uint8Array(size); out.set(v, size - v.length); return out;
  };
  const r = int(), s = int();
  const out = new Uint8Array(size * 2); out.set(r, 0); out.set(s, size);
  return out;
}

export async function verify(pem: string, data: Uint8Array, der: Uint8Array): Promise<boolean> {
  const spki = unb64(pem.replace(/-----[^-]+-----/g, '').replace(/\s+/g, ''));
  const key = await crypto.subtle.importKey('spki', spki, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
  return crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, derToRaw(der) as BufferSource, data as BufferSource);
}
