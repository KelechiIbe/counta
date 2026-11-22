// More of Counta on WhatsApp and Siri: the books inbox, orders and deliveries, stock, purchase orders, credit notes, customers
// and products, approvals, tax returns and the daily report. Each tool checks what it can, then holds the action and reads
// it back; runMore carries it out after the person's yes (a tax return, after their approval PIN). Every step runs as the
// person through svc_chat_rpc, so the database's own rules decide. Money out is never done here.
import { type ChartAccount, forBankLine, searchAccounts } from './accounts.ts';
import { can, type Env, findCustomer, hold, pickByName, roundN, url } from './common.ts';
import { type Item, matchItem, naira, parseLines } from './words.ts';

type P = Record<string, unknown>;
const str = (description: string, e?: string[]): P => ({ type: 'STRING', description, ...(e ? { enum: e } : {}) });
const num = (description: string): P => ({ type: 'NUMBER', description });
const bool = (description: string): P => ({ type: 'BOOLEAN', description });
const obj = (properties: Record<string, P>, required: string[] = []): P => ({ type: 'OBJECT', properties, ...(required.length ? { required } : {}) });
const LINES = str('One line each, separated by semicolons: quantity, the product, and optionally "at" a price in naira. For example "5 Indomie carton at 9600; 2 Peak Milk carton".');

export const MORE_TOOLS = [
  { name: 'books_inbox', description: 'The questions waiting in the books inbox, numbered: each payment Atlas was not sure about, with its best guess and the other likely accounts, or the documents a payment could settle, and VAT questions about products.' },
  { name: 'answer_books_questions', description: 'Prepare answers to books inbox questions, by their numbers from books_inbox, to post on a yes. Several at once, like "1 yes, 2 is rent".',
    parameters: obj({ answers: { type: 'ARRAY', description: 'One per question answered', items: obj({
      n: num('The question\'s number from books_inbox'),
      answer: str('yes: take Atlas\'s guess (or the first document); document: one of the documents listed; account: the account they name; not_real: a duplicate or a reversed transfer; standard, zero or exempt: for a VAT question',
        ['yes', 'document', 'account', 'not_real', 'standard', 'zero', 'exempt']),
      account: str('With answer account: what the money was for, in their words ("rent", "diesel", "salary")'),
      document: num('With answer document: the document\'s number in that question\'s list'),
      party: str('The customer or supplier, when the money settles what a customer or supplier owes') }, ['n', 'answer']) } }, ['answers']) },
  { name: 'orders', description: 'Orders: those waiting to be confirmed, or all recent ones, with what is paid and where each delivery stands.',
    parameters: obj({ status: str('Which', ['to_confirm', 'all']), customer: str('A customer, if said') }) },
  { name: 'confirm_order', description: 'Prepare confirming an order waiting to be confirmed, by its number: it posts the sale, takes the stock and opens a delivery when the customer asked for one.',
    parameters: obj({ number: str('The order number') }, ['number']) },
  { name: 'cancel_order', description: 'Prepare cancelling an order, a quote or a sale still waiting for its transfer, with the reason.',
    parameters: obj({ number: str('The number'), reason: str('Why') }, ['number', 'reason']) },
  { name: 'deliveries', description: 'Deliveries: waiting to go, on the way, or all recent ones, with the address, driver and whether one waits for payment.',
    parameters: obj({ status: str('Which', ['waiting', 'on_the_way', 'all']) }) },
  { name: 'update_delivery', description: 'Prepare marking a delivery dispatched, delivered (with who received it) or failed, by its delivery number or its order or sale number.',
    parameters: obj({ number: str('Delivery number (DN-...) or the order or sale number'), status: str('What happened', ['dispatched', 'delivered', 'failed']),
      received_by: str('With delivered: the name of the person who received the goods') }, ['number', 'status']) },
  { name: 'send_document', description: 'Prepare sending an invoice, receipt, quote or order to its customer by WhatsApp or email: the link to view it, pay it and follow the order.',
    parameters: obj({ number: str('The document number'), channel: str('How', ['whatsapp', 'email']) }, ['number']) },
  { name: 'payment_link', description: 'The page where the customer pays an invoice or order by transfer, card or USSD, to share with them.',
    parameters: obj({ number: str('The invoice or order number') }, ['number']) },
  { name: 'stock_waiting', description: 'Stock on its way between branches waiting to be received, and stock counts waiting for approval.' },
  { name: 'move_stock', description: 'Prepare moving stock from one branch to another.',
    parameters: obj({ item: str('The product'), qty: num('How many selling units'), from: str('From which branch'), to: str('To which branch') }, ['item', 'qty', 'from', 'to']) },
  { name: 'receive_transfer', description: 'Prepare confirming that stock on its way has arrived at its branch, by its reference or the product.',
    parameters: obj({ ref: str('The transfer reference'), item: str('Or the product') }) },
  { name: 'decide_count', description: 'Prepare approving (which posts the differences) or rejecting (which asks for a recount) a stock count waiting for approval.',
    parameters: obj({ ref: str('The count reference'), approve: bool('true to approve, false to reject') }, ['approve']) },
  { name: 'purchase_order', description: 'Prepare a purchase order to a supplier already in Counta: quantities in the supplier\'s units (cartons, bags), at a price if said, else the last cost.',
    parameters: obj({ supplier: str('The supplier'), lines: LINES }, ['supplier', 'lines']) },
  { name: 'credit_note', description: 'Prepare a credit note on an invoice for an amount (a price reduction, a discount agreed after the sale, a service not delivered), with the reason. Nothing comes back into stock.',
    parameters: obj({ number: str('The invoice number'), amount: num('The amount in naira, VAT included'), reason: str('Why') }, ['number', 'amount', 'reason']) },
  { name: 'add_customer', description: 'Prepare adding a new customer.',
    parameters: obj({ name: str('Their name'), phone: str('Phone number'), email: str('Email address'), kind: str('A business or a person', ['business', 'individual']) }, ['name']) },
  { name: 'add_product', description: 'Prepare adding a new product: what it costs the business and what it sells for are both needed (per selling unit).',
    parameters: obj({ name: str('The product, as a shop would list it'), price: num('Selling price per unit, naira'), cost: num('What one unit costs the business, naira'),
      unit: str('The selling unit (piece, tin, bottle, pack, bag)'), category: str('Category'), barcode: str('Barcode digits, if known'),
      photo: str('When the product came from a photo they sent here: the photo reference Martina noted (wa-….jpg)') }, ['name']) },
  { name: 'approvals', description: 'Requests waiting for the person\'s approval: invoices past the discount limit, credit notes and returns, VAT exemptions, and payments.' },
  { name: 'decide_approval', description: 'Prepare approving or rejecting one of the requests from approvals, by its number. Rejecting needs a reason. Payments are approved in Counta.',
    parameters: obj({ n: num('Its number from approvals'), approve: bool('true to approve, false to reject'), reason: str('With a rejection: why') }, ['n', 'approve']) },
  { name: 'tax_returns', description: 'Tax returns ready to approve and where the sent ones stand: VAT by month, WHT to the NRS by month, companies income tax by year.' },
  { name: 'approve_tax_return', description: 'Prepare approving a tax return: Counta files it (VAT) or approves it (CIT) and sends it to TaxStreem Flux to file on Rev360. Needs the person\'s approval PIN.',
    parameters: obj({ tax: str('Which', ['vat', 'wht', 'cit']), period: str('The month as YYYY-MM for VAT and WHT, the year for CIT') }, ['tax', 'period']) },
  { name: 'daily_report', description: 'Send the person the daily report as a PDF here: sales, money in and out, orders and deliveries, stock, the books inbox, tax due and who did what.',
    parameters: obj({ day: str('today, yesterday, or a date as YYYY-MM-DD') }) },
];

