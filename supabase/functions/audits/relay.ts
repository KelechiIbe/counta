// The transfer relay (relay/ in the repository): a small server with one fixed address that passes Counta's signed requests
// to Flutterwave, for the calls Flutterwave takes only from TaxStreem's whitelisted address. The audits function sends the
// firms' subaccount calls through it. Signing is the same as the payments function's: HMAC-SHA256, with the relay's shared
// secret, over the time, method, path (with its query) and body.

// The paths the audits function sends through the relay.
export const RELAY_PATH = /^\/subaccounts(\/|\?|$)/;

// The relay's secret is 64 hex characters; a value saved with the server's prompt or "RELAY_SECRET=" around it still works.
export function relayKey(raw: string): string {
  return raw.match(/[0-9a-f]{64}/i)?.[0].toLowerCase() || raw;
}

export async function hmacHex(key: string, body: string): Promise<string> {
  const k = await crypto.subtle.importKey('raw', new TextEncoder().encode(key), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(body)));
  return Array.from(sig).map((x) => x.toString(16).padStart(2, '0')).join('');
}

// The headers of one signed request through the relay. ts: seconds since 1970 (the relay refuses one over five minutes old).
export async function relayHeaders(key: string, method: string, path: string, body: string, flwKey: string, ts = Math.floor(Date.now() / 1000)) {
  const t = String(ts);
  return {
    'Content-Type': 'application/json', 'X-Relay-Timestamp': t, 'X-Relay-Signature': await hmacHex(key, `${t}\n${method}\n${path}\n${body}`),
    'X-Flw-Authorization': `Bearer ${flwKey}`,
  };
}

// What the relay's own answer means. Its messages start "Relay:". A path it does not forward (a relay not yet updated to
// forward subaccounts) sent nothing, so the call can go straight to Flutterwave instead. Any other refusal also sent
// nothing. No answer from Flutterwave (504) means the request may have gone.
export function relayRefusal(status: number, text: string): 'not_forwarded' | 'refused' | 'no_answer' | null {
  let msg = '';
  try { msg = String(JSON.parse(text)?.message || ''); } catch { /* not json */ }
  if (!msg.startsWith('Relay:')) return null;
  if (status === 504) return 'no_answer';
  if (/this path is not forwarded/.test(msg)) return 'not_forwarded';
  return 'refused';
}
