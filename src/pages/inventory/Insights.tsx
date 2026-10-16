import { useEffect, useMemo, useState } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { can, useInventory, useSession } from '../../state/session';
import { useLoc } from '../../shell/AppShell';
import { useCashStory } from '../../shell/needsAction';
import { useAction, useCashVsStock } from '../../lib/queries';
import { rpc } from '../../lib/supabase';
import { K, N, P, addDays, fmtDay, plural, weekday } from '../../lib/format';
import { batchWindow, buildItems, daysLabel, deadStock, qtyLabel, waLink } from '../../lib/domain';
import { Icon } from '../../components/Icon';
import { Alert, Annot, Chip, Empty, Field, Label, Modal, ModalHead } from '../../components/ui';

type Tab = 'variance' | 'dead' | 'expiry';
const TONE = {
  red: { border: '#FECACA', bg: '#FEF2F2', fg: '#991B1B', icon: 'trendDown' },
  green: { border: '#BBF7D0', bg: '#F0FDF4', fg: '#166534', icon: 'check' },
  amber: { border: '#FED7AA', bg: '#FFF7ED', fg: '#9A3412', icon: 'trendUp' },
  grey: { border: '#E6E6E6', bg: '#FAFAFA', fg: '#374151', icon: 'info' },
};

export default function Insights() {
  const { data: inv } = useInventory();
  const location = useLocation();
  const nav = useNavigate();
  const [tab, setTab] = useState<Tab>((location.state as any)?.tab || 'variance');
  useEffect(() => { if ((location.state as any)?.tab) nav(location.pathname, { replace: true, state: null }); }, []); // eslint-disable-line react-hooks/exhaustive-deps
  if (!inv) return null;
  const tabs: { id: Tab; label: string }[] = [{ id: 'variance', label: 'Cash vs stock' }, { id: 'dead', label: 'Dead stock' }, { id: 'expiry', label: 'Batches & expiry' }];
  return (
    <div className="container">
      <div className="row wrap" style={{ gap: 6 }}>
        {tabs.map((t) => <button key={t.id} className={'pill' + (tab === t.id ? ' on' : '')} onClick={() => setTab(t.id)}>{t.label}</button>)}
      </div>
      {tab === 'variance' && <Variance />}
      {tab === 'dead' && <Dead />}
      {tab === 'expiry' && <Expiry />}
    </div>
  );
}

