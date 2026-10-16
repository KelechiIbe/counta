import { useEffect, useMemo, useState } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { can, useInventory, useSession } from '../../state/session';
import { useAction, useProposals, useReceipt, useReceipts } from '../../lib/queries';
import { must, rpc, supabase } from '../../lib/supabase';
import { N, N2, P, fmtDay, when } from '../../lib/format';
import { marginColor, suAbbr } from '../../lib/domain';
import type { Proposal } from '../../lib/types';
import { acct, usePostingMap } from '../../lib/accounts';
import { Icon } from '../../components/Icon';
import { Alert, Annot, Empty, Label, SkeletonRows } from '../../components/ui';

const KIND: Record<Proposal['kind'], [string, string]> = {
  cost_increase: ['Cost increase', 't-orange'], below_replacement: ['Below replacement cost', 't-red'], margin_compressed: ['Margin compressed', 't-amber'],
};
const m = (price: number, cost: number | null) => (cost == null || !price ? null : ((price - cost) / price) * 100);

function copy(p: Proposal, threshold: number, costs: boolean): string {
  const su = p.selling_unit;
  if (!costs) return p.kind === 'below_replacement' ? `Selling below what it costs to restock. Suggested price ${N(p.suggested_price)} per ${su}.` : `Costs have moved. Suggested price ${N(p.suggested_price)} per ${su}.`;
  const now = m(Number(p.old_price), Number(p.new_cost));
  const keep = m(Number(p.suggested_price), Number(p.new_cost));
  if (p.kind === 'cost_increase') return `Cost rose from ${N2(p.old_cost)} to ${N2(p.new_cost)} per ${su}. At ${N(p.old_price)} the margin drops to ${P(now)}; ${N(p.suggested_price)} keeps it near ${P(keep)}.`;
  if (p.kind === 'below_replacement') return `Selling at ${N(p.old_price)} but the latest invoice costs ${N2(p.new_cost)} per ${su} to replace, so each sale loses ${N(Number(p.new_cost) - Number(p.old_price))} against restocking.`;
  return `Margin is ${P(now)}, under your ${threshold}% threshold. ${N(p.suggested_price)} brings it back to ${P(keep)}.`;
}

