// Money, numbers and dates in the TaxStreem house style.

export function N(n: number | null | undefined): string {
  if (n === null || n === undefined || Number.isNaN(n)) return '—';
  const v = Math.round(n);
  return (v < 0 ? '−' : '') + '₦' + Math.abs(v).toLocaleString('en-NG');
}
export function N2(n: number | null | undefined): string {
  if (n === null || n === undefined || Number.isNaN(n)) return '—';
  const neg = n < 0;
  return (neg ? '−' : '') + '₦' + Math.abs(n).toLocaleString('en-NG', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}
export function K(n: number | null | undefined): string {
  if (n === null || n === undefined || Number.isNaN(n)) return '—';
  const a = Math.abs(n);
  const s = a >= 1e9 ? (a / 1e9).toFixed(2) + 'B' : a >= 1e6 ? (a / 1e6).toFixed(2) + 'M' : a >= 1e3 ? (a / 1e3).toFixed(a >= 1e5 ? 0 : 1) + 'k' : String(Math.round(a));
  return (n < 0 ? '−' : '') + '₦' + s;
}
export function P(n: number | null | undefined): string {
  if (n === null || n === undefined || !Number.isFinite(n)) return '—';
  return (Math.round(n * 10) / 10).toFixed(1) + '%';
}
export function num(n: number | null | undefined, dp = 0): string {
  if (n === null || n === undefined || Number.isNaN(n)) return '—';
  return Number(n).toLocaleString('en-NG', { maximumFractionDigits: dp });
}
export function signed(n: number): string {
  if (n === 0) return '—';
  return (n > 0 ? '+' : '−') + Math.abs(n).toLocaleString('en-NG', { maximumFractionDigits: 3 });
}

const TZ = 'Africa/Lagos';
const dayKey = (d: Date) => d.toLocaleDateString('en-CA', { timeZone: TZ });

export function lagosToday(): string { return dayKey(new Date()); }
export function toDayKey(iso: string | Date): string { return dayKey(typeof iso === 'string' ? new Date(iso) : iso); }
export function daysBetween(a: string, b: string): number {
  return Math.round((Date.parse(b + 'T00:00:00Z') - Date.parse(a + 'T00:00:00Z')) / 86400000);
}
export function addDays(day: string, n: number): string {
  const d = new Date(day + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10);
}
export function fmtDay(day: string | null | undefined, withYear = true): string {
  if (!day) return '—';
  const d = new Date(day.length === 10 ? day + 'T12:00:00Z' : day);
  return d.toLocaleDateString('en-GB', { day: '2-digit', month: 'short', ...(withYear ? { year: 'numeric' } : {}), timeZone: day.length === 10 ? 'UTC' : TZ });
}
export function fmtTime(iso: string): string {
  return new Date(iso).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', timeZone: TZ });
}
export function when(iso: string | null | undefined): string {
  if (!iso) return '—';
  const k = toDayKey(iso); const today = lagosToday();
  const diff = daysBetween(k, today);
  if (diff === 0) return 'Today · ' + fmtTime(iso);
  if (diff === 1) return 'Yesterday · ' + fmtTime(iso);
  return fmtDay(k, false) + ' · ' + fmtTime(iso);
}
export function weekday(day: string): string {
  return new Date(day + 'T12:00:00Z').toLocaleDateString('en-GB', { weekday: 'long', timeZone: 'UTC' });
}
export function isoDow(day: string): number { const d = new Date(day + 'T12:00:00Z').getUTCDay(); return d === 0 ? 7 : d; }
export function initials(name: string): string {
  const parts = name.replace(/[^A-Za-z0-9 ]/g, ' ').trim().split(/\s+/).filter(Boolean);
  if (!parts.length) return '··';
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[1][0]).toUpperCase();
}
export function shortName(name: string): string {
  const parts = name.trim().split(/\s+/);
  if (parts.length < 2) return name;
  return parts[0] + ' ' + parts[1][0] + '.';
}
export function plural(n: number, one: string, many?: string): string {
  return n + ' ' + (n === 1 ? one : many ?? one + 's');
}
export function uuid(): string {
  if (typeof crypto !== 'undefined' && 'randomUUID' in crypto) return crypto.randomUUID();
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0; return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
  });
}

// Font size for a headline figure on a tile, so long amounts stay on one line.
export function kpiFont(v: string): number {
  return v.length > 16 ? 16 : v.length > 14 ? 18 : v.length > 12 ? 20 : 22;
}

// "One million, two hundred and five thousand naira and fifty kobo only", the way Nigerian invoices and cheques write amounts.
const ONES = ['', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen',
  'sixteen', 'seventeen', 'eighteen', 'nineteen'];
const TENS = ['', '', 'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety'];
function under1000(n: number): string {
  const h = Math.floor(n / 100), r = n % 100;
  const rest = r < 20 ? ONES[r] : TENS[Math.floor(r / 10)] + (r % 10 ? '-' + ONES[r % 10] : '');
  return [h ? ONES[h] + ' hundred' : '', rest].filter(Boolean).join(h && rest ? ' and ' : '');
}
export function wholeWords(n: number): string {
  n = Math.floor(Math.abs(n));
  if (n === 0) return 'zero';
  const scales = ['', ' thousand', ' million', ' billion', ' trillion'];
  const parts: string[] = [];
  let i = 0;
  while (n > 0 && i < scales.length) {
    const chunk = n % 1000;
    if (chunk) parts.unshift(under1000(chunk) + scales[i]);
    n = Math.floor(n / 1000); i++;
  }
  // "one thousand and five": the last group takes "and" when it has no hundreds.
  const last = parts.length > 1 ? parts[parts.length - 1] : '';
  if (last && !/hundred/.test(last) && !/thousand|million|billion|trillion/.test(last)) parts[parts.length - 1] = 'and ' + last;
  return parts.join(', ').replace(', and ', ' and ');
}
export function amountInWords(amount: number, currency = 'naira', minor = 'kobo'): string {
  const v = Math.round(Math.abs(Number(amount) || 0) * 100);
  const whole = Math.floor(v / 100), cents = v % 100;
  const text = `${wholeWords(whole)} ${currency}${cents ? ` and ${wholeWords(cents)} ${minor}` : ''} only`;
  return text.charAt(0).toUpperCase() + text.slice(1);
}
