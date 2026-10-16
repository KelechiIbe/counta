// Inventory rules from BUILD_SPEC §3–4: derived status, units, reorder points, vendor scores, cash vs stock.
import type { Batch, Inventory, Item, Location, Vendor, PurchaseOrder } from './types';
import { addDays, daysBetween, fmtDay, isoDow, K, N, P, shortName, toDayKey, weekday } from './format';

export type Status = 'Below cost' | 'Dead' | 'Expiring' | 'Low' | 'Healthy';
export const STATUS_ORDER: Status[] = ['Below cost', 'Dead', 'Expiring', 'Low', 'Healthy'];

const TONES: Record<string, string> = {
  Healthy: 't-green', Low: 't-orange', Expiring: 't-amber', Dead: 't-grey', 'Below cost': 't-red',
  Posted: 't-green', 'Needs review': 't-orange', Reading: 't-blue', Discarded: 't-grey',
  'Awaiting approval': 't-amber', 'Awaiting reasons': 't-orange', 'In progress': 't-blue', Approved: 't-green',
  Draft: 't-grey', Sent: 't-blue', Received: 't-green', Cancelled: 't-grey', Applied: 't-green', Dismissed: 't-grey',
  Expired: 't-red', OK: 't-green', Watch: 't-blue', Quarantined: 't-grey', 'In transit': 't-purple',
  blue: 't-blue', grey: 't-grey', purple: 't-purple', amber: 't-amber', red: 't-red', green: 't-green', orange: 't-orange',
};
export const tone = (label: string) => TONES[label] || 't-grey';

// ---------- units ----------
const PU_ABBR: Record<string, string> = { Carton: 'ctn', Bag: 'bag', Bale: 'bale', Pack: 'pk', Crate: 'crate', Roll: 'roll', Dozen: 'doz', Sack: 'sack', Tray: 'tray', Tin: 'tin' };
const SU_ABBR: Record<string, string> = { pack: 'pk', bottle: 'btl', sachet: 'sct', piece: 'pc' };
export const puAbbr = (pu: string) => PU_ABBR[pu] || (pu || '').toLowerCase();
export const suAbbr = (su: string) => SU_ABBR[su] || su;
export function pluralUnit(u: string, n: number): string {
  if (Math.abs(n) === 1 || /s$/i.test(u) || /^(kg|g|l|ml|cl|ltr)$/i.test(u)) return u;
  if (u === 'box') return 'boxes';
  return u + 's';
}
const fq = (n: number) => Number(n).toLocaleString('en-NG', { maximumFractionDigits: 3 });

export function qtyLabel(it: Pick<Item, 'purchase_unit' | 'pack_size' | 'selling_unit'>, q: number): string {
  const su = suAbbr(it.selling_unit);
  const neg = q < 0; const a = Math.abs(q); const sign = neg ? '−' : '';
  if (!it.pack_size || it.pack_size <= 1) return sign + fq(a) + ' ' + su;
  const c = Math.floor(a / it.pack_size); const r = Math.round((a - c * it.pack_size) * 1000) / 1000;
  if (!c) return sign + fq(a) + ' ' + su;
  return sign + c.toLocaleString('en-NG') + ' ' + puAbbr(it.purchase_unit) + (r ? ' + ' + fq(r) + ' ' + su : '') + ' · ' + sign + fq(a) + ' ' + su;
}
export function suQty(it: Pick<Item, 'selling_unit'>, q: number) { return fq(q) + ' ' + pluralUnit(it.selling_unit, q); }

// ---------- item view ----------
export interface ItemView extends Item {
  q: number; qAll: number; vel: number; cover: number | null; margin: number | null; value: number | null;
  status: Status; batchesInScope: Batch[]; trend: number | null; lastSaleDays: number | null;
}
export const sumQty = (it: Item) => Object.values(it.qty || {}).reduce((a, b) => a + Number(b), 0);

