import { assertEquals, assertRejects } from 'jsr:@std/assert@1';
import { contact, LookupError, localPhone, lookupWith, ninDigits, ninLookup, ninPerson } from './mono_lookup.ts';

Deno.test('mono_lookup_phones_and_nins', () => {
  assertEquals([localPhone('+234 803 123 4567'), localPhone('2348031234567'), localPhone('8031234567'), localPhone('08031234567'),
    localPhone('0123 456 7890'), localPhone('12'), localPhone(null)], ['08031234567', '08031234567', '08031234567', '08031234567', null, null, null]);
  assertEquals([ninDigits('123 4567 8901'), ninDigits('1234567890'), ninDigits(undefined)], ['12345678901', null, null]);
});

Deno.test('mono_lookup_nin_record', () => {
  assertEquals(ninPerson({ data: { firstName: ' Ada ', middleName: 'Grace', lastName: 'Obi', phone_number: '0803 123 4567', photo: 'x' } }),
    { first: 'Ada', middle: 'Grace', last: 'Obi', phone: '08031234567' });
  assertEquals(ninPerson({ firstname: 'ADA', surname: 'OBI', telephoneno: '' }), { first: 'ADA', middle: null, last: 'OBI', phone: null });
});

Deno.test('mono_lookup_contacts', () => {
  assertEquals(contact({ firstname: 'Ada', other_name: 'Grace', surname: 'Obi', email: ' ADA@X.Example.Test', phone_number: '+2348031234567', identity_number: '1' }),
    { surname: 'OBI', given: 'ADA GRACE', email: 'ada@x.example.test', phone: '08031234567' });
  assertEquals(contact({ corporation_name: 'Holdings Ltd' }), null);
  assertEquals(contact({ firstname: 'Ada', surname: 'Obi', email: 'nope' })?.email, null);
});

Deno.test('mono_lookup_http', async () => {
  const f = (async (url: string | URL | Request) => String(url).endsWith('/v3/lookup/nin')
    ? new Response(JSON.stringify({ status: 'failed', message: 'Provider timed out' }), { status: 502 })
    : new Response('{}', { status: 404 })) as typeof fetch;
  const lookup = lookupWith(f, 'https://mono.example.test/', 'k');
  const e = await assertRejects(() => ninLookup(lookup, '12345678901'), LookupError);
  assertEquals([e.status, e.reason], [502, 'Provider timed out']);
  assertEquals((await lookup('/v3/lookup/cac/company/1/directors')).status, 404);
});
