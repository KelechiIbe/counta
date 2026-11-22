import { assertEquals, assert } from 'jsr:@std/assert@1';
import { cleanWht, whtPrompt, type WhtType } from './wht.ts';

const TYPES: WhtType[] = [
  { code: 'professional', name: 'Professional, consultancy, technical and management services', rate: 0.05 },
  { code: 'services', name: 'Other services', rate: 0.02 },
  { code: 'goods', name: 'Supply of goods', rate: 0.02 },
  { code: 'ex_reimbursable', name: 'Not subject: out-of-pocket costs reimbursed', rate: 0 },
];

Deno.test('the prompt lists the codes with the business rate and numbers the lines', () => {
  const p = whtPrompt({ name: 'Line Tech Ltd', legal_form: 'company', category: 'Technology', products: ['Router'] }, TYPES,
    ['Technology Implementation Services', 'Supply of Huggies Diapers']);
  assert(p.includes('professional: Professional, consultancy, technical and management services (5%)'));
  assert(p.includes('goods: Supply of goods (2%)'));
  assert(p.includes('1: Technology Implementation Services'));
  assert(p.includes('2: Supply of Huggies Diapers'));
  assert(p.includes('Products on its list: Router.'));
  assert(!p.includes('\n\n\n'));
});

Deno.test('answers are matched by id, unknown codes dropped and confidence kept between 0 and 1', () => {
  const lines = ['Technology Implementation Services', 'Medical services', 'Supply of Huggies Diapers', 'Taxi fare'];
  const got = cleanWht(lines, [
    { id: '3', code: 'goods', confidence: 0.95, reason: 'Retail of nappies' },
    { id: '1', code: ' professional ', confidence: 1.4, reason: '  Technical   work ' },
    { id: '2', code: 'medical', confidence: 0.9, reason: 'Not a code' },
  ], TYPES, 'gemini-x');
  assertEquals(got.map((a) => a.category), ['professional', null, 'goods', null]);
  assertEquals(got[0].confidence, 1);
  assertEquals(got[0].reason, 'Technical work');
  assertEquals(got[1].confidence, 0);
  assertEquals(got[3].category, null);
  assertEquals(got[2].model, 'gemini-x');
  assertEquals(got[2].description, 'Supply of Huggies Diapers');
});

Deno.test('a malformed answer gives no codes', () => {
  assertEquals(cleanWht(['A', 'B'], null, TYPES).map((a) => a.category), [null, null]);
  assertEquals(cleanWht(['A'], [{ code: 'goods' }], TYPES)[0].category, null);
});
