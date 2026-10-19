import { useEffect, useMemo, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { edge } from '../../lib/api';
import { Drawer, Field, XButton, Alert, Thumb } from '../../components/ui';
import { Icon } from '../../components/Icon';
import { VatInfo } from '../../components/VatInfo';
import { rpc, supabase } from '../../lib/supabase';
import { useInventory, useSession, useToast } from '../../state/session';
import { useAction } from '../../lib/queries';
import { N } from '../../lib/format';
import { sumQty } from '../../lib/domain';
import { ITEM_TYPES, defaultVat, fieldsFor, industryOf, typeSells, type FieldDef, type ItemType } from '../../lib/industries';
import type { Item } from '../../lib/types';
import type { Drafts } from '../../lib/drafts';
import { shrinkImage } from '../../lib/images';
import { vatPct } from '../../lib/vat';

// Kept for screens that still offer the older fixed lists.
export const CATEGORIES = ['Staples', 'Noodles', 'Dairy', 'Beverages', 'Drinks', 'Household', 'Personal care', 'OTC medicine', 'Breakfast', 'Snacks', 'Baby', 'Frozen', 'General'];
export const PURCHASE_UNITS = ['Carton', 'Bag', 'Bale', 'Pack', 'Crate', 'Roll', 'Dozen', 'Sack', 'Tray'];
export const SELLING_UNITS = ['piece', 'pack', 'sachet', 'tin', 'bottle', 'bar', 'tube', 'derica', 'mudu', 'paint bucket', 'kg', 'litre'];
const INFORMAL = ['derica', 'mudu', 'paint bucket'];
const uniq = (xs: (string | null | undefined)[]) => [...new Set(xs.filter(Boolean) as string[])];

export function AttrInput({ f, value, onChange }: { f: FieldDef; value: any; onChange: (v: any) => void }) {
  if (f.type === 'select') {
    const opts = f.options || [];
    const v = value == null ? '' : String(value);
    return (
      <select className="input" value={v} onChange={(e) => onChange(e.target.value)}>
        <option value="">—</option>
        {opts.map((o) => <option key={o}>{o}</option>)}
        {v && !opts.includes(v) && <option>{v}</option>}
      </select>
    );
  }
  if (f.type === 'bool') {
    const v = value === true || /^(true|yes|y|1)$/i.test(String(value ?? '')) ? 'yes' : value === false || /^(false|no|n|0)$/i.test(String(value ?? '')) ? 'no' : '';
    return (
      <select className="input" value={v} onChange={(e) => onChange(e.target.value === '' ? '' : e.target.value === 'yes')}>
        <option value="">—</option><option value="yes">Yes</option><option value="no">No</option>
      </select>
    );
  }
  return (
    <input className="input" type={f.type === 'number' ? 'number' : f.type === 'date' ? 'date' : 'text'} inputMode={f.type === 'number' ? 'decimal' : undefined}
      value={value ?? ''} placeholder={f.placeholder} onChange={(e) => onChange(e.target.value)} />
  );
}

export default function ItemForm({ item, draft, note, onClose, onSaved }: {
  item?: Item | null; draft?: Drafts['product'] | null; note?: string; onClose: () => void; onSaved?: (id: string) => void;
}) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const { run, busy } = useAction();
  const qc = useQueryClient();
  const editing = !!item;
  const hasStock = item ? sumQty(item) !== 0 : false;
  const ind = industryOf(inv?.org.industry);
  const indFields = ind.fields;
  const commonFields = fieldsFor(ind.id).filter((f) => !indFields.some((x) => x.key === f.key));
  // A new item can start from a draft: Martina's, or what the phone read from the product's photos.
  const d = !item ? draft : null;
  const dType = d?.item_type && ITEM_TYPES.some((t) => t.id === d.item_type) ? (d.item_type as ItemType) : null;
  const [f, setF] = useState({
    name: item?.name || d?.name || '', item_type: (item?.item_type as ItemType) || dType || ind.types[0], category: item?.category || d?.category || ind.categories[0],
    brand: item?.brand || d?.brand || '', description: item?.description || d?.description || '', vat_treatment: item ? item.vat_treatment : 'auto',
    purchase_unit: item?.purchase_unit || d?.purchase_unit || ind.purchaseUnits[0], pack_size: item ? String(item.pack_size) : d?.pack_size ? String(d.pack_size) : '',
    selling_unit: item?.selling_unit || d?.unit || ind.sellingUnits[0],
    cost: item?.wac != null ? String(Math.round(Number(item.wac) * 100) / 100) : d?.cost ? String(d.cost) : '', price: item && Number(item.price) > 0 ? String(item.price) : d?.price ? String(d.price) : '',
    track_batches: item ? item.track_batches : ind.batches, barcode: item?.barcode || d?.barcode || '', sku: item?.sku || '', nafdac_no: item?.nafdac_no || d?.nafdac_no || '',
    reorder_floor: item ? String(item.reorder_floor) : '', preferred_vendor_id: item?.preferred_vendor_id || '', alt_vendor_id: item?.alt_vendor_id || '',
    import_priced: item?.import_priced || false,
  });
  const [attrs, setAttrs] = useState<Record<string, any>>({ ...(item?.attributes || {}) });
  // The storefront description lives apart from the staff note, so it is read straight from the item.
  const [shopText, setShopText] = useState('');
  const [shopLoaded, setShopLoaded] = useState('');
  useEffect(() => {
    if (!item?.id) return;
    supabase.from('items').select('shop_description').eq('id', item.id).maybeSingle()
      .then(({ data }) => { const v = (data as any)?.shop_description || ''; setShopText(v); setShopLoaded(v); });
  }, [item?.id]);
  const [err, setErr] = useState<Record<string, string>>({});
  const [more, setMore] = useState(editing || !!(d?.barcode || d?.nafdac_no));
  const taken = f.barcode.trim() ? inv?.items.find((i) => i.barcode === f.barcode.trim() && i.id !== item?.id) : undefined;
  const set = (k: keyof typeof f, v: any) => { setF({ ...f, [k]: v }); setErr({ ...err, [k]: '' }); };
  const sells = typeSells(f.item_type);
  const cost = parseFloat(f.cost); const price = parseFloat(f.price); const pack = Number(f.pack_size);
  const priceWarn = sells && f.cost !== '' && f.price !== '' && price <= cost;
  const conv = f.pack_size && pack >= 1 ? `1 ${f.purchase_unit.toLowerCase()} = ${f.pack_size} ${f.selling_unit}${pack === 1 ? '' : 's'}${f.cost ? ' · ' + N(cost * pack) + ' per ' + f.purchase_unit.toLowerCase() : ''}` : '';
  const categories = useMemo(() => uniq([...ind.categories, ...(inv?.items.map((i) => i.category) || []), f.category]), [ind, inv, f.category]);
  const brands = useMemo(() => uniq(inv?.items.map((i) => i.brand) || []).sort(), [inv]);
  const typeOpts = uniq([...ind.types, f.item_type]).map((id) => ITEM_TYPES.find((t) => t.id === id)!).filter(Boolean);
  const otherTypes = ITEM_TYPES.filter((t) => !typeOpts.some((x) => x.id === t.id));
  const showNafdac = ind.nafdac || !!f.nafdac_no;

  async function save() {
    const e: Record<string, string> = {};
    if (!f.name.trim()) e.name = 'Product name is required';
    if (!(Number.isInteger(pack) && pack >= 1)) e.pack_size = 'Whole number, at least 1';
    if (!editing || !hasStock) { if (!(cost >= 0) || f.cost === '') e.cost = 'Enter a cost per selling unit'; }
    if (sells && !(price > 0)) e.price = 'Enter a selling price';
    if (!sells && f.price !== '' && !(price >= 0)) e.price = 'Zero or more';
    if (f.reorder_floor !== '' && !(Number(f.reorder_floor) >= 0)) e.reorder_floor = 'Zero or more';
    setErr(e);
    if (Object.keys(e).length) return;
    const cleanAttrs: Record<string, any> = {};
    for (const fd of [...indFields, ...commonFields]) {
      const v = attrs[fd.key];
      if (v === '' || v == null) continue;
      cleanAttrs[fd.key] = fd.type === 'number' ? Number(v) : v;
    }
    for (const [k, v] of Object.entries(attrs)) if (!(k in cleanAttrs) && v !== '' && v != null && ![...indFields, ...commonFields].some((x) => x.key === k)) cleanAttrs[k] = v;
    // 'auto' lets the tax agent (Numens) decide after saving; until it answers, the industry default applies.
    const auto = f.vat_treatment === 'auto';
    const chosenVat = auto ? defaultVat(ind.id) : f.vat_treatment;
    const vatChanged = !auto && (!editing || f.vat_treatment !== item?.vat_treatment);
    const payload: any = {
      ...f, vat_treatment: chosenVat, id: item?.id, pack_size: pack, price: sells ? price : (price > 0 ? price : 0), cost: !editing || !hasStock ? cost : null,
      informal_unit: INFORMAL.includes(f.selling_unit), reorder_floor: f.reorder_floor === '' ? 0 : Number(f.reorder_floor),
      preferred_vendor_id: f.preferred_vendor_id || null, alt_vendor_id: f.alt_vendor_id || null, needs_review: false,
      attributes: cleanAttrs,
    };
    const id = await run(() => rpc<string>('upsert_item', { p_org: orgId, p_item: payload }), {
      ok: editing ? (item?.item_type && item.item_type !== f.item_type && hasStock ? 'Item updated · stock value moved to its new account' : 'Item updated')
        : f.barcode ? 'Item created · barcode linked' : 'Item created · QR label ready to print',
    });
    if (!id) return;
    // The front photo from the phone becomes the item's picture.
    if (d?.photo) {
      try {
        const pic = await shrinkImage(new File([d.photo], 'front.jpg', { type: d.photo_type || d.photo.type || 'image/jpeg' }));
        const path = `${orgId}/${id}-${Date.now()}.${pic.ext}`;
        const { error } = await supabase.storage.from('item-photos').upload(path, pic.blob, { contentType: pic.type, cacheControl: '31536000' });
        if (error) throw new Error(error.message);
        await rpc('set_item_photo', { p_item: id, p_path: path });
        qc.invalidateQueries({ queryKey: ['inv'] });
      } catch (e) { toast(`Saved, but the photo did not upload: ${(e as Error).message}`, 'err'); }
    }
    if (sells && shopText.trim() !== shopLoaded.trim()) {
      await rpc('set_item_shop_details', { p_item: id, p: { shop_description: shopText } }).catch((e) => toast((e as Error).message, 'err'));
      qc.invalidateQueries({ queryKey: ['shop'] });
    }
    if (vatChanged) {
      // A person's choice is final for the agent, so it is recorded as a manual decision.
      await rpc('set_item_vat', { p_item: id, p_treatment: f.vat_treatment, p_reason: editing ? 'Changed on the item' : 'Set when the item was added' }).catch(() => undefined);
    } else if (auto) {
      edge('ai', { action: 'vat_classify_item', item_id: id }).then(() => qc.invalidateQueries({ queryKey: ['inv'] })).catch(() => undefined);
    }
    onSaved?.(id); onClose();
  }

  const fieldGrid = (fields: FieldDef[]) => (
    <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
      {fields.map((fd) => (
        <Field key={fd.key} label={fd.label} hint={fd.hint}>
          <AttrInput f={fd} value={attrs[fd.key]} onChange={(v) => setAttrs({ ...attrs, [fd.key]: v })} />
        </Field>
      ))}
    </div>
  );

  return (
    <Drawer onClose={onClose} width={560}>
      <div className="drawer-hd" style={{ alignItems: 'center' }}><div className="drawer-title grow">{editing ? 'Edit item' : 'New item'}</div><XButton onClick={onClose} /></div>
      <div className="drawer-body" style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
        {d && <Alert kind="blue" icon="sparkles">{note || 'Martina prepared this item. Check it, add anything missing, then save it.'}</Alert>}
        <Field label="Product name" req error={err.name}>
          <input className={'input' + (err.name ? ' err' : '')} value={f.name} onChange={(e) => set('name', e.target.value)} placeholder={String(ind.example[0]?.name || 'e.g. Golden Penny Spaghetti 500g')} autoFocus={!editing} />
        </Field>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <Field label="Kind of item" hint={ITEM_TYPES.find((t) => t.id === f.item_type)?.hint}>
            <select className="input" value={f.item_type} onChange={(e) => set('item_type', e.target.value)}>
              {typeOpts.map((t) => <option key={t.id} value={t.id}>{t.label}</option>)}
              {otherTypes.length > 0 && <optgroup label="Other kinds">{otherTypes.map((t) => <option key={t.id} value={t.id}>{t.label}</option>)}</optgroup>}
            </select>
          </Field>
          <Field label="Category">
            <input className="input" list="item-categories" value={f.category} onChange={(e) => set('category', e.target.value)} />
            <datalist id="item-categories">{categories.map((c) => <option key={c} value={c} />)}</datalist>
          </Field>
          <Field label="Brand">
            <input className="input" list="item-brands" value={f.brand} onChange={(e) => set('brand', e.target.value)} placeholder="Optional" />
            <datalist id="item-brands">{brands.map((b) => <option key={b} value={b} />)}</datalist>
          </Field>
          <Field label={<>VAT treatment{f.vat_treatment !== 'auto' && <VatInfo side="sale" treatment={f.vat_treatment} name={f.name} item={editing && item?.vat_treatment === f.vat_treatment ? item : null} vatRegistered={inv?.org.vat_registered} />}</>} hint={f.vat_treatment === 'auto' ? 'Numens reads the item and sets its VAT under the NTA 2025. You can change it later.' : undefined}>
            <select className="input" value={f.vat_treatment} onChange={(e) => set('vat_treatment', e.target.value)}>
              {!editing && <option value="auto">Let Numens decide</option>}
              <option value="standard">Standard · {vatPct()}</option><option value="zero">Zero-rated (basic food, medicine, farm inputs)</option><option value="exempt">Exempt (baby products, petroleum products…)</option>
            </select>
          </Field>
        </div>
        {editing && hasStock && item?.item_type && item.item_type !== f.item_type && (
          <Alert kind="blue" icon="info">Changing the kind of item moves its stock value to the matching inventory account ({ITEM_TYPES.find((t) => t.id === f.item_type)?.account}) with a reclass journal.</Alert>
        )}
        <div style={{ border: '1px solid #E6E6E6', borderRadius: 14, padding: 14, display: 'flex', flexDirection: 'column', gap: 12, background: '#FAFAFA' }}>
          <div className="label" style={{ fontFamily: 'inherit', letterSpacing: '.06em' }}>Units · how you buy vs how you {sells ? 'sell' : 'use it'}</div>
          <div className="m-2" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10 }}>
            <div><div style={{ fontSize: 12, color: '#4B5563', marginBottom: 6 }}>Buy by the</div>
              <input className="input" list="item-pu" value={f.purchase_unit} onChange={(e) => set('purchase_unit', e.target.value)} disabled={editing && hasStock} />
              <datalist id="item-pu">{uniq([...ind.purchaseUnits, ...PURCHASE_UNITS]).map((u) => <option key={u} value={u} />)}</datalist></div>
            <div><div style={{ fontSize: 12, color: '#4B5563', marginBottom: 6 }}>Contains <span className="req">*</span></div>
              <input className={'input' + (err.pack_size ? ' err' : '')} type="number" inputMode="numeric" value={f.pack_size} onChange={(e) => set('pack_size', e.target.value)} placeholder="e.g. 40" disabled={editing && hasStock} title={editing && hasStock ? 'Pack size is fixed once stock exists' : undefined} /></div>
            <div><div style={{ fontSize: 12, color: '#4B5563', marginBottom: 6 }}>{sells ? 'Sell' : 'Count'} by the</div>
              <input className="input" list="item-su" value={f.selling_unit} onChange={(e) => set('selling_unit', e.target.value)} disabled={editing && hasStock} />
              <datalist id="item-su">{uniq([...ind.sellingUnits, ...SELLING_UNITS]).map((u) => <option key={u} value={u} />)}</datalist></div>
          </div>
          {err.pack_size && <div className="err-text" style={{ marginTop: -4 }}>{err.pack_size}</div>}
          {conv && <div style={{ fontSize: 13, color: '#1E3A8A', background: '#F0F7FF', borderRadius: 10, padding: '8px 12px' }}>{conv}</div>}
          {INFORMAL.includes(f.selling_unit) && <div className="hint">Informal measure. You set this conversion yourself and can change it as your scoop changes.</div>}
        </div>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <Field label={`Cost per ${f.selling_unit || 'unit'}`} req={!editing || !hasStock} error={err.cost} hint={editing && hasStock ? 'Set by receipts (weighted average). Post a receipt to change it.' : undefined}>
            <input className={'input' + (err.cost ? ' err' : '')} type="number" inputMode="decimal" value={f.cost} onChange={(e) => set('cost', e.target.value)} placeholder="₦" disabled={editing && hasStock} />
          </Field>
          <Field label={sells ? 'Selling price' : 'Selling price (optional)'} req={sells} error={err.price} hint={sells ? undefined : 'Leave blank if you never sell it.'}>
            <input className={'input' + (err.price ? ' err' : '')} type="number" inputMode="decimal" value={f.price} onChange={(e) => set('price', e.target.value)} placeholder="₦" />
          </Field>
        </div>
        {priceWarn && <Alert kind="amber" icon="alert">Price is at or below cost, so every sale loses money. You can still save it.</Alert>}
        <label className="check"><input type="checkbox" checked={f.track_batches} onChange={(e) => set('track_batches', e.target.checked)} />Track batches and expiry dates{ind.nafdac ? ' (NAFDAC-regulated or perishable)' : ''}</label>

        {sells && (
          <div style={{ border: '1px solid #E6E6E6', borderRadius: 14, padding: 14, display: 'flex', flexDirection: 'column', gap: 10 }}>
            <div className="row" style={{ gap: 10, alignItems: 'flex-start' }}>
              {item && <Thumb name={item.name} path={item.photo_path} size={48} radius={10} />}
              <div className="grow">
                <div className="label" style={{ fontFamily: 'inherit', letterSpacing: '.06em' }}>Online shop</div>
                <div className="hint" style={{ marginTop: 2 }}>{item ? (item.photo_path ? 'The photo shows in the shop. Change it from the item\'s picture.' : 'Add a photo by tapping the picture on the item once it is saved.') : 'Add a photo from the item once it is saved.'}</div>
              </div>
            </div>
            <Field label="Description for customers" hint={`What customers read when they open the product: what it is, size or weight, what is in the pack, how to use it. Line breaks are kept. ${shopText.length.toLocaleString('en-NG')} of 4,000 characters.`}>
              <textarea className="input" value={shopText} maxLength={4000} onChange={(e) => setShopText(e.target.value)} style={{ minHeight: 120 }}
                placeholder={'Chocolate malt drink with ACTIV-GO, 400g tin.\nMakes about 20 cups. Mix 3 heaped spoons with hot or cold milk.'} />
            </Field>
          </div>
        )}

        {indFields.length > 0 && (
          <div style={{ border: '1px solid #E6E6E6', borderRadius: 14, padding: 14, display: 'flex', flexDirection: 'column', gap: 12 }}>
            <div className="label" style={{ fontFamily: 'inherit', letterSpacing: '.06em' }}>{ind.label} details</div>
            {fieldGrid(indFields)}
          </div>
        )}

        <button className="btn-ghost" style={{ color: '#0072F5', fontSize: 13, display: 'flex', alignItems: 'center', gap: 6, cursor: 'pointer', padding: 0, alignSelf: 'flex-start' }} onClick={() => setMore(!more)}>
          <Icon name="chevD" size={14} color="#0072F5" style={{ transform: more ? 'rotate(180deg)' : undefined }} />Barcode, codes, reorder floor, vendors and more
        </button>
        {more && (
          <>
            <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
              <Field label="Barcode (EAN / UPC)" error={taken ? `${taken.name} already uses this barcode` : undefined}><input className="input" value={f.barcode} onChange={(e) => set('barcode', e.target.value)} placeholder="Leave blank to use a QR label" /></Field>
              <Field label="Catalogue ID / SKU"><input className="input" value={f.sku} onChange={(e) => set('sku', e.target.value)} /></Field>
              <Field label={`Reorder floor (${f.selling_unit}s)`} error={err.reorder_floor}><input className="input" type="number" value={f.reorder_floor} onChange={(e) => set('reorder_floor', e.target.value)} placeholder="0" /></Field>
              {showNafdac && <Field label="NAFDAC number"><input className="input" value={f.nafdac_no} onChange={(e) => set('nafdac_no', e.target.value)} placeholder="e.g. A4-0271" /></Field>}
              <Field label="Preferred vendor"><select className="input" value={f.preferred_vendor_id} onChange={(e) => set('preferred_vendor_id', e.target.value)}><option value="">None yet</option>{inv?.vendors.map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}</select></Field>
              <Field label="Alternative vendor"><select className="input" value={f.alt_vendor_id} onChange={(e) => set('alt_vendor_id', e.target.value)}><option value="">None</option>{inv?.vendors.map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}</select></Field>
            </div>
            {fieldGrid(commonFields)}
            <Field label="Description"><textarea className="input" value={f.description} onChange={(e) => set('description', e.target.value)} placeholder="Anything that helps staff pick the right item" /></Field>
            <label className="check"><input type="checkbox" checked={f.import_priced} onChange={(e) => set('import_priced', e.target.checked)} />Import-priced (show FX timing advice when reordering)</label>
          </>
        )}
        {!editing && <div className="hint">No barcode? We'll generate a QR label on save. A photo can be added from the item once it exists.</div>}
      </div>
      <div className="drawer-ft">
        <button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" onClick={save} disabled={busy}>{editing ? 'Save changes' : 'Save item'}</button>
      </div>
    </Drawer>
  );
}
