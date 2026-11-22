import { assert, assertEquals } from 'jsr:@std/assert@1';
import { PDFDocument } from 'npm:pdf-lib@1.17.1';
import { headline, pdfSafe, type Report, reportCaption, reportFileName, reportPdf, sections } from './report.ts';

const owner = {
  day: '2026-11-22', empty: false,
  sales: { count: 3, total: 125000, vat: 8720.93, receipts: 2, invoices: 1, invoiced: 50000, previous_day: 100000, paid_in_full: 1,
    overdue: { count: 2, owed: 75000 }, top: [{ name: 'Golden Penny Semovita 1kg', qty: 12, value: 21600 }] },
  money: { in: { cash: 40000, transfer: 35000 }, in_total: 75000, out_bills: 20000, out_payouts: 0, cash_and_bank: 1250000, payouts_waiting: 1 },
  orders: { new: { count: 1, total: 5400 }, to_confirm: 1, dispatched: 0, delivered: 0, waiting: 0, failed: 0 },
  stock: { moves: { sale: 3, receipt: 1 }, received_value: 120000, counts_waiting: 0, transfers_waiting: 0, out: ['Peak Milk 400g'], low: [] },
  books: { questions: 2, posted_by_atlas: 5, bills_to_approve: 1, approvals: 0 },
  tax: [{ label: 'VAT return', period: '2026-11-01', due: '2026-12-21', amount: 8720.93 }],
};
const cashier = { day: '2026-11-22', empty: false, sales: owner.sales, orders: owner.orders };
const report = (data: Record<string, unknown>, name = 'Ikeja Grocers Ltd'): Report => ({
  id: '00000000-0000-0000-0000-000000000001', kind: 'scheduled', day: '2026-11-22', org_id: 'o', business: { name, timezone: 'Africa/Lagos' },
  person: { name: 'Ada Okeke', email: 'ada@example.test', whatsapp: '2348030000001' }, channels: { email: true, whatsapp: true },
  app_url: 'https://counta-taxstreem.netlify.app/', data,
});

Deno.test('report_parts_follow_the_role', () => {
  assertEquals(sections(owner).map((s) => s.heading), ['Sales', 'Money', 'Orders and deliveries', 'Stock', 'Books', 'Tax coming due']);
  assertEquals(sections(cashier).map((s) => s.heading), ['Sales', 'Orders and deliveries']);
  assertEquals(sections({ ...owner, people: { actions: 4, by: [{ name: 'Tunde', actions: 4 }] } }).at(-1)?.heading, 'Who did what');
});
Deno.test('report_sales_rows', () => {
  const s = sections(owner)[0];
  assertEquals(s.rows[0], ['Sales recorded', '3 sales (2 receipts, 1 invoice)']);
  assertEquals(s.rows[2], ['The day before', '₦100,000.00 (up 25%)']);
  assertEquals(s.list, ['Golden Penny Semovita 1kg: 12 sold, ₦21,600.00']);
  assertEquals(sections({ sales: { count: 1, receipts: 1, invoices: 0, total: 10, previous_day: 0 } })[0].rows[2], ['The day before', '₦0.00']);
});
Deno.test('report_money_by_method', () => {
  const m = sections(owner)[1];
  assert(m.rows.some(([a, b]) => a === 'In by cash' && b === '₦40,000.00'));
  assert(m.rows.some(([a, b]) => a === 'In by transfers' && b === '₦35,000.00'));
});
Deno.test('report_headline', () => {
  assertEquals(headline(report(owner)), ['Sales ₦125,000.00 from 3 sales.', 'Money in ₦75,000.00, out ₦20,000.00.', '1 order to confirm.',
    '2 questions in the books inbox.', '1 product out of stock.']);
  assertEquals(headline(report({})), []);
  assert(reportCaption(report({})).endsWith('Here is the day in Counta.'));
  assert(reportCaption(report(owner)).startsWith('*Daily report, Sunday, 22 November 2026*\n'));
});
Deno.test('report_text_fits_the_pdf_fonts', () => {
  assertEquals(pdfSafe('₦5,000 – “ok” … Ọ̀ṣun'), 'NGN 5,000 - "ok" ... Osun');
  assertEquals(pdfSafe('日本'), '??');
});
Deno.test('report_file_name', () => {
  assertEquals(reportFileName(report(owner, 'Ada & Sons (Nig.) Ltd')), 'Daily-report-Ada-Sons-Nig-Ltd-2026-11-22.pdf');
  assertEquals(reportFileName(report(owner, '日本')), 'Daily-report-Business-2026-11-22.pdf');
});
Deno.test('report_pdf_one_page_for_a_normal_day', async () => {
  const bytes = await reportPdf(report(owner), new Date('2026-11-22T18:00:00Z'));
  assertEquals(new TextDecoder().decode(bytes.slice(0, 5)), '%PDF-');
  assertEquals((await PDFDocument.load(bytes)).getPageCount(), 1);
});
Deno.test('report_pdf_busy_day_breaks_pages', async () => {
  const busy = { ...owner, sales: { ...owner.sales, top: Array.from({ length: 10 }, (_, i) => ({ name: `Product ${i}`, qty: i + 1, value: 1000 * (i + 1) })) },
    stock: { ...owner.stock, out: Array.from({ length: 10 }, (_, i) => `Out ${i}`), low: Array.from({ length: 10 }, (_, i) => `Low ${i}`) },
    tax: Array.from({ length: 6 }, (_, i) => ({ label: `Tax ${i}`, period: '2026-11-01', due: '2026-12-21', amount: 100 })),
    people: { actions: 40, by: Array.from({ length: 8 }, (_, i) => ({ name: `Person ${i}`, actions: 5 })) } };
  const doc = await PDFDocument.load(await reportPdf(report(busy, 'A business with a very long name that goes on and on and on Ltd')));
  assert(doc.getPageCount() >= 2);
});
