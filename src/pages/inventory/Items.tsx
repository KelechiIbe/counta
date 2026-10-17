import { useEffect, useMemo, useRef, useState } from 'react';
import { useLocation, useNavigate, Link } from 'react-router-dom';
import { can, useInventory, useSession, useToast } from '../../state/session';
import { useLoc } from '../../shell/AppShell';
import { buildItems, batchWindow, daysLabel, marginColor, pct, qtyLabel, suAbbr, type ItemView, type Status } from '../../lib/domain';
import { K, N, P, fmtDay, when } from '../../lib/format';
import { useItemMoves, useAction } from '../../lib/queries';
import { moveQty, moveRef, typeLabel, typeTone } from '../../lib/ledger';
import { Icon } from '../../components/Icon';
import { Chip, Drawer, Pills, Stat, Thumb, XButton, Alert, Empty, SkeletonRows } from '../../components/ui';
import ItemForm from './ItemForm';
import ImportPanel from './ImportPanel';
import { ALL_FIELDS, ITEM_TYPES, fieldsFor, formatAttr, industryOf, typeLabel as kindLabel, typeSells } from '../../lib/industries';
import { downloadBlob, itemsXlsx, safeName } from '../../lib/exporters';
import TransferModal from '../../components/TransferModal';
import { ItemAccountCard } from '../../components/ChartOfAccounts';
import { printLabel, qrSvg } from '../../lib/labels';
import { supabase, rpc } from '../../lib/supabase';

const COLS = 'minmax(240px,2fr) 120px minmax(160px,1.2fr) 100px 100px 90px 110px 110px 24px';

