// A self-signed X.509 certificate for TaxStreem's invoice-signing key in the HSM (EC P-256), so a JAdES seal can name its
// signer (x5c, x5t#S256) and anyone can check it. The certificate's own signature is made by the HSM like every seal; the
// private half never leaves it. A certificate from a certification authority can replace it later.
//
// DER, the small part of it a certificate needs (X.690): SEQUENCE, SET, INTEGER, OBJECT IDENTIFIER, strings, times, BIT
// STRING, OCTET STRING, BOOLEAN and explicit context tags.

const tlv = (tag: number, body: Uint8Array): Uint8Array => {
  const n = body.length;
  const len = n < 0x80 ? [n] : n < 0x100 ? [0x81, n] : n < 0x10000 ? [0x82, n >> 8, n & 0xff] : [0x83, n >> 16, (n >> 8) & 0xff, n & 0xff];
  const out = new Uint8Array(1 + len.length + n);
  out[0] = tag; out.set(len, 1); out.set(body, 1 + len.length);
  return out;
};
const cat = (...parts: Uint8Array[]) => {
  const out = new Uint8Array(parts.reduce((a, p) => a + p.length, 0));
  let i = 0;
  for (const p of parts) { out.set(p, i); i += p.length; }
  return out;
};
export const seq = (...p: Uint8Array[]) => tlv(0x30, cat(...p));
const set = (...p: Uint8Array[]) => tlv(0x31, cat(...p));
// A positive INTEGER from big-endian bytes: leading zeros dropped, one added when the top bit is set.
const intBytes = (b: Uint8Array) => {
  let i = 0;
  while (i < b.length - 1 && b[i] === 0) i++;
  const v = b.slice(i);
  return tlv(0x02, v[0] & 0x80 ? cat(new Uint8Array([0]), v) : v);
};
const intSmall = (n: number) => tlv(0x02, new Uint8Array([n]));
export const oid = (dotted: string) => {
  const [a, b, ...rest] = dotted.split('.').map(Number);
  const out = [40 * a + b];
  for (const n of rest) {
    const groups: number[] = [];
    let v = n;
    do { groups.unshift(v & 0x7f); v = Math.floor(v / 128); } while (v > 0);
    for (let i = 0; i < groups.length - 1; i++) groups[i] |= 0x80;
    out.push(...groups);
  }
  return tlv(0x06, new Uint8Array(out));
};
const enc = new TextEncoder();
const utf8 = (s: string) => tlv(0x0c, enc.encode(s));
const printable = (s: string) => tlv(0x13, enc.encode(s));
const two = (n: number) => String(n).padStart(2, '0');
// UTCTime for years before 2050, as RFC 5280 asks.
const time = (d: Date) => {
  const y = d.getUTCFullYear();
  const body = `${y < 2050 ? two(y % 100) : y}${two(d.getUTCMonth() + 1)}${two(d.getUTCDate())}${two(d.getUTCHours())}${two(d.getUTCMinutes())}${two(d.getUTCSeconds())}Z`;
  return tlv(y < 2050 ? 0x17 : 0x18, enc.encode(body));
};
const bits = (b: Uint8Array, unused = 0) => tlv(0x03, cat(new Uint8Array([unused]), b));
const octets = (b: Uint8Array) => tlv(0x04, b);
const bool = (v: boolean) => tlv(0x01, new Uint8Array([v ? 0xff : 0]));
const explicit = (n: number, body: Uint8Array) => tlv(0xa0 + n, body);

const ECDSA_SHA256 = '1.2.840.10045.4.3.2';
const OIDS = { C: '2.5.4.6', O: '2.5.4.10', OU: '2.5.4.11', CN: '2.5.4.3', basicConstraints: '2.5.29.19', keyUsage: '2.5.29.15', subjectKeyId: '2.5.29.14' };

