// Price lists for distributors and wholesale buyers: a percentage off retail, a markup on cost, or fixed prices per item
// with quantity breaks (10 cartons at one price, 50 at a lower one). A customer's list applies at the till and on invoices.
import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { can, useInventory, useSession, useToast } from '../../state/session';
import { rpc } from '../../lib/supabase';
import { money, useCustomers, type PriceList } from '../../lib/api';
import { N2 } from '../../lib/format';
import { Icon } from '../../components/Icon';
import { ItemPicker } from '../../components/ItemPicker';
import { Alert, Drawer, Empty, Field, SkeletonRows } from '../../components/ui';

const RULE: Record<PriceList['rule'], string> = { fixed: 'Fixed prices per item', discount_on_retail: 'Percentage off retail', markup_on_cost: 'Markup on cost' };

export default function PriceLists() {
  const { data: inv } = useInventory();
  const data = useCustomers();
  const [open, setOpen] = useState<PriceList | 'new' | null>(null);
  if (!inv) return null;
  const lists = data.data?.price_lists || [];
  const customers = data.data?.customers || [];
  return (
    <div className="container" style={{ maxWidth: 1000 }}>
      <div className="row wrap" style={{ justifyContent: 'space-between' }}>
        <div className="muted" style={{ fontSize: 14, maxWidth: 620 }}>Give distributors and bulk buyers their own prices. Put the list on the customer and the till and invoices charge it; anyone can still sell at retail.</div>
        {can(inv, 'edit_prices') && <button className="btn btn-primary btn-sm" onClick={() => setOpen('new')}><Icon name="plus" size={14} color="#fff" />Price list</button>}
      </div>
      <div className="card" style={{ overflow: 'hidden' }}>
        {data.isLoading ? <SkeletonRows n={4} /> : !lists.length ? <div style={{ padding: 20 }}><Empty>No price lists yet. Everyone pays retail.</Empty></div> : lists.map((l) => (
          <div key={l.id} className="tr click" onClick={() => setOpen(l)} style={{ gridTemplateColumns: 'minmax(0,1.4fr) 200px 140px 120px' }}>
            <span><b>{l.name}</b><span className="faint" style={{ display: 'block', fontSize: 12, textTransform: 'capitalize' }}>{l.kind}{l.active === false ? ' · switched off' : ''}</span></span>
            <span className="muted">{RULE[l.rule]}{l.rule !== 'fixed' ? ` · ${Number(l.pct)}%` : ''}</span>
            <span className="muted">{l.items.length} item price{l.items.length === 1 ? '' : 's'}</span>
            <span className="muted">{customers.filter((c) => c.price_list_id === l.id).length} customers</span>
          </div>
        ))}
      </div>
      {open && <ListEditor list={open === 'new' ? null : open} onClose={() => setOpen(null)} />}
    </div>
  );
}

