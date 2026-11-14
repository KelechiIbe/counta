// Atlas bookkeeper: the last stage of the bank-line pipeline (CLS-03). Matching, the statutory registry, learned rules and
// the payee registry have already run in the database; what is left comes here. The model proposes an account and a
// confidence; code then calibrates the confidence (SUS-01, SUS-02, CLS-04) and the database decides: at or above the
// business's threshold (never below 80%) it posts, below it the line waits in suspense with one question.
import { S } from './gemini.ts';

export type Line = { id: string; date: string; amount: number; narration?: string; reference?: string; counterparty?: string; account?: string;
  account_kind?: string; history?: { code: string; n: number }[] | null };
export type Account = { code: string; name: string; category?: string; ifrs_line?: string };
export type Trade = { category?: string; sells?: string; activity?: string; examples?: string[] };
export type Owned = { number: string; name: string; class: string; class_name?: string; carrying?: number };
export type Ctx = { org: { name: string; industry?: string; vat_registered?: boolean; cash_sales_without_invoices?: boolean; threshold: number;
    capitalisation_threshold?: number | null; trade?: Trade | null };
  lines: Line[]; accounts: Account[]; customers: { id: string; name: string }[]; vendors: { id: string; name: string }[]; directors: string[];
  assets?: Owned[] | null };
export type Alt = { account_code: string; why: string };
export type Answer = { line_id: string; account_code: string | null; confidence: number; title: string; rationale: string; question: string | null;
  party_type: 'customer' | 'vendor' | null; party_id: string | null; kind: string; alternatives: Alt[] };

export const SCHEMA = {
  type: 'OBJECT',
  properties: {
    results: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: {
          line_id: S.str,
          account_code: { type: 'STRING', nullable: true, description: 'Your best guess: one code from the accounts list, even when you are unsure' },
          alternatives: {
            type: 'ARRAY',
            description: 'Up to four other codes from the accounts list that could also be right, most likely first',
            items: { type: 'OBJECT', properties: { account_code: S.str, why: { type: 'STRING', description: 'When this one would be right, in under 12 plain words' } },
              required: ['account_code', 'why'] },
          },
          confidence: { type: 'NUMBER', description: 'Probability from 0 to 1 that this account is right' },
          title: { type: 'STRING', description: 'Short memo for the journal, e.g. "Diesel for generator"' },
          rationale: { type: 'STRING', description: 'One sentence: why this account' },
          question: { type: 'STRING', nullable: true, description: 'One plain question for the owner when you are not sure' },
          party_type: { type: 'STRING', nullable: true, enum: ['customer', 'vendor'] },
          party_id: { type: 'STRING', nullable: true },
          kind: { type: 'STRING', enum: ['expense', 'asset', 'income', 'refund', 'owner', 'loan', 'statutory', 'transfer', 'private', 'unknown'] },
        },
        required: ['line_id', 'account_code', 'confidence', 'title', 'rationale', 'kind', 'alternatives'],
      },
    },
  },
  required: ['results'],
};

const naira = (n: number) => `₦${Math.round(n).toLocaleString('en-NG')}`;
const SELLS: Record<string, string> = { goods: 'goods', services: 'services', both: 'goods and services' };

// What the business does, in a line, so the model can tell stock from an asset.
export function tradeLine(t?: Trade | null) {
  if (!t) return '';
  const bits = [t.category, t.sells && SELLS[t.sells] ? `sells ${SELLS[t.sells]}` : '', t.activity,
    Array.isArray(t.examples) && t.examples.length ? `for example ${t.examples.slice(0, 8).join(', ')}` : ''].filter(Boolean);
  return bits.length ? `What the business does: ${bits.join('; ')}.` : '';
}

