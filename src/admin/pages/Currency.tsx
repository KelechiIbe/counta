// Currencies Counta takes on import entries, and the naira rate for each: fetched every morning, or set by hand for a day.
import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { rpc } from '../../lib/supabase';
import { edge } from '../../lib/api';
import { fmtDay, lagosToday, num, when } from '../../lib/format';
import { useToast } from '../../state/session';
import { Icon } from '../../components/Icon';
import { Alert, Field, Pills, SkeletonRows, Spinner } from '../../components/ui';
import { tidyError } from '../api';
import { Card, PageHead, Toggle } from '../ui';

type Rate = { currency: string; rate: number; day: string; source: 'auto' | 'manual' | 'base' } | null;
type Cur = {
  code: string; name: string; symbol: string | null; allowed: boolean; base: boolean; rate: Rate;
  manual: { day: string; rate: number; by: string | null; at: string }[];
  history: { day: string; rate: number; source: 'auto' | 'manual' }[];
};

const naira = (v: number) => `₦${num(v, v < 10 ? 4 : 2)}`;

function RateForm({ c, onDone }: { c: Cur; onDone: () => void }) {
  const toast = useToast();
  const [day, setDay] = useState(lagosToday());
  const [rate, setRate] = useState(c.rate?.rate ? String(c.rate.rate) : '');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function save() {
    const r = Number(rate.replace(/,/g, ''));
    if (!(r > 0)) { setErr(`Enter how many naira one ${c.code} is worth.`); return; }
    setBusy(true); setErr(null);
    try { await rpc('admin_set_rate', { p_code: c.code, p_day: day, p_rate: r }); toast(`${c.code} set to ${naira(r)} from ${fmtDay(day)}`); onDone(); }
    catch (e) { setErr(tidyError(e)); }
    setBusy(false);
  }
  return (
    <div className="stack" style={{ gap: 10, padding: '12px 16px', background: 'var(--canvas)', borderTop: '1px solid var(--line)' }}>
      <div className="row wrap" style={{ gap: 10, alignItems: 'flex-end' }}>
        <Field label="From" style={{ flex: '0 1 170px' }}><input className="input" type="date" value={day} max={lagosToday()} onChange={(e) => setDay(e.target.value)} /></Field>
        <Field label={`Naira for 1 ${c.code}`} style={{ flex: '0 1 200px' }}>
          <input className="input num" inputMode="decimal" value={rate} onChange={(e) => setRate(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter') void save(); }} />
        </Field>
        <button className="btn btn-primary btn-sm" disabled={busy} onClick={save}>{busy ? <Spinner small /> : null}Set the rate</button>
      </div>
      <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }}>A rate set here stands from that day until a later rate exists, and the morning fetch never writes over it.{c.code === 'USD' ? ' The dollar rate also feeds the reorder timing advice.' : ''}</div>
      {err && <Alert kind="red" icon="alert">{err}</Alert>}
    </div>
  );
}