function ListEditor({ list, onClose }: { list: PriceList | null; onClose: () => void }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const [f, setF] = useState({ name: list?.name || '', kind: list?.kind || 'wholesale', rule: list?.rule || 'discount_on_retail', pct: String(list?.pct ?? '5'), active: list?.active !== false });
  const [items, setItems] = useState(list?.items.map((i) => ({ ...i, price: String(i.price), min_qty: String(i.min_qty), key: crypto.randomUUID() })) || []);
  const [busy, setBusy] = useState(false);
  if (!inv) return null;
  const editable = can(inv, 'edit_prices');
  async function save() {
    setBusy(true);
    try {
      await rpc('save_price_list', { p_org: orgId, p_list: { id: list?.id || null, name: f.name, kind: f.kind, rule: f.rule, pct: Number(f.pct) || 0, active: f.active,
        items: items.map((i) => ({ item_id: i.item_id, min_qty: Number(i.min_qty) || 1, price: money(i.price) })) } });
      toast('Price list saved'); await Promise.all(['customers', 'till'].map((k) => qc.invalidateQueries({ queryKey: [k] }))); onClose();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  const itemOf = (id: string) => inv.items.find((i) => i.id === id);
  return (
    <Drawer onClose={onClose} width={720}>
      <div className="drawer-hd"><div className="grow"><div className="drawer-title">{list ? list.name : 'New price list'}</div></div><button className="x-btn" onClick={onClose} aria-label="Close"><Icon name="x" size={18} /></button></div>
      <div className="drawer-body stack" style={{ gap: 14 }}>
        {!editable && <Alert kind="yellow" icon="shield">Only someone who edits prices can change price lists.</Alert>}
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1.4fr 1fr', gap: 12 }}>
          <Field label="Name"><input className="input" disabled={!editable} value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} placeholder="Distributors" /></Field>
          <Field label="For"><select className="input" disabled={!editable} value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value as any })}><option value="wholesale">Wholesale buyers</option><option value="distributor">Distributors</option><option value="staff">Staff</option><option value="custom">Other</option></select></Field>
        </div>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1.4fr 1fr', gap: 12 }}>
          <Field label="Items not listed below are priced by"><select className="input" disabled={!editable} value={f.rule} onChange={(e) => setF({ ...f, rule: e.target.value as any })}>
            <option value="discount_on_retail">A percentage off the retail price</option><option value="markup_on_cost">A markup on what the item cost</option><option value="fixed">Retail price (only the items below differ)</option></select></Field>
          {f.rule !== 'fixed' && <Field label={f.rule === 'markup_on_cost' ? 'Markup %' : 'Discount %'}><input className="input" disabled={!editable} inputMode="decimal" value={f.pct} onChange={(e) => setF({ ...f, pct: e.target.value })} /></Field>}
        </div>
        <label className="check"><input type="checkbox" disabled={!editable} checked={f.active} onChange={(e) => setF({ ...f, active: e.target.checked })} />In use</label>
        <div className="label">Item prices and quantity breaks</div>
        <div className="card" style={{ overflow: 'visible' }}>
          {items.length > 0 && <div className="tr head shade th" style={{ gridTemplateColumns: 'minmax(0,1.6fr) 110px 130px 110px 30px' }}><span>Item</span><span className="right">From qty</span><span className="right">Price per unit</span><span className="right">Retail</span><span /></div>}
          {items.map((i) => {
            const it = itemOf(i.item_id);
            return (
              <div key={i.key} className="tr" style={{ gridTemplateColumns: 'minmax(0,1.6fr) 110px 130px 110px 30px' }}>
                <span className="ellipsis">{it?.name || 'Item'}<span className="faint" style={{ fontSize: 11 }}> · per {it?.selling_unit}</span></span>
                <input className="input input-sm num" disabled={!editable} inputMode="decimal" value={i.min_qty} onChange={(e) => setItems((xs) => xs.map((x) => (x.key === i.key ? { ...x, min_qty: e.target.value } : x)))} aria-label="From quantity" />
                <input className="input input-sm num" disabled={!editable} inputMode="decimal" value={i.price} onChange={(e) => setItems((xs) => xs.map((x) => (x.key === i.key ? { ...x, price: e.target.value } : x)))} aria-label="Price" />
                <span className="right muted num">{N2(it?.price)}</span>
                {editable && <button className="btn btn-ghost btn-xs" onClick={() => setItems((xs) => xs.filter((x) => x.key !== i.key))} aria-label="Remove"><Icon name="trash" size={13} /></button>}
              </div>
            );
          })}
          {editable && <div style={{ padding: 12 }}><ItemPicker items={inv.items} onPick={(it) => setItems((xs) => [...xs, { item_id: it.id, min_qty: '1', price: String(Number(it.price)), key: crypto.randomUUID() }])} placeholder="Add an item price" /></div>}
        </div>
        <div className="faint" style={{ fontSize: 12 }}>Add the same item again with a higher "from qty" for a quantity break. Prices are per selling unit; a carton is charged its pack size times the unit price.</div>
      </div>
      {editable && <div className="drawer-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={busy || !f.name.trim()} onClick={save}>Save price list</button></div>}
    </Drawer>
  );
}
