import { useState } from 'react';
import { Drawer, Field, XButton, Alert } from '../../components/ui';
import { Icon } from '../../components/Icon';
import { rpc } from '../../lib/supabase';
import { useInventory, useSession } from '../../state/session';
import { useAction } from '../../lib/queries';
import { N } from '../../lib/format';
import { sumQty } from '../../lib/domain';
import type { Item } from '../../lib/types';

export const CATEGORIES = ['Staples', 'Noodles', 'Dairy', 'Beverages', 'Drinks', 'Household', 'Personal care', 'OTC medicine', 'Breakfast', 'Snacks', 'Baby', 'Frozen', 'General'];
export const PURCHASE_UNITS = ['Carton', 'Bag', 'Bale', 'Pack', 'Crate', 'Roll', 'Dozen', 'Sack', 'Tray'];
export const SELLING_UNITS = ['piece', 'pack', 'sachet', 'tin', 'bottle', 'bar', 'tube', 'derica', 'mudu', 'paint bucket', 'kg', 'litre'];
const INFORMAL = ['derica', 'mudu', 'paint bucket'];

export default function ItemForm({ item, onClose, onSaved }: { item?: Item | null; onClose: () => void; onSaved?: (id: string) => void }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const { run, busy } = useAction();
  const editing = !!item;
  const hasStock = item ? sumQty(item) !== 0 : false;
  const [f, setF] = useState({
    name: item?.name || '', category: item?.category || 'Staples', vat_treatment: item?.vat_treatment || 'standard',
    purchase_unit: item?.purchase_unit || 'Carton', pack_size: item ? String(item.pack_size) : '', selling_unit: item?.selling_unit || 'piece',
    cost: item?.wac != null ? String(Math.round(Number(item.wac) * 100) / 100) : '', price: item ? String(item.price) : '',
    track_batches: item?.track_batches || false, barcode: item?.barcode || '', sku: item?.sku || '', nafdac_no: item?.nafdac_no || '',
    reorder_floor: item ? String(item.reorder_floor) : '', preferred_vendor_id: item?.preferred_vendor_id || '', alt_vendor_id: item?.alt_vendor_id || '',
    import_priced: item?.import_priced || false,
  });
  const [err, setErr] = useState<Record<string, string>>({});
  const [more, setMore] = useState(editing);
  const set = (k: keyof typeof f, v: any) => { setF({ ...f, [k]: v }); setErr({ ...err, [k]: '' }); };
  const cost = parseFloat(f.cost); const price = parseFloat(f.price); const pack = Number(f.pack_size);
  const priceWarn = f.cost !== '' && f.price !== '' && price <= cost;
  const conv = f.pack_size && pack >= 1 ? `1 ${f.purchase_unit.toLowerCase()} = ${f.pack_size} ${f.selling_unit}${pack === 1 ? '' : 's'}${f.cost ? ' · ' + N(cost * pack) + ' per ' + f.purchase_unit.toLowerCase() : ''}` : '';

  async function save() {
    const e: Record<string, string> = {};
    if (!f.name.trim()) e.name = 'Product name is required';
    if (!(Number.isInteger(pack) && pack >= 1)) e.pack_size = 'Whole number, at least 1';
    if (!editing || !hasStock) { if (!(cost >= 0) || f.cost === '') e.cost = 'Enter a cost per selling unit'; }
    if (!(price > 0)) e.price = 'Enter a selling price';
    if (f.reorder_floor !== '' && !(Number(f.reorder_floor) >= 0)) e.reorder_floor = 'Zero or more';
    setErr(e);
    if (Object.keys(e).length) return;
    const payload: any = {
      ...f, id: item?.id, pack_size: pack, price, cost: !editing || !hasStock ? cost : null,
      informal_unit: INFORMAL.includes(f.selling_unit), reorder_floor: f.reorder_floor === '' ? 0 : Number(f.reorder_floor),
      preferred_vendor_id: f.preferred_vendor_id || null, alt_vendor_id: f.alt_vendor_id || null, needs_review: false,
    };
    const id = await run(() => rpc<string>('upsert_item', { p_org: orgId, p_item: payload }), {
      ok: editing ? 'Item updated' : f.barcode ? 'Item created · barcode linked' : 'Item created · QR label ready to print',
    });
    if (id) { onSaved?.(id); onClose(); }
  }

  return (
    <Drawer onClose={onClose} width={520}>
      <div className="drawer-hd" style={{ alignItems: 'center' }}><div className="drawer-title grow">{editing ? 'Edit item' : 'New item'}</div><XButton onClick={onClose} /></div>
      <div className="drawer-body" style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
        <Field label="Product name" req error={err.name}>
          <input className={'input' + (err.name ? ' err' : '')} value={f.name} onChange={(e) => set('name', e.target.value)} placeholder="e.g. Golden Penny Spaghetti 500g" autoFocus={!editing} />
        </Field>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <Field label="Category">
            <select className="input" value={f.category} onChange={(e) => set('category', e.target.value)}>
              {[...new Set([...CATEGORIES, ...(inv?.items.map((i) => i.category) || [])])].map((c) => <option key={c}>{c}</option>)}
            </select>
          </Field>
          <Field label="VAT treatment">
            <select className="input" value={f.vat_treatment} onChange={(e) => set('vat_treatment', e.target.value)}>
              <option value="standard">Standard · 7.5%</option><option value="zero">Zero-rated (basic food)</option><option value="exempt">Exempt (medicine)</option>
            </select>
          </Field>
        </div>
        <div style={{ border: '1px solid #E6E6E6', borderRadius: 14, padding: 14, display: 'flex', flexDirection: 'column', gap: 12, background: '#FAFAFA' }}>
          <div className="label" style={{ fontFamily: 'inherit', letterSpacing: '.06em' }}>Units · how you buy vs how you sell</div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10 }}>
            <div><div style={{ fontSize: 12, color: '#4B5563', marginBottom: 6 }}>Buy by the</div>
              <select className="input" value={f.purchase_unit} onChange={(e) => set('purchase_unit', e.target.value)}>{PURCHASE_UNITS.map((u) => <option key={u}>{u}</option>)}</select></div>
            <div><div style={{ fontSize: 12, color: '#4B5563', marginBottom: 6 }}>Contains <span className="req">*</span></div>
              <input className={'input' + (err.pack_size ? ' err' : '')} type="number" inputMode="numeric" value={f.pack_size} onChange={(e) => set('pack_size', e.target.value)} placeholder="40" disabled={editing && hasStock} title={editing && hasStock ? 'Pack size is fixed once stock exists' : undefined} /></div>
            <div><div style={{ fontSize: 12, color: '#4B5563', marginBottom: 6 }}>Sell by the</div>
              <select className="input" value={f.selling_unit} onChange={(e) => set('selling_unit', e.target.value)} disabled={editing && hasStock}>{[...new Set([...SELLING_UNITS, f.selling_unit])].map((u) => <option key={u}>{u}</option>)}</select></div>
          </div>
          {err.pack_size && <div className="err-text" style={{ marginTop: -4 }}>{err.pack_size}</div>}
          {conv && <div style={{ fontSize: 13, color: '#1E3A8A', background: '#F0F7FF', borderRadius: 10, padding: '8px 12px' }}>{conv}</div>}
          {INFORMAL.includes(f.selling_unit) && <div className="hint">Informal measure. You set this conversion yourself and can change it as your scoop changes.</div>}
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <Field label="Cost per selling unit" req={!editing || !hasStock} error={err.cost} hint={editing && hasStock ? 'Set by receipts (weighted average). Post a receipt to change it.' : undefined}>
            <input className={'input' + (err.cost ? ' err' : '')} type="number" inputMode="decimal" value={f.cost} onChange={(e) => set('cost', e.target.value)} placeholder="₦" disabled={editing && hasStock} />
          </Field>
          <Field label="Selling price" req error={err.price}>
            <input className={'input' + (err.price ? ' err' : '')} type="number" inputMode="decimal" value={f.price} onChange={(e) => set('price', e.target.value)} placeholder="₦" />
          </Field>
        </div>
        {priceWarn && <Alert kind="amber" icon="alert">Price is at or below cost — you would lose money on every sale. You can still save it.</Alert>}
        <label className="check"><input type="checkbox" checked={f.track_batches} onChange={(e) => set('track_batches', e.target.checked)} />Track batches and expiry dates (NAFDAC-regulated or perishable)</label>
        <button className="btn-ghost" style={{ color: '#0072F5', fontSize: 13, display: 'flex', alignItems: 'center', gap: 6, cursor: 'pointer', padding: 0, alignSelf: 'flex-start' }} onClick={() => setMore(!more)}>
          <Icon name="chevD" size={14} color="#0072F5" style={{ transform: more ? 'rotate(180deg)' : undefined }} />Barcode, reorder floor, vendors and NAFDAC
        </button>
        {more && (
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
            <Field label="Barcode (EAN)"><input className="input" value={f.barcode} onChange={(e) => set('barcode', e.target.value)} placeholder="Leave blank to use a QR label" /></Field>
            <Field label="Catalogue ID"><input className="input" value={f.sku} onChange={(e) => set('sku', e.target.value)} /></Field>
            <Field label={`Reorder floor (${f.selling_unit}s)`} error={err.reorder_floor}><input className="input" type="number" value={f.reorder_floor} onChange={(e) => set('reorder_floor', e.target.value)} placeholder="0" /></Field>
            <Field label="NAFDAC number"><input className="input" value={f.nafdac_no} onChange={(e) => set('nafdac_no', e.target.value)} placeholder="e.g. A4-0271" /></Field>
            <Field label="Preferred vendor"><select className="input" value={f.preferred_vendor_id} onChange={(e) => set('preferred_vendor_id', e.target.value)}><option value="">None yet</option>{inv?.vendors.map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}</select></Field>
            <Field label="Alternative vendor"><select className="input" value={f.alt_vendor_id} onChange={(e) => set('alt_vendor_id', e.target.value)}><option value="">None</option>{inv?.vendors.map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}</select></Field>
            <label className="check" style={{ gridColumn: '1 / -1' }}><input type="checkbox" checked={f.import_priced} onChange={(e) => set('import_priced', e.target.checked)} />Import-priced (show FX timing advice when reordering)</label>
          </div>
        )}
        {!editing && <div className="hint">No barcode? We'll generate a QR label on save. Photo, reorder floor and preferred vendor can be added later.</div>}
      </div>
      <div className="drawer-ft">
        <button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" onClick={save} disabled={busy}>{editing ? 'Save changes' : 'Save item'}</button>
      </div>
    </Drawer>
  );
}