export function velocity(it: Item, today: string): number {
  if (!it.first_at) return 0;
  const days = Math.min(30, Math.max(7, daysBetween(toDayKey(it.first_at), today)));
  return Number(it.sold_30) / days;
}

export function statusOf(it: Item, q: number, batches: Batch[], today: string): Status {
  if (it.replacement_cost != null && Number(it.price) < Number(it.replacement_cost)) return 'Below cost';
  const ref = it.last_sale_at || it.first_at;
  if (q > 0 && ref && daysBetween(toDayKey(ref), today) >= 90) return 'Dead';
  if (batches.some((b) => b.expiry_date && daysBetween(today, b.expiry_date) <= 30)) return 'Expiring';
  if (q <= Number(it.reorder_floor)) return 'Low';
  return 'Healthy';
}

export function buildItems(inv: Inventory, loc: string): ItemView[] {
  const today = inv.today;
  const live = inv.batches.filter((b) => !b.quarantined && Number(b.qty_remaining) > 0);
  return inv.items.map((it) => {
    const qAll = sumQty(it);
    const q = loc === 'ALL' ? qAll : Number(it.qty?.[loc] || 0);
    const bs = live.filter((b) => b.item_id === it.id && (loc === 'ALL' || b.location_id === loc));
    const vel = velocity(it, today);
    const wac = it.wac == null ? null : Number(it.wac);
    const price = Number(it.price);
    const prevVel = Number(it.sold_prev30) / 30;
    const ref = it.last_sale_at || it.first_at;
    return {
      ...it, price, wac, q, qAll, vel, cover: vel > 0 ? q / vel : null,
      margin: wac != null && price > 0 ? ((price - wac) / price) * 100 : null,
      value: wac != null ? q * wac : null,
      status: statusOf(it, q, bs, today), batchesInScope: bs,
      trend: prevVel > 0.5 ? (vel - prevVel) / prevVel : null,
      lastSaleDays: ref ? daysBetween(toDayKey(ref), today) : null,
    };
  });
}

export function marginColor(m: number | null, threshold = 8): string {
  if (m == null) return '#9CA3AF';
  return m < 0 ? '#DC2626' : m < threshold ? '#C2410C' : '#15803D';
}

// ---------- batches ----------
export function batchWindow(b: Batch, today: string): { label: string; days: number | null; rule: string } {
  if (b.quarantined) return { label: 'Quarantined', days: b.expiry_date ? daysBetween(today, b.expiry_date) : null, rule: 'Out of sellable stock' };
  if (!b.expiry_date) return { label: 'OK', days: null, rule: '' };
  const d = daysBetween(today, b.expiry_date);
  if (d < 0) return { label: 'Expired', days: d, rule: 'Must leave sellable stock' };
  if (d <= 30) return { label: 'Expiring', days: d, rule: 'Promote · sells first (FEFO)' };
  if (d <= 90) return { label: 'Watch', days: d, rule: 'Watch · sell before newer batches' };
  return { label: 'OK', days: d, rule: '' };
}
export const daysLabel = (d: number | null) => d == null ? 'No expiry' : d < 0 ? 'Expired ' + -d + 'd ago' : d + ' days left';

