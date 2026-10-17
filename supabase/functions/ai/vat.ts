// VAT treatment of items under the Nigeria Tax Act 2025. Numens (TaxStreem's tax model) decides when it is connected;
// Gemini stands in until then. Below the confidence threshold the database asks a person instead of changing the item.

export type VatItem = { id: string; org_id: string; name: string; category?: string; brand?: string; description?: string; item_type?: string; unit?: string;
  current?: string; industry?: string };
export type VatAnswer = { id: string; treatment: 'standard' | 'zero' | 'exempt'; confidence: number; reason: string; law: string; source: 'numens' | 'gemini'; model?: string };

export const VAT_SYSTEM = `You decide the VAT treatment of products and services sold by Nigerian businesses under the Nigeria Tax Act 2025 (NTA 2025).
The standard rate is 7.5%. Answer "standard" unless the item clearly falls in one of these lists.

Zero-rated (s.187, 0% VAT, the seller recovers input VAT):
- basic food items (staples such as rice, beans, garri, yam, maize, millet, sorghum, bread, flour, fresh fruit and vegetables, fresh or frozen meat, fish and poultry, eggs, milk, cooking oil, salt, sugar, water)
- all medical and pharmaceutical products, including medicinal herbal products; medical equipment; medical services
- educational books and materials; tuition for nursery, primary, secondary and tertiary education
- fertilisers; locally produced agricultural chemicals, veterinary medicine and animal feed; live cattle, goats, sheep and poultry; agricultural seeds and seedlings
- electricity generated or transmitted to the grid or distribution companies
- exported goods (not oil and gas), exported services and exported intangible property
- electric vehicles and parts for assembling them

Exempt (s.186, no VAT, input VAT not recoverable):
- baby products; locally manufactured sanitary towels, pads and tampons
- petroleum products, CNG, LPG and other gaseous hydrocarbons; renewable energy equipment
- shared passenger road transport; land and buildings; money and securities; government licences
- hire or lease of tractors, ploughs and other agricultural equipment
- assistive devices for persons with disability (hearing aids, wheelchairs, braille materials)
- military hardware and uniforms supplied to the armed forces and security agencies

Everything else is standard-rated, including processed or luxury food and drinks (soft drinks, beverages, chocolate, snacks, alcohol, sweets),
cosmetics, toiletries, household goods, phones, electronics, clothing, building materials, services such as repairs, delivery and consulting.

Confidence is the probability you are right, from 0 to 1. Give 0.95 or more only when the item plainly belongs in its list or plainly does not.
Give less than 0.8 when the name is vague, when it could be a basic food or a processed one (for example "Milo", "custard", "noodles"), when
"locally manufactured" or "locally produced" matters and you cannot tell, or when the business's trade suggests something unusual.
reason: one short sentence a shop owner understands. law: "NTA 2025 s.187" for zero-rated, "NTA 2025 s.186" for exempt, "NTA 2025 standard rate" for standard.`;

export const VAT_SCHEMA = {
  type: 'OBJECT',
  properties: {
    results: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: {
          id: { type: 'STRING' },
          treatment: { type: 'STRING', enum: ['standard', 'zero', 'exempt'] },
          confidence: { type: 'NUMBER' },
          reason: { type: 'STRING' },
          law: { type: 'STRING' },
        },
        required: ['id', 'treatment', 'confidence', 'reason', 'law'],
      },
    },
  },
  required: ['results'],
};

export function vatPrompt(items: VatItem[]) {
  return 'Items:\n' + items.map((i) => JSON.stringify({ id: i.id, name: i.name, category: i.category || '', brand: i.brand || '', description: i.description || '',
    kind: i.item_type || '', unit: i.unit || '', business_trade: i.industry || '' })).join('\n');
}

export function cleanVat(items: VatItem[], raw: any[], source: 'numens' | 'gemini', model?: string): VatAnswer[] {
  const ids = new Set(items.map((i) => i.id));
  const seen = new Set<string>();
  const out: VatAnswer[] = [];
  for (const r of raw || []) {
    const id = String(r?.id || '');
    if (!ids.has(id) || seen.has(id) || !['standard', 'zero', 'exempt'].includes(r.treatment)) continue;
    seen.add(id);
    const conf = Math.min(Math.max(Number(r.confidence) || 0, 0), 1);
    out.push({ id, treatment: r.treatment, confidence: Math.round(conf * 1000) / 1000, reason: String(r.reason || '').slice(0, 400),
      law: String(r.law || '').slice(0, 120), source, model });
  }
  return out;
}

// Numens: POST {NUMENS_API_URL}/vat/classify  {items:[{id,name,category,brand,description,kind,unit,business_trade}]}
//   -> {results:[{id, treatment, confidence, reason, law}], model?}
export async function numens(url: string, key: string, items: VatItem[]): Promise<VatAnswer[]> {
  const res = await fetch(url.replace(/\/$/, '') + '/vat/classify', {
    method: 'POST', headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ country: 'NG', law: 'NTA2025', items: items.map((i) => ({ id: i.id, name: i.name, category: i.category, brand: i.brand,
      description: i.description, kind: i.item_type, unit: i.unit, business_trade: i.industry })) }),
    signal: AbortSignal.timeout(30_000),
  });
  if (!res.ok) throw new Error(`Numens ${res.status}: ${(await res.text()).slice(0, 200)}`);
  const body = await res.json();
  return cleanVat(items, body?.results || [], 'numens', body?.model || 'numens');
}