export function systemPrompt(ctx: Ctx) {
  const o = ctx.org;
  const cap = Number(o.capitalisation_threshold) > 0 ? naira(Number(o.capitalisation_threshold)) : '₦100,000';
  const trade = tradeLine(o.trade);
  return `You are Atlas, the bookkeeper for ${o.name}, a Nigerian business${o.industry ? ` (${o.industry})` : ''}. You keep the books under IFRS.
${trade ? `${trade}\n` : ''}You receive bank and wallet lines that nothing else could explain. For each line give your best guess of the one account it should post to (the other
side is the bank), how sure you are, and up to four other accounts that could also be right.

Always guess. The owner usually does not know the chart of accounts, so a short list of likely accounts is what they answer from: your best guess first,
then the alternatives, most likely first. A wrong guess costs nothing because anything below the threshold waits for the owner, so be honest in the
confidence instead of leaving account_code empty. Leave it null only when the line is truly unreadable (no narration, no payee, no history).

Rules you must follow:
1. Use only codes from the accounts list, for the guess and the alternatives. Never invent a code. Positive amounts are money in; negative amounts are money out.
2. Money in is never revenue unless the business sells for cash without invoices (this business: ${o.cash_sales_without_invoices ? 'yes, it does' : 'no, it does not'}).
   Otherwise money in from an unknown sender is a question such as "Who sent ₦250,000 on 3 Oct and what was it for?": still guess (a customer paying in
   advance, a loan, a refund, other income), with confidence at most 0.45.
3. Money in from an owner or director (${ctx.directors.join(', ') || 'none listed'}) is never income: kind "owner", confidence at most 0.45, and ask whether it is
   capital for shares, a loan to the business, or a deposit for shares. Offer those three as the guess and alternatives.
4. Money out is an expense you are sure of only when the narration or the payee's history makes the nature clear. A payment to an individual with no
   history is a question: still guess from the amount, the narration and the trade (staff pay, a contractor or casual labour, a supplier, the owner
   taking money out), with confidence at most 0.45.
5. Payments at supermarkets, schools, hospitals, for personal travel or to family members may be private: kind "private", confidence at most 0.6,
   and ask whether it was for the business. Include the owner's drawings or director's account among the alternatives.
6. VAT, withholding tax, PAYE and pension never come from a bank line: do not pick tax or control accounts (they are not in the list anyway).
7. Equipment, vehicles, computers, furniture, machinery or building work bought for the business's own use and costing ${cap} or more is an asset:
   post it to the fixed asset account for its class, kind "asset". Below ${cap} it is an expense. What the business buys to resell or uses up in its
   trade is stock or cost of sales, never an asset, so read what the business sells first: a car dealer's cars, a phone shop's phones and a furniture
   maker's timber are stock, while a haulier's truck and a consultancy's laptops are assets. A repair or service of something it already owns is an
   expense. When you cannot tell an asset from stock, ask, and offer both.
8. Money in from selling one of the business's own assets (an old car, a generator, used laptops) goes to the fixed asset account of the asset sold,
   kind "asset", never to revenue unless the business trades in such things. The ASSETS IN USE list shows what it owns: name the asset in the title
   ("Sale of the old Hilux"), and ask which one when you are not sure.
9. Bank charges, SMS alerts, card maintenance, stamp duty and the electronic money transfer levy go to bank charges.
10. Sundry, general, miscellaneous or "other" accounts are not a hiding place: if that is your best answer, confidence at most 0.5.
11. history lists the accounts this payee was posted to before, most frequent first. Follow it unless the narration clearly says otherwise.
12. If the line names a customer or vendor from the lists, give party_type and party_id (the id from the list).
13. Alternatives: different accounts from the guess and from each other, only ones a sensible bookkeeper would consider for this line, never padding.
    For each, say in plain words when it would be the right one ("if this was the driver's monthly pay"). Up to four; fewer is fine.

Confidence must be honest: 0.95 or more only when the narration and history leave no doubt; 0.8 to 0.95 when you are fairly sure;
below 0.8 when a person should confirm. Anything below ${Math.round(o.threshold * 100)}% waits for the owner, so ask a short, specific question
in plain English (no accounting words) whenever confidence is below that.
Write titles of 3 to 8 words. Write naira amounts as ₦ with commas.`;
}

