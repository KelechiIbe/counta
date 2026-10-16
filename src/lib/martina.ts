// Martina: the inventory prompt bar. Gemini answers when configured; a rules engine answers otherwise.
import type { Inventory, Proposal, CountSession } from './types';
import type { CashStory, ItemView, Suggestion } from './domain';
import { qtyLabel, suAbbr } from './domain';
import { K, N, P } from './format';
import { ai } from './supabase';

export interface Answer { t: string; d: string; cta: string; route: string; action?: { type: 'draft_po'; item_id: string } | null; source: 'ai' | 'rules' }

export function buildContext(inv: Inventory, items: ItemView[], suggestions: Suggestion[], proposals: Proposal[], story: CashStory, counts: CountSession[]) {
  const locName = (id: string) => inv.locations.find((l) => l.id === id)?.name || 'Unknown';
  return {
    business: inv.org.name, today: inv.today, currency: 'NGN', margin_threshold_pct: Number(inv.org.margin_threshold),
    viewer_role: inv.me.role, can_see_costs: inv.can_see_costs,
    locations: inv.locations.map((l) => l.name),
    items: items.map((i) => ({
      id: i.id, name: i.name, category: i.category, status: i.status,
      on_hand: Object.fromEntries(inv.locations.map((l) => [l.name, Number(i.qty[l.id] || 0)])),
      on_hand_label: qtyLabel(i, i.qAll), selling_unit: i.selling_unit, purchase_unit: i.purchase_unit, pack_size: i.pack_size,
      sales_per_day: Math.round(i.vel * 10) / 10, days_cover: i.cover != null ? Math.round(i.cover * 10) / 10 : null,
      reorder_floor: Number(i.reorder_floor), price: i.price,
      ...(inv.can_see_costs ? { avg_cost: i.wac, replacement_cost: i.replacement_cost, margin_pct: i.margin != null ? Math.round(i.margin * 10) / 10 : null } : {}),
      expiring_batches: i.batchesInScope.filter((b) => b.expiry_date).map((b) => ({ batch: b.batch_no, expiry: b.expiry_date, qty: Number(b.qty_remaining), branch: locName(b.location_id) })),
      vendor: inv.vendors.find((v) => v.id === i.preferred_vendor_id)?.name || null,
    })),
    reorder_suggestions: suggestions.map((s) => ({ item_id: s.item.id, item: s.item.name, order: `${s.qtyPU} ${s.item.purchase_unit}`, vendor: s.vendor?.name, est_cost: s.cost, reason: s.reason })),
    open_price_proposals: proposals.filter((p) => p.status === 'open').map((p) => ({ item: p.item_name, kind: p.kind, price_now: p.old_price, suggested: p.suggested_price })),
    cash_vs_stock: story.hasTakings ? { headline: story.headline, pattern: story.pattern, weeks: story.weeks.map((w) => ({ week: w.label, implied: w.implied, recorded: w.recorded, gap: w.gap })) } : null,
    counts_awaiting_approval: counts.filter((c) => c.status === 'awaiting_approval').map((c) => ({ ref: c.ref, area: c.area, branch: locName(c.location_id) })),
  };
}

const ROUTES = ['/inventory', '/inventory/items', '/inventory/receive', '/inventory/counts', '/inventory/reorder', '/inventory/pricing', '/inventory/insights', '/inventory/locations'];

export async function askMartina(question: string, ctx: ReturnType<typeof buildContext>, fallback: () => Answer): Promise<Answer> {
  try {
    const r = await ai<{ ok: boolean; answer?: any }>('ask', { question, context: ctx });
    if (r?.ok && r.answer?.title) {
      const a = r.answer;
      return {
        t: String(a.title), d: String(a.detail || ''), cta: String(a.cta_label || 'Open'),
        route: ROUTES.includes(a.cta_route) ? a.cta_route : '/inventory/items',
        action: a.action?.type === 'draft_po' && a.action.item_id ? { type: 'draft_po', item_id: a.action.item_id } : null,
        source: 'ai',
      };
    }
  } catch { /* fall through */ }
  return fallback();
}

const words = (s: string) => s.toLowerCase().replace(/[^a-z0-9 ]/g, ' ').split(/\s+/).filter((w) => w.length > 2);
function findItem(q: string, items: ItemView[]): ItemView | null {
  const qw = new Set(words(q));
  let best: ItemView | null = null; let score = 0;
  for (const i of items) {
    const s = words(i.name).filter((w) => qw.has(w) && !['and', 'the'].includes(w)).length;
    if (s > score) { score = s; best = i; }
  }
  return score > 0 ? best : null;
}