function Variance() {
  const { data: inv } = useInventory();
  const { loc } = useLoc();
  const nav = useNavigate();
  const { story, loading } = useCashStory(loc);
  const cash = useCashVsStock(can(inv, 'see_margins'));
  const [record, setRecord] = useState(false);
  const days = useDays(cash.data, (inv?.locations || []).map((l) => l.id).filter((id) => loc === 'ALL' || id === loc), inv?.today || '');
  if (!inv) return null;
  if (!can(inv, 'see_margins')) return <Alert kind="yellow" icon="shield">Cash vs stock compares takings with what was sold, so it is visible to the owner and anyone with See margins.</Alert>;
  const recorder = inv.me.role === 'owner' || inv.me.role === 'manager';
  const t = TONE[story.tone];
  const shift = story.names.map((n) => inv.members.find((m) => m.display_name === n)).filter(Boolean);
  const branch = story.location?.name || 'the shop';
  const ask = (first: string) => `Hi ${first}, the ${story.weekday || 'recent'} takings at ${branch} came to ${N(Math.abs(story.gap))} less than stock movements say was sold. Can you walk me through the ${story.weekday || ''} shift when you have a minute?`.replace(/\s+/g, ' ');
  const maxImplied = Math.max(1, ...story.weeks.map((w) => Math.max(w.implied, w.recorded)));
  return (
    <>
      {loading ? <div className="card card-pad"><div className="skel" style={{ height: 120 }} /></div> : !story.hasTakings ? (
        <div className="card card-pad stack" style={{ gap: 10, alignItems: 'flex-start' }}>
          <div className="row"><Icon name="trendDown" size={18} color="#7C3AED" /><div style={{ fontSize: 15, fontWeight: 600 }}>No takings recorded yet</div></div>
          <div className="ink3" style={{ fontSize: 14, lineHeight: 1.5, maxWidth: 640 }}>Record each day's cash and POS or transfer settlements per branch. Counta compares them with the selling value of stock that left the shelf and explains any gap in plain English, including patterns by weekday and shift.</div>
          {recorder && <button className="btn btn-primary btn-sm" onClick={() => setRecord(true)}><Icon name="plus" size={14} color="#fff" />Record takings</button>}
        </div>
      ) : (
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(360px,1fr))', gap: 20, alignItems: 'start' }}>
          <div style={{ border: '1px solid ' + t.border, background: t.bg, borderRadius: 16, padding: 20 }}>
            <div className="row"><Icon name={t.icon} size={18} color={t.fg} /><div style={{ fontSize: 13, fontWeight: 600, color: t.fg }}>{story.title}</div></div>
            <div style={{ fontFamily: 'var(--font-brand)', fontSize: 22, fontWeight: 600, lineHeight: 1.3, marginTop: 12, letterSpacing: '-.01em' }}>{story.headline}</div>
            {story.pattern && <div className="ink3" style={{ fontSize: 14, lineHeight: 1.5, marginTop: 12 }}>{story.pattern}</div>}
            {story.tone === 'red' && (
              <div className="row wrap" style={{ marginTop: 16 }}>
                {inv.me.role === 'owner' && (shift.length ? shift.map((m) => (
                  <a key={m!.id} className="btn btn-dark btn-sm" href={waLink(m!.phone, ask(m!.display_name.split(' ')[0]))} target="_blank" rel="noreferrer"><Icon name="wa" size={14} color="#fff" />Ask {m!.display_name.split(' ')[0]}</a>
                )) : <a className="btn btn-dark btn-sm" href={waLink(null, ask('team'))} target="_blank" rel="noreferrer"><Icon name="wa" size={14} color="#fff" />Ask the {story.weekday || ''} shift</a>)}
                {can(inv, 'approve_adjustments') && <button className="btn btn-secondary btn-sm" onClick={() => nav('/inventory/counts', { state: { newCount: { location_id: story.location?.id, area: `Whole store · ${story.weekday || 'end of day'} close` } } })}>Schedule a count for {story.weekday ? story.weekday + ' close' : 'closing time'}</button>}
              </div>
            )}
          </div>
          <div className="card card-pad">
            <div className="row" style={{ justifyContent: 'space-between' }}><Label>Implied takings vs recorded · last 4 weeks</Label>{recorder && <button className="btn btn-secondary btn-xs" onClick={() => setRecord(true)}>Record takings</button>}</div>
            <div className="stack" style={{ gap: 14, marginTop: 14 }}>
              {story.weeks.map((w) => (
                <div key={w.label}>
                  <div className="row" style={{ justifyContent: 'space-between', fontSize: 13 }}>
                    <span style={{ fontWeight: 500 }}>{w.label}{!w.complete ? <span className="faint" style={{ fontWeight: 400 }}> · takings missing for some days</span> : ''}</span>
                    <span style={{ fontWeight: 600, color: w.gap > 0 && Math.abs(w.gapPct) >= 0.5 ? '#DC2626' : w.gap < 0 && Math.abs(w.gapPct) >= 0.5 ? '#C2410C' : '#15803D' }}>{Math.abs(w.gapPct) < 0.5 ? 'matched' : `gap ${N(w.gap)} · ${P(w.gapPct)}`}</span>
                  </div>
                  <div style={{ position: 'relative', height: 10, background: w.gap > 0 ? '#FEE2E2' : '#F3F4F6', borderRadius: 5, marginTop: 6, overflow: 'hidden', width: `${Math.max(8, (w.implied / maxImplied) * 100)}%` }}>
                    <div style={{ position: 'absolute', inset: '0 auto 0 0', background: '#111827', borderRadius: 5, width: `${w.implied ? Math.min(100, (w.recorded / w.implied) * 100) : 0}%` }} />
                  </div>
                  <div className="row muted" style={{ justifyContent: 'space-between', fontSize: 11, marginTop: 4 }}><span>Recorded {N(w.recorded)}</span><span>Implied {N(w.implied)}</span></div>
                </div>
              ))}
            </div>
            <div className="muted" style={{ fontSize: 12, marginTop: 14, lineHeight: 1.45 }}>Implied = Σ quantity relieved × selling price. Recorded = cash sales + POS/transfer settlements matched by Numens.</div>
          </div>
        </div>
      )}
      {story.hasTakings && days.length > 0 && (
        <div className="card" style={{ overflow: 'hidden' }}>
          <div className="card-hd"><Label>Daily detail · last 14 days</Label></div>
          <div className="tbl">
            <div className="tr head th rsp" style={{ gridTemplateColumns: '150px 120px repeat(5, minmax(100px,1fr))', minWidth: 860 }}>
              <span>Day</span><span>Branch</span><span className="right">Implied</span><span className="right">Cash</span><span className="right">POS</span><span className="right">Transfers</span><span className="right">Gap</span>
            </div>
            {days.map((d) => (
              <div key={d.day + d.loc} className="tr rsp" style={{ gridTemplateColumns: '150px 120px repeat(5, minmax(100px,1fr))', minWidth: 860 }}>
                <span className="muted" style={{ fontWeight: 600 }}>{weekday(d.day).slice(0, 3)} {fmtDay(d.day, false)}</span>
                <span className="ink3">{inv.locations.find((l) => l.id === d.loc)?.name}</span>
                <span className="right num m-main" data-label="Implied">{N(d.implied)}</span>
                <span className="right num ink3" data-label="Cash">{d.rec ? N(d.rec.cash) : '—'}</span><span className="right num ink3" data-label="POS">{d.rec ? N(d.rec.pos) : '—'}</span><span className="right num ink3" data-label="Transfers">{d.rec ? N(d.rec.transfers) : '—'}</span>
                <span className="right num" data-label="Gap" style={{ fontWeight: 600, color: !d.rec ? '#9CA3AF' : d.gap > 1000 ? '#DC2626' : d.gap < -1000 ? '#C2410C' : '#15803D' }}>{d.rec ? (Math.abs(d.gap) < 1 ? '—' : N(d.gap)) : 'not recorded'}</span>
              </div>
            ))}
          </div>
        </div>
      )}
      {record && <TakingsModal onClose={() => setRecord(false)} implied={cash.data?.implied || []} />}
    </>
  );
}

