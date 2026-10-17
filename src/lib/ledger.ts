import type { LedgerRow, Location } from './types';
import { puAbbr, suAbbr } from './domain';
import { shortName } from './format';

const TYPE: Record<string, [string, string]> = {
  opening: ['Opening', 'grey'], receipt: ['Receipt', 'blue'], sale: ['Sale', 'grey'], voice_sale: ['Voice', 'grey'],
  transfer_out: ['Transfer', 'purple'], transfer_in: ['Transfer', 'purple'], adjustment: ['Adjustment', 'amber'],
  quarantine: ['Quarantine', 'red'], write_off: ['Write-off', 'red'],
  issue: ['Issued', 'orange'], issue_return: ['Returned', 'orange'], production_in: ['Produced', 'green'],
};
export const typeLabel = (t: string) => TYPE[t]?.[0] || t;
export const typeTone = (t: string) => 't-' + (TYPE[t]?.[1] || 'grey');

const fq = (n: number) => Math.abs(n).toLocaleString('en-NG', { maximumFractionDigits: 3 });

export function moveQty(m: Pick<LedgerRow, 'qty' | 'pack_size' | 'purchase_unit' | 'selling_unit' | 'n' | 'type' | 'n_items'>): string {
  const q = Number(m.qty);
  const sign = q > 0 ? '+' : q < 0 ? '−' : '';
  if (m.n > 1 && m.n_items > 1) {
    if (m.type === 'receipt' || m.type === 'opening') return `+${m.n} lines`;
    return `${sign}${fq(q)} units`;
  }
  const su = suAbbr(m.selling_unit);
  const a = Math.abs(q);
  if (m.pack_size > 1 && a >= m.pack_size) {
    const c = Math.floor(a / m.pack_size); const r = Math.round((a - c * m.pack_size) * 1000) / 1000;
    return `${sign}${c.toLocaleString('en-NG')} ${puAbbr(m.purchase_unit)}${r ? ' + ' + fq(r) : ''} (${fq(a)} ${su})`;
  }
  return `${sign}${fq(a)} ${su}`;
}

export function moveItem(m: LedgerRow): string {
  if (m.n > 1 && m.n_items > 1) {
    if (m.type === 'receipt') return `${m.vendor_name || 'Receipt'} · ${m.n} lines`;
    if (m.type === 'opening') return `Opening stock · ${m.n} items`;
    if (m.type === 'sale') return `${m.n} items (day close)`;
    return `${m.n} items`;
  }
  return m.item_name;
}

export function moveRef(m: LedgerRow, locs: Location[]): string {
  const j = m.journal_ref ? m.journal_ref + ' · ' : '';
  switch (m.type) {
    case 'receipt': return j + (m.vendor_name || m.journal_memo || 'Receipt') + (m.channel === 'Photo + OCR' ? ' · handwritten invoice' : '');
    case 'sale': return m.n > 1 ? `COGS posted · ${m.journal_ref}` : j + (m.channel || 'Sale');
    case 'voice_sale': return (m.note || 'Voice entry') + (m.review_status === 'pending' ? ' · awaiting owner review' : ' · owner reviewed');
    case 'transfer_out': return j + (m.note || 'Transfer') + ' · out';
    case 'transfer_in': return j + (m.note || 'Transfer received');
    case 'adjustment': return j + (m.journal_memo?.replace(/^Count /, 'Count ') || 'Adjustment') ;
    case 'quarantine': return j + (m.note || 'Out of sellable stock');
    case 'opening': return j + (m.journal_memo || 'Opening balance');
    case 'issue': case 'issue_return': case 'production_in': return j + (m.journal_memo || '');
    default: return j + (m.journal_memo || '');
  }
}

export function moveBy(m: LedgerRow, locs: Location[]): string {
  const loc = locs.find((l) => l.id === m.location_id)?.name || '';
  return `${m.author_name ? shortName(m.author_name) : 'System'}${loc ? ' · ' + loc : ''}`;
}
