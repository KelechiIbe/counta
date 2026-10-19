// Adding a product from the phone: a photo of the front and one of the back. The phone reads the barcode on the back
// itself; Gemini reads the name, brand, size, unit and NAFDAC number from both photos. The usual item form opens filled
// in, the person adds the price and cost and anything else, and the front photo becomes the product's picture.
// From then on the barcode finds the product at the till, the way a POS scanner does.
import { useEffect, useRef, useState } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { can, useInventory, useSession } from '../state/session';
import { edge } from '../lib/api';
import { makeDetector } from '../lib/barcode';
import { shrinkImage } from '../lib/images';
import type { Drafts } from '../lib/drafts';
import type { Item } from '../lib/types';
import { Icon } from '../components/Icon';
import { Spinner, Thumb } from '../components/ui';
import ItemForm from '../pages/inventory/ItemForm';
import { MTop, useM } from './ctx';
import { Done } from './common';
import { Camera } from './Scan';

type Shot = { file: File; url: string };
type Read = {
  name: string; brand: string | null; description: string | null; category: string | null; selling_unit: string | null; purchase_unit: string | null;
  pack_size: number | null; barcode: string | null; nafdac_no: string | null; item_type: string; confidence: number; warnings: string[];
};

const toB64 = (b: Blob) => new Promise<string>((res, rej) => { const r = new FileReader(); r.onload = () => res(String(r.result).split(',')[1] || ''); r.onerror = rej; r.readAsDataURL(b); });

// The barcode in a still photo, read on the phone.
async function barcodeIn(file: File): Promise<string | null> {
  try {
    const det = await makeDetector();
    if (!det) return null;
    const bmp = await createImageBitmap(file);
    try {
      const codes = await (det as unknown as { detect: (s: ImageBitmap) => Promise<{ rawValue: string }[]> }).detect(bmp);
      return codes.find((c) => /^\d{8,14}$/.test(c.rawValue))?.rawValue || null;
    } finally { bmp.close?.(); }
  } catch { return null; }
}

