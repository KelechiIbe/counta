// Filing fees: what a filing-only business pays for each year's income tax return, by the number of transactions on the
// year's bank statements, set separately for companies income tax and personal income tax; and the years paid for.
import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { rpc } from '../../lib/supabase';
import { N2, when } from '../../lib/format';
import { useToast } from '../../state/session';
import { Alert, SkeletonRows, Spinner } from '../../components/ui';
import { tidyError } from '../api';
import { Card, grid, PageHead, Tile } from '../ui';

type Kind = 'cit' | 'pit';
type Band = { up_to: number | null; price: number };
type AdminFiling = {
  prices: (Band & { kind: Kind; updated_at: string })[]; businesses: number; collected_month: number; collected_total: number;
  orders: { id: string; business: string; year: number; kind: Kind; status: 'open' | 'paid'; counted: number | null; band_up_to: number | null; amount: number | null;
    extra_due: number; extra_paid: number; payer: string | null; practice: string | null; paid_at: string | null; at: string; filed: boolean }[];
};
const KIND_NAME: Record<Kind, string> = { cit: 'Companies income tax', pit: 'Personal income tax' };
const plain = (v: string) => v.replace(/[,\s₦]/g, '');

export default function FilingFees() {
  const q = useQuery({ queryKey: ['admin-filing'], queryFn: () => rpc<AdminFiling>('admin_filing') });
  const d = q.data;
  return (
    <div className="stack" style={{ gap: 18 }}>
      <PageHead title="Filing fees" sub="A filing-only business pays once for each year's income tax return. The fee is the band its count falls in: the statement lines dated in the year, with 35 lines for each page of a scanned statement. A scan read after payment that puts the year in a dearer band owes the difference." />
      {q.isLoading ? <SkeletonRows n={6} /> : !d ? <Alert kind="red" icon="alert">{tidyError(q.error)}</Alert> : (
        <>
          <div style={grid(200)}>
            <Tile label="Filing-only businesses" value={d.businesses.toLocaleString('en-NG')} />
            <Tile label="Collected this month" value={N2(d.collected_month)} />
            <Tile label="Collected in all" value={N2(d.collected_total)} />
          </div>
          <div style={grid(380)}>
            {(['cit', 'pit'] as Kind[]).map((k) => <Bands key={k} kind={k} bands={d.prices.filter((p) => p.kind === k)} />)}
          </div>
          <Card title="Years paid for" sub="The newest first. A year still open has not been paid." pad={false}>
            {!d.orders.length ? <div className="card-pad faint">None yet.</div> : (
              <div className="tbl">
                <div className="tr head shade th hide-sm" style={{ gridTemplateColumns: 'minmax(180px,1.4fr) 70px 90px 110px 120px minmax(140px,1fr) 90px', minWidth: 860 }}>
                  <span>Business</span><span>Year</span><span>Return</span><span className="right">Counted</span><span className="right">Paid</span><span>By</span><span>State</span>
                </div>
                {d.orders.map((o) => (
                  <div key={o.id} className="tr" style={{ gridTemplateColumns: 'minmax(180px,1.4fr) 70px 90px 110px 120px minmax(140px,1fr) 90px', minWidth: 860 }}>
                    <span className="ellipsis"><b>{o.business}</b></span>
                    <span>{o.year}</span>
                    <span className="muted">{o.kind.toUpperCase()}</span>
                    <span className="right num">{o.counted != null ? o.counted.toLocaleString('en-NG') : '—'}</span>
                    <span className="right num">{o.amount != null ? N2(Number(o.amount) + Number(o.extra_paid || 0)) : '—'}
                      {Number(o.extra_due) > 0 && <span style={{ display: 'block', fontSize: 11, color: '#B45309' }}>{N2(o.extra_due)} owed</span>}</span>
                    <span className="muted ellipsis">{o.status === 'paid' ? `${o.payer === 'practice' && o.practice ? o.practice : 'The business'} · ${when(o.paid_at)}` : `Started ${when(o.at)}`}</span>
                    <span><span className={'chip ' + (o.filed ? 't-green' : o.status === 'paid' ? 't-blue' : 't-grey')}>{o.filed ? 'Filed' : o.status === 'paid' ? 'Paid' : 'Open'}</span></span>
                  </div>
                ))}
              </div>
            )}
          </Card>
        </>
      )}
    </div>
  );
}