export function localAnswer(q: string, inv: Inventory, items: ItemView[], suggestions: Suggestion[], proposals: Proposal[], story: CashStory): Answer {
  const s = q.toLowerCase();
  const loc = inv.locations.find((l) => s.includes(l.name.toLowerCase()));
  const item = findItem(q, items);
  const base = { source: 'rules' as const, action: null };
  if (/(po|order|reorder|draft|buy)/.test(s) && item) {
    const sg = suggestions.find((x) => x.item.id === item.id);
    return {
      ...base, t: `Draft PO for ${item.name}`,
      d: sg ? `${sg.qtyPU} ${sg.item.purchase_unit.toLowerCase()}${sg.qtyPU === 1 ? '' : 's'} from ${sg.vendor?.name || 'your usual vendor'}${sg.cost != null ? ` at about ${N(sg.cost)}` : ''}. ${sg.reason.split('. ').slice(0, 2).join('. ')}. It waits for your approval before anything is sent.`
        : `${item.name} has ${qtyLabel(item, item.qAll)} on hand${item.cover != null ? `, about ${Math.round(item.cover)} days of cover` : ''}. I can start a draft order; nothing is sent until you approve it.`,
      cta: 'Open draft', route: '/inventory/reorder', action: { type: 'draft_po', item_id: item.id },
    };
  }
  if (item && /(how many|left|remain|on hand|stock|have)/.test(s)) {
    const where = loc ? Number(item.qty[loc.id] || 0) : item.qAll;
    return {
      ...base, t: `${item.name}${loc ? ' at ' + loc.name : ''}`,
      d: `${qtyLabel(item, where)} on hand${loc ? '' : ' across all branches'}. ${item.vel > 0 ? `It sells about ${Math.round(item.vel * 10) / 10} ${suAbbr(item.selling_unit)} a day, so that is roughly ${Math.round(where / item.vel)} days of cover.` : 'There have been no sales in the last 30 days.'}`,
      cta: 'View item', route: '/inventory/items',
    };
  }
  if (/(cash|match|takings|saturday|sunday|shortfall|gap)/.test(s)) {
    if (!story.hasTakings) return { ...base, t: 'No takings recorded yet', d: 'Record daily cash and POS takings, or connect Numens, and I will compare them with what stock movements say you sold.', cta: 'Record takings', route: '/inventory/insights' };
    return { ...base, t: story.weekday ? `Why ${story.weekday} did not match` : 'Cash vs stock last week', d: [story.headline, story.pattern].filter(Boolean).join(' '), cta: 'See variance', route: '/inventory/insights' };
  }
  if (/(losing|lose|margin|below cost|money|profit)/.test(s)) {
    const below = items.filter((i) => i.status === 'Below cost');
    const thin = items.filter((i) => i.margin != null && i.margin >= 0 && i.margin < Number(inv.org.margin_threshold) && i.status !== 'Below cost');
    const open = proposals.filter((p) => p.status === 'open').length;
    if (!inv.can_see_costs) return { ...base, t: 'Margins are owner-only', d: 'Your role does not include costs and margins. Ask the owner to check the Pricing page.', cta: 'View items', route: '/inventory/items' };
    const parts: string[] = [];
    for (const b of below.slice(0, 2)) parts.push(`${b.name} sells at ${N(b.price)} but costs ${N(b.replacement_cost)} to replace, so every ${suAbbr(b.selling_unit)} loses ${N(Number(b.replacement_cost) - b.price)}.`);
    if (thin.length) parts.push(`${thin.slice(0, 3).map((t) => t.name.split(' ').slice(0, 2).join(' ')).join(', ')} ${thin.length === 1 ? 'is' : 'are'} above cost but under your ${inv.org.margin_threshold}% margin threshold.`);
    if (open) parts.push(`${open} price proposal${open === 1 ? ' is' : 's are'} waiting.`);
    return { ...base, t: below.length ? 'Items losing money' : 'Margins look healthy', d: parts.join(' ') || `Every item clears your ${inv.org.margin_threshold}% margin threshold.`, cta: 'Review prices', route: '/inventory/pricing' };
  }
  if (/(expir|expiry|batch|nafdac)/.test(s)) {
    const exp = items.flatMap((i) => i.batchesInScope.filter((b) => b.expiry_date).map((b) => ({ i, b }))).sort((a, b) => (a.b.expiry_date! < b.b.expiry_date! ? -1 : 1)).slice(0, 3);
    return { ...base, t: 'Batches expiring soon', d: exp.length ? exp.map(({ i, b }) => `${i.name} batch ${b.batch_no} (${Number(b.qty_remaining)} ${suAbbr(i.selling_unit)}) expires ${b.expiry_date}.`).join(' ') : 'No tracked batches expire soon.', cta: 'Batches & expiry', route: '/inventory/insights' };
  }
  if (/(dead|not selling|slow|stuck)/.test(s)) {
    const dead = items.filter((i) => i.status === 'Dead');
    return { ...base, t: 'Dead stock', d: dead.length ? `${dead.map((d) => d.name).join(', ')} ${dead.length === 1 ? 'has' : 'have'} not sold in 90+ days, holding ${K(dead.reduce((a, d) => a + (d.value || 0), 0))} at cost.` : 'Nothing has sat unsold for 90 days.', cta: 'See markdowns', route: '/inventory/insights' };
  }
  if (/(low|running|finish|short|out of)/.test(s)) {
    const scoped = items.map((i) => ({ i, q: loc ? Number(i.qty[loc.id] || 0) : i.qAll })).filter(({ i, q }) => i.vel > 0 && (q <= Number(i.reorder_floor) * (loc ? 0.5 : 1) || q / i.vel < 4))
      .sort((a, b) => a.q / a.i.vel - b.q / b.i.vel).slice(0, 3);
    if (!scoped.length) return { ...base, t: `Nothing running low${loc ? ' at ' + loc.name : ''}`, d: 'Every selling line has at least four days of cover.', cta: 'View items', route: '/inventory/items' };
    const other = loc ? inv.locations.find((l) => l.id !== loc.id) : null;
    const first = scoped[0];
    const spare = other ? Number(first.i.qty[other.id] || 0) : 0;
    return {
      ...base, t: `Running low${loc ? ' at ' + loc.name : ''}`,
      d: scoped.map(({ i, q }) => `${i.name} (${qtyLabel(i, q)}, ~${Math.max(0, Math.round(q / i.vel))} days)`).join(', ') + '.' + (other && spare > first.i.vel * 3 ? ` ${other.name} has ${qtyLabel(first.i, spare)} of ${first.i.name.split(' ')[0]}, so a transfer can cover the gap.` : ''),
      cta: 'Open reorder', route: '/inventory/reorder',
    };
  }
  const total = items.reduce((a, i) => a + (i.value || 0), 0);
  const low = items.filter((i) => i.status === 'Low').length;
  const dead = items.filter((i) => i.status === 'Dead').length;
  const expiring = items.filter((i) => i.status === 'Expiring').length;
  return {
    ...base, t: 'Stock position',
    d: `${inv.can_see_costs ? `You hold ${K(total)} of stock` : 'You stock'} across ${inv.locations.map((l) => l.name).join(' and ')} in ${items.length} items. ${low} ${low === 1 ? 'is' : 'are'} at or below the floor, ${dead} ${dead === 1 ? 'is' : 'are'} dead stock and ${expiring} ${expiring === 1 ? 'has' : 'have'} a batch expiring within 30 days.`,
    cta: 'View items', route: '/inventory/items',
  };
}

