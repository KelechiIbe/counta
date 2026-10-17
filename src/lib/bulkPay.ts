// Bulk payments: the template, reading a filled sheet, matching banks, checking names, and the results file.
import type { SheetField } from '../components/SheetRows';
import { cellText, parseNum, type Cell } from './sheet';

export interface Bank { code: string; name: string }

// The columns of the template, and the headings other payroll and bank sheets use for the same thing.
export const BULK_FIELDS: SheetField[] = [
  { key: 'name', label: 'Beneficiary name', required: true, syn: ['beneficiary name', 'beneficiary', 'name', 'account name', 'payee', 'payee name', 'staff name', 'employee name', 'full name', 'recipient', 'recipient name'] },
  { key: 'bank', label: 'Bank', required: true, syn: ['bank', 'bank name', 'beneficiary bank', 'bank code', 'sort code', 'bank sort code'] },
  { key: 'account_number', label: 'Account number', required: true, syn: ['account number', 'account no', 'acct no', 'nuban', 'beneficiary account', 'acc no', 'account num', 'account'] },
  { key: 'amount', label: 'Amount (₦)', syn: ['amount', 'amount ngn', 'net pay', 'net amount', 'amount to pay', 'net salary', 'pay', 'value'], hint: 'What the person receives' },
  { key: 'narration', label: 'Narration', syn: ['narration', 'description', 'remark', 'remarks', 'memo', 'purpose', 'details', 'note'] },
  { key: 'bill', label: 'Bill number', syn: ['bill number', 'bill no', 'bill', 'invoice number', 'invoice no', 'their invoice'] },
  { key: 'supplier', label: 'Supplier in Counta', syn: ['supplier in counta', 'supplier', 'vendor', 'vendor name', 'supplier name'] },
  { key: 'account', label: 'Account code', syn: ['account code', 'gl code', 'ledger code', 'expense account', 'account to charge'] },
  { key: 'reference', label: 'Your reference', syn: ['your reference', 'reference', 'ref', 'staff id', 'employee id', 'staff number'] },
];

// Used for the template only when the payment rail cannot be reached for its own list. Sending always uses the
// rail's list, matched by name.
export const COMMON_BANKS: Bank[] = [
  ['044', 'Access Bank'], ['023', 'Citibank Nigeria'], ['050', 'Ecobank Nigeria'], ['070', 'Fidelity Bank'], ['011', 'First Bank of Nigeria'],
  ['214', 'First City Monument Bank'], ['00103', 'Globus Bank'], ['058', 'Guaranty Trust Bank'], ['301', 'Jaiz Bank'], ['082', 'Keystone Bank'],
  ['50211', 'Kuda Bank'], ['303', 'Lotus Bank'], ['50515', 'Moniepoint MFB'], ['999992', 'OPay'], ['999991', 'PalmPay'], ['076', 'Polaris Bank'],
  ['101', 'Providus Bank'], ['221', 'Stanbic IBTC Bank'], ['068', 'Standard Chartered Bank'], ['232', 'Sterling Bank'], ['100', 'SunTrust Bank'],
  ['302', 'TAJ Bank'], ['102', 'Titan Trust Bank'], ['032', 'Union Bank of Nigeria'], ['033', 'United Bank For Africa'], ['215', 'Unity Bank'],
  ['035', 'Wema Bank'], ['057', 'Zenith Bank'],
].map(([code, name]) => ({ code, name }));

// What Flutterwave charges per NGN transfer, for the estimate. The fee the rail reports is what posts.
export const transferFee = (amount: number) => (amount <= 5000 ? 10.75 : amount <= 50000 ? 26.88 : 53.75);

