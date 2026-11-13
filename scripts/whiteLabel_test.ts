import { assertEquals } from 'jsr:@std/assert@1';
import { showPoweredBy } from '../src/lib/whiteLabel.ts';

Deno.test('powered_by_hidden_when_org_unknown', () => {
  assertEquals(showPoweredBy(undefined, undefined), false);
  assertEquals(showPoweredBy(null), false);
});
Deno.test('powered_by_follows_white_label', () => {
  assertEquals(showPoweredBy(undefined, false), true);
  assertEquals(showPoweredBy(undefined, true), false);
  assertEquals(showPoweredBy({ white_label: true }), false);
  assertEquals(showPoweredBy({ white_label: false }), true);
  assertEquals(showPoweredBy({}), true);
});