// ---------- seasonality (category defaults until two cycles of own history exist) ----------
const RAMADAN: Record<number, [string, string]> = {
  2026: ['2026-02-18', '2026-03-22'], 2027: ['2027-02-08', '2027-03-12'], 2028: ['2028-01-28', '2028-03-01'],
  2029: ['2029-01-16', '2029-02-18'], 2030: ['2030-01-06', '2030-02-08'],
};
const overlaps = (a1: string, a2: string, b1: string, b2: string) => a1 <= b2 && b1 <= a2;
export function season(category: string, start: string, end: string): { mult: number; label: string | null } {
  const y = Number(start.slice(0, 4));
  const cat = category.toLowerCase();
  const festive = ['drinks', 'beverages', 'noodles', 'staples', 'breakfast', 'dairy'];
  for (const yy of [y, y + 1]) {
    if (festive.includes(cat) && overlaps(start, end, `${yy - 1}-12-01`, `${yy}-01-05`)) return { mult: 1.25, label: 'Detty December' };
    if (festive.includes(cat) && overlaps(start, end, `${yy}-12-01`, `${yy + 1}-01-05`)) return { mult: 1.25, label: 'Detty December' };
    const r = RAMADAN[yy];
    if (r && ['staples', 'drinks', 'beverages', 'dairy'].includes(cat) && overlaps(start, end, r[0], r[1])) return { mult: 1.15, label: 'Ramadan and Sallah' };
  }
  if (['noodles', 'breakfast', 'beverages', 'dairy'].includes(cat) && (overlaps(start, end, `${y}-09-01`, `${y}-09-21`) || overlaps(start, end, `${y}-01-06`, `${y}-01-20`)))
    return { mult: 1.1, label: 'Back-to-school' };
  return { mult: 1, label: null };
}

// ---------- FX ----------
export interface FxTrend { from: number; to: number; change: number; days: number; latestDay: string }
export function fxTrend(rows: { day: string; usd_ngn: number }[]): FxTrend | null {
  if (!rows || rows.length < 2) return null;
  const sorted = [...rows].sort((a, b) => a.day.localeCompare(b.day));
  const latest = sorted[sorted.length - 1];
  const target = addDays(latest.day, -7);
  const base = [...sorted].reverse().find((r) => r.day <= target) || sorted[0];
  if (base.day === latest.day) return null;
  return { from: Number(base.usd_ngn), to: Number(latest.usd_ngn), change: (Number(latest.usd_ngn) - Number(base.usd_ngn)) / Number(base.usd_ngn), days: daysBetween(base.day, latest.day), latestDay: latest.day };
}
export function fxBanner(fx: FxTrend | null, importNames: string[]): string | null {
  if (!fx || !importNames.length) return null;
  const pct = (fx.change * 100).toFixed(1);
  const names = importNames.slice(0, 3).join(', ') + (importNames.length > 3 ? ' and others' : '');
  const span = fx.days >= 6 ? 'this week' : `over ${fx.days} days`;
  const moved = `USD/NGN moved from ₦${Math.round(fx.from).toLocaleString('en-NG')} to ₦${Math.round(fx.to).toLocaleString('en-NG')} ${span} (${fx.change >= 0 ? '+' : ''}${pct}%).`;
  if (fx.change >= 0.01) return `${moved} Import-priced lines (${names}) will likely cost ${Math.max(1, Math.round(fx.change * 100))}–${Math.round(fx.change * 100) + 1}% more at the next restock, so ordering this week is favoured.`;
  if (fx.change <= -0.01) return `${moved} The naira is firming, so import-priced lines (${names}) may cost a little less next restock. If cover allows, waiting a week is reasonable.`;
  return `${moved} That is flat enough that timing gives no real advantage on import-priced lines (${names}).`;
}
export function fxItemNote(fx: FxTrend | null): string | null {
  if (!fx) return null;
  const pct = Math.abs(fx.change * 100).toFixed(1);
  if (fx.change >= 0.01) return `Import-priced. Naira weakened ${pct}% recently; ordering now is likely cheaper than waiting two weeks.`;
  if (fx.change <= -0.01) return `Import-priced. Naira firmed ${pct}% recently; prices may ease slightly if you can wait.`;
  return null;
}

