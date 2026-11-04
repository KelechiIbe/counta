// The personal income tax computation of a business name or partnership as a pack (the same model the financial
// statements use), so Word, PDF and Excel all say the same thing: the business's assessable profit, how it is shared, each
// person's computation, and the capital allowances. A person whose figures the reader may not see is left out.
import type { Block, PCol, PRow, PSection, PackModel } from './fsPack';

const DATE = (d?: string | null) => (d ? new Date(d.slice(0, 10) + 'T12:00:00Z').toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric', timeZone: 'UTC' }) : '');
const ROLE: Record<string, string> = { proprietor: 'Proprietor', active: 'Partner working in the business', dormant: 'Dormant partner' };
const money = (key: string, label: string): PCol => ({ key, label, type: 'money' });
const rowsOf = (rows: any[], extra?: (r: any) => Record<string, unknown>): PRow[] =>
  (rows || []).map((r) => ({ cells: { line: r.line, basis: r.basis || '', amount: r.amount, ...(extra ? extra(r) : {}) },
    style: r._style === 'memo' ? 'line' : r._style || 'line', indent: 0 }));

export function buildPitPack(d: any, orgName: string): PackModel {
  const comp = d.computation || {};
  const biz = comp.business || {};
  const people: any[] = comp.people || [];
  const law = comp.regime === 'PITA' ? 'the Personal Income Tax Act (as amended), the law for 2025 accounts' : 'the Nigeria Tax Act 2025 and the Nigeria Tax Administration Act 2025';
  const periodText = `for the year ended ${DATE(comp.to)}`;
  const partnership = comp.kind === 'partnership';
  const cols: PCol[] = [{ key: 'line', label: '', type: 'text' }, { key: 'basis', label: 'Basis', type: 'text' }, money('amount', '₦')];
  const sections: PSection[] = [];

  sections.push({ key: 'business', group: 'tax', title: 'The business', subtitle: periodText.replace(/^f/, 'F'), blocks: [
    { t: 'para', text: `Personal income tax computation of ${orgName}, ${partnership ? 'a partnership' : 'a business owned by one person'}, under ${law}, `
      + `for year of assessment ${comp.yoa}. The assessable profit starts from the profit before tax in the accounts; each adjustment shows where it comes from.` },
    { t: 'table', cols, rows: rowsOf(biz.rows) },
  ] });

  if (partnership) {
    const pc: PCol[] = [{ key: 'line', label: 'Partner', type: 'text' }, { key: 'share', label: 'Share', type: 'pct' }, money('pay', 'Pay charged\n₦'),
      money('profit', 'Share of profit\n₦'), money('income', 'From the business\n₦'), { key: 'state', label: 'Taxed by', type: 'text' }];
    sections.push({ key: 'partners', group: 'tax', title: 'How the profit is shared', subtitle: periodText.replace(/^f/, 'F'), wide: true, blocks: [
      { t: 'para', text: 'Each partner is taxed on the pay, interest on capital and benefits the accounts charged for them, and on their share of the profit after those charges '
        + '(NTA 2025 s.15(1)), in the ratio of the partnership agreement, or equally where there is none (s.15(3)). A partner working in the business is taxed by the state of the office '
        + 'he works from, a dormant partner by the state he lives in (Twelfth Schedule para 4).' },
      { t: 'table', cols: pc, rows: people.map((p) => ({ cells: { line: p.name, share: Number(p.share_pct), pay: p.computation?.figures?.remuneration,
        profit: p.computation?.figures?.share_profit, income: p.computation?.figures?.business_income, state: p.authority_name || p.authority || '' }, style: 'line', indent: 0 })) },
    ] });
  }

  for (const p of people) {
    if (p.hidden) continue;
    const f = p.computation?.figures || {};
    const blocks: Block[] = [
      { t: 'kv', items: [['Taxpayer', p.name], ['Tax ID', p.tin || 'Not given'], ['Role', ROLE[p.role] || p.role],
        ...(partnership ? [['Share of the profit', `${Number(p.share_pct)}%`] as [string, string]] : []),
        ['Taxed by', p.authority_name || p.authority || 'Not known'], ['Year of assessment', String(comp.yoa)]] },
      { t: 'table', cols, rows: rowsOf(p.computation?.rows) },
    ];
    const bands: any[] = (p.computation?.bands || []).filter((b: any) => Number(b.slice) > 0);
    if (bands.length) {
      blocks.push({ t: 'heading', level: 3, text: 'Tax band by band' });
      blocks.push({ t: 'table', cols: [{ key: 'line', label: 'Band', type: 'text' }, { key: 'rate', label: 'Rate', type: 'pct' }, money('slice', 'Income in the band\n₦'), money('tax', 'Tax\n₦')],
        rows: bands.map((b) => ({ cells: { line: b.label, rate: Number(b.rate) * 100, slice: b.slice, tax: b.tax }, style: 'line', indent: 0 })) });
    }
    const left = (p.computation?.other_income || []).filter((l: any) => l.treatment !== 'taxable');
    if (left.length) blocks.push({ t: 'para', text: 'Left out of total income: ' + left.map((l: any) => `${l.label} (${l.treatment === 'final' ? 'taxed in full at source' : 'exempt'})`).join('; ') + '.' });
    blocks.push({ t: 'para', text: `Carried forward to the next year: business losses ₦${Number(p.computation?.cf?.losses || 0).toLocaleString('en-NG', { minimumFractionDigits: 2 })}, `
      + `unused capital allowances ₦${Number(p.computation?.cf?.ca || 0).toLocaleString('en-NG', { minimumFractionDigits: 2 })}. Effective rate ${(Number(f.effective_rate || 0) * 100).toFixed(1)}%.` });
    blocks.push({ t: 'sign', items: [{ name: p.name, role: 'Taxpayer' }, { name: '', role: 'Prepared by' }] });
    sections.push({ key: `person_${p.person_id}`, group: 'tax', title: p.name, subtitle: `Personal income tax ${periodText}`, blocks });
  }

  const ca = biz.ca || {};
  if ((ca.assets || []).length) {
    const cc: PCol[] = [{ key: 'line', label: 'Asset', type: 'text' }, { key: 'category', label: 'Category', type: 'text' }, money('qce', 'Cost\n₦'), money('twdv_bf', 'Tax value b/f\n₦'),
      money('allowance', 'Allowance\n₦'), money('twdv_cf', 'Tax value c/f\n₦')];
    sections.push({ key: 'capital_allowances', group: 'tax', title: 'Capital allowances', subtitle: periodText.replace(/^f/, 'F'), wide: true, blocks: [
      { t: 'para', text: comp.regime === 'PITA'
        ? 'Initial and annual allowances under the old law, with ₦10 kept on each asset until it is sold. An asset used partly in private life gets the business share.'
        : 'Annual allowances on cost at the First Schedule rates, with 1% of cost kept until the asset is sold. An asset used partly in private life gets the business share.'
          + (partnership ? ' The allowances are shared in the profit-sharing ratio (First Schedule para 19(3)).' : '') },
      { t: 'table', cols: cc, rows: (ca.assets as any[]).filter((a) => a.qualifies !== false).map((a) => ({ cells: { line: `${a.number ? a.number + ' ' : ''}${a.name}`, category: a.category || '',
        qce: a.qce, twdv_bf: a.twdv_bf, allowance: a.allowance, twdv_cf: a.twdv_cf }, style: 'line', indent: 0 })) },
    ] });
  }

  const attested = d.row?.attested;
  if (attested?.statement) {
    sections.push({ key: 'attestation', group: 'tax', title: 'Statement of accounts', subtitle: '', blocks: [
      { t: 'para', text: attested.statement }, { t: 'para', text: `Confirmed by ${attested.by} on ${DATE(String(attested.at || '').slice(0, 10))}.` },
    ] });
  }

  return {
    orgName, legal: [], reportTitle: 'Personal income tax computation', periodText, endText: DATE(comp.to), framework: '',
    frameworkText: `Year of assessment ${comp.yoa}. Prepared under ${law}${comp.rulebook?.status !== 'approved' ? ', on rules awaiting TaxStreem sign-off' : ''}.`,
    sections, warnings: [], generated: new Date().toISOString(), approvedOn: d.row?.approved_at ? String(d.row.approved_at).slice(0, 10) : null, signers: [],
  };
}