// ------------------------------------------------------------------ helpers
const lagosToday = () => new Date(Date.now() + 3600_000).toISOString().slice(0, 10);
const addDays = (d: string, n: number) => new Date(Date.parse(d + 'T12:00:00Z') + n * 86400_000).toISOString().slice(0, 10);
const monthName = (ym: string) => new Date(ym.slice(0, 7) + '-01T12:00:00Z').toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' });
const pct = (c: unknown) => (Number.isFinite(Number(c)) ? `${Math.round(Number(c) * 100)}%` : undefined);
const same = (a: unknown, b: unknown) => String(a ?? '').trim().toLowerCase() === String(b ?? '').trim().toLowerCase();

// What a waiting request is about, in one line (as src/lib/approvals.ts approvalLine says it in the app).
const MONEY_KINDS = ['payout', 'payout_batch', 'refund'];
function approvalWords(a: any): string {
  const s = a.summary || {};
  switch (a.kind) {
    case 'invoice': return `an invoice to ${s.customer || 'a customer'} for ${naira(s.total)}${Number(s.discount) > 0 ? `, ${s.discount_pct}% off` : ''}${s.relief ? ', exempt from VAT' : ''}`;
    case 'credit_note': return `a credit note for ${s.customer || 'a customer'} of ${naira(s.total)}${s.reason ? ` (${s.reason})` : ''}`;
    case 'refund': return `a refund to ${s.customer || 'a customer'} of ${naira(s.amount)}`;
    case 'payout': return `a payment of ${naira(s.amount)} to ${s.account_name || 'an account'}`;
    case 'payout_batch': return `a bulk payment of ${s.rows} payments, ${naira(s.total)}`;
    case 'recurring': return `a recurring invoice to ${s.customer || 'a customer'}, ${s.frequency || ''}`.trim();
  }
  return String(a.kind || 'a request').replace(/_/g, ' ');
}

async function findDoc(e: Env, number: string, kinds?: string[]) {
  const r = await e.rpc('get_sales', { filter: { q: String(number || '').trim(), limit: 10 } });
  const rows: any[] = (r?.rows || []).filter((x: any) => same(x.number, number) && (!kinds || kinds.includes(x.doc_type)));
  return rows[0] || null;
}

// The account a person's words name for a bank line. Everyday words ("rent", "diesel") mean a cost when money went out and
// income when it came in; words for an advance, a loan, a deposit, an asset or the owner's own money mean the balance sheet.
export function accountFor(accounts: ChartAccount[], words: string, moneyIn: boolean): ChartAccount | null {
  const w = String(words || '').trim();
  if (!w) return null;
  const fit = searchAccounts(accounts, w, 5).filter((h) => (moneyIn ? !/^[567]/.test(h.code) : !/^4/.test(h.code)));
  if (!fit.length) return null;
  const balance = /\b(advance|prepaid|prepay|deposit|loan|asset|director|owner|capital|own account|refund|repay)\b/i.test(w);
  return fit.find((h) => (balance ? /^[123]/.test(h.code) : moneyIn ? /^4/.test(h.code) : /^[567]/.test(h.code))) || fit[0];
}

// Account names for codes, from the chart (read once per turn).
async function chartOf(e: Env, memo: { accounts?: ChartAccount[] }) {
  if (!memo.accounts) {
    const c = await e.rpc('get_chart');
    memo.accounts = forBankLine((c?.accounts || []) as ChartAccount[]);
  }
  return memo.accounts;
}

function questionKind(q: any): 'vat' | 'match' | 'account' | 'other' {
  if (q.kind === 'item_vat') return 'vat';
  if (q.source_type !== 'bank_line') return 'other';
  return q.proposal?.kind === 'invoice_match' || q.proposal?.kind === 'bill_match' ? 'match' : 'account';
}

function candidatesOf(q: any): any[] {
  const m = q.proposal || {};
  if (Array.isArray(m.candidates) && m.candidates.length) return m.candidates;
  return [{ kind: m.kind === 'invoice_match' ? 'sale' : 'bill', number: m.number, party_name: m.customer_name || m.vendor_name }];
}

function lineWords(q: any) {
  const l = q.line || {};
  const amt = Number(l.amount ?? q.amount ?? 0);
  const who = l.counterparty || String(l.narration || '').slice(0, 50);
  return `${naira(Math.abs(amt))} ${amt > 0 ? 'in from' : 'out to'} ${who || 'the bank'}${l.date ? ` on ${l.date}` : ''}`;
}

