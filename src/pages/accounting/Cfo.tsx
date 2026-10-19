// The CFO pack: headline numbers, an AI commentary written over the ledger's own figures, ratios, management accounts by
// month, twelve-month trends, budget against actual, a 13-week cash forecast and sales analysis. One click exports the
// board pack.
import { useEffect, useMemo, useRef, useState } from 'react';
import { useScreenPeriod } from '../../lib/period';
import { useQueryClient } from '@tanstack/react-query';
import { can, useInventory, useSession, useToast } from '../../state/session';
import { rpc } from '../../lib/supabase';
import { edge, money, today, useReport, yearStart, type Report } from '../../lib/api';
import { areport, periodLabel, prepRows } from '../../lib/accounting';
import { K, N2, P, kpiFont } from '../../lib/format';
import { Icon } from '../../components/Icon';
import { Alert, Modal, ModalHead, Pills, SkeletonRows, Spinner } from '../../components/ui';
import { ExportMenu, PeriodBar, ReportPanel, checkLines, useMeta, type Period } from '../../components/Books';

type Tab = 'ratios' | 'management_accounts' | 'trends' | 'budget_vs_actual' | 'cash_forecast' | 'sales_analysis';
const PACK = ['sofp', 'sopl', 'cash_flow', 'ratios', 'management_accounts', 'trends', 'budget_vs_actual', 'cash_forecast', 'ar_aging', 'ap_aging'];

