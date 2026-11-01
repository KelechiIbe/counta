// TaxStreem's seal on what Counta sends NRS: a JAdES baseline B-B signature (ETSI TS 119 182-1), a JWS in compact form
// with the payload attached. The protected header carries alg ES256, the claimed signing time as iat (JAdES 1.2.1: iat,
// not sigT, from 15 July 2025), and the signing certificate as x5c and x5t#S256. The signature is made by the HSM key; the
// payload is the invoice exactly as it went to NRS, so anyone with the seal can show what was sent, and when.

const b64url = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const unb64url = (s: string) => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (s.length % 4)) % 4)), (c) => c.charCodeAt(0));
const b64 = (b: Uint8Array) => btoa(String.fromCharCode(...b));
const enc = new TextEncoder(), dec = new TextDecoder();

export type Sealer = {
  certDer: Uint8Array;
  // Signs the bytes and answers the signature as r||s (64 bytes), as ES256 wants.
  signRaw: (data: Uint8Array) => Promise<Uint8Array>;
};

export async function seal(payload: string, s: Sealer, now = Date.now()): Promise<string> {
  const thumb = new Uint8Array(await crypto.subtle.digest('SHA-256', s.certDer as BufferSource));
  const header = { alg: 'ES256', typ: 'jose', cty: 'json', iat: Math.floor(now / 1000), 'x5t#S256': b64url(thumb), x5c: [b64(s.certDer)] };
  const input = `${b64url(enc.encode(JSON.stringify(header)))}.${b64url(enc.encode(payload))}`;
  const sig = await s.signRaw(enc.encode(input));
  if (sig.length !== 64) throw new Error('The HSM gave a signature of the wrong size.');
  return `${input}.${b64url(sig)}`;
}

// What a seal says and whether it holds: the signature against the certificate it names, and the thumbprint against that
// certificate. Used by the tests and by anyone checking a seal; Counta's own check of the certificate itself is that it
// is the one it made for the HSM key.
export async function openSeal(jws: string): Promise<{ ok: boolean; header: Record<string, any>; payload: string; certDer: Uint8Array; why?: string }> {
  const parts = jws.split('.');
  if (parts.length !== 3) return { ok: false, header: {}, payload: '', certDer: new Uint8Array(), why: 'not a compact JWS' };
  const header = JSON.parse(dec.decode(unb64url(parts[0])));
  const payload = dec.decode(unb64url(parts[1]));
  const certDer = Uint8Array.from(atob(String(header.x5c?.[0] ?? '')), (c) => c.charCodeAt(0));
  const fail = (why: string) => ({ ok: false, header, payload, certDer, why });
  if (header.alg !== 'ES256') return fail('alg is not ES256');
  if (!Number.isInteger(header.iat)) return fail('no iat');
  const thumb = b64url(new Uint8Array(await crypto.subtle.digest('SHA-256', certDer as BufferSource)));
  if (thumb !== header['x5t#S256']) return fail('x5t#S256 does not match the certificate');
  const spki = certSpki(certDer);
  const key = await crypto.subtle.importKey('spki', spki as BufferSource, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
  const good = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, unb64url(parts[2]) as BufferSource, enc.encode(`${parts[0]}.${parts[1]}`) as BufferSource);
  return good ? { ok: true, header, payload, certDer } : fail('the signature does not verify');
}

// The SubjectPublicKeyInfo inside a certificate: tbsCertificate's seventh element (version, serial, signature, issuer,
// validity, subject, subjectPublicKeyInfo).
export function certSpki(der: Uint8Array): Uint8Array {
  let i = 0;
  const head = () => {
    const tag = der[i++];
    let n = der[i++];
    if (n & 0x80) { const k = n & 0x7f; n = 0; for (let j = 0; j < k; j++) n = (n << 8) | der[i++]; }
    return { tag, n };
  };
  head(); // Certificate
  head(); // tbsCertificate
  for (let k = 0; k < 7; k++) {
    const start = i;
    const h = head();
    if (k === 0 && h.tag !== 0xa0) { i = start; continue; } // no explicit version
    if (k === 6) return der.slice(start, i + h.n);
    i += h.n;
  }
  throw new Error('no public key in the certificate');
}
