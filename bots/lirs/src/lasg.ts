// Paying an e-Tax bill by transfer, through e-Tax's Flutterwave channel: the Lagos State Government payments page
// (payments.lasg-public.com/tax-confirm?bill_type=<bill reference>). The page asks for an email and phone number, then
// Make Payment, Bank transfer, Proceed to pay, and Flutterwave's checkout shows a one-time account for the exact amount.
// The bot reads that account and closes the page; it never presses "I have made this bank transfer" and never pays.
// The same page shows whether the bill is paid, which is how the bot checks for the payment (no e-Tax sign-in, so the
// person is never signed out of e-Tax by these checks).
import type { Browser, Page, Response } from 'playwright';
import { cfg } from './config.js';
import { Refused, Transient } from './errors.js';
import { newContext } from './etax.js';
import type { Reporter } from './file.js';

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const n = (v: unknown) => { const x = Number(String(v ?? '').replace(/[,₦\s]|NGN/gi, '')); return Number.isFinite(x) ? x : 0; };

// The first object (depth-first) that has every one of the keys.
export function findWith(x: any, keys: string[], depth = 0): any {
  if (!x || typeof x !== 'object' || depth > 8) return null;
  if (!Array.isArray(x) && keys.every((k) => k in x)) return x;
  for (const v of Array.isArray(x) ? x : Object.values(x)) { const f = findWith(v, keys, depth + 1); if (f) return f; }
  return null;
}

// A time Flutterwave gives ("2026-11-04 22:33:30", an ISO string, or seconds or milliseconds since 1970) as ISO.
export function toIso(v: unknown): string | null {
  if (v === null || v === undefined || v === '') return null;
  if (typeof v === 'number' || /^\d{9,13}$/.test(String(v))) { const x = Number(v); const d = new Date(x < 1e12 ? x * 1000 : x); return isNaN(+d) ? null : d.toISOString(); }
  const s = String(v).trim();
  // Flutterwave's plain times are Lagos time (UTC+1).
  const plain = s.match(/^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}(?::\d{2})?)$/);
  const d = new Date(plain ? `${plain[1]}T${plain[2].length === 5 ? plain[2] + ':00' : plain[2]}+01:00` : s);
  return isNaN(+d) ? null : d.toISOString();
}

type Seen = { url: string; body: any };
async function open(browser: Browser, ref: string) {
  const ctx = await newContext(browser);
  const page = await ctx.newPage();
  page.setDefaultTimeout(cfg.navTimeoutMs);
  const seen: Seen[] = [];
  const take = async (r: Response) => {
    const ct = r.headers()['content-type'] || '';
    if (!ct.includes('json')) return;
    try { seen.push({ url: r.url(), body: await r.json() }); } catch { /* not readable */ }
  };
  page.on('response', (r) => { void take(r); });
  try {
    await page.goto(`${cfg.lasgBase}/tax-confirm?bill_type=${encodeURIComponent(ref)}`, { waitUntil: 'domcontentloaded' });
  } catch (e) {
    await ctx.close().catch(() => {});
    throw new Transient(`The Lagos State payments page did not open (${(e as Error).message.split('\n')[0]}).`);
  }
  return { ctx, page, seen };
}

// What the page says about the bill: its invoice as the page's own API gave it, and which screen it shows.
async function state(page: Page, seen: Seen[], ref: string, waitMs = cfg.navTimeoutMs, leaving = '') {
  const until = Date.now() + waitMs;
  while (Date.now() < until) {
    const inv = [...seen].reverse().map((s) => findWith(s.body, ['bill_reference', 'status'])).find((x) => x && String(x.bill_reference) === ref)
      || [...seen].reverse().map((s) => findWith(s.body, ['bill_reference', 'status'])).find(Boolean);
    const screen = await page.evaluate(() => {
      const t = document.body?.innerText || '';
      if (document.querySelector('input[name="email"]')) return 'form';
      if (/Reset Payment/i.test(t)) return 'pending';
      if (/Payment successfully completed|Download receipt|Send receipt/i.test(t)) return 'paid';
      if (/cannot be processed|Something went wrong/i.test(t)) return 'error';
      return '';
    }).catch(() => '');
    if (screen && screen !== leaving) return { inv, screen, text: await page.evaluate(() => document.body?.innerText || '').catch(() => '') };
    await sleep(500);
  }
  throw new Transient('The Lagos State payments page did not show the bill.');
}

