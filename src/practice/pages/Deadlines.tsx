// Every client's tax deadlines in one list, soonest (and missed) first.
import { useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { N2, fmtDay } from '../../lib/format';
import { Seg } from '../../components/ui';
import { Card, PageHead } from '../../admin/ui';
import { usePracticeHome } from '../api';

export default function Deadlines({ pid }: { pid: string }) {
  const h = usePracticeHome(pid).data!;
  const [which, setWhich] = useState<'all' | 'vat' | 'wht' | 'cit'>('all');
  const rows = useMemo(() => h.clients.filter((c) => c.status === 'active' && c.health)
    .flatMap((c) => c.health!.deadlines.map((d) => ({ ...d, client: c })))
    .filter((d) => which === 'all' || (which === 'wht' ? ['wht', 'wvat'].includes(d.tax) : d.tax === which))
    .sort((a, b) => a.due.localeCompare(b.due)), [h.clients, which]);
  return (
    <>
      <PageHead title="Deadlines" sub="Returns and payments every client owes, as Counta works them out from their books." />
      <Seg value={which} onChange={setWhich} options={[{ id: 'all', label: 'All' }, { id: 'vat', label: 'VAT' }, { id: 'wht', label: 'WHT' }, { id: 'cit', label: 'CIT' }]} />
      <Card pad={false}>
        {!rows.length ? <div className="card-pad faint">Nothing is due.</div> : (
          <div className="tbl">
            <div className="tr head shade th hide-sm" style={{ gridTemplateColumns: 'minmax(180px,1fr) minmax(160px,1fr) 120px 130px', minWidth: 640 }}>
              <span>Client</span><span>What</span><span className="right">Amount</span><span className="right">Due</span>
            </div>
            {rows.map((d, i) => (
              <Link key={i} to={`/practice/${pid}/clients/${d.client.id}`} className="tr click" style={{ gridTemplateColumns: 'minmax(180px,1fr) minmax(160px,1fr) 120px 130px', minWidth: 640, color: 'inherit' }}>
                <b className="ellipsis">{d.client.business_name}</b>
                <span>{d.label} <span className="faint">· {d.tax === 'cit' ? new Date(d.period).getUTCFullYear() : new Date(d.period + 'T12:00:00Z').toLocaleDateString('en-GB', { month: 'short', year: 'numeric' })}</span></span>
                <span className="right num">{d.amount != null ? N2(d.amount) : ''}</span>
                <span className="right"><span className={'chip ' + (d.overdue ? 't-red' : 't-grey')}>{fmtDay(d.due)}</span></span>
              </Link>
            ))}
          </div>
        )}
      </Card>
    </>
  );
}