// ---------- vendor scores (five explainable dimensions) ----------
export interface VendorStats {
  receipts: number; last_receipt_at: string | null; items: { item_id: string; avg_cost: number; min_cost: number; max_cost: number; n: number; cv: number }[];
  po_ordered: number; po_received: number; lead_days_measured: number | null;
}
export interface VendorScore {
  vendor: Vendor; total: number; landed: number; lead: number; leadDays: number; fill: number; fillPct: number; stability: number;
  stabilityLabel: string; credit: number; why: string; landedNote: string | null;
}
export function scoreVendors(vendors: Vendor[], stats: Record<string, VendorStats> | undefined, items: Item[]): Record<string, VendorScore> {
  const out: Record<string, VendorScore> = {};
  const nameOf = (id: string) => items.find((i) => i.id === id)?.name?.split(' ').slice(0, 2).join(' ') || 'an item';
  // cheapest average cost per item across vendors
  const best: Record<string, { cost: number; vendor: string }> = {};
  for (const v of vendors) for (const s of stats?.[v.id]?.items || []) {
    if (!best[s.item_id] || s.avg_cost < best[s.item_id].cost) best[s.item_id] = { cost: Number(s.avg_cost), vendor: v.id };
  }
  for (const v of vendors) {
    const st = stats?.[v.id];
    const leadDays = st?.lead_days_measured != null ? Number(st.lead_days_measured) : v.lead_time_days;
    const lead = Math.max(40, 100 - 8 * leadDays);
    const fillPct = st && Number(st.po_ordered) > 0 ? Math.min(100, (Number(st.po_received) / Number(st.po_ordered)) * 100) : v.fill_rate != null ? Number(v.fill_rate) : 90;
    const cvs = (st?.items || []).filter((x) => x.n > 1).map((x) => Number(x.cv));
    const cv = cvs.length ? cvs.reduce((a, b) => a + b, 0) / cvs.length : null;
    const stabilityLabel = cv != null ? (cv < 0.02 ? 'High' : cv < 0.05 ? 'Medium' : 'Low') : v.price_stability || 'Medium';
    const stability = stabilityLabel === 'High' ? 95 : stabilityLabel === 'Medium' ? 75 : 50;
    const cd = v.credit_days;
    const credit = cd >= 30 ? 100 : cd >= 14 ? 85 : cd >= 7 ? 70 : cd > 0 ? 55 : 40;
    let landed = 85; let landedNote: string | null = null; let landedWin: string | null = null; let landedLose: string | null = null;
    const mine = st?.items || [];
    const compared = mine.filter((s) => best[s.item_id]);
    if (compared.length) {
      const idx = compared.map((s) => (best[s.item_id].cost / Number(s.avg_cost)) * 100);
      landed = Math.round(idx.reduce((a, b) => a + b, 0) / idx.length);
      const win = compared.find((s) => best[s.item_id].vendor === v.id && mine.length);
      if (win) { landedWin = 'lowest landed price on ' + nameOf(win.item_id); landedNote = 'Lowest for ' + nameOf(win.item_id); }
      const lose = compared.find((s) => best[s.item_id].vendor !== v.id && Number(s.avg_cost) > best[s.item_id].cost * 1.02);
      if (lose) landedLose = 'pricier than the best alternative on ' + nameOf(lose.item_id);
    }
    const total = Math.round(0.3 * landed + 0.2 * lead + 0.2 * fillPct + 0.15 * stability + 0.15 * credit);
    const strengths: string[] = []; const weak: string[] = [];
    if (landedWin) strengths.push(landedWin);
    if (leadDays === 0) strengths.push('same-day supply'); else if (leadDays <= 1) strengths.push('next-day delivery'); else if (leadDays >= 3) weak.push(`a ${leadDays}-day lead time`);
    if (fillPct >= 97) strengths.push(`${Math.round(fillPct)}% fill rate${st?.receipts ? ` across ${st.receipts} invoice${st.receipts === 1 ? '' : 's'}` : ''}`); else if (fillPct < 92) weak.push(`a ${Math.round(fillPct)}% fill rate`);
    if (stabilityLabel === 'High') strengths.push('stable prices'); else if (stabilityLabel === 'Low') weak.push('prices that move often');
    if (cd >= 14) strengths.push(`${cd}-day credit`); else if (cd === 0) weak.push('no credit');
    if (landedLose) weak.push(landedLose);
    const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
    let why = strengths.length ? cap(listJoin(strengths.slice(0, 3))) + '.' : 'Scores sit close to average across all five measures.';
    if (weak.length) why += ' Held back by ' + listJoin(weak.slice(0, 2)) + '.';
    out[v.id] = { vendor: v, total, landed, lead, leadDays, fill: fillPct, fillPct, stability, stabilityLabel, credit, why, landedNote };
  }
  return out;
}
export function listJoin(a: string[]): string {
  if (a.length <= 1) return a.join('');
  return a.slice(0, -1).join(', ') + ' and ' + a[a.length - 1];
}