export async function billStatus(browser: Browser, c: any) {
  const ref = String(c.bill?.existing?.reference || '');
  if (!ref) throw new Refused('There is no bill to check yet.');
  const { ctx, page, seen } = await open(browser, ref);
  try {
    const s = await state(page, seen, ref);
    if (s.screen === 'error') throw new Transient(`The Lagos State payments page could not show bill ${ref} just now.`);
    const status = String(s.inv?.status || (s.screen === 'paid' ? 'paid' : '')).toLowerCase();
    const paid = status === 'paid' || s.screen === 'paid';
    return { paid, status: status || s.screen, reference: ref, amount_paid: paid ? n(s.inv?.bill_amount ?? s.inv?.amount ?? c.bill?.existing?.amount) || null : null,
      paid_at: paid ? (toIso(s.inv?.paid_at ?? s.inv?.payment_date ?? s.inv?.updated_at) || null) : null };
  } finally { await ctx.close().catch(() => {}); }
}

// The person's phone as the page wants it: the ten digits after +234.
export function localPhone(p: unknown) {
  let d = String(p ?? '').replace(/\D/g, '');
  if (d.startsWith('234')) d = d.slice(3);
  if (d.startsWith('0')) d = d.slice(1);
  return /^[789]\d{9}$/.test(d) ? d : '';
}

// The one-time account in Flutterwave's checkout: from its own API answer, or read off the checkout.
function accountFrom(seen: Seen[]) {
  for (const s of [...seen].reverse()) {
    const a = findWith(s.body, ['transfer_account']) || findWith(s.body, ['account_number', 'bank_name']);
    if (a) {
      const num = String(a.transfer_account ?? a.account_number ?? '').replace(/\s/g, '');
      if (/^\d{10}$/.test(num)) {
        return { account_number: num, bank_name: String(a.transfer_bank ?? a.bank_name ?? ''), account_name: String(a.account_name ?? a.transfer_account_name ?? a.beneficiary_name ?? a.transfer_note ?? ''),
          amount: n(a.transfer_amount ?? a.amount), expires_at: toIso(a.account_expiration ?? a.expires_at ?? a.expiry_date) };
      }
    }
  }
  return null;
}
export function accountFromText(t: string) {
  const text = t.replace(/ /g, ' ');
  const num = text.match(/account\s*(?:number|no\.?)?\s*[:\n ]*\s*(\d{10})\b/i)?.[1] || text.match(/\b(\d{10})\b/)?.[1];
  if (!num) return null;
  const lines = text.split('\n').map((l) => l.trim()).filter((l) => l && l.length < 80 && !/transfer|account number|^bank(\s*name)?:?$/i.test(l));
  const bank = lines.find((l) => /\b(MFB|Microfinance)\b/i.test(l)) || lines.find((l) => /\bBank\b/i.test(l)) || '';
  const amt = text.match(/(?:₦|NGN)\s?([\d,]+(?:\.\d{2})?)/)?.[1];
  const mins = text.match(/(?:expires?|valid)\D{0,20}(\d{1,3})\s*(?:min|minutes)/i)?.[1] || text.match(/\b(\d{1,2}):(\d{2})\b/)?.[1];
  return { account_number: num, bank_name: bank.replace(/^bank\s*(?:name)?\s*:?\s*/i, ''), account_name: /LASG Collection/i.test(text) ? 'LASG Collection' : '',
    amount: n(amt), expires_at: mins ? new Date(Date.now() + Number(mins) * 60_000).toISOString() : null };
}

