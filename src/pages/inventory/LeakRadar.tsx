import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { can, useInventory, useSession } from '../../state/session';
import { useAction } from '../../lib/queries';
import { rpc } from '../../lib/supabase';
import { K, N, addDays, fmtDay, num, when } from '../../lib/format';
import { Icon } from '../../components/Icon';
import { Alert, Chip, Label, Seg, Spinner } from '../../components/ui';

interface Radar {
  days: number; today: string; unexplained: number; found: number; net_unexplained: number; damage: number; cogs: number; revenue: number;
  shrink_pct: number | null; monthly_leak: number; ira: number | null; lines_counted: number | null; cash_short: number; cash_days: number;
  weeks: { week: string; unexplained: number; found: number; damage: number }[];
  locations: { location_id: string; name: string; unexplained: number; found: number; damage: number; cogs: number; shrink_pct: number | null; cash_short: number; ira: number | null }[];
  items: { item_id: string; location_id: string; item: string; location: string; unit: string; on_hand: number; unit_cost: number; per_day: number;
    days_unchecked: number; lost_qty: number; sold_qty: number; loss_rate: number; risk: number; flags: string[] }[];
  spot_checks_per_day: number; spot_check_last: string | null;
  spot_checks: { id: string; ref: string; location_id: string; area: string; status: string; assignee: string | null; created_at: string; items: number; differences: number }[];
  can_see_people: boolean; loss_events?: number;
  people?: { member_id: string; name: string; role: string; sales: number; sales_value: number; offline_sales: number; voice_sales: number; loss: number; events: number; loss_pct: number | null }[];
}
const pct = (n: number | null | undefined, dp = 1) => (n == null ? '—' : Math.abs(n) > 0 && Math.abs(n) < 0.05 ? 'under 0.1%' : n.toFixed(dp) + '%');

