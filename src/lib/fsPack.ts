// Turns the database's financial statements pack into one ordered set of sections (headings, paragraphs, tables,
// company details and signature blocks). The screen, Word, PDF and Excel all draw from this one model, so the
// four always say the same thing.

export type PColType = 'text' | 'note' | 'money' | 'pct' | 'number';
export interface PCol { key: string; label: string; type: PColType }
export interface PRow { cells: Record<string, unknown>; style: string; indent: number }
export type Block =
  | { t: 'heading'; level: 2 | 3; text: string }
  | { t: 'para'; text: string; indent?: number }
  | { t: 'kv'; items: [string, string][] }
  | { t: 'sign'; items: { name: string; role: string }[]; date?: string }
  | { t: 'table'; cols: PCol[]; rows: PRow[] };
export interface PSection { key: string; title: string; subtitle: string; blocks: Block[]; wide?: boolean; group: 'front' | 'statements' | 'notes' | 'other' | 'tax' }
export interface PackModel {
  orgName: string; legal: string[]; reportTitle: string; periodText: string; endText: string; framework: string; sections: PSection[];
  warnings: { level: string; text: string; key?: string }[]; generated: string; approvedOn: string | null; signers: { name: string; role: string; frc_number?: string }[];
}

const DATE = (d?: string | null) => (d ? new Date(d + 'T12:00:00Z').toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric', timeZone: 'UTC' }) : '');
const SHORT = (d?: string | null) => (d ? new Date(d + 'T12:00:00Z').toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' }) : '');
const NUMERIC = new Set(['line', 'subtotal', 'total', 'warning']);
const hasAmount = (r: Record<string, unknown>, keys: string[]) => keys.some((k) => r[k] !== null && r[k] !== undefined && r[k] !== '');

// Accounting style: 1,234,567.89 and (1,234,567.89) for negatives; a dash for nil.
export function acct(v: unknown, dp = 2): string {
  if (v === null || v === undefined || v === '') return '';
  const n = Number(v);
  if (!Number.isFinite(n)) return String(v);
  if (Math.abs(n) < 0.005) return '–';
  const s = Math.abs(n).toLocaleString('en-NG', { minimumFractionDigits: dp, maximumFractionDigits: dp });
  return n < 0 ? `(${s})` : s;
}
export function cellText(col: PCol, v: unknown): string {
  if (col.type === 'money') return acct(v);
  if (col.type === 'pct') return v === null || v === undefined || v === '' ? '' : `${Number(v).toLocaleString('en-NG', { maximumFractionDigits: 1 })}%`;
  if (col.type === 'number') return v === null || v === undefined || v === '' ? '' : acct(v);
  return v === null || v === undefined ? '' : String(v);
}

// Statement rows: everything that is not a paragraph stays in one table, so headings sit inside it as they do in print.
function statementBlocks(rows: any[], cols: PCol[]): Block[] {
  const out: Block[] = [];
  let table: PRow[] | null = null;
  const flush = () => { if (table?.length) out.push({ t: 'table', cols, rows: table }); table = null; };
  for (const r of rows) {
    const st = r._style || 'line';
    if (st === 'text') { flush(); out.push({ t: 'para', text: String(r.line ?? ''), indent: Number(r._indent || 0) }); continue; }
    if (st === 'blank') continue;
    (table ||= []).push({ cells: r, style: st, indent: Number(r._indent || 0) });
  }
  flush();
  return out;
}

// Narrative rows (notes, directors' report): headings become headings, a subheading stays in a table only when
// figures follow it, paragraphs are paragraphs, and runs of figures become small tables.
function narrativeBlocks(rows: any[], cols: PCol[], amountKeys: string[], headingLevel: 2 | 3): Block[] {
  const out: Block[] = [];
  let table: PRow[] | null = null;
  let kv: [string, string][] | null = null;
  let sign: { name: string; role: string }[] | null = null;
  const flush = () => {
    if (table?.length) out.push({ t: 'table', cols, rows: table });
    if (kv?.length) out.push({ t: 'kv', items: kv });
    if (sign?.length) out.push({ t: 'sign', items: sign });
    table = null; kv = null; sign = null;
  };
  rows.forEach((r, i) => {
    const st = r._style || 'line';
    const next = rows[i + 1];
    if (st === 'kv') { if (table || sign) flush(); (kv ||= []).push([String(r.line ?? ''), String(r.text ?? '')]); return; }
    if (st === 'signature') { if (table || kv) flush(); (sign ||= []).push({ name: /^[.\s]*$/.test(String(r.line ?? '')) ? '' : String(r.line), role: String(r.text ?? '') }); return; }
    if (st === 'heading') { flush(); out.push({ t: 'heading', level: headingLevel, text: String(r.line ?? '') }); return; }
    if (st === 'subheading') {
      const figuresFollow = next && NUMERIC.has(next._style || 'line') && hasAmount(next, amountKeys);
      if (figuresFollow) { if (kv || sign) flush(); (table ||= []).push({ cells: r, style: st, indent: Number(r._indent || 0) }); return; }
      flush(); out.push({ t: 'heading', level: 3, text: String(r.line ?? '') }); return;
    }
    if (st === 'text') { flush(); out.push({ t: 'para', text: String(r.line ?? ''), indent: Number(r._indent || 0) }); return; }
    if (st === 'blank') return;
    if (kv || sign) flush();
    (table ||= []).push({ cells: r, style: st, indent: Number(r._indent || 0) });
  });
  flush();
  return out;
}

export function buildPack(pack: any, signersOverride?: { name: string; role: string; frc_number?: string }[]): PackModel {
  const o = pack.org || {};
  const p = pack.periods || {};
  const sme = o.framework === 'ifrs_sme';
  const framework = sme ? 'IFRS for SMEs Accounting Standard' : 'IFRS Accounting Standards';
  const full = !!p.full_year;
  const endText = DATE(p.to);
  const periodText = full ? `for the year ended ${endText}` : `for the period ended ${endText}`;
  const cur = SHORT(p.to);
  const priorPl = SHORT(p.prior_to);
  const priorBs = SHORT(p.balance_prior_to || p.prior_to);
  const money = (key: string, label: string): PCol => ({ key, label, type: 'money' });
  const lineCol: PCol = { key: 'line', label: '', type: 'text' };
  const noteCol: PCol = { key: 'note', label: 'Note', type: 'note' };
  const bsCols = [lineCol, noteCol, money('current', `${cur}\n₦`), money('prior', `${priorBs}\n₦`)];
  const plCols = [lineCol, noteCol, money('current', `${cur}\n₦`), money('prior', `${priorPl}\n₦`)];
  const noteCols = [lineCol, money('current', `${cur}\n₦`), money('prior', `Comparative\n₦`)];
  const signers = signersOverride || (pack.signing_directors || []);
  const approvedOn = o.fs_narrative?.approved_on || null;

  const sections: PSection[] = [];
  const add = (s: PSection) => sections.push(s);

  add({ key: 'corporate', group: 'front', title: 'Corporate information', subtitle: '', blocks: narrativeBlocks(pack.corporate?.rows || [], [], [], 2) });
  add({ key: 'directors_report', group: 'front', title: "Report of the directors", subtitle: periodText.replace(/^f/, 'F'),
    blocks: narrativeBlocks(pack.directors_report?.rows || [], [lineCol, money('current', `${cur}\n₦`), money('prior', `${priorPl}\n₦`)], ['current', 'prior'], 3) });
  add({ key: 'responsibilities', group: 'front', title: "Statement of directors' responsibilities", subtitle: `In relation to the financial statements ${periodText}`,
    blocks: narrativeBlocks(pack.responsibilities?.rows || [], [], [], 3) });

  const approval: Block[] = [
    { t: 'para', text: `The financial statements were approved by the Board of Directors on ${approvedOn ? DATE(approvedOn) : '........................................'} and signed on its behalf by:` },
    { t: 'sign', items: signerItems(signers) },
  ];
  add({ key: 'sopl', group: 'statements', title: 'Statement of profit or loss and other comprehensive income', subtitle: periodText.replace(/^f/, 'F'), blocks: statementBlocks(pack.sopl?.rows || [], plCols) });
  add({ key: 'sofp', group: 'statements', title: 'Statement of financial position', subtitle: `As at ${endText}`, blocks: [...statementBlocks(pack.sofp?.rows || [], bsCols), ...approval] });
  const soceCols: PCol[] = [{ key: 'component', label: '', type: 'text' }, money('opening', 'Opening\n₦'), money('profit', 'Profit or loss\n₦'), money('oci', 'Other comprehensive income\n₦'),
    money('capital', 'Shares issued\n₦'), money('dividends', 'Dividends\n₦'), money('other', 'Other\n₦'), money('closing', 'Closing\n₦')];
  add({ key: 'soce', group: 'statements', title: 'Statement of changes in equity', subtitle: periodText.replace(/^f/, 'F'), wide: true,
    blocks: statementBlocks((pack.soce?.rows || []).map((r: any) => ({ ...r, line: r.component })), soceCols) });
  add({ key: 'cash_flow', group: 'statements', title: 'Statement of cash flows', subtitle: periodText.replace(/^f/, 'F'), blocks: statementBlocks(pack.cash_flow?.rows || [], plCols) });
  add({ key: 'notes', group: 'notes', title: 'Notes to the financial statements', subtitle: periodText.replace(/^f/, 'F'), blocks: narrativeBlocks(pack.notes?.rows || [], noteCols, ['current', 'prior'], 2) });
  const vaCols: PCol[] = [lineCol, money('current', `${cur}\n₦`), { key: 'current_pct', label: '%', type: 'pct' }, money('prior', `${priorPl}\n₦`), { key: 'prior_pct', label: '%', type: 'pct' }];
  add({ key: 'value_added', group: 'other', title: 'Statement of value added', subtitle: periodText.replace(/^f/, 'F'), blocks: statementBlocks(pack.value_added?.rows || [], vaCols) });
  const years: { key: string; label: string }[] = pack.five_year?.extra?.columns || [];
  const fyCols: PCol[] = [lineCol, ...years.map((y) => ({ key: y.key, label: `${y.label}\n₦`, type: 'money' as PColType }))];
  add({ key: 'five_year', group: 'other', title: 'Five-year financial summary', subtitle: `As at and for the years ended ${years.length ? years[0].label.slice(-4) : ''}`.trim(),
    blocks: statementBlocks((pack.five_year?.rows || []).map((r: any) => r._number ? { ...r, _style: 'line' } : r), fyCols) });

  // The tax computation and capital allowance schedule go out with the statements, as the tax return needs them.
  if (pack.tax_computation) {
    const tc = pack.tax_computation;
    const fig = tc.extra?.figures || {};
    const set = tc.extra?.settings || {};
    const flags: { level: string; text: string }[] = tc.extra?.flags || [];
    const taxCols: PCol[] = [lineCol, { key: 'basis', label: 'Basis', type: 'text' }, money('current', `${cur}\n₦`)];
    const legacy = fig.regime === 'LEGACY_CITA';
    const small = !fig.small_company ? '' : legacy ? 'The company is a small company (turnover up to ₦25 million), so no companies income tax or tertiary education tax is charged.'
      : 'The company is a small company (turnover and fixed assets within the limits), so no companies income tax or development levy is charged.';
    const intro: Block[] = [{ t: 'para', text: `Companies income tax computation under the ${fig.law || (legacy ? 'Companies Income Tax Act' : 'Nigeria Tax Act 2025')}, from the statement of profit or loss ${periodText}. `
      + `Each adjustment shows where its figure comes from. ${small}`.trim() }];
    const posted: Block[] = set.posted_ref ? [{ t: 'para', text: `The charge was posted to the accounts in ${set.posted_ref}.` }] : [];
    const notes: Block[] = flags.length ? [{ t: 'heading', level: 3, text: 'Points to check' }, ...flags.map((f) => ({ t: 'para', text: f.text } as Block))] : [];
    add({ key: 'tax_computation', group: 'tax', title: 'Tax computation', subtitle: periodText.replace(/^f/, 'F'),
      blocks: [...intro, ...statementBlocks((tc.rows || []).map((r: any) => (r.memo ? { ...r, _style: 'line' } : r)), taxCols), ...posted, ...notes] });
  }
  if (pack.capital_allowances) {
    const ca = pack.capital_allowances;
    const cls: PCol[] = [{ key: 'line', label: 'Class', type: 'text' }, { key: 'rate_pct', label: 'Rate', type: 'pct' }, money('twdv_bf', 'Tax value b/f\n₦'), money('additions', 'Additions\n₦'),
      money('disposals', 'Disposals\n₦'), money('allowance', 'Allowance\n₦'), money('balancing_charge', 'Balancing charge\n₦'), money('balancing_allowance', 'Balancing allowance\n₦'),
      money('twdv_cf', 'Tax value c/f\n₦')];
    const assets: any[] = ca.extra?.assets || [];
    const assetRows = assets.map((a) => ({ ...a, line: `${a.number} ${a.name} (in use ${SHORT(a.in_use)})`, rate_pct: a.rate != null ? Number(a.rate) * 100 : null, _style: 'line', _indent: 0 }));
    const months = Number(ca.extra?.months || 12);
    const caText = ca.extra?.regime === 'LEGACY_CITA'
      ? 'Initial allowance in the year an asset is first used and annual allowances on the rest, at the Second Schedule rates of the Companies Income Tax Act, '
        + 'for assets owned and in use at the end of the period, with ₦10 kept on each asset until it is sold. Allowances used in a year are limited to two-thirds of assessable profit '
        + '(not for manufacturing and agro-allied companies); what is not used carries forward.'
      : `Annual allowances on cost at the First Schedule rates, a full year for each asset owned and in use at the end of the period${months < 12 ? `, shared for a period of ${months} months` : ''}, `
        + `with ${Math.round(Number(ca.extra?.retention ?? 0.01) * 100)}% of cost kept until the asset is sold. Assets in use before the period have had one year's allowance for each earlier year end.`;
    add({ key: 'capital_allowances', group: 'tax', title: 'Capital allowances', subtitle: periodText.replace(/^f/, 'F'), wide: true, blocks: [
      { t: 'para', text: caText },
      ...statementBlocks(ca.rows || [], cls),
      ...(assetRows.length ? [{ t: 'heading', level: 3, text: 'Asset by asset' } as Block, ...statementBlocks(assetRows, [{ ...cls[0], label: 'Asset' }, ...cls.slice(1)])] : []),
    ] });
  }

  return {
    orgName: o.name || '', legal: [o.rc_number ? `Company registration number ${String(o.rc_number).replace(/^RC[\s:]*/i, 'RC ')}` : '', o.tin ? `Tax identification number ${o.tin}` : ''].filter(Boolean),
    reportTitle: 'Financial statements', periodText, endText, framework, sections, warnings: pack.warnings || [], generated: pack.generated_at || new Date().toISOString(), approvedOn,
    signers,
  };
}

export function signerItems(signers: { name: string; role: string; frc_number?: string }[]): { name: string; role: string }[] {
  const list = signers.length ? signers.slice(0, 2) : [{ name: '', role: 'Director' }, { name: '', role: 'Director' }];
  while (list.length < 2) list.push({ name: '', role: 'Director' });
  return list.map((s) => ({ name: s.name || '', role: `${s.role || 'Director'} · ${s.frc_number ? 'FRC/' + String(s.frc_number).replace(/^FRC\//i, '') : 'FRC/....................'}` }));
}

export const SECTION_TITLES: Record<string, string> = {
  corporate: 'Corporate information', directors_report: "Directors' report", responsibilities: "Directors' responsibilities", sopl: 'Profit or loss',
  sofp: 'Financial position', soce: 'Changes in equity', cash_flow: 'Cash flows', notes: 'Notes', value_added: 'Value added', five_year: 'Five-year summary',
  tax_computation: 'Tax computation', capital_allowances: 'Capital allowances',
};