// One return's bands: each up to a number of transactions, the last with no upper end.
function Bands({ kind, bands }: { kind: Kind; bands: Band[] }) {
  const qc = useQueryClient();
  const toast = useToast();
  const start = bands.length ? bands : [{ up_to: 5000, price: 70000 }, { up_to: null, price: 120000 }];
  const [rows, setRows] = useState(() => start.map((b) => ({ up_to: b.up_to == null ? '' : String(b.up_to), price: String(Number(b.price)) })));
  const [busy, setBusy] = useState(false);
  const set = (i: number, k: 'up_to' | 'price', v: string) => setRows((r) => r.map((x, j) => (j === i ? { ...x, [k]: v } : x)));
  const last = rows.length - 1;
  // What the database would refuse, said before Save.
  const problem = rows.length < 1 || rows.length > 10 ? 'Between 1 and 10 bands.'
    : rows.some((r) => !/^\d+(\.\d{1,2})?$/.test(plain(r.price)) || Number(plain(r.price)) <= 0) ? 'Give every band a price above zero, like 70000.'
    : rows.slice(0, last).some((r) => !/^\d+$/.test(plain(r.up_to)) || Number(plain(r.up_to)) < 1) ? 'Every band but the last needs its highest number of transactions.'
    : rows.slice(1, last).some((r, i) => Number(plain(r.up_to)) <= Number(plain(rows[i].up_to))) ? 'Each band must go higher than the one before.'
    : null;
  async function save() {
    if (problem) { toast(problem, 'err'); return; }
    setBusy(true);
    try {
      await rpc('admin_filing_prices_save', { p: { kind, bands: rows.map((r, i) => (i === last ? { price: plain(r.price) } : { up_to: Number(plain(r.up_to)), price: plain(r.price) })) } });
      await qc.invalidateQueries({ queryKey: ['admin-filing'] });
      toast(`${KIND_NAME[kind]} fees saved`);
    } catch (e) { toast(tidyError(e), 'err'); }
    setBusy(false);
  }
  return (
    <Card title={KIND_NAME[kind]} sub={kind === 'cit' ? 'Companies.' : 'Business names and partnerships.'}
      right={<button className="btn btn-primary btn-sm" disabled={busy || !!problem} onClick={save} data-testid={`save-${kind}`}>{busy ? <Spinner small /> : null}Save</button>}>
      <div className="stack" style={{ gap: 8 }}>
        {rows.map((r, i) => (
          <div key={i} className="row wrap" style={{ gap: 8, alignItems: 'center' }}>
            {i === last
              ? <span className="muted" style={{ width: 190, fontSize: 13 }}>{rows.length > 1 ? `More than ${Number(plain(rows[last - 1].up_to) || 0).toLocaleString('en-NG')}` : 'Any number'} transactions</span>
              : <label className="row" style={{ gap: 6, width: 190, fontSize: 13 }}><span className="muted">Up to</span>
                  <input className="input input-sm num" style={{ width: 110 }} inputMode="numeric" value={r.up_to} aria-label={`Band ${i + 1}: highest number of transactions`}
                    onChange={(e) => set(i, 'up_to', e.target.value)} /></label>}
            <label className="row" style={{ gap: 6, fontSize: 13 }}><span className="muted">₦</span>
              <input className="input input-sm num" style={{ width: 130 }} inputMode="decimal" value={r.price} aria-label={`Band ${i + 1}: price`} onChange={(e) => set(i, 'price', e.target.value)} /></label>
            {rows.length > 1 && i !== last && <button className="btn btn-ghost btn-xs" onClick={() => setRows((x) => x.filter((_, j) => j !== i))} aria-label={`Remove band ${i + 1}`}>Remove</button>}
          </div>
        ))}
        {rows.length < 10 && <div><button className="btn btn-ghost btn-sm" onClick={() => setRows((x) => {
          const top = x.length > 1 ? Number(plain(x[x.length - 2].up_to)) || 0 : 0;
          return [...x.slice(0, -1), { up_to: String(top ? top * 2 : 5000), price: x[x.length - 1].price }, x[x.length - 1]];
        })}>Add a band</button></div>}
        {problem && <div style={{ fontSize: 12, color: '#B91C1C' }}>{problem}</div>}
        {!bands.length && <Alert kind="amber" icon="alert">No prices yet: filing-only businesses see no fee and cannot pay until these are saved.</Alert>}
      </div>
    </Card>
  );
}
