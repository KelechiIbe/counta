import { assertEquals } from 'jsr:@std/assert@1';
import { RELAY_PATH, relayHeaders, relayKey, relayRefusal } from './relay.ts';

Deno.test('relay_paths', () => {
  for (const p of ['/subaccounts', '/subaccounts/2181', '/subaccounts?account_bank=058&account_number=0011223344']) assertEquals(RELAY_PATH.test(p), true, p);
  for (const p of ['/subaccountsx', '/payments', '/transactions/verify_by_reference?tx_ref=AUD-1', '/payout-subaccounts']) assertEquals(RELAY_PATH.test(p), false, p);
});

Deno.test('relay_key', () => {
  const k = 'ab'.repeat(32);
  assertEquals(relayKey(k), k);
  assertEquals(relayKey(`RELAY_SECRET=${k.toUpperCase()}`), k);
  assertEquals(relayKey('short'), 'short');
});

// The relay checks HMAC-SHA256 of "time\nmethod\npath\nbody" with the shared secret (relay/server.mjs, signedOk).
Deno.test('relay_signature_matches_the_server', async () => {
  const h = await relayHeaders('a'.repeat(64), 'POST', '/subaccounts', '{"a":1}', 'FLWSECK_TEST-x', 1794650000);
  assertEquals(h, {
    'Content-Type': 'application/json', 'X-Relay-Timestamp': '1794650000',
    'X-Relay-Signature': '0f8fdb7474bd145e24245879aa8104634e189abb51bae4a9ac3a167eebcc38e5',
    'X-Flw-Authorization': 'Bearer FLWSECK_TEST-x',
  });
});

Deno.test('relay_refusals', () => {
  assertEquals(relayRefusal(403, '{"status":"error","message":"Relay: this path is not forwarded."}'), 'not_forwarded');
  assertEquals(relayRefusal(401, '{"status":"error","message":"Relay: bad_signature"}'), 'refused');
  assertEquals(relayRefusal(504, '{"status":"error","message":"Relay: Flutterwave did not answer."}'), 'no_answer');
  // Flutterwave's own answers pass through untouched.
  assertEquals(relayRefusal(400, '{"status":"error","message":"A subaccount with the account number already exists"}'), null);
  assertEquals(relayRefusal(200, '{"status":"success","data":{"id":2181}}'), null);
  assertEquals(relayRefusal(502, 'Bad gateway'), null);
});