export function AddScreen() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const { queue } = useM();
  const nav = useNavigate();
  const loc = useLocation();
  const params = new URLSearchParams(loc.search);
  const then = params.get('then');
  const [front, setFront] = useState<Shot | null>(null);
  const [back, setBack] = useState<Shot | null>(null);
  const [code, setCode] = useState<string | null>(() => (/^\d{6,14}$/.test(params.get('barcode') || '') ? params.get('barcode') : null));
  const [codeFrom, setCodeFrom] = useState<'photo' | 'scan' | 'till' | null>(() => (params.get('barcode') ? 'till' : null));
  const [scanning, setScanning] = useState(false);
  const [busy, setBusy] = useState<'barcode' | 'read' | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [form, setForm] = useState<{ draft: Drafts['product']; note: string } | null>(null);
  const [saved, setSaved] = useState<Item | string | null>(null);
  const frontIn = useRef<HTMLInputElement>(null);
  const backIn = useRef<HTMLInputElement>(null);
  useEffect(() => () => { if (front) URL.revokeObjectURL(front.url); if (back) URL.revokeObjectURL(back.url); }, []); // eslint-disable-line react-hooks/exhaustive-deps
  if (!inv) return null;
  if (!(can(inv, 'add_items') || can(inv, 'edit_prices'))) {
    return <><MTop title="Add a product" /><div className="m-pad muted">Your role does not add products. Ask the owner for "Add products".</div></>;
  }
  const existing = code ? inv.items.find((i) => i.barcode === code) : undefined;

  async function shoot(which: 'front' | 'back', f: File | undefined) {
    if (!f) return;
    if (!f.type.startsWith('image/')) { setErr('Take a photo, or choose a picture.'); return; }
    setErr(null);
    const shot = { file: f, url: URL.createObjectURL(f) };
    if (which === 'front') { if (front) URL.revokeObjectURL(front.url); setFront(shot); }
    else {
      if (back) URL.revokeObjectURL(back.url);
      setBack(shot);
      if (codeFrom !== 'scan' && codeFrom !== 'till') {
        setBusy('barcode');
        const c = await barcodeIn(f);
        setBusy(null);
        if (c) { setCode(c); setCodeFrom('photo'); navigator.vibrate?.(60); }
      }
    }
  }

  async function read() {
    if (!front) { setErr('Take a photo of the front first.'); return; }
    setBusy('read'); setErr(null);
    try {
      const shots = [front, back].filter(Boolean) as Shot[];
      const images = await Promise.all(shots.map(async (s) => {
        const pic = await shrinkImage(s.file, 1280, 0.82);
        return { mime: pic.type === 'image/png' ? 'image/png' : pic.type === 'image/webp' ? 'image/webp' : 'image/jpeg', data: await toB64(pic.blob) };
      }));
      const categories = [...new Set(inv!.items.map((i) => i.category).filter(Boolean))].slice(0, 60);
      const r = await edge<{ product: Read }>('ai', { action: 'read_product', org_id: orgId, images, barcode: code, industry: inv!.org.industry || 'retail', categories });
      if (!r.ok) {
        // Without the reader, the form still opens with the photo and barcode for typing in.
        setErr(r.error || 'The photos could not be read just now.');
        setBusy(null);
        return;
      }
      const p = r.product;
      const photo = await shrinkImage(front.file);
      const draft: Drafts['product'] = {
        // Without a carton size on the pack, it is bought and sold by the same unit until the person says otherwise.
        name: p.name, kind: 'product', brand: p.brand, description: p.description, category: p.category, unit: p.selling_unit,
        purchase_unit: p.pack_size ? p.purchase_unit : p.selling_unit ? p.selling_unit.charAt(0).toUpperCase() + p.selling_unit.slice(1) : null,
        pack_size: p.pack_size || 1, barcode: p.barcode || code, nafdac_no: p.nafdac_no, item_type: p.item_type, photo: photo.blob, photo_type: photo.type, price: null, cost: null,
      };
      const notes = [`Read from your photos${p.confidence < 0.6 ? ', but not clearly' : ''}. Check the name and size, then add the cost and selling price.`, ...p.warnings];
      setForm({ draft, note: notes.join(' ') });
    } catch (e) { setErr((e as Error).message); }
    setBusy(null);
  }

  async function typeIn() {
    const photo = front ? await shrinkImage(front.file).catch(() => null) : null;
    setForm({ draft: { name: '', kind: 'product', barcode: code, photo: photo?.blob || null, photo_type: photo?.type || null }, note: 'Type the product in. The barcode and the front photo are kept.' });
  }

  function reset() {
    if (front) URL.revokeObjectURL(front.url);
    if (back) URL.revokeObjectURL(back.url);
    setFront(null); setBack(null); setCode(null); setCodeFrom(null); setForm(null); setSaved(null); setErr(null);
  }

  if (saved) {
    const it = typeof saved === 'string' ? inv.items.find((i) => i.id === saved) : saved;
    return (
      <>
        <MTop title="Add a product" />
        <Done title={`${it?.name || 'The product'} is in your stock`} body={code ? 'Scan its barcode at the till to sell it.' : 'It has a QR label to print from the item on the computer.'}
          action={then === 'sell' ? 'Back to the till' : 'Add another'} onAction={() => (then === 'sell' ? nav('/m/till') : reset())} />
        {then !== 'sell' && can(inv, 'record_sales') && <div className="m-pad" style={{ paddingTop: 0 }}><button className="m-btn secondary" style={{ width: '100%' }} onClick={() => nav('/m/till')}>Sell it now</button></div>}
      </>
    );
  }

  return (
    <>
      <MTop title="Add a product" />
      <div className="m-pad stack" style={{ gap: 14 }}>
        <div className="ink3" style={{ fontSize: 14, lineHeight: 1.5 }}>Take a photo of the front, then the back with the barcode. Counta reads the rest; you add the price.</div>
        {!queue.online && <div className="alert alert-yellow">Reading photos needs data. You can still type the product in.</div>}
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
          {([['front', 'Front', front, frontIn], ['back', 'Back, with the barcode', back, backIn]] as const).map(([k, label, shot, ref]) => (
            <button key={k} type="button" className="m-card" onClick={() => ref.current?.click()} aria-label={`Photo of the ${k}`}
              style={{ height: 150, padding: 0, overflow: 'hidden', display: 'grid', placeItems: 'center', position: 'relative', border: shot ? '1px solid #E6E6E6' : '1.5px dashed #B9D4FF', background: shot ? '#000' : '#F7FAFF', cursor: 'pointer' }}>
              {shot ? <img src={shot.url} alt="" style={{ width: '100%', height: '100%', objectFit: 'cover' }} />
                : <span className="stack" style={{ alignItems: 'center', gap: 6, color: '#0072F5', fontSize: 13, fontWeight: 600 }}><Icon name="camera" size={24} color="#0072F5" />{label}</span>}
              {shot && <span style={{ position: 'absolute', left: 8, bottom: 8, background: 'rgba(0,0,0,.6)', color: '#fff', fontSize: 11, borderRadius: 6, padding: '2px 6px' }}>{label} · retake</span>}
            </button>
          ))}
        </div>
        <input ref={frontIn} type="file" accept="image/*" capture="environment" hidden onChange={(e) => { void shoot('front', e.target.files?.[0]); e.target.value = ''; }} />
        <input ref={backIn} type="file" accept="image/*" capture="environment" hidden onChange={(e) => { void shoot('back', e.target.files?.[0]); e.target.value = ''; }} />

        <div className="m-card row" style={{ gap: 10, padding: 12 }}>
          <Icon name="scan" size={18} color={code ? '#15803D' : '#6B7280'} />
          <div className="grow" style={{ minWidth: 0 }}>
            <div style={{ fontSize: 13, fontWeight: 600 }}>{busy === 'barcode' ? 'Reading the barcode…' : code ? <span className="mono">{code}</span> : 'No barcode yet'}</div>
            <div className="faint" style={{ fontSize: 11 }}>{code ? (codeFrom === 'photo' ? 'Read from the photo of the back' : codeFrom === 'till' ? 'Scanned at the till' : 'Scanned with the camera') : 'It is read from the back photo, or scan it live'}</div>
          </div>
          <button className="btn btn-secondary btn-xs" onClick={() => setScanning(!scanning)}>{scanning ? 'Close' : code ? 'Scan again' : 'Scan it'}</button>
        </div>
        {scanning && <Camera height={220} paused={false} onCode={(c) => { setCode(c); setCodeFrom('scan'); setScanning(false); navigator.vibrate?.(60); }} />}
        {existing && (
          <div className="alert alert-blue row" style={{ gap: 10, alignItems: 'center' }}>
            <Thumb name={existing.name} path={existing.photo_path} size={36} radius={8} />
            <span className="grow" style={{ minWidth: 0 }}>Already in your stock as <b>{existing.name}</b>.</span>
            {can(inv, 'record_sales') && <button className="btn btn-primary btn-xs" onClick={() => nav(`/m/till?code=${encodeURIComponent(existing.barcode || '')}`)}>Sell it</button>}
          </div>
        )}
        {err && <div className="alert alert-red">{err}</div>}
        <button className="m-btn" disabled={!front || busy !== null || !queue.online || !!existing} onClick={read}>
          {busy === 'read' ? <><Spinner small />Reading the photos…</> : 'Read the product'}
        </button>
        <button className="m-btn ghost" disabled={busy !== null || !!existing} onClick={typeIn}>Type it in instead</button>
      </div>
      {form && <ItemForm draft={form.draft} note={form.note} onClose={() => setForm(null)} onSaved={(id) => setSaved(id)} />}
    </>
  );
}