const norm = (s: string) => String(s || '').toLowerCase().replace(/&/g, ' and ').replace(/[^a-z0-9 ]+/g, ' ').replace(/\s+/g, ' ').trim();
const STOP = new Set(['plc', 'ltd', 'limited', 'nigeria', 'nig', 'ng', 'of', 'the', 'bank', 'microfinance', 'mfb', 'digital', 'services', 'service', 'payment', 'payments', 'psb', 'company', 'co']);
const key = (s: string) => norm(s).split(' ').filter((w) => w && !STOP.has(w)).join(' ');
// Names people use for the same bank. Any one of them finds the bank whatever the rail calls it ("GTBank Plc",
// "Guaranty Trust Bank").
const GROUPS: string[][] = [
  ['guaranty trust', 'gtbank', 'gtb', 'gt', 'gtco', 'guaranty'], ['united for africa', 'uba', 'united'], ['first city monument', 'fcmb', 'first city'],
  ['first', 'firstbank', 'fbn'], ['stanbic ibtc', 'stanbic', 'ibtc'], ['standard chartered', 'stanchart', 'scb'], ['opay', 'o pay', 'paycom'],
  ['palmpay', 'palm pay'], ['moniepoint', 'monie point', 'teamapt'], ['ecobank', 'eco'], ['wema', 'alat'], ['polaris', 'skye'],
  ['union', 'unionbank'], ['fidelity'], ['zenith'], ['access'], ['sterling'], ['keystone'], ['providus'], ['kuda'],
];

// Finds the rail's bank for whatever the sheet says: a code, the full name, or a short name people use ("GTB", "UBA").
// Returns the bank, or the candidates to choose from when the name fits more than one.
export function matchBank(value: string, banks: Bank[]): { bank?: Bank; options?: Bank[] } {
  const v = String(value || '').trim();
  if (!v || !banks.length) return {};
  if (/^\d{3,6}$/.test(v)) { const b = banks.find((x) => x.code === v); if (b) return { bank: b }; }
  const nv = norm(v);
  const exact = banks.filter((b) => norm(b.name) === nv);
  if (exact.length === 1) return { bank: exact[0] };
  const kv = key(v);
  if (!kv) return {};
  const forms = GROUPS.find((g) => g.includes(kv) || g.includes(kv.replace(/ /g, ''))) || [kv];
  const same = banks.filter((b) => forms.includes(key(b.name)));
  if (same.length === 1) return { bank: same[0] };
  if (same.length > 1) return { options: same };
  const near = banks.filter((b) => { const k = key(b.name); return forms.some((f) => k.startsWith(f + ' ') || k.split(' ').includes(f) || (f.length >= 5 && k.includes(f))); });
  if (near.length === 1) return { bank: near[0] };
  if (near.length > 1) return { options: near.slice(0, 12) };
  return {};
}

const NAME_STOP = new Set(['ltd', 'limited', 'plc', 'nig', 'nigeria', 'enterprise', 'enterprises', 'ventures', 'and', 'the', 'mr', 'mrs', 'miss', 'ms', 'dr', 'chief', 'alhaji', 'alhaja', 'engr', 'co', 'company']);
const words = (s: string) => norm(s).split(' ').filter((w) => w.length > 1 && !NAME_STOP.has(w));
// Whether the name in the sheet is the name the bank holds. Every word of the sheet's name must appear in the bank's
// (one may be missing when the sheet gives three or more), so "John Smith" never passes for "JOHN DOE".
export function namesAgree(sheet: string, bank: string): boolean {
  const a = words(sheet), b = words(bank);
  if (!a.length || !b.length) return false;
  const missing = a.filter((w) => !b.some((x) => x === w || (w.length >= 4 && x.length >= 4 && (x.startsWith(w) || w.startsWith(x)))));
  return missing.length === 0 || (a.length >= 3 && missing.length === 1);
}

export interface BulkRow {
  row: number; name: string; bankText: string; bank_code: string; bank_name: string; bankOptions?: Bank[];
  account_number: string; amount: number | null; narration: string; bill: string; supplier: string; account: string; reference: string;
  notes: string[]; issues: string[]; resolved?: string; resolving?: boolean; include: boolean; touched?: boolean; server?: any;
}

