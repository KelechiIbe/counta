// The signature Counta uses with Flux and the bot: x-counta-signature: t=<unix seconds>,v1=<hex HMAC-SHA256 of "<t>.<raw body>">.
import { createHmac, timingSafeEqual } from 'node:crypto';

export function sign(raw: string, secret: string, now = Math.floor(Date.now() / 1000)) {
  const v1 = createHmac('sha256', secret).update(`${now}.${raw}`).digest('hex');
  return `t=${now},v1=${v1}`;
}

export function verify(raw: string, header: string | null | undefined, secret: string, now = Math.floor(Date.now() / 1000)) {
  if (!secret || !header) return false;
  const t = Number(header.match(/(?:^|,)\s*t=(\d+)/)?.[1]);
  const v1 = header.match(/(?:^|,)\s*v1=([0-9a-f]{64})/)?.[1];
  if (!t || !v1 || Math.abs(now - t) > 300) return false;
  const want = Buffer.from(createHmac('sha256', secret).update(`${t}.${raw}`).digest('hex'), 'hex');
  const got = Buffer.from(v1, 'hex');
  return want.length === got.length && timingSafeEqual(want, got);
}
