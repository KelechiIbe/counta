// Drafts Martina prepares for a screen to open filled in: an invoice, a sale at the till, a supplier bill, a payment link or
// a new product. Nothing is saved until the person confirms on that screen.
import { useEffect, useState, useSyncExternalStore } from 'react';
import type { Item } from './types';

export type DraftLine = { item_id: string | null; name: string; qty: number; unit_price: number | null };
export type Drafts = {
  invoice: { customer: string; lines: DraftLine[]; due_in_days?: number | null; note?: string | null };
  sale: { lines: DraftLine[]; customer?: string | null };
  bill: { vendor: string; amount: number; description: string; due_date?: string | null };
  payment_link: { amount: number; customer?: string | null; description?: string | null };
  product: { name: string; kind?: 'product' | 'service'; price?: number | null; cost?: number | null; unit?: string | null; category?: string | null;
    brand?: string | null; description?: string | null; barcode?: string | null; nafdac_no?: string | null; purchase_unit?: string | null; pack_size?: number | null;
    photo?: Blob | null; photo_type?: string | null; item_type?: string | null };
};
type Kind = keyof Drafts;
type Entry = { kind: Kind; data: any; at: number } | null;

let current: Entry = null;
const listeners = new Set<() => void>();
const emit = () => listeners.forEach((l) => l());

export function setDraft<K extends Kind>(kind: K, data: Drafts[K]) { current = { kind, data, at: Date.now() }; emit(); }
export function clearDraft() { current = null; emit(); }

// The draft for this screen, taken once: the screen opens its form with it and the draft is gone.
export function useDraft<K extends Kind>(kind: K): Drafts[K] | null {
  const e = useSyncExternalStore((cb) => { listeners.add(cb); return () => listeners.delete(cb); }, () => current);
  const [taken, setTaken] = useState<{ data: Drafts[K]; at: number } | null>(null);
  useEffect(() => {
    if (e && e.kind === kind && e.at !== taken?.at) { setTaken({ data: e.data, at: e.at }); current = null; }
  }, [e, kind]); // eslint-disable-line react-hooks/exhaustive-deps
  return taken?.data ?? null;
}

// "3 Peak Milk 400g at 2800; 1 delivery at 1500" -> lines, each matched to a product when one fits.
const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
export function matchItem(name: string, items: Pick<Item, 'id' | 'name' | 'barcode' | 'sku'>[]): Pick<Item, 'id' | 'name'> | null {
  const n = norm(name);
  if (!n) return null;
  const exact = items.find((i) => norm(i.name) === n || i.barcode === name.trim() || (i.sku && norm(i.sku) === n));
  if (exact) return exact;
  const words = n.split(' ').filter((w) => w.length > 1);
  let best: { it: Pick<Item, 'id' | 'name'>; score: number } | null = null;
  for (const it of items) {
    const iw = norm(it.name).split(' ');
    const hit = words.filter((w) => iw.some((x) => x === w || (w.length >= 4 && x.startsWith(w)) || (x.length >= 4 && w.startsWith(x)))).length;
    const score = hit / Math.max(words.length, 1);
    if (hit && (!best || score > best.score)) best = { it, score };
  }
  return best && best.score >= 0.6 ? best.it : null;
}
export function parseLines(text: string, items: Pick<Item, 'id' | 'name' | 'barcode' | 'sku' | 'price'>[]): DraftLine[] {
  return String(text || '').split(/[;\n]+/).map((raw) => raw.trim()).filter(Boolean).slice(0, 40).map((raw) => {
    const m = raw.match(/^(\d+(?:\.\d+)?)\s*(?:x|×|of)?\s+(.+?)(?:\s+(?:at|@|for)\s*(?:₦|n|ngn)?\s*([\d,]+(?:\.\d+)?)\s*(?:each|naira)?)?\s*$/i);
    const qty = m ? Number(m[1]) : 1;
    const name = (m ? m[2] : raw).replace(/^(?:x|×)\s*/i, '').trim();
    const price = m?.[3] ? Number(m[3].replace(/,/g, '')) : null;
    const it = matchItem(name, items);
    return { item_id: it?.id ?? null, name: it?.name ?? name, qty: qty > 0 ? qty : 1, unit_price: price ?? (it ? Number((it as any).price) || null : null) };
  });
}
