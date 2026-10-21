// What Martina can look up and prepare everywhere in Counta. Each tool runs here, as the signed-in person, through the
// same database calls the screens make, so the database's own rules decide what she sees; a role that cannot see costs
// gets answers without them. Drafts open on a screen filled in; the person confirms.
import type { QueryClient } from '@tanstack/react-query';
import { rpc } from '../lib/supabase';
import { buildItems, qtyLabel } from '../lib/domain';
import { parseLines, setDraft } from '../lib/drafts';
import type { Inventory } from '../lib/types';

type Ctx = { org: () => string; nav: (to: string) => void; qc: QueryClient; celebrate: () => void };
type Tool = (p: any) => Promise<unknown>;

const round = (n: unknown) => (n == null || !Number.isFinite(Number(n)) ? null : Math.round(Number(n)));
const lagosToday = () => new Date(Date.now() + 3600_000).toISOString().slice(0, 10);
const iso = (d: Date) => d.toISOString().slice(0, 10);

// A period as dates, in Lagos time.
export function periodDates(period: string, from?: string, to?: string): { from: string; to: string; label: string } {
  const t = new Date(lagosToday() + 'T12:00:00Z');
  const day = (d: Date, n: number) => new Date(d.getTime() + n * 86400_000);
  const y = t.getUTCFullYear(), m = t.getUTCMonth();
  const monday = day(t, -((t.getUTCDay() + 6) % 7));
  const q = Math.floor(m / 3);
  switch (period) {
    case 'today': return { from: iso(t), to: iso(t), label: 'today' };
    case 'yesterday': return { from: iso(day(t, -1)), to: iso(day(t, -1)), label: 'yesterday' };
    case 'this_week': return { from: iso(monday), to: iso(t), label: 'this week so far' };
    case 'last_week': return { from: iso(day(monday, -7)), to: iso(day(monday, -1)), label: 'last week' };
    case 'last_month': return { from: iso(new Date(Date.UTC(y, m - 1, 1))), to: iso(new Date(Date.UTC(y, m, 0))), label: 'last month' };
    case 'this_quarter': return { from: iso(new Date(Date.UTC(y, q * 3, 1))), to: iso(t), label: 'this quarter so far' };
    case 'last_quarter': return { from: iso(new Date(Date.UTC(y, q * 3 - 3, 1))), to: iso(new Date(Date.UTC(y, q * 3, 0))), label: 'last quarter' };
    case 'this_year': return { from: `${y}-01-01`, to: iso(t), label: 'this year so far' };
    case 'last_year': return { from: `${y - 1}-01-01`, to: `${y - 1}-12-31`, label: 'last year' };
    case 'custom':
      if (/^\d{4}-\d{2}-\d{2}$/.test(String(from)) && /^\d{4}-\d{2}-\d{2}$/.test(String(to))) return { from: String(from), to: String(to), label: `${from} to ${to}` };
      return { from: iso(new Date(Date.UTC(y, m, 1))), to: iso(t), label: 'this month so far' };
    default: return { from: iso(new Date(Date.UTC(y, m, 1))), to: iso(t), label: 'this month so far' };
  }
}

// Report rows trimmed for the agent: the first rows, numbers rounded, long text cut.
function slim(rows: Record<string, any>[] | undefined, n = 12) {
  return (rows || []).slice(0, n).map((r) => Object.fromEntries(Object.entries(r).filter(([, v]) => v != null && v !== '' && typeof v !== 'object')
    .map(([k, v]) => [k, typeof v === 'number' ? Math.round(v * 100) / 100 : typeof v === 'string' ? v.slice(0, 80) : v])));
}

async function inventory(ctx: Ctx): Promise<Inventory> {
  const o = ctx.org();
  return ctx.qc.getQueryData<Inventory>(['inv', o]) || await rpc<Inventory>('get_inventory', { p_org: o });
}

const SCREENS: Record<string, string> = {
  home: '/home', till: '/sell/till', sales: '/sell/sales', invoices: '/sell/sales', customers: '/sell/customers', orders: '/sell/orders',
  products: '/inventory/items', stock_counts: '/inventory/counts', reorder: '/inventory/reorder', receive_stock: '/inventory/receive', payments: '/payments',
  bills: '/purchases/bills', vendors: '/purchases/vendors', banking: '/accounting/banking', books: '/accounting/inbox', reports: '/accounting/ledgers',
  tax: '/tax/vat', vat: '/tax/vat', wht: '/tax/wht', cit: '/tax/cit', team: '/settings#team', settings: '/settings',
  identity: '/settings#identity',
};