// ---------- reorder suggestions ----------
export interface Suggestion {
  item: ItemView; onHand: number; floor: number; vel: number; leadDays: number; vendor: Vendor | null; alt: Vendor | null;
  qtyPU: number; qtySU: number; unitCostPU: number | null; cost: number | null; cover: number; tone: 'red' | 'amber' | 'blue';
  reason: string; fx: string | null; capped: boolean; seasonLabel: string | null;
}
export function reorderSuggestions(inv: Inventory, items: ItemView[], openPOs: PurchaseOrder[], fx: FxTrend | null): Suggestion[] {
  const today = inv.today;
  const vendors = new Map(inv.vendors.map((v) => [v.id, v]));
  const onOrder = new Set(openPOs.filter((p) => p.status === 'draft' || p.status === 'sent').flatMap((p) => p.po_lines.map((l) => l.item_id)));
  const out: Suggestion[] = [];
  let cashLeft = inv.org.cash_available != null ? Number(inv.org.cash_available) : null;
  const ranked = [...items].filter((i) => i.vel > 0).sort((a, b) => (a.cover ?? 999) - (b.cover ?? 999));
  for (const it of ranked) {
    if (onOrder.has(it.id)) continue;
    if (it.snoozed_until && it.snoozed_until >= today) continue;
    const vendor = it.preferred_vendor_id ? vendors.get(it.preferred_vendor_id) || null : null;
    const alt = it.alt_vendor_id ? vendors.get(it.alt_vendor_id) || null : null;
    const lead = vendor?.lead_time_days ?? 2;
    const safety = Number(inv.org.safety_days);
    const s = season(it.category, today, addDays(today, lead + Number(inv.org.cover_days)));
    const vel = it.vel;
    const floor = Number(it.reorder_floor);
    const onHand = it.qAll;
    const reorderPoint = floor + vel * (lead + safety) * s.mult;
    if (onHand > reorderPoint) continue;
    const target = floor + vel * (lead + Number(inv.org.cover_days)) * s.mult;
    let qtyPU = Math.max(1, Math.ceil((target - onHand) / it.pack_size));
    const unitCostSU = it.last_cost ?? it.wac;
    const unitCostPU = unitCostSU != null ? Number(unitCostSU) * it.pack_size : null;
    let capped = false;
    if (cashLeft != null && unitCostPU) {
      const affordable = Math.floor(cashLeft / unitCostPU);
      if (affordable < qtyPU) { qtyPU = Math.max(1, affordable); capped = true; }
      cashLeft = Math.max(0, cashLeft - qtyPU * unitCostPU);
    }
    const cover = vel > 0 ? onHand / vel : 0;
    const days = vel > 0 ? Math.max(0, (onHand - floor) / vel) : 0;
    const su = pluralUnit(it.selling_unit, 2);
    const leadPhrase = !vendor ? 'no preferred vendor yet' : lead === 0 ? `${vendor.name} supplies same day` : lead === 1 ? `${vendor.name.split(' ')[0]} delivers next day` : `${vendor.name.split(' ')[0]} takes ${lead} days`;
    const parts: string[] = [];
    if (onHand <= floor) parts.push('Below reorder floor.');
    else parts.push(`Will cross the floor in ~${Math.max(1, Math.round(days))} day${Math.round(days) === 1 ? '' : 's'}.`);
    parts.push(`${fq(Math.round(vel * 10) / 10)} ${su}/day; ${leadPhrase}.`);
    const exp = it.batchesInScope.filter((b) => b.expiry_date && daysBetween(today, b.expiry_date) >= 0 && daysBetween(today, b.expiry_date) <= 30)
      .sort((a, b) => (a.expiry_date! < b.expiry_date! ? -1 : 1))[0];
    if (exp) parts.push(`Batch ${exp.batch_no} (${fq(Number(exp.qty_remaining))} ${su}) expires in ${daysBetween(today, exp.expiry_date!)} days and should sell first.`);
    if (it.trend != null && it.trend >= 0.1) parts.push(`Sales are up ${Math.round(it.trend * 100)}% on the previous 30 days.`);
    if (s.label) parts.push(`${s.label} usually lifts demand; sized for it.`);
    parts.push(`Sized for ${inv.org.cover_days} days of cover.`);
    if (capped) parts.push('Capped by the cash you have set aside for stock.');
    out.push({
      item: it, onHand, floor, vel, leadDays: lead, vendor, alt, qtyPU, qtySU: qtyPU * it.pack_size, unitCostPU,
      cost: unitCostPU != null ? qtyPU * unitCostPU : null, cover,
      tone: onHand <= floor || cover < lead + safety ? 'red' : s.label && onHand > floor + vel * lead ? 'blue' : 'amber',
      reason: parts.join(' '), fx: it.import_priced ? fxItemNote(fx) : null, capped, seasonLabel: s.label,
    });
  }
  return out;
}

