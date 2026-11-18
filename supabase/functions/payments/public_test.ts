import { assertEquals } from 'jsr:@std/assert@1';
import { publicCheckEvery, publicView } from './public.ts';

Deno.test('the rail is read every 5 seconds for three minutes after the customer says they paid, every 15 otherwise', () => {
  const now = Date.parse('2026-11-18T10:00:00Z');
  assertEquals(publicCheckEvery(null, now), 15_000);
  assertEquals(publicCheckEvery('', now), 15_000);
  assertEquals(publicCheckEvery('not a date', now), 15_000);
  assertEquals(publicCheckEvery('2026-11-18T09:59:00Z', now), 5_000);
  assertEquals(publicCheckEvery('2026-11-18T09:57:00.001Z', now), 5_000);
  assertEquals(publicCheckEvery('2026-11-18T09:57:00Z', now), 15_000);
  assertEquals(publicCheckEvery('2026-11-18T10:01:00Z', now), 15_000);
});

Deno.test('the payer sees the claim and nothing private', () => {
  const v = publicView({ id: 'x', tx_ref: 'CNT-1', method: 'account', status: 'pending', amount: 107500, direct: true, pay_ref: 'INV-0001',
    claimed_at: '2026-11-18T09:59:00Z', claim: { amount: 102500, name: 'Bola' }, claim_flagged: false, sale_id: 's', payer: { name: 'x' } })!;
  assertEquals(v.claimed_at, '2026-11-18T09:59:00Z');
  assertEquals(v.claim_amount, 102500);
  assertEquals(v.claim_flagged, false);
  assertEquals(v.pay_ref, 'INV-0001');
  assertEquals('tx_ref' in v || 'id' in v || 'sale_id' in v || 'payer' in v, false);
  const s = publicView({ method: 'account', status: 'pending', amount: 1, claim_amount: 5, claim_flagged: true })!;
  // A request row straight from the database says when the business was asked.
  assertEquals(publicView({ method: 'account', status: 'pending', amount: 1, claim: { amount: 7 }, claim_flagged_at: '2026-11-18T10:00:00Z' })!.claim_flagged, true);
  assertEquals([s.claim_amount, s.claim_flagged, s.claimed_at], [5, true, undefined]);
  assertEquals(publicView({ method: 'link', status: 'failed', amount: 1, direct: false, pay_ref: 'X' })!.pay_ref, undefined);
  assertEquals(publicView(null), null);
});
