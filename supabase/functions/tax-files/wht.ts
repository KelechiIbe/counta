// Withholding tax schedules on the official templates: the NRS schedule (130 rows a file, as the template holds; more rows
// make more files) and the state schedule (one file per state service, rows added as needed). The template's own formulas
// compute the tax; each file says whether they agree with what Counta deducted.
import { serial, Workbook } from './xlsx.ts';

export type WhtRow = {
  beneficiary_name: string; beneficiary_type: string | null; beneficiary_number: string | null; address: string | null; transaction_date: string;
  description: string; amount: number; transaction_type: string | null; recipient_type: string; resident_type: string; rate: number; wht: number;
};
export type WhtSchedule = { authority: string; kind: string; period: string; authority_name: string; rows: WhtRow[]; total: number;
  checks: { severity: string; text: string }[]; org: { name: string; tin: string | null } };
export type WhtFile = { name: string; bytes: Uint8Array; rows: number; total: number; template_total: number; mismatches: { row: number; counta: number; template: number }[] };

const NRS_FIRST = 6, NRS_ROWS = 130;
const r2 = (n: number) => Math.round(n * 100) / 100;
const num = (v: unknown) => (typeof v === 'number' ? v : Number(v) || 0);

export function nrsFiles(template: Uint8Array, s: WhtSchedule, baseName: string): WhtFile[] {
  const out: WhtFile[] = [];
  for (let start = 0; start < s.rows.length; start += NRS_ROWS) {
    const part = s.rows.slice(start, start + NRS_ROWS);
    const wb = new Workbook(template.slice());
    part.forEach((r, i) => {
      const row = NRS_FIRST + i;
      wb.set('WHT', `B${row}`, r.beneficiary_name);
      wb.set('WHT', `C${row}`, r.beneficiary_type ?? '');
      wb.set('WHT', `D${row}`, r.beneficiary_number ?? '');
      wb.set('WHT', `E${row}`, serial(r.transaction_date));
      wb.set('WHT', `F${row}`, r.description);
      wb.set('WHT', `G${row}`, r2(num(r.amount)));
      wb.set('WHT', `H${row}`, r.transaction_type ?? '');
      wb.set('WHT', `I${row}`, r.recipient_type);
      wb.set('WHT', `J${row}`, r.resident_type);
    });
    const mismatches: WhtFile['mismatches'] = [];
    let tt = 0;
    part.forEach((r, i) => {
      const k = num(wb.value('WHT', `K${NRS_FIRST + i}`));
      tt += k;
      if (Math.abs(k - num(r.wht)) >= 0.05) mismatches.push({ row: NRS_FIRST + i, counta: num(r.wht), template: r2(k) });
    });
    const n = Math.floor(start / NRS_ROWS) + 1, many = s.rows.length > NRS_ROWS;
    out.push({ name: many ? baseName.replace(/\.xlsx$/, `_${n}.xlsx`) : baseName, bytes: wb.save(), rows: part.length,
      total: r2(part.reduce((a, r) => a + num(r.wht), 0)), template_total: r2(tt), mismatches });
  }
  return out;
}

export function stateFile(template: Uint8Array, s: WhtSchedule, name: string): WhtFile {
  const wb = new Workbook(template.slice());
  const first = 3;
  s.rows.forEach((r, i) => {
    const row = first + i;
    if (i > 0) wb.cloneRow('WHT', first, row);
    wb.set('WHT', `A${row}`, r.beneficiary_name);
    wb.set('WHT', `B${row}`, r.beneficiary_number ?? '');
    wb.set('WHT', `C${row}`, serial(r.transaction_date));
    wb.set('WHT', `D${row}`, r.description);
    wb.set('WHT', `E${row}`, r2(num(r.amount)));
    wb.set('WHT', `F${row}`, num(r.rate));
  });
  const mismatches: WhtFile['mismatches'] = [];
  let tt = 0;
  s.rows.forEach((r, i) => {
    const g = num(wb.value('WHT', `G${first + i}`));
    tt += g;
    if (Math.abs(g - num(r.wht)) >= 0.05) mismatches.push({ row: first + i, counta: num(r.wht), template: r2(g) });
  });
  return { name, bytes: wb.save(), rows: s.rows.length, total: r2(s.rows.reduce((a, r) => a + num(r.wht), 0)), template_total: r2(tt), mismatches };
}