const txt = (c: Cell | undefined) => cellText(c ?? null).trim();
export function readBulkRows(rows: (Record<string, Cell> & { _row: number })[], banks: Bank[]): BulkRow[] {
  return rows.map((r) => {
    const notes: string[] = [], issues: string[] = [];
    let acct = txt(r.account_number).replace(/[\s-]/g, '');
    // Excel drops the leading zero of an account number typed as a number.
    if (typeof r.account_number === 'number' && /^\d{9}$/.test(acct)) { acct = '0' + acct; notes.push('Leading zero put back on the account number'); }
    if (!/^\d{10}$/.test(acct)) issues.push(acct ? `Account number ${acct} does not have 10 digits` : 'No account number');
    const bankText = txt(r.bank);
    const m = matchBank(bankText, banks);
    if (!bankText) issues.push('No bank');
    else if (!m.bank && !m.options) issues.push(`Bank "${bankText}" not recognised`);
    const rawAmount = txt(r.amount);
    const amount = rawAmount === '' ? null : parseNum(r.amount ?? null);
    if (rawAmount !== '' && !(amount != null && amount > 0)) issues.push(`Amount "${rawAmount}" is not an amount in naira`);
    return {
      row: r._row, name: txt(r.name), bankText, bank_code: m.bank?.code || '', bank_name: m.bank?.name || '', bankOptions: m.bank ? undefined : m.options,
      account_number: acct, amount: amount != null && amount > 0 ? Math.round(amount * 100) / 100 : null, narration: txt(r.narration).slice(0, 80),
      bill: txt(r.bill), supplier: txt(r.supplier), account: txt(r.account).split(/\s/)[0] || '', reference: txt(r.reference).slice(0, 60),
      notes, issues, include: true,
    };
  }).filter((r) => r.name || r.account_number || r.amount);
}

async function excel() {
  const mod: any = await import('exceljs');
  return (mod.default || mod) as typeof import('exceljs');
}
const BLUE = 'FF0072F5';
const colLetter = (n: number) => String.fromCharCode(65 + n);