function useDays(data: { implied: any[]; recorded: any[] } | undefined, locs: string[], today: string) {
  return useMemo(() => {
    if (!data || !today) return [];
    const out: { day: string; loc: string; implied: number; rec: any; gap: number }[] = [];
    for (let i = 1; i <= 14; i++) {
      const day = addDays(today, -i);
      for (const loc of locs) {
        const implied = data.implied.filter((r) => r.day === day && r.location_id === loc).reduce((a, r) => a + Number(r.implied), 0);
        const rec = data.recorded.find((r) => r.day === day && r.location_id === loc) || null;
        if (!implied && !rec) continue;
        out.push({ day, loc, implied, rec, gap: implied - (rec ? Number(rec.recorded) : 0) });
      }
    }
    return out;
  }, [data, locs.join(','), today]); // eslint-disable-line react-hooks/exhaustive-deps
}

function TakingsModal({ onClose, implied }: { onClose: () => void; implied: { day: string; location_id: string; implied: number }[] }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const { run, busy } = useAction();
  const [loc, setLoc] = useState(inv?.me.location_id || inv?.locations[0]?.id || '');
  const [day, setDay] = useState(addDays(inv?.today || new Date().toISOString().slice(0, 10), -1));
  const [f, setF] = useState({ cash: '', pos: '', transfers: '' });
  const imp = implied.filter((r) => r.day === day && r.location_id === loc).reduce((a, r) => a + Number(r.implied), 0);
  const total = (Number(f.cash) || 0) + (Number(f.pos) || 0) + (Number(f.transfers) || 0);
  async function save() {
    const r = await run(() => rpc('record_takings', { p_org: orgId, p_location: loc, p_day: day, p_cash: Number(f.cash) || 0, p_pos: Number(f.pos) || 0, p_transfers: Number(f.transfers) || 0 }),
      { ok: `Takings saved for ${weekday(day)} ${fmtDay(day, false)}`, invalidate: ['cash'] });
    if (r !== undefined) onClose();
  }
  return (
    <Modal onClose={onClose} width={480}>
      <ModalHead title="Record takings" sub="One row per branch per day. Saving again replaces that day." onClose={onClose} />
      <div className="modal-body">
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <Field label="Branch"><select className="input" value={loc} onChange={(e) => setLoc(e.target.value)}>{inv?.locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</select></Field>
          <Field label="Day"><input className="input" type="date" value={day} max={inv?.today} onChange={(e) => setDay(e.target.value)} /></Field>
        </div>
        <div className="m-2" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 12 }}>
          <Field label="Cash"><input className="input" type="number" min={0} inputMode="numeric" value={f.cash} onChange={(e) => setF({ ...f, cash: e.target.value })} placeholder="₦" /></Field>
          <Field label="POS"><input className="input" type="number" min={0} inputMode="numeric" value={f.pos} onChange={(e) => setF({ ...f, pos: e.target.value })} placeholder="₦" /></Field>
          <Field label="Transfers"><input className="input" type="number" min={0} inputMode="numeric" value={f.transfers} onChange={(e) => setF({ ...f, transfers: e.target.value })} placeholder="₦" /></Field>
        </div>
        <div style={{ background: '#FAFAFA', borderRadius: 12, padding: '12px 14px', fontSize: 13, lineHeight: 1.5 }}>
          Stock movements imply <b>{N(imp)}</b> sold at this branch that day. You are recording <b>{N(total)}</b>{imp ? <>, a difference of <b style={{ color: imp - total > 1000 ? '#DC2626' : '#15803D' }}>{N(imp - total)}</b></> : ''}.
        </div>
      </div>
      <div className="modal-ft">
        <button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" onClick={save} disabled={busy || !loc || !day}>Save takings</button>
      </div>
    </Modal>
  );
}