// ---------- dead stock ----------
export interface DeadRow { item: ItemView; days: number; carrying: number | null; mark: number; mOld: number | null; mNew: number | null; clearWeeks: number }
export function deadStock(items: ItemView[]): DeadRow[] {
  const byCat: Record<string, number[]> = {};
  for (const i of items) (byCat[i.category] ||= []).push(i.vel);
  return items.filter((i) => i.status === 'Dead').map((i) => {
    const wac = i.wac;
    let mark = wac != null ? Math.ceil((wac * 1.02) / 50) * 50 : Math.round((i.price * 0.88) / 50) * 50;
    if (mark >= i.price * 0.96) mark = Math.floor((i.price * 0.9) / 50) * 50;
    if (wac != null && mark < wac) mark = Math.ceil(wac / 10) * 10;
    const catVel = (byCat[i.category] || []).filter((v) => v > 0);
    const avg = catVel.length ? catVel.reduce((a, b) => a + b, 0) / catVel.length : 1;
    const perDay = Math.max(0.5, avg * 0.2);
    return {
      item: i, days: i.lastSaleDays ?? 90, carrying: i.value, mark,
      mOld: i.margin, mNew: wac != null ? ((mark - wac) / mark) * 100 : null,
      clearWeeks: Math.min(12, Math.max(2, Math.ceil(i.q / perDay / 7))),
    };
  });
}

