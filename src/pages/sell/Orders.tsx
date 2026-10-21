// Orders and deliveries: orders from the online shop, the phone or a sales rep wait here until confirmed; confirmed orders
// for delivery get a delivery note that follows the van to the customer.
import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { can, useInventory, useSession, useToast } from '../../state/session';
import { rpc } from '../../lib/supabase';
import { money, useDeliveries, useSales, type Customer, type Sale } from '../../lib/api';
import { N2, fmtDay, when } from '../../lib/format';
import { Icon } from '../../components/Icon';
import { PeriodPicker } from '../../components/PeriodPicker';
import { useScreenPeriod } from '../../lib/period';
import { ItemPicker } from '../../components/ItemPicker';
import { Alert, Drawer, Empty, Field, Modal, ModalHead, Pills, SkeletonRows } from '../../components/ui';
import type { Item } from '../../lib/types';
import { CustomerPicker, StatusChip } from './common';
import { SaleDrawer } from './Sales';

export default function Orders() {
  const { data: inv } = useInventory();
  const [tab, setTab] = useState<'waiting' | 'all' | 'deliveries'>('waiting');
  const [open, setOpen] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
  const { orgId } = useSession();
  const [period, setPeriod] = useScreenPeriod(orgId, 'orders', 'all', inv?.org.fiscal_year_start || 1);
  const orders = useSales({ doc_type: 'order', limit: 300, from: period.preset === 'all' ? null : period.from, to: period.preset === 'all' ? null : period.to });
  const deliveries = useDeliveries(60);
  if (!inv) return null;
  const rows = (orders.data?.rows || []).filter((o) => tab === 'all' || (!o.confirmed && !['cancelled', 'void'].includes(o.status)));
  return (
    <div className="container">
      <div className="row wrap" style={{ justifyContent: 'space-between' }}>
        <Pills value={tab} onChange={setTab} options={[{ id: 'waiting', label: 'Waiting to confirm', count: orders.data?.orders_waiting || undefined }, { id: 'all', label: 'All orders' }, { id: 'deliveries', label: 'Deliveries' }]} />
        <div className="row wrap">
          {tab !== 'deliveries' && <PeriodPicker value={period} onChange={setPeriod} align="end" />}
          <button className="btn btn-primary btn-sm" onClick={() => setCreating(true)}><Icon name="plus" size={14} color="#fff" />Take an order</button>
        </div>
      </div>
      {tab !== 'deliveries' ? (
        <div className="card" style={{ overflow: 'hidden' }}>
          {orders.isLoading ? <SkeletonRows n={6} /> : !rows.length ? <div style={{ padding: 20 }}><Empty>{tab === 'waiting' ? 'No orders waiting. Orders from your online shop and the ones staff take by phone appear here.' : 'No orders yet.'}</Empty></div> : rows.map((o) => (
            <div key={o.id} className="tr click" onClick={() => setOpen(o.id)} style={{ gridTemplateColumns: '120px minmax(0,1.4fr) 120px 130px 120px 120px' }}>
              <b>{o.number}</b>
              <span className="ellipsis">{o.customer_name}<span className="faint" style={{ display: 'block', fontSize: 11 }}>{when(o.created_at)} · {o.channel === 'online' ? 'online shop' : o.channel}{(o as any).delivery_method === 'delivery' ? ' · delivery' : (o as any).delivery_method === 'pickup' ? ' · pickup' : ''}</span></span>
              <span><StatusChip s={o.confirmed && o.status === 'pending' ? 'open' : o.status} /></span>
              <span className="right num">{N2(o.total)}</span>
              <span className="right num muted">{Number(o.amount_paid) ? `${N2(o.amount_paid)} paid` : '—'}</span>
              <span className="muted" style={{ fontSize: 12 }}>{o.confirmed ? 'Confirmed' : 'Not yet confirmed'}</span>
            </div>
          ))}
        </div>
      ) : (
        <Deliveries list={deliveries.data || []} loading={deliveries.isLoading} onOpen={setOpen} />
      )}
      {open && <OrderDrawer id={open} onClose={() => setOpen(null)} />}
      {creating && <OrderEditor onClose={() => setCreating(false)} onSaved={(id) => { setCreating(false); setOpen(id); }} />}
    </div>
  );
}

