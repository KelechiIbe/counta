// What Martina may do, not just prepare, once the person says yes: record a sale, issue an invoice (and send it), approve a
// supplier bill, remind a customer. Each works in two steps. The first call checks everything and holds the action, which
// shows on screen with Approve and Cancel; Martina reads it back. confirm_action carries it out only if the person has said
// yes since (in their own words, checked here, not taken from Martina) or tapped Approve. Anything that sends money out
// (paying a bill, a payout, a bulk or tax payment) is never done here: Martina opens it on screen and the person taps.
import { useSyncExternalStore } from 'react';
import type { QueryClient } from '@tanstack/react-query';
import { rpc } from '../lib/supabase';
import { N2 } from '../lib/format';
import { parseLines } from '../lib/drafts';
import { can } from '../state/session';
import type { Inventory } from '../lib/types';
import { saidYes } from './handsFree';

export type Done = { done: true; summary: string; number?: string };
export type Pending = { id: string; kind: 'sale' | 'invoice' | 'bill' | 'reminder'; title: string; lines: string[]; total: number | null; note?: string; at: number;
  run: () => Promise<Done> };

let pending: Pending | null = null;
const listeners = new Set<() => void>();
const emit = () => listeners.forEach((l) => l());
const hold = (p: Pending) => { pending = p; emit(); return p; };
export const clearPending = () => { if (pending) { pending = null; emit(); } };
export const currentPending = () => pending;
export function usePendingAction() {
  return useSyncExternalStore((cb) => { listeners.add(cb); return () => { listeners.delete(cb); }; }, () => pending);
}

// Carries out the action held, once. A tap on Approve comes here directly; Martina comes through confirm_action.
export async function runPending(id: string): Promise<Done | { error: string }> {
  const p = pending;
  if (!p || p.id !== id) return { error: 'Nothing is waiting for approval. Prepare it again.' };
  if (Date.now() - p.at > 10 * 60_000) { clearPending(); return { error: 'That waited too long. Prepare it again.' }; }
  pending = null; emit();
  try { return await p.run(); } catch (e) { return { error: (e as Error).message || 'Counta could not do that.' }; }
}

type Ctx = { org: () => string; inv: () => Promise<Inventory>; nav: (to: string) => void; qc: QueryClient;
  // What the person said (or typed) to Martina since a moment: their words decide, not hers.
  userSince: (at: number) => string[] };

const id = () => (crypto as any).randomUUID?.() || `a${Date.now()}${Math.random().toString(16).slice(2)}`;
const lagosToday = () => new Date(Date.now() + 3600_000).toISOString().slice(0, 10);
const addDays = (d: string, n: number) => new Date(Date.parse(d + 'T12:00:00Z') + n * 86400_000).toISOString().slice(0, 10);
const PAY: Record<string, string> = { cash: 'cash', transfer: 'transfer', bank: 'transfer', pos: 'pos', card: 'card', later: 'later', credit: 'later', owing: 'later' };
const PAY_WORDS: Record<string, string> = { cash: 'paid in cash', transfer: 'paid by transfer (confirmed when the money arrives)', pos: 'paid by POS', card: 'paid by card',
  later: 'to be paid later (it waits in Sales to settle)' };
const askBack = (p: Pending) => ({
  waiting_for_approval: true, action_id: p.id, read_back: [p.title, ...p.lines, p.total != null ? `Total ${N2(p.total)}` : '', p.note || ''].filter(Boolean).join('. '),
  next: 'Read this back in one or two sentences and ask whether to go ahead. It is on their screen with Approve and Cancel. Call confirm_action only after they say yes; call cancel_action if they say no.',
});

async function findCustomer(o: string, name: string) {
  const r = await rpc<any>('get_customers', { p_org: o });
  const all: any[] = (r?.customers || []).filter((c: any) => !c.archived && !c.is_walk_in);
  const n = name.trim().toLowerCase();
  const exact = all.filter((c) => c.name.toLowerCase() === n);
  if (exact.length === 1) return { customer: exact[0] };
  const part = all.filter((c) => c.name.toLowerCase().includes(n) || n.includes(c.name.toLowerCase()));
  if (part.length === 1) return { customer: part[0] };
  if (part.length > 1) return { choose: part.slice(0, 6).map((c) => c.name) };
  return { none: true };
}