export const pemBody = (pem: string) => Uint8Array.from(atob(pem.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '')), (c) => c.charCodeAt(0));
export const toPem = (der: Uint8Array, label = 'CERTIFICATE') => {
  const b64 = btoa(String.fromCharCode(...der));
  return `-----BEGIN ${label}-----\n${b64.match(/.{1,64}/g)!.join('\n')}\n-----END ${label}-----\n`;
};
const hex = (b: Uint8Array) => [...b].map((x) => x.toString(16).padStart(2, '0')).join('');

// The public key bits inside a SubjectPublicKeyInfo (the BIT STRING after the algorithm), for the key identifier.
function spkiKeyBits(spki: Uint8Array): Uint8Array {
  // SEQUENCE { SEQUENCE { algorithm }, BIT STRING { 00, key } }
  let i = 1;
  const readLen = () => { let n = spki[i++]; if (n & 0x80) { const k = n & 0x7f; n = 0; for (let j = 0; j < k; j++) n = (n << 8) | spki[i++]; } return n; };
  readLen();
  if (spki[i++] !== 0x30) throw new Error('not a SubjectPublicKeyInfo');
  const algLen = readLen(); // read first: `i += readLen()` would add to i as it was before the length was read
  i += algLen;
  if (spki[i++] !== 0x03) throw new Error('not a SubjectPublicKeyInfo');
  const n = readLen();
  return spki.slice(i + 1, i + n);
}

export type Subject = { CN: string; O?: string; OU?: string; C?: string };
export const subjectText = (s: Subject) => [s.CN && `CN=${s.CN}`, s.OU && `OU=${s.OU}`, s.O && `O=${s.O}`, s.C && `C=${s.C}`].filter(Boolean).join(', ');
function name(s: Subject): Uint8Array {
  const rdn = (k: keyof typeof OIDS, v: Uint8Array) => set(seq(oid(OIDS[k]), v));
  return seq(...[s.C && rdn('C', printable(s.C)), s.O && rdn('O', utf8(s.O)), s.OU && rdn('OU', utf8(s.OU)), rdn('CN', utf8(s.CN))].filter(Boolean) as Uint8Array[]);
}

// A certificate for the key in spkiPem, signed by `sign` (which returns a DER ECDSA signature over the bytes it is given).
export async function selfSignedCert(opts: { spkiPem: string; subject: Subject; days: number; sign: (tbs: Uint8Array) => Promise<Uint8Array>; now?: Date }) {
  const spki = pemBody(opts.spkiPem);
  const now = opts.now ?? new Date();
  const notBefore = new Date(Math.floor(now.getTime() / 1000) * 1000 - 3600_000);
  const notAfter = new Date(notBefore.getTime() + opts.days * 86400_000);
  const serial = crypto.getRandomValues(new Uint8Array(16));
  serial[0] &= 0x7f;
  if (serial[0] === 0) serial[0] = 1;
  const ski = new Uint8Array(await crypto.subtle.digest('SHA-1', spkiKeyBits(spki) as BufferSource));
  const extensions = seq(
    seq(oid(OIDS.basicConstraints), bool(true), octets(seq())),
    // digitalSignature and nonRepudiation (contentCommitment): bits 0 and 1, six unused bits.
    seq(oid(OIDS.keyUsage), bool(true), octets(bits(new Uint8Array([0xc0]), 6))),
    seq(oid(OIDS.subjectKeyId), octets(octets(ski))),
  );
  const alg = seq(oid(ECDSA_SHA256));
  const nm = name(opts.subject);
  const tbs = seq(explicit(0, intSmall(2)), intBytes(serial), alg, nm, seq(time(notBefore), time(notAfter)), nm, spki, explicit(3, extensions));
  const sig = await opts.sign(tbs);
  const der = seq(tbs, alg, bits(sig));
  const sha256 = hex(new Uint8Array(await crypto.subtle.digest('SHA-256', der as BufferSource)));
  return { der, pem: toPem(der), sha256, subject: subjectText(opts.subject), notBefore, notAfter };
}