function Dead() {
  const { data: inv } = useInventory();
  const { loc } = useLoc();
  const { run, busy } = useAction();
  const rows = useMemo(() => (inv ? deadStock(buildItems(inv, loc)) : []), [inv, loc]);
  const [applied, setApplied] = useState<Record<string, boolean>>({});
  if (!inv) return null;
  const costs = inv.can_see_costs;
  const owner = can(inv, 'edit_prices');
  return (
    <div className="stack" style={{ gap: 12 }}>
      <div className="ink3" style={{ fontSize: 14 }}>Capital sleeping on a shelf. Anything unmoved for 90 days, with what a markdown does to margin and how long it should take to clear.</div>
      {rows.map((d) => {
        const live = applied[d.item.id] || d.item.price <= d.mark;
        return (
          <div key={d.item.id} className="card m-2" style={{ padding: '18px 20px', display: 'grid', gridTemplateColumns: 'minmax(220px,1.3fr) repeat(4,minmax(110px,.7fr)) auto', gap: 16, alignItems: 'center' }}>
            <div className="m-full"><div style={{ fontSize: 15, fontWeight: 600 }}>{d.item.name}</div><div className="muted" style={{ fontSize: 12, marginTop: 2 }}>{qtyLabel(d.item, d.item.q)} · unmoved {d.days} days</div></div>
            <div><div className="mini-label">Carrying value</div><div style={{ fontSize: 16, fontWeight: 600, marginTop: 4 }}>{costs ? N(d.carrying) : '—'}</div></div>
            <div><div className="mini-label">Price → markdown</div><div style={{ fontSize: 14, marginTop: 4 }}>{N(d.item.price)} → <b style={{ color: '#0072F5' }}>{N(d.mark)}</b></div></div>
            <div><div className="mini-label">Margin after</div><div style={{ fontSize: 14, marginTop: 4 }}>{costs ? <>{P(d.mOld)} → <b style={{ color: '#C2410C' }}>{P(d.mNew)}</b></> : '—'}</div></div>
            <div><div className="mini-label">Clears in</div><div style={{ fontSize: 14, marginTop: 4 }}>~{plural(d.clearWeeks, 'week')}</div></div>
            <div className="m-full m-left" style={{ minWidth: 140, display: 'flex', justifyContent: 'flex-end' }}>
              {live ? <span className="row" style={{ fontSize: 13, fontWeight: 600, color: '#15803D' }}><Icon name="check" size={16} color="#15803D" sw={2.5} />Markdown live</span>
                : owner ? <button className="btn btn-primary btn-sm" disabled={busy} onClick={async () => {
                  const r = await run(() => rpc('change_price', { p_item: d.item.id, p_price: d.mark, p_reason: 'Dead stock markdown' }), { ok: `${d.item.name.split(' ').slice(0, 2).join(' ')} marked down to ${N(d.mark)}`, invalidate: ['inv', 'priceChanges'] });
                  if (r !== undefined) setApplied((a) => ({ ...a, [d.item.id]: true }));
                }}>Apply markdown</button> : <Annot>Awaits owner approval</Annot>}
            </div>
          </div>
        );
      })}
      {!rows.length && <Empty>Nothing has sat unsold for 90 days{loc !== 'ALL' ? ' at this branch' : ''}. Good.</Empty>}
    </div>
  );
}