export default function Items() {
  const { data: inv } = useInventory();
  const { loc } = useLoc();
  const location = useLocation();
  const [search, setSearch] = useState('');
  const [filter, setFilter] = useState<'all' | Status | 'review'>((location.state as any)?.filter || 'all');
  const [sel, setSel] = useState<string | null>((location.state as any)?.item || null);
  const [add, setAdd] = useState(false);
  const [upload, setUpload] = useState(false);
  const [exporting, setExporting] = useState(false);
  const toast = useToast();
  const items = useMemo(() => (inv ? buildItems(inv, loc) : []), [inv, loc]);
  if (!inv) return null;
  const costs = inv.can_see_costs;
  const q = search.trim().toLowerCase();
  const shown = items.filter((i) => (!q || i.name.toLowerCase().includes(q) || i.category.toLowerCase().includes(q) || (i.barcode || '').includes(q) || (i.sku || '').toLowerCase().includes(q))
    && (filter === 'all' || (filter === 'review' ? i.needs_review : i.status === filter)));
  const chips: { id: any; label: string; count: number }[] = [
    { id: 'all', label: 'All items', count: items.length },
    ...(['Low', 'Expiring', 'Dead', 'Below cost'] as Status[]).map((s) => ({ id: s, label: s, count: items.filter((i) => i.status === s).length })),
  ];
  if (items.some((i) => i.needs_review)) chips.push({ id: 'review', label: 'Needs a check', count: items.filter((i) => i.needs_review).length });
  const selected = sel ? items.find((i) => i.id === sel) || null : null;
  return (
    <div className="container" style={{ gap: 16 }}>
      <div className="row wrap" style={{ gap: 10 }}>
        <div className="row" style={{ border: '1px solid #E6E6E6', borderRadius: 10, padding: '9px 12px', flex: '1 1 220px', minWidth: 0, maxWidth: 360 }}>
          <Icon name="search" size={16} color="#9CA3AF" />
          <input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Search products or categories" aria-label="Search items"
            className="bare-input" style={{ border: 'none', fontSize: 14, flex: 1, minWidth: 0, boxShadow: 'none', outline: 'none' }} />
        </div>
        <Pills value={filter} onChange={setFilter} options={chips} />
        <div style={{ flex: 1 }} />
        <button className="btn btn-secondary" disabled={exporting} title="Every item and field, in the import template layout" onClick={async () => {
          setExporting(true);
          try { downloadBlob(await itemsXlsx(inv), `${safeName(inv.org.name)} – item list.xlsx`); } catch (e: any) { toast(e.message || 'Export failed', 'err'); }
          setExporting(false);
        }}><Icon name="download" size={16} />{exporting ? 'Exporting…' : 'Export'}</button>
        {can(inv, 'edit_prices') && <button className="btn btn-secondary" onClick={() => setUpload(true)}><Icon name="upload" size={16} />Upload</button>}
        {can(inv, 'edit_prices') && inv.items.length < 5 && <Link className="btn btn-ghost" to="/inventory/migrate"><Icon name="truck" size={16} />Move from another system</Link>}
        {can(inv, 'edit_prices') && <button className="btn btn-primary" onClick={() => setAdd(true)}><Icon name="plus" size={16} color="#fff" />Add item</button>}
      </div>
      <div className="card" style={{ overflow: 'hidden' }}>
        <div className="tbl">
          <div className="tr head shade th rsp" style={{ gridTemplateColumns: COLS, minWidth: 1060 }}>
            <span>Product</span><span>Category</span><span>On hand</span><span className="right">Avg cost</span><span className="right">Price</span><span className="right">Margin</span><span className="right">Value</span><span>Status</span><span />
          </div>
          {shown.map((i) => (
            <div key={i.id} className="tr click blue rsp" onClick={() => setSel(i.id)} style={{ gridTemplateColumns: COLS, minWidth: 1060, padding: '10px 20px' }}>
              <div className="row m-main" style={{ gap: 12, minWidth: 0 }}>
                <Thumb name={i.name} path={i.photo_path} />
                <div style={{ minWidth: 0 }}>
                  <div className="ellipsis" style={{ fontWeight: 600 }}>{i.name}</div>
                  <div style={{ fontSize: 11, color: '#9CA3AF' }}>{[i.brand, !typeSells(i.item_type) ? kindLabel(i.item_type) : null, i.barcode || 'No barcode · QR generated'].filter(Boolean).join(' · ')}{i.needs_review ? ' · needs a check' : ''}</div>
                </div>
              </div>
              <span className="ink3 hide-sm">{i.category}</span>
              <span data-label="On hand">{qtyLabel(i, i.q)}</span>
              <span className="right ink3 num hide-sm">{costs ? N(i.wac) : '—'}</span>
              <span className="right num" data-label="Price" style={{ fontWeight: 500 }}>{Number(i.price) > 0 ? N(i.price) : <span className="faint">Not sold</span>}</span>
              <span className={'right num' + (costs ? '' : ' hide-sm')} data-label="Margin" style={{ fontWeight: 600, color: costs ? marginColor(i.margin, Number(inv.org.margin_threshold)) : '#9CA3AF' }}>{costs ? P(i.margin) : '—'}</span>
              <span className="right num hide-sm">{costs ? K(i.value) : '—'}</span>
              <span className="m-end"><Chip label={i.status} /></span>
              <span className="hide-sm"><Icon name="chevR" size={16} color="#9CA3AF" /></span>
            </div>
          ))}
          {!shown.length && <div style={{ padding: 40, textAlign: 'center', color: '#6B7280', fontSize: 14 }}>No items match this filter.</div>}
        </div>
      </div>
      {selected && <ItemDrawer item={selected} onClose={() => setSel(null)} />}
      {add && <ItemForm onClose={() => setAdd(false)} onSaved={(id) => setSel(id)} />}
      {upload && <ImportPanel onClose={() => setUpload(false)} />}
    </div>
  );
}

