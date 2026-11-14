// Last year's accounts read for the opening position of a filing-only year (atlas action read_opening): the keys
// public.filing_opening_save posts, what the model is asked, and the shape the Filing page gets. Pure, so it is tested on its own.
import { S } from './gemini.ts';

export const OPENING_KEYS: Record<string, string> = {
  inventory: 'inventories, stock', trade_receivables: 'trade receivables, debtors', other_receivables: 'other receivables, deposits, staff loans',
  prepayments: 'prepayments', director_receivable: 'amounts directors owe the business', investments: 'investments',
  trade_payables: 'trade payables, creditors', accruals: 'accruals, accrued expenses', other_payables: 'other payables',
  director_payable: 'amounts the business owes its directors (directors\' current account)', tax_payable: 'income tax payable',
  loans_short: 'short-term loans and overdrafts other than bank balances', loans_long: 'long-term bank loans', shareholder_loans: 'loans from shareholders',
  share_capital: 'share capital (or the proprietor\'s capital for a business name)', share_premium: 'share premium', deposit_for_shares: 'deposit for shares',
  retained_earnings: 'retained earnings (negative for accumulated losses)',
};
export const ASSET_CLASSES: Record<string, string> = {
  '1501': 'Freehold land', '1502': 'Non-industrial buildings', '1503': 'Industrial buildings', '1504': 'Plant', '1505': 'Ships, boats and yachts',
  '1506': 'Heavy equipment', '1507': 'Aircraft engines and fuselage', '1508': 'Aircraft and vessel furnishing', '1509': 'Towers and cables',
  '1510': 'Trains and tracks', '1511': 'Motor vehicles', '1512': 'Buses and trucks', '1513': 'Tools and equipment', '1514': 'Office equipment',
  '1515': 'Medical equipment', '1516': 'Household equipment', '1517': 'Computer hardware', '1518': 'Office fixtures', '1519': 'Furniture and fittings',
  '1520': 'Assets under construction', '1521': 'Capital work in progress', '1522': 'Bearer plants', '1523': 'Biological assets',
  '1524': 'Petroleum development costs', '1525': 'Distribution network', '1526': 'Leasehold improvements', '1527': 'Other property, plant and equipment',
};
// What the model read, cleaned for the Filing page: one line per key (captions kept), each asset class, bank and cash apart.
export function openingOut(out: any) {
  const n = (v: unknown) => (v == null || v === '' || !Number.isFinite(Number(v)) ? null : Math.round(Number(v) * 100) / 100);
  const by = new Map<string, { key: string; amount: number; captions: string[] }>();
  let cash = 0; const other: { caption: string; amount: number }[] = [];
  for (const l of Array.isArray(out?.lines) ? out.lines : []) {
    const amt = n(l?.amount); const caption = String(l?.caption || '').replace(/\s+/g, ' ').trim().slice(0, 120);
    if (amt == null || amt === 0) continue;
    if (l?.key === 'cash') { cash += amt; continue; }
    if (!OPENING_KEYS[l?.key]) { other.push({ caption: caption || 'Other', amount: amt }); continue; }
    // Only retained earnings may be below zero; any other figure is taken as printed without its sign.
    const v = l.key === 'retained_earnings' ? amt : Math.abs(amt);
    const cur = by.get(l.key) || { key: l.key as string, amount: 0, captions: [] as string[] };
    cur.amount = Math.round((cur.amount + v) * 100) / 100; if (caption) cur.captions.push(caption);
    by.set(l.key, cur);
  }
  const assets = (Array.isArray(out?.assets) ? out.assets : []).map((a: any) => {
    const cost = n(a?.cost); let acc = n(a?.accumulated) ?? 0;
    if (cost == null || cost <= 0 || !ASSET_CLASSES[a?.class_account]) return null;
    acc = Math.min(Math.max(Math.abs(acc), 0), cost);
    return { class_account: a.class_account, name: String(a?.name || ASSET_CLASSES[a.class_account]).replace(/\s+/g, ' ').trim().slice(0, 200), cost, accumulated: acc,
      in_use_from: /^\d{4}-\d{2}-\d{2}$/.test(String(a?.in_use_from || '')) ? a.in_use_from : null };
  }).filter(Boolean).slice(0, 200);
  return {
    is_accounts: Boolean(out?.is_accounts), entity_name: out?.entity_name ? String(out.entity_name).slice(0, 160) : null,
    as_of: /^\d{4}-\d{2}-\d{2}$/.test(String(out?.as_of || '')) ? out.as_of : null,
    lines: [...by.values()], assets, cash: Math.round(cash * 100) / 100, other,
    confidence: Math.max(0, Math.min(100, Math.round(Number(out?.confidence) || 0))),
    warnings: (Array.isArray(out?.warnings) ? out.warnings : []).map((w: unknown) => String(w).slice(0, 200)).slice(0, 6),
  };
}

export const OPENING_SCHEMA = {
  type: 'OBJECT',
  properties: {
    is_accounts: { type: 'BOOLEAN', description: 'True when this is a set of financial statements, a statement of accounts or a tax computation with a balance sheet' },
    entity_name: S.nstr,
    as_of: { type: 'STRING', nullable: true, description: 'YYYY-MM-DD: the date of the statement of financial position read' },
    lines: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: { key: { type: 'STRING', enum: [...Object.keys(OPENING_KEYS), 'cash', 'other'] }, caption: S.str, amount: { type: 'NUMBER' } },
        required: ['key', 'caption', 'amount'],
      },
    },
    assets: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: { class_account: { type: 'STRING', enum: Object.keys(ASSET_CLASSES) }, name: S.str, cost: { type: 'NUMBER' },
          accumulated: { type: 'NUMBER', nullable: true }, in_use_from: { type: 'STRING', nullable: true, description: 'YYYY-MM-DD when printed' } },
        required: ['class_account', 'name', 'cost'],
      },
    },
    confidence: { type: 'NUMBER', description: '0 to 100' },
    warnings: { type: 'ARRAY', items: S.str },
  },
  required: ['is_accounts', 'lines', 'assets', 'confidence'],
};

// What the model is told: read the balance sheet at the end of the year before the year being filed.
export function openingSystem(year: number | null) {
  return `You read a Nigerian business's financial statements (or statement of accounts) for the year before ${year || 'the year being filed'}, to bring
its closing position into its books as the opening position of ${year || 'the next year'}.
Rules:
- Read the statement of financial position (balance sheet) at the end of the latest year shown, the current-year column, never the comparatives.
  as_of is that date.
- lines: one for each balance, with the key that fits: ${Object.entries(OPENING_KEYS).map(([k, v]) => `${k} (${v})`).join('; ')}.
  Bank balances, cash and short deposits use the key cash. A balance that fits none uses other, with its caption. Subtotals and totals are left out.
- amount as printed, a positive number, except retained earnings, which is negative when the statements show accumulated losses or a deficit.
- assets: property, plant and equipment from its note, one entry per class: cost at the year end and accumulated depreciation at the year end.
  class_account is the class code that fits best: ${Object.entries(ASSET_CLASSES).map(([k, v]) => `${k} ${v}`).join('; ')}.
  When only the carrying amount is shown, give it as the cost with accumulated null and say so in warnings. Leave PPE out of lines.
- is_accounts: false when the document is something else (a bank statement, an invoice, a letter).
- confidence 0-100. warnings: short plain sentences about anything a person should check (the balance sheet does not balance, figures in thousands, the
  year is not the one before ${year || 'the year being filed'}).
- Figures shown in thousands (₦'000) are multiplied out. Never invent a figure that is not on the document.`;
}
