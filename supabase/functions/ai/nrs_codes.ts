// The codes NRS wants on e-invoices: the HS code of each item (a six-digit HS 2022 subheading such as 1902.30, from
// NRS's list of 5,612) and the service code of the business (a four-digit ISIC Rev. 4 class, from NRS's list of 419).
// Gemini chooses them; the database checks each against NRS's list and marks unsure ones for a person to confirm.

export type HsItem = { id: string; org_id: string; name: string; category?: string; brand?: string; description?: string; item_type?: string; unit?: string;
  current?: string; industry?: string };
export type HsAnswer = { id: string; code: string | null; heading: string | null; confidence: number; reason: string };
export type CodeRow = { code: string; label: string | null };

const STR = { type: 'STRING' }, NUM = { type: 'NUMBER' }, NSTR = { type: 'STRING', nullable: true };

export const HS_SYSTEM = `You choose the Harmonized System (HS) code for products sold by Nigerian businesses, for the e-invoices they send to the
Nigeria Revenue Service (NRS). NRS uses the six-digit subheadings of HS 2022, written with a dot after the fourth digit, like 1902.30.

For each item, give:
- hs_code: the six-digit subheading that best describes the goods as the business sells them
- heading: its four-digit heading (the first four digits)
- confidence: from 0 to 1, how sure you are
- reason: one short sentence in plain words

Use the name, brand, category, description, unit and the kind of business. Brand names often say what the product is (Indomie is instant noodles,
Peak is milk, Dangote is cement or sugar or salt). Classify the goods themselves, not their packaging. When an item is too vague to classify,
give your best code with a low confidence. Give only real HS 2022 subheadings.`;

export const HS_SCHEMA = {
  type: 'OBJECT',
  properties: {
    results: { type: 'ARRAY', items: { type: 'OBJECT', properties: { id: STR, hs_code: NSTR, heading: NSTR, confidence: NUM, reason: STR },
      required: ['id', 'hs_code', 'confidence', 'reason'] } },
  },
  required: ['results'],
};

export function hsPrompt(items: HsItem[]) {
  return 'Items:\n' + items.map((i) => JSON.stringify({ id: i.id, name: i.name, brand: i.brand || '', category: i.category || '', description: i.description || '',
    kind: i.item_type || '', unit: i.unit || '', business_trade: i.industry || '' })).join('\n');
}

// An HS code as NRS lists it, from what came back (190230, 1902.30.00, 1902 30).
export function hsCode(v: unknown): string | null {
  const d = String(v ?? '').replace(/\D/g, '');
  return d.length >= 6 ? `${d.slice(0, 4)}.${d.slice(4, 6)}` : null;
}

export function cleanHs(items: HsItem[], raw: any[]): HsAnswer[] {
  const ids = new Set(items.map((i) => i.id));
  const seen = new Set<string>();
  const out: HsAnswer[] = [];
  for (const r of raw || []) {
    const id = String(r?.id || '');
    if (!ids.has(id) || seen.has(id)) continue;
    seen.add(id);
    const code = hsCode(r.hs_code);
    const heading = String(r.heading || '').replace(/\D/g, '').slice(0, 4) || (code ? code.slice(0, 4) : null);
    out.push({ id, code, heading: heading && heading.length === 4 ? heading : null, confidence: Math.round(Math.min(Math.max(Number(r.confidence) || 0, 0), 1) * 1000) / 1000,
      reason: String(r.reason || '').replace(/\s+/g, ' ').trim().slice(0, 400) });
  }
  return out;
}

// The second look: when Gemini's code is not on NRS's list, it chooses again from NRS's codes under the same heading
// (or chapter).
export const HS_PICK_SYSTEM = `You choose the Harmonized System (HS) code for a product sold by a Nigerian business, from the list of codes the
Nigeria Revenue Service (NRS) accepts. Choose exactly one code from the list: the subheading that best describes the goods as sold. If none of them
fits the product, answer null. Give your confidence from 0 to 1 and one short sentence in plain words.`;

export const HS_PICK_SCHEMA = {
  type: 'OBJECT', properties: { code: NSTR, confidence: NUM, reason: STR }, required: ['code', 'confidence', 'reason'],
};

export function hsPickPrompt(item: HsItem, candidates: CodeRow[]) {
  return 'Item:\n' + JSON.stringify({ name: item.name, brand: item.brand || '', category: item.category || '', description: item.description || '',
    kind: item.item_type || '', unit: item.unit || '', business_trade: item.industry || '' })
    + '\n\nNRS codes to choose from (code: description):\n' + candidates.map((c) => `${c.code}: ${c.label || ''}`).join('\n');
}

export function cleanPick(raw: any, candidates: CodeRow[]): { code: string | null; confidence: number; reason: string } {
  const code = hsCode(raw?.code);
  const ok = code && candidates.some((c) => c.code === code) ? code : null;
  return { code: ok, confidence: ok ? Math.round(Math.min(Math.max(Number(raw?.confidence) || 0, 0), 1) * 1000) / 1000 : 0,
    reason: String(raw?.reason || '').replace(/\s+/g, ' ').trim().slice(0, 400) };
}

// The business's service code.
export type ServiceOrg = { org_id: string; name: string; industry?: string; offering?: string; principal_activity?: string; items?: string[]; services?: string[] };

export const SERVICE_SYSTEM = `You choose the service code a Nigerian business puts on its e-invoices to the Nigeria Revenue Service (NRS): one
four-digit class of ISIC Rev. 4, from NRS's list. Choose the class that best describes the business's main activity, or the services it sells when
it sells services. Answer only with a code from the list, your confidence from 0 to 1, and one short sentence in plain words.`;

export const SERVICE_SCHEMA = {
  type: 'OBJECT', properties: { code: NSTR, confidence: NUM, reason: STR }, required: ['code', 'confidence', 'reason'],
};

export function servicePrompt(o: ServiceOrg, list: CodeRow[]) {
  const sells = o.offering === 'services' ? 'services' : o.offering === 'both' ? 'goods and services' : 'goods';
  return 'Business:\n' + JSON.stringify({ name: o.name, kind_of_business: o.industry || '', sells, principal_activity: o.principal_activity || '',
    some_items: (o.items || []).slice(0, 12), some_services: (o.services || []).slice(0, 12) })
    + '\n\nNRS service codes (code: description):\n' + list.map((c) => `${c.code}: ${c.label || ''}`).join('\n');
}

export function cleanService(raw: any, list: CodeRow[]): { code: string | null; confidence: number; reason: string } {
  const code = String(raw?.code ?? '').replace(/\D/g, '');
  const ok = /^\d{4}$/.test(code) && (!list.length || list.some((c) => c.code === code)) ? code : null;
  return { code: ok, confidence: ok ? Math.round(Math.min(Math.max(Number(raw?.confidence) || 0, 0), 1) * 1000) / 1000 : 0,
    reason: String(raw?.reason || '').replace(/\s+/g, ' ').trim().slice(0, 400) };
}