export async function bulkTemplateXlsx(o: { orgName: string; banks: Bank[]; suppliers: string[]; accounts: { code: string; name: string }[] }): Promise<Blob> {
  const ExcelJS = await excel();
  const wb = new ExcelJS.Workbook();
  wb.creator = 'Counta · TaxStreem'; wb.created = new Date();
  const ws = wb.addWorksheet('Payments', { views: [{ state: 'frozen', ySplit: 1 }] });
  const ex = wb.addWorksheet('Example', { views: [{ state: 'frozen', ySplit: 1 }] });
  const how = wb.addWorksheet('How to fill it');
  const bk = wb.addWorksheet('Banks');
  const lists = wb.addWorksheet('Lists', { state: 'veryHidden' });
  const cols = [
    { h: 'Beneficiary name*', w: 30, note: 'The name on the bank account. Counta checks it with the bank before anything is sent.' },
    { h: 'Bank*', w: 28, note: 'Pick from the list, or type the bank\'s name or code.' },
    { h: 'Account number*', w: 18, text: true, note: '10 digits (NUBAN). Keep the leading zero.' },
    { h: 'Amount (₦)*', w: 16, fmt: '#,##0.00', note: 'What the person receives. For a bill, leave it empty to pay what is owed after withholding tax.' },
    { h: 'Narration', w: 30, note: 'Shows on their bank statement. Up to 80 characters.' },
    { h: 'Bill number', w: 16, note: 'A bill in Counta (such as BILL-0012) or the supplier\'s own invoice number. Withholding tax is deducted and the bill is cleared.' },
    { h: 'Supplier in Counta', w: 26, note: 'For a payment to a supplier without a bill: it is recorded against what you owe them.' },
    { h: 'Account code', w: 14, note: 'For anything else, the account to charge (such as an expense). Leave empty to use the one you choose on upload.' },
    { h: 'Your reference', w: 18, note: 'Your own reference, such as a staff ID. It comes back in the results.' },
  ];
  const head = (s: any) => {
    const r = s.getRow(1);
    cols.forEach((c, i) => {
      const cell = r.getCell(i + 1);
      cell.value = c.h; cell.font = { bold: true, color: { argb: 'FFFFFFFF' } };
      cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: i < 4 ? 'FF004FB0' : BLUE } };
      cell.alignment = { vertical: 'middle', wrapText: true };
      cell.note = { texts: [{ text: c.note }] } as any;
      s.getColumn(i + 1).width = c.w;
      if (c.text) s.getColumn(i + 1).numFmt = '@';
      if (c.fmt) s.getColumn(i + 1).numFmt = c.fmt;
    });
    r.height = 32;
  };
  head(ws); head(ex);
  // Dropdowns from the lists; a value typed in that is not on a list is still accepted.
  const banks = [...o.banks].sort((a, b) => a.name.localeCompare(b.name));
  banks.forEach((b, i) => { lists.getCell(`A${i + 1}`).value = b.name; });
  o.suppliers.forEach((v, i) => { lists.getCell(`B${i + 1}`).value = v; });
  o.accounts.forEach((a, i) => { lists.getCell(`C${i + 1}`).value = a.code; });
  const dv = (col: number, ref: string) => (ws as any).dataValidations.add(`${colLetter(col)}2:${colLetter(col)}1001`, {
    type: 'list', allowBlank: true, formulae: [ref], showErrorMessage: true, errorStyle: 'information', errorTitle: 'Not on the list', error: 'Keep it if you are sure; Counta checks it on upload.',
  });
  if (banks.length) dv(1, `Lists!$A$1:$A$${banks.length}`);
  if (o.suppliers.length) dv(6, `Lists!$B$1:$B$${o.suppliers.length}`);
  if (o.accounts.length) dv(7, `Lists!$C$1:$C$${o.accounts.length}`);
  (ws as any).dataValidations.add('D2:D1001', { type: 'decimal', operator: 'greaterThan', formulae: [0], allowBlank: true, showErrorMessage: true, errorTitle: 'Amount', error: 'Enter an amount in naira, such as 25000.' });
  ws.autoFilter = { from: { row: 1, column: 1 }, to: { row: 1, column: cols.length } };

  const sample = [
    ['Ada Okoro', 'Guaranty Trust Bank', '0123456789', 185000, 'October salary', '', '', o.accounts.find((a) => /salar/i.test(a.name))?.code || '6101', 'STAFF-014'],
    ['Adex Consulting Ltd', 'Access Bank', '0690000031', null, 'Retainer, October', 'BILL-0012', 'Adex Consulting Ltd', '', 'INV-118'],
    ['Musa Bello', 'Zenith Bank', '2034567891', 15000, 'Delivery to Ikeja', '', '', '', ''],
  ];
  sample.forEach((r, i) => { const row = ex.getRow(i + 2); r.forEach((v, j) => { row.getCell(j + 1).value = v as any; }); row.font = { italic: true, color: { argb: 'FF4B5563' } }; });

  const g: [string, string][] = [
    [`${o.orgName} · bulk payment template`, 'h1'],
    ['Fill the Payments sheet, one person or business per row, then upload it from Payments → Bulk payments.', ''],
    ['', ''],
    ['Every row needs', 'h2'],
    ['The beneficiary\'s name, their bank and their 10-digit account number. Counta asks the bank for the name on each account before anything is sent and shows you any that differ.', ''],
    ['The amount the person receives, in naira. Transfer fees are charged to the wallet on top.', ''],
    ['', ''],
    ['What each payment is for (one of these)', 'h2'],
    ['Bill number: pays a bill already in Counta. Withholding tax is deducted at the bill\'s rate and the bill is cleared when the bank confirms. Leave Amount empty to pay what is owed.', ''],
    ['Supplier in Counta: a payment to a supplier on account, without a bill. It reduces what you owe them. No withholding tax is deducted.', ''],
    ['Account code: anything else, such as salaries, allowances or delivery costs. It is charged to that account.', ''],
    ['Leave all three empty and the account you choose on the upload screen is used for that row.', ''],
    ['', ''],
    ['After you upload', 'h2'],
    ['You see every row with the bank\'s name for the account, what it pays for, and any problem. Untick rows you do not want to pay.', ''],
    ['If your role needs a second person to approve payouts above the limit in Payments → Settings, the whole batch waits for one approval.', ''],
    ['Sending goes from the business wallet, one transfer per row. You can close the page; Counta carries on and tells you when the batch finishes.', ''],
    ['Download the results from the batch at any time: each row\'s status, fee, reference and the reason for any failure.', ''],
    ['', ''],
    ['Your own sheet works too', 'h2'],
    ['A payroll or bank upload sheet with the same information can be uploaded as it is. Match its columns on screen.', ''],
  ];
  how.getColumn(1).width = 120;
  g.forEach(([t, s], i) => {
    const c = how.getCell(`A${i + 1}`); c.value = t; c.alignment = { wrapText: true, vertical: 'top' };
    if (s === 'h1') c.font = { bold: true, size: 14, color: { argb: BLUE } }; else if (s === 'h2') c.font = { bold: true, size: 11 };
  });
  bk.getColumn(1).width = 46; bk.getColumn(2).width = 12;
  bk.getRow(1).values = ['Bank', 'Code']; bk.getRow(1).font = { bold: true };
  banks.forEach((b, i) => { bk.getRow(i + 2).values = [b.name, b.code]; });
  bk.getColumn(2).numFmt = '@';
  wb.views = [{ activeTab: 0 } as any];
  const buf = await wb.xlsx.writeBuffer();
  return new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
}