function ItemDrawer({ item: it, onClose }: { item: ItemView; onClose: () => void }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const nav = useNavigate();
  const toast = useToast();
  const { run } = useAction();
  const [tab, setTab] = useState<'stock' | 'details' | 'units' | 'batches' | 'moves'>('stock');
  const [edit, setEdit] = useState(false);
  const [transfer, setTransfer] = useState(false);
  const [qr, setQr] = useState<string>('');
  const [uploading, setUploading] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);
  const moves = useItemMoves(tab === 'moves' ? it.id : null);
  useEffect(() => { qrSvg(it.barcode || it.qr_code, 80).then(setQr).catch(() => {}); }, [it.barcode, it.qr_code]);
  if (!inv) return null;
  const costs = inv.can_see_costs;
  const vendor = inv.vendors.find((v) => v.id === it.preferred_vendor_id);
  const vat = { standard: 'Standard 7.5%', zero: 'Zero-rated', exempt: 'Exempt' }[it.vat_treatment];
  const totalAll = Math.max(1, it.qAll);
  const batches = inv.batches.filter((b) => b.item_id === it.id).sort((a, b) => (a.expiry_date || '9') < (b.expiry_date || '9') ? -1 : 1);
  const su = it.selling_unit;

  async function upload(f: File) {
    if (!f.type.startsWith('image/')) { toast('Choose an image file.', 'err'); return; }
    setUploading(true);
    const ext = (f.name.split('.').pop() || 'jpg').toLowerCase();
    const path = `${orgId}/${it.id}-${Date.now()}.${ext}`;
    const { error } = await supabase.storage.from('item-photos').upload(path, f, { upsert: true, contentType: f.type });
    if (error) { toast(error.message, 'err'); setUploading(false); return; }
    await run(() => rpc('set_item_photo', { p_item: it.id, p_path: path }), { ok: 'Photo saved', invalidate: ['inv'] });
    setUploading(false);
  }

  return (
    <>
      <Drawer onClose={onClose} width={560}>
        <div className="drawer-pad-x" style={{ display: 'flex', alignItems: 'flex-start', gap: 14, padding: '20px 24px 0' }}>
          <button onClick={() => fileRef.current?.click()} title="Add a product photo" style={{ border: 0, padding: 0, background: 'none', cursor: 'pointer', position: 'relative' }}>
            <Thumb name={it.name} path={it.photo_path} size={64} radius={12} />
            {uploading && <span style={{ position: 'absolute', inset: 0, display: 'grid', placeItems: 'center', background: 'rgba(255,255,255,.7)', borderRadius: 12 }}><span className="spinner spinner-sm" /></span>}
          </button>
          <input ref={fileRef} type="file" accept="image/*" capture="environment" hidden onChange={(e) => e.target.files?.[0] && upload(e.target.files[0])} />
          <div className="grow">
            <div className="row wrap"><div className="drawer-title">{it.name}</div><Chip label={it.status} /></div>
            <div className="muted" style={{ fontSize: 13, marginTop: 4 }}>{[it.brand, it.category, !typeSells(it.item_type) ? kindLabel(it.item_type) : null, vat, vendor?.name || 'No preferred vendor'].filter(Boolean).join(' · ')}</div>
          </div>
          {can(inv, 'edit_prices') && <button className="btn btn-secondary btn-xs" onClick={() => setEdit(true)}><Icon name="pencil" size={14} />Edit</button>}
          <XButton onClick={onClose} />
        </div>
        <div className="m-2 drawer-pad-x" style={{ display: 'grid', gridTemplateColumns: 'repeat(4,1fr)', gap: 8, padding: '16px 24px 0' }}>
          <Stat label="On hand" value={qtyLabel(it, it.qAll)} />
          <Stat label="Days cover" value={it.cover != null ? Math.round(it.qAll / Math.max(it.vel, 0.0001)) : '—'} />
          <Stat label={`Price / ${su}`} value={Number(it.price) > 0 ? N(it.price) : 'Not sold'} />
          <Stat label="Margin" value={costs ? P(it.margin) : '—'} color={costs ? marginColor(it.margin, Number(inv.org.margin_threshold)) : '#9CA3AF'} />
        </div>
        <div className="row drawer-pad-x" style={{ gap: 4, padding: '16px 24px 0', borderBottom: '1px solid #E6E6E6', overflowX: 'auto', flexWrap: 'nowrap' }} role="tablist">
          {([['stock', 'Stock'], ['details', 'Details'], ['units', 'Units & labels'], ['batches', 'Batches'], ['moves', 'Movements']] as const).map(([id, label]) => (
            <button key={id} role="tab" aria-selected={tab === id} onClick={() => setTab(id)}
              style={{ border: 'none', background: 'transparent', padding: '8px 12px', fontSize: 13, fontWeight: 600, color: tab === id ? '#0072F5' : '#6B7280', borderBottom: '2px solid ' + (tab === id ? '#0072F5' : 'transparent'), cursor: 'pointer', marginBottom: -1 }}>{label}</button>
          ))}
        </div>
        <div className="drawer-body">
          {tab === 'stock' && (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
              {inv.locations.map((l) => {
                const q = Number(it.qty?.[l.id] || 0);
                return (
                  <div key={l.id} className="card" style={{ padding: 14, borderRadius: 12 }}>
                    <div className="row" style={{ justifyContent: 'space-between', fontSize: 14 }}><span style={{ fontWeight: 600 }}>{l.name}</span><span>{qtyLabel(it, q)}</span></div>
                    <div className="bar" style={{ marginTop: 10 }}><div style={{ width: pct(q, totalAll) + '%' }} /></div>
                    <div className="row" style={{ justifyContent: 'space-between', fontSize: 12, color: '#6B7280', marginTop: 6 }}><span>{pct(q, totalAll)}% of total</span><span>{costs && it.wac != null ? K(q * it.wac) + ' at cost' : ''}</span></div>
                  </div>
                );
              })}
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, fontSize: 13 }}>
                <div className="card" style={{ padding: 12, borderRadius: 12 }}><div className="muted">Reorder floor</div><div style={{ fontWeight: 600, marginTop: 2 }}>{Number(it.reorder_floor).toLocaleString('en-NG')} {su}</div></div>
                <div className="card" style={{ padding: 12, borderRadius: 12 }}><div className="muted">Sales velocity</div><div style={{ fontWeight: 600, marginTop: 2 }}>{Math.round(it.vel * 10) / 10} {su}/day</div></div>
              </div>
              {it.status === 'Low' && <Alert kind="amber">Below reorder floor. A suggested order is waiting on the Reorder page.</Alert>}
              {it.status === 'Dead' && <Alert kind="grey">No sale in 90+ days. Insights → Dead stock has a markdown suggestion with its effect on margin.</Alert>}
              {it.status === 'Below cost' && costs && <Alert kind="red" icon="alert">Selling at {N(it.price)} while replacing it costs {N(it.replacement_cost)}. A price proposal is on the Pricing page.</Alert>}
              {it.status === 'Expiring' && <Alert kind="yellow">A batch expires within 30 days. Sell it first (FEFO), or quarantine it once it expires.</Alert>}
              {it.needs_review && <Alert kind="blue" icon="info">Created from a receipt with a provisional price. Check the price and units, then save.</Alert>}
              {Object.keys(it.notes || {}).length > 0 && (
                <div className="card" style={{ padding: 12, borderRadius: 12, fontSize: 13 }}>
                  <div className="mini-label" style={{ marginBottom: 6 }}>Notes from import</div>
                  {Object.entries(it.notes).map(([k, v]) => <div key={k}><span className="muted">{k}:</span> {String(v)}</div>)}
                </div>
              )}
              <div className="row" style={{ marginTop: 4 }}>
                {can(inv, 'receive_stock') && <button className="btn btn-primary btn-sm" onClick={() => nav('/inventory/receive', { state: { manualItem: it.id } })}>Receive stock</button>}
                {can(inv, 'transfer_stock') && inv.locations.length > 1 && <button className="btn btn-secondary btn-sm" style={{ color: '#111827' }} onClick={() => setTransfer(true)}>Transfer</button>}
              </div>
            </div>
          )}
          {tab === 'details' && <ItemDetails it={it} />}
          {tab === 'units' && (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
              <div className="card" style={{ padding: 14, borderRadius: 12 }}>
                <div className="mini-label">Conversion</div>
                <div style={{ fontFamily: 'var(--font-brand)', fontSize: 20, fontWeight: 600, marginTop: 6 }}>1 {it.purchase_unit.toLowerCase()} = {it.pack_size} {su}{it.pack_size === 1 ? '' : 's'}</div>
                <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginTop: 12, fontSize: 13 }}>
                  <div><div className="muted">Buy by the {it.purchase_unit.toLowerCase()}</div><div style={{ fontWeight: 600 }}>{costs && it.wac != null ? N(it.wac * it.pack_size) + ' cost' : '—'}</div></div>
                  <div><div className="muted">Sell by the {su}</div><div style={{ fontWeight: 600 }}>{N(it.price)} each · {N(it.price * it.pack_size)} per {it.purchase_unit.toLowerCase()}</div></div>
                </div>
                {it.informal_unit && <div className="alert alert-blue" style={{ marginTop: 12, fontSize: 12 }}>Informal measure. You set this conversion yourself (1 {it.purchase_unit.toLowerCase()} ≈ {it.pack_size} {su}s); it is yours to edit as your scoop changes.</div>}
              </div>
              <div className="card row" style={{ padding: 14, borderRadius: 12, gap: 16 }}>
                <div style={{ width: 96, height: 96, border: '1px solid #E6E6E6', borderRadius: 8, display: 'grid', placeItems: 'center', flex: 'none', background: '#fff' }} dangerouslySetInnerHTML={{ __html: qr }} />
                <div className="grow">
                  <div className="mini-label">Identification</div>
                  {it.barcode ? (
                    <><div style={{ fontSize: 14, marginTop: 4 }}>EAN <span className="mono">{it.barcode}</span></div><div className="muted" style={{ fontSize: 12, marginTop: 2 }}>Scans resolve straight to this item. QR label is optional for shelf edges.</div></>
                  ) : (
                    <><div style={{ fontSize: 14, marginTop: 4 }}>No manufacturer barcode</div><div className="muted" style={{ fontSize: 12, marginTop: 2 }}>We generated a QR label ({it.qr_code}). Print on ordinary sticker paper and fix to the carton or shelf edge.</div></>
                  )}
                  <button className="btn btn-secondary btn-sm" style={{ marginTop: 10, color: '#111827' }} onClick={() => printLabel(it, inv.org.name).catch((e) => toast(e.message, 'err'))}><Icon name="printer" size={16} />Print label</button>
                </div>
              </div>
              {costs && <ItemAccountCard itemId={it.id} itemName={it.name} />}
              <button className="card row" onClick={() => fileRef.current?.click()} style={{ padding: 14, borderRadius: 12, gap: 12, borderStyle: 'dashed', borderColor: '#D1D5DB', cursor: 'pointer', textAlign: 'left', background: '#fff' }}>
                <Icon name="image" size={20} color="#6B7280" />
                <div style={{ fontSize: 13, color: '#4B5563', lineHeight: 1.45 }}>{it.photo_path ? 'Replace the product photo.' : 'Product photo. Drop an image or take one on the phone — a picture of the carton settles disagreements faster than a SKU.'}</div>
              </button>
            </div>
          )}
          {tab === 'batches' && (it.track_batches || batches.length ? (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              <div className="muted" style={{ fontSize: 12, marginBottom: 4 }}>Consumed first-expiry-first-out. Expired batches leave sellable stock automatically.{it.nafdac_no ? ` NAFDAC ${it.nafdac_no}.` : ''}</div>
              {!batches.length && <Empty>No batches on hand yet. The next receipt creates one.</Empty>}
              {batches.map((b) => {
                const w = batchWindow(b, inv.today);
                return (
                  <div key={b.id} className="card m-2" style={{ padding: '12px 14px', borderRadius: 12, display: 'grid', gridTemplateColumns: '1fr 1fr 1fr auto', gap: 10, alignItems: 'center', fontSize: 13 }}>
                    <div><div className="mono" style={{ fontWeight: 600 }}>{b.batch_no}</div><div style={{ fontSize: 11, color: '#9CA3AF' }}>{inv.locations.find((l) => l.id === b.location_id)?.name}</div></div>
                    <div><div>{fmtDay(b.expiry_date)}</div><div style={{ fontSize: 11, color: '#9CA3AF' }}>{daysLabel(w.days)}</div></div>
                    <div><div>{Number(b.qty_remaining).toLocaleString('en-NG')} {su}</div><div style={{ fontSize: 11, color: '#9CA3AF' }}>Remaining</div></div>
                    <Chip label={w.label} />
                  </div>
                );
              })}
            </div>
          ) : (
            <Empty style={{ padding: 28, fontSize: 13 }}>Batch tracking is off for this item. Turn it on for NAFDAC-regulated or perishable goods; the OCR pass then reads batch number and expiry from the invoice.</Empty>
          ))}
          {tab === 'moves' && (
            <div>
              {moves.isLoading && <SkeletonRows n={4} />}
              {moves.data && !moves.data.length && <Empty style={{ padding: 28, fontSize: 13 }}>No movements yet.</Empty>}
              {(moves.data || []).map((m) => (
                <div key={m.gid} className="row" style={{ gap: 12, padding: '12px 0', borderBottom: '1px solid #F3F4F6', fontSize: 13 }}>
                  <span className={'chip ' + typeTone(m.type)} style={{ flex: 'none' }}>{typeLabel(m.type)}</span>
                  <div className="grow">
                    <div style={{ fontWeight: 500 }}>{moveQty(m)}{m.value != null ? ' · ' + N(m.value) : ''}</div>
                    <div className="muted ellipsis" style={{ fontSize: 12 }}>{moveRef(m, inv.locations)} · {m.author_name || 'System'} · {inv.locations.find((l) => l.id === m.location_id)?.name}</div>
                  </div>
                  <span className="faint" style={{ fontSize: 12, flex: 'none' }}>{when(m.recorded_at)}</span>
                </div>
              ))}
            </div>
          )}
        </div>
      </Drawer>
      {edit && <ItemForm item={it} onClose={() => setEdit(false)} />}
      {transfer && <TransferModal itemId={it.id} onClose={() => setTransfer(false)} />}
    </>
  );
}


