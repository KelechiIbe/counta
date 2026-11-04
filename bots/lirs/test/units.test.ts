import { test } from 'node:test';
import assert from 'node:assert/strict';
import { matchAgency, tokens } from '../src/match.js';
import { accountFromText, findWith, localPhone, toIso } from '../src/lasg.js';
import { accommodationBody, assetBody, reliefData, statementOfIncome } from '../src/file.js';
import { scrub } from '../src/errors.js';
import { nameWords, namesMatch } from '../src/check.js';
import { kindOf, mergeToPdf } from '../src/pdf.js';
import { PDFDocument } from 'pdf-lib';

const AG = [
  { FullName: 'Lekki I Tax Station', orcAgency2: '13085' }, { FullName: 'Lekki II Tax Stattion', orcAgency2: '13086' },
  { FullName: 'Ikeja Tax Station', orcAgency2: '13001' }, { FullName: 'Ikeja GRA Tax Station', orcAgency2: '13002' },
  { FullName: 'Victoria Island Tax Station', orcAgency2: '13050' }, { FullName: 'Apapa Tax Station', orcAgency2: '13060' },
];

test('tax stations: e-Tax spellings, numerals, and no guessing between close names', () => {
  assert.deepEqual(tokens('Lekki II Tax Stattion'), ['lekki', '2']);
  assert.equal(matchAgency('Lekki II', AG)?.orcAgency2, '13086');
  assert.equal(matchAgency('LEKKI 2 TAX OFFICE', AG)?.orcAgency2, '13086');
  assert.equal(matchAgency('Lekki I', AG)?.orcAgency2, '13085');
  assert.equal(matchAgency('Lekki', AG), null, 'Lekki alone could be either');
  assert.equal(matchAgency('Ikeja', AG)?.orcAgency2, '13001');
  assert.equal(matchAgency('Ikeja G.R.A.', AG)?.orcAgency2, '13002');
  assert.equal(matchAgency('Victoria Island', AG)?.orcAgency2, '13050');
  assert.equal(matchAgency('Badagry', AG), null);
  assert.equal(matchAgency('', AG), null);
});

test('reading Flutterwave: its API answer, its times, and the checkout text', () => {
  assert.deepEqual(findWith({ status: 'success', meta: { authorization: { transfer_account: '1', x: 2 } } }, ['transfer_account']), { transfer_account: '1', x: 2 });
  assert.equal(toIso('2026-11-04 23:30:00'), '2026-11-04T22:30:00.000Z', 'Flutterwave plain times are Lagos time');
  assert.equal(toIso(1793830200), new Date(1793830200 * 1000).toISOString());
  assert.equal(toIso('nonsense'), null);
  const a = accountFromText('LASG Collection\nTransfer NGN 505.00 to\nBank name\nFlutterwave MFB\nAccount number\n9912345678\nExpires in 14:59');
  assert.equal(a?.account_number, '9912345678'); assert.equal(a?.bank_name, 'Flutterwave MFB'); assert.equal(a?.amount, 505); assert.equal(a?.account_name, 'LASG Collection');
  assert.equal(accountFromText('No account here'), null);
  assert.equal(localPhone('08031234567'), '8031234567'); assert.equal(localPhone('+234 803 123 4567'), '8031234567');
  assert.equal(localPhone('012345'), ''); assert.equal(localPhone(null), '');
});

test('the return\'s forms from Counta\'s figures', () => {
  const c = { year: 2025, taxpayer: { name: 'Ada Obi' }, return: { income: { fields: { salary: 1000.5, trade_income: -40000, other_income: 0 }, other_lines: [{ label: 'x', amount: 0 }] },
    accommodation: { address: ' 1 Road ', type: 'room', occupancy: 'family', started_on: '2026-02-01' } } };
  const s = statementOfIncome(c, 9);
  assert.equal(s.data.salary, '1000.50'); assert.equal(s.data.trade_income, 0, 'a loss goes as nil'); assert.deepEqual(s.breakdowns, []);
  const a = accommodationBody(c, { individualId: 5, payerId: 'N-1', name: 'Ada' }, 3);
  assert.deepEqual([a.accommodation_user_type_id, a.rent_paid, a.started_at, a.ended_at, a.address], [3, '0.00', '2025-01-01', '2025-12-31', '1 Road']);
  const emp = accommodationBody({ ...c, return: { accommodation: { address: 'A', occupancy: 'employer', rent_paid_by_employer: 900000, started_on: '2025-12-31' } } }, { individualId: 5, payerId: 'N-1', name: 'Ada' }, 3);
  assert.deepEqual([emp.rent_paid, emp.started_at, emp.ended_at], ['900000.00', '2025-01-01', '2025-12-31'], 'a stay e-Tax cannot take falls back to the whole year');
  assert.throws(() => accommodationBody({ year: 2025, return: { accommodation: {} } }, { individualId: 5, payerId: 'N-1', name: '' }, 3), /home address/);
  assert.deepEqual(reliefData({ portal_type: 6, amount: 120000, details: { mortgage_institution: 'Abbey', mortgage_capital: '25,000,000' } }),
    { primaryMortgageInstitution: 'Abbey', capitalSumonMortgage: 25000000, totalInterestPaidInYear: 120000 });
  assert.deepEqual(reliefData({ portal_type: 5, amount: '2500.555' }), { amount: 2500.56 });
  assert.throws(() => reliefData({ portal_type: false, label: 'Gratuity' }), /form for Gratuity/);
  assert.equal(assetBody({ class: '1501', cost: 1, acquired_on: '2024-01-02T00:00:00Z' }, 'A').type_id, 3);
  assert.deepEqual(assetBody({ class: '1519', cost: 10, first_year: 2023 }, 'A'), { type_id: 5, data: { dateOfPurchase: '2023-01-01', address: 'A', costOfAcquisition: 10 } });
});

test('files and secrets', async () => {
  assert.equal(scrub('bad password hunter2 here', ['hunter2', null, '']), 'bad password ••• here');
  const d = await PDFDocument.create(); d.addPage(); const p = Buffer.from(await d.save());
  const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');
  assert.equal(kindOf(p), 'pdf'); assert.equal(kindOf(png), 'png'); assert.equal(kindOf(Buffer.from('hello')), 'other');
  const m = await mergeToPdf([p, png, p]);
  assert.equal((await PDFDocument.load(m)).getPageCount(), 3);
  await assert.rejects(mergeToPdf([p, Buffer.from('<html>')]));
});

test('whose login it is: names on e-Tax and in Counta', () => {
  assert.deepEqual(nameWords('Mrs. Chigoziem  Ibe-Okafor'), ['chigoziem', 'ibeokafor']);
  assert.ok(namesMatch('Chigoziem Ibe', 'IBE CHIGOZIEM ADAEZE'), 'surname first, with a middle name');
  assert.ok(namesMatch('Chigoziem Ibe', 'Chigoziem Okafor'), 'a maiden name still shares the first name');
  assert.ok(namesMatch('Adébáyọ̀ Ọlá', 'ADEBAYO OLA'), 'accents');
  assert.ok(!namesMatch('Ngozi Okafor', 'Dan Uzo'));
  assert.ok(namesMatch('', 'Dan Uzo'), 'nothing to compare');
  assert.ok(!namesMatch('Dr Ada Obi', 'Mr Bayo Ade'), 'titles do not count');
});
