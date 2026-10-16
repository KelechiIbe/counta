import { useRef, useState, type DragEvent } from 'react';
import { Drawer, Field, Spinner, XButton, Alert } from '../../components/ui';
import { Icon } from '../../components/Icon';
import { rpc } from '../../lib/supabase';
import { useInventory, useSession } from '../../state/session';
import { useAction } from '../../lib/queries';
import { acct, usePostingMap } from '../../lib/accounts';

type FieldKey = 'name' | 'sku' | 'price' | 'cost' | 'qty' | 'pack_size' | 'barcode' | 'category' | 'selling_unit' | 'purchase_unit' | 'vat_treatment' | 'reorder_floor' | 'note';
const FIELDS: { key: FieldKey; label: string; syn: string[] }[] = [
  { key: 'name', label: 'Name', syn: ['product name', 'product', 'item name', 'item', 'description', 'name', 'goods', 'product description'] },
  { key: 'sku', label: 'Catalogue ID', syn: ['item code', 'code', 'sku', 'catalogue id', 'catalog id', 'product code', 'product id', 'item id'] },
  { key: 'price', label: 'Selling price', syn: ['sell price', 'selling price', 'price', 'retail price', 'unit price', 'sp', 'sales price'] },
  { key: 'cost', label: 'Unit cost', syn: ['buy price', 'cost', 'cost price', 'unit cost', 'purchase price', 'cp', 'buying price'] },
  { key: 'qty', label: 'On hand', syn: ['qty', 'quantity', 'on hand', 'stock', 'balance', 'units', 'closing stock', 'stock level', 'qty on hand'] },
  { key: 'pack_size', label: 'Pack size', syn: ['ctn size', 'carton size', 'pack size', 'pack', 'units per carton', 'case size', 'per carton', 'pcs per ctn', 'qty per carton'] },
  { key: 'barcode', label: 'Barcode', syn: ['barcode', 'ean', 'upc', 'gtin', 'bar code'] },
  { key: 'category', label: 'Category', syn: ['category', 'group', 'department', 'class', 'type'] },
  { key: 'selling_unit', label: 'Selling unit', syn: ['unit', 'uom', 'selling unit', 'sell unit'] },
  { key: 'purchase_unit', label: 'Purchase unit', syn: ['purchase unit', 'buy unit', 'carton type'] },
  { key: 'vat_treatment', label: 'VAT', syn: ['vat', 'tax', 'vat treatment', 'vat status'] },
  { key: 'reorder_floor', label: 'Reorder floor', syn: ['reorder level', 'reorder', 'min', 'minimum', 'reorder point', 'floor', 'min stock'] },
];

function autoMatch(headers: string[]): Record<number, FieldKey> {
  const used = new Set<FieldKey>(); const map: Record<number, FieldKey> = {};
  headers.forEach((h, i) => {
    const k = h.toLowerCase().replace(/[_\-.]/g, ' ').replace(/\s+/g, ' ').trim();
    const f = FIELDS.find((f) => !used.has(f.key) && f.syn.includes(k)) || FIELDS.find((f) => !used.has(f.key) && f.syn.some((s) => s.length > 3 && k.includes(s)));
    if (f) { map[i] = f.key; used.add(f.key); } else map[i] = 'note';
  });
  return map;
}
const vatOf = (v: string) => { const s = (v || '').toLowerCase(); return /exempt/.test(s) ? 'exempt' : /zero|^0/.test(s) ? 'zero' : 'standard'; };