function Row({ c }: { c: Cur }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const refresh = () => qc.invalidateQueries({ queryKey: ['admin-currencies'] });
  async function allow(on: boolean) {
    setBusy(true);
    try { await rpc('admin_set_currency', { p_code: c.code, p_allowed: on }); await refresh(); toast(on ? `${c.code} is taken now` : `${c.code} is no longer taken`); }
    catch (e) { toast(tidyError(e), 'err'); }
    setBusy(false);
  }
  async function clear(day: string) {
    setBusy(true);
    try { await rpc('admin_clear_rate', { p_code: c.code, p_day: day }); await refresh(); toast('Removed. The fetched rate applies again.'); }
    catch (e) { toast(tidyError(e), 'err'); }
    setBusy(false);
  }
  const r = c.rate;
  return (
    <div style={{ borderTop: '1px solid var(--line)' }}>
      <div className="adm-row" style={{ gridTemplateColumns: 'minmax(0,1.4fr) minmax(0,1.3fr) auto', borderTop: 0 }}>
        <div style={{ minWidth: 0 }}>
          <b>{c.code}</b> <span className="muted">{c.name}</span>{c.symbol && c.symbol !== c.code && <span className="faint"> · {c.symbol}</span>}
          {c.base && <div className="faint" style={{ fontSize: 12 }}>The base currency. Every amount in the books is in naira.</div>}
        </div>
        <div style={{ minWidth: 0, fontSize: 14 }}>
          {c.base ? <span className="faint">1</span> : r ? (
            <>
              <b className="num">{naira(r.rate)}</b> <span className={'chip ' + (r.source === 'manual' ? 't-purple' : 't-grey')} style={{ marginLeft: 4 }}>{r.source === 'manual' ? 'Set by hand' : 'Fetched'}</span>
              <div className="faint" style={{ fontSize: 12 }}>{r.day === lagosToday() ? 'Today' : `From ${fmtDay(r.day)}`}</div>
            </>
          ) : <span className="faint">No rate yet</span>}
        </div>
        <div className="row" style={{ gap: 8, justifyContent: 'flex-end' }}>
          {!c.base && <button className="btn btn-secondary btn-sm" onClick={() => setOpen(!open)} aria-expanded={open}>{open ? 'Close' : 'Rates'}</button>}
          {busy && <Spinner small />}
          <Toggle on={c.allowed} disabled={c.base || busy} label={`Take ${c.code}`} onChange={allow} />
        </div>
      </div>
      {open && (
        <>
          <RateForm c={c} onDone={() => { void refresh(); }} />
          {(c.manual.length > 0 || c.history.length > 0) && (
            <div className="row wrap" style={{ gap: 18, padding: '10px 16px 14px', alignItems: 'flex-start', fontSize: 13 }}>
              {c.manual.length > 0 && (
                <div className="stack" style={{ gap: 4, flex: '1 1 260px', minWidth: 0 }}>
                  <span className="mini-label">Set by hand</span>
                  {c.manual.map((m) => (
                    <div key={m.day} className="row" style={{ gap: 8, justifyContent: 'space-between' }}>
                      <span>{fmtDay(m.day)} · <b className="num">{naira(m.rate)}</b> <span className="faint">{m.by ? `${m.by}, ` : ''}{when(m.at)}</span></span>
                      <button className="btn btn-ghost btn-sm" disabled={busy} onClick={() => clear(m.day)}>Remove</button>
                    </div>
                  ))}
                </div>
              )}
              {c.history.length > 0 && (
                <div className="stack" style={{ gap: 2, flex: '1 1 200px', minWidth: 0 }}>
                  <span className="mini-label">Last two weeks</span>
                  {c.history.map((h) => <div key={h.day} className="row" style={{ justifyContent: 'space-between', gap: 8 }}><span className="faint">{fmtDay(h.day, false)}</span><span className="num">{naira(h.rate)}{h.source === 'manual' ? ' (by hand)' : ''}</span></div>)}
                </div>
              )}
            </div>
          )}
        </>
      )}
    </div>
  );
}

export default function Currency() {
  const qc = useQueryClient();
  const toast = useToast();
  const [show, setShow] = useState<'taken' | 'all'>('taken');
  const [busy, setBusy] = useState(false);
  const q = useQuery({ queryKey: ['admin-currencies'], queryFn: () => rpc<Cur[]>('admin_currencies') });
  async function fetchNow() {
    setBusy(true);
    const r = await edge<{ currencies: number; added: number }>('fx', {});
    setBusy(false);
    if (r.ok === false) { toast(r.error || 'The rates did not come back.', 'err'); return; }
    toast(r.currencies ? `Fetched today's rate for ${r.currencies} ${r.currencies === 1 ? 'currency' : 'currencies'}` : 'The rate service did not answer. Try again in a while.', r.currencies ? undefined : 'err');
    await qc.invalidateQueries({ queryKey: ['admin-currencies'] });
  }
  const rows = (q.data || []).filter((c) => show === 'all' || c.allowed);
  const taken = (q.data || []).filter((c) => c.allowed).length;
  return (
    <>
      <PageHead title="Currency" sub="The currencies businesses can record imports and customs entries in, and the naira rate Counta uses for each. Rates are fetched every morning at 6:05; a rate you set for a day wins over the fetched one."
        right={<button className="btn btn-secondary" disabled={busy} onClick={fetchNow}>{busy ? <Spinner small /> : <Icon name="refresh" size={14} />}Fetch today's rates</button>} />
      {q.isError && <Alert kind="red" icon="alert">{tidyError(q.error)}</Alert>}
      <Card title={`Currencies (${taken} taken)`} sub="Switching one off stops new entries in it. Entries already recorded keep their currency and rate."
        right={<Pills value={show} onChange={setShow} options={[{ id: 'taken', label: 'Taken' }, { id: 'all', label: 'All' }]} />} pad={false}>
        {q.isLoading ? <div className="card-pad"><SkeletonRows n={6} /></div> : rows.map((c) => <Row key={c.code} c={c} />)}
      </Card>
      <Alert kind="grey" icon="info">Invoices, bills and the books stay in naira. A foreign currency is used where money crosses the border: import entries, customs duty and the landed cost of goods.</Alert>
    </>
  );
}
