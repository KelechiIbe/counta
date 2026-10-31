// Prism's channel for partners (part 3). Prism, TaxStreem's product for partners, passes their invoices to Counta signed
// with the secret Prism's bills use (TAXSTREEM_SSO_SECRET): x-taxstreem-signature: t=<unix seconds>,v1=<hex HMAC-SHA256 of
// "<t>.<raw body>">, at most five minutes old. Counta's callbacks to Prism are signed the same way, in x-counta-signature.
// See docs/prism-einvoicing.md.

const enc = new TextEncoder();
const hmacKey = (secret: string, use: KeyUsage[]) => crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, use);

export async function verifySigned(raw: string, header: string | null, secret: string, now = Math.floor(Date.now() / 1000)): Promise<boolean> {
  if (!secret || !header) return false;
  const t = Number(header.match(/(?:^|,)\s*t=(\d+)/)?.[1]);
  const v1 = header.match(/(?:^|,)\s*v1=([0-9a-f]{64})/)?.[1];
  if (!t || !v1 || Math.abs(now - t) > 300) return false;
  const mac = new Uint8Array(32);
  v1.match(/../g)!.forEach((h, i) => (mac[i] = parseInt(h, 16)));
  return await crypto.subtle.verify('HMAC', await hmacKey(secret, ['verify']), mac, enc.encode(`${t}.${raw}`));
}

export async function signBody(raw: string, secret: string, t = Math.floor(Date.now() / 1000)): Promise<string> {
  const mac = new Uint8Array(await crypto.subtle.sign('HMAC', await hmacKey(secret, ['sign']), enc.encode(`${t}.${raw}`)));
  return `t=${t},v1=${[...mac].map((b) => b.toString(16).padStart(2, '0')).join('')}`;
}

// An answer to Prism other than 200, with what to put right.
export class Answer extends Error {
  constructor(public status: number, public body: Record<string, unknown>) { super(String(body.error ?? 'error')); }
}

// The database's refusals: a conflict (PX409, such as e-invoicing not on yet or a number used), not found (PX404), or
// something to put right in what was sent (422).
export const dbAnswer = (e: { message: string; code?: string }, extra: Record<string, unknown> = {}) =>
  new Answer(e.code === 'PX409' ? 409 : e.code === 'PX404' ? 404 : 422, { ok: false, error: e.message, ...extra });
