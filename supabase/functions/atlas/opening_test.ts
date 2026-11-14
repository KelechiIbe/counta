import { assertEquals, assertStringIncludes } from 'jsr:@std/assert@1';
import { ASSET_CLASSES, OPENING_KEYS, OPENING_SCHEMA, openingOut, openingSystem } from './opening.ts';

Deno.test('opening_keys_match_the_database', () => {
  // The keys public.filing_opening_save posts, in the same order as its map.
  assertEquals(Object.keys(OPENING_KEYS), ['inventory', 'trade_receivables', 'other_receivables', 'prepayments', 'director_receivable', 'investments',
    'trade_payables', 'accruals', 'other_payables', 'director_payable', 'tax_payable', 'loans_short', 'loans_long', 'shareholder_loans', 'share_capital',
    'share_premium', 'deposit_for_shares', 'retained_earnings']);
  assertEquals(Object.keys(ASSET_CLASSES).length, 27);
  assertEquals(ASSET_CLASSES['1511'], 'Motor vehicles');
});

Deno.test('opening_out_cleans_the_reading', () => {
  const r = openingOut({
    is_accounts: true, entity_name: 'Femi Motors Ltd', as_of: '2023-12-31', confidence: 87.6, warnings: ['Figures in thousands'],
    lines: [
      { key: 'inventory', caption: 'Inventories', amount: 4000000 },
      { key: 'trade_receivables', caption: 'Trade receivables', amount: 1200000.004 },
      { key: 'trade_receivables', caption: 'Other debtors', amount: 300000 },
      { key: 'trade_payables', caption: 'Trade payables', amount: -1500000 },
      { key: 'retained_earnings', caption: 'Accumulated deficit', amount: -300000 },
      { key: 'cash', caption: 'Cash at bank', amount: 2500000 },
      { key: 'cash', caption: 'Cash in hand', amount: 20000 },
      { key: 'goodwill', caption: 'Goodwill', amount: 50000 },
      { key: 'accruals', caption: 'Accruals', amount: 0 },
      { key: 'loans_long', caption: 'Bank loan', amount: 'n/a' },
    ],
    assets: [
      { class_account: '1511', name: 'Motor vehicles', cost: 6000000, accumulated: 7000000 },
      { class_account: '1514', name: '  Office   equipment ', cost: 240000, accumulated: null, in_use_from: '2023-06-01' },
      { class_account: '9999', name: 'Nonsense', cost: 1 },
      { class_account: '1517', name: 'Laptops', cost: 0 },
    ],
  });
  assertEquals(r.as_of, '2023-12-31');
  assertEquals(r.confidence, 88);
  assertEquals(r.lines, [
    { key: 'inventory', amount: 4000000, captions: ['Inventories'] },
    { key: 'trade_receivables', amount: 1500000, captions: ['Trade receivables', 'Other debtors'] },
    { key: 'trade_payables', amount: 1500000, captions: ['Trade payables'] },
    { key: 'retained_earnings', amount: -300000, captions: ['Accumulated deficit'] },
  ]);
  assertEquals(r.cash, 2520000);
  assertEquals(r.other, [{ caption: 'Goodwill', amount: 50000 }]);
  assertEquals(r.assets, [
    { class_account: '1511', name: 'Motor vehicles', cost: 6000000, accumulated: 6000000, in_use_from: null },
    { class_account: '1514', name: 'Office equipment', cost: 240000, accumulated: 0, in_use_from: '2023-06-01' },
  ]);
  assertEquals(openingOut(null), { is_accounts: false, entity_name: null, as_of: null, lines: [], assets: [], cash: 0, other: [], confidence: 0, warnings: [] });
});

Deno.test('opening_prompt_and_schema', () => {
  const p = openingSystem(2024);
  assertStringIncludes(p, 'for the year before 2024');
  assertStringIncludes(p, 'the opening position of 2024');
  assertStringIncludes(p, 'inventory (inventories, stock)');
  assertStringIncludes(p, '1511 Motor vehicles');
  assertStringIncludes(openingSystem(null), 'for the year before the year being filed');
  assertEquals((OPENING_SCHEMA.properties.lines.items.properties.key as any).enum.slice(-2), ['cash', 'other']);
  assertEquals((OPENING_SCHEMA.properties.assets.items.properties.class_account as any).enum.length, 27);
});
