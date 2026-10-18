// The words Counta speaks, in English and Nigerian Pidgin. Only facts from the database go into them (voice_say).

// Numbers as words, so every voice model says them the same way ("fifteen thousand naira", not "one five zero zero zero").
const ONES = ['zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'eleven', 'twelve', 'thirteen',
  'fourteen', 'fifteen', 'sixteen', 'seventeen', 'eighteen', 'nineteen'];
const TENS = ['', '', 'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety'];
function under1000(n: number): string {
  const h = Math.floor(n / 100), r = n % 100;
  const rest = r < 20 ? (r ? ONES[r] : '') : TENS[Math.floor(r / 10)] + (r % 10 ? '-' + ONES[r % 10] : '');
  return [h ? `${ONES[h]} hundred` : '', h && rest ? 'and' : '', rest].filter(Boolean).join(' ');
}
export function words(v: number): string {
  let n = Math.floor(Math.abs(v));
  if (n === 0) return 'zero';
  if (n >= 1e15) return n.toLocaleString('en-US');
  const parts: string[] = [];
  for (const [size, name] of [[1e12, 'trillion'], [1e9, 'billion'], [1e6, 'million'], [1e3, 'thousand']] as const) {
    if (n >= size) { parts.push(`${under1000(Math.floor(n / size))} ${name}`); n %= size; }
  }
  if (n) parts.push((parts.length && n < 100 ? 'and ' : '') + under1000(n));
  return parts.join(' ').replace(/\s+/g, ' ');
}
export const naira = (v: unknown) => {
  const n = Math.round(Number(v) * 100) / 100;
  if (!Number.isFinite(n) || n < 0) return '';
  const whole = Math.floor(n), kobo = Math.round((n - whole) * 100);
  return `${words(whole)} naira${kobo ? ` ${words(kobo)} kobo` : ''}`;
};
const qty = (v: unknown) => {
  const n = Number(v);
  if (Number.isInteger(n)) return words(n);
  const r = Math.round(n * 100) / 100;
  return r === 0.5 ? 'half' : String(r);
};
const clean = (v: unknown, n = 80) => String(v ?? '').replace(/[<>{}\[\]\\]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, n);
const titleCase = (s: string) => s.toLowerCase().replace(/\b\p{L}/gu, (c) => c.toUpperCase());

export const DEMO = { amount: 15000, payer: 'Chidi Okafor' };

export function phrase(kind: string, lang: 'en' | 'pcm', vars: Record<string, unknown>, extra: { voiceName?: string; business?: string } = {}): string {
  const payer = vars.payer ? titleCase(clean(vars.payer, 60)) : '';
  const amount = naira(vars.amount);
  switch (kind) {
    case 'payment_received':
      if (lang === 'pcm') return payer ? `Alert don land! ${payer} don pay you ${amount}.` : `Alert don land! Money don enter: ${amount}.`;
      return payer ? `Payment received: ${amount} from ${payer}.` : `Payment received: ${amount}.`;
    case 'sale_recorded': {
      const item = clean(vars.item), n = Number(vars.qty);
      let unit = clean(vars.unit, 20);
      // "2 carton" is said "two cartons"; short units such as kg or pcs are left alone.
      if (unit && n > 1 && !/s$/i.test(unit) && !unit.includes('.') && !/^(kg|g|mg|ml|cl|l|ltr|lb|pc|pcs|m|cm|mm|ft|in|yd)$/i.test(unit)) unit += /(ch|sh|x)$/i.test(unit) ? 'es' : 's';
      const what = unit ? `${qty(n)} ${unit}${lang === 'pcm' ? '' : ' of'} ${item}` : `${qty(n)} ${item}`;
      if (lang === 'pcm') return Number(vars.amount) > 0 ? `Sale don enter: ${what}, ${amount}.` : `Sale don enter: ${what}.`;
      return Number(vars.amount) > 0 ? `Sale recorded: ${what}, ${amount}.` : `Sale recorded: ${what}.`;
    }
    case 'payment_demo':
      if (lang === 'pcm') return `Alert don land! ${DEMO.payer} don pay you ${naira(DEMO.amount)}. Na so I go dey tell you anytime money enter.`;
      return `Payment received! ${naira(DEMO.amount)} from ${DEMO.payer}. That's how I'll tell you every time money lands.`;
    case 'preview': {
      const name = clean(extra.voiceName || '', 30);
      if (lang === 'pcm') return `How far! Na me be ${name || 'your Counta voice'}. Alert don land: ${DEMO.payer} don pay you ${naira(DEMO.amount)}.`;
      return `Hello, I'm ${name || 'your Counta voice'}. Payment received: ${naira(DEMO.amount)} from ${DEMO.payer}.`;
    }
    default:
      return '';
  }
}

// Phrases that never change for a voice are kept and reused; the rest name a real payer or sale and are not stored.
export const cacheable = (kind: string) => kind === 'preview' || kind === 'payment_demo';

// A library voice's name without the description some owners add ("Ada - warm Lagos narrator" becomes "Ada").
export const shortName = (name: unknown) => clean(String(name ?? '').split(/\s[-|–:(]\s?|\s\(/)[0], 40) || 'Voice';
