// Reading a year's audited financial statements (or a trial balance) onto the lines of the Rev360 CIT template, for years
// Counta's books do not cover. The AI places each figure; the database adds up lines that land on one cell and keeps the
// lowest confidence; a person reviews every line before the return can be approved.

export type TemplateLine = { cell: string; sheet: string; addr: string; section: string | null; label: string; note: string | null; positive_only?: boolean };
export type TbRow = { code?: string; name: string; debit?: number; credit?: number; balance?: number };

export const CIT_MAP_SYSTEM = `You prepare Nigerian companies income tax returns. You place the figures of one company's financial statements for one
accounting year onto the input lines of the NRS Rev360 CIT Excel template. The template's own formulas add the lines up, so put each figure on the most
specific line and never on a total.

How to place figures:
- Use the figures for the CURRENT year only (never the comparative column), in naira. Statements in thousands or millions: multiply out.
- Revenue goes on the INCOME_STATEMENT sector lines (D7 to D27) by the company's business; cost of sales on its own lines (purchases, direct labour,
  opening and closing inventory, depreciation of production assets, other direct costs).
- Other income on OTHER_INCOME lines: dividends received (franked investment income), interest, rent, profit on disposal of assets, exchange and
  fair-value gains, grants and other non-taxable income.
- Administrative and operating expenses on the ADMINISTRATIVE_EXPENSES lines, one expense per line. Do not lump expenses together: if a note splits an
  expense, place each part. Depreciation and amortisation have their own lines. Only an expense with no matching line goes on "Other operating expenses".
- Finance costs other than interest, and taxation (the income tax charge in the statement of profit or loss), on their INCOME_STATEMENT lines.
- The statement of financial position line by line: property, plant and equipment (net), intangible assets, investments, inventories, receivables,
  cash, payables, current tax, borrowings, share capital, retained earnings and reserves. Assets and liabilities as positive amounts; retained
  earnings negative when they are accumulated losses.
- PROFIT_ADJUSTMENT lines only when the statements include a tax computation that shows those adjustments; otherwise leave them out.
- Amounts are positive unless the line is an equity reserve or retained earnings that is a deficit.

For each placed figure give: cell (exactly as listed), amount, confidence (0 to 1: 0.9 or more only when the statement line plainly matches the template
line; below 0.8 when a person should check), and source_text (the words and figure from the statements, short).
Also give the statements' own totals as printed: revenue, profit before tax, total assets, total equity and liabilities; the period end date;
the company name; and warnings for anything you could not place or that looks inconsistent.`;

export const CIT_MAP_SCHEMA = {
  type: 'OBJECT',
  properties: {
    company_name: { type: 'STRING', nullable: true },
    period_end: { type: 'STRING', nullable: true, description: 'YYYY-MM-DD' },
    unit: { type: 'STRING', nullable: true, description: 'naira, thousands or millions as printed' },
    lines: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: { cell: { type: 'STRING' }, amount: { type: 'NUMBER' }, confidence: { type: 'NUMBER' }, source_text: { type: 'STRING' } },
        required: ['cell', 'amount', 'confidence', 'source_text'],
      },
    },
    totals: {
      type: 'OBJECT',
      properties: { revenue: { type: 'NUMBER', nullable: true }, profit_before_tax: { type: 'NUMBER', nullable: true },
        total_assets: { type: 'NUMBER', nullable: true }, total_equity_liabilities: { type: 'NUMBER', nullable: true } },
    },
    warnings: { type: 'ARRAY', items: { type: 'STRING' } },
  },
  required: ['lines', 'totals', 'warnings'],
};

export function catalogueText(lines: TemplateLine[]) {
  return lines.filter((l) => l.cell !== 'USER_INPUT!D7')
    .map((l) => `${l.cell} | ${l.section || l.sheet} | ${l.label}${l.note ? ` (${l.note})` : ''}`).join('\n');
}

export function tbText(rows: TbRow[]) {
  return rows.slice(0, 1500).map((r) => {
    const bal = r.balance ?? ((Number(r.debit) || 0) - (Number(r.credit) || 0));
    return `${r.code ?? ''} | ${r.name} | ${bal >= 0 ? 'Dr' : 'Cr'} ${Math.abs(bal).toFixed(2)}`;
  }).join('\n');
}

// Keep what lands on a real input line, with a usable amount and confidence.
export function cleanCitLines(raw: any[], lines: TemplateLine[]) {
  const cells = new Set(lines.filter((l) => l.cell !== 'USER_INPUT!D7').map((l) => l.cell));
  const out: { cell: string; amount: number; confidence: number; note: string }[] = [];
  const dropped: string[] = [];
  for (const r of raw || []) {
    const cell = String(r?.cell || '').trim();
    const amount = Math.round(Number(r?.amount) * 100) / 100;
    if (!cells.has(cell) || !Number.isFinite(amount) || amount === 0) { if (cell) dropped.push(cell); continue; }
    out.push({ cell, amount, confidence: Math.min(Math.max(Number(r.confidence) || 0, 0), 1), note: String(r.source_text || '').slice(0, 200) });
  }
  return { lines: out, dropped };
}