// ---------- cash vs stock (Numens) ----------
export interface DayImplied { day: string; location_id: string; implied: number; authors: string[] | null }
export interface DayRecorded { day: string; location_id: string; recorded: number; cash: number; pos: number; transfers: number; source: string }
export interface WeekRow { label: string; start: string; end: string; implied: number; recorded: number; gap: number; gapPct: number; complete: boolean }
export interface CashStory {
  hasTakings: boolean; weeks: WeekRow[]; headline: string | null; pattern: string | null; tone: 'red' | 'green' | 'amber' | 'grey';
  title: string; location: Location | null; weekday: string | null; names: string[]; gap: number; weekLabel: string | null;
}
const weekLabel = (start: string, end: string) => {
  const s = new Date(start + 'T12:00:00Z'); const e = new Date(end + 'T12:00:00Z');
  const sm = s.toLocaleDateString('en-GB', { month: 'short', timeZone: 'UTC' }); const em = e.toLocaleDateString('en-GB', { month: 'short', timeZone: 'UTC' });
  return sm === em ? `${s.getUTCDate()}–${e.getUTCDate()} ${em}` : `${s.getUTCDate()} ${sm}–${e.getUTCDate()} ${em}`;
};
export function cashVsStock(data: { implied: DayImplied[]; recorded: DayRecorded[] } | undefined, locations: Location[], loc: string, today: string): CashStory {
  const empty: CashStory = { hasTakings: false, weeks: [], headline: null, pattern: null, tone: 'grey', title: 'Cash vs stock', location: null, weekday: null, names: [], gap: 0, weekLabel: null };
  if (!data) return empty;
  const imp = data.implied.filter((r) => loc === 'ALL' || r.location_id === loc);
  const rec = data.recorded.filter((r) => loc === 'ALL' || r.location_id === loc);
  if (!rec.length) return { ...empty, hasTakings: false };
  let end = addDays(today, -1);
  while (isoDow(end) !== 7) end = addDays(end, -1);
  const weeks: WeekRow[] = [];
  for (let w = 3; w >= 0; w--) {
    const e = addDays(end, -7 * w); const s = addDays(e, -6);
    const days = (r: { day: string }) => r.day >= s && r.day <= e;
    const implied = imp.filter(days).reduce((a, r) => a + Number(r.implied), 0);
    const recDays = rec.filter(days);
    const recorded = recDays.reduce((a, r) => a + Number(r.recorded), 0);
    const daysWithSales = new Set(imp.filter(days).map((r) => r.day + r.location_id)).size;
    weeks.push({ label: weekLabel(s, e), start: s, end: e, implied, recorded, gap: implied - recorded, gapPct: implied ? ((implied - recorded) / implied) * 100 : 0, complete: recDays.length >= daysWithSales * 0.7 });
  }
  const last = weeks[weeks.length - 1];
  const out: CashStory = { ...empty, hasTakings: true, weeks, weekLabel: last.label };
  if (!last.implied) { out.headline = 'No sales were recorded last week, so there is nothing to compare yet.'; return out; }
  // where does the gap sit?
  const locGaps = locations.map((l) => {
    const li = imp.filter((r) => r.location_id === l.id && r.day >= last.start && r.day <= last.end);
    const lr = rec.filter((r) => r.location_id === l.id && r.day >= last.start && r.day <= last.end);
    const gap = li.reduce((a, r) => a + Number(r.implied), 0) - lr.reduce((a, r) => a + Number(r.recorded), 0);
    return { l, gap };
  }).filter((x) => loc === 'ALL' || x.l.id === loc).sort((a, b) => b.gap - a.gap);
  const worst = locGaps[0];
  out.location = worst?.l || null;
  const dayGaps = (start: string, stop: string, locId: string) => {
    const days: Record<string, number> = {};
    for (const r of imp) if (r.location_id === locId && r.day >= start && r.day <= stop) days[r.day] = (days[r.day] || 0) + Number(r.implied);
    for (const r of rec) if (r.location_id === locId && r.day >= start && r.day <= stop && days[r.day] != null) days[r.day] -= Number(r.recorded);
    return Object.entries(days).sort((a, b) => b[1] - a[1]);
  };
  out.gap = last.gap;
  const pct = Math.abs(last.gapPct);
  if (last.gap <= 0 || pct < 0.5) {
    if (last.gap < 0 && pct >= 0.5) {
      out.tone = 'amber'; out.title = `Recorded takings ran ahead · ${last.label}`;
      out.headline = `Recorded takings for ${last.label} came to ${N(last.recorded)}, which is ${N(-last.gap)} more than stock movements imply. That usually means items left the shelf without being recorded as sales.`;
    } else {
      out.tone = 'green'; out.title = `Takings matched · ${last.label}`;
      out.headline = `Stock movements and recorded takings for ${last.label} agree within ${P(pct)}. Nothing to chase this week.`;
    }
    return out;
  }
  out.tone = 'red';
  out.title = `Numens · week of ${last.label}${worst ? ' · ' + worst.l.name : ''}`;
  let where = 'is spread across the week';
  let topDay: string | null = null;
  if (worst && worst.gap > 0) {
    const dg = dayGaps(last.start, last.end, worst.l.id);
    if (dg.length) {
      topDay = dg[0][0];
      const share = dg[0][1] / Math.max(1, last.gap);
      const dayName = `${weekday(topDay)} ${fmtDay(topDay, false).replace(/^0/, '')}`;
      if (share >= 0.6) where = `sits almost entirely on ${dayName}${locGaps.length > 1 ? ' at ' + worst.l.name : ''}`;
      else if (share >= 0.4) where = `is mostly on ${dayName}${locGaps.length > 1 ? ' at ' + worst.l.name : ''}`;
    }
  }
  out.headline = `Stock movements say you sold ${N(last.implied)} last week. Cash and POS settlements came to ${N(last.recorded)}. The ${N(last.gap)} gap ${where}.`;
  // pattern: same weekday tops the gap at this branch for the last four weeks
  if (worst && topDay) {
    const dow = isoDow(topDay);
    const hits: { day: string; gap: number }[] = [];
    for (const w of weeks) {
      const dg = dayGaps(w.start, w.end, worst.l.id);
      if (dg.length && isoDow(dg[0][0]) === dow && dg[0][1] >= 20000) hits.push({ day: dg[0][0], gap: dg[0][1] });
      else break;
    }
    if (hits.length >= 4 || (hits.length === weeks.length && hits.length >= 3)) {
      const wd = weekday(topDay);
      const lo = Math.min(...hits.map((h) => h.gap)); const hi = Math.max(...hits.map((h) => h.gap));
      const authorSets = hits.map((h) => new Set(imp.filter((r) => r.day === h.day && r.location_id === worst.l.id).flatMap((r) => r.authors || [])));
      const names = [...authorSets[0]].filter((n) => authorSets.every((s) => s.has(n)));
      out.weekday = wd; out.names = names;
      const ord = ['', 'first', 'second', 'third', 'fourth', 'fifth', 'sixth'][hits.length] || hits.length + 'th';
      out.pattern = `This is the ${ord} ${wd} in a row with a ${K(lo).replace('₦', '₦')}–${K(hi).replace('₦', '')} shortfall at ${worst.l.name}. That pattern points at cash sales going unrecorded or pilferage on the ${wd} shift, not at a one-off miscount.` +
        (names.length ? ` ${listJoin(names.map(shortName))} ${names.length === 1 ? 'was' : 'were'} on that shift each time.` : '');
    }
  }
  return out;
}

