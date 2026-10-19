// Periods for every data screen: ready-made choices (this month, last quarter, last year...) and any two dates. Each
// screen remembers its own last choice for each business; a ready-made choice moves with the calendar ("this month"
// stays this month), dates typed in stay as typed.
import { useCallback, useEffect, useState } from 'react';
import { lastMonthEnd, monthStart, today, yearStart } from './api';
import { addDays, fmtDay } from './format';

export type Period = { from: string; to: string };
export type PresetId = 'today' | 'week' | 'l30' | 'mtd' | 'lm' | 'qtd' | 'lq' | 'ytd' | 'ly' | 'l12' | 'all';
export type PeriodValue = Period & { preset?: PresetId | null };

// The earliest day "All dates" reaches. Counta keeps books and files returns from January 2023; older records still show.
export const ALL_FROM = '2000-01-01';
export const BOOKS_FLOOR = '2023-01-01';

export const PRESET_ORDER: PresetId[] = ['today', 'week', 'mtd', 'lm', 'qtd', 'lq', 'ytd', 'ly', 'l12', 'all'];
// Lists that work in rolling days also offer the last 30.
export const ROLLING: PresetId[] = ['today', 'week', 'l30', 'mtd', 'lm', 'qtd', 'lq', 'ytd', 'ly', 'l12'];

const addMonthsTo = (day: string, n: number) => {
  const d = new Date(day.slice(0, 8) + '01T12:00:00Z');
  d.setUTCMonth(d.getUTCMonth() + n);
  return d.toISOString().slice(0, 10);
};
const monthEnd = (day: string) => addDays(addMonthsTo(day, 1), -1);

export function presetLabel(id: PresetId, fy = 1): string {
  const fin = fy !== 1;
  return {
    today: 'Today', week: 'This week', l30: 'Last 30 days', mtd: 'This month', lm: 'Last month', qtd: 'This quarter', lq: 'Last quarter',
    ytd: fin ? 'This financial year' : 'This year', ly: fin ? 'Last financial year' : 'Last year', l12: 'Last 12 months', all: 'All dates',
  }[id];
}

export function presetRange(id: PresetId, fy = 1, t = today()): Period {
  switch (id) {
    case 'today': return { from: t, to: t };
    case 'week': {
      const dow = (new Date(t + 'T12:00:00Z').getUTCDay() + 6) % 7; // Monday first
      return { from: addDays(t, -dow), to: t };
    }
    case 'l30': return { from: addDays(t, -29), to: t };
    case 'mtd': return { from: monthStart(t), to: t };
    case 'lm': { const e = lastMonthEnd(t); return { from: monthStart(e), to: e }; }
    case 'qtd': {
      const q = Math.floor((Number(t.slice(5, 7)) - 1) / 3) * 3 + 1;
      return { from: `${t.slice(0, 4)}-${String(q).padStart(2, '0')}-01`, to: t };
    }
    case 'lq': {
      const q = Math.floor((Number(t.slice(5, 7)) - 1) / 3) * 3 + 1;
      const thisQ = `${t.slice(0, 4)}-${String(q).padStart(2, '0')}-01`;
      const from = addMonthsTo(thisQ, -3);
      return { from, to: addDays(thisQ, -1) };
    }
    case 'ytd': return { from: yearStart(t, fy), to: t };
    case 'ly': { const ys = yearStart(t, fy); return { from: yearStart(addDays(ys, -1), fy), to: addDays(ys, -1) }; }
    case 'l12': return { from: addMonthsTo(monthStart(t), -11), to: t };
    case 'all': return { from: ALL_FROM, to: t };
  }
}

// "This month · 1 to 19 Oct 2026", "1 Mar 2023 to 30 Jun 2023", "All dates".
export function periodText(v: PeriodValue, fy = 1): string {
  if (v.preset === 'all') return presetLabel('all', fy);
  const same = v.from === v.to;
  const sameYear = v.from.slice(0, 4) === v.to.slice(0, 4);
  const range = same ? fmtDay(v.from) : `${fmtDay(v.from, !sameYear)} to ${fmtDay(v.to)}`;
  return v.preset ? `${presetLabel(v.preset, fy)} · ${range}` : range;
}

// The months a period covers, as the first day of each, for screens that work month by month.
export const monthsOf = (v: Period): { from: string; to: string } => ({ from: monthStart(v.from), to: monthEnd(v.to) });

type Stored = { p?: PresetId; from?: string; to?: string };
const keyOf = (org: string | null, screen: string) => `counta.period.${org || 'none'}.${screen}`;
const validDay = (d: unknown): d is string => typeof d === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(d);

export function readPeriod(org: string | null, screen: string, def: PresetId, fy = 1): PeriodValue {
  let s: Stored | null = null;
  try { s = JSON.parse(localStorage.getItem(keyOf(org, screen)) || 'null'); } catch { s = null; }
  if (s?.p && (PRESET_ORDER.includes(s.p) || s.p === 'l30')) return { ...presetRange(s.p, fy), preset: s.p };
  if (s && validDay(s.from) && validDay(s.to) && s.from <= s.to) return { from: s.from, to: s.to, preset: null };
  return { ...presetRange(def, fy), preset: def };
}

export function writePeriod(org: string | null, screen: string, v: PeriodValue) {
  try { localStorage.setItem(keyOf(org, screen), JSON.stringify(v.preset ? { p: v.preset } : { from: v.from, to: v.to })); } catch { /* private mode */ }
}

// A screen's period, remembered for this business on this device.
export function useScreenPeriod(org: string | null, screen: string, def: PresetId = 'mtd', fy = 1): [PeriodValue, (v: PeriodValue) => void] {
  const [v, setV] = useState<PeriodValue>(() => readPeriod(org, screen, def, fy));
  useEffect(() => { setV(readPeriod(org, screen, def, fy)); }, [org, screen, def, fy]);
  const set = useCallback((n: PeriodValue) => { setV(n); writePeriod(org, screen, n); }, [org, screen]);
  return [v, set];
}

// The period just before, of the same length, for comparisons.
export function previousPeriod(v: Period): Period {
  const days = Math.round((Date.parse(v.to) - Date.parse(v.from)) / 86400000) + 1;
  // A whole month compares with the whole month before it.
  if (v.from === monthStart(v.from) && v.to === monthEnd(v.from)) { const f = addMonthsTo(v.from, -1); return { from: f, to: monthEnd(f) }; }
  return { from: addDays(v.from, -days), to: addDays(v.from, -1) };
}
