// How far back a bank feed reaches and in what steps. Kept apart from index.ts so it can be tested on its own.
export type HistoryState = { last_line_date?: string | null; history_to?: string | null; history_done?: boolean | null; books_start?: string | null };

// Counta keeps books and files returns from January 2023, so an account's history is asked for back to then (or to the
// date the books start, if later). Banks decide how much internet-banking history they hand over; whatever is older than
// what arrives comes from uploaded statements.
export const HISTORY_FLOOR = '2023-01-01';
const DAY = 86400_000;
const WINDOW_DAYS = 92;
export const isDay = (d: unknown): d is string => typeof d === 'string' && /^\d{4}-\d{2}-\d{2}/.test(d);
const utcDay = (d: string) => new Date(Date.parse(d.slice(0, 10) + 'T00:00:00Z'));
// Where a fetch starts: while the history is still being walked, where the walk reached (or the floor); afterwards three
// days before the newest line seen, since banks post late.
export function fetchStart(a: HistoryState, now = new Date()): { from: Date; history: boolean } {
  if (a.history_done) {
    const from = isDay(a.last_line_date) ? new Date(utcDay(a.last_line_date).getTime() - 3 * DAY) : new Date(now.getTime() - 3 * DAY);
    return { from, history: false };
  }
  if (isDay(a.history_to)) return { from: new Date(utcDay(a.history_to).getTime() + DAY), history: true };
  const floor = utcDay(HISTORY_FLOOR);
  const books = isDay(a.books_start) ? utcDay(a.books_start) : null;
  return { from: books && books > floor ? books : floor, history: true };
}
// The windows a fetch walks through, oldest first, each at most WINDOW_DAYS long.
export function windows(from: Date, to: Date): { from: Date; to: Date }[] {
  const out: { from: Date; to: Date }[] = [];
  for (let s = from.getTime(); s <= to.getTime(); s += WINDOW_DAYS * DAY) out.push({ from: new Date(s), to: new Date(Math.min(s + (WINDOW_DAYS - 1) * DAY, to.getTime())) });
  return out;
}