export const STATUS_WORD: Record<string, string> = {
  pending_approval: 'Waiting for approval', approved: 'Ready to send', processing: 'At the bank', successful: 'Paid', failed: 'Failed', reversed: 'Reversed', cancelled: 'Cancelled',
};
export const paidFor = (r: any) => r.bill_number ? `${r.bill_number}${r.vendor_name ? ' · ' + r.vendor_name : ''}` : r.vendor_name ? `${r.vendor_name} (on account)` : r.account_code ? `${r.account_code} ${r.account_label || ''}`.trim() : '';

export async function bulkResultsXlsx(b: any, orgName: string): Promise<Blob> {
  const ExcelJS = await excel();
  const wb = new ExcelJS.Workbook();
  const ws = wb.addWorksheet('Results', { views: [{ state: 'frozen', ySplit: 5 }] });
  ws.getCell('A1').value = orgName; ws.getCell('A1').font = { bold: true, size: 14 };
  ws.getCell('A2').value = `${b.number} · ${b.title}`; ws.getCell('A2').font = { bold: true, size: 12, color: { argb: BLUE } };
  ws.getCell('A3').value = `${STATUS_WORD[b.status] || String(b.status).replace(/_/g, ' ')} · ${b.paid_count} paid, ${b.failed_count} failed, ${b.cancelled_count} cancelled · generated ${new Date().toLocaleString('en-GB', { timeZone: 'Africa/Lagos' })}`;
  ws.getCell('A3').font = { size: 9, color: { argb: 'FF6B7280' } };
  const cols = [['Row', 7], ['Paid to (name at the bank)', 30], ['Bank', 24], ['Account number', 16], ['Amount', 14], ['Fee', 10], ['WHT', 12], ['Paid for', 30], ['Narration', 28],
    ['Your reference', 16], ['Status', 16], ['Counta reference', 22], ['Payout', 11], ['Completed', 18], ['Reason', 36]] as const;
  const hr = ws.getRow(5);
  cols.forEach(([h, w], i) => {
    const c = hr.getCell(i + 1); c.value = h; c.font = { bold: true, color: { argb: 'FFFFFFFF' } };
    c.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: BLUE } }; ws.getColumn(i + 1).width = w;
  });
  (b.rows || []).forEach((r: any, i: number) => {
    ws.getRow(6 + i).values = [r.row, r.account_name, r.bank_name || r.bank_code, r.account_number, Number(r.amount), Number(r.fee) || null, r.wht != null ? Number(r.wht) : null,
      paidFor(r), r.narration, r.your_reference, STATUS_WORD[r.status] || r.status, r.reference, r.number,
      r.completed_at ? new Date(r.completed_at).toLocaleString('en-GB', { timeZone: 'Africa/Lagos' }) : '', r.error || ''];
  });
  [5, 6, 7].forEach((c) => { ws.getColumn(c).numFmt = '#,##0.00'; });
  ws.getColumn(4).numFmt = '@';
  const last = 5 + (b.rows || []).length;
  const tr = ws.getRow(last + 1);
  tr.getCell(1).value = 'Total';
  tr.getCell(5).value = { formula: `SUM(E6:E${last})`, result: (b.rows || []).reduce((a: number, r: any) => a + Number(r.amount), 0) } as any;
  tr.getCell(6).value = { formula: `SUM(F6:F${last})`, result: (b.rows || []).reduce((a: number, r: any) => a + (Number(r.fee) || 0), 0) } as any;
  tr.font = { bold: true };
  ws.autoFilter = { from: { row: 5, column: 1 }, to: { row: last, column: cols.length } };
  const buf = await wb.xlsx.writeBuffer();
  return new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
}