export default function Cfo() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const qc = useQueryClient();
  const toast = useToast();
  const [tab, setTab] = useState<Tab>('ratios');
  const [period, setPeriod] = useScreenPeriod(orgId, 'cfo', 'ytd', inv?.org.fiscal_year_start || 1);
  const [by, setBy] = useState('item');
  const [comment, setComment] = useState<any>(null);
  const [writing, setWriting] = useState(false);
  const [budget, setBudget] = useState(false);
  const kpis = useReport('kpis', period.from, period.to);
  const trends = useReport('trends', null, period.to);
  const meta = useMeta();
  if (!inv) return null;
  const k = kpis.data?.rows?.[0] || {};
  async function write() {
    setWriting(true);
    const r = await edge<{ commentary: any }>('atlas', { action: 'commentary', org_id: orgId, from: period.from, to: period.to });
    if (r.ok === false) toast(r.error || 'Could not write the commentary.', 'err'); else setComment(r.commentary);
    setWriting(false);
  }
  async function pack() {
    const reps = await Promise.all(PACK.map((r) => {
      const d = areport(r);
      const from = d.period === 'asAt' ? null : period.from;
      return qc.fetchQuery({ queryKey: ['report', r, from, period.to, '{}', orgId], queryFn: () => rpc<Report>('accounting_report', { p_org: orgId, p_report: r, p_from: from, p_to: period.to, p_options: {} }) });
    }));
    const sheets = reps.map((rep, i) => {
      const d = areport(PACK[i]);
      return { meta: meta(d.title, d.period === 'asAt' ? periodLabel(null, period.to) : periodLabel(period.from, period.to)), cols: d.cols(rep.extra).filter((c) => inv!.can_see_costs || !c.cost), rows: prepRows(d, rep.rows), extra: checkLines(d.id, rep.extra).map((c) => c.text) };
    });
    if (comment) {
      sheets.unshift({ meta: meta('Commentary', periodLabel(period.from, period.to)), cols: [{ key: 'line', label: 'Commentary' }],
        rows: [{ line: comment.headline, _style: 'heading' }, ...(comment.points || []).flatMap((p: any) => [{ line: p.title, _style: 'subheading' }, { line: p.detail, _style: 'text' }]),
          { line: 'What to do', _style: 'heading' }, ...(comment.actions || []).map((a: string) => ({ line: a, _style: 'text' }))] as any, extra: [] });
    }
    return sheets;
  }
  const tiles: [string, string, string?][] = [
    ['Revenue this month', N2(k.revenue_mtd), k.revenue_last_month != null ? `last month ${K(k.revenue_last_month)}` : undefined],
    ['Profit this month', N2(k.profit_mtd), k.profit_last_month != null ? `last month ${K(k.profit_last_month)}` : undefined],
    ['Cash', N2(k.cash), k.runway_months != null ? (Number(k.runway_months) > 0 ? `${k.runway_months} months of runway` : 'Spending more than it earns') : undefined],
    ['Customers owe', N2(k.receivables), Number(k.receivables_overdue) ? `${K(k.receivables_overdue)} overdue` : undefined],
    ['We owe suppliers', N2(k.payables), k.bills_to_pay ? `${k.bills_to_pay} bills to pay` : undefined],
    Number(k.vat_payable) < 0 ? ['VAT credit', N2(-k.vat_payable), 'input VAT to carry forward'] : ['VAT to pay', N2(Number(k.vat_payable || 0)), 'due by the 21st of next month'],
  ];
  return (
    <div className="container" style={{ maxWidth: 1400 }}>
      <div className="row wrap" style={{ justifyContent: 'space-between', gap: 10 }}>
        <PeriodBar value={period} onChange={setPeriod} />
        <ExportMenu name={`${inv.org.name} board pack ${period.to}`} sheets={pack} cover={meta('Board pack', periodLabel(period.from, period.to), 'Management information prepared by Counta from the ledger. Not audited.')} />
      </div>
      {kpis.error ? <Alert kind="yellow" icon="shield">{(kpis.error as Error).message}</Alert> : (
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill,minmax(200px,1fr))', gap: 12 }}>
          {kpis.isLoading ? <SkeletonRows n={3} /> : tiles.map(([l, v, s]) => (
            <div key={l} className="card card-pad"><div className="label">{l}</div><div className="num kpi-val" title={v} style={{ fontSize: kpiFont(v) }}>{v}</div>{s && <div className="faint" style={{ fontSize: 12, marginTop: 4 }}>{s}</div>}</div>
          ))}
        </div>
      )}
      <Trend rows={trends.data?.rows || []} />
      <div className="card card-pad stack" style={{ gap: 10 }}>
        <div className="row" style={{ justifyContent: 'space-between' }}>
          <div className="row"><Icon name="sparkles" size={18} color="#7C3AED" /><b>Finance director's commentary</b></div>
          <button className="btn btn-secondary btn-sm" disabled={writing} onClick={write}>{writing ? <><Spinner small />Writing…</> : comment ? 'Write it again' : 'Write it'}</button>
        </div>
        {!comment ? <div className="muted" style={{ fontSize: 13 }}>Atlas reads this period's numbers (profit, ratios, trends, who owes what) and writes what matters, why, and what to do. It never changes a figure.</div> : (
          <div className="stack" style={{ gap: 10 }}>
            <div style={{ fontSize: 16, fontWeight: 600 }}>{comment.headline}</div>
            {(comment.points || []).map((p: any, i: number) => (
              <div key={i} className="row" style={{ alignItems: 'flex-start', gap: 10 }}>
                <span style={{ width: 8, height: 8, borderRadius: 4, marginTop: 7, flex: 'none', background: p.tone === 'good' ? '#22C55E' : p.tone === 'bad' ? '#DC2626' : '#F59E0B' }} />
                <div><b>{p.title}.</b> <span className="ink3">{p.detail}</span></div>
              </div>
            ))}
            {(comment.actions || []).length > 0 && <div><div className="label" style={{ marginBottom: 4 }}>What to do</div>{comment.actions.map((a: string, i: number) => <div key={i} style={{ fontSize: 14 }}>· {a}</div>)}</div>}
            {(comment.questions || []).length > 0 && <div><div className="label" style={{ marginBottom: 4 }}>Questions to look into</div>{comment.questions.map((a: string, i: number) => <div key={i} style={{ fontSize: 14 }}>· {a}</div>)}</div>}
          </div>
        )}
      </div>
      <div className="row wrap" style={{ justifyContent: 'space-between' }}>
        <Pills value={tab} onChange={setTab} options={[{ id: 'ratios', label: 'Ratios' }, { id: 'management_accounts', label: 'By month' }, { id: 'trends', label: 'Trends' },
          { id: 'budget_vs_actual', label: 'Budget' }, { id: 'cash_forecast', label: 'Cash forecast' }, { id: 'sales_analysis', label: 'Sales analysis' }]} />
        {tab === 'sales_analysis' && <select className="input input-sm" style={{ width: 'auto' }} value={by} onChange={(e) => setBy(e.target.value)} aria-label="Group by">
          {areport('sales_analysis').by!.map((b) => <option key={b} value={b}>By {b.replace('_', ' ')}</option>)}</select>}
        {tab === 'budget_vs_actual' && can(inv, 'keep_books') && <button className="btn btn-secondary btn-sm" onClick={() => setBudget(true)}><Icon name="pencil" size={14} />Set the budget</button>}
      </div>
      <ReportPanel id={tab} period={period} options={tab === 'sales_analysis' ? { by } : {}} />
      {budget && <BudgetEditor onClose={() => setBudget(false)} />}
    </div>
  );
}