// ------------------------------------------------------------------ the tools
export function moreTools(e: Env): Record<string, (a: any) => Promise<unknown>> {
  const memo: { accounts?: ChartAccount[] } = {};
  return {
    books_inbox: async () => {
      const r = await e.rpc('get_books_inbox');
      const qs: any[] = r?.questions || [];
      const accounts = qs.some((q) => questionKind(q) === 'account') ? await chartOf(e, memo).catch(() => []) : [];
      const name = (code: string) => accounts.find((a) => a.code === code)?.name;
      return {
        waiting: qs.length, link: url(e, '/accounting/inbox'),
        questions: qs.slice(0, 10).map((q, i) => {
          const k = questionKind(q);
          return {
            n: i + 1, about: k === 'vat' ? (q.question || q.title) : k === 'other' ? (q.question || q.title) : lineWords(q), narration: q.line?.narration?.slice(0, 80),
            kind: k === 'vat' ? 'VAT of a product' : k === 'match' ? 'which document this payment settles' : k === 'account' ? 'which account' : 'answered in Counta',
            atlas_guess: k === 'account' ? (q.account_name || name(q.proposal?.account_code)) : k === 'vat' ? q.proposal?.treatment : undefined,
            sure: k === 'account' || k === 'vat' ? pct(q.confidence) : undefined,
            other_accounts: k === 'account' ? (Array.isArray(q.proposal?.alternatives) ? q.proposal.alternatives : []).map((a: any) => name(a?.account_code)).filter(Boolean).slice(0, 4) : undefined,
            documents: k === 'match' ? candidatesOf(q).slice(0, 5).map((c: any, j: number) => ({ n: j + 1, number: c.number, who: c.party_name, owed: roundN(c.due) })) : undefined,
          };
        }),
        more_in_counta: Math.max(0, qs.length - 10),
        also_waiting: { payments_to_confirm: r?.payments_to_confirm || 0, bills_to_approve: r?.bills_to_approve || 0, payouts_to_approve: r?.payouts_to_approve || 0 },
        note: 'Keep these numbers. They may answer several at once, like "1 yes, 2 is rent, 3 is not real".',
      };
    },

    answer_books_questions: async ({ answers }) => {
      if (!can(e, 'keep_books')) return { error: 'Their role does not answer books questions. Someone who keeps the books does.' };
      const list: any[] = Array.isArray(answers) ? answers.slice(0, 10) : [];
      if (!list.length) return { error: 'Say which question and the answer.' };
      const r = await e.rpc('get_books_inbox');
      const qs: any[] = r?.questions || [];
      const out: any[] = [], lines: string[] = [], needs: string[] = [];
      let customers: any[] | null = null, vendors: any[] | null = null;
      for (const a of list) {
        const n = Number(a?.n), q = qs[n - 1];
        if (!q) { needs.push(`There is no question ${a?.n}.`); continue; }
        const k = questionKind(q), ans = String(a?.answer || '');
        if (k === 'other') { needs.push(`Question ${n} is answered in Counta: ${url(e, '/accounting/inbox')}`); continue; }
        if (k === 'vat') {
          const t = ans === 'yes' ? q.proposal?.treatment : ans;
          if (!['standard', 'zero', 'exempt'].includes(String(t))) { needs.push(`Question ${n} is about VAT: standard, zero-rated or exempt?`); continue; }
          out.push({ proposal_id: q.id, fn: 'set_item_vat', item_id: q.source_id, treatment: t, reason: t === q.proposal?.treatment ? 'Confirmed the suggestion on WhatsApp' : 'Changed the suggestion on WhatsApp' });
          lines.push(`${n}. ${q.question || q.title}: ${t === 'standard' ? 'charge VAT' : t === 'zero' ? 'zero-rated' : 'exempt'}`);
          continue;
        }
        if (ans === 'not_real') {
          out.push({ proposal_id: q.id, fn: 'resolve_proposal', answer: { action: 'ignore', note: 'Not a real transaction (said on WhatsApp)' } });
          lines.push(`${n}. ${lineWords(q)}: not a real transaction, taken out`);
          continue;
        }
        if (k === 'match' && (ans === 'yes' || ans === 'document')) {
          const cands = candidatesOf(q), i = ans === 'yes' ? 0 : Number(a?.document) - 1;
          const c = cands[i];
          if (!c) { needs.push(`Question ${n}: which of the ${cands.length} documents?`); continue; }
          out.push({ proposal_id: q.id, fn: 'resolve_proposal', answer: { action: 'approve', candidate: i } });
          lines.push(`${n}. ${lineWords(q)}: settles ${c.number}${c.party_name ? ` (${c.party_name})` : ''}`);
          continue;
        }
        if (ans === 'yes') {
          const code = q.proposal?.account_code;
          if (!code) { needs.push(`Question ${n}: Atlas has no guess for this one. What was it for?`); continue; }
          const accounts = await chartOf(e, memo);
          if (/^(1101|1102|2101|2102)/.test(code)) { needs.push(`Question ${n}: which ${/^11/.test(code) ? 'customer' : 'supplier'} was it?`); continue; }
          out.push({ proposal_id: q.id, fn: 'resolve_proposal', answer: { action: 'approve', remember: true } });
          lines.push(`${n}. ${lineWords(q)}: ${q.account_name || accounts.find((x) => x.code === code)?.name || code}`);
          continue;
        }
        if (ans === 'account') {
          const accounts = await chartOf(e, memo);
          const words = String(a?.account || '').trim();
          const acct = accountFor(accounts, words, Number(q.line?.amount ?? 0) > 0);
          if (!acct) { needs.push(`Question ${n}: no account fits "${words}". Say it another way, or choose in Counta.`); continue; }
          let party: { type: string; id: string; name: string } | null = null;
          if (/^(1101|1102)/.test(acct.code)) {
            customers ??= ((await e.rpc('get_customers'))?.customers || []).filter((c: any) => !c.archived && !c.is_walk_in);
            const p = pickByName(customers as any[], String(a?.party || ''));
            if (!p.one) { needs.push(`Question ${n}: which customer${p.choose ? ` (${p.choose.join(', ')})` : ''}?`); continue; }
            party = { type: 'customer', id: (p.one as any).id, name: p.one.name };
          } else if (/^(2101|2102)/.test(acct.code)) {
            vendors ??= (await e.rpc('get_inventory'))?.vendors || [];
            const p = pickByName(vendors as any[], String(a?.party || ''));
            if (!p.one) { needs.push(`Question ${n}: which supplier${p.choose ? ` (${p.choose.join(', ')})` : ''}?`); continue; }
            party = { type: 'vendor', id: (p.one as any).id, name: p.one.name };
          }
          const sameAsGuess = acct.code === q.proposal?.account_code;
          out.push({ proposal_id: q.id, fn: 'resolve_proposal', answer: { action: sameAsGuess && !party ? 'approve' : 'change', account_code: acct.code,
            party_type: party?.type ?? null, party_id: party?.id ?? null, remember: true } });
          lines.push(`${n}. ${lineWords(q)}: ${acct.name}${party ? ` (${party.name})` : ''}`);
          continue;
        }
        needs.push(`Question ${n}: what should it be?`);
      }
      if (!out.length) return { need: needs.join(' ') || 'Say which question and the answer.' };
      const held = await hold(e, 'inbox', `Post ${out.length === 1 ? 'this answer' : `these ${out.length} answers`} in the books`, lines, null,
        'Counta remembers each payee for next time', { answers: out });
      return needs.length ? { ...held, also_tell_them: needs.join(' ') } : held;
    },

    orders: async ({ status, customer }) => {
      const filter: Record<string, unknown> = { doc_type: 'order', limit: 20 };
      if (status === 'to_confirm') filter.status = 'pending';
      if (customer) {
        const f = await findCustomer(e, String(customer));
        if (!('customer' in f)) return { found: 0, note: 'choose' in f ? `Several customers match: ${f.choose!.join(', ')}.` : `No customer called ${customer}.` };
        filter.customer_id = f.customer.id;
      }
      const [s, d] = await Promise.all([e.rpc('get_sales', { filter }), e.rpc('get_deliveries', { days: 30 }).catch(() => [])]);
      const dels: any[] = Array.isArray(d) ? d : [];
      const rows: any[] = (s?.rows || []).slice(0, 12);
      return { found: rows.length, link: url(e, '/sell/orders'), orders: rows.map((o) => {
        const dv = dels.find((x) => x.sale_id === o.id);
        return { number: o.number, customer: o.customer_name, date: o.issue_date, total: roundN(o.total), still_owed: roundN(o.balance),
          status: o.status === 'pending' ? 'waiting to be confirmed' : o.status,
          delivery: dv ? `${dv.number} ${dv.held ? 'waiting for payment' : dv.status}` : undefined };
      }) };
    },

    confirm_order: async ({ number }) => {
      if (!can(e, 'record_sales')) return { error: 'Their role does not confirm orders.' };
      const o = await findDoc(e, number, ['order']);
      if (!o) return { error: `No order ${number}.` };
      if (o.status !== 'pending') return { error: `${o.number} is ${o.status === 'cancelled' ? 'cancelled' : 'already confirmed'}.` };
      const full = await e.rpc('get_sale', { sale_id: o.id }).catch(() => null);
      const lines = (full?.lines || []).filter((l: any) => l.kind !== 'delivery').slice(0, 8).map((l: any) => `${Number(l.qty)} × ${l.description}`);
      return await hold(e, 'order_confirm', `Confirm order ${o.number} from ${o.customer_name}`, lines, Number(o.total),
        `Confirming posts the sale and takes the stock${full?.delivery_method === 'delivery' ? ', and opens a delivery' : ''}`, { sale_id: o.id, number: o.number });
    },

    cancel_order: async ({ number, reason }) => {
      if (!can(e, 'record_sales')) return { error: 'Their role does not cancel orders.' };
      if (!String(reason || '').trim()) return { need: 'Ask why it is being cancelled.' };
      const o = await findDoc(e, number, ['order', 'quote', 'receipt']);
      if (!o) return { error: `No order or quote ${number}.` };
      if (o.confirmed) return { error: `${o.number} is confirmed and in the books already. Void it in Counta: ${url(e, '/sell/sales')}` };
      if (['cancelled', 'converted', 'void', 'expired'].includes(o.status)) return { error: `${o.number} is ${o.status} already.` };
      return await hold(e, 'order_cancel', `Cancel ${o.number} for ${o.customer_name}`, [`Reason: ${String(reason).slice(0, 200)}`], Number(o.total),
        'Money already paid on it stays with the customer as credit, to use or refund', { sale_id: o.id, number: o.number, reason: String(reason).slice(0, 300) });
    },

    deliveries: async ({ status }) => {
      const d = await e.rpc('get_deliveries', { days: 14 });
      let list: any[] = Array.isArray(d) ? d : [];
      if (status === 'waiting') list = list.filter((x) => x.status === 'pending');
      else if (status === 'on_the_way') list = list.filter((x) => x.status === 'dispatched');
      return { found: list.length, link: url(e, '/sell/orders'), deliveries: list.slice(0, 12).map((x) => ({ number: x.number, for: `${x.sale_number} · ${x.customer_name}`,
        address: x.address, status: x.held ? 'waiting for payment' : x.status, driver: x.driver_name || x.vehicle_name || undefined, scheduled: x.scheduled_for || undefined,
        delivered_to: x.received_by || undefined, items: (x.lines || []).slice(0, 4).map((l: any) => `${Number(l.qty)} ${l.description}`).join(', ') })) };
    },

    update_delivery: async ({ number, status, received_by }) => {
      if (!can(e, 'record_sales')) return { error: 'Their role does not update deliveries.' };
      const d = await e.rpc('get_deliveries', { days: 60 });
      const list: any[] = Array.isArray(d) ? d : [];
      const dv = list.find((x) => same(x.number, number)) || list.find((x) => same(x.sale_number, number));
      if (!dv) return { error: `No delivery for ${number}.` };
      if (['delivered', 'cancelled'].includes(dv.status)) return { error: `${dv.number} is already ${dv.status}.` };
      if (status === 'dispatched' && dv.held) return { error: `${dv.number} waits for payment: goods leave once ${dv.sale_number} is paid. A manager can agree payment on delivery in Counta.` };
      if (status === 'delivered' && !String(received_by || '').trim()) return { need: 'Ask the name of the person who received the goods.' };
      const what = status === 'dispatched' ? 'on its way' : status === 'delivered' ? `delivered, received by ${String(received_by).trim()}` : 'failed';
      return await hold(e, 'delivery', `Mark ${dv.number} (${dv.sale_number}, ${dv.customer_name}) ${what}`, [], null, '',
        { delivery_id: dv.id, number: dv.number, status, received_by: String(received_by || '').trim() || null });
    },

    send_document: async ({ number, channel }) => {
      if (!can(e, 'record_sales')) return { error: 'Their role does not send documents.' };
      const s = await findDoc(e, number);
      if (!s) return { error: `No document ${number}.` };
      const full = await e.rpc('get_sale', { sale_id: s.id });
      const via = channel === 'email' ? 'email' : channel === 'whatsapp' ? 'whatsapp' : full?.customer_phone ? 'whatsapp' : 'email';
      const to = via === 'whatsapp' ? full?.customer_phone : full?.customer_email;
      if (!to) return { error: `${s.customer_name || 'The customer'} has no ${via === 'whatsapp' ? 'phone number' : 'email address'} on ${s.number}. Add it in Counta.` };
      return await hold(e, 'send_doc', `Send ${s.number} to ${s.customer_name} by ${via === 'whatsapp' ? 'WhatsApp' : 'email'}`, [], null, `To ${to}`,
        { sale_id: s.id, number: s.number, channel: via, to, customer: s.customer_name });
    },

    payment_link: async ({ number }) => {
      const s = await findDoc(e, number, ['invoice', 'order', 'receipt']);
      if (!s) return { error: `No invoice or order ${number}.` };
      const full = await e.rpc('get_sale', { sale_id: s.id });
      if (!full?.public_token) return { error: `${s.number} has no page yet. Issue it first.` };
      return { link: url(e, `/p/${full.public_token}`), number: s.number, customer: s.customer_name, still_owed: roundN(s.balance),
        note: Number(s.balance) > 0 ? 'The customer pays there by transfer, card or USSD; Counta settles it when the money arrives.' : 'It is paid in full.' };
    },

    stock_waiting: async () => {
      const r = await e.rpc('stock_waiting');
      return { transfers: (r?.transfers || []).slice(0, 10), counts: (r?.counts || []).slice(0, 10), links: { counts: url(e, '/inventory/counts'), branches: url(e, '/inventory/locations') } };
    },

    move_stock: async ({ item, qty, from, to }) => {
      if (!can(e, 'transfer_stock')) return { error: 'Their role does not move stock between branches.' };
      const inv = await e.rpc('get_inventory');
      const it = matchItem(String(item || ''), inv?.items || []) as any;
      if (!it) return { error: `No product called ${item}.` };
      const locs: any[] = inv?.locations || [];
      if (locs.length < 2) return { error: `The business has one branch${locs[0] ? ` (${locs[0].name})` : ''}, so there is nowhere to move stock to. Branches are added in Counta: ${url(e, '/inventory/locations')}` };
      const f = pickByName(locs, String(from || '')), t = pickByName(locs, String(to || ''));
      if (!f.one || !t.one) return { need: `Ask which branches. They are: ${locs.map((l) => l.name).join(', ')}.` };
      if ((f.one as any).id === (t.one as any).id) return { error: 'The two branches are the same.' };
      const q = Number(qty);
      if (!(q > 0)) return { need: 'Ask how many.' };
      const have = Number(it.qty?.[(f.one as any).id] || 0);
      if (have < q) return { error: `${f.one.name} has ${have} ${it.selling_unit || ''} of ${it.name}.`.replace(/\s+/g, ' ') };
      return await hold(e, 'transfer', `Move ${q} ${it.selling_unit || ''} of ${it.name} from ${f.one.name} to ${t.one.name}`.replace(/\s+/g, ' '), [], null,
        `It shows at ${t.one.name} as on its way until someone there receives it`,
        { item_id: it.id, from: (f.one as any).id, to: (t.one as any).id, qty: q, client_uuid: crypto.randomUUID(), item: it.name });
    },

    receive_transfer: async ({ ref, item }) => {
      if (!can(e, 'receive_stock') && !can(e, 'transfer_stock')) return { error: 'Their role does not receive stock.' };
      const r = await e.rpc('stock_waiting');
      const list: any[] = r?.transfers || [];
      const hits = list.filter((t) => (ref && same(t.ref, ref)) || (!ref && item && String(t.item).toLowerCase().includes(String(item).toLowerCase())));
      if (!hits.length) return { error: list.length ? `None matches. On the way: ${list.slice(0, 6).map((t) => `${t.ref} (${t.qty} ${t.item} to ${t.to})`).join('; ')}.` : 'Nothing is on its way.' };
      if (hits.length > 1) return { need: `Ask which: ${hits.slice(0, 6).map((t) => `${t.ref} (${t.qty} ${t.item} to ${t.to})`).join('; ')}.` };
      const t = hits[0];
      return await hold(e, 'transfer_receive', `Receive ${t.ref} at ${t.to}: ${t.qty} ${t.unit || ''} of ${t.item} from ${t.from}`.replace(/\s+/g, ' '), [], null,
        'Confirm only once the goods are there', { transfer_id: t.id, ref: t.ref });
    },

    decide_count: async ({ ref, approve }) => {
      if (!can(e, 'approve_adjustments')) return { error: 'Their role does not approve stock counts.' };
      const r = await e.rpc('stock_waiting');
      const list: any[] = r?.counts || [];
      const c = ref ? list.find((x) => same(x.ref, ref)) : list.length === 1 ? list[0] : null;
      if (!c) return list.length ? { need: `Ask which count: ${list.map((x) => `${x.ref} at ${x.location}${x.area ? `, ${x.area}` : ''}`).join('; ')}.` } : { error: 'No count waits for approval.' };
      return await hold(e, 'count', `${approve ? 'Approve' : 'Reject'} count ${c.ref} at ${c.location}${c.area ? `, ${c.area}` : ''}`, [], null,
        approve ? 'Approving posts the differences to the books' : 'Rejecting asks for a recount', { session_id: c.id, ref: c.ref, approve: Boolean(approve) },
      ).then((h) => ({ ...h, review: url(e, '/inventory/counts') }));
    },

    purchase_order: async ({ supplier, lines }) => {
      if (!can(e, 'approve_pos')) return { error: 'Their role does not raise purchase orders.' };
      const inv = await e.rpc('get_inventory');
      const v = pickByName(inv?.vendors || [], String(supplier || ''));
      if (!v.one) return v.choose ? { need: `Ask which supplier: ${v.choose.join(', ')}.` } : { error: `No supplier called ${supplier}. Add them in Counta first: ${url(e, '/purchases/vendors')}` };
      const vendor: any = v.one;
      const items: any[] = inv?.items || [];
      const parsed = parseLines(String(lines || ''), items as Item[]);
      const unknown = parsed.filter((l) => !l.item_id);
      if (unknown.length) return { error: `Not in the product list: ${unknown.map((l) => l.name).join(', ')}. Add them in Counta first.` };
      const priced = parsed.map((l) => {
        const it = items.find((x) => x.id === l.item_id);
        const typed = /\bat\b|@/i.test(String(lines)) && l.unit_price != null && l.unit_price !== Number(it?.price) ? l.unit_price : null;
        const last = Number(it?.last_cost ?? it?.wac ?? 0) * Math.max(1, Number(it?.pack_size || 1));
        return { item_id: l.item_id!, name: it?.name || l.name, qty: l.qty, unit: it?.purchase_unit || 'unit', unit_cost: typed ?? (last > 0 ? Math.round(last * 100) / 100 : null) };
      });
      const noCost = priced.filter((l) => !(Number(l.unit_cost) > 0));
      if (noCost.length) return { need: `Ask the price per ${noCost[0].unit} of ${noCost.map((l) => l.name).join(', ')}.` };
      const total = Math.round(priced.reduce((s, l) => s + l.qty * Number(l.unit_cost), 0) * 100) / 100;
      return await hold(e, 'po', `Raise a purchase order to ${vendor.name}`, priced.map((l) => `${l.qty} ${l.unit} ${l.name} at ${naira(l.unit_cost)}`), total,
        'Approved and ready to send to the supplier', { vendor_id: vendor.id, vendor: vendor.name, phone: vendor.phone || null, channel: vendor.channel || null,
          lines: priced.map((l) => ({ item_id: l.item_id, qty: l.qty, unit_cost: l.unit_cost })), words: priced.map((l) => `${l.qty} ${l.unit} ${l.name}`) });
    },

    credit_note: async ({ number, amount, reason }) => {
      if (!can(e, 'record_sales')) return { error: 'Their role does not raise credit notes.' };
      if (!String(reason || '').trim()) return { need: 'Ask the reason for the credit note.' };
      const s = await findDoc(e, number, ['invoice', 'receipt']);
      if (!s) return { error: `No invoice ${number}.` };
      const info = await e.rpc('sale_creditable', { sale_id: s.id });
      const pool = (info?.lines || []).reduce((t: number, l: any) => t + Math.max(0, Number(l.creditable) || 0), 0);
      const amt = Math.round(Number(amount) * 100) / 100;
      if (!(amt > 0)) return { need: 'Ask the amount.' };
      if (amt > pool + 0.004) return { error: `At most ${naira(pool)} can be credited on ${s.number}.` };
      const due = Number(info?.due ?? s.balance ?? 0);
      return await hold(e, 'credit', `Credit note on ${s.number} (${s.customer_name}) for ${naira(amt)}`, [`Reason: ${String(reason).slice(0, 200)}`], null,
        due > 0.004 ? `It comes off what ${s.customer_name} owes first${amt > due ? `; the extra ${naira(amt - due)} stays as their credit` : ''}` : `${s.customer_name} has paid, so it stays as their credit to use or refund in Counta`,
        { sale_id: s.id, number: s.number, amount: amt, reason: String(reason).slice(0, 300) });
    },

    add_customer: async ({ name, phone, email, kind }) => {
      if (!can(e, 'record_sales')) return { error: 'Their role does not add customers.' };
      const n = String(name || '').trim();
      if (!n) return { need: 'Ask the customer\'s name.' };
      const f = await findCustomer(e, n);
      if ('customer' in f && f.customer.name.toLowerCase() === n.toLowerCase()) return { error: `${f.customer.name} is already a customer.` };
      return await hold(e, 'customer', `Add ${n} as a customer`, [phone ? `Phone ${phone}` : '', email ? `Email ${email}` : '', kind === 'business' ? 'A business' : kind === 'individual' ? 'A person' : ''].filter(Boolean),
        null, '', { name: n, phone: phone || null, email: email || null, kind: kind === 'business' ? 'business' : kind === 'individual' ? 'individual' : null });
    },

    add_product: async ({ name, price, cost, unit, category, barcode, photo }) => {
      if (!can(e, 'add_items') && !can(e, 'edit_prices')) return { error: 'Their role does not add products. The owner can allow it in Settings.' };
      const n = String(name || '').trim();
      if (!n) return { need: 'Ask the product\'s name.' };
      if (!(Number(price) > 0)) return { need: `Ask what one ${unit || 'unit'} of ${n} sells for.` };
      if (!(Number(cost) >= 0) || cost == null || cost === '') return { need: `Ask what one ${unit || 'unit'} of ${n} costs the business.` };
      const inv = await e.rpc('get_inventory');
      if ((inv?.items || []).some((i: any) => i.name.toLowerCase() === n.toLowerCase())) return { error: `${n} is already in the product list.` };
      const pic = /^wa-[0-9a-f-]{36}\.(jpg|png|webp)$/.test(String(photo || '').trim()) ? `${e.ctx.org_id}/${String(photo).trim()}` : null;
      return await hold(e, 'product', `Add ${n}`, [`Sells at ${naira(Number(price))} a ${unit || 'piece'}`, `Costs ${naira(Number(cost))}`, category ? `Category ${category}` : '', barcode ? `Barcode ${barcode}` : '',
        pic ? 'With the photo you sent as its picture' : ''].filter(Boolean),
        null, 'Its stock starts at nothing; receive stock in Counta', { name: n, price: Number(price), cost: Number(cost), unit: String(unit || 'piece').slice(0, 20),
          category: category ? String(category).slice(0, 40) : null, barcode: barcode ? String(barcode).replace(/\D/g, '').slice(0, 14) || null : null, photo: pic });
    },

    approvals: async () => {
      const r = await e.rpc('approvals_list');
      const items: any[] = (r?.items || []).filter((a: any) => a.status === 'pending');
      return { waiting: items.length, link: url(e, '/approvals'), requests: items.slice(0, 10).map((a, i) => ({ n: i + 1, what: approvalWords(a),
        asked_by: a.requested_by_name, why_it_waits: a.reasons, they_can_decide: Boolean(a.can_decide),
        money_out: MONEY_KINDS.includes(a.kind) || Boolean(a.payout_id || a.batch_id) || undefined })) };
    },

    decide_approval: async ({ n, approve, reason }) => {
      const r = await e.rpc('approvals_list');
      const items: any[] = (r?.items || []).filter((a: any) => a.status === 'pending');
      const a = items[Number(n) - 1];
      if (!a) return { error: `There is no request ${n}.` };
      if (MONEY_KINDS.includes(a.kind) || a.payout_id || a.batch_id) return { link: url(e, '/approvals'), note: 'Money out is approved in Counta. Give the link.' };
      if (!a.can_decide) return { error: a.approver === 'director' ? 'This one waits for the director, by their own link.' : 'Their role does not decide this one; the owner or an admin does.' };
      if (!approve && !String(reason || '').trim()) return { need: 'Ask why it is rejected; the person who asked sees the reason.' };
      const what = approvalWords(a);
      return await hold(e, 'approval', `${approve ? 'Approve' : 'Reject'} ${what}, asked by ${a.requested_by_name || 'someone'}`, !approve ? [`Reason: ${String(reason).slice(0, 200)}`] : [], null,
        approve ? 'It goes through as the person who asked' : '', { approval_id: a.id, approve: Boolean(approve), note: reason ? String(reason).slice(0, 300) : null, what });
    },

    tax_returns: async () => {
      const out: Record<string, unknown> = { link: url(e, '/tax') };
      const flux = await e.rpc('get_flux_tax').catch(() => null);
      const sent = (tax: string, period: string) => (flux?.returns || []).find((x: any) => x.tax === tax && String(x.period).slice(0, 7) === period.slice(0, 7));
      try {
        const v = await e.rpc('vat_position');
        out.vat = (v?.months || []).filter((m: any) => m.ended).slice(0, 4).map((m: any) => {
          const f = sent('vat', String(m.period));
          return { month: String(m.period).slice(0, 7), output_vat: roundN(m.output), input_vat: roundN(m.input), payable: roundN(m.payable), due: m.due_date,
            state: !m.filed ? 'ready to approve' : f ? `with Flux: ${String(f.status).replace(/_/g, ' ')}` : 'filed in Counta, not sent to Flux yet', paid: m.status === 'paid' || undefined };
        });
      } catch (x) { out.vat = (x as Error).message; }
      try {
        const y = await e.rpc('cit_years');
        out.cit = (y?.years || []).filter((c: any) => c.ended).slice(0, 2).map((c: any) => ({ year: c.year, status: c.status, flux: c.flux_status || undefined,
          tax: roundN(c.total_tax), payable: roundN(c.payable), due: c.due, problems_to_fix: c.blocks || undefined }));
      } catch (x) { out.cit = (x as Error).message; }
      const wht: any[] = [];
      for (const back of [1, 2]) {
        const d = new Date(lagosToday() + 'T12:00:00Z');
        const ym = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() - back, 1)).toISOString().slice(0, 7);
        try {
          const s = await e.rpc('wht_schedule', { period: `${ym}-01`, authority: 'NRS', kind: 'wht' });
          if ((s?.rows || []).length) { const f = sent('wht', ym); wht.push({ month: ym, deductions: s.rows.length, total: roundN(s.total), state: f ? `with Flux: ${String(f.status).replace(/_/g, ' ')}` : 'ready to approve' }); }
        } catch { /* no WHT view for this role */ }
      }
      out.wht_to_nrs = wht;
      return out;
    },

    approve_tax_return: async ({ tax, period }) => {
      if (!can(e, 'file_tax')) return { error: 'Their role does not approve tax returns. The owner can allow it (File tax) in Settings.' };
      const t = String(tax || '');
      if (t === 'vat' || t === 'wht') {
        const ym = String(period || '').slice(0, 7);
        if (!/^\d{4}-(0[1-9]|1[0-2])$/.test(ym)) return { need: 'Ask which month.' };
        if (t === 'vat') {
          const v = await e.rpc('vat_position');
          const m = (v?.months || []).find((x: any) => String(x.period).slice(0, 7) === ym);
          if (!m) return { error: `Counta has no VAT for ${monthName(ym)}.` };
          if (!m.ended) return { error: `${monthName(ym)} has not ended yet.` };
          const payable = Number(m.payable || 0);
          return await hold(e, 'tax_return', `Approve the VAT return for ${monthName(ym)}`,
            [`Output VAT ${naira(m.output)}`, `Input VAT ${naira(m.input)}`, payable > 0 ? `${naira(payable)} to pay by ${m.due_date}` : `Nothing to pay${Number(m.credit_cf) > 0 ? `; ${naira(m.credit_cf)} carried forward` : ''}`],
            null, m.filed ? 'It is filed in Counta; approving sends it to TaxStreem Flux to file on Rev360' : 'Approving files it in Counta and sends it to TaxStreem Flux to file on Rev360',
            { tax: 'vat', period: ym, file: !m.filed, payable }, true);
        }
        const s = await e.rpc('wht_schedule', { period: `${ym}-01`, authority: 'NRS', kind: 'wht' });
        if (!(s?.rows || []).length) return { error: `No WHT was deducted for the NRS in ${monthName(ym)}.` };
        const blocks = (s.checks || []).filter((c: any) => c.severity === 'block');
        if (blocks.length) return { error: `Fix these in Counta first: ${blocks.map((c: any) => c.text).join(' ')} ${url(e, '/tax/wht')}` };
        return await hold(e, 'tax_return', `Approve the WHT schedule to the NRS for ${monthName(ym)}`, [`${s.rows.length} deduction${s.rows.length === 1 ? '' : 's'}`, `${naira(s.total)} withheld`],
          null, 'Approving sends it to TaxStreem Flux to file on Rev360', { tax: 'wht', period: ym, total: Number(s.total) }, true);
      }
      if (t === 'cit') {
        const year = Number(String(period || '').slice(0, 4));
        const y = await e.rpc('cit_years');
        const c = (y?.years || []).find((x: any) => Number(x.year) === year);
        if (!c) return { error: `Counta has no ${year} companies income tax year.` };
        if (!c.ended) return { error: `The ${year} accounting year has not ended.` };
        if (Number(c.blocks) > 0) return { error: `The ${year} return has ${c.blocks} problem${c.blocks === 1 ? '' : 's'} to fix first: ${url(e, '/tax/cit')}` };
        if (!['draft', 'approved'].includes(String(c.status))) return { error: `The ${year} return is ${String(c.status).replace(/_/g, ' ')}.` };
        return await hold(e, 'tax_return', `Approve the ${year} companies income tax return`,
          [`Profit before tax ${naira(c.profit_before_tax)}`, `Tax ${naira(c.total_tax)}`, Number(c.payable) > 0 ? `${naira(c.payable)} to pay by ${c.due}` : 'Nothing to pay'],
          null, c.status === 'draft' ? 'Approving fixes the return and sends it to TaxStreem Flux to file on Rev360' : 'It is approved; this sends it to TaxStreem Flux',
          { tax: 'cit', year, approve: c.status === 'draft' }, true);
      }
      return { error: 'VAT, WHT or companies income tax? Personal income tax is approved in Counta.' };
    },

    daily_report: async ({ day }) => {
      const d = String(day || 'today').toLowerCase();
      const when = d === 'yesterday' ? addDays(lagosToday(), -1) : /^\d{4}-\d{2}-\d{2}$/.test(d) ? d : lagosToday();
      if (e.ctx.channel === 'siri') return { error: 'The report is a PDF: ask on WhatsApp, or open it in Counta.' };
      const id = await e.svc('svc_daily_report_ask', { p_link: e.ctx.link_id, p_day: when });
      const r = e.call ? await e.call('messaging', { action: 'daily_report', id }) : null;
      const res = r?.result || r;
      if (res?.status === 'sent') return { sent: true, day: when, note: 'The PDF is in this chat. Say so in one line; do not repeat its figures unless asked.' };
      if (res?.status === 'empty') return { sent: false, day: when, note: 'Nothing was recorded that day, so there is no report.' };
      return { sent: false, error: res?.error || 'The report could not be made just now.' };
    },
  };
}

