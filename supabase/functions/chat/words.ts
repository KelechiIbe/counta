// Words Martina reads on WhatsApp and Siri. The yes and no lists match src/guide/handsFree.ts, and the product lines match
// src/lib/drafts.ts (parseLines, matchItem), so the app, WhatsApp and Siri understand the same things; keep them alike.

// A yes or no to "Shall I go ahead?", in English or Pidgin. A reply holding both ("yes... no, wait") counts as neither.
const YES = /\b(yes|yeah|yea|yep|yup|ya|sure|ok|okay|alright|all right|go ahead|go on|do it|do that|confirm(ed)?|approve(d)?|proceed|save it|record it|issue it|send it|correct|that'?s (right|correct|fine|good)|perfect|please do|abeg do am|do am|oya|na so|e correct|carry go|make you do am)\b/i;
const NO = /\b(no|nope|nah|don'?t|do not|wait|stop|cancel|hold on|hold it|not yet|never ?mind|change|wrong|abeg no|no o|make you no|leave am|forget it)\b/i;
export const saidYes = (t: string) => YES.test(t) && !NO.test(t);
export const saidNo = (t: string) => NO.test(t);

export type Item = { id: string; name: string; barcode?: string | null; sku?: string | null; price?: number | string | null };
export type Line = { item_id: string | null; name: string; qty: number; unit_price: number | null };

const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
export function matchItem(name: string, items: Item[]): Item | null {
  const n = norm(name);
  if (!n) return null;
  const exact = items.find((i) => norm(i.name) === n || i.barcode === name.trim() || (i.sku && norm(i.sku) === n));
  if (exact) return exact;
  const words = n.split(' ').filter((w) => w.length > 1);
  let best: { it: Item; score: number } | null = null;
  for (const it of items) {
    const iw = norm(it.name).split(' ');
    const hit = words.filter((w) => iw.some((x) => x === w || (w.length >= 4 && x.startsWith(w)) || (x.length >= 4 && w.startsWith(x)))).length;
    const score = hit / Math.max(words.length, 1);
    if (hit && (!best || score > best.score)) best = { it, score };
  }
  return best && best.score >= 0.6 ? best.it : null;
}

// "3 Peak Milk 400g at 2800; 1 delivery at 1500" -> lines, each matched to a product when one fits.
export function parseLines(text: string, items: Item[]): Line[] {
  return String(text || '').split(/[;\n]+/).map((raw) => raw.trim()).filter(Boolean).slice(0, 40).map((raw) => {
    const m = raw.match(/^(\d+(?:\.\d+)?)\s*(?:x|×|of)?\s+(.+?)(?:\s+(?:at|@|for)\s*(?:₦|n|ngn)?\s*([\d,]+(?:\.\d+)?)\s*(?:each|naira)?)?\s*$/i);
    const qty = m ? Number(m[1]) : 1;
    const name = (m ? m[2] : raw).replace(/^(?:x|×)\s*/i, '').trim();
    const price = m?.[3] ? Number(m[3].replace(/,/g, '')) : null;
    const it = matchItem(name, items);
    return { item_id: it?.id ?? null, name: it?.name ?? name, qty: qty > 0 ? qty : 1, unit_price: price ?? (it ? Number(it.price) || null : null) };
  });
}

export const naira = (v: unknown) => {
  const n = Number(v);
  if (!Number.isFinite(n)) return '₦0.00';
  return (n < 0 ? '-₦' : '₦') + Math.abs(n).toLocaleString('en-NG', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
};

// "LINK 123456" (any case, spaces or a dash inside the code), as sent from the wa.me link Counta gives.
export function linkCode(text: string): string | null {
  const m = String(text || '').trim().match(/^link[\s:#-]*(\d{3})[\s-]?(\d{3})\s*$/i);
  return m ? m[1] + m[2] : null;
}
export const isUnlink = (text: string) => /^\s*(unlink|stop martina|disconnect)\s*[.!]?\s*$/i.test(String(text || ''));