// Revenue and profit, twelve months, as bars.
// Revenue and profit by month on one scale, with losses drawn below the zero line.
function Trend({ rows }: { rows: any[] }) {
  const box = useRef<HTMLDivElement>(null);
  const [W, setW] = useState(720);
  useEffect(() => {
    const el = box.current;
    if (!el || typeof ResizeObserver === 'undefined') return;
    const ro = new ResizeObserver(([e]) => setW(Math.max(280, Math.round(e.contentRect.width))));
    ro.observe(el);
    return () => ro.disconnect();
  }, [rows.length > 0]); // eslint-disable-line react-hooks/exhaustive-deps
  if (!rows.length) return null;
  const rev = rows.map((r) => Number(r.revenue) || 0);
  const pro = rows.map((r) => Number(r.profit) || 0);
  const top = Math.max(1, ...rev, ...pro);
  const bottom = Math.min(0, ...rev, ...pro);
  const H = 170; const padT = 8; const padB = 22; const left = 52;
  const plot = H - padT - padB;
  const y = (v: number) => padT + ((top - v) / (top - bottom)) * plot;
  const zero = y(0);
  const step = (W - left) / rows.length;
  const bw = Math.max(4, Math.min(12, step / 3.2));
  return (
    <div className="card card-pad">
      <div className="row" style={{ justifyContent: 'space-between', marginBottom: 10 }}><b>Last twelve months</b>
        <span className="row" style={{ gap: 12, fontSize: 12 }}>
          <span className="row" style={{ gap: 4 }}><span style={{ width: 10, height: 10, background: '#0072F5', borderRadius: 2 }} />Revenue</span>
          <span className="row" style={{ gap: 4 }}><span style={{ width: 10, height: 10, background: '#22C55E', borderRadius: 2 }} />Profit</span>
          <span className="row" style={{ gap: 4 }}><span style={{ width: 10, height: 10, background: '#DC2626', borderRadius: 2 }} />Loss</span>
        </span></div>
      <div ref={box} style={{ width: '100%' }}>
      <svg viewBox={`0 0 ${W} ${H}`} width={W} height={H} role="img" aria-label="Revenue and profit for the last twelve months" style={{ display: 'block', overflow: 'visible' }}>
        {zero - y(top) > 12 && <text x={left - 6} y={y(top) + 4} textAnchor="end" fontSize="10" fill="#9CA3AF">{K(top)}</text>}
        {bottom < 0 && y(bottom) - zero > 12 && <text x={left - 6} y={y(bottom) + 4} textAnchor="end" fontSize="10" fill="#9CA3AF">{K(bottom)}</text>}
        <text x={left - 6} y={zero + 3} textAnchor="end" fontSize="10" fill="#9CA3AF">0</text>
        <line x1={left} x2={W} y1={zero} y2={zero} stroke="#D1D5DB" strokeWidth="1" />
        {rows.map((r, i) => {
          const cx = left + step * i + step / 2;
          const bar = (v: number, x: number, fill: string) => <rect x={x} width={bw} y={Math.min(y(v), zero)} height={Math.max(Math.abs(y(v) - zero), v ? 1 : 0)} rx="1.5" fill={fill} />;
          return (
            <g key={r.month}>
              <title>{`${r.month}: revenue ${N2(rev[i])}, ${pro[i] < 0 ? 'loss' : 'profit'} ${N2(Math.abs(pro[i]))}${r.gross_margin != null ? `, gross margin ${P(r.gross_margin)}` : ''}`}</title>
              {bar(rev[i], cx - bw - 1, '#0072F5')}
              {bar(pro[i], cx + 1, pro[i] < 0 ? '#DC2626' : '#22C55E')}
              <text x={cx} y={H - 6} textAnchor="middle" fontSize="10" fill="#9CA3AF">{String(r.month).slice(0, 3)}</text>
            </g>
          );
        })}
      </svg>
      </div>
    </div>
  );
}

