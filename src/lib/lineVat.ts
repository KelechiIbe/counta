// Numens decides the VAT on the lines a person types on an invoice (a service, a fee, a charge). The words of each line go
// to the AI function, which answers from what the business has on record for those words (Numens' earlier answer, or a
// person's choice, which Numens never replaces) and asks Numens about the rest. Each line shows the answer with its reason.
// Answers below the business's confidence threshold are used, and the person confirms or changes them before the invoice
// is issued; a change is the person's decision and is used for those words from then on.
//
// Answers are kept here per business for the session, so lines typed again, on this invoice or the next, show at once.
import { useEffect, useState } from 'react';
import { ai } from './supabase';
import { vatPct } from './vat';

export type VatT = 'standard' | 'zero' | 'exempt';
export type VatBy = 'numens' | 'person';
export type LineVatAnswer = {
  description: string; treatment: VatT; source: 'numens' | 'gemini' | 'person'; confidence: number | null; reason: string | null;
  law: string | null; nrs_label: string | null; by: string | null; at: string | null;
  ai: { source?: string; treatment?: VatT; confidence?: number; reason?: string } | null;
};
// What a line shows: Numens' answer (or the person's earlier choice), whether it is still being asked, whether Numens is
// not sure of it, and whether no answer came back (the person chooses).
export type LineVatState = { answer: LineVatAnswer | null; loading: boolean; unsure: boolean; failed: boolean };

export const vatKey = (s: string) => s.replace(/\s+/g, ' ').trim().toLowerCase();
export const VAT_NAME: Record<VatT, string> = { standard: 'Standard-rated', zero: 'Zero-rated', exempt: 'Exempt' };
export const vatLabel = (t: VatT, day?: string | null) => (t === 'standard' ? `VAT ${vatPct(day)}` : VAT_NAME[t]);

type Entry = { a: LineVatAnswer | null; t: number };
const store = new Map<string, Entry>();
const asking = new Set<string>();
const threshold = new Map<string, number>();
const listeners = new Set<() => void>();
const emit = () => listeners.forEach((f) => f());
const id = (org: string, d: string) => `${org}|${vatKey(d)}`;
// An answer is kept for ten minutes; no answer is asked again after thirty seconds.
const fresh = (e: Entry | undefined) => !!e && Date.now() - e.t < (e.a ? 600_000 : 30_000);

async function ask(org: string, descriptions: string[]) {
  const want = [...new Map(descriptions.filter((d) => vatKey(d)).map((d) => [vatKey(d), d.replace(/\s+/g, ' ').trim()])).values()]
    .filter((d) => !asking.has(id(org, d)) && !fresh(store.get(id(org, d))));
  if (!want.length) return;
  for (const d of want) asking.add(id(org, d));
  emit();
  const got = new Map<string, LineVatAnswer | null>();
  try {
    for (let i = 0; i < want.length; i += 50) {
      const r = await ai<{ threshold: number; results: (Omit<LineVatAnswer, 'treatment' | 'source'> & { treatment: VatT | null; source: LineVatAnswer['source'] | null })[] }>(
        'vat_lines', { org_id: org, lines: want.slice(i, i + 50) });
      if (r.ok === false) break;
      if (Number(r.threshold) > 0) threshold.set(org, Number(r.threshold));
      for (const a of r.results || []) got.set(vatKey(a.description), a.treatment && a.source ? (a as LineVatAnswer) : null);
    }
  } catch { /* each line then shows that Numens could not answer, and the person chooses */ }
  for (const d of want) {
    store.set(id(org, d), { a: got.get(vatKey(d)) ?? null, t: Date.now() });
    asking.delete(id(org, d));
  }
  emit();
}

// After a save that recorded the person's choices: the next look at those words asks again, so it shows what is on record.
export function forgetLineVat(org: string | null | undefined, descriptions: string[]) {
  if (!org) return;
  for (const d of descriptions) store.delete(id(org, d));
  emit();
}

export function lineVatThreshold(org: string | null | undefined) {
  return (org && threshold.get(org)) || 0.8;
}

export function lineVatOf(org: string | null | undefined, description: string): LineVatState {
  if (!org || !vatKey(description)) return { answer: null, loading: false, unsure: false, failed: false };
  const k = id(org, description);
  const e = store.get(k);
  const a = e?.a ?? null;
  if (!a && (asking.has(k) || !e)) return { answer: null, loading: true, unsure: false, failed: false };
  return { answer: a, loading: false, unsure: !!a && a.source !== 'person' && (a.confidence ?? 0) < lineVatThreshold(org), failed: !a };
}

// Asks for the lines' VAT a moment after their words stop changing. Pass no lines to ask for nothing (a business that does
// not charge VAT, say).
export function useLineVat(org: string | null | undefined, descriptions: string[]) {
  const [, redraw] = useState(0);
  useEffect(() => {
    const f = () => redraw((x) => x + 1);
    listeners.add(f);
    return () => { listeners.delete(f); };
  }, []);
  const words = [...new Set(descriptions.map(vatKey).filter(Boolean))].sort().join('\n');
  useEffect(() => {
    if (!org || !words) return;
    const list = descriptions.filter((d) => vatKey(d));
    const h = setTimeout(() => { void ask(org, list); }, 700);
    return () => clearTimeout(h);
  }, [org, words]); // eslint-disable-line react-hooks/exhaustive-deps
  return (description: string) => lineVatOf(org, description);
}

// A typed line's VAT as it goes to the books: the person's choice, else Numens' answer, else what the line had.
export function lineVatTreatment(st: LineVatState, by: VatBy, current: VatT): VatT {
  return by === 'person' ? current : st.answer?.treatment ?? current;
}

// The lines a person must look at before the document goes out: Numens is not sure, or gave no answer. Lines still being
// asked come back apart, so the page can wait for them.
export function linesToCheck<L extends { description: string; vat_by: VatBy }>(lines: L[], st: (d: string) => LineVatState) {
  const typed = lines.filter((l) => vatKey(l.description) && l.vat_by !== 'person');
  return { waiting: typed.filter((l) => st(l.description).loading), unsure: typed.filter((l) => !st(l.description).loading && (st(l.description).unsure || st(l.description).failed)) };
}