export default function LeakRadar() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const nav = useNavigate();
  const { run, busy } = useAction();
  const [days, setDays] = useState<'30' | '90' | '180'>('90');
  const q = useQuery({ queryKey: ['radar', orgId, days], enabled: !!orgId && can(inv, 'see_margins'), queryFn: () => rpc<Radar>('leak_radar', { p_org: orgId, p_days: Number(days) }), staleTime: 60_000 });
  if (!inv) return null;
  if (!can(inv, 'see_margins')) return <Alert kind="yellow" icon="shield">Leak radar works with costs, so the owner and anyone with See margins can see it.</Alert>;
  const r = q.data;
  const owner = can(inv, 'owner');
  const approver = can(inv, 'approve_adjustments');
  const maxWeek = Math.max(1, ...(r?.weeks || []).map((w) => w.unexplained + w.damage));
  // Every week of the last twelve, so a single bad week shows as one bar among quiet ones.
  const weeks = (() => {
    const today = inv.today || new Date().toISOString().slice(0, 10);
    const monday = (d: string) => { const x = new Date(d + 'T12:00:00Z'); return addDays(d, -((x.getUTCDay() + 6) % 7)); };
    const have = new Map((r?.weeks || []).map((w) => [String(w.week).slice(0, 10), w]));
    const out: Radar['weeks'] = [];
    for (let w = monday(addDays(today, -84)); w <= today; w = addDays(w, 7)) out.push(have.get(w) || { week: w, unexplained: 0, found: 0, damage: 0 });
    return out;
  })();
  const locName = (id: string) => inv.locations.find((l) => l.id === id)?.name || '';
  async function spot() {
    await run(() => rpc<{ created: number }>('run_spot_checks', { p_org: orgId }), {
      ok: (x) => (x.created ? `${x.created} spot check${x.created === 1 ? '' : 's'} sent to staff phones` : 'Nothing to spot check: the riskiest items were counted this week'),
      invalidate: ['radar', 'counts'] });
  }
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="row m-wrap" style={{ justifyContent: 'space-between', gap: 12 }}>
        <div className="ink3" style={{ fontSize: 14, maxWidth: 680, lineHeight: 1.5 }}>
          Where stock is going missing, how fast, and what to count next. Every count, write-off and cash-up feeds it, and each item's risk is the naira likely to have gone since someone last checked it.
        </div>
        <Seg value={days} onChange={setDays} options={[{ id: '30', label: '30 days' }, { id: '90', label: '90 days' }, { id: '180', label: '180 days' }]} />
      </div>
      {q.isLoading || !r ? <div className="card" style={{ display: 'grid', placeItems: 'center', minHeight: 200 }}>{q.error ? <Alert kind="red" icon="alert">{(q.error as Error).message}</Alert> : <Spinner />}</div> : (
        <>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(170px,1fr))', gap: 12 }}>
            <Tile label="Leaking a month" value={N(r.monthly_leak)} sub={`missing, damaged or expired, from the last ${r.days} days`} tone={r.monthly_leak > 0 ? 'red' : 'green'} />
            <Tile label="Went missing" value={N(r.net_unexplained)} sub={`${pct(r.shrink_pct, 2)} of cost of sales${r.found > 0 ? ` · ${N(r.found)} found` : ''}`} />
            <Tile label="Damaged or expired" value={N(r.damage)} sub="breakage, expiry and quarantine" />
            <Tile label="Count accuracy" value={r.ira == null ? '—' : r.ira.toFixed(1) + '%'} sub={r.lines_counted ? `of ${num(r.lines_counted)} lines counted matched the books` : 'no counts yet'} tone={r.ira != null && r.ira < 95 ? 'amber' : undefined} />
            <Tile label="Cash short" value={N(r.cash_short)} sub={r.cash_days ? `takings below sales on recorded days` : 'record takings to compare'} tone={r.cash_short > 0 ? 'amber' : undefined} />
          </div>

          {r.weeks.length > 0 && (
            <div className="card card-pad">
              <div className="row" style={{ justifyContent: 'space-between', marginBottom: 12 }}><Label>Losses by week</Label><span className="faint" style={{ fontSize: 12 }}><Dot c="#DC2626" />Went missing <Dot c="#F59E0B" />Damaged or expired</span></div>
              <div style={{ display: 'flex', alignItems: 'flex-end', gap: 6, height: 110 }}>
                {weeks.map((w, i) => (
                  <div key={w.week} title={`Week of ${fmtDay(w.week)}: ${N(w.unexplained)} missing, ${N(w.damage)} damaged`} style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', height: '100%', minWidth: 0 }}>
                    <div style={{ flex: 1, width: '100%', maxWidth: 40, display: 'flex', flexDirection: 'column', justifyContent: 'flex-end' }}>
                      <div style={{ background: '#F59E0B', height: `${(w.damage / maxWeek) * 100}%`, borderRadius: w.damage ? '4px 4px 0 0' : 0 }} />
                      <div style={{ background: '#DC2626', height: `${(w.unexplained / maxWeek) * 100}%`, borderRadius: w.damage ? 0 : '4px 4px 0 0' }} />
                      {w.damage + w.unexplained === 0 && <div style={{ height: 2, background: '#E5E7EB', borderRadius: 1 }} />}
                    </div>
                    <div className="faint" style={{ fontSize: 10, textAlign: 'center', marginTop: 4, whiteSpace: 'nowrap', height: 13 }}>{i % 2 === 0 ? fmtDay(w.week, false) : ''}</div>
                  </div>
                ))}
              </div>
            </div>
          )}

          <div className="card" style={{ overflow: 'hidden' }}>
            <div className="card-hd row m-wrap" style={{ justifyContent: 'space-between', gap: 8 }}>
              <Label>Count these next</Label>
              {approver && <button className="btn btn-primary btn-sm" disabled={busy} onClick={spot}><Icon name="send" size={14} color="#fff" />Send spot checks now</button>}
            </div>
            {r.items.length ? (
              <div style={{ overflow: 'auto' }}>
                <table className="mini-table" style={{ width: '100%', minWidth: 760 }}>
                  <thead><tr><th>Item</th><th>Branch</th><th className="right">On the books</th><th className="right">Sells a day</th><th className="right">Last checked</th><th>Why</th><th className="right">Likely missing</th></tr></thead>
                  <tbody>
                    {r.items.slice(0, 15).map((x) => (
                      <tr key={x.item_id + x.location_id}>
                        <td style={{ fontWeight: 600 }}>{x.item}</td><td className="ink3">{x.location}</td>
                        <td className="right num" style={{ color: x.on_hand < 0 ? '#DC2626' : undefined }}>{num(x.on_hand, 2)} {x.unit}</td>
                        <td className="right num">{num(x.per_day, 1)}</td>
                        <td className="right num">{x.days_unchecked} day{x.days_unchecked === 1 ? '' : 's'}</td>
                        <td>{x.flags.length ? <span className="row wrap" style={{ gap: 4 }}>{x.flags.map((f) => <Chip key={f} label={f} t={/Below zero|missing/.test(f) ? 't-red' : 't-grey'} />)}</span> : <span className="faint">Fast mover</span>}</td>
                        <td className="right num" style={{ fontWeight: 600 }}>{N(x.risk)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            ) : <div className="muted" style={{ padding: 20, fontSize: 14 }}>Nothing stands out yet. Risk builds up as items sell without being counted.</div>}
            <div className="faint" style={{ fontSize: 12, padding: '10px 20px', lineHeight: 1.5 }}>
              Likely missing = units sold since the last check × this item's loss rate (or the business's, at least 0.5%) × unit cost. Items below zero on the books come first: a sale or receipt was recorded wrongly.
            </div>
          </div>

          <div className="card card-pad stack" style={{ gap: 12 }}>
            <div className="row m-wrap" style={{ justifyContent: 'space-between', gap: 10 }}>
              <div>
                <div style={{ fontSize: 15, fontWeight: 600 }}>Daily spot checks</div>
                <div className="ink3" style={{ fontSize: 13, lineHeight: 1.5, marginTop: 2, maxWidth: 620 }}>Each morning at 5:30 the riskiest items at every branch go to one person's phone as a short blind count. Counta picks someone who did not sell those items lately, so the counter is never checking their own sales. Done daily, it replaces the month-end stock-take.</div>
              </div>
              {owner ? (
                <select className="input" style={{ maxWidth: 200 }} value={r.spot_checks_per_day} aria-label="Spot check items per branch"
                  onChange={(e) => { const n = Number(e.target.value); run(() => rpc('set_spot_checks', { p_org: orgId, p_n: n }), { ok: n ? `Daily spot checks on: ${n} items per branch` : 'Daily spot checks off', invalidate: ['radar', 'inv'] }); }}>
                  <option value={0}>Off</option>{[3, 5, 8, 10, 15].map((n) => <option key={n} value={n}>{n} items per branch</option>)}
                </select>
              ) : <Chip label={r.spot_checks_per_day ? `${r.spot_checks_per_day} items a day` : 'Off'} t={r.spot_checks_per_day ? 't-green' : 't-grey'} />}
            </div>
            {r.spot_checks.length > 0 && (
              <div className="stack" style={{ gap: 6 }}>
                {r.spot_checks.slice(0, 8).map((s) => (
                  <button key={s.id} className="row click" onClick={() => nav('/inventory/counts?open=' + s.id)}
                    style={{ border: '1px solid #EEF0F3', borderRadius: 10, padding: '8px 12px', background: '#fff', cursor: 'pointer', font: 'inherit', textAlign: 'left', gap: 10 }}>
                    <span style={{ fontWeight: 600, color: '#0072F5' }}>{s.ref}</span>
                    <span className="grow ink3" style={{ fontSize: 13 }}>{locName(s.location_id)} · {s.items} items · {s.assignee || 'unassigned'} · {when(s.created_at)}</span>
                    <Chip label={s.status === 'open' ? 'Waiting' : s.status === 'approved' ? 'Approved' : 'To review'} t={s.status === 'open' ? 't-blue' : s.status === 'approved' ? 't-green' : 't-amber'} />
                    {s.status !== 'open' && <span className="faint" style={{ fontSize: 12 }}>{s.differences ? `${s.differences} off` : 'all matched'}</span>}
                  </button>
                ))}
              </div>
            )}
          </div>

          {r.locations.length > 1 && (
            <div className="card" style={{ overflow: 'hidden' }}>
              <div className="card-hd"><Label>By branch</Label></div>
              <div style={{ overflow: 'auto' }}>
                <table className="mini-table" style={{ width: '100%', minWidth: 620 }}>
                  <thead><tr><th>Branch</th><th className="right">Went missing</th><th className="right">Share of cost of sales</th><th className="right">Damaged or expired</th><th className="right">Count accuracy</th><th className="right">Cash short</th></tr></thead>
                  <tbody>{r.locations.map((l) => (
                    <tr key={l.location_id}><td style={{ fontWeight: 600 }}>{l.name}</td><td className="right num">{N(l.unexplained - l.found)}</td><td className="right num">{pct(l.shrink_pct, 2)}</td>
                      <td className="right num">{N(l.damage)}</td><td className="right num">{l.ira == null ? '—' : l.ira.toFixed(1) + '%'}</td><td className="right num">{N(l.cash_short)}</td></tr>
                  ))}</tbody>
                </table>
              </div>
            </div>
          )}

          {r.can_see_people && r.people && (
            <div className="card" style={{ overflow: 'hidden' }}>
              <div className="card-hd"><Label>Losses found on items each person sold</Label></div>
              {(r.loss_events || 0) < 3 ? (
                <div className="muted" style={{ padding: 20, fontSize: 14 }}>Too few counts with missing stock to show a pattern yet ({r.loss_events || 0} in this period). Daily spot checks build this up quickly.</div>
              ) : (
                <div style={{ overflow: 'auto' }}>
                  <table className="mini-table" style={{ width: '100%', minWidth: 640 }}>
                    <thead><tr><th>Person</th><th className="right">Sales</th><th className="right">Sales value</th><th className="right">Missing on their items</th><th className="right">Per ₦100 sold</th><th className="right">Offline · voice</th></tr></thead>
                    <tbody>{r.people.map((p) => (
                      <tr key={p.member_id}><td style={{ fontWeight: 600 }}>{p.name}<div className="faint" style={{ fontSize: 11, fontWeight: 400, textTransform: 'capitalize' }}>{p.role}</div></td>
                        <td className="right num">{num(p.sales)}</td><td className="right num">{K(p.sales_value)}</td><td className="right num">{N(p.loss)}</td>
                        <td className="right num">{p.loss_pct == null ? '—' : '₦' + p.loss_pct.toFixed(2)}</td><td className="right num">{num(p.offline_sales)} · {num(p.voice_sales)}</td></tr>
                    ))}</tbody>
                  </table>
                </div>
              )}
              <div className="faint" style={{ fontSize: 12, padding: '10px 20px', lineHeight: 1.5 }}>
                When a count finds stock missing, its value is shared among the people who sold that item at that branch since it was last counted, by how much each sold. A high figure is a reason to watch and count more often. It is never proof of who took anything.
              </div>
            </div>
          )}
        </>
      )}
    </div>
  );
}

function Tile({ label, value, sub, tone }: { label: string; value: string; sub: string; tone?: 'red' | 'amber' | 'green' }) {
  const c = tone === 'red' ? '#B91C1C' : tone === 'amber' ? '#A16207' : tone === 'green' ? '#15803D' : '#111827';
  return (
    <div className="card" style={{ padding: '14px 16px' }}>
      <div className="mini-label">{label}</div>
      <div style={{ fontSize: 20, fontWeight: 600, marginTop: 4, color: c }} className="num">{value}</div>
      <div className="faint" style={{ fontSize: 12, marginTop: 2, lineHeight: 1.4 }}>{sub}</div>
    </div>
  );
}
const Dot = ({ c }: { c: string }) => <span style={{ display: 'inline-block', width: 8, height: 8, borderRadius: 2, background: c, margin: '0 4px 0 10px' }} />;