export function voiceActions(ctx: Ctx): Record<string, (p: any) => Promise<unknown>> {
  return {
    record_sale: async ({ lines, payment, customer }) => {
      const inv = await ctx.inv();
      if (!can(inv, 'record_sales')) return { error: 'Their role does not record sales.' };
      const parsed = parseLines(String(lines || ''), inv.items);
      const known = parsed.filter((l) => l.item_id);
      if (!known.length) return { error: 'None of those are in the product list. Check the names, or add the products first.' };
      const pay = PAY[String(payment || '').toLowerCase()];
      if (!pay) return { need: 'Ask how it was paid: cash, transfer, POS, card, or later (on credit).' };
      // A sale recorded this way uses the prices in the product list.
      const items = new Map(inv.items.map((i) => [i.id, i]));
      const priced = known.map((l) => ({ ...l, list: Number((items.get(l.item_id!) as any)?.price) || 0 }));
      const changed = priced.filter((l) => l.unit_price != null && Math.abs(Number(l.unit_price) - l.list) > 0.004);
      const total = priced.reduce((s, l) => s + l.qty * l.list, 0);
      const who = String(customer || '').trim();
      const saleId = id();
      const p = hold({
        id: saleId, kind: 'sale', title: who ? `Record a sale to ${who}` : 'Record a sale', at: Date.now(), total: Math.round(total * 100) / 100,
        lines: priced.map((l) => `${l.qty} × ${l.name} at ${N2(l.list)}`), note: PAY_WORDS[pay],
        run: async () => {
          const r = await rpc<any>('record_quick_sale', { p_org: ctx.org(), p: { lines: known.map((l) => ({ item_id: l.item_id, qty: l.qty, unit: 'selling' })), pay,
            customer_name: who || null, voice: true, client_uuid: saleId, note: 'Recorded by Martina on a spoken yes' } });
          for (const k of ['sales', 'inv', 'finance']) void ctx.qc.invalidateQueries({ queryKey: [k] });
          return { done: true, number: r.number, summary: `Sale ${r.number} recorded, ${N2(r.total)}${r.settle_later ? ', waiting in Sales to be settled' : pay === 'transfer' ? ', the transfer is confirmed when it arrives' : ''}${r.review_status === 'pending' ? '. The owner reviews sales recorded by voice until they are trusted' : ''}.` };
        },
      });
      return { ...askBack(p), ...(changed.length ? { prices: `The product list prices apply here, not the ones said for ${changed.map((l) => l.name).join(', ')}. For other prices, use draft_sale and the till.` } : {}),
        not_found: parsed.filter((l) => !l.item_id).map((l) => l.name) };
    },

    issue_invoice: async ({ customer, lines, due_in_days, send }) => {
      const inv = await ctx.inv();
      if (!can(inv, 'record_sales')) return { error: 'Their role does not raise invoices.' };
      const o = ctx.org();
      const f = await findCustomer(o, String(customer || ''));
      if ('choose' in f) return { need: `More than one customer matches. Ask which: ${f.choose!.join(', ')}.` };
      if ('none' in f) return { error: `No customer called ${customer}. Add them on the Customers screen first, or use draft_invoice to open the invoice on screen.` };
      const c = f.customer;
      const parsed = parseLines(String(lines || ''), inv.items);
      if (!parsed.length) return { error: 'Say what goes on the invoice.' };
      const noPrice = parsed.filter((l) => l.unit_price == null || !(Number(l.unit_price) > 0));
      if (noPrice.length) return { need: `Ask the price of ${noPrice.map((l) => l.name).join(', ')}.` };
      const channel = send === 'whatsapp' ? 'whatsapp' : send === 'email' ? 'email' : null;
      const to = channel === 'whatsapp' ? c.phone : channel === 'email' ? c.email : null;
      if (channel && !to) return { error: `${c.name} has no ${channel === 'whatsapp' ? 'phone number' : 'email address'} on file. Issue it without sending, or add it on the Customers screen.` };
      const today = lagosToday();
      const days = Number(due_in_days) >= 0 && due_in_days !== '' && due_in_days != null ? Number(due_in_days) : Number(inv.org.invoice_terms_days ?? 14);
      const due = addDays(today, days);
      const total = parsed.reduce((s, l) => s + l.qty * Number(l.unit_price), 0);
      const p = hold({
        id: id(), kind: 'invoice', title: `Issue an invoice to ${c.name}`, at: Date.now(), total: Math.round(total * 100) / 100,
        lines: [...parsed.map((l) => `${l.qty} × ${l.name} at ${N2(Number(l.unit_price))}`), `Due ${due}`],
        note: [inv.org.prices_include_vat ? 'Prices include VAT' : inv.org.vat_registered ? 'VAT is added on top where it applies' : '', channel ? `Sent to ${to} by ${channel === 'whatsapp' ? 'WhatsApp' : 'email'}` : 'Not sent to the customer'].filter(Boolean).join('. '),
        run: async () => {
          const s = await rpc<any>('save_sale_doc', { p_org: o, p_doc: { id: null, doc_type: 'invoice', status: 'issue', customer_id: c.id, issue_date: today, due_date: due,
            prices_include_vat: Boolean(inv.org.prices_include_vat), delivery_fee: 0, notes: 'Raised by Martina on a spoken yes', terms: null, reference: null,
            lines: parsed.map((l) => (l.item_id ? { item_id: l.item_id, qty: l.qty, unit: 'selling', unit_price: Number(l.unit_price), discount: 0 }
              : { description: l.name, qty: l.qty, unit_price: Number(l.unit_price), discount: 0, vat_treatment: 'standard', revenue_account: null })) } });
          let sent = '';
          if (channel && to) {
            try { await rpc('send_document', { p_sale: s.id, p_channel: channel, p_to: to }); sent = ` and sent to ${c.name} by ${channel === 'whatsapp' ? 'WhatsApp' : 'email'}`; }
            catch (e) { sent = `. It could not be sent: ${(e as Error).message}`; }
          }
          for (const k of ['sales', 'sale', 'customers', 'finance']) void ctx.qc.invalidateQueries({ queryKey: [k] });
          return { done: true, number: s.number, summary: `Invoice ${s.number} issued to ${c.name} for ${N2(s.total)}, due ${due}${sent}.` };
        },
      });
      return askBack(p);
    },

    approve_bill: async ({ number, vendor }) => {
      const inv = await ctx.inv();
      if (!can(inv, 'keep_books') && !can(inv, 'make_payments')) return { error: 'Their role does not approve bills.' };
      const r = await rpc<any>('get_bills', { p_org: ctx.org(), p_filter: {} });
      let list: any[] = (r?.bills || []).filter((b: any) => b.status === 'draft');
      if (number) list = list.filter((b) => String(b.number).toLowerCase() === String(number).toLowerCase() || String(b.vendor_ref || '').toLowerCase() === String(number).toLowerCase());
      if (vendor) list = list.filter((b) => String(b.vendor_name).toLowerCase().includes(String(vendor).toLowerCase()));
      if (!list.length) return { error: 'No bill waiting for approval matches that. Use the bills tool to see what is waiting.' };
      if (list.length > 1) return { need: `More than one bill is waiting: ${list.slice(0, 6).map((b) => `${b.number} from ${b.vendor_name}, ${N2(b.total)}`).join('; ')}. Ask which.` };
      const b = list[0];
      const p = hold({
        id: id(), kind: 'bill', title: `Approve ${b.number} from ${b.vendor_name}`, at: Date.now(), total: Number(b.total),
        lines: [b.vendor_ref ? `Their invoice ${b.vendor_ref}` : '', b.due_date ? `Due ${b.due_date}` : ''].filter(Boolean),
        note: 'Approving puts it in the books and on the list to pay. Paying it is a separate step on screen.',
        run: async () => {
          await rpc('approve_bill', { p_bill: b.id });
          void ctx.qc.invalidateQueries({ queryKey: ['bills'] });
          return { done: true, number: b.number, summary: `${b.number} from ${b.vendor_name} is approved and in the books. It is on the list to pay.` };
        },
      });
      return askBack(p);
    },

    remind_customer: async ({ customer, channel }) => {
      const inv = await ctx.inv();
      if (!can(inv, 'record_sales')) return { error: 'Their role does not send reminders.' };
      const o = ctx.org();
      const f = await findCustomer(o, String(customer || ''));
      if ('choose' in f) return { need: `More than one customer matches. Ask which: ${f.choose!.join(', ')}.` };
      if ('none' in f) return { error: `No customer called ${customer}.` };
      const c = f.customer;
      const via = channel === 'email' ? 'email' : channel === 'whatsapp' ? 'whatsapp' : c.phone ? 'whatsapp' : 'email';
      if (via === 'whatsapp' ? !c.phone : !c.email) return { error: `${c.name} has no ${via === 'whatsapp' ? 'phone number' : 'email address'} on file.` };
      const s = await rpc<any>('get_sales', { p_org: o, p_filter: { customer_id: c.id, doc_type: 'invoice,order', status: 'open,partially_paid', limit: 20 } });
      const open: any[] = (s?.rows || []).filter((x: any) => Number(x.balance) > 0 && x.doc_type !== 'receipt');
      if (!open.length) return { error: `${c.name} owes nothing on an invoice.` };
      const owed = open.reduce((a, x) => a + Number(x.balance), 0);
      const one = open.length === 1 ? open[0] : null;
      const p = hold({
        id: id(), kind: 'reminder', title: `Remind ${c.name} by ${via === 'whatsapp' ? 'WhatsApp' : 'email'}`, at: Date.now(), total: Math.round(owed * 100) / 100,
        lines: one ? [`About ${one.number}, ${N2(one.balance)} owed${one.overdue_days ? `, ${one.overdue_days} days overdue` : ''}`] : [`A statement of ${open.length} unpaid invoices`],
        note: `To ${via === 'whatsapp' ? c.phone : c.email}`,
        run: async () => {
          if (one) await rpc('send_reminder', { p_sale: one.id, p_channel: via });
          else await rpc('send_statement', { p_customer: c.id, p_channel: via });
          return { done: true, summary: `${c.name} has been sent ${one ? `a reminder about ${one.number}` : 'a statement of what they owe'} by ${via === 'whatsapp' ? 'WhatsApp' : 'email'}.` };
        },
      });
      return askBack(p);
    },

    // Money out: opened on screen, never paid here.
    pay_bill: async ({ number, vendor }) => {
      const inv = await ctx.inv();
      if (!can(inv, 'make_payments')) return { error: 'Their role does not pay bills.' };
      const r = await rpc<any>('get_bills', { p_org: ctx.org(), p_filter: {} });
      let list: any[] = (r?.bills || []).filter((b: any) => ['approved', 'partially_paid'].includes(b.status) && Number(b.balance) > 0);
      if (number) list = list.filter((b) => String(b.number).toLowerCase() === String(number).toLowerCase() || String(b.vendor_ref || '').toLowerCase() === String(number).toLowerCase());
      if (vendor) list = list.filter((b) => String(b.vendor_name).toLowerCase().includes(String(vendor).toLowerCase()));
      if (!list.length) return { error: 'No approved bill to pay matches that. A bill must be approved before it is paid.' };
      if (list.length > 1) return { need: `More than one bill matches: ${list.slice(0, 6).map((b) => `${b.number} from ${b.vendor_name}, ${N2(b.balance)}`).join('; ')}. Ask which.` };
      const b = list[0];
      ctx.nav(`/purchases/bills?open=${b.id}`);
      return { opened: `${b.number} from ${b.vendor_name}, ${N2(b.balance)} to pay`, note: 'Money leaves the wallet only when the person taps Pay on screen. Tell them it is open and where to tap. Never say it is paid.' };
    },

    confirm_action: async ({ action_id }) => {
      const p = pending;
      if (!p || p.id !== action_id) return { error: 'Nothing is waiting with that id. Prepare it again.' };
      const words = ctx.userSince(p.at);
      const last = words[words.length - 1] || '';
      if (!last || !saidYes(last)) return { not_done: true, note: last ? 'What they said was not a clear yes. Ask again, or cancel.' : 'They have not answered yet. Ask whether to go ahead.' };
      return await runPending(p.id);
    },

    cancel_action: async ({ action_id }) => {
      if (pending && (!action_id || pending.id === action_id)) { clearPending(); return 'Cancelled. Nothing was done.'; }
      return 'Nothing was waiting.';
    },
  };
}