const REPORT: Record<string, string> = { profit_and_loss: 'sopl', balance_sheet: 'sofp', cash_flow: 'cash_flow', receivables_ageing: 'ar_aging', payables_ageing: 'ap_aging',
  ratios: 'ratios', trends: 'trends', cash_forecast: 'cash_forecast' };

export function assistantTools(ctx: Ctx): Record<string, Tool> {
  return {
    get_overview: async () => {
      const o = ctx.org();
      const [fin, inv] = await Promise.all([rpc<any>('get_finance_overview', { p_org: o }).catch(() => null), inventory(ctx).catch(() => null)]);
      const items = inv ? buildItems(inv, 'ALL') : [];
      const low = items.filter((i) => i.status === 'Low');
      return {
        money: fin ? { revenue_this_month: round(fin.revenue_mtd), revenue_last_month: round(fin.revenue_last_month), profit_this_month: round(fin.profit_mtd),
          profit_last_month: round(fin.profit_last_month), revenue_this_year: round(fin.revenue_ytd), cash_and_bank: round(fin.cash),
          customers_owe: round(fin.receivables), of_which_overdue: round(fin.receivables_overdue), owed_to_suppliers: round(fin.payables), bills_to_pay: fin.bills_to_pay,
          vat_payable: round(fin.vat_payable), books_questions_waiting: fin.inbox, months_of_cash_left: fin.runway_months } : 'Their role does not see the money figures.',
        stock: inv ? { products: inv.items.length, running_low_or_out: low.length, examples: low.slice(0, 5).map((i) => i.name) } : null,
      };
    },
    sales_report: async ({ period, from, to, by }) => {
      const p = periodDates(period, from, to);
      const r = await rpc<any>('accounting_report', { p_org: ctx.org(), p_report: 'sales_analysis', p_from: p.from, p_to: p.to,
        p_options: { by: by && by !== 'total' ? by : 'month' } });
      return { period: p.label, from: p.from, to: p.to, totals: r?.extra?.totals ?? r?.extra ?? null, rows: slim(r?.rows, by && by !== 'total' ? 10 : 3) };
    },
    find_documents: async ({ kind, customer, number, status, period, from, to }) => {
      const o = ctx.org();
      const filter: Record<string, unknown> = { limit: 10 };
      if (kind && kind !== 'any') filter.doc_type = kind;
      if (number) filter.q = String(number);
      // The sales list filters by the documents' own statuses: owing is open or partly paid; overdue is that, past its due date.
      if (status === 'unpaid' || status === 'overdue') { filter.status = 'open,partially_paid'; filter.limit = 50; }
      if (status === 'paid') filter.status = 'paid';
      if (period) { const p = periodDates(period, from, to); filter.from = p.from; filter.to = p.to; }
      if (customer) {
        const cs = await rpc<any>('get_customers', { p_org: o });
        const c = (cs?.customers || []).find((x: any) => x.name.toLowerCase().includes(String(customer).toLowerCase()));
        if (!c) return { found: 0, note: `No customer called ${customer}.` };
        filter.customer_id = c.id;
      }
      const r = await rpc<any>('get_sales', { p_org: o, p_filter: filter });
      const rows = (r?.rows || []).filter((x: any) => status !== 'overdue' || Number(x.overdue_days) > 0).slice(0, 10);
      return { found: rows.length, documents: rows.map((s: any) => ({ number: s.number, kind: s.doc_type, customer: s.customer_name, date: s.issue_date, total: round(s.total),
        still_owed: round(s.balance), status: s.status, overdue_days: s.overdue_days || undefined })) };
    },
    customers: async ({ name, owing_only }) => {
      const r = await rpc<any>('get_customers', { p_org: ctx.org() });
      let list: any[] = (r?.customers || []).filter((c: any) => !c.archived && !c.is_walk_in);
      if (name) list = list.filter((c) => c.name.toLowerCase().includes(String(name).toLowerCase()));
      if (owing_only || !name) list = list.filter((c) => Number(c.receivable) > 0).sort((a, b) => Number(b.receivable) - Number(a.receivable));
      return { count: list.length, customers: list.slice(0, 10).map((c) => ({ name: c.name, owes: round(c.receivable), overdue: round(c.overdue), oldest_due: c.oldest_due,
        open_documents: c.open_count, bought_last_12_months: round(c.sales_12m), last_bought: c.last_sale, phone: c.phone })) };
    },
    stock: async ({ item, filter }) => {
      const inv = await inventory(ctx);
      let items = buildItems(inv, 'ALL');
      if (item) items = items.filter((i) => i.name.toLowerCase().includes(String(item).toLowerCase()));
      if (filter === 'low') items = items.filter((i) => i.status === 'Low' && i.qAll > 0);
      if (filter === 'out') items = items.filter((i) => i.qAll <= 0);
      if (filter === 'expiring') {
        const soon = Date.now() + 60 * 86400_000;
        const ids = new Set(inv.batches.filter((b) => b.expiry_date && Date.parse(b.expiry_date) < soon && Number(b.qty_remaining) > 0).map((b) => b.item_id));
        items = items.filter((i) => ids.has(i.id));
      }
      return { count: items.length, items: items.slice(0, 10).map((i) => ({ name: i.name, on_hand: qtyLabel(i, i.qAll), status: i.status,
        days_of_cover: i.cover != null ? Math.round(i.cover) : undefined, reorder_at: i.reorder_floor ? qtyLabel(i, Number(i.reorder_floor)) : undefined,
        by_branch: inv.locations.map((l) => `${l.name}: ${qtyLabel(i, Number(i.qty?.[l.id] || 0))}`).join('; '), price: round(i.price) })) };
    },
    money: async () => {
      const o = ctx.org();
      const [bank, pay] = await Promise.all([rpc<any>('get_banking', { p_org: o }).catch((e) => ({ error: e.message })), rpc<any>('get_payments', { p_org: o }).catch(() => null)]);
      return {
        accounts: bank?.error ? bank.error : (bank?.accounts || []).slice(0, 10).map((a: any) => ({ name: a.name, kind: a.kind, balance: round(a.balance ?? a.book_balance),
          last_reconciled: a.last_reconciliation?.as_of })),
        wallet: pay?.wallet ? { status: pay.wallet.status, bank: pay.wallet.bank_name, account_number: pay.wallet.account_number, balance: round(pay.wallet.books_balance) } : null,
        payouts_waiting_approval: (pay?.payouts || []).filter((p: any) => p.status === 'pending_approval').length || 0,
        payment_requests_open: (pay?.requests || []).filter((r: any) => r.status === 'pending').length || 0,
      };
    },
    bills: async ({ status, vendor }) => {
      const r = await rpc<any>('get_bills', { p_org: ctx.org(), p_filter: {} });
      let list: any[] = r?.bills || [];
      if (vendor) list = list.filter((b) => b.vendor_name.toLowerCase().includes(String(vendor).toLowerCase()));
      if (status !== 'all') list = list.filter((b) => ['approved', 'partially_paid', 'draft', 'pending'].includes(b.status) && Number(b.balance) > 0);
      if (status === 'overdue') list = list.filter((b) => Number(b.overdue_days) > 0);
      list.sort((a, b) => String(a.due_date).localeCompare(String(b.due_date)));
      return { count: list.length, total_owed: round(list.reduce((s, b) => s + Number(b.balance || 0), 0)),
        bills: list.slice(0, 10).map((b) => ({ number: b.number, supplier: b.vendor_name, due: b.due_date, owed: round(b.balance), status: b.status, overdue_days: b.overdue_days || undefined })) };
    },
    financial_report: async ({ report, period, from, to }) => {
      const p = periodDates(period || (report === 'balance_sheet' || report.endsWith('ageing') ? 'today' : 'this_month'), from, to);
      const r = await rpc<any>('accounting_report', { p_org: ctx.org(), p_report: REPORT[report] || 'sopl', p_from: report === 'balance_sheet' ? null : p.from, p_to: p.to, p_options: {} });
      return { report, period: report === 'balance_sheet' ? `as at ${p.to}` : p.label, totals: r?.extra?.totals ?? null, lines: slim(r?.rows, 14) };
    },
    tax_position: async ({ tax }) => {
      const o = ctx.org();
      if (tax === 'vat') {
        const r = await rpc<any>('vat_position', { p_org: o, p: {} });
        return { months: (r?.months || []).slice(-4).map((x: any) => Object.fromEntries(Object.entries(x).filter(([, v]) => typeof v !== 'object').map(([k, v]) => [k, typeof v === 'number' ? round(v) : v]))) };
      }
      if (tax === 'wht') {
        const r = await rpc<any>('withholding_overview', { p_org: o, p: {} });
        return { due: slim(r?.due || r?.periods || r?.lines, 8), remitted: slim(r?.remittances, 5) };
      }
      const r = await rpc<any>('cit_years', { p_org: o });
      return { years: slim(r?.years, 4), profile: r?.profile ? { legal_form: r.profile.legal_form, small_company: r.profile.small_company } : null };
    },
    books_questions: async () => {
      const r = await rpc<any>('get_books_inbox', { p_org: ctx.org() });
      const qs = r?.questions || [];
      return { waiting: qs.length, questions: qs.slice(0, 6).map((q: any) => ({ question: q.question || q.title, amount: round(q.amount ?? q.line?.amount), date: q.line?.date,
        narration: q.line?.narration?.slice?.(0, 80), suggestion: q.account_name })) };
    },
    team: async () => {
      const r = await rpc<any>('get_team', { p_org: ctx.org() });
      if (!r?.can_manage) return { note: 'Only someone who manages the team sees everyone.' };
      return { people: (r.members || []).filter((m: any) => m.status !== 'disabled').map((m: any) => ({ name: m.display_name, role: m.role_label,
        status: m.status === 'invited' ? 'invited, not joined yet' : m.has_login ? 'joined' : 'no login' })) };
    },
    compliance_score: async () => {
      const s = await rpc<any>('compliance_score', { p_org: ctx.org() });
      return { score: s.score, out_of: s.total, doing_well: s.items.filter((i: any) => i.ok).map((i: any) => i.label),
        to_do: s.items.filter((i: any) => !i.ok).map((i: any) => ({ what: i.label, how: i.text })) };
    },
    open_screen: async ({ screen }) => {
      const to = SCREENS[String(screen)];
      if (!to) return { error: 'Unknown screen.' };
      ctx.nav(to);
      return `Showing ${screen}.`;
    },
    draft_invoice: async ({ customer, lines, due_in_days, note }) => {
      const inv = await inventory(ctx);
      const parsed = parseLines(lines, inv.items);
      if (!parsed.length) return { error: 'Say what goes on the invoice.' };
      setDraft('invoice', { customer: String(customer || ''), lines: parsed, due_in_days: Number(due_in_days) || null, note: note || null });
      ctx.nav('/sell/sales');
      return { opened: 'a new invoice on screen, for the person to check and issue', lines: parsed.map((l) => `${l.qty} × ${l.name}${l.item_id ? '' : ' (not in the product list, added as written)'}${l.unit_price ? ` at ${l.unit_price}` : ' (no price yet)'}`) };
    },
    draft_sale: async ({ lines, customer }) => {
      const inv = await inventory(ctx);
      const parsed = parseLines(lines, inv.items);
      const known = parsed.filter((l) => l.item_id);
      if (!known.length) return { error: 'None of those are in the product list. Check the names, or add the products first.' };
      setDraft('sale', { lines: known, customer: customer || null });
      ctx.nav('/sell/till');
      return { opened: 'the till with these in the cart, for the person to take payment', in_cart: known.map((l) => `${l.qty} × ${l.name}`),
        not_found: parsed.filter((l) => !l.item_id).map((l) => l.name) };
    },
    draft_bill: async ({ vendor, amount, description, due_date }) => {
      if (!(Number(amount) > 0)) return { error: 'Say the amount.' };
      setDraft('bill', { vendor: String(vendor || ''), amount: Number(amount), description: String(description || ''), due_date: /^\d{4}-\d{2}-\d{2}$/.test(String(due_date)) ? due_date : null });
      ctx.nav('/purchases/bills');
      return { opened: 'a new bill on screen, for the person to check and save' };
    },
    draft_payment_link: async ({ amount, customer, description }) => {
      if (!(Number(amount) > 0)) return { error: 'Say the amount.' };
      setDraft('payment_link', { amount: Number(amount), customer: customer || null, description: description || null });
      ctx.nav('/payments');
      return { opened: 'a payment link on screen, for the person to check and create' };
    },
    draft_product: async ({ name, kind, price, cost, unit, category }) => {
      if (!String(name || '').trim()) return { error: 'Say the name.' };
      // Counta keeps stock items only; a service goes straight onto an invoice as its own line.
      if (kind === 'service') return { not_saved: true, note: 'Services are not kept as items in Counta. Put the service on an invoice with draft_invoice, with its price.' };
      setDraft('product', { name: String(name), kind: kind === 'service' ? 'service' : 'product', price: Number(price) || null, cost: Number(cost) || null, unit: unit || null, category: category || null });
      ctx.nav('/inventory/items');
      return { opened: 'a new product on screen, for the person to check and save' };
    },
  };
}