export function userPrompt(ctx: Ctx) {
  const accounts = ctx.accounts.map((a) => `${a.code} ${a.name}${a.ifrs_line ? ` [${a.ifrs_line}]` : ''}`).join('\n');
  const parties = [...ctx.customers.slice(0, 300).map((c) => `customer ${c.id} ${c.name}`), ...ctx.vendors.slice(0, 300).map((v) => `vendor ${v.id} ${v.name}`)].join('\n');
  const lines = ctx.lines.map((l) => JSON.stringify({ line_id: l.id, date: l.date, amount: l.amount, narration: l.narration || '', reference: l.reference || '',
    counterparty: l.counterparty || '', bank: l.account, history: l.history || [] })).join('\n');
  const owned = (ctx.assets || []).slice(0, 60).map((a) => `${a.number} ${a.name} [${a.class}${a.class_name ? ` ${a.class_name}` : ''}]`
    + (a.carrying != null ? ` carrying ${naira(Number(a.carrying))}` : '')).join('\n');
  return `ACCOUNTS (code name [statement line])\n${accounts}\n\nCUSTOMERS AND VENDORS\n${parties || '(none)'}\n\nASSETS IN USE\n${owned || '(none)'}\n\nLINES\n${lines}`;
}

const FALLBACK = /(sundry|general expense|miscellaneous|other income|other sectors|other expenses|other operating)/i;

// The fixed asset accounts (1501 to 1527), and for some the words that, in what a business sells, mean it trades in them.
export const isAssetAccount = (code: string | null | undefined) => !!code && /^15(0[1-9]|1\d|2[0-7])$/.test(code);
const TRADES_IN: Record<string, RegExp> = {
  '1511': /\b(cars?|vehicles?|motors?|auto|automobiles?|tokunbo)\b/i,
  '1512': /\b(buses|bus|trucks?|lorr(y|ies)|tippers?|vehicles?)\b/i,
  '1514': /\b(office equipment|printers?|photocopiers?)\b/i,
  '1517': /\b(computers?|laptops?|phones?|tablets?|electronics?|gadgets?)\b/i,
  '1519': /\b(furniture|chairs?|tables?|beds?|sofas?)\b/i,
  '1513': /\b(tools?|generators?|equipment|machines?|machinery)\b/i,
  '1506': /\b(heavy equipment|excavators?|cranes?|tractors?)\b/i,
  '1515': /\b(medical equipment|hospital equipment)\b/i,
};
// Whether the business sells what this asset account holds: then a purchase may be stock.
export function tradesIn(trade: Trade | null | undefined, code: string) {
  const re = TRADES_IN[code];
  if (!re || !trade || trade.sells === 'services') return false;
  return re.test([trade.category, trade.activity, ...(Array.isArray(trade.examples) ? trade.examples : [])].filter(Boolean).join(' '));
}

// The other accounts the model offered: only real codes from the list, none twice, never the guess itself, at most four.
export function alternativesOf(raw: unknown, codes: Map<string, Account>, guess: string | null): Alt[] {
  const out: Alt[] = [];
  const seen = new Set<string>(guess ? [guess] : []);
  for (const a of Array.isArray(raw) ? raw : []) {
    const code = String((a as any)?.account_code ?? a ?? '').trim();
    if (!code || seen.has(code) || !codes.has(code)) continue;
    seen.add(code);
    out.push({ account_code: code, why: String((a as any)?.why || '').trim().slice(0, 120) });
    if (out.length === 4) break;
  }
  return out;
}