export default function ImportPanel({ onClose }: { onClose: () => void }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const { run } = useAction();
  const posting = usePostingMap().data;
  const [step, setStep] = useState<0 | 1 | 2 | 3>(0);
  const [file, setFile] = useState<string>('');
  const [rows, setRows] = useState<string[][]>([]);
  const [headers, setHeaders] = useState<string[]>([]);
  const [map, setMap] = useState<Record<number, FieldKey>>({});
  const [loc, setLoc] = useState(inv?.locations[0]?.id || '');
  const [qtyIn, setQtyIn] = useState<'selling' | 'purchase'>('selling');
  const [costIn, setCostIn] = useState<'selling' | 'purchase'>('selling');
  const [err, setErr] = useState<string | null>(null);
  const [drag, setDrag] = useState(false);
  const [manual, setManual] = useState([{ name: '', sku: '', price: '', cost: '', qty: '', pack_size: '', purchase_unit: 'Carton', selling_unit: 'piece', vat: 'standard', more: false }]);
  const input = useRef<HTMLInputElement>(null);

  async function readFile(f: File) {
    setErr(null);
    if (f.size > 10 * 1024 * 1024) { setErr('That file is over 10MB. Split it and try again.'); return; }
    setFile(f.name); setStep(1);
    try {
      const XLSX = await import('xlsx');
      const wb = XLSX.read(await f.arrayBuffer(), { type: 'array' });
      const sheet = wb.Sheets[wb.SheetNames[0]];
      const all = XLSX.utils.sheet_to_json<string[]>(sheet, { header: 1, raw: false, defval: '' }) as string[][];
      const clean = all.filter((r) => r.some((c) => String(c).trim() !== ''));
      if (clean.length < 2) throw new Error('No product rows found under the header row.');
      const hdr = clean[0].map((h) => String(h).trim() || 'Column');
      setHeaders(hdr); setRows(clean.slice(1).map((r) => hdr.map((_, i) => String(r[i] ?? '').trim())));
      setMap(autoMatch(hdr));
      setTimeout(() => setStep(2), 500);
    } catch (e: any) { setErr(e.message || 'Could not read that file.'); setStep(0); }
  }
  function onDrop(e: DragEvent) { e.preventDefault(); setDrag(false); const f = e.dataTransfer.files?.[0]; if (f) readFile(f); }

  const matched = Object.values(map).filter((v) => v !== 'note').length;
  const hasName = Object.values(map).includes('name');
  const hasPrice = Object.values(map).includes('price');

  async function doImport() {
    if (!hasName || !hasPrice) { setErr('Match a column to Name and one to Selling price.'); return; }
    setStep(3);
    const payload = rows.map((r) => {
      const o: any = { notes: {} };
      headers.forEach((h, i) => {
        const k = map[i]; const v = r[i];
        if (k === 'note') { if (v) o.notes[h] = v; } else if (k === 'vat_treatment') o.vat_treatment = vatOf(v); else o[k] = v;
      });
      const pack = Math.max(1, Math.floor(Number(String(o.pack_size || '1').replace(/[^0-9.]/g, '')) || 1));
      o.pack_size = pack;
      if (qtyIn === 'purchase' && o.qty) o.qty = String(Number(String(o.qty).replace(/[^0-9.\-]/g, '')) * pack);
      if (costIn === 'purchase' && o.cost) o.cost = String(Number(String(o.cost).replace(/[^0-9.\-]/g, '')) / pack);
      return o;
    });
    const r = await run(() => rpc<any>('import_items', { p_org: orgId, p_location: loc, p_rows: payload, p_file_name: file }), {
      ok: (r: any) => `${r.created} products imported${r.skipped.length ? ` · ${r.skipped.length} skipped` : ''}${Object.values(map).includes('note') ? ' · extra columns kept as notes' : ''}`,
    });
    if (r) onClose(); else setStep(2);
  }

  async function saveManual() {
    setErr(null);
    const good = manual.filter((m) => m.name.trim());
    if (!good.length) { setErr('Enter at least one product name.'); return; }
    for (const m of good) {
      if (!(Number(m.price) > 0)) { setErr(`Enter a selling price for ${m.name}.`); return; }
    }
    setStep(3);
    const payload = good.map((m) => ({ name: m.name, sku: m.sku, price: m.price, cost: m.cost, qty: m.qty, pack_size: m.pack_size || '1', purchase_unit: m.purchase_unit, selling_unit: m.selling_unit, vat_treatment: m.vat }));
    const r = await run(() => rpc<any>('import_items', { p_org: orgId, p_location: loc, p_rows: payload, p_file_name: 'Manual entry' }), { ok: (r: any) => `${r.created} product${r.created === 1 ? '' : 's'} added` });
    if (r) onClose(); else setStep(0);
  }

  return (
    <Drawer onClose={onClose} width={560}>
      <div className="drawer-hd">
        <span style={{ width: 48, height: 48, borderRadius: '50%', background: '#F3F4F6', display: 'grid', placeItems: 'center', flex: 'none' }}><Icon name="upload" size={22} color="#6B7280" /></span>
        <div className="grow"><div style={{ fontFamily: 'var(--font-brand)', fontSize: 22, fontWeight: 600 }}>Upload inventory</div><div className="muted" style={{ fontSize: 14, marginTop: 2 }}>Upload a spreadsheet of your products to import them.</div></div>
        <XButton onClick={onClose} />
      </div>
      <div className="drawer-body">
        {step === 0 && (
          <>
            <div onClick={() => input.current?.click()} onDragOver={(e) => { e.preventDefault(); setDrag(true); }} onDragLeave={() => setDrag(false)} onDrop={onDrop}
              style={{ border: '1.5px dashed ' + (drag ? '#0072F5' : '#D1D5DB'), background: drag ? '#F0F7FF' : '#fff', borderRadius: 16, padding: '36px 20px', textAlign: 'center', cursor: 'pointer' }} role="button" tabIndex={0}>
              <div style={{ width: 44, height: 44, margin: '0 auto', borderRadius: 8, background: '#111827', color: '#fff', fontSize: 10, fontWeight: 700, display: 'grid', placeItems: 'center' }}>xlsx</div>
              <div style={{ fontSize: 15, marginTop: 14 }}><span style={{ color: '#0072F5', textDecoration: 'underline' }}>Choose a file</span> or drag &amp; drop it here</div>
              <div className="muted" style={{ fontSize: 13, marginTop: 4 }}>XLSX, XLS or CSV · up to 10MB</div>
              <input ref={input} type="file" accept=".xlsx,.xls,.csv" hidden onChange={(e) => e.target.files?.[0] && readFile(e.target.files[0])} />
            </div>
            {err && <Alert kind="red" icon="alert" style={{ marginTop: 12 }}>{err}</Alert>}
            <div style={{ textAlign: 'center', fontSize: 11, fontWeight: 600, letterSpacing: '.08em', color: '#9CA3AF', margin: '22px 0 16px' }}>OR ENTER MANUALLY</div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
              {manual.map((m, i) => {
                const set = (k: string, v: any) => setManual(manual.map((x, j) => (j === i ? { ...x, [k]: v } : x)));
                return (
                  <div key={i} style={{ border: '1px solid #E6E6E6', borderRadius: 14, padding: 16, display: 'flex', flexDirection: 'column', gap: 12 }}>
                    <div className="row" style={{ justifyContent: 'space-between' }}><div style={{ fontSize: 14, fontWeight: 600 }}>Product {i + 1}</div>{manual.length > 1 && <XButton size={16} onClick={() => setManual(manual.filter((_, j) => j !== i))} />}</div>
                    <Field label="Name" req><input className="input" value={m.name} onChange={(e) => set('name', e.target.value)} placeholder="e.g. Golden Penny Spaghetti 500g" /></Field>
                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
                      <Field label="Catalogue ID"><input className="input" value={m.sku} onChange={(e) => set('sku', e.target.value)} /></Field>
                      <Field label="Selling price" req><input className="input" type="number" inputMode="decimal" value={m.price} onChange={(e) => set('price', e.target.value)} placeholder="₦" /></Field>
                    </div>
                    <button className="btn-ghost" style={{ color: '#0072F5', fontSize: 13, display: 'flex', alignItems: 'center', gap: 6, cursor: 'pointer', padding: 0 }} onClick={() => set('more', !m.more)}>
                      <Icon name="chevD" size={14} color="#0072F5" style={{ transform: m.more ? 'rotate(180deg)' : undefined }} />Add more details (optional): units, pack size, cost, stock, VAT
                    </button>
                    {m.more && (
                      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10 }}>
                        <Field label="Buy by the"><select className="input" value={m.purchase_unit} onChange={(e) => set('purchase_unit', e.target.value)}>{['Carton', 'Bag', 'Bale', 'Pack', 'Crate', 'Roll'].map((u) => <option key={u}>{u}</option>)}</select></Field>
                        <Field label="Contains"><input className="input" type="number" value={m.pack_size} onChange={(e) => set('pack_size', e.target.value)} placeholder="1" /></Field>
                        <Field label="Sell by the"><select className="input" value={m.selling_unit} onChange={(e) => set('selling_unit', e.target.value)}>{['piece', 'pack', 'sachet', 'tin', 'bottle', 'derica', 'mudu', 'paint bucket', 'kg'].map((u) => <option key={u}>{u}</option>)}</select></Field>
                        <Field label="Cost / selling unit"><input className="input" type="number" value={m.cost} onChange={(e) => set('cost', e.target.value)} placeholder="₦" /></Field>
                        <Field label="On hand now"><input className="input" type="number" value={m.qty} onChange={(e) => set('qty', e.target.value)} placeholder="0" /></Field>
                        <Field label="VAT"><select className="input" value={m.vat} onChange={(e) => set('vat', e.target.value)}><option value="standard">Standard 7.5%</option><option value="zero">Zero-rated</option><option value="exempt">Exempt</option></select></Field>
                      </div>
                    )}
                  </div>
                );
              })}
              <div className="row" style={{ justifyContent: 'space-between' }}>
                <button className="btn btn-secondary btn-sm" onClick={() => setManual([...manual, { name: '', sku: '', price: '', cost: '', qty: '', pack_size: '', purchase_unit: 'Carton', selling_unit: 'piece', vat: 'standard', more: false }])}><Icon name="plus" size={14} />Another product</button>
                <button className="btn btn-primary btn-sm" onClick={saveManual}>Save products</button>
              </div>
            </div>
          </>
        )}
        {(step === 1 || step === 3) && (
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 14, padding: '60px 0', textAlign: 'center' }}>
            <Spinner />
            <div style={{ fontSize: 15, fontWeight: 600 }}>{step === 1 ? `Reading ${file}` : `Creating ${rows.length || manual.filter((m) => m.name).length} items and opening balances…`}</div>
            <div className="muted" style={{ fontSize: 13 }}>{step === 1 ? 'Matching headers to your item master' : `Opening stock posts to Atlas · Dr ${acct(posting, 'inventory').code} ${acct(posting, 'inventory').name} / Cr ${acct(posting, 'opening_equity').code} ${acct(posting, 'opening_equity').name}`}</div>
          </div>
        )}
        {step === 2 && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            <div>
              <div style={{ fontSize: 14, fontWeight: 600 }}>Match columns</div>
              <div className="muted" style={{ fontSize: 13, margin: '4px 0 2px', lineHeight: 1.45 }}>
                {rows.length} rows · {headers.length} columns. We matched {matched} of {headers.length}. Unmatched columns are kept on each item as notes; nothing is dropped.
              </div>
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              {headers.map((h, i) => (
                <div key={i} style={{ display: 'grid', gridTemplateColumns: '1fr 24px 1fr', gap: 10, alignItems: 'center', border: '1px solid #E6E6E6', borderRadius: 10, padding: '8px 12px', fontSize: 13 }}>
                  <span className="mono ink3 ellipsis" title={rows[0]?.[i] ? `e.g. ${rows[0][i]}` : ''}>{h}</span>
                  <span className="faint">→</span>
                  <select className="input input-sm" value={map[i]} onChange={(e) => setMap({ ...map, [i]: e.target.value as FieldKey })}
                    style={{ fontWeight: 600, color: map[i] === 'note' ? '#C2410C' : '#15803D', background: map[i] === 'note' ? '#FFF7ED' : '#F0FDF4', borderColor: 'transparent' }}>
                    <option value="note">Needs review (keep as note)</option>
                    {FIELDS.map((f) => <option key={f.key} value={f.key} disabled={Object.entries(map).some(([j, v]) => v === f.key && Number(j) !== i)}>{f.label}</option>)}
                  </select>
                </div>
              ))}
            </div>
            {Object.values(map).includes('pack_size') && (
              <div className="alert alert-blue">Pack sizes found: we will set <b>1 carton = {headers[Number(Object.entries(map).find(([, v]) => v === 'pack_size')?.[0])]}</b> selling units for each row. You can change conversions per item later.</div>
            )}
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10 }}>
              <Field label="Opening stock at"><select className="input" value={loc} onChange={(e) => setLoc(e.target.value)}>{inv?.locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</select></Field>
              <Field label="Quantities are in"><select className="input" value={qtyIn} onChange={(e) => setQtyIn(e.target.value as any)}><option value="selling">Selling units</option><option value="purchase">Cartons / bags</option></select></Field>
              <Field label="Costs are per"><select className="input" value={costIn} onChange={(e) => setCostIn(e.target.value as any)}><option value="selling">Selling unit</option><option value="purchase">Carton / bag</option></select></Field>
            </div>
            {err && <Alert kind="red" icon="alert">{err}</Alert>}
          </div>
        )}
      </div>
      {step === 2 && (
        <div className="drawer-ft">
          <button className="btn btn-secondary" onClick={() => { setStep(0); setRows([]); }}>Cancel</button>
          <button className="btn btn-primary" onClick={doImport} disabled={!hasName || !hasPrice}>Import {rows.length} products</button>
        </div>
      )}
    </Drawer>
  );
}