function ItemDetails({ it }: { it: ItemView }) {
  const { data: inv } = useInventory();
  if (!inv) return null;
  const ind = industryOf(inv.org.industry);
  const indKeys = new Set(fieldsFor(inv.org.industry).map((f) => f.key));
  const attrs = it.attributes || {};
  const rows: [string, string][] = [
    ['Kind of item', kindLabel(it.item_type)],
    ['Inventory account', it.inventory_account || ITEM_TYPES.find((t) => t.id === (it.item_type || 'merchandise'))?.account || '1203'],
    ['Brand', it.brand || ''], ['Catalogue ID / SKU', it.sku || ''], ['Barcode', it.barcode || ''], ['NAFDAC number', it.nafdac_no || ''],
  ];
  const own = fieldsFor(inv.org.industry).map((f) => [f.label, formatAttr(f, attrs[f.key])] as [string, string]);
  const other = Object.keys(attrs).filter((k) => !indKeys.has(k)).map((k) => [ALL_FIELDS.find((f) => f.key === k)?.label || k, formatAttr(ALL_FIELDS.find((f) => f.key === k), attrs[k])] as [string, string]);
  const block = (title: string, list: [string, string][]) => list.some(([, v]) => v) && (
    <div className="card" style={{ padding: 14, borderRadius: 12 }}>
      <div className="mini-label" style={{ marginBottom: 8 }}>{title}</div>
      <div style={{ display: 'grid', gridTemplateColumns: 'minmax(120px,40%) 1fr', rowGap: 6, columnGap: 12, fontSize: 13 }}>
        {list.filter(([, v]) => v).map(([k, v]) => [<span key={k + 'k'} className="muted">{k}</span>, <span key={k + 'v'} style={{ wordBreak: 'break-word' }}>{v}</span>])}
      </div>
    </div>
  );
  return (
    <div className="stack" style={{ gap: 12 }}>
      {block('Item', rows)}
      {block(`${ind.label} details`, own)}
      {block('Other details', other)}
      {it.description && <div className="card" style={{ padding: 14, borderRadius: 12, fontSize: 13, lineHeight: 1.5 }}><div className="mini-label" style={{ marginBottom: 6 }}>Description</div>{it.description}</div>}
      {!own.some(([, v]) => v) && !other.length && <div className="hint">No {ind.label.toLowerCase()} details yet. Use Edit to add them, or upload a sheet with those columns.</div>}
    </div>
  );
}
