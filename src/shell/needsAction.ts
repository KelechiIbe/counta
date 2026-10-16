import { useMemo } from 'react';
import { can, useInventory } from '../state/session';
import { useCashVsStock, useCounts, useFx, usePOs, useProposals, useReceipts, useTransfers } from '../lib/queries';
import { buildItems, cashVsStock, fxTrend, reorderSuggestions, type CashStory, type Suggestion } from '../lib/domain';
import { daysBetween } from '../lib/format';

export function useSuggestions(): { suggestions: Suggestion[]; ready: boolean } {
  const { data: inv } = useInventory();
  const canSee = can(inv, 'approve_pos') || can(inv, 'see_margins');
  const pos = usePOs(canSee);
  const fx = useFx();
  return useMemo(() => {
    if (!inv) return { suggestions: [], ready: false };
    const items = buildItems(inv, 'ALL');
    return { suggestions: reorderSuggestions(inv, items, pos.data || [], fxTrend(fx.data || [])), ready: !canSee || !!pos.data };
  }, [inv, pos.data, fx.data, canSee]);
}

export function useCashStory(loc: string): { story: CashStory; loading: boolean } {
  const { data: inv } = useInventory();
  const enabled = can(inv, 'see_margins');
  const cash = useCashVsStock(enabled);
  return useMemo(() => ({
    story: cashVsStock(cash.data, inv?.locations || [], loc, inv?.today || new Date().toISOString().slice(0, 10)),
    loading: enabled && cash.isLoading,
  }), [cash.data, inv, loc, enabled, cash.isLoading]);
}

export interface ActionRow { key: string; t: string; d: string; cta: string; to: string; icon: string; color: string; bg: string; state?: any }