export default function Pricing() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const proposals = useProposals();
  const { run, busy } = useAction();
  const location = useLocation();
  const nav = useNavigate();
  const [custom, setCustom] = useState<Record<string, string>>({});
  const [editing, setEditing] = useState<string | null>(null);
  const [landed, setLanded] = useState<string | null>((location.state as any)?.landed || null);
  useEffect(() => { if ((location.state as any)?.landed) nav(location.pathname, { replace: true, state: null }); }, []); // eslint-disable-line react-hooks/exhaustive-deps
  const changes = useQuery({
    queryKey: ['priceChanges', orgId], enabled: !!orgId && !!inv?.can_see_costs,
    queryFn: () => must<any[]>(supabase.from('price_changes').select('*').eq('org_id', orgId!).order('created_at', { ascending: false }).limit(15)),
  });
  if (!inv) return null;
  const owner = can(inv, 'edit_prices');
  const costs = inv.can_see_costs;
  const list = proposals.data || [];
  const open = list.filter((p) => p.status === 'open');
  const threshold = Number(inv.org.margin_threshold);
  const name = (id: string) => inv.items.find((i) => i.id === id)?.name || 'Item';
  const who = (id: string | null) => inv.members.find((x) => x.id === id)?.display_name || 'System';

  async function decide(p: Proposal, apply: boolean) {
    const price = custom[p.id] ? Number(custom[p.id]) : undefined;
    if (apply && price != null && !(price > 0)) return;
    await run(() => rpc('decide_proposal', { p_proposal: p.id, p_apply: apply, p_price: price ?? null }), {
      ok: apply ? `${p.item_name.split(' ').slice(0, 2).join(' ')} now ${N(price ?? p.suggested_price)}` : 'Price kept', invalidate: ['proposals', 'inv', 'priceChanges'],
    });
    setEditing(null);
  }

  return (
    <div className="container">
      <div className="row wrap" style={{ justifyContent: 'space-between' }}>
        <Label>Price proposals · {open.length} open</Label>
        {owner && <button className="btn btn-secondary btn-sm" disabled={busy} onClick={() => run(() => rpc<number>('refresh_price_alerts', { p_org: orgId }), { ok: (n) => n ? `${n} new proposal${n === 1 ? '' : 's'}` : 'Prices checked · nothing new', invalidate: ['proposals'] })}><Icon name="refresh" size={14} />Check prices now</button>}
      </div>
      <div className="stack" style={{ gap: 12 }}>
        {proposals.isLoading && <div className="card"><SkeletonRows n={3} /></div>}
        {list.map((p) => {
          const closed = p.status !== 'open';
          const nowM = m(Number(p.old_price), p.new_cost == null ? null : Number(p.new_cost));
          const sug = custom[p.id] ? Number(custom[p.id]) : Number(p.suggested_price);
          const keepM = m(sug, p.new_cost == null ? null : Number(p.new_cost));
          return (
            <div key={p.id} className="card" style={{ padding: '18px 20px', display: 'grid', gridTemplateColumns: 'minmax(240px,1.4fr) minmax(320px,2fr) auto', gap: 20, alignItems: 'center', opacity: closed ? 0.75 : 1 }}>
              <div style={{ minWidth: 0 }}>
                <span className={'chip ' + KIND[p.kind][1]}>{KIND[p.kind][0]}</span>
                <div style={{ fontSize: 15, fontWeight: 600, marginTop: 8 }}>{p.item_name}</div>
                <div className="ink3" style={{ fontSize: 13, lineHeight: 1.5, marginTop: 4 }}>{copy(p, threshold, costs)}</div>
                <div className="faint" style={{ fontSize: 11, marginTop: 6 }}>Source · {p.source_ref || '—'} · {fmtDay(p.created_at, false)}</div>
              </div>
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4,1fr)', gap: 4, background: '#FAFAFA', borderRadius: 12, padding: '12px 14px' }}>
                <div><div className="mini-label">Old cost</div><div className="ink3" style={{ fontSize: 15, marginTop: 4 }}>{costs ? N2(p.old_cost) : '—'}</div></div>
                <div><div className="mini-label">New cost</div><div style={{ fontSize: 15, fontWeight: 600, marginTop: 4 }}>{costs ? N2(p.new_cost) : '—'}</div></div>
                <div><div className="mini-label">Price now</div><div className="ink3" style={{ fontSize: 15, marginTop: 4 }}>{N(p.old_price)}</div>{costs && <div style={{ fontSize: 11, marginTop: 2, color: marginColor(nowM, threshold) }}>{P(nowM)} margin</div>}</div>
                <div>
                  <div className="mini-label" style={{ color: '#0072F5' }}>{custom[p.id] ? 'Your price' : 'Suggested'}</div>
                  {editing === p.id ? (
                    <input className="input input-sm" autoFocus type="number" min={1} style={{ marginTop: 2, width: 100 }} value={custom[p.id] ?? String(p.suggested_price)}
                      onChange={(e) => setCustom((c) => ({ ...c, [p.id]: e.target.value }))} onKeyDown={(e) => e.key === 'Enter' && setEditing(null)} />
                  ) : <div style={{ fontSize: 15, fontWeight: 700, color: '#0072F5', marginTop: 4 }}>{N(sug)}</div>}
                  {costs && <div style={{ fontSize: 11, marginTop: 2, color: marginColor(keepM, threshold) }}>{P(keepM)} margin</div>}
                </div>
              </div>
              <div className="stack" style={{ gap: 8, minWidth: 130 }}>
                {!closed && owner && (
                  <>
                    <button className="btn btn-primary btn-sm" disabled={busy} onClick={() => decide(p, true)}>Apply {N(sug)}</button>
                    <button className="btn btn-secondary btn-sm" disabled={busy} onClick={() => decide(p, false)}>Keep price</button>
                    <button className="btn btn-ghost btn-xs" onClick={() => setEditing(editing === p.id ? null : p.id)}>{editing === p.id ? 'Done' : 'Set my own price'}</button>
                  </>
                )}
                {!closed && !owner && <Annot>Awaits owner approval</Annot>}
                {closed && <span className={'chip ' + (p.status === 'applied' ? 't-green' : 't-grey')} style={{ textAlign: 'center', padding: '6px 10px', fontSize: 12 }}>{p.status === 'applied' ? 'Applied' : 'Kept price'}{p.decided_by_name ? ' · ' + p.decided_by_name.split(' ')[0] : ''}</span>}
              </div>
            </div>
          );
        })}
        {proposals.data && !list.length && <Empty>No price proposals. When an invoice costs more than last time, or a price slips under your {threshold}% margin, a proposal appears here. Nothing reprices on its own.</Empty>}
      </div>

      {owner && <LandedCost receiptId={landed} setReceiptId={setLanded} />}

      {costs && (
        <div className="card" style={{ overflow: 'hidden' }}>
          <div className="card-hd"><Label>Price changes · audit trail</Label><span className="faint" style={{ fontSize: 12 }}>Every change carries a reason and the person who made it</span></div>
          <div className="tbl">
            <div className="tr head th" style={{ gridTemplateColumns: '150px minmax(200px,1.5fr) 180px minmax(160px,1fr) 150px', minWidth: 860 }}>
              <span>When</span><span>Item</span><span>Price</span><span>Reason</span><span>By</span>
            </div>
            {changes.isLoading && <SkeletonRows n={3} />}
            {(changes.data || []).map((c) => (
              <div key={c.id} className="tr" style={{ gridTemplateColumns: '150px minmax(200px,1.5fr) 180px minmax(160px,1fr) 150px', minWidth: 860 }}>
                <span className="muted">{when(c.created_at)}</span><span style={{ fontWeight: 500 }}>{name(c.item_id)}</span>
                <span className="num">{N(c.old_price)} → <b>{N(c.new_price)}</b></span><span className="ink3">{c.reason}</span><span className="ink3">{who(c.changed_by)}</span>
              </div>
            ))}
            {changes.data && !changes.data.length && <div className="muted" style={{ padding: 20, fontSize: 14 }}>No price changes yet.</div>}
          </div>
        </div>
      )}
    </div>
  );
}

