// Verifying what TaxStreem sends: the signed sign-in token (JWT, HS256) and signed server-to-server requests.

const enc = new TextEncoder();

function b64urlDecode(s: string): Uint8Array<ArrayBuffer> {
  const pad = s.length % 4 === 0 ? '' : '='.repeat(4 - (s.length % 4));
  const bin = atob(s.replace(/-/g, '+').replace(/_/g, '/') + pad);
  const out = new Uint8Array(new ArrayBuffer(bin.length));
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
export function b64urlEncode(b: Uint8Array | string): string {
  const bytes = typeof b === 'string' ? enc.encode(b) : b;
  let bin = '';
  for (const x of bytes) bin += String.fromCharCode(x);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function hmacKey(secret: string, usage: KeyUsage[]) {
  return await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, usage);
}

export class SsoError extends Error {}

export type SsoClaims = {
  iss: string; aud: string | string[]; exp: number; iat: number; jti: string; sub: string;
  email: string; email_verified: boolean; name?: string; phone?: string;
  org: { id: string; name?: string; email?: string; phone?: string; tin?: string; rc_number?: string; vat_registered?: boolean };
  role?: string; rail?: string; next?: string;
};

// Checks the signature, who issued it, who it is for, and that it is fresh. A token lives at most ten minutes.
export async function verifySsoToken(token: string, secret: string, opts: { issuer?: string; now?: number } = {}): Promise<SsoClaims> {
  if (!secret) throw new SsoError('Sign-in from TaxStreem is not set up yet.');
  const parts = String(token || '').split('.');
  if (parts.length !== 3) throw new SsoError('This sign-in link is not valid.');
  let header: any, claims: any;
  try {
    header = JSON.parse(new TextDecoder().decode(b64urlDecode(parts[0])));
    claims = JSON.parse(new TextDecoder().decode(b64urlDecode(parts[1])));
  } catch { throw new SsoError('This sign-in link is not valid.'); }
  if (header?.alg !== 'HS256') throw new SsoError('This sign-in link is not valid.');
  const ok = await crypto.subtle.verify('HMAC', await hmacKey(secret, ['verify']), b64urlDecode(parts[2]), enc.encode(`${parts[0]}.${parts[1]}`));
  if (!ok) throw new SsoError('This sign-in link is not valid.');
  const now = opts.now ?? Math.floor(Date.now() / 1000);
  const issuer = opts.issuer || 'taxstreem';
  const aud = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (claims.iss !== issuer || !aud.includes('counta')) throw new SsoError('This sign-in link was not made for Counta.');
  if (typeof claims.exp !== 'number' || claims.exp < now - 30) throw new SsoError('This sign-in link has expired. Open Counta from TaxStreem again.');
  if (typeof claims.iat !== 'number' || claims.iat > now + 60 || claims.exp - claims.iat > 600) throw new SsoError('This sign-in link is not valid.');
  if (!claims.jti || typeof claims.jti !== 'string' || claims.jti.length > 200) throw new SsoError('This sign-in link is not valid.');
  if (!claims.email || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(claims.email)) throw new SsoError('TaxStreem did not send an email address.');
  // TaxStreem must have confirmed the address: otherwise anyone could claim someone else's email and enter their business.
  if (claims.email_verified !== true) throw new SsoError('Confirm your email address on TaxStreem first.');
  if (!claims.org?.id) throw new SsoError('TaxStreem did not say which business this is.');
  if (claims.next && !(typeof claims.next === 'string' && /^\/(?!\/)[\w\-/?=&.%]*$/.test(claims.next))) delete claims.next;
  claims.email = String(claims.email).trim().toLowerCase();
  return claims as SsoClaims;
}

// For tests and for TaxStreem's own reference implementation.
export async function signSsoToken(claims: Record<string, unknown>, secret: string) {
  const h = b64urlEncode(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const p = b64urlEncode(JSON.stringify(claims));
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', await hmacKey(secret, ['sign']), enc.encode(`${h}.${p}`)));
  return `${h}.${p}.${b64urlEncode(sig)}`;
}

// Server-to-server requests from TaxStreem (Prism bills): header x-taxstreem-signature: t=<unix seconds>,v1=<hex HMAC-SHA256 of "<t>.<raw body>">.
export async function signBody(raw: string, secret: string, t = Math.floor(Date.now() / 1000)) {
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', await hmacKey(secret, ['sign']), enc.encode(`${t}.${raw}`)));
  return `t=${t},v1=${Array.from(sig).map((x) => x.toString(16).padStart(2, '0')).join('')}`;
}

export async function verifyBody(raw: string, header: string | null, secret: string, now = Math.floor(Date.now() / 1000)) {
  if (!secret || !header) return false;
  const t = Number(header.match(/(?:^|,)\s*t=(\d+)/)?.[1]);
  const v1 = header.match(/(?:^|,)\s*v1=([0-9a-f]{64})/)?.[1];
  if (!t || !v1 || Math.abs(now - t) > 300) return false;
  const bytes = new Uint8Array(new ArrayBuffer(32));
  v1.match(/../g)!.forEach((h, i) => (bytes[i] = parseInt(h, 16)));
  return await crypto.subtle.verify('HMAC', await hmacKey(secret, ['verify']), bytes, enc.encode(`${t}.${raw}`));
}
