// Bank statements from any Nigerian bank, as Excel, CSV or PDF. Each file is turned into one table (dates, narrations,
// money in and out, running balance), checked against its own balances, and sent to import_bank_lines.
//
// Banks lay statements out differently: GTBank and First Bank print Debits and Credits columns, Stanbic and Kuda a
// signed Amount, UBA and Union a Dr/Cr marker, some banks list the newest line first, and narrations wrap onto two or
// three printed lines. The reader finds the columns by their headings, joins wrapped narrations and works out the
// direction of an unsigned amount from the running balance. What it cannot read (a scanned PDF, an unusual layout)
// goes to the AI reader, and its answer passes the same checks.
import type { Cell, SheetData } from './sheet';

export type Role = 'date' | 'value_date' | 'description' | 'reference' | 'debit' | 'credit' | 'amount' | 'drcr' | 'balance' | 'ignore';
export interface StmtLine { row: number; date: string; description: string; reference: string | null; amount: number; balance: number | null; issues: string[] }
export interface StmtMeta {
  bank_name: string | null; account_number: string | null; account_name: string | null;
  period_from: string | null; period_to: string | null; opening_balance: number | null; closing_balance: number | null;
}
export interface Statement {
  kind: 'excel' | 'csv' | 'pdf'; read_by: 'columns' | 'ai'; meta: StmtMeta; lines: StmtLine[]; problems: string[];
  newest_first: boolean; roles?: Role[]; header?: string[]; balance_check: 'agrees' | 'differs' | 'unknown'; difference: number | null;
}

// ------------------------------------------------------------------ values
const MONTHS: Record<string, number> = { jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, jul: 7, aug: 8, sep: 9, sept: 9, oct: 10, nov: 11, dec: 12 };
const pad = (n: number) => String(n).padStart(2, '0');
function iso(y: number, m: number, d: number): string | null {
  if (y < 100) y += 2000;
  if (y < 1990 || y > 2100 || m < 1 || m > 12 || d < 1 || d > 31) return null;
  const dt = new Date(Date.UTC(y, m - 1, d));
  if (dt.getUTCMonth() !== m - 1) return null;
  return `${y}-${pad(m)}-${pad(d)}`;
}

// Day first, as Nigerian banks print it: 01/10/2026, 01-10-26, 01-Oct-2026, 1 Oct 2026, Oct 01, 2026, 2026-10-01,
// with or without a time after it. An Excel date arrives as a Date or a serial number.
export function stmtDate(v: Cell | undefined): string | null {
  if (v == null || v === '') return null;
  if (v instanceof Date) {
    if (isNaN(v.getTime())) return null;
    return new Date(v.getTime() + 12 * 3600_000).toISOString().slice(0, 10);
  }
  if (typeof v === 'number') return v > 30000 && v < 80000 ? new Date(Math.round((v - 25569) * 86400_000)).toISOString().slice(0, 10) : null;
  let s = String(v).trim().toLowerCase().replace(/\s+/g, ' ');
  s = s.replace(/[ t,]+\d{1,2}:\d{2}(:\d{2}(\.\d+)?)?\s*(am|pm)?(\s*(wat|gmt|utc)?[+-]?\d{0,4})?z?$/, '').trim();
  let m = s.match(/^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})$/);
  if (m) return iso(+m[1], +m[2], +m[3]);
  m = s.match(/^(\d{1,2})[-/.](\d{1,2})[-/.](\d{2}|\d{4})$/);
  if (m) return iso(+m[3], +m[2], +m[1]);
  m = s.match(/^(\d{1,2})(?:st|nd|rd|th)?[\s\-/.]*([a-z]{3,9})[\s,\-/.]*(\d{2}|\d{4})$/);
  if (m && MONTHS[m[2].slice(0, 3)]) return iso(+m[3], MONTHS[m[2].slice(0, 3)], +m[1]);
  m = s.match(/^([a-z]{3,9})[\s\-/.]*(\d{1,2})(?:st|nd|rd|th)?[\s,\-/.]+(\d{4})$/);
  if (m && MONTHS[m[1].slice(0, 3)]) return iso(+m[3], MONTHS[m[1].slice(0, 3)], +m[2]);
  m = s.match(/^(\d{2})(\d{2})(\d{4})$/);
  if (m) return iso(+m[3], +m[2], +m[1]);
  return null;
}

// Money as printed: 1,234.56 · (1,234.56) · -1,234.56 · 1,234.56 DR · ₦1,234.56 · NGN 1,234.56 CR. Returns the signed
// value and whether the figure itself said which way it went.
export function money(v: Cell | undefined): { n: number; signed: boolean } | null {
  if (v == null || v === '') return null;
  if (typeof v === 'number') return isFinite(v) ? { n: v, signed: v < 0 } : null;
  if (typeof v !== 'string') return null;
  let s = v.trim().toUpperCase();
  if (!s || /^[-–—]+$/.test(s) || s === 'NIL' || s === 'N/A') return null;
  let neg = false; let signed = false;
  if (/^\(.*\)$/.test(s)) { neg = true; signed = true; s = s.slice(1, -1); }
  const sfx = s.match(/([\d\s])(DR|CR|D|C)\.?$/);
  if (sfx) { signed = true; neg = sfx[2].startsWith('D'); s = s.slice(0, s.length - sfx[0].length + 1).trim(); }
  s = s.replace(/NGN|₦|N(?=\s*[\d.])/g, '').replace(/[\s,]/g, '');
  if (/^-/.test(s)) { neg = !neg; signed = true; s = s.slice(1); }
  if (/^\+/.test(s)) { signed = true; s = s.slice(1); }
  if (!/^\d+(\.\d+)?$/.test(s)) return null;
  const n = parseFloat(s);
  return { n: neg ? -n : n, signed };
}
// A figure as banks print amounts: two decimals or thousands commas (so a day "01" or a cheque number is not money).
export const moneyLike = (s: string) => /^\(?[-+]?\s?(?:NGN|₦|N)?\s?(?:\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+\.\d{2})\)?(?:\s?(?:DR|CR|D|C)\.?)?$/i.test(s.trim());
const txt = (c: Cell | undefined) => (c == null ? '' : c instanceof Date ? stmtDate(c) || '' : String(c).trim());
const r2 = (n: number) => Math.round(n * 100) / 100;

