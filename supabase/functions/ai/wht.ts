// The WHT type of what a Nigerian business sells, line by line, so Counta knows what a customer that withholds will keep back
// from an invoice: each line's words go to the model with the business's trade and the types it may choose from (the NRS
// table Counta keeps in wht_rates, with this business's rate for each). Numens decides when it is connected; Gemini stands
// in until then. The database keeps each answer for the line's words, and a person's choice always wins over it.

export type WhtType = { code: string; name: string; rate: number };
export type WhtBusiness = { name?: string; industry?: string; offering?: string; activity?: string; legal_form?: string; category?: string; products?: string[] };
export type WhtAnswer = { description: string; category: string | null; confidence: number; reason: string; source: 'gemini'; model?: string };

export const WHT_SYSTEM = `You decide the withholding tax (WHT) type of each line a Nigerian business puts on its invoices, under the Deduction of Tax at
Source (Withholding) Regulations as the NRS WHT schedule lists them. The customer is a company or government body that withholds tax when it pays.
Choose for each line exactly one code from the list you are given, judging what the line supplies, not who buys it.

How to choose:
- Professional, consultancy, technical and management services (code professional): work that needs a profession's skill: legal, accounting, audit,
  tax, engineering, architecture, medical and health services, IT implementation, software development, technical support, training, management fees.
- Other services (services): everything else rendered as a service: cleaning, security, catering, logistics and delivery, repairs, events, printing,
  advertising placements, hire of staff.
- Supply of goods (goods): selling physical goods the business did not make itself, including retail and wholesale of food, drinks, medicines, nappies
  and other consumer products, equipment and materials.
- Goods made by the business itself (ex_manufacturer): only when the business manufactures or produces what it sells (a factory, a farm, a bakery
  selling its own bread).
- Rent, hire or lease (rent): rent of buildings, land, equipment or vehicles. Commission (commission), brokerage (brokerage), royalty (royalty),
  construction (construction_roads for roads, bridges, buildings and power plants; construction_other for other construction work).
- Out-of-pocket costs reimbursed at cost (ex_reimbursable), telephone, data and airline tickets (ex_telecom_airline), insurance premiums (ex_insurance),
  petroleum products listed in the code's name (ex_petroleum), and other "Not subject" codes when the line plainly is one of them.

Give a confidence between 0 and 1: 0.9 or more only when the words leave no real doubt, 0.6 to 0.8 when the trade decides it, lower when you guess.
Give one short sentence of reason a business owner understands. Never invent a code that is not in the list.`;

export const WHT_SCHEMA = {
  type: 'OBJECT',
  properties: {
    results: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: { id: { type: 'STRING' }, code: { type: 'STRING' }, confidence: { type: 'NUMBER' }, reason: { type: 'STRING' } },
        required: ['id', 'code', 'confidence', 'reason'],
      },
    },
  },
  required: ['results'],
};

const NL = String.fromCharCode(10);
const pct = (r: number) => `${Math.round(Number(r || 0) * 10000) / 100}%`;

export function whtPrompt(business: WhtBusiness, types: WhtType[], lines: string[]): string {
  const b = business || {};
  const trade = [b.category, b.industry, b.activity].filter(Boolean).join('; ') || 'not given';
  const sells = (b.products || []).slice(0, 30).join(', ');
  return [
    `Business: ${b.name || 'a Nigerian business'} (${b.legal_form || 'company'}). Trade: ${trade}. Mostly sells: ${b.offering || 'not given'}.`,
    sells ? `Products on its list: ${sells}.` : '',
    '',
    'Codes you may choose from (code: what it covers, this business\'s rate):',
    ...types.map((t) => `${t.code}: ${t.name} (${pct(t.rate)})`),
    '',
    'Invoice lines (id: words):',
    ...lines.map((l, i) => `${i + 1}: ${l}`),
  ].filter((x, i, a) => !(x === '' && a[i - 1] === '')).join(NL);
}

// The model's answers matched back to the lines, keeping only codes from the list and confidences between 0 and 1.
export function cleanWht(lines: string[], results: unknown, types: WhtType[], model?: string): WhtAnswer[] {
  const codes = new Set(types.map((t) => t.code));
  const byId = new Map<string, any>();
  for (const r of Array.isArray(results) ? results : []) if (r && typeof r === 'object' && (r as any).id != null) byId.set(String((r as any).id), r);
  return lines.map((description, i) => {
    const r = byId.get(String(i + 1));
    const code = r && typeof r.code === 'string' && codes.has(r.code.trim()) ? r.code.trim() : null;
    const c = Number(r?.confidence);
    return { description, category: code, confidence: code && Number.isFinite(c) ? Math.min(Math.max(c, 0), 1) : 0,
      reason: String(r?.reason || '').replace(/\s+/g, ' ').trim().slice(0, 300), source: 'gemini' as const, model };
  });
}