// ------------------------------------------------------------------ carrying out what the person said yes to
export async function runMore(e: Env, kind: string, p: any, actionId: string): Promise<unknown> {
  const via = e.ctx.channel === 'siri' ? 'Siri' : 'WhatsApp';
  switch (kind) {
    case 'inbox': {
      let ok = 0;
      const failed: string[] = [];
      for (const a of (p.answers || []) as any[]) {
        try {
          if (a.fn === 'set_item_vat') await e.rpc('set_item_vat', { item_id: a.item_id, treatment: a.treatment, reason: a.reason });
          else await e.rpc('resolve_proposal', { proposal_id: a.proposal_id, answer: a.answer });
          ok++;
        } catch (x) { failed.push((x as Error).message.slice(0, 160)); }
      }
      return { done: ok > 0, summary: `${ok} answer${ok === 1 ? '' : 's'} posted in the books.${failed.length ? ` ${failed.length} could not be posted: ${failed.join(' ')}` : ''}` };
    }
    case 'order_confirm': {
      const r = await e.rpc('confirm_order', { sale_id: p.sale_id });
      return { done: true, number: p.number, summary: `${p.number} is confirmed and posted${r?.delivery_method === 'delivery' ? '; its delivery is waiting to go' : ''}.` };
    }
    case 'order_cancel': {
      await e.rpc('cancel_order', { sale_id: p.sale_id, reason: p.reason });
      return { done: true, number: p.number, summary: `${p.number} is cancelled.` };
    }
    case 'delivery': {
      await e.rpc('save_delivery', { delivery: { id: p.delivery_id, status: p.status, ...(p.received_by ? { received_by: p.received_by } : {}) } });
      return { done: true, number: p.number, summary: `${p.number} is marked ${p.status === 'dispatched' ? 'on its way' : p.status}.` };
    }
    case 'send_doc': {
      await e.rpc('send_document', { sale_id: p.sale_id, channel: p.channel, to: p.to });
      return { done: true, number: p.number, summary: `${p.number} is on its way to ${p.customer} by ${p.channel === 'whatsapp' ? 'WhatsApp' : 'email'}.` };
    }
    case 'transfer': {
      const r = await e.rpc('create_transfer', { item_id: p.item_id, from: p.from, to: p.to, qty: p.qty, client_uuid: p.client_uuid });
      return { done: true, number: r?.ref, summary: `${r?.ref ? `${r.ref}: ` : ''}${p.qty} of ${p.item} is on its way. Whoever receives it at the other branch confirms it in Counta or here.` };
    }
    case 'transfer_receive': {
      const ref = await e.rpc('receive_transfer', { transfer_id: p.transfer_id });
      return { done: true, number: p.ref, summary: `${p.ref} is received${typeof ref === 'string' && ref ? ` (${ref})` : ''}.` };
    }
    case 'count': {
      if (p.approve) { const r = await e.rpc('approve_count', { session_id: p.session_id }); return { done: true, number: p.ref, summary: `Count ${p.ref} is approved${r?.net_value != null ? `; the differences come to ${naira(r.net_value)}` : ''}.` }; }
      await e.rpc('reject_count', { session_id: p.session_id });
      return { done: true, number: p.ref, summary: `Count ${p.ref} is rejected; the counter is asked to count again.` };
    }
    case 'po': {
      const r = await e.rpc('save_po', { vendor_id: p.vendor_id, lines: p.lines, send: true, sent_via: p.channel || 'whatsapp', note: `Raised by Martina on ${via} on a yes` });
      const text = `Purchase order ${r?.ref || ''} from ${e.ctx.business}: ${(p.words || []).join('; ')}. Please confirm the delivery date.`;
      const phone = String(p.phone || '').replace(/\D/g, '').replace(/^0(?=\d{10}$)/, '234');
      const wa = /^\d{11,15}$/.test(phone) ? `https://wa.me/${phone}?text=${encodeURIComponent(text)}` : null;
      return { done: true, number: r?.ref, summary: `${r?.ref || 'The purchase order'} to ${p.vendor} is approved${r?.total != null ? `, ${naira(r.total)}` : ''}.`,
        send_it: wa ? `Tap to send it to ${p.vendor} on WhatsApp: ${wa}` : `Send it to ${p.vendor} from Counta: ${url(e, '/inventory/reorder')}` };
    }
    case 'credit': {
      const r = await e.rpc('credit_sale', { sale_id: p.sale_id, credit: { reason: p.reason, amount: p.amount, refund: {} } });
      const waiting = r?.pending_approval || r?.approval?.status === 'pending' || (Array.isArray(r?.approvals) && r.approvals.some((a: any) => a.status === 'pending'));
      if (waiting) return { done: true, summary: `The credit note on ${p.number} waits for the owner or an admin to approve it.` };
      return { done: true, number: r?.credit_note?.number, summary: `${r?.credit_note?.number || 'The credit note'} on ${p.number} for ${naira(p.amount)} is raised${Number(r?.store_credit) > 0 ? `; ${naira(r.store_credit)} is kept as credit` : ''}.` };
    }
    case 'customer': {
      await e.rpc('save_customer', { customer: { name: p.name, phone: p.phone, email: p.email, ...(p.kind ? { kind: p.kind } : {}) } });
      return { done: true, summary: `${p.name} is added as a customer.` };
    }
    case 'product': {
      await e.rpc('upsert_item', { item: { name: p.name, price: p.price, cost: p.cost, selling_unit: p.unit, purchase_unit: p.unit, pack_size: 1, category: p.category,
        barcode: p.barcode, item_type: 'merchandise' }, photo: p.photo || null });
      return { done: true, summary: `${p.name} is in the product list at ${naira(p.price)}. Receive its stock in Counta.` };
    }
    case 'approval': {
      const r = await e.rpc('approval_decide', { approval_id: p.approval_id, approve: p.approve, note: p.note });
      return { done: true, summary: `${p.approve ? 'Approved' : 'Rejected'}: ${p.what}.${r?.status === 'approved_not_done' || r?.error ? ` It could not go through: ${r?.error || 'see Counta'}.` : ''}` };
    }
    case 'tax_return': {
      const who = `Approved on ${via} by ${e.ctx.first_name} with their approval PIN`;
      const flux = (r: any) => !r ? 'Counta could not reach the filing service just now; send it from Counta.'
        : r.ok ? `It is with TaxStreem Flux${r.flux_ref ? ` (reference ${r.flux_ref})` : ''}, which files it on Rev360. Counta tells you the payment reference when it comes.`
        : r.reason === 'not_configured' ? `Flux is not connected yet: download the return in Counta and file it on Rev360 (${url(e, '/tax')}).`
        : `Flux did not take it: ${r.error || 'try again from Counta'}.`;
      if (p.tax === 'vat') {
        if (p.file) await e.rpc('file_vat_return', { period: `${p.period}-01`, filing: { refund_claim: 0, notes: who } });
        const r = e.call ? await e.call('tax-files', { action: 'flux_send', link_id: e.ctx.link_id, org_id: e.ctx.org_id, tax: 'vat', period: p.period }) : null;
        return { done: true, summary: `The VAT return for ${monthName(p.period)} is ${p.file ? 'filed in Counta' : 'approved'}. ${flux(r)}` };
      }
      if (p.tax === 'wht') {
        const r = e.call ? await e.call('tax-files', { action: 'flux_send', link_id: e.ctx.link_id, org_id: e.ctx.org_id, tax: 'wht', period: p.period }) : null;
        return { done: true, summary: `The WHT schedule for ${monthName(p.period)} is approved. ${flux(r)}` };
      }
      if (p.tax === 'cit') {
        if (p.approve) await e.rpc('approve_cit_year', { year: p.year });
        const r = e.call ? await e.call('tax-files', { action: 'cit_send', link_id: e.ctx.link_id, org_id: e.ctx.org_id, year: p.year }) : null;
        return { done: true, summary: `The ${p.year} companies income tax return is approved. ${flux(r)}` };
      }
      return { error: 'Unknown return.' };
    }
  }
  void actionId;
  return { error: 'Unknown action.' };
}
