// The VAT rate, from TaxStreem's rule book (set in the admin portal). Rates are dated: a document uses the rate on its own
// date, so an invoice from before a change keeps the rate it had. The database works VAT out the same way; these are for
// figures shown before something is saved, and for labels.
import { useQuery } from '@tanstack/react-query';
import { supabase } from './supabase';
import { lagosToday } from './format';

const DEFAULT = 0.075;
// Newest first.
let history: { from: string; value: number }[] = [];

export function vatRateOn(day?: string | null): number {
  const d = (day || lagosToday()).slice(0, 10);
  for (const h of history) if (h.from <= d) return h.value;
  return DEFAULT;
}
// "7.5%"
export function vatPct(day?: string | null): string {
  return `${Math.round(vatRateOn(day) * 100 * 100) / 100}%`;
}
// VAT inside a VAT-inclusive amount.
export const vatInside = (gross: number, day?: string | null) => { const r = vatRateOn(day); return gross - gross / (1 + r); };

async function load() {
  const { data } = await supabase.from('tax_rules').select('effective_from, value').eq('key', 'vat_rate').order('effective_from', { ascending: false });
  history = (data || []).map((r: any) => ({ from: String(r.effective_from), value: Number(r.value) })).filter((r) => r.value > 0);
  return history;
}

// Screens that show a VAT figure or label call this so they redraw once the rule book has loaded.
export function useVatRate() {
  const q = useQuery({ queryKey: ['vat-rates'], queryFn: load, staleTime: 30 * 60_000 });
  return { ready: q.isSuccess, rate: vatRateOn(), on: vatRateOn, pct: vatPct, version: q.dataUpdatedAt };
}
