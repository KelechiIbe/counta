// The companies income tax return written into the Rev360 template. The cell map comes from the database (cit_pack): one
// value per input cell, nothing else. After writing, the template's own formulas are evaluated and must agree with the
// computation Counta approved: profit before tax, add-backs, deductions and a balanced statement of financial position.
import { Workbook } from './xlsx.ts';

export type CellWrite = { sheet: string; addr: string; value: number | string; label?: string };
export type CitPack = {
  org_id: string; year: number; yoa: number; regime: string; draft: boolean; status: string; file_name: string;
  cell_map: CellWrite[]; figures: Record<string, unknown>; org: Record<string, unknown>; declaration: unknown[]; rows: unknown[];
  from: string; to: string; due: string; afs_path: string | null; template_path: string | null; can_send: boolean;
  flux: Record<string, unknown>; checks: unknown[]; approved_by?: string; approved_at?: string;
};
export type Tie = { id: string; label: string; template: number; counta: number; ok: boolean };

const n = (v: unknown) => (typeof v === 'number' ? v : Number(v ?? 0) || 0);

export function fillCit(templateBytes: Uint8Array, pack: CitPack) {
  const wb = new Workbook(templateBytes);
  wb.set('USER_INPUT', 'D7', pack.year);
  const seen = new Set<string>();
  for (const c of pack.cell_map) {
    const key = `${c.sheet}!${c.addr}`;
    if (key === 'USER_INPUT!D7') continue;
    if (seen.has(key)) throw new Error(`${key} appears twice in the cell map.`);
    seen.add(key);
    if (typeof c.value === 'number' && !Number.isFinite(c.value)) throw new Error(`${key} is not a number.`);
    wb.set(c.sheet, c.addr, typeof c.value === 'number' ? Math.round(c.value * 100) / 100 : c.value);
  }
  const f = pack.figures || {};
  const tie = (id: string, label: string, template: number, counta: number): Tie =>
    ({ id, label, template: Math.round(template * 100) / 100, counta: Math.round(counta * 100) / 100, ok: Math.abs(template - counta) < 1 });
  const v = (s: string, a: string) => n(wb.value(s, a));
  const ties: Tie[] = [
    tie('pbt', 'Profit before tax', v('INCOME_STATEMENT', 'E115'), n(f.profit_before_tax)),
    tie('pbt_carried', 'Profit before tax on the adjustment sheet', v('PROFIT_ADJUSTMENT', 'E11'), n(f.profit_before_tax)),
    tie('addbacks', 'Total added back', v('PROFIT_ADJUSTMENT', 'E33'), n(f.addbacks)),
    tie('deductions', 'Total deductions', v('PROFIT_ADJUSTMENT', 'E41'), n(f.deductions)),
    tie('balance', 'Total assets against equity and liabilities', v('STATEMENT_OF_FINANCIAL_POSITION', 'E69'), v('STATEMENT_OF_FINANCIAL_POSITION', 'E127')),
  ];
  const bytes = wb.save();
  return { bytes, ties };
}
