import { assert, assertEquals, assertStringIncludes } from 'jsr:@std/assert@1';
import { calibrate, isAssetAccount, systemPrompt, tradeLine, tradesIn, userPrompt, type Ctx } from './bookkeeper.ts';

const accounts = [
  { code: '1511', name: 'Motor Vehicles' }, { code: '1512', name: 'Buses and trucks' }, { code: '1514', name: 'Office Equipment' },
  { code: '1517', name: 'Computer Hardware' }, { code: '5101', name: 'Purchases' }, { code: '6209', name: 'Repairs & Maintenance' },
  { code: '4516', name: 'Sundry Income' },
];
const ctx = (over: Partial<Ctx['org']> = {}, assets: Ctx['assets'] = []): Ctx => ({
  org: { name: 'Test Ltd', threshold: 0.8, capitalisation_threshold: 100000, ...over },
  lines: [
    { id: 'a', date: '2026-03-05', amount: -450000, narration: 'SLOT SYSTEMS LAPTOPS' },
    { id: 'b', date: '2026-03-06', amount: -40000, narration: 'MOUSE AND KEYBOARD' },
    { id: 'c', date: '2026-03-07', amount: 3000000, narration: 'SALE OF HILUX' },
    { id: 'd', date: '2026-03-08', amount: -9000000, narration: 'TOYOTA CAMRY' },
  ],
  accounts, customers: [], vendors: [], directors: [], assets,
});
const ans = (line_id: string, account_code: string, confidence = 0.95) => ({ line_id, account_code, confidence, title: 't', rationale: 'r', kind: 'asset', alternatives: [] });

Deno.test('asset_accounts', () => {
  assert(isAssetAccount('1501') && isAssetAccount('1517') && isAssetAccount('1527'));
  assert(!isAssetAccount('1500') && !isAssetAccount('1528') && !isAssetAccount('1560') && !isAssetAccount('1203') && !isAssetAccount(null));
});

Deno.test('trade_line', () => {
  assertEquals(tradeLine(null), '');
  assertEquals(tradeLine({ category: 'Cars, spare parts and auto services', sells: 'both', examples: ['Tokunbo cars', 'Spare parts'] }),
    'What the business does: Cars, spare parts and auto services; sells goods and services; for example Tokunbo cars, Spare parts.');
});

Deno.test('trades_in', () => {
  const dealer = { category: 'Cars, spare parts and auto services', sells: 'both', examples: ['Tokunbo cars'] };
  assert(tradesIn(dealer, '1511'));
  assert(!tradesIn(dealer, '1517'));
  assert(!tradesIn({ category: 'Logistics, haulage and transport', sells: 'services', examples: ['Trucks for hire'] }, '1512'), 'a service business never trades in its trucks');
  assert(tradesIn({ category: 'Phones, computers and electronics', sells: 'goods' }, '1517'));
});

Deno.test('prompt_tells_trade_threshold_and_assets', () => {
  const c = ctx({ capitalisation_threshold: 250000, trade: { category: 'Logistics, haulage and transport', sells: 'services' } },
    [{ number: 'FA-0003', name: 'Toyota Hilux', class: '1511', class_name: 'Motor vehicles', carrying: 689784.95 }]);
  const sys = systemPrompt(c);
  assertStringIncludes(sys, 'What the business does: Logistics, haulage and transport; sells services.');
  assertStringIncludes(sys, 'costing ₦250,000 or more is an asset');
  assertStringIncludes(sys, "a car dealer's cars, a phone shop's phones");
  assertStringIncludes(sys, '8. Money in from selling one of the business');
  assertStringIncludes(userPrompt(c), 'ASSETS IN USE\nFA-0003 Toyota Hilux [1511 Motor vehicles] carrying ₦689,785');
  assertStringIncludes(userPrompt(ctx()), 'ASSETS IN USE\n(none)');
  assertStringIncludes(systemPrompt(ctx({ capitalisation_threshold: null })), 'costing ₦100,000 or more');
});

Deno.test('calibrate_assets', () => {
  // A haulier's laptops above the threshold post; a small purchase coded to an asset waits.
  let out = calibrate(ctx({ trade: { category: 'Logistics', sells: 'services' } }), [ans('a', '1517'), ans('b', '1517')]);
  assertEquals(out[0].confidence, 0.95);
  assertEquals(out[1].confidence, 0.6);
  assertStringIncludes(out[1].rationale, 'below the capitalisation threshold');
  assert(out[1].question);
  // A car dealer buying a car: stock or an asset? A person decides.
  out = calibrate(ctx({ trade: { category: 'Cars, spare parts and auto services', sells: 'both', examples: ['cars'] } }), [ans('d', '1511')]);
  assertEquals(out[0].confidence, 0.6);
  assertStringIncludes(out[0].rationale, 'stock or an asset');
  // Money in for an asset: fine when the register holds one of that kind, a question when it does not.
  out = calibrate(ctx({}, [{ number: 'FA-0003', name: 'Toyota Hilux', class: '1511' }]), [ans('c', '1511', 0.9)]);
  assertEquals(out[0].confidence, 0.9);
  out = calibrate(ctx(), [ans('c', '1511', 0.9)]);
  assertEquals(out[0].confidence, 0.5);
  assertStringIncludes(out[0].rationale, 'no asset of this kind in the register');
});
