import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { can, useInventory, useSession, useToast } from '../../state/session';
import { useAction } from '../../lib/queries';
import { rpc } from '../../lib/supabase';
import { N, addDays, fmtDay, num, when } from '../../lib/format';
import { downloadBlob, reportXlsx, safeName } from '../../lib/exporters';
import type { RCol } from '../../lib/reports';
import { Icon } from '../../components/Icon';
import { Alert, Annot, Chip, Field, Label, Modal, ModalHead, Spinner } from '../../components/ui';

interface Line {
  item_id: string; location_id: string; item: string; location: string; category: string; unit: string; qty: number; unit_cost: number | null;
  value: number; price: number | null; nrv_unit: number | null; age_days: number | null; expired_qty: number; allowance: number; reason: string | null;
}
interface Preview {
  period_end: string; closed_through: string | null; today: string; can_close: boolean; stock_value: number; lines_count: number; negative_lines: number;
  gl_inventory: number; wip_value: number; transit_value: number; current_allowance: number; proposed_allowance: number; lines: Line[];
  checks: { receipts_waiting: number; counts_waiting: number; counts_open: number; transfers_in_transit: number; runs_open: number; voice_to_review: number };
}
interface Close {
  id: string; period_end: string; status: 'closed' | 'reopened'; stock_value: number; gl_value: number | null; wip_value: number; transit_value: number;
  allowance: number; allowance_change: number; journal_ref: string | null; lines_count: number; note: string | null; closed_at: string; closed_by: string | null;
  reopened_at: string | null; reopened_by: string | null; policy: Record<string, number>;
}
const POLICY = { selling_cost_pct: 0, age_180_pct: 25, age_365_pct: 50, expired_pct: 100 };
const monthEnd = (day: string) => { const d = new Date(day + 'T12:00:00Z'); return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 0)).toISOString().slice(0, 10); };
const monthName = (day: string) => new Date(day + 'T12:00:00Z').toLocaleString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' });
// "October 2026" for a full month, "to 16 Oct 2026" when the close stops part way through one.
const closeName = (day: string) => (monthEnd(day) === day ? monthName(day) : 'to ' + fmtDay(day));