// Code, not the model, has the last word on confidence.
export function calibrate(ctx: Ctx, raw: any[]): Answer[] {
  const codes = new Map(ctx.accounts.map((a) => [a.code, a]));
  const lines = new Map(ctx.lines.map((l) => [l.id, l]));
  const parties = new Map<string, 'customer' | 'vendor'>([...ctx.customers.map((c) => [c.id, 'customer'] as const), ...ctx.vendors.map((v) => [v.id, 'vendor'] as const)]);
  const out: Answer[] = [];
  for (const r of raw || []) {
    const line = lines.get(String(r?.line_id));
    if (!line) continue;
    let code: string | null = r.account_code ? String(r.account_code).trim() : null;
    let conf = Math.min(Math.max(Number(r.confidence) || 0, 0), 1);
    const notes: string[] = [];
    const acct = code ? codes.get(code) : undefined;
    if (code && !acct) { notes.push('account not in the chart'); code = null; conf = Math.min(conf, 0.3); }
    const inflow = Number(line.amount) > 0;
    const first = code?.[0];
    if (acct && FALLBACK.test(acct.name)) { conf = Math.min(conf, 0.5); notes.push('fallback account'); }
    // Direction sanity (CLS-04, AR-07).
    if (code && inflow && first === '4' && !ctx.org.cash_sales_without_invoices) { conf = Math.min(conf, 0.5); notes.push('money in is not revenue without a sale'); }
    if (code && !inflow && first === '4') { conf = Math.min(conf, 0.4); notes.push('money out to an income account'); }
    if (code && inflow && /^[567]/.test(code)) { conf = Math.min(conf, 0.7); notes.push('money in to an expense account (a refund?)'); }
    if (code && /^3/.test(code)) { conf = Math.min(conf, 0.6); notes.push('equity needs the owner to confirm'); }
    if (r.kind === 'private' || r.kind === 'owner' || r.kind === 'unknown') conf = Math.min(conf, 0.6);
    // Fixed assets: below the capitalisation threshold it is an expense; a business that sells such things may be buying stock;
    // money in for an asset of a kind the register does not hold needs a person.
    if (isAssetAccount(code)) {
      const cap = Number(ctx.org.capitalisation_threshold) || 0;
      if (!inflow && cap > 0 && Math.abs(Number(line.amount)) < cap) { conf = Math.min(conf, 0.6); notes.push('below the capitalisation threshold'); }
      if (!inflow && tradesIn(ctx.org.trade, code!)) { conf = Math.min(conf, 0.6); notes.push('the business sells such things: stock or an asset?'); }
      if (inflow && !(ctx.assets || []).some((a) => a.class === code)) { conf = Math.min(conf, 0.5); notes.push('no asset of this kind in the register'); }
    }
    // The model asking the owner something means it wants a person to decide: it never posts on its own then.
    if (r.question && String(r.question).trim()) conf = Math.min(conf, 0.79);
    // Following the payee's own history is the strongest evidence there is.
    const top = line.history?.[0];
    if (code && top && top.code !== code && top.n >= 3) { conf = Math.min(conf, 0.75); notes.push(`this payee usually goes to ${top.code}`); }
    let partyType: 'customer' | 'vendor' | null = null, partyId: string | null = null;
    if (r.party_id && parties.has(String(r.party_id))) { partyId = String(r.party_id); partyType = parties.get(partyId)!; }
    const alternatives = alternativesOf(r.alternatives, codes, code);
    // No usable guess but a usable alternative: the first alternative becomes the guess, as a weak one.
    if (!code && alternatives.length) { code = alternatives.shift()!.account_code; conf = Math.min(conf, 0.3); }
    const question = conf < ctx.org.threshold
      ? (r.question && String(r.question).trim()) || (inflow ? 'What was this money for?' : 'What was this payment for?')
      : null;
    out.push({ line_id: line.id, account_code: code, confidence: Math.round(conf * 1000) / 1000, title: String(r.title || line.narration || '').slice(0, 120),
      rationale: [String(r.rationale || '').slice(0, 400), ...notes].filter(Boolean).join(' · '), question, party_type: partyType, party_id: partyId,
      kind: String(r.kind || 'unknown'), alternatives });
  }
  return out;
}