export async function transferAccount(browser: Browser, c: any, rep: Reporter) {
  const ref = String(c.bill?.existing?.reference || '');
  if (!ref) throw new Refused('There is no bill to pay yet.');
  const email = String(c.org?.email || '').trim();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) throw new Refused('The Lagos State payments page needs an email for the receipt. Add the business\'s email under Settings, then ask again.');
  const { ctx, page, seen } = await open(browser, ref);
  try {
    let s = await state(page, seen, ref);
    if (s.screen === 'paid' || String(s.inv?.status || '').toLowerCase() === 'paid') return { paid: true, reference: ref };
    if (s.screen === 'error') throw new Transient(`The Lagos State payments page could not take bill ${ref} just now.`);
    if (s.screen === 'pending') {
      // An earlier account was asked for and not used: start again for a fresh one.
      await page.getByText('Reset Payment', { exact: true }).first().click();
      s = await state(page, seen, ref, cfg.navTimeoutMs, 'pending');
      if (s.screen !== 'form') throw new Transient('The Lagos State payments page did not start a new payment.');
    }
    const due = n(s.inv?.amount_to_pay ?? s.inv?.bill_amount ?? c.bill?.existing?.amount);
    await page.locator('input[name="email"]').fill(email);
    const phone = localPhone(c.org?.phone);
    if (phone && await page.locator('input[name="phone_number"]').count()) await page.locator('input[name="phone_number"]').fill(phone);
    const amt = page.locator('input[name="amount"]');
    if (await amt.count() && await amt.isEditable().catch(() => false)) {
      const cur = n(await amt.inputValue().catch(() => ''));
      if (!cur && due) await amt.fill(due.toFixed(2));
      else if (due && Math.abs(cur - due) > 0.005) throw new Refused(`The payments page asks for ₦${cur.toFixed(2)}, not the bill's ₦${due.toFixed(2)}. Nothing was paid.`);
    }
    await page.getByRole('button', { name: /Make Payment/i }).first().click();
    await page.getByText('Payment Options').first().waitFor();
    await page.getByText('Bank transfer', { exact: true }).first().click();
    const modal = await page.evaluate(() => document.body?.innerText || '');
    const fee = n(modal.match(/Processing fee\s*\n?\s*\+?₦?\s*([\d,]+(?:\.\d+)?)/i)?.[1]);
    await rep.step('payment_page', `Bank transfer chosen on the Lagos State payments page${fee ? ` (fee ₦${fee.toFixed(2)})` : ''}.`);
    await page.getByRole('button', { name: /Proceed to pay/i }).first().click();
    // Flutterwave's checkout opens over the page with the account.
    const until = Date.now() + 60_000;
    let acct = null as ReturnType<typeof accountFrom>;
    let nudged = false;
    while (Date.now() < until && !acct) {
      acct = accountFrom(seen);
      if (acct) break;
      for (const f of page.frames()) {
        if (f === page.mainFrame()) continue;
        const t = await f.evaluate(() => document.body?.innerText || '').catch(() => '');
        if (/account/i.test(t)) { const a = accountFromText(t); if (a) { acct = a; break; } }
        // Some checkouts ask once more for the transfer option.
        if (!nudged && /bank transfer/i.test(t) && Date.now() > until - 45_000) {
          const b = f.getByText(/^(Pay with )?bank transfer$/i).first();
          if (await b.count()) { await b.click().catch(() => {}); nudged = true; }
        }
      }
      await sleep(700);
    }
    if (!acct) throw new Transient('Flutterwave\'s checkout did not show a transfer account.');
    const charge = [...seen].reverse().map((x) => (/create-charge/.test(x.url) ? x.body : null)).find(Boolean);
    const exact = acct.amount || n(charge?.charge_amount ?? charge?.data?.charge_amount) || (due + fee);
    return { account_number: acct.account_number, bank_name: acct.bank_name || 'Flutterwave MFB', account_name: acct.account_name || 'LASG Collection',
      amount: Math.round(exact * 100) / 100, fee: fee || Math.max(Math.round((exact - due) * 100) / 100, 0), expires_at: acct.expires_at,
      channel: 'Flutterwave', charge_reference: String(charge?.reference ?? charge?.data?.reference ?? '') || null };
  } finally {
    await ctx.close().catch(() => {});
  }
}