const CHARGES = ['Duty', 'Clearing', 'Haulage', 'Agent'];

function LandedCost({ receiptId, setReceiptId }: { receiptId: string | null; setReceiptId: (id: string | null) => void }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const receipts = useReceipts();
  const posted = (receipts.data || []).filter((r) => r.status === 'posted');
  const sel = receiptId || posted[0]?.id || null;
  const receipt = useReceipt(sel);
  const { run, busy } = useAction();
  const map = usePostingMap().data;
  const [charges, setCharges] = useState<Record<string, string>>({});
  const [other, setOther] = useState({ label: '', amount: '' });
  const [payee, setPayee] = useState('');
  const history = useQuery({
    queryKey: ['landed', orgId], enabled: !!orgId,
    queryFn: () => must<any[]>(supabase.from('landed_costs').select('*, journals(ref)').eq('org_id', orgId!).order('created_at', { ascending: false }).limit(10)),
  });
  const rows = useMemo(() => {
    const by: Record<string, { item_id: string; name: string; value: number; su: number; unit: string }> = {};
    for (const l of receipt.data?.receipt_lines || []) {
      if (!l.item_id) continue;
      const it = inv?.items.find((i) => i.id === l.item_id);
      const v = Number(l.qty) * Number(l.unit_cost);
      const su = Number(l.qty) * (l.unit_kind === 'purchase' ? it?.pack_size || 1 : 1);
      by[l.item_id] = by[l.item_id] || { item_id: l.item_id, name: it?.name || 'Item', value: 0, su: 0, unit: it?.selling_unit || 'unit' };
      by[l.item_id].value += v; by[l.item_id].su += su;
    }
    return Object.values(by).sort((a, b) => b.value - a.value);
  }, [receipt.data, inv]);
  if (!inv) return null;
  const totalCharges = CHARGES.reduce((a, k) => a + (Number(charges[k]) || 0), 0) + (Number(other.amount) || 0);
  const invoice = rows.reduce((a, r) => a + r.value, 0);
  const done = (history.data || []).filter((h) => h.receipt_id === sel);
  let left = totalCharges;
  const alloc = rows.map((r, i) => {
    const a = i === rows.length - 1 ? Math.round(left * 100) / 100 : Math.round((totalCharges * r.value / (invoice || 1)) * 100) / 100;
    left -= a;
    return { ...r, share: invoice ? r.value / invoice : 0, alloc: a, landed: r.value + a };
  });
  async function post() {
    const payload: Record<string, number> = {};
    for (const k of CHARGES) if (Number(charges[k]) > 0) payload[k] = Number(charges[k]);
    if (other.label.trim() && Number(other.amount) > 0) payload[other.label.trim()] = Number(other.amount);
    const r = await run(() => rpc<any>('post_landed_cost', { p_receipt: sel, p_charges: payload, p_payee: payee || null }), {
      ok: (r) => `${r.journal_ref} posted · ${N(r.absorbed)} into stock value${Number(r.expensed) ? `, ${N(r.expensed)} to cost of sales` : ''}`,
      invalidate: ['inv', 'ledger', 'landed', 'activity', 'proposals'],
    });
    if (r) { setCharges({}); setOther({ label: '', amount: '' }); setPayee(''); }
  }
  const r0 = receipt.data;
  return (
    <div className="card card-pad">
      <div className="row wrap" style={{ justifyContent: 'space-between', gap: 12 }}>
        <div className="row"><Label>Landed cost{r0 ? ` · ${r0.ref}` : ''}</Label><span className="chip t-grey" style={{ fontSize: 10 }}>PHASE 4</span></div>
        <select className="input input-sm" style={{ maxWidth: 360 }} value={sel || ''} onChange={(e) => setReceiptId(e.target.value)} aria-label="Receipt">
          {!posted.length && <option value="">No posted receipts yet</option>}
          {posted.map((r) => <option key={r.id} value={r.id}>{r.ref} · {r.vendor_name} · {N(r.gross)} · {fmtDay(r.posted_at || r.created_at, false)}</option>)}
        </select>
      </div>
      <div className="ink3" style={{ fontSize: 13, marginTop: 8, lineHeight: 1.5 }}>Shipment charges like duty, clearing, haulage and agent fees are spread across the receipt by line value. Duty and levies post to {acct(map, 'landed_duty').code} {acct(map, 'landed_duty').name}, the rest to {acct(map, 'landed_freight').code} {acct(map, 'landed_freight').name}. Stock still on hand absorbs its share into weighted average cost and moves into {acct(map, 'inventory').code}; any share on stock already sold stays in cost of sales.</div>
      {sel && (
        <>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(130px,1fr))', gap: 10, marginTop: 14 }}>
            {CHARGES.map((k) => (
              <div key={k}><label className="field-label" style={{ fontSize: 12 }}>{k}</label><input className="input input-sm" type="number" min={0} placeholder="₦0" value={charges[k] || ''} onChange={(e) => setCharges((c) => ({ ...c, [k]: e.target.value }))} /></div>
            ))}
            <div><label className="field-label" style={{ fontSize: 12 }}>Other charge</label><input className="input input-sm" placeholder="Label" value={other.label} onChange={(e) => setOther((o) => ({ ...o, label: e.target.value }))} /></div>
            <div><label className="field-label" style={{ fontSize: 12 }}>Amount</label><input className="input input-sm" type="number" min={0} placeholder="₦0" value={other.amount} onChange={(e) => setOther((o) => ({ ...o, amount: e.target.value }))} /></div>
            <div><label className="field-label" style={{ fontSize: 12 }}>Pay to</label><input className="input input-sm" placeholder="Clearing agent" value={payee} onChange={(e) => setPayee(e.target.value)} /></div>
          </div>
          <div className="th" style={{ marginTop: 16, display: 'grid', gridTemplateColumns: 'minmax(200px,1.5fr) 120px 80px 120px 130px 120px', gap: 12, padding: '0 4px' }}>
            <span>Line</span><span className="right">Invoice</span><span className="right">Share</span><span className="right">Allocated</span><span className="right">Landed</span><span className="right">Per unit</span>
          </div>
          {receipt.isLoading && <SkeletonRows n={2} />}
          {alloc.map((a) => (
            <div key={a.item_id} style={{ display: 'grid', gridTemplateColumns: 'minmax(200px,1.5fr) 120px 80px 120px 130px 120px', gap: 12, fontSize: 13, padding: '10px 4px', borderTop: '1px solid #F3F4F6', alignItems: 'center' }}>
              <span style={{ fontWeight: 500 }}>{a.name}</span><span className="right ink3 num">{N(a.value)}</span><span className="right ink3">{P(a.share * 100)}</span>
              <span className="right num" style={{ color: '#A16207' }}>+{N(a.alloc)}</span><span className="right num" style={{ fontWeight: 600 }}>{N(a.landed)}</span>
              <span className="right ink3 num">{a.su ? N2(a.landed / a.su) + '/' + suAbbr(a.unit) : '—'}</span>
            </div>
          ))}
          <div className="row wrap" style={{ justifyContent: 'space-between', borderTop: '1px solid #E6E6E6', marginTop: 4, paddingTop: 12, gap: 10 }}>
            <span className="ink3" style={{ fontSize: 13 }}>Invoice {N(invoice)} + charges {N(totalCharges)} = <b style={{ color: '#111827' }}>{N(invoice + totalCharges)}</b> into inventory valuation</span>
            <button className="btn btn-dark btn-sm" disabled={busy || totalCharges <= 0 || !rows.length} onClick={post}>Post allocation with receipt</button>
          </div>
          {done.length > 0 && <Alert kind="grey" icon="info" style={{ marginTop: 12 }}>{done.map((h) => `${h.journals?.ref || 'Journal'} allocated ${N(h.total)} on ${fmtDay(h.created_at, false)}`).join(' · ')}. Posting again adds a further allocation.</Alert>}
          {!rows.length && !receipt.isLoading && <Alert kind="yellow" icon="info" style={{ marginTop: 12 }}>This receipt has no stock lines to allocate to.</Alert>}
        </>
      )}
      {!posted.length && receipts.data && <Empty style={{ marginTop: 12 }}>Post a receipt first, then allocate its shipment charges here.</Empty>}
    </div>
  );
}

