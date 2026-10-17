// Atlas bookkeeper: the last stage of the bank-line pipeline (CLS-03). Matching, the statutory registry, learned rules and
// the payee registry have already run in the database; what is left comes here. The model proposes an account and a
// confidence; code then calibrates the confidence (SUS-01, SUS-02, CLS-04) and the database decides: at or above the
// business's threshold (never below 80%) it posts, below it the line waits in suspense with one question.
import { S } from './gemini.ts';

export type Line = { id: string; date: string; amount: number; narration?: string; reference?: string; counterparty?: string; account?: string;
  account_kind?: string; history?: { code: string; n: number }[] | null };
export type Account = { code: string; name: string; category?: string; ifrs_line?: string };
export type Ctx = { org: { name: string; industry?: string; vat_registered?: boolean; cash_sales_without_invoices?: boolean; threshold: number };
  lines: Line[]; accounts: Account[]; customers: { id: string; name: string }[]; vendors: { id: string; name: string }[]; directors: string[] };
export type Answer = { line_id: string; account_code: string | null; confidence: number; title: string; rationale: string; question: string | null;
  party_type: 'customer' | 'vendor' | null; party_id: string | null; kind: string };

export const SCHEMA = {
  type: 'OBJECT',
  properties: {
    results: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: {
          line_id: S.str,
          account_code: { type: 'STRING', nullable: true, description: 'One code from the accounts list, or null when you cannot tell' },
          confidence: { type: 'NUMBER', description: 'Probability from 0 to 1 that this account is right' },
          title: { type: 'STRING', description: 'Short memo for the journal, e.g. "Diesel for generator"' },
          rationale: { type: 'STRING', description: 'One sentence: why this account' },
          question: { type: 'STRING', nullable: true, description: 'One plain question for the owner when you are not sure' },
          party_type: { type: 'STRING', nullable: true, enum: ['customer', 'vendor'] },
          party_id: { type: 'STRING', nullable: true },
          kind: { type: 'STRING', enum: ['expense', 'asset', 'income', 'refund', 'owner', 'loan', 'statutory', 'transfer', 'private', 'unknown'] },
        },
        required: ['line_id', 'account_code', 'confidence', 'title', 'rationale', 'kind'],
      },
    },
  },
  required: ['results'],
};

export function systemPrompt(ctx: Ctx) {
  const o = ctx.org;
  return `You are Atlas, the bookkeeper for ${o.name}, a Nigerian business${o.industry ? ` (${o.industry})` : ''}. You keep the books under IFRS.
You receive bank and wallet lines that nothing else could explain. For each line choose the one account it should post to (the other side is the bank),
or say you cannot tell.

Rules you must follow:
1. Use only codes from the accounts list. Never invent a code. Positive amounts are money in; negative amounts are money out.
2. Money in is never revenue unless the business sells for cash without invoices (this business: ${o.cash_sales_without_invoices ? 'yes, it does' : 'no, it does not'}).
   Otherwise money in from an unknown sender gets account_code null and a question such as "Who sent ₦250,000 on 3 Oct and what was it for?".
3. Money in from an owner or director (${ctx.directors.join(', ') || 'none listed'}) is never income: account_code null, kind "owner", and ask whether it is
   capital for shares, a loan to the business, or a deposit for shares.
4. Money out is an expense only when the narration or the payee's history makes the nature clear. Payments to individuals with no history: null and ask.
5. Payments at supermarkets, schools, hospitals, for personal travel or to family members may be private: kind "private", confidence at most 0.6,
   and ask whether it was for the business.
6. VAT, withholding tax, PAYE and pension never come from a bank line: do not pick tax or control accounts (they are not in the list anyway).
7. Equipment, vehicles, computers, furniture or building work above about ₦250,000 are assets, not expenses (PPE accounts), unless clearly a repair.
8. Bank charges, SMS alerts, card maintenance, stamp duty and the electronic money transfer levy go to bank charges.
9. Sundry, general, miscellaneous or "other" accounts are not a hiding place: if that is your best answer, confidence at most 0.5.
10. history lists the accounts this payee was posted to before, most frequent first. Follow it unless the narration clearly says otherwise.
11. If the line names a customer or vendor from the lists, give party_type and party_id (the id from the list).

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
  return `ACCOUNTS (code name [statement line])\n${accounts}\n\nCUSTOMERS AND VENDORS\n${parties || '(none)'}\n\nLINES\n${lines}`;
}

const FALLBACK = /(sundry|general expense|miscellaneous|other income|other sectors|other expenses|other operating)/i;

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
    // Following the payee's own history is the strongest evidence there is.
    const top = line.history?.[0];
    if (code && top && top.code !== code && top.n >= 3) { conf = Math.min(conf, 0.75); notes.push(`this payee usually goes to ${top.code}`); }
    let partyType: 'customer' | 'vendor' | null = null, partyId: string | null = null;
    if (r.party_id && parties.has(String(r.party_id))) { partyId = String(r.party_id); partyType = parties.get(partyId)!; }
    const question = conf < ctx.org.threshold
      ? (r.question && String(r.question).trim()) || (inflow ? 'What was this money for?' : 'What was this payment for?')
      : null;
    out.push({ line_id: line.id, account_code: code, confidence: Math.round(conf * 1000) / 1000, title: String(r.title || line.narration || '').slice(0, 120),
      rationale: [String(r.rationale || '').slice(0, 400), ...notes].filter(Boolean).join(' · '), question, party_type: partyType, party_id: partyId,
      kind: String(r.kind || 'unknown') });
  }
  return out;
}
