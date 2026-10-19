// Ledgers and reports: trial balance, general ledger, journal register, chart of accounts, fixed asset register, customer and
// vendor sub-ledgers and ageing, VAT return and WHT schedule. Any of them, or all at once, to Excel, PDF or CSV.
import { useMemo, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { useScreenPeriod } from '../../lib/period';
import { useInventory, useSession } from '../../state/session';
import { rpc } from '../../lib/supabase';
import { monthStart, today, useChart, yearStart, type Report } from '../../lib/api';
import { AREPORTS, areport, periodLabel, prepRows, type AGroup } from '../../lib/accounting';
import { ExportMenu, PeriodBar, ReportPanel, checkLines, useMeta, type Period } from '../../components/Books';
import JournalDrawer from '../../components/JournalDrawer';

const GROUPS: AGroup[] = ['Ledgers', 'Customers & vendors', 'Tax'];

export default function Ledgers() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const qc = useQueryClient();
  const chart = useChart();
  const [id, setId] = useState('trial_balance');
  const [period, setPeriod] = useScreenPeriod(orgId, 'ledgers', 'ytd', inv?.org.fiscal_year_start || 1);
  const [accounts, setAccounts] = useState<string[]>([]);
  const [journal, setJournal] = useState<string | null>(null);
  const meta = useMeta();
  const def = areport(id);
  const list = AREPORTS.filter((r) => GROUPS.includes(r.group));
  const postable = useMemo(() => (chart.data?.accounts || []).filter((a: any) => !a.is_group), [chart.data]);
  if (!inv) return null;
  const vatPeriod = id === 'vat_return' ? { from: monthStart(period.to), to: period.to } : period;
  async function pack() {
    const ids = list.map((r) => r.id);
    const reps = await Promise.all(ids.map((r) => {
      const d = areport(r);
      const from = d.period === 'asAt' ? null : r === 'vat_return' ? monthStart(period.to) : period.from;
      return qc.fetchQuery({ queryKey: ['report', r, from, period.to, '{}', orgId], queryFn: () => rpc<Report>('accounting_report', { p_org: orgId, p_report: r, p_from: from, p_to: period.to, p_options: {} }) });
    }));
    return reps.map((rep, i) => {
      const d = areport(ids[i]);
      return { meta: meta(d.title, d.period === 'asAt' ? periodLabel(null, period.to) : periodLabel(period.from, period.to)), cols: d.cols(rep.extra).filter((c) => inv!.can_see_costs || !c.cost), rows: prepRows(d, rep.rows), extra: checkLines(d.id, rep.extra).map((c) => c.text) };
    });
  }
  return (
    <div className="container" style={{ maxWidth: 1400 }}>
      <div className="row wrap" style={{ justifyContent: 'space-between', gap: 10 }}>
        <PeriodBar value={period} onChange={setPeriod} asAt={def.period === 'asAt'} />
        <ExportMenu name={`${inv.org.name} ledgers ${period.to}`} sheets={pack} cover={meta('Ledgers and schedules', periodLabel(period.from, period.to))} />
      </div>
      <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '240px minmax(0,1fr)', gap: 16, alignItems: 'start' }}>
        <div className="card" style={{ padding: 8 }}>
          {GROUPS.map((g) => (
            <div key={g}>
              <div className="mini-label" style={{ padding: '10px 10px 4px' }}>{g}</div>
              {list.filter((r) => r.group === g).map((r) => (
                <button key={r.id} className={'nav-item' + (r.id === id ? ' active' : '')} style={{ fontSize: 14, padding: '8px 10px' }} onClick={() => setId(r.id)}>{r.title}</button>
              ))}
            </div>
          ))}
        </div>
        <div className="stack" style={{ gap: 10, minWidth: 0 }}>
          <div className="muted" style={{ fontSize: 13 }}>{def.blurb}</div>
          {def.accounts && (
            <div className="row wrap" style={{ gap: 6 }}>
              <select className="input input-sm" style={{ maxWidth: 360 }} value="" onChange={(e) => e.target.value && setAccounts([...new Set([...accounts, e.target.value])])} aria-label="Add an account">
                <option value="">{accounts.length ? 'Add another account' : 'All accounts (or pick some)'}</option>{postable.map((a: any) => <option key={a.code} value={a.code}>{a.code} {a.name}</option>)}
              </select>
              {accounts.map((a) => <button key={a} className="pill on" onClick={() => setAccounts(accounts.filter((x) => x !== a))}>{a} ×</button>)}
            </div>
          )}
          <ReportPanel id={id} period={vatPeriod} options={def.accounts && accounts.length ? { accounts } : {}}
            onRow={(r) => (typeof r.ref === 'string' && /^JE-/.test(r.ref) ? setJournal(r.ref) : undefined)} />
        </div>
      </div>
      {journal && <JournalDrawer journalRef={journal} onClose={() => setJournal(null)} />}
    </div>
  );
}