function OrderDrawer({ id, onClose }: { id: string; onClose: () => void }) {
  const [cancel, setCancel] = useState(false);
  const [reason, setReason] = useState('');
  return (
    <SaleDrawer id={id} onClose={onClose} actions={(s, act, busy) => s.doc_type !== 'order' || s.journal_id || ['cancelled', 'void'].includes(s.status) ? null : (
      <>
        <button className="btn btn-primary btn-sm" disabled={busy} onClick={() => act(() => rpc('confirm_order', { p_sale: s.id }), 'Order confirmed. Stock and revenue are in the books.')}><Icon name="check" size={14} color="#fff" />Confirm order</button>
        {!cancel ? <button className="btn btn-secondary btn-sm" onClick={() => setCancel(true)}>Cancel order</button> : (
          <span className="row"><input className="input input-sm" autoFocus placeholder="Why is it cancelled?" value={reason} onChange={(e) => setReason(e.target.value)} />
            <button className="btn btn-danger btn-sm" disabled={busy || reason.trim().length < 3} onClick={() => act(() => rpc('cancel_order', { p_sale: s.id, p_reason: reason }), 'Order cancelled')}>Cancel it</button></span>
        )}
      </>
    )} />
  );
}

function Deliveries({ list, loading, onOpen }: { list: any[]; loading: boolean; onOpen: (saleId: string) => void }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const [tab, setTab] = useState<'open' | 'done'>('open');
  const rows = list.filter((d) => (tab === 'open' ? ['pending', 'dispatched'].includes(d.status) : !['pending', 'dispatched'].includes(d.status)));
  const vans = (inv?.locations || []).filter((l: any) => l.kind === 'van');
  const manager = !!inv && (inv.me.role === 'owner' || inv.me.role === 'manager' || can(inv, 'approve_adjustments'));
  const [receiving, setReceiving] = useState<any | null>(null);
  async function update(d: any, patch: Record<string, unknown>, ok: string) {
    try { await rpc('save_delivery', { p_org: orgId, p_delivery: { id: d.id, sale_id: d.sale_id, ...patch } }); toast(ok); await qc.invalidateQueries({ queryKey: ['deliveries'] }); return true; }
    catch (e) { toast((e as Error).message, 'err'); return false; }
  }
  function printNote(d: any) {
    const w = window.open('', '_blank', 'width=720,height=900');
    if (!w) return;
    const esc = (t: string) => String(t ?? '').replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]!));
    w.document.write(`<!doctype html><html><head><meta charset="utf-8"><title>${esc(d.number)}</title><style>body{font:13px/1.5 -apple-system,Helvetica,Arial,sans-serif;margin:32px;color:#111827}
      h1{font-size:20px;margin:0} table{width:100%;border-collapse:collapse;margin-top:16px} td,th{border-bottom:1px solid #E5E7EB;padding:8px;text-align:left} .sig{margin-top:48px;display:flex;gap:48px} .sig div{flex:1;border-top:1px solid #111827;padding-top:6px}</style></head><body>
      <div style="color:#6B7280">${esc(inv?.org.name || '')}</div><h1>Delivery note ${esc(d.number)}</h1>
      <p>For ${esc(d.customer_name || '')} · ${esc(d.sale_number || '')}<br>${esc(d.address || '')}${d.contact_phone ? ' · ' + esc(d.contact_phone) : ''}</p>
      <table><tr><th>Item</th><th>Quantity</th></tr>${(d.lines || []).map((l: any) => `<tr><td>${esc(l.description)}</td><td>${Number(l.qty)} ${esc(l.unit_label)}</td></tr>`).join('')}</table>
      ${Number(d.balance) > 0 ? `<p><b>To collect on delivery: NGN ${Number(d.balance).toLocaleString('en-NG', { minimumFractionDigits: 2 })}</b></p>` : ''}
      <div class="sig"><div>Delivered by</div><div>Received by (name and signature)</div><div>Date</div></div><script>window.onload=()=>window.print()<\/script></body></html>`);
    w.document.close();
  }
  return (
    <div className="stack" style={{ gap: 12 }}>
      <Pills value={tab} onChange={setTab} options={[{ id: 'open', label: 'To deliver' }, { id: 'done', label: 'Delivered or failed' }]} />
      <div className="card" style={{ overflow: 'hidden' }}>
        {loading ? <SkeletonRows n={5} /> : !rows.length ? <div style={{ padding: 20 }}><Empty>Nothing here. Confirmed orders marked for delivery get a delivery note.</Empty></div> : rows.map((d) => (
          <div key={d.id} className="tr" style={{ gridTemplateColumns: 'minmax(0,1.4fr) 140px 160px auto', gap: 12 }}>
            <span style={{ minWidth: 0 }}><b>{d.number}</b> <button className="btn btn-ghost btn-xs" onClick={() => onOpen(d.sale_id)}>{d.sale_number || 'Order'}</button>
              <span className="faint" style={{ display: 'block', fontSize: 12 }}>{d.customer_name} · {d.address || 'no address'}{d.scheduled_for ? ` · for ${fmtDay(d.scheduled_for)}` : ''}</span>
              <span className="faint" style={{ display: 'block', fontSize: 12 }}>{(d.lines || []).map((l: any) => `${Number(l.qty)} ${l.unit_label} ${l.description}`).join(', ')}</span></span>
            <span><StatusChip s={d.status} />{Number(d.balance) > 0 && <span className="faint" style={{ display: 'block', fontSize: 11 }}>collect {N2(d.balance)}</span>}
              {d.held && <span className="chip t-amber" style={{ display: 'inline-block', marginTop: 3 }} title="The goods leave once the payment is confirmed">waiting for payment</span>}
              {d.collect_on_delivery && <span className="faint" style={{ display: 'block', fontSize: 11 }}>pay on delivery{d.collect_agreed_by_name ? `, agreed by ${d.collect_agreed_by_name}` : ''}</span>}</span>
            <select className="input input-sm" value={d.vehicle_location_id || ''} onChange={(e) => update(d, { vehicle_location_id: e.target.value || null }, 'Van assigned')} disabled={!vans.length} aria-label="Van">
              <option value="">{vans.length ? 'Which van?' : 'No vans set up'}</option>{vans.map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}
            </select>
            <span className="row wrap" style={{ gap: 4 }}>
              <button className="btn btn-ghost btn-xs" onClick={() => printNote(d)}><Icon name="printer" size={13} />Note</button>
              {d.status === 'pending' && <button className="btn btn-secondary btn-xs" disabled={d.held} title={d.held ? 'Waiting for the payment to be confirmed' : undefined} onClick={() => update(d, { status: 'dispatched' }, 'On its way')}>Dispatched</button>}
              {d.held && manager && <button className="btn btn-ghost btn-xs" onClick={() => { if (window.confirm(`Let ${d.number} leave unpaid, with ${N2(d.balance)} collected on delivery?`)) void update(d, { collect_on_delivery: true }, 'Payment on delivery agreed'); }}>Agree payment on delivery</button>}
              {['pending', 'dispatched'].includes(d.status) && <button className="btn btn-primary btn-xs" onClick={() => setReceiving(d)}>Delivered</button>}
              {['pending', 'dispatched'].includes(d.status) && <button className="btn btn-ghost btn-xs" onClick={() => update(d, { status: 'failed' }, 'Marked as not delivered')}>Failed</button>}
            </span>
          </div>
        ))}
      </div>
      {receiving && <ReceivedModal d={receiving} onClose={() => setReceiving(null)}
        onSave={async (who, note) => { if (await update(receiving, { status: 'delivered', received_by: who, ...(note ? { notes: note } : {}) }, `${receiving.number} delivered`)) setReceiving(null); }} />}
      {rows.some((d) => d.held) && <Alert kind="amber" icon="clock">Goods leave once the payment is confirmed. Take it by Pay by transfer, which confirms in seconds, or confirm the transfer against the bank in Sales. {manager ? 'You can agree payment on delivery for a customer you trust.' : 'A manager can agree payment on delivery.'}</Alert>}
      {!vans.length && <Alert kind="grey" icon="truck">Selling from vans? Add each van as a branch of kind "van" under Locations &amp; staff, transfer stock to it, and open the till on the van to sell from it.</Alert>}
    </div>
  );
}

