// Who pays for Counta and how: monthly recurring revenue, businesses on each plan, trials, payments that failed, and every
// business's plan with its last payment.
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { rpc } from '../../lib/supabase';
import { N2, fmtDay, when } from '../../lib/format';
import { Alert, SkeletonRows } from '../../components/ui';
import { tidyError } from '../api';
import { Card, grid, PageHead, Tile } from '../ui';

const STATUS: Record<string, string> = { active: 't-green', trialing: 't-blue', past_due: 't-red' };

export default function Subscriptions() {
  const [search, setSearch] = useState('');
  const [status, setStatus] = useState('');
  const q = useQuery({ queryKey: ['admin-subscriptions', search, status], queryFn: () => rpc<any>('admin_subscriptions', { p: { search: search || null, status: status || null } }) });
  const d = q.data;
  return (
    <div className="stack" style={{ gap: 18 }}>
      <PageHead title="Subscriptions" sub="Plans businesses pay for, by card or from their wallet. A payment that fails is tried again each day; after three days the business moves to the default plan." />
      {q.isLoading ? <SkeletonRows n={6} /> : !d ? <Alert kind="red" icon="alert">{tidyError(q.error)}</Alert> : (
        <>
          <div style={grid(170)}>
            <Tile label="Monthly recurring revenue" value={N2(d.mrr)} sub="Yearly plans counted as a twelfth, VAT included" />
            <Tile label="Paying" value={Number(d.paying).toLocaleString()} sub={`${d.comp} complimentary`} />
            <Tile label="On a trial" value={Number(d.trialing).toLocaleString()} />
            <Tile label="Payment overdue" value={Number(d.past_due).toLocaleString()} tone={Number(d.past_due) ? '#B91C1C' : undefined} onClick={Number(d.past_due) ? () => setStatus('past_due') : undefined} />
            <Tile label="Collected this month" value={N2(d.collected_month)} sub={`${d.failed_month} failed payment${Number(d.failed_month) === 1 ? '' : 's'}`} />
            <Tile label="Not renewing" value={Number(d.cancelling).toLocaleString()} />
          </div>
          <div className="row wrap" style={{ gap: 6 }}>
            {(d.by_plan || []).map((p: any) => <span key={p.code} className="chip t-grey">{p.plan}: {p.businesses}</span>)}
          </div>
          <Card title="Businesses" right={<div className="row wrap" style={{ gap: 8 }}>
            <input className="input input-sm" placeholder="Search by name" value={search} onChange={(e) => setSearch(e.target.value)} aria-label="Search" style={{ width: 200 }} />
            <select className="input input-sm" value={status} onChange={(e) => setStatus(e.target.value)} aria-label="Status" style={{ width: 150 }}>
              <option value="">Every status</option><option value="active">Active</option><option value="trialing">On a trial</option><option value="past_due">Payment overdue</option><option value="paying">Paying</option></select>
          </div>} pad={false}>
            <div className="tbl"><div className="tr head shade th hide-sm" style={{ gridTemplateColumns: 'minmax(180px,1.4fr) 130px 110px 120px 130px minmax(160px,1fr)', minWidth: 860 }}>
              <span>Business</span><span>Plan</span><span>Status</span><span className="right">Price</span><span>Period ends</span><span>Last payment</span></div>
              {!(d.rows || []).length ? <div style={{ padding: 16 }} className="faint">No businesses match.</div> : (d.rows || []).map((r: any) => (
                <div key={r.org_id} className="tr" style={{ gridTemplateColumns: 'minmax(180px,1.4fr) 130px 110px 120px 130px minmax(160px,1fr)', minWidth: 860 }}>
                  <Link to={`/admin/businesses/${r.org_id}`} className="ellipsis" style={{ fontWeight: 600 }}>{r.name}</Link>
                  <span>{r.plan}{r.comp && <span className="chip t-purple" style={{ marginLeft: 4 }}>comp</span>}</span>
                  <span><span className={'chip ' + (STATUS[r.status] || 't-grey')}>{r.status.replace('_', ' ')}</span>{r.cancelling && <span className="faint" style={{ display: 'block', fontSize: 11 }}>not renewing</span>}</span>
                  <span className="right num">{Number(r.price) > 0 ? `${N2(r.price)}${r.billing === 'year' ? '/yr' : '/mo'}` : 'Free'}<span className="faint" style={{ display: 'block', fontSize: 11 }}>{r.pay_method === 'card' ? 'card' : r.pay_method === 'wallet' ? 'wallet' : ''}</span></span>
                  <span className="muted">{r.period_end ? fmtDay(r.period_end) : '—'}</span>
                  <span className="faint" style={{ fontSize: 12 }}>{r.last_charge ? `${r.last_charge.status} ${when(r.last_charge.at)}${r.last_charge.error ? ` · ${r.last_charge.error}` : ''}` : '—'}</span>
                </div>
              ))}
            </div>
          </Card>
        </>
      )}
    </div>
  );
}