function BudgetEditor({ onClose }: { onClose: () => void }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const [year, setYear] = useState(Number(today().slice(0, 4)));
  const ma = useReport('management_accounts', `${year - 1}-01-01`, `${year - 1}-12-31`);
  const [vals, setVals] = useState<Record<string, string>>({});
  const [growth, setGrowth] = useState('10');
  const rows = useMemo(() => (ma.data?.rows || []).filter((r: any) => r.code), [ma.data]);
  if (!inv) return null;
  async function save() {
    const lines: any[] = [];
    for (const r of rows) {
      const annual = vals[r.code] !== undefined ? money(vals[r.code]) : Number(r.total) * (1 + (Number(growth) || 0) / 100);
      if (annual == null) continue;
      for (let m = 1; m <= 12; m++) lines.push({ account_code: r.code, month: `${year}-${String(m).padStart(2, '0')}-01`, amount: Math.round((annual / 12) * 100) / 100 });
    }
    try { await rpc('save_budget', { p_org: orgId, p_lines: lines }); toast('Budget saved'); await qc.invalidateQueries({ queryKey: ['report'] }); onClose(); } catch (e) { toast((e as Error).message, 'err'); }
  }
  return (
    <Modal onClose={onClose} width={720}>
      <ModalHead title={`Budget for ${year}`} sub="Starts from last year's actual plus growth. Change any line; it is spread evenly over the months." onClose={onClose} />
      <div className="modal-body">
        <div className="row wrap"><select className="input input-sm" style={{ width: 'auto' }} value={year} onChange={(e) => setYear(Number(e.target.value))}>{[0, 1].map((d) => <option key={d} value={Number(today().slice(0, 4)) + d}>{Number(today().slice(0, 4)) + d}</option>)}</select>
          <span className="muted" style={{ fontSize: 13 }}>Growth on last year</span><input className="input input-sm" style={{ width: 80 }} value={growth} onChange={(e) => setGrowth(e.target.value)} />%</div>
        {ma.isLoading ? <SkeletonRows n={5} /> : !rows.length ? <Alert kind="grey" icon="info">No income or expenses last year to start from. Type the annual figures once you have a month of trading.</Alert> : (
          <div className="card" style={{ maxHeight: 400, overflow: 'auto' }}>
            {rows.map((r: any) => (
              <div key={r.code} className="tr" style={{ gridTemplateColumns: 'minmax(0,1fr) 130px 150px' }}>
                <span className="ellipsis">{r.code} {r.account}</span><span className="right num faint">{N2(r.total)}</span>
                <input className="input input-sm num" inputMode="decimal" value={vals[r.code] ?? String(Math.round(Number(r.total) * (1 + (Number(growth) || 0) / 100)))} onChange={(e) => setVals({ ...vals, [r.code]: e.target.value })} aria-label={`Budget for ${r.account}`} />
              </div>
            ))}
          </div>
        )}
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={!rows.length} onClick={save}>Save budget</button></div>
    </Modal>
  );
}
