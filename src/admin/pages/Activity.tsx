import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { rpc } from '../../lib/supabase';
import { N, num, when } from '../../lib/format';
import { Alert, Pills, SkeletonRows } from '../../components/ui';
import { tidyError } from '../api';
import { Card, grid, PageHead } from '../ui';

type Act = {
  since: string; messages: Record<string, number>; calls: Record<string, number>; ai: Record<string, number>; martina: Record<string, number>;
  payouts: Record<string, { count: number; amount: number }>; payments: Record<string, { count: number; amount: number }>; signups: number; businesses: number;
  failures: { at: string; kind: string; what: string; org_id: string | null; business: string | null; error: string }[];
};
const AI_LABEL: Record<string, string> = { read_invoice: 'Invoices read', product: 'Product photos', nin_slip: 'NIN slips', document: 'CAC documents', web: 'Web lookups',
  search: 'CAC searches', profile: 'CAC records', tin: 'Tax ID lookups', status_report: 'Status reports', nin: 'NIN checks' };

function Counts({ data, label }: { data: Record<string, number>; label: (k: string) => string }) {
  const keys = Object.keys(data).sort();
  if (!keys.length) return <div className="faint" style={{ fontSize: 13 }}>None</div>;
  return (
    <div className="stack" style={{ gap: 4, fontSize: 14 }}>
      {keys.map((k) => <div key={k} className="row" style={{ justifyContent: 'space-between', gap: 10 }}><span className={/failed/.test(k) ? '' : 'muted'} style={/failed/.test(k) ? { color: 'var(--red)' } : undefined}>{label(k)}</span><b className="num">{num(data[k])}</b></div>)}
    </div>
  );
}

export default function Activity() {
  const [days, setDays] = useState<'1' | '7' | '30'>('7');
  const [kind, setKind] = useState('all');
  const q = useQuery({ queryKey: ['admin-activity', days], queryFn: () => rpc<Act>('admin_activity', { p_days: Number(days) }) });
  const d = q.data;
  const kinds = d ? [...new Set(d.failures.map((f) => f.kind))] : [];
  const fails = (d?.failures || []).filter((f) => kind === 'all' || f.kind === kind);
  const split = (k: string) => k.replace(':', ' · ').replace(/_/g, ' ');
  return (
    <>
      <PageHead title="Activity" sub="What happened across every business, and everything that failed with the reason it gave."
        right={<Pills value={days} onChange={setDays} options={[{ id: '1', label: 'Today' }, { id: '7', label: '7 days' }, { id: '30', label: '30 days' }]} />} />
      {q.isError && <Alert kind="red" icon="alert">{tidyError(q.error)}</Alert>}
      {!d ? <SkeletonRows n={6} /> : (
        <>
          <div style={grid(230)}>
            <Card title="Sign-ups"><div style={{ fontSize: 14, lineHeight: 1.8 }}><div>{num(d.signups)} people</div><div>{num(d.businesses)} new businesses</div></div></Card>
            <Card title="Messages"><Counts data={d.messages} label={split} /></Card>
            <Card title="Phone calls"><Counts data={d.calls} label={split} /></Card>
            <Card title="AI reads"><Counts data={d.ai} label={(k) => AI_LABEL[k] || k.replace(/_/g, ' ')} /></Card>
            <Card title="Martina"><Counts data={d.martina} label={(k) => (k === 'assistant' ? 'Assistant conversations' : 'Onboarding conversations')} /></Card>
            <Card title="Money">
              <div className="stack" style={{ gap: 4, fontSize: 14 }}>
                {Object.entries(d.payments).map(([k, v]) => <div key={'p' + k} className="row" style={{ justifyContent: 'space-between', gap: 10 }}><span className="muted">Payment requests · {k}</span><b className="num">{num(v.count)} · {N(v.amount)}</b></div>)}
                {Object.entries(d.payouts).map(([k, v]) => <div key={'o' + k} className="row" style={{ justifyContent: 'space-between', gap: 10 }}><span className="muted">Payouts · {k.replace(/_/g, ' ')}</span><b className="num">{num(v.count)} · {N(v.amount)}</b></div>)}
                {!Object.keys(d.payments).length && !Object.keys(d.payouts).length && <div className="faint" style={{ fontSize: 13 }}>None</div>}
              </div>
            </Card>
          </div>
          <Card title={`What failed (${num(d.failures.length)})`} sub="The newest first, up to 200. Each line names the business and the reason the service gave."
            right={kinds.length > 1 ? <select className="input" style={{ width: 180 }} value={kind} onChange={(e) => setKind(e.target.value)} aria-label="Kind of failure">
              <option value="all">Everything</option>{kinds.map((k) => <option key={k} value={k}>{k}</option>)}</select> : undefined} pad={false}>
            {!fails.length ? <div className="card-pad muted" style={{ fontSize: 14 }}>Nothing failed in this period.</div> : fails.map((f, i) => (
              <div key={i} className="adm-row" style={{ gridTemplateColumns: '130px 90px minmax(0,1fr)' }}>
                <span className="faint">{when(f.at)}</span><span><span className="chip t-red">{f.kind}</span></span>
                <span style={{ minWidth: 0 }}>
                  <b>{f.what}</b>{f.business && <> · {f.org_id ? <Link to={`/admin/businesses/${f.org_id}`}>{f.business}</Link> : f.business}</>}
                  <div className="muted" style={{ wordBreak: 'break-word', fontSize: 13 }}>{f.error}</div>
                </span>
              </div>
            ))}
          </Card>
        </>
      )}
    </>
  );
}