interface OLine { key: string; item: Item; qty: string; unit: 'selling' | 'purchase' }
function OrderEditor({ onClose, onSaved }: { onClose: () => void; onSaved: (id: string) => void }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const [customer, setCustomer] = useState<Customer | null>(null);
  const [lines, setLines] = useState<OLine[]>([]);
  const [f, setF] = useState({ delivery_method: 'delivery', delivery_address: '', delivery_fee: '', notes: '', location_id: inv?.me.location_id || inv?.locations[0]?.id || '' });
  const [busy, setBusy] = useState(false);
  if (!inv) return null;
  async function save() {
    if (!customer) { toast('Choose the customer.', 'err'); return; }
    setBusy(true);
    try {
      const s = await rpc<Sale>('save_order', { p_org: orgId, p_doc: { customer_id: customer.id, location_id: f.location_id || null, delivery_method: f.delivery_method,
        delivery_address: f.delivery_method === 'delivery' ? (f.delivery_address || customer.address) : null, delivery_fee: money(f.delivery_fee) || 0, notes: f.notes || null,
        lines: lines.map((l) => ({ item_id: l.item.id, qty: Number(l.qty), unit: l.unit })) } });
      toast(`${s.number} taken`); await qc.invalidateQueries({ queryKey: ['sales'] }); onSaved(s.id);
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  return (
    <Drawer onClose={onClose} width={640}>
      <div className="drawer-hd"><div className="grow"><div className="drawer-title">Take an order</div><div className="muted" style={{ fontSize: 13 }}>Prices follow the customer's price list. Nothing posts until the order is confirmed.</div></div>
        <button className="x-btn" onClick={onClose} aria-label="Close"><Icon name="x" size={18} /></button></div>
      <div className="drawer-body stack" style={{ gap: 12 }}>
        <Field label="Customer" req><CustomerPicker value={customer} onChange={setCustomer} walkIn={false} placeholder="Choose the customer" /></Field>
        <Field label="Supplied from"><select className="input" value={f.location_id} onChange={(e) => setF({ ...f, location_id: e.target.value })}>{inv.locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</select></Field>
        <ItemPicker items={inv.items} onPick={(it) => setLines((ls) => [...ls, { key: crypto.randomUUID(), item: it, qty: '1', unit: it.pack_size > 1 ? 'purchase' : 'selling' }])} />
        {lines.map((l) => (
          <div key={l.key} className="row" style={{ gap: 8 }}>
            <span className="grow ellipsis">{l.item.name}</span>
            <input className="input input-sm num" style={{ width: 80 }} inputMode="decimal" value={l.qty} onChange={(e) => setLines((ls) => ls.map((x) => (x.key === l.key ? { ...x, qty: e.target.value } : x)))} aria-label="Quantity" />
            {l.item.pack_size > 1 ? <select className="input input-sm" style={{ width: 'auto' }} value={l.unit} onChange={(e) => setLines((ls) => ls.map((x) => (x.key === l.key ? { ...x, unit: e.target.value as any } : x)))}>
              <option value="selling">{l.item.selling_unit}</option><option value="purchase">{l.item.purchase_unit} of {l.item.pack_size}</option></select> : <span className="faint" style={{ fontSize: 12 }}>{l.item.selling_unit}</span>}
            <button className="btn btn-ghost btn-xs" onClick={() => setLines((ls) => ls.filter((x) => x.key !== l.key))} aria-label="Remove"><Icon name="trash" size={13} /></button>
          </div>
        ))}
        <Field label="Delivery"><select className="input" value={f.delivery_method} onChange={(e) => setF({ ...f, delivery_method: e.target.value })}><option value="delivery">We deliver</option><option value="pickup">Customer picks up</option></select></Field>
        {f.delivery_method === 'delivery' && <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 160px', gap: 10 }}>
          <Field label="Address"><input className="input" value={f.delivery_address} placeholder={customer?.address || ''} onChange={(e) => setF({ ...f, delivery_address: e.target.value })} /></Field>
          <Field label="Delivery charge"><input className="input" inputMode="decimal" value={f.delivery_fee} onChange={(e) => setF({ ...f, delivery_fee: e.target.value })} placeholder="0.00" /></Field>
        </div>}
        <Field label="Notes"><input className="input" value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} /></Field>
      </div>
      <div className="drawer-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={busy || !lines.length} onClick={save}>Save order</button></div>
    </Drawer>
  );
}

// Who took the goods: the name is kept on the delivery note's record (the database insists on it).
function ReceivedModal({ d, onClose, onSave }: { d: any; onClose: () => void; onSave: (who: string, note: string) => Promise<void> }) {
  const [who, setWho] = useState(d.received_by || '');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const ok = who.trim().length >= 2;
  async function save() { if (!ok || busy) return; setBusy(true); await onSave(who.trim(), note.trim()); setBusy(false); }
  return (
    <Modal onClose={onClose} width={420}>
      <ModalHead title={`Mark ${d.number} delivered`} sub={`${d.customer_name || 'Customer'}${d.address ? ' · ' + d.address : ''}`} onClose={onClose} />
      <form className="modal-body" onSubmit={(e) => { e.preventDefault(); save(); }}>
        <Field label="Received by" req hint="The name of the person who took the goods.">
          <input className="input" autoFocus value={who} onChange={(e) => setWho(e.target.value)} placeholder="e.g. Mrs Adaeze Okafor" maxLength={120} />
        </Field>
        <Field label="Note"><input className="input" value={note} onChange={(e) => setNote(e.target.value)} placeholder="Optional, e.g. left with the gateman" maxLength={300} /></Field>
        {Number(d.balance) > 0 && <Alert kind="amber" icon="dollar">There is {N2(d.balance)} to collect on this delivery. Record the payment on the sale.</Alert>}
        <button type="submit" hidden />
      </form>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" onClick={save} disabled={!ok || busy}>{busy ? 'Saving…' : 'Delivered'}</button></div>
    </Modal>
  );
}