function Expiry() {
  const { data: inv } = useInventory();
  const { loc } = useLoc();
  const { run, busy } = useAction();
  if (!inv) return null;
  const items = new Map(inv.items.map((i) => [i.id, i]));
  const rows = inv.batches.filter((b) => loc === 'ALL' || b.location_id === loc)
    .map((b) => ({ b, it: items.get(b.item_id), w: batchWindow(b, inv.today) }))
    .filter((r) => r.it)
    .sort((a, b) => Number(a.b.quarantined) - Number(b.b.quarantined) || (a.b.expiry_date || '9999').localeCompare(b.b.expiry_date || '9999'));
  const costs = inv.can_see_costs;
  const approver = can(inv, 'approve_adjustments');
  const tracked = inv.items.filter((i) => i.track_batches).length;
  const COLS = 'minmax(200px,1.4fr) 110px 120px 130px minmax(120px,1fr) 110px 120px minmax(180px,1fr) 120px';
  return (
    <div className="card" style={{ overflow: 'hidden' }}>
      <div className="card-hd"><Label>Batches · first-expiry-first-out</Label><span className="faint" style={{ fontSize: 12 }}>{plural(tracked, 'item')} tracked · expired batches leave sellable stock automatically overnight</span></div>
      <div className="tbl">
        <div className="tr head th rsp" style={{ gridTemplateColumns: COLS, minWidth: 1180 }}>
          <span>Item</span><span>Batch</span><span>Expiry</span><span>Window</span><span>Quantity</span><span className="right">Value</span><span>Status</span><span>Rule</span><span />
        </div>
        {rows.map(({ b, it, w }) => (
          <div key={b.id} className="tr rsp" style={{ gridTemplateColumns: COLS, minWidth: 1180, opacity: b.quarantined ? 0.7 : 1 }}>
            <div className="m-main"><div style={{ fontWeight: 600 }}>{it!.name}</div><div className="faint" style={{ fontSize: 11 }}>{[it!.nafdac_no ? 'NAFDAC ' + it!.nafdac_no : null, inv.locations.find((l) => l.id === b.location_id)?.name].filter(Boolean).join(' · ')}</div></div>
            <span className="mono ink3" style={{ fontSize: 12 }}>{b.batch_no}</span>
            <span className="ink3" data-label="Expires">{fmtDay(b.expiry_date)}</span>
            <span style={{ fontWeight: 500 }}>{daysLabel(w.days)}</span>
            <span className="ink3">{qtyLabel(it!, Number(b.qty_remaining))}</span>
            <span className="right num">{costs && it!.wac != null ? K(Number(b.qty_remaining) * Number(it!.wac)) : '—'}</span>
            <span><Chip label={w.label} /></span>
            <span className="muted m-main" style={{ fontSize: 12 }}>{w.rule}</span>
            <span className="m-end" style={{ display: 'flex', justifyContent: 'flex-end' }}>
              {!b.quarantined && (w.label === 'Expired' || w.label === 'Expiring') && approver && (
                <button className="btn btn-danger btn-xs" disabled={busy} onClick={() => run(() => rpc<string>('quarantine_batch', { p_batch: b.id }), { ok: (ref) => `Batch ${b.batch_no} quarantined${ref ? ' · ' + ref : ''}`, invalidate: ['inv', 'ledger', 'activity'] })}>Quarantine</button>
              )}
            </span>
          </div>
        ))}
        {!rows.length && <div className="muted" style={{ padding: 24, fontSize: 14 }}>{tracked ? 'No batches on hand.' : 'Batch tracking is off for every item. Turn it on for NAFDAC-regulated or perishable goods in the item drawer; receipts then record batch number and expiry.'}</div>}
      </div>
    </div>
  );
}