// ------------------------------------------------------------------ columns
const norm = (h: string) => String(h ?? '').toLowerCase().replace(/[₦().:#*_]/g, ' ').replace(/\s+/g, ' ').trim();
const SYN: [Role, string[]][] = [
  ['value_date', ['value date', 'val date', 'value dt', 'effective date', 'valuedate']],
  ['date', ['transaction date', 'trans date', 'tran date', 'txn date', 'trans dt', 'tran dt', 'posting date', 'posted date', 'date posted', 'post date', 'book date',
    'entry date', 'actual date', 'created on', 'date time', 'datetime', 'trans time', 'transaction time', 'posted', 'date']],
  ['description', ['narration', 'narrative', 'naration', 'description', 'details', 'detail', 'transaction details', 'transaction detail', 'transaction description',
    'remarks', 'remark', 'particulars', 'transaction particulars',
    'transaction narration', 'narration description', 'memo', 'transaction remarks', 'beneficiary details', 'purpose']],
  ['reference', ['reference', 'ref', 'ref no', 'reference no', 'reference number', 'cheque no', 'chq no', 'chq', 'cheque number', 'cheque', 'document no',
    'transaction reference', 'trans ref', 'txn ref', 'tran ref', 'session id', 'transaction id', 'instrument no', 'check no']],
  ['debit', ['debit', 'debits', 'debit amount', 'debit amt', 'dr', 'dr amount', 'withdrawal', 'withdrawals', 'withdrawal amt', 'withdrawal amount', 'money out',
    'paid out', 'pay out', 'amount out', 'outflow', 'outflows', 'debit ngn', 'payments']],
  ['credit', ['credit', 'credits', 'credit amount', 'credit amt', 'cr', 'cr amount', 'deposit', 'deposits', 'deposit amount', 'lodgement', 'lodgements', 'lodgment',
    'money in', 'paid in', 'pay in', 'amount in', 'inflow', 'inflows', 'credit ngn', 'receipts']],
  ['drcr', ['dr cr', 'dr/cr', 'd c', 'd/c', 'cr dr', 'cr/dr', 'debit credit', 'debit/credit', 'type', 'transaction type', 'tran type', 'txn type', 'direction']],
  ['amount', ['amount', 'transaction amount', 'txn amount', 'tran amount', 'amt', 'amount ngn', 'value']],
  ['balance', ['balance', 'running balance', 'closing balance', 'available balance', 'ledger balance', 'book balance', 'balance ngn', 'bal', 'current balance', 'account balance']],
];

// Which column is which: an exact heading wins, then the longest heading found inside a cell. Each role once.
export function rolesOf(header: string[]): Role[] {
  const cand: { col: number; role: Role; score: number }[] = [];
  header.forEach((raw, col) => {
    const h = norm(raw).replace(/\//g, ' ');
    const hs = norm(raw);
    if (!h || h.length > 40) return;
    for (const [role, syns] of SYN) {
      for (const syn of syns) {
        const sn = syn.replace(/\//g, ' ');
        let score = 0;
        if (h === sn || hs === syn || h.replace(/ /g, '') === sn.replace(/ /g, '')) score = 1000 + syn.length;
        else if (syn.length > 2 && (` ${h} `).includes(` ${sn} `)) score = syn.length;
        if (score) cand.push({ col, role, score });
      }
    }
  });
  cand.sort((a, b) => b.score - a.score);
  const roles: Role[] = header.map(() => 'ignore');
  const taken = new Set<Role>();
  for (const c of cand) {
    if (roles[c.col] !== 'ignore' || taken.has(c.role)) continue;
    roles[c.col] = c.role; taken.add(c.role);
  }
  // A statement that prints only a value date uses it as the transaction date.
  if (!taken.has('date') && taken.has('value_date')) roles[roles.indexOf('value_date')] = 'date';
  // OPay and PalmPay print one signed column headed "Debit/Credit" (-5,000.00 out, +20,000.00 in): with no other amount
  // column, that is the amount. A column of DR and CR markers then reads no figures and the statement goes to the AI reader.
  if (!taken.has('amount') && !taken.has('debit') && !taken.has('credit') && taken.has('drcr')) roles[roles.indexOf('drcr')] = 'amount';
  return roles;
}
const usable = (roles: Role[]) => roles.includes('date') && (roles.includes('amount') || roles.includes('debit') || roles.includes('credit'));
const roleCount = (roles: Role[]) => roles.filter((r) => r !== 'ignore').length;

// ------------------------------------------------------------------ the header block
const BANKS: [RegExp, string][] = [
  [/guaranty trust|gtbank|\bgtb\b|gtco/i, 'GTBank'], [/access bank|\baccess\b(?! code)/i, 'Access Bank'], [/zenith/i, 'Zenith Bank'], [/first ?bank|firstbank|fbn\b/i, 'First Bank'],
  [/united bank for africa|\buba\b/i, 'UBA'], [/fidelity/i, 'Fidelity Bank'], [/first city monument|\bfcmb\b/i, 'FCMB'], [/union bank/i, 'Union Bank'],
  [/sterling/i, 'Sterling Bank'], [/stanbic/i, 'Stanbic IBTC'], [/wema|\balat\b/i, 'Wema Bank'], [/polaris/i, 'Polaris Bank'], [/ecobank/i, 'Ecobank'],
  [/keystone/i, 'Keystone Bank'], [/providus/i, 'Providus Bank'], [/jaiz/i, 'Jaiz Bank'], [/moniepoint/i, 'Moniepoint'], [/\bopay\b|paycom/i, 'OPay'],
  [/\bkuda\b/i, 'Kuda'], [/palmpay/i, 'PalmPay'], [/unity bank/i, 'Unity Bank'], [/heritage bank/i, 'Heritage Bank'], [/globus/i, 'Globus Bank'],
  [/titan trust/i, 'Titan Trust Bank'], [/premium ?trust/i, 'PremiumTrust Bank'], [/parallex/i, 'Parallex Bank'], [/suntrust/i, 'SunTrust Bank'],
  [/signature bank/i, 'Signature Bank'], [/optimus/i, 'Optimus Bank'], [/lotus bank/i, 'Lotus Bank'], [/taj ?bank/i, 'TAJBank'], [/standard chartered/i, 'Standard Chartered'],
  [/citibank/i, 'Citibank'], [/\bvfd\b/i, 'VFD MFB'], [/fairmoney/i, 'FairMoney'], [/carbon/i, 'Carbon'], [/rubies/i, 'Rubies MFB'], [/sparkle/i, 'Sparkle'],
];
const LABEL_NUM = '\\(?-?[₦N]?\\s?[\\d,]+(?:\\.\\d{1,2})?\\)?(?:\\s?(?:DR|CR))?';
// text: the header block above the table; tail: the end of the statement, where closing figures are printed.
export function readMeta(text: string, fileName = '', tail = ''): StmtMeta {
  const t = text.replace(/\u00a0/g, ' ');
  const all = `${t}\n${tail.replace(/\u00a0/g, ' ')}`;
  const bank = BANKS.find(([re]) => re.test(t) || re.test(fileName))?.[1] || null;
  // The number may be printed in groups ("0123 456 789"), but never runs on to the next line.
  const acct = t.match(/(?:account|acct|a\/c)[ \t]*(?:no|number|num|#)?\.?[ \t]*[:\-]?[ \t]*(\d(?:[ -]?\d){9,11})(?!\d)/i)?.[1]?.replace(/\D/g, '')
    || t.match(/(?:^|[^\d])(\d{10})(?:[^\d]|$)/)?.[1] || null;
  const name = t.match(/(?:account|acct|customer)\s*name\s*[:\-]?\s*([A-Z0-9&.,'()\- ]{3,80}?)(?:\s{2,}|\n|\||$|\s(?:account|acct|currency|address|period|branch|date)\b)/i)?.[1]?.trim() || null;
  const datePat = '(\\d{1,2}[-/. ](?:\\d{1,2}|[A-Za-z]{3,9})[-/. ]\\d{2,4}|\\d{4}-\\d{2}-\\d{2}|[A-Za-z]{3,9} \\d{1,2},? \\d{4})';
  let from: string | null = null; let to: string | null = null;
  const per = t.match(new RegExp(`(?:period|statement period|from|between|date range)\\s*[:\\-]?\\s*${datePat}\\s*(?:to|-|–|—|and|through|till)\\s*${datePat}`, 'i'));
  if (per) { from = stmtDate(per[1]); to = stmtDate(per[2]); }
  if (!from) from = stmtDate(t.match(new RegExp(`(?:start date|from date|period from|begin(?:ning)? date)\\s*[:\\-]?\\s*${datePat}`, 'i'))?.[1] ?? null);
  if (!to) to = stmtDate(t.match(new RegExp(`(?:end date|to date|period to|ending date)\\s*[:\\-]?\\s*${datePat}`, 'i'))?.[1] ?? null);
  const num = (re: RegExp) => { const m = all.match(re); const v = m ? money(m[1]) : null; return v ? v.n : null; };
  const opening = num(new RegExp(`(?:opening balance|opening bal\\.?|balance b\\/?f|balance brought forward|brought forward|beginning balance|start balance)\\s*[:\\-]?\\s*(?:NGN|₦)?\\s*(${LABEL_NUM})`, 'i'));
  const closing = num(new RegExp(`(?:closing balance|closing bal\\.?|balance c\\/?f|carried forward|ending balance|end balance|available balance)\\s*[:\\-]?\\s*(?:NGN|₦)?\\s*(${LABEL_NUM})`, 'i'));
  return { bank_name: bank, account_number: acct && acct.length >= 10 && acct.length <= 12 ? acct : null, account_name: name, period_from: from, period_to: to,
    opening_balance: opening, closing_balance: closing };
}

// ------------------------------------------------------------------ the table
const OPENING_ROW = /^(opening balance|opening bal|balance b\/?f|balance brought forward|brought forward|b\/f|balance forward|beginning balance)\b/i;
const CLOSING_ROW = /^(closing balance|closing bal|balance c\/?f|carried forward|c\/f|total|totals|sub ?total|grand total|ending balance|end of statement|total debits?|total credits?)\b/i;
const FOOTER = /^(page \d+|\d+ of \d+$|printed on|generated on|this (is a|statement)|customer care|for enquir|please|disclaimer|www\.|https?:)/i;

// Reads the rows below a header into statement lines.
export function readTable(rows: Cell[][], h: number, roles: Role[], rowNo?: number[]): { lines: StmtLine[]; opening: number | null; closing: number | null; problems: string[] } {
  const col = (r: Role) => roles.indexOf(r);
  const cDate = col('date'), cDesc = col('description'), cRef = col('reference'), cDr = col('debit'), cCr = col('credit'), cAmt = col('amount'), cSign = col('drcr'), cBal = col('balance');
  const lines: (StmtLine & { unsigned?: boolean; mag: number })[] = [];
  let opening: number | null = null; let closing: number | null = null;
  const problems: string[] = [];
  const headerText = rows[h].map((c) => norm(txt(c))).join('|');
  for (let i = h + 1; i < rows.length; i++) {
    const r = rows[i] || [];
    const texts = r.map(txt);
    if (!texts.some(Boolean)) continue;
    if (texts.map(norm).join('|') === headerText) continue; // the heading again on the next page
    const desc = cDesc >= 0 ? texts[cDesc] : texts.filter((x, k) => k !== cDate && x && !money(x) && !stmtDate(x)).join(' ');
    const first = texts.find(Boolean) || '';
    const bal = cBal >= 0 ? money(r[cBal]) : null;
    const d = cDate >= 0 ? stmtDate(r[cDate]) : null;
    const label = texts.find((x) => OPENING_ROW.test(x) || CLOSING_ROW.test(x)) || '';
    const moved = [cDr, cCr, cAmt].some((c) => c >= 0 && Math.abs(money(r[c])?.n || 0) > 0);
    if (OPENING_ROW.test(label) && !moved) { if (bal) opening = bal.n; continue; }
    if (CLOSING_ROW.test(label) && (!d || !moved)) { if (bal && /balance|c\/f|carried/i.test(label)) closing = bal.n; continue; }
    // Money in and out: two columns, one signed column, or an amount with a Dr/Cr marker.
    let mag = 0; let amount = 0; let unsigned = false;
    if (cDr >= 0 || cCr >= 0) {
      const dr = cDr >= 0 ? money(r[cDr]) : null; const cr = cCr >= 0 ? money(r[cCr]) : null;
      const dv = Math.abs(dr?.n || 0); const cv = Math.abs(cr?.n || 0);
      amount = cv - dv; mag = Math.abs(amount);
      if (!dv && !cv && cAmt >= 0) { const a = money(r[cAmt]); if (a) { amount = a.n; mag = Math.abs(a.n); unsigned = !a.signed; } }
    } else if (cAmt >= 0) {
      const a = money(r[cAmt]);
      if (a) {
        mag = Math.abs(a.n);
        const mark = cSign >= 0 ? norm(texts[cSign]) : '';
        if (/^(d|dr|debit|withdrawal|out|-)/.test(mark)) amount = -mag;
        else if (/^(c|cr|credit|deposit|in|\+)/.test(mark)) amount = mag;
        else { amount = a.n; unsigned = !a.signed; }
      }
    }
    if (!d) {
      // A narration that wrapped onto the next printed line, or the heading block of a later page.
      if (!mag && lines.length && desc && !FOOTER.test(desc) && !FOOTER.test(first)) {
        const prev = lines[lines.length - 1];
        prev.description = `${prev.description} ${desc}`.replace(/\s+/g, ' ').trim().slice(0, 500);
        if (!prev.reference && cRef >= 0 && texts[cRef]) prev.reference = texts[cRef];
      } else if (mag && lines.length && !lines[lines.length - 1].mag) {
        // Some layouts print the amount on the line under the date.
        const prev = lines[lines.length - 1];
        Object.assign(prev, { amount, mag, unsigned, balance: bal ? bal.n : prev.balance });
      } else if (mag) {
        problems.push(`Row ${rowNo?.[i] ?? i + 1} has an amount but no date it could read: "${texts.filter(Boolean).join(' · ').slice(0, 80)}".`);
      }
      continue;
    }
    if (!mag && !desc) continue;
    lines.push({ row: rowNo?.[i] ?? i + 1, date: d, description: desc.replace(/\s+/g, ' ').trim().slice(0, 500), reference: cRef >= 0 ? texts[cRef] || null : null,
      amount: r2(amount), balance: bal ? r2(bal.n) : null, issues: [], unsigned, mag: r2(mag) });
  }
  return { lines: lines.filter((l) => l.mag > 0 || l.amount !== 0) as any, opening, closing, problems };
}

// Puts the lines in date order, settles unsigned amounts from the running balance, checks each balance against the
// one before and the whole statement against its opening and closing figures.
export function settle(raw: (StmtLine & { unsigned?: boolean; mag?: number })[], meta: StmtMeta): { lines: StmtLine[]; newest_first: boolean; problems: string[];
  meta: StmtMeta; balance_check: Statement['balance_check']; difference: number | null } {
  const problems: string[] = [];
  let lines = raw.map((l) => ({ ...l, issues: [...(l.issues || [])] }));
  const newest = lines.length > 1 && lines[0].date > lines[lines.length - 1].date;
  if (newest) lines = lines.reverse();
  const hasBal = lines.filter((l) => l.balance != null).length >= Math.max(1, lines.length * 0.6);
  let prevBal: number | null = meta.opening_balance;
  let unsure = 0; let breaks = 0;
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    if (l.unsigned) {
      const mag = Math.abs(l.amount);
      if (hasBal && l.balance != null && prevBal != null) {
        const delta = r2(l.balance - prevBal);
        if (Math.abs(Math.abs(delta) - mag) < 0.011) l.amount = delta < 0 ? -mag : mag;
        else { l.issues.push('Could not tell from the balance whether this was money in or out.'); unsure++; }
      } else if (hasBal && l.balance != null && i + 1 < lines.length && lines[i + 1].balance != null && !lines[i + 1].unsigned) {
        // The first line: work back from the next one.
        const before = r2(lines[i + 1].balance! - lines[i + 1].amount);
        l.amount = Math.abs(r2(before - (l.balance - mag))) < 0.011 ? mag : -mag;
      } else { l.issues.push('No sign, Dr/Cr marker or balance shows whether this was money in or out. Counted as money in.'); unsure++; }
      delete l.unsigned;
    }
    if (l.balance != null && prevBal != null && Math.abs(r2(prevBal + l.amount) - l.balance) >= 0.011) {
      l.issues.push(`The balance does not follow from the line before (expected ${r2(prevBal + l.amount).toLocaleString('en-NG', { minimumFractionDigits: 2 })}).`);
      breaks++;
    }
    if (l.balance != null) prevBal = l.balance; else if (prevBal != null) prevBal = r2(prevBal + l.amount);
    delete (l as any).mag;
  }
  const m = { ...meta };
  if (m.opening_balance == null && lines.length && lines[0].balance != null) m.opening_balance = r2(lines[0].balance - lines[0].amount);
  const lastBal = [...lines].reverse().find((l) => l.balance != null)?.balance ?? null;
  if (m.closing_balance == null) m.closing_balance = lastBal;
  if (!m.period_from && lines.length) m.period_from = lines[0].date;
  if (!m.period_to && lines.length) m.period_to = lines[lines.length - 1].date;
  const sum = r2(lines.reduce((a, l) => a + l.amount, 0));
  let check: Statement['balance_check'] = 'unknown'; let diff: number | null = null;
  if (m.opening_balance != null && m.closing_balance != null) {
    diff = r2(m.opening_balance + sum - m.closing_balance);
    check = Math.abs(diff) < 0.011 ? 'agrees' : 'differs';
  }
  if (unsure) problems.push(`${unsure} line${unsure === 1 ? '' : 's'} could not be told apart as money in or out. Check the marked lines.`);
  if (breaks) problems.push(`${breaks} line${breaks === 1 ? '' : 's'} carry a balance that does not follow from the line before. A line may be missing or misread.`);
  if (check === 'differs') problems.push(`Opening balance plus the lines does not reach the closing balance (off by ${Math.abs(diff!).toLocaleString('en-NG', { minimumFractionDigits: 2 })}).`);
  return { lines, newest_first: newest, problems, meta: m, balance_check: check, difference: diff };
}

// ------------------------------------------------------------------ Excel and CSV
export function fromSheet(sheet: SheetData, kind: 'excel' | 'csv', fileName: string, forced?: { header: number; roles: Role[] }): Statement | null {
  const rows = sheet.rows;
  let h = forced?.header ?? -1; let roles = forced?.roles ?? [];
  if (!forced) {
    let best = -1;
    for (let i = 0; i < Math.min(rows.length, 60); i++) {
      const rs = rolesOf((rows[i] || []).map(txt));
      const sc = roleCount(rs) + (usable(rs) ? 10 : 0);
      if (sc > best) { best = sc; h = i; roles = rs; }
    }
    if (h < 0 || !usable(roles)) return null;
  }
  const above = rows.slice(0, h).map((r) => r.map(txt).filter(Boolean).join('  ')).join('\n');
  const below = rows.slice(-8).map((r) => r.map(txt).filter(Boolean).join('  ')).join('\n');
  const meta = readMeta(above, fileName, below);
  const t = readTable(rows, h, roles, sheet.rowNo);
  if (meta.opening_balance == null && t.opening != null) meta.opening_balance = t.opening;
  if (meta.closing_balance == null && t.closing != null) meta.closing_balance = t.closing;
  const s = settle(t.lines, meta);
  return { kind, read_by: 'columns', meta: s.meta, lines: s.lines, problems: [...t.problems, ...s.problems], newest_first: s.newest_first, roles,
    header: (rows[h] || []).map(txt), balance_check: s.balance_check, difference: s.difference };
}

// CSV is read as text so day-first dates are not turned into month-first ones.
export async function readStatementSheets(file: File): Promise<{ sheets: SheetData[]; kind: 'excel' | 'csv' }> {
  const XLSX = await import('xlsx');
  const csv = /\.(csv|txt)$/i.test(file.name) || file.type === 'text/csv';
  const wb = XLSX.read(await file.arrayBuffer(), csv ? { type: 'array', raw: true } : { type: 'array', cellDates: true });
  const sheets = wb.SheetNames.map((name) => {
    const ws = wb.Sheets[name];
    if (!ws?.['!ref']) return { name, rows: [] as Cell[][], rowNo: [] as number[] };
    const r = XLSX.utils.decode_range(ws['!ref']);
    const range = { s: { r: 0, c: 0 }, e: { r: Math.min(r.e.r, 20000), c: Math.min(r.e.c, 60) } };
    const all = XLSX.utils.sheet_to_json<Cell[]>(ws, { header: 1, raw: !csv, rawNumbers: csv ? false : undefined, defval: null, blankrows: true, range }) as Cell[][];
    const rows: Cell[][] = []; const rowNo: number[] = [];
    all.forEach((row, i) => {
      const clean = row.map((c) => (typeof c === 'string' ? c.trim() || null : c));
      if (clean.some((c) => c != null && c !== '')) { rows.push(clean); rowNo.push(i + 1); }
    });
    return { name, rows, rowNo };
  }).filter((s) => s.rows.length);
  return { sheets, kind: csv ? 'csv' : 'excel' };
}

// ------------------------------------------------------------------ PDF
export class PdfPasswordError extends Error { constructor(public wrong: boolean) { super(wrong ? 'That password did not open the statement.' : 'This statement is protected with a password.'); } }
interface Chunk { x0: number; x1: number; s: string }
// raw: the words as the PDF holds them; chunks: neighbouring words of text joined (figures are never joined, so a credit
// printed close to its balance stays two figures).
interface PdfLine { y: number; h: number; raw: Chunk[]; chunks: Chunk[] }
export interface PdfText { pages: PdfLine[][]; scanned: boolean; numPages: number }

let pdfjsP: Promise<any> | null = null;
async function pdfjs() {
  if (!pdfjsP) {
    pdfjsP = (async () => {
      const lib: any = await import('pdfjs-dist/legacy/build/pdf.mjs');
      const worker = (await import('pdfjs-dist/legacy/build/pdf.worker.min.mjs?url')).default;
      lib.GlobalWorkerOptions.workerSrc = worker;
      return lib;
    })();
  }
  return pdfjsP;
}

export async function openPdf(file: File, password?: string): Promise<any> {
  const lib = await pdfjs();
  try {
    return await lib.getDocument({ data: new Uint8Array(await file.arrayBuffer()), password, isEvalSupported: false }).promise;
  } catch (e: any) {
    if (e?.name === 'PasswordException') throw new PdfPasswordError(e.code === 2);
    throw new Error('Could not open that PDF. If the bank emailed it, download it again or ask the bank for an Excel copy.');
  }
}

const isFigure = (s: string) => moneyLike(s) || /^(DR|CR)\.?$/i.test(s.trim());
export function linesOf(items: { x0: number; x1: number; y: number; h: number; s: string }[]): PdfLine[] {
  const sorted = [...items].sort((a, b) => b.y - a.y || a.x0 - b.x0);
  const lines: PdfLine[] = [];
  for (const it of sorted) {
    const ln = lines.find((l) => Math.abs(l.y - it.y) <= Math.max(2, Math.min(l.h, it.h) * 0.45));
    const c = { x0: it.x0, x1: it.x1, s: it.s };
    if (ln) { ln.raw.push(c); ln.h = Math.max(ln.h, it.h); } else lines.push({ y: it.y, h: it.h, raw: [c], chunks: [] });
  }
  for (const ln of lines) {
    ln.raw.sort((a, b) => a.x0 - b.x0);
    const merged: Chunk[] = [];
    for (const c of ln.raw) {
      const last = merged[merged.length - 1];
      if (last && !isFigure(c.s) && !isFigure(last.s) && !stmtDate(last.s) && c.x0 - last.x1 < ln.h * 0.6) {
        last.s = `${last.s}${c.x0 - last.x1 > ln.h * 0.15 ? ' ' : ''}${c.s}`.replace(/\s+/g, ' ');
        last.x1 = Math.max(last.x1, c.x1);
      } else merged.push({ ...c });
    }
    // "1,000.00" and a separate "CR" are one figure.
    const out: Chunk[] = [];
    for (const c of merged) {
      const last = out[out.length - 1];
      if (last && /^(DR|CR)\.?$/i.test(c.s.trim()) && moneyLike(last.s) && c.x0 - last.x1 < ln.h * 1.5) { last.s = `${last.s} ${c.s.trim()}`; last.x1 = c.x1; }
      else out.push({ ...c, s: c.s.trim() });
    }
    ln.chunks = out.filter((c) => c.s);
  }
  return lines.sort((a, b) => b.y - a.y);
}

// The words on each page grouped into printed lines.
export async function pdfText(doc: any): Promise<PdfText> {
  const pages: PdfLine[][] = [];
  let chars = 0;
  for (let p = 1; p <= doc.numPages; p++) {
    const page = await doc.getPage(p);
    const tc = await page.getTextContent();
    const items = (tc.items as any[]).filter((it) => typeof it.str === 'string' && it.str.trim()).map((it) => {
      const hgt = Math.abs(it.transform[3]) || it.height || 8;
      return { x0: it.transform[4], x1: it.transform[4] + (it.width || it.str.length * hgt * 0.5), y: it.transform[5], h: hgt, s: it.str.replace(/\s+/g, ' ') };
    });
    chars += items.reduce((a, it) => a + it.s.trim().length, 0);
    pages.push(linesOf(items));
  }
  return { pages, scanned: chars < 40 * doc.numPages, numPages: doc.numPages };
}

// Page text with columns kept apart, for the AI reader.
export const pageText = (lines: PdfLine[]) => lines.map((l) => l.chunks.map((c) => c.s).join(' | ')).join('\n');

// Page images for a scanned statement.
export async function pageImages(doc: any, from: number, to: number): Promise<{ mime: string; data: string }[]> {
  const out: { mime: string; data: string }[] = [];
  for (let p = from; p <= Math.min(to, doc.numPages); p++) {
    const page = await doc.getPage(p);
    // About 2,000 pixels across, so small print on a scan stays legible to the reader.
    const vp = page.getViewport({ scale: Math.min(3.5, 2000 / page.getViewport({ scale: 1 }).width) });
    const c = document.createElement('canvas'); c.width = Math.round(vp.width); c.height = Math.round(vp.height);
    await page.render({ canvasContext: c.getContext('2d')!, viewport: vp, canvas: c }).promise;
    out.push({ mime: 'image/jpeg', data: c.toDataURL('image/jpeg', 0.85).split(',')[1] });
    page.cleanup();
  }
  return out;
}

// A heading line: words joined only when together they make a known heading ("Trans" + "Date"), so two headings
// printed close together ("Debit" "Credit") stay two columns. A heading printed on two lines ("Value" over "Date") is
// put together column by column.
function headingOf(lines: PdfLine[], i: number): { roles: Role[]; cols: Chunk[]; skip: number } | null {
  const known = new Set(SYN.flatMap(([, syns]) => syns.map((x) => x.replace(/\//g, ' '))));
  const join = (raw: Chunk[], h: number) => {
    const out: Chunk[] = [];
    for (let k = 0; k < raw.length; k++) {
      let best = raw[k]; let used = 0;
      for (let n = 1; n <= 3 && k + n < raw.length; n++) {
        const cand = raw.slice(k, k + n + 1);
        // Only words printed close together make one heading.
        if (cand.some((c, j) => j > 0 && c.x0 - cand[j - 1].x1 > h * 1.2)) break;
        const text = cand.map((c) => c.s).join(' ');
        if (known.has(norm(text).replace(/\//g, ' '))) { best = { x0: cand[0].x0, x1: cand[cand.length - 1].x1, s: text }; used = n; }
      }
      out.push(best); k += used;
    }
    return out;
  };
  const tryCols = (cols: Chunk[]) => { const roles = rolesOf(cols.map((c) => c.s)); return usable(roles) && roleCount(roles) >= 3 ? roles : null; };
  const one = join(lines[i].raw, lines[i].h);
  const r1 = tryCols(one);
  if (r1) return { roles: r1, cols: one, skip: 0 };
  if (i + 1 < lines.length && lines[i].y - lines[i + 1].y < lines[i].h * 2.2) {
    const two = one.map((c) => ({ ...c }));
    for (const c of join(lines[i + 1].raw, lines[i + 1].h)) {
      const over = two.find((m) => c.x0 < m.x1 + 3 && c.x1 > m.x0 - 3);
      if (over) { over.s = `${over.s} ${c.s}`; over.x0 = Math.min(over.x0, c.x0); over.x1 = Math.max(over.x1, c.x1); } else two.push({ ...c });
    }
    two.sort((a, b) => a.x0 - b.x0);
    const r2x = tryCols(two);
    if (r2x) return { roles: r2x, cols: two, skip: 1 };
  }
  return null;
}

const NOISE = /^(channel|category|branch|originating branch|status|terminal( id)?|mode|transaction channel|tran channel)$/;
// Turns the printed lines into the same table an Excel statement gives: the heading fixes where each column sits,
// and every word below goes to the column it falls under (figures by their right edge, as banks right-align them).
export function pdfTable(t: PdfText): { rows: Cell[][]; header: number; roles: Role[]; metaText: string } | null {
  let cols: { role: Role; x0: number; x1: number; label: string }[] | null = null;
  const rows: Cell[][] = []; let header = -1; let metaText = '';
  const NUMERIC: Role[] = ['debit', 'credit', 'amount', 'balance'];
  for (let p = 0; p < t.pages.length; p++) {
    const lines = t.pages[p];
    let i = 0; let headed = false;
    for (let k = 0; k < Math.min(lines.length, 45); k++) {
      const hd = headingOf(lines, k);
      if (!hd) continue;
      if (!cols) { header = rows.length; rows.push(hd.roles.map((r) => r)); }
      cols = hd.cols.map((c, j) => ({ role: hd.roles[j], x0: c.x0, x1: c.x1, label: norm(c.s) }));
      if (header === 0 && !metaText) metaText = lines.slice(0, k).map((l) => l.chunks.map((c) => c.s).join('  ')).join('\n');
      i = k + 1 + hd.skip; headed = true;
      break;
    }
    if (!cols) { if (p === 0) metaText = lines.map((l) => l.chunks.map((c) => c.s).join('  ')).join('\n'); continue; }
    // Rows are written in the first page's column order.
    const firstRoles = rows[header] as Role[];
    const dateCol = cols.findIndex((c) => c.role === 'date');
    const descCol = cols.findIndex((c) => c.role === 'description');
    let lastY: number | null = null; let started = headed;
    for (; i < lines.length; i++) {
      const ln = lines[i];
      const cells: (string | null)[] = cols.map(() => null);
      for (const c of ln.chunks) {
        let best = -1;
        if (isFigure(c.s)) {
          let d = Infinity;
          cols.forEach((col, j) => { if (NUMERIC.includes(col.role)) { const dd = Math.abs(col.x1 - c.x1); if (dd < d) { d = dd; best = j; } } });
          if (best >= 0 && d > Math.max(90, (cols[best].x1 - cols[best].x0) * 3)) best = -1;
        }
        if (best < 0) {
          const mid = (c.x0 + c.x1) / 2;
          let d = Infinity;
          cols.forEach((col, j) => { const dd = mid >= col.x0 - 4 && mid <= col.x1 + 4 ? 0 : Math.min(Math.abs(col.x0 - mid), Math.abs(col.x1 - mid)); if (dd < d) { d = dd; best = j; } });
          // A channel or category column ("Mobile", "POS", "Bills") says nothing about who paid; it stays out of the narration.
          if (d === 0 && cols[best].role === 'ignore' && NOISE.test(cols[best].label)) continue;
          // Words spilling out of the narration belong to it.
          if (descCol >= 0 && /[a-z]{2}/i.test(c.s) && !stmtDate(c.s) && !['description', 'reference', 'drcr'].includes(cols[best].role)) best = descCol;
        }
        cells[best] = cells[best] == null ? c.s : `${cells[best]} ${c.s}`;
      }
      const dated = dateCol >= 0 && !!stmtDate(cells[dateCol]);
      // A page without its own heading starts at its first dated line; a big gap after the table is the footer.
      if (!started) { if (!dated) continue; started = true; }
      if (lastY != null && lastY - ln.y > ln.h * 4 && !dated) { lastY = ln.y; continue; }
      lastY = ln.y;
      rows.push(firstRoles.map((role) => { const j = cols!.findIndex((c) => c.role === role && role !== 'ignore'); return j >= 0 ? cells[j] : null; }));
      // Columns this page has that the first page's heading did not name are dropped.
    }
  }
  if (!cols || header < 0) return null;
  return { rows, header, roles: rows[header] as Role[], metaText };
}

export function fromPdfText(t: PdfText, fileName: string): Statement | null {
  const tb = pdfTable(t);
  if (!tb) return null;
  const lastPage = (t.pages[t.pages.length - 1] || []).map((l) => l.chunks.map((c) => c.s).join('  ')).join('\n');
  const meta = readMeta(tb.metaText, fileName, lastPage);
  const tr = readTable(tb.rows, tb.header, tb.roles);
  if (meta.opening_balance == null && tr.opening != null) meta.opening_balance = tr.opening;
  if (meta.closing_balance == null && tr.closing != null) meta.closing_balance = tr.closing;
  if (!tr.lines.length) return null;
  const s = settle(tr.lines, meta);
  return { kind: 'pdf', read_by: 'columns', meta: s.meta, lines: s.lines, problems: [...tr.problems, ...s.problems], newest_first: s.newest_first, roles: tb.roles,
    balance_check: s.balance_check, difference: s.difference };
}

// What the AI reader returns, through the same checks.
export interface AiStatement {
  bank_name?: string | null; account_number?: string | null; account_name?: string | null; period_from?: string | null; period_to?: string | null;
  opening_balance?: number | null; closing_balance?: number | null; order?: 'oldest_first' | 'newest_first'; notes?: string | null;
  lines: { date: string | null; description: string; reference: string | null; debit: number | null; credit: number | null; balance: number | null }[];
}
export function fromAi(parts: AiStatement[], fileName: string): Statement {
  const head = parts[0] || ({ lines: [] } as AiStatement);
  const last = parts[parts.length - 1] || head;
  const pick = (k: 'opening_balance' | 'closing_balance', order: AiStatement[]) => order.map((p) => p[k]).find((v) => v != null) ?? null;
  const meta: StmtMeta = {
    bank_name: head.bank_name || readMeta('', fileName).bank_name, account_number: head.account_number || null, account_name: head.account_name || null,
    period_from: head.period_from || null, period_to: last.period_to || head.period_to || null,
    opening_balance: pick('opening_balance', parts), closing_balance: pick('closing_balance', [last, ...parts.slice(0, -1).reverse()]),
  };
  const problems: string[] = [];
  // Each part is put oldest first (by its dates, or the order the reader saw when its dates are all one day), and the
  // parts in date order: a statement printed newest first has its newest lines on page 1.
  const asc = parts.map((p, k) => {
    const days = p.lines.map((l) => l.date).filter(Boolean) as string[];
    const rev = days.length > 1 && days[0] !== days[days.length - 1] ? days[0] > days[days.length - 1] : p.order === 'newest_first';
    const lines = rev ? [...p.lines].reverse() : p.lines;
    const d = lines.map((l) => l.date).filter(Boolean) as string[];
    return { k, p, lines, from: d[0] || '', to: d[d.length - 1] || '' };
  });
  const newestFirst = asc.length > 1 && asc[0].from > asc[asc.length - 1].from;
  const ordered = newestFirst ? [...asc].reverse() : asc;
  const raw: StmtLine[] = [];
  let n = 0;
  for (const { p, lines } of ordered) {
    for (const l of lines) {
      n++;
      if (!l.date) { problems.push(`Line ${n} has no date the reader could make out: "${String(l.description || '').slice(0, 60)}".`); continue; }
      const amt = r2(Math.abs(l.credit || 0) - Math.abs(l.debit || 0));
      if (!amt) continue;
      raw.push({ row: n, date: l.date, description: l.description, reference: l.reference, amount: amt, balance: l.balance ?? null, issues: [] });
    }
    if (p.notes) problems.push(p.notes);
  }
  // A reader looking at a newest-first page sometimes gives the balance after the oldest line as the opening balance.
  const first = raw[0];
  const near = (a: number | null | undefined, b: number | null | undefined) => a != null && b != null && Math.abs(a - b) < 0.011;
  if (first && first.balance != null && near(meta.opening_balance, first.balance) && !near(r2(first.balance - first.amount), meta.opening_balance)) {
    meta.opening_balance = r2(first.balance - first.amount);
  }
  // Read a few pages at a time, a reader may give where its pages start or end as the statement's opening or closing
  // balance. A figure that is the balance part-way through the statement is not either; the lines' own balances are used.
  if (raw.length > 1 && meta.opening_balance != null && first?.balance != null && !near(r2(first.balance - first.amount), meta.opening_balance)
      && raw.slice(1).some((l) => l.balance != null && (near(l.balance, meta.opening_balance) || near(r2(l.balance - l.amount), meta.opening_balance)))) meta.opening_balance = null;
  const end = raw[raw.length - 1];
  if (raw.length > 1 && meta.closing_balance != null && end?.balance != null && !near(end.balance, meta.closing_balance)
      && raw.slice(0, -1).some((l) => near(l.balance, meta.closing_balance))) meta.closing_balance = null;
  // Money in read as money out (or the other way) shows in the running balance: when the balance before and after say
  // plainly which way it went, that is what is recorded, and the line says so.
  let prev: number | null = meta.opening_balance;
  for (const l of raw) {
    if (l.balance != null && prev != null && Math.abs(r2(prev + l.amount) - l.balance) >= 0.011 && Math.abs(r2(prev - l.amount) - l.balance) < 0.011) {
      l.amount = -l.amount;
      l.issues.push(`Read as money ${l.amount > 0 ? 'out' : 'in'}; the running balance shows money ${l.amount > 0 ? 'in' : 'out'}, so it is recorded that way.`);
    }
    prev = l.balance ?? (prev == null ? null : r2(prev + l.amount));
  }
  const s = settle(raw, meta);
  return { kind: 'pdf', read_by: 'ai', meta: s.meta, lines: s.lines, problems: [...problems, ...s.problems], newest_first: newestFirst || asc.some((x) => x.lines !== x.p.lines), balance_check: s.balance_check, difference: s.difference };
}

export const lastFour = (s: string | null | undefined) => (s || '').replace(/\D/g, '').slice(-4);
