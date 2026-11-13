import { assert, assertEquals } from 'jsr:@std/assert@1';
import { deriveMerge, type LetterBody, renderModel } from './letter.ts';
// The default letter as private.letter_default_body() returns it (Task 20 regenerates the file and compares it with the SQL).
import bodyJson from './default_letter.json' with { type: 'json' };

const body = bodyJson as unknown as LetterBody;

Deno.test('render_numbering_full', () => {
  const r = renderModel(body, { 'service.advisory': true, 'service.bookkeeping': true }, 'full');
  assertEquals(r.find((b) => b.id === 'scope')!.number, '1.');
  assertEquals(r.find((b) => b.id === 'svc_bookkeeping')!.number, '(b)');
  assertEquals(r.find((b) => b.id === 'svc_bookkeeping')!.ref, '1.1(b)');
  assertEquals(r.find((b) => b.id === 'term')!.ref, '13');
  assert(r.some((b) => b.text.includes('paragraph 1.1(b) applies')));
});
Deno.test('render_renumbers_when_services_off', () => {
  const r = renderModel(body, { 'service.advisory': false, 'service.bookkeeping': true }, 'involved');
  assertEquals(r.find((b) => b.id === 'svc_bookkeeping')!.number, '(a)');
  assert(r.some((b) => b.text.includes('paragraph 1.1(a) applies')));
  assert(!r.some((b) => b.text.startsWith('Full mandate.')));            // 2.2 dropped, 2.3 becomes 2.2
  assert(!renderModel(body, { 'service.bookkeeping': false }, 'full').some((b) => b.text.includes('paragraph 1.1(')));
});
Deno.test('render_inline_and_fields', () => {
  const t = renderModel(body, { 'client.name': 'Ada Foods Ltd', 'proposal.date': '' }, 'involved').map((b) => b.text).join('\n');
  assert(t.includes('act for Ada Foods Ltd') && !t.includes('our proposal dated'));
});
Deno.test('derive_merge_amounts', () => {
  const m = deriveMerge({ 'fees.amount': 250000, 'client.name': 'Ada Foods Ltd' });
  assertEquals(m['fees.amount'], 'NGN 250,000.00'); assertEquals(m['fees.amount_words'], 'two hundred and fifty thousand naira only'); assertEquals(m['client.name_upper'], 'ADA FOODS LTD');
});