export default function MonthEnd() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const closes = useQuery({ queryKey: ['closes', orgId], enabled: !!orgId && !!inv?.can_see_costs, queryFn: () => rpc<{ closed_through: string | null; closes: Close[] }>('get_period_closes', { p_org: orgId }) });
  const today = inv?.today || new Date().toISOString().slice(0, 10);
  const lastMonthEnd = addDays(today.slice(0, 8) + '01', -1);
  const [end, setEnd] = useState(lastMonthEnd);
  const [policy, setPolicy] = useState(POLICY);
  const [debounced, setDebounced] = useState({ end, policy });
  const [overrides, setOverrides] = useState<Record<string, string>>({});
  const [confirm, setConfirm] = useState(false);
  useEffect(() => { const t = setTimeout(() => setDebounced({ end, policy }), 400); return () => clearTimeout(t); }, [end, policy]);
  useEffect(() => {
    const ct = closes.data?.closed_through;
    if (ct && end <= ct) setEnd(monthEnd(addDays(ct, 1)) < today ? monthEnd(addDays(ct, 1)) : addDays(today, -1));
  }, [closes.data?.closed_through]); // eslint-disable-line react-hooks/exhaustive-deps
  const preview = useQuery({
    queryKey: ['close-preview', orgId, debounced.end, JSON.stringify(debounced.policy)],
    enabled: !!orgId && !!inv?.can_see_costs && !!debounced.end,
    queryFn: () => rpc<Preview>('period_close_preview', { p_org: orgId, p_period_end: debounced.end, p_policy: debounced.policy }),
  });
  const p = preview.data;
  const key = (l: Pick<Line, 'item_id' | 'location_id'>) => l.item_id + '|' + l.location_id;
  const allowanceOf = (l: Line) => (overrides[key(l)] !== undefined ? Math.max(0, Math.min(Number(overrides[key(l)]) || 0, l.value)) : Number(l.allowance));
  const newAllowance = useMemo(() => {
    if (!p) return 0;
    const changed = p.lines.reduce((a, l) => a + allowanceOf(l) - Number(l.allowance), 0);
    return Number(p.proposed_allowance) + changed;
  }, [p, overrides]); // eslint-disable-line react-hooks/exhaustive-deps
  if (!inv) return null;
  if (!inv.can_see_costs) return <div className="container"><Alert kind="yellow" icon="shield">Month-end close works with costs. Ask the owner for the See margins permission.</Alert></div>;
  const owner = can(inv, 'owner');
  const agrees = p ? Math.abs(Number(p.stock_value) + Number(p.wip_value) - Number(p.gl_inventory)) < 1 : false;
  const change = p ? newAllowance - Number(p.current_allowance) : 0;
  const checks = p ? [
    [p.checks.receipts_waiting, 'invoice', 'waiting to be posted in Receive stock', '/inventory/receive'],
    [p.checks.counts_waiting, 'count', 'waiting for your approval', '/inventory/counts'],
    [p.checks.counts_open, 'count', 'still being counted', '/inventory/counts'],
    [p.checks.transfers_in_transit, 'transfer', 'not yet received at the other branch', '/inventory/locations'],
    [p.checks.runs_open, 'production run', 'still open, so its cost sits in work in progress', '/inventory/production'],
    [p.checks.voice_to_review, 'voice sale', 'not yet reviewed', '/inventory/locations'],
  ].filter(([n]) => Number(n) > 0) as [number, string, string, string][] : [];

  async function downloadSnapshot(c: Close) {
    try {
      const rows = await rpc<Record<string, unknown>[]>('get_period_close_lines', { p_close: c.id });
      const cols: RCol[] = [
        { key: 'item', label: 'Item' }, { key: 'sku', label: 'SKU' }, { key: 'category', label: 'Category' }, { key: 'location', label: 'Branch' },
        { key: 'qty', label: 'Qty', type: 'qty' }, { key: 'unit', label: 'Unit' }, { key: 'unit_cost', label: 'Unit cost', type: 'money' },
        { key: 'value', label: 'Value at cost', type: 'money', total: true }, { key: 'price', label: 'Price', type: 'money' },
        { key: 'nrv_unit', label: 'Net realisable value', type: 'money' }, { key: 'allowance', label: 'Allowance', type: 'money', total: true },
        { key: 'carrying', label: 'Carrying amount', type: 'money', total: true }, { key: 'reason', label: 'Reason' },
      ];
      const meta = { org: inv!.org.name, title: `Closing stock · ${monthEnd(c.period_end) === c.period_end ? monthName(c.period_end) : fmtDay(c.period_end)}`, period: `As at ${fmtDay(c.period_end)}`, branch: 'All branches', by: inv!.me.display_name,
        generated: new Date().toLocaleString('en-GB', { timeZone: 'Africa/Lagos' }), note: `Closed ${fmtDay(c.closed_at.slice(0, 10))}${c.closed_by ? ' by ' + c.closed_by : ''}. Values at weighted average cost; the allowance carries stock at the lower of cost and net realisable value.` };
      downloadBlob(await reportXlsx(meta, cols, rows, [`Stock at cost ${N(c.stock_value)} · allowance ${N(c.allowance)} · carrying amount ${N(c.stock_value - c.allowance)}`]),
        `${safeName(inv!.org.name)} – closing stock – ${c.period_end}.xlsx`);
    } catch (e: any) { toast(e.message || 'Download failed', 'err'); }
  }

  const latest = closes.data?.closes.find((c) => c.status === 'closed');
  return (
    <div className="container">
      <div className="row m-wrap" style={{ justifyContent: 'space-between', gap: 12, alignItems: 'flex-start' }}>
        <div className="ink3" style={{ fontSize: 14, maxWidth: 720, lineHeight: 1.55 }}>
          Closing a month freezes its closing stock and sets the allowance for stock worth less than it cost, so the books carry stock at the lower of cost and net realisable value. Nothing can post into a closed month: a phone that syncs late posts on the first open day with a note. Next month opens on exactly this month's closing figure.
        </div>
        <div className="card" style={{ padding: '10px 14px', flex: 'none' }}>
          <div className="mini-label">Closed through</div>
          <div style={{ fontSize: 16, fontWeight: 600, marginTop: 2 }}>{closes.data?.closed_through ? fmtDay(closes.data.closed_through) : 'Nothing closed yet'}</div>
        </div>
      </div>

      <div className="card">
        <div className="card-pad stack" style={{ gap: 14 }}>
          <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(150px,1fr))', gap: 12 }}>
            <Field label="Close up to"><input className="input" type="date" value={end} max={addDays(today, -1)} onChange={(e) => { setEnd(e.target.value); setOverrides({}); }} /></Field>
            <Field label="Selling costs, % of price" hint="Delivery, commission and the like."><input className="input" type="number" min={0} max={90} value={policy.selling_cost_pct} onChange={(e) => setPolicy({ ...policy, selling_cost_pct: Number(e.target.value) })} /></Field>
            <Field label="No sales 181–365 days"><div className="row" style={{ gap: 6 }}><input className="input" type="number" min={0} max={100} value={policy.age_180_pct} onChange={(e) => setPolicy({ ...policy, age_180_pct: Number(e.target.value) })} /><span className="muted">%</span></div></Field>
            <Field label="No sales over 365 days"><div className="row" style={{ gap: 6 }}><input className="input" type="number" min={0} max={100} value={policy.age_365_pct} onChange={(e) => setPolicy({ ...policy, age_365_pct: Number(e.target.value) })} /><span className="muted">%</span></div></Field>
            <Field label="Expired batches"><div className="row" style={{ gap: 6 }}><input className="input" type="number" min={0} max={100} value={policy.expired_pct} onChange={(e) => setPolicy({ ...policy, expired_pct: Number(e.target.value) })} /><span className="muted">%</span></div></Field>
          </div>
          <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }}>
            Each line's allowance is the largest of three tests: price below cost (net of selling costs), batches past their expiry date, and time since the item last sold or was used. The percentages are your policy; set them once with your accountant.
          </div>
        </div>
        {preview.isLoading || (preview.isFetching && !p) ? <div style={{ display: 'grid', placeItems: 'center', minHeight: 160 }}><Spinner /></div> : preview.error ? (
          <div className="card-pad"><Alert kind="red" icon="alert">{(preview.error as Error).message}</Alert></div>
        ) : p && closes.data?.closed_through && p.period_end <= closes.data.closed_through ? (
          <div className="card-pad" style={{ borderTop: '1px solid #F3F4F6' }}>
            <Alert kind="green" icon="lock">
              The books are closed through {fmtDay(closes.data.closed_through)}. Its figures are in the history below, with a snapshot to download. Pick a later day to close, once that day has ended.
            </Alert>
          </div>
        ) : p && (
          <>
            <div className="card-pad" style={{ borderTop: '1px solid #F3F4F6' }}>
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(170px,1fr))', gap: 12 }}>
                <Fig label={`Stock at cost, ${fmtDay(p.period_end)}`} value={N(Number(p.stock_value) + Number(p.wip_value))} sub={`${num(p.lines_count)} item lines${Number(p.wip_value) ? ` · ${N(p.wip_value)} in production` : ''}`} />
                <Fig label="Inventory accounts" value={N(p.gl_inventory)} sub={agrees ? 'Agrees with the stock' : `Differs by ${N(Number(p.stock_value) + Number(p.wip_value) - Number(p.gl_inventory))}`} tone={agrees ? 'green' : 'red'} />
                <Fig label="Allowance after close" value={N(newAllowance)} sub={`Now ${N(p.current_allowance)} · ${change >= 0 ? 'write down' : 'release'} ${N(Math.abs(change))}`} />
                <Fig label="Carrying amount" value={N(Number(p.stock_value) + Number(p.wip_value) - newAllowance)} sub={Number(p.transit_value) ? `plus ${N(p.transit_value)} in transit` : 'lower of cost and net realisable value'} />
              </div>
            </div>
            {(checks.length > 0 || p.negative_lines > 0) && (
              <div className="card-pad" style={{ paddingTop: 0 }}>
                <Alert kind="yellow" icon="info">
                  <div className="stack" style={{ gap: 4 }}>
                    <b>Before you close</b>
                    {checks.map(([n, what, why, to]) => <span key={what + why}>{n} {what}{n === 1 ? '' : 's'} {why}. <Link to={to}>Open</Link></span>)}
                    {p.negative_lines > 0 && <span>{p.negative_lines} item line{p.negative_lines === 1 ? ' shows' : 's show'} below zero. Count {p.negative_lines === 1 ? 'it' : 'them'} so the closing figure is real.</span>}
                  </div>
                </Alert>
              </div>
            )}
            <div style={{ overflow: 'auto', borderTop: '1px solid #F3F4F6' }}>
              {p.lines.length ? (
                <table className="mini-table report-table" style={{ width: '100%', minWidth: 860 }}>
                  <thead><tr><th>Item</th><th>Branch</th><th className="right">Qty</th><th className="right">Unit cost</th><th className="right">Value</th><th className="right">Net realisable value</th><th>Reason</th><th className="right">Allowance</th></tr></thead>
                  <tbody>
                    {p.lines.map((l) => (
                      <tr key={key(l)}>
                        <td>{l.item}</td><td className="ink3">{l.location}</td>
                        <td className="right num" style={{ color: l.qty < 0 ? '#DC2626' : undefined }}>{num(Number(l.qty), 2)} {l.unit}</td>
                        <td className="right num">{l.unit_cost != null ? N(l.unit_cost) : '—'}</td>
                        <td className="right num">{N(l.value)}</td>
                        <td className="right num">{l.nrv_unit != null ? N(l.nrv_unit) : '—'}</td>
                        <td className="ink3">{l.qty < 0 ? 'Below zero, count it' : l.reason || ''}{l.expired_qty > 0 && l.reason !== 'Expired batches' ? ` · ${num(l.expired_qty)} expired` : ''}</td>
                        <td className="right">
                          {owner && p.can_close && l.qty > 0 ? (
                            <input className="input input-sm num" style={{ width: 120, textAlign: 'right' }} type="number" min={0} max={l.value} aria-label={'Allowance for ' + l.item}
                              value={overrides[key(l)] ?? String(l.allowance)} onChange={(e) => setOverrides({ ...overrides, [key(l)]: e.target.value })} />
                          ) : <span className="num">{N(allowanceOf(l))}</span>}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              ) : <div className="muted" style={{ padding: '20px', fontSize: 14 }}>No item needs writing down at {fmtDay(p.period_end)}. Everything is worth at least what it cost.</div>}
            </div>
            <div className="card-pad row m-wrap" style={{ justifyContent: 'space-between', gap: 12, borderTop: '1px solid #F3F4F6' }}>
              <span className="faint" style={{ fontSize: 12, maxWidth: 560, lineHeight: 1.5 }}>
                Closing posts one entry dated {fmtDay(p.period_end)}: Dr inventory write-downs, Cr allowance for inventory obsolescence (or the reverse when the allowance falls). Stock at cost does not change.
              </span>
              {owner ? (
                <button className="btn btn-primary" disabled={!p.can_close} onClick={() => setConfirm(true)} title={p.can_close ? '' : 'Choose a day after the last close and before today'}>
                  <Icon name="lock" size={15} color="#fff" />Close {closeName(p.period_end)}
                </button>
              ) : <Annot>Only the owner closes a month</Annot>}
            </div>
          </>
        )}
      </div>

      <div className="card" style={{ overflow: 'hidden' }}>
        <div className="card-hd"><Label>Closed months</Label></div>
        {closes.data?.closes.length ? (
          <div style={{ overflow: 'auto' }}>
            <table className="mini-table" style={{ width: '100%', minWidth: 760 }}>
              <thead><tr><th>Up to</th><th className="right">Stock at cost</th><th className="right">Allowance</th><th className="right">Carrying amount</th><th>Entry</th><th>Closed</th><th /></tr></thead>
              <tbody>
                {closes.data.closes.map((c) => (
                  <tr key={c.id} style={{ opacity: c.status === 'reopened' ? 0.55 : 1 }}>
                    <td style={{ fontWeight: 600 }}>{fmtDay(c.period_end)} {c.status === 'reopened' && <Chip label="Reopened" t="t-grey" />}</td>
                    <td className="right num">{N(Number(c.stock_value) + Number(c.wip_value))}</td>
                    <td className="right num">{N(c.allowance)}</td>
                    <td className="right num">{N(Number(c.stock_value) + Number(c.wip_value) - Number(c.allowance))}</td>
                    <td className="ink3">{c.journal_ref || '—'}</td>
                    <td className="ink3">{when(c.closed_at)}{c.closed_by ? ' · ' + c.closed_by : ''}</td>
                    <td className="right" style={{ whiteSpace: 'nowrap' }}>
                      <div className="row" style={{ gap: 4, justifyContent: 'flex-end' }}>
                        <button className="btn btn-ghost btn-xs" onClick={() => downloadSnapshot(c)}><Icon name="download" size={13} />Snapshot</button>
                        {owner && latest?.id === c.id && <ReopenButton close={c} />}
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : <div className="muted" style={{ padding: 20, fontSize: 14 }}>No month has been closed. Close last month once its invoices, counts and transfers are in.</div>}
      </div>

      <div className="card card-pad stack" style={{ gap: 6, fontSize: 13.5, lineHeight: 1.6 }}>
        <Label>How opening and closing stock are worked out</Label>
        <div className="ink3">Counta keeps stock perpetually at weighted average cost. Closing stock for any day is every movement up to the end of that day: opening stock, plus receipts at cost (with landed charges), production output and transfers in, less sales at cost, stock issued to jobs and transfers out, plus or minus count adjustments and write-offs. The Stock movement summary report shows each of those columns per item, and the Stock valuation report agrees the total to the inventory accounts.</div>
        <div className="ink3">The opening stock of a period is the closing stock of the day before it. A closed month makes that figure permanent. Moving from another system? <Link to="/inventory/migrate">Move to Counta</Link> sets opening stock as at your go-live date.</div>
      </div>

      {confirm && p && <CloseModal p={p} policy={policy} overrides={p.lines.filter((l) => overrides[key(l)] !== undefined).map((l) => ({ item_id: l.item_id, location_id: l.location_id, allowance: allowanceOf(l) }))}
        allowance={newAllowance} change={change} checks={checks.length} onClose={() => setConfirm(false)} />}
    </div>
  );
}

function Fig({ label, value, sub, tone }: { label: string; value: string; sub: string; tone?: 'green' | 'red' }) {
  return (
    <div style={{ border: '1px solid #EEF0F3', borderRadius: 12, padding: '12px 14px' }}>
      <div className="mini-label">{label}</div>
      <div style={{ fontSize: 18, fontWeight: 600, marginTop: 4 }} className="num">{value}</div>
      <div style={{ fontSize: 12, marginTop: 2, color: tone === 'green' ? '#15803D' : tone === 'red' ? '#B91C1C' : '#6B7280' }}>{sub}</div>
    </div>
  );
}

function CloseModal({ p, policy, overrides, allowance, change, checks, onClose }: {
  p: Preview; policy: typeof POLICY; overrides: { item_id: string; location_id: string; allowance: number }[]; allowance: number; change: number; checks: number; onClose: () => void;
}) {
  const { orgId } = useSession();
  const { run, busy } = useAction();
  const [note, setNote] = useState('');
  async function go() {
    const r = await run(() => rpc<any>('close_period', { p_org: orgId, p_period_end: p.period_end, p_policy: policy, p_overrides: overrides, p_note: note }),
      { ok: (x) => `Closed ${closeName(p.period_end)}${x.journal_ref ? ' · ' + x.journal_ref : ''}`, invalidate: ['closes', 'close-preview', 'ledger', 'report'] });
    if (r) onClose();
  }
  return (
    <Modal onClose={onClose} width={480}>
      <ModalHead title={`Close ${closeName(p.period_end)}?`} onClose={onClose} />
      <div className="modal-body">
        <div className="ink3" style={{ fontSize: 14, lineHeight: 1.55 }}>
          Stock up to {fmtDay(p.period_end)} locks at {N(Number(p.stock_value) + Number(p.wip_value))} at cost, carried at {N(Number(p.stock_value) + Number(p.wip_value) - allowance)}.
          {change !== 0 ? ` One entry ${change > 0 ? 'writes down' : 'releases'} ${N(Math.abs(change))}.` : ' The allowance does not change, so nothing posts.'}
        </div>
        {checks > 0 && <Alert kind="yellow" icon="info">Some items on the checklist are still open. Anything they post later lands in the next month.</Alert>}
        <Field label="Note"><input className="input" value={note} onChange={(e) => setNote(e.target.value)} placeholder="Optional, e.g. agreed with the accountant" /></Field>
      </div>
      <div className="modal-ft">
        <button className="btn btn-secondary" onClick={onClose}>Not yet</button>
        <button className="btn btn-primary" disabled={busy} onClick={go}><Icon name="lock" size={15} color="#fff" />Close and lock</button>
      </div>
    </Modal>
  );
}

function ReopenButton({ close }: { close: Close }) {
  const { orgId } = useSession();
  const { run, busy } = useAction();
  const [ask, setAsk] = useState(false);
  const [reason, setReason] = useState('');
  return (
    <>
      <button className="btn btn-ghost btn-xs" onClick={() => setAsk(true)}>Reopen</button>
      {ask && (
        <Modal onClose={() => setAsk(false)} width={440}>
          <ModalHead title={`Reopen ${closeName(close.period_end)}?`} onClose={() => setAsk(false)} />
          <div className="modal-body">
            <div className="ink3" style={{ fontSize: 14, lineHeight: 1.55 }}>The month's allowance entry is reversed and postings can land in it again. Close it again when you are done.</div>
            <Field label="Why"><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. late supplier invoice" /></Field>
          </div>
          <div className="modal-ft">
            <button className="btn btn-secondary" onClick={() => setAsk(false)}>Cancel</button>
            <button className="btn btn-primary" disabled={busy} onClick={() => run(() => rpc('reopen_period', { p_org: orgId, p_reason: reason }), { ok: 'Month reopened', invalidate: ['closes', 'close-preview', 'ledger', 'report'] }).then(() => setAsk(false))}>Reopen</button>
          </div>
        </Modal>
      )}
    </>
  );
}
