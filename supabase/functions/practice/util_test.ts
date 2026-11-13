import { assert, assertEquals } from 'jsr:@std/assert@1';
import { clientIp, exportable, pngFromDataUrl, sha256Hex, tokenOk } from './util.ts';

Deno.test('client_ip', () => assertEquals(clientIp(new Request('http://x', { headers: { 'x-forwarded-for': '203.0.113.9, 10.0.0.1' } })), '203.0.113.9'));
Deno.test('sha256_vector', async () => assertEquals(await sha256Hex(new TextEncoder().encode('abc')), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'));
Deno.test('token_ok', () => { assert(tokenOk('es_' + 'a'.repeat(48), 'es')); assert(!tokenOk('es_' + 'a'.repeat(47), 'es')); assert(!tokenOk('dc_' + 'a'.repeat(48), 'es')); });
Deno.test('png_data_url', () => assertEquals(pngFromDataUrl('data:image/jpeg;base64,AAAA'), null));
Deno.test('export_skips_kyc', () => {
  const org = '11111111-1111-4111-8111-111111111111';
  assert(exportable(`${org}/documents/receipt.pdf`, org));
  assert(!exportable(`${org}/kyc/nin-slip-1.pdf`, org) && !exportable(`${org}/kyc/cac.pdf`, org));
  assert(!exportable(`22222222-2222-4222-8222-222222222222/documents/x.pdf`, org));
});