// ---------- misc ----------
export function pct(n: number, d: number) { return d ? Math.max(0, Math.min(100, Math.round((n / d) * 100))) : 0; }
export function channelSentence(v: Vendor | null): string {
  if (!v) return '—';
  return v.channel === 'whatsapp' ? 'WhatsApp' : v.channel === 'email' ? 'Email' : 'Phone';
}
export function poMessage(opts: { org: string; ref: string; vendor: string; lines: { name: string; qty: number; unit: string; unitCost?: number | null }[]; total?: number | null; branch?: string | null }): string {
  const lines = opts.lines.map((l) => `• ${l.qty} ${pluralUnit(l.unit.toLowerCase(), l.qty)} ${l.name}${l.unitCost ? ` @ ${N(l.unitCost)}` : ''}`).join('\n');
  return `Hello ${opts.vendor},\n\nPurchase order ${opts.ref} from ${opts.org}${opts.branch ? ' (' + opts.branch + ')' : ''}:\n${lines}${opts.total ? `\n\nTotal: ${N(opts.total)}` : ''}\n\nPlease confirm availability and delivery date. Thank you.`;
}
export function waLink(phone: string | null | undefined, text: string): string {
  const p = (phone || '').replace(/[^0-9]/g, '').replace(/^0/, '234');
  return `https://wa.me/${p}?text=${encodeURIComponent(text)}`;
}