export const pctLabel = P;

// ---------------------------------------------------------------- chat (Assistant page and the phone's WhatsApp-style tab)
export interface ChatMsg { role: 'user' | 'bot'; text: string; at: number; quick?: string[]; action?: { type: 'offer_po'; item_id: string; qty?: number | null; vendor_id?: string | null } | null; route?: string | null; cta?: string | null; source?: 'ai' | 'rules' }

export async function chatMartina(history: ChatMsg[], ctx: ReturnType<typeof buildContext>, fallback: (q: string) => Answer): Promise<ChatMsg> {
  const last = [...history].reverse().find((m) => m.role === 'user')?.text || '';
  try {
    const r = await ai<{ ok: boolean; reply?: string; quick_replies?: string[]; action?: any }>('chat', { messages: history.map((m) => ({ role: m.role, text: m.text })), context: ctx });
    if (r?.ok && r.reply) {
      const a = r.action?.type === 'offer_po' && r.action.item_id && ctx.items.some((i) => i.id === r.action.item_id) ? { type: 'offer_po' as const, item_id: r.action.item_id, qty: r.action.qty_purchase_units ?? null, vendor_id: r.action.vendor_id ?? null } : null;
      return { role: 'bot', text: r.reply, at: Date.now(), quick: (r.quick_replies || []).slice(0, 3), action: a, source: 'ai' };
    }
  } catch { /* fall through to rules */ }
  const a = fallback(last);
  return {
    role: 'bot', text: `${a.t}. ${a.d}`, at: Date.now(), source: 'rules', route: a.route, cta: a.cta,
    action: a.action?.type === 'draft_po' ? { type: 'offer_po', item_id: a.action.item_id } : null,
    quick: ['What is running low?', 'Which items are losing money?', 'Does cash match stock?'].filter((q) => q.toLowerCase() !== last.toLowerCase()).slice(0, 3),
  };
}

export async function aiStatus(): Promise<{ configured: boolean; model?: string }> {
  try {
    const r = await ai<{ ok: boolean; configured?: boolean; model?: string }>('status', {});
    return { configured: !!r?.configured, model: r?.model };
  } catch { return { configured: false }; }
}