export function useNeedsAction(): { rows: ActionRow[]; total: number; badges: { reorder: number; pricing: number; counts: number; receive: number; locations: number } } {
  const { data: inv } = useInventory();
  const { suggestions } = useSuggestions();
  const proposals = useProposals();
  const counts = useCounts();
  const receipts = useReceipts(can(inv, 'receive_stock') || can(inv, 'see_margins'));
  const transfers = useTransfers();
  const { story } = useCashStory('ALL');
  return useMemo(() => {
    const rows: ActionRow[] = [];
    const badges = { reorder: 0, pricing: 0, counts: 0, receive: 0, locations: 0 };
    if (!inv) return { rows, total: 0, badges };
    const today = inv.today;
    const name = (s: string) => s.split(' ').slice(0, 2).join(' ');
    if (can(inv, 'approve_pos') && suggestions.length) {
      badges.reorder = suggestions.length;
      const below = suggestions.filter((s) => s.onHand <= s.floor);
      const next = suggestions.find((s) => s.onHand > s.floor);
      const parts = [below[0] && `${name(below[0].item.name)} is below floor`, next && `${name(next.item.name)} crosses it in ~${Math.max(1, Math.round((next.onHand - next.floor) / next.vel))} days`].filter(Boolean);
      rows.push({ key: 'reorder', t: `${suggestions.length} reorder suggestion${suggestions.length === 1 ? '' : 's'}`, d: parts.join(' · ') || 'Stock is approaching its floor', cta: 'Review', to: '/inventory/reorder', icon: 'package', color: '#0072F5', bg: '#F0F7FF' });
    }
    const open = (proposals.data || []).filter((p) => p.status === 'open');
    if (open.length) {
      badges.pricing = can(inv, 'edit_prices') ? open.length : 0;
      if (can(inv, 'edit_prices')) {
        const below = open.find((p) => p.kind === 'below_replacement');
        rows.push({ key: 'pricing', t: `${open.length} price proposal${open.length === 1 ? '' : 's'}`, d: below ? `${name(below.item_name)} is selling below replacement cost` : `${name(open[0].item_name)} costs more than it used to`, cta: 'Review', to: '/inventory/pricing', icon: 'tag', color: '#DC2626', bg: '#FEF2F2' });
      }
    }
    const cs = counts.data || [];
    const awaiting = cs.filter((c) => c.status === 'awaiting_approval' || c.status === 'awaiting_reasons');
    if (awaiting.length && can(inv, 'approve_adjustments')) {
      badges.counts = awaiting.length;
      const a = awaiting[0];
      const who = inv.members.find((m) => m.id === a.assignee_id)?.display_name || 'staff';
      const area = a.area;
      rows.push({ key: 'count', t: `Count ${a.ref} ${a.status === 'awaiting_reasons' ? 'needs reasons' : 'awaiting approval'}`, d: `${area} · ${who}${awaiting.length > 1 ? ` · +${awaiting.length - 1} more` : ''}`, cta: 'Approve', to: '/inventory/counts', state: { open: a.id }, icon: 'camera', color: '#A16207', bg: '#FEFCE8' });
    }
    const mine = cs.filter((c) => c.assignee_id === inv.me.id && (c.status === 'open' || c.status === 'awaiting_reasons'));
    if (mine.length) rows.push({ key: 'mycount', t: `You have ${mine.length} count${mine.length === 1 ? '' : 's'} to do`, d: mine.map((c) => c.ref + ' · ' + c.area).join(', '), cta: 'Open phone', to: '/m/count', icon: 'phone', color: '#0072F5', bg: '#F0F7FF' });
    const review = (receipts.data || []).filter((r) => r.status === 'needs_review');
    if (review.length && can(inv, 'receive_stock')) {
      badges.receive = review.length;
      const r = review[0];
      const doubt = (r.receipt_lines || []).filter((l) => !l.confirmed).length;
      rows.push({ key: 'receipt', t: `Receipt ${r.ref} needs review`, d: [doubt ? `${doubt} line${doubt === 1 ? '' : 's'} under confidence` : 'Ready to post', r.vendor_name, r.source === 'photo_handwritten' ? 'handwritten' : r.source === 'manual' ? 'manual' : 'invoice'].filter(Boolean).join(' · '), cta: 'Review', to: '/inventory/receive', state: { open: r.id }, icon: 'image', color: '#C2410C', bg: '#FFF7ED' });
    }
    if (story.tone === 'red' && can(inv, 'see_margins')) {
      rows.push({ key: 'cash', t: story.weekday ? `${story.weekday} cash shortfall` : 'Cash does not match stock', d: `₦${Math.round(story.gap).toLocaleString('en-NG')} gap for ${story.weekLabel}${story.pattern ? ` · ${story.weekday} pattern` : ''}`, cta: 'Explain', to: '/inventory/insights', state: { tab: 'variance' }, icon: 'trendDown', color: '#7C3AED', bg: '#F5F3FF' });
    }
    const expired = inv.batches.filter((b) => !b.quarantined && Number(b.qty_remaining) > 0 && b.expiry_date && daysBetween(today, b.expiry_date) < 0);
    if (expired.length && can(inv, 'approve_adjustments')) {
      rows.push({ key: 'expired', t: `${expired.length} expired batch${expired.length === 1 ? '' : 'es'} still on the shelf`, d: 'Quarantine to take them out of sellable stock', cta: 'Quarantine', to: '/inventory/insights', state: { tab: 'expiry' }, icon: 'alert', color: '#DC2626', bg: '#FEF2F2' });
    }
    const intransit = (transfers.data || []).filter((t) => t.status === 'in_transit');
    if (intransit.length && (can(inv, 'transfer_stock') || can(inv, 'receive_stock'))) {
      badges.locations = intransit.length;
      rows.push({ key: 'transfer', t: `${intransit.length} transfer${intransit.length === 1 ? '' : 's'} in transit`, d: 'Confirm when the receiving branch has the goods', cta: 'Open', to: '/inventory/locations', icon: 'arrowLR', color: '#7C3AED', bg: '#F5F3FF' });
    }
    const unpriced = inv.items.filter((i) => i.needs_review);
    if (unpriced.length && can(inv, 'edit_prices')) {
      rows.push({ key: 'newitems', t: `${unpriced.length} item${unpriced.length === 1 ? '' : 's'} need a quick check`, d: unpriced.slice(0, 2).map((i) => i.name).join(', ') + (unpriced.length > 2 ? '…' : ''), cta: 'Check', to: '/inventory/items', state: { filter: 'review' }, icon: 'pencil', color: '#0072F5', bg: '#F0F7FF' });
    }
    return { rows, total: rows.length, badges };
  }, [inv, suggestions, proposals.data, counts.data, receipts.data, transfers.data, story]);
}
