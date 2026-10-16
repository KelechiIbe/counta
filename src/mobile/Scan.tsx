import { useEffect, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { can, useInventory } from '../state/session';
import { N, P, fmtDay, daysBetween } from '../lib/format';
import { marginColor, pluralUnit, qtyLabel, suAbbr } from '../lib/domain';
import type { Item } from '../lib/types';
import { Icon } from '../components/Icon';
import { Stat, Thumb } from '../components/ui';
import { BranchChip, MTop, QueueBanner, useM } from './ctx';
import { Done, ItemSearch, SaleSheet } from './common';
import { makeDetector } from '../lib/barcode';

export default function ScanScreen() {
  const { data: inv } = useInventory();
  const [item, setItem] = useState<Item | null>(null);
  const [miss, setMiss] = useState<string | null>(null);
  const [selling, setSelling] = useState(false);
  const [done, setDone] = useState<string | null>(null);
  function found(code: string) {
    const it = inv?.items.find((i) => i.barcode === code || i.qr_code === code || i.sku === code) || null;
    if (it) { setItem(it); setMiss(null); if (navigator.vibrate) navigator.vibrate(60); } else setMiss(code);
  }
  const reset = () => { setItem(null); setMiss(null); setSelling(false); setDone(null); };
  return (
    <>
      <MTop title="Scan" right={<BranchChip />} />
      <QueueBanner />
      {done ? <Done title="Recorded" body={done + '. It posts to the books as soon as there is data.'} action="Scan another" onAction={reset} />
        : item ? (selling ? <div className="m-pad"><SaleSheet item={item} onCancel={() => setSelling(false)} onDone={setDone} /></div> : <ItemCard item={item} onSell={() => setSelling(true)} onAgain={reset} />)
        : (
          <div className="stack" style={{ flex: 1 }}>
            <Camera onCode={found} paused={!!item} />
            <div className="m-pad stack" style={{ gap: 10 }}>
              {miss && <div className="alert alert-yellow">No item uses the code <span className="mono">{miss}</span>. Search by name below, or ask the owner to add the barcode to the item.</div>}
              <div className="muted" style={{ fontSize: 12, textAlign: 'center' }}>No barcode? Scan the QR label we printed, or search by name.</div>
              <ItemSearch onPick={(i) => { setItem(i); setMiss(null); }} />
            </div>
          </div>
        )}
    </>
  );
}

function Camera({ onCode, paused }: { onCode: (c: string) => void; paused: boolean }) {
  const video = useRef<HTMLVideoElement>(null);
  const [state, setState] = useState<'idle' | 'on' | 'unsupported' | 'denied'>('idle');
  const supported = typeof navigator !== 'undefined' && !!navigator.mediaDevices?.getUserMedia;
  useEffect(() => {
    if (!supported) { setState('unsupported'); return; }
    let stream: MediaStream | null = null; let timer = 0; let stop = false;
    (async () => {
      try {
        stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: 'environment' } }, audio: false });
        if (stop) { stream.getTracks().forEach((t) => t.stop()); return; }
        if (video.current) { video.current.srcObject = stream; await video.current.play().catch(() => {}); }
        setState('on');
        const det = await makeDetector();
        if (!det) { setState('unsupported'); stream.getTracks().forEach((t) => t.stop()); return; }
        let last = '';
        const tick = async () => {
          if (stop) return;
          if (video.current && video.current.readyState >= 2 && !paused) {
            try {
              const codes = await det.detect(video.current);
              const v = codes?.[0]?.rawValue;
              if (v && v !== last) { last = v; onCode(v); setTimeout(() => { last = ''; }, 2500); }
            } catch { /* frame not ready */ }
          }
          timer = window.setTimeout(tick, 280);
        };
        tick();
      } catch { setState('denied'); }
    })();
    return () => { stop = true; window.clearTimeout(timer); stream?.getTracks().forEach((t) => t.stop()); };
  }, [supported]); // eslint-disable-line react-hooks/exhaustive-deps
  if (state === 'unsupported' || state === 'denied') {
    return (
      <div style={{ background: '#111827', color: '#fff', padding: '28px 20px', textAlign: 'center', fontSize: 13, lineHeight: 1.5 }}>
        <Icon name="scan" size={28} color="#fff" />
        <div style={{ marginTop: 8 }}>{state === 'denied' ? 'Camera access was blocked. Allow the camera for this site in your browser settings, or search below.' : 'This phone cannot open the camera from the browser. Search by name or type the code below.'}</div>
      </div>
    );
  }
  return (
    <div style={{ background: '#111827', position: 'relative', height: 300, overflow: 'hidden' }}>
      <video ref={video} playsInline muted style={{ width: '100%', height: '100%', objectFit: 'cover' }} />
      <div style={{ position: 'absolute', inset: '18% 12%', border: '2px solid rgba(255,255,255,.75)', borderRadius: 12 }} />
      <div style={{ position: 'absolute', left: '12%', right: '12%', height: 2, background: '#0072F5', boxShadow: '0 0 12px #3E88FF', animation: 'tsScan 2.4s ease-in-out infinite' }} />
      <div style={{ position: 'absolute', bottom: 12, left: 0, right: 0, textAlign: 'center', color: '#fff', fontSize: 13 }}>{state === 'on' ? 'Point at a barcode or QR label' : 'Starting camera…'}</div>
    </div>
  );
}

function ItemCard({ item: it, onSell, onAgain }: { item: Item; onSell: () => void; onAgain: () => void }) {
  const { data: inv } = useInventory();
  const { loc } = useM();
  const nav = useNavigate();
  if (!inv) return null;
  const here = Number(it.qty?.[loc] || 0);
  const branch = inv.locations.find((l) => l.id === loc)?.name || 'here';
  const fefo = inv.batches.filter((b) => b.item_id === it.id && b.location_id === loc && !b.quarantined && Number(b.qty_remaining) > 0 && b.expiry_date)
    .sort((a, b) => a.expiry_date!.localeCompare(b.expiry_date!))[0];
  const days = fefo ? daysBetween(inv.today, fefo.expiry_date!) : null;
  const costs = inv.can_see_costs;
  const margin = costs && it.wac != null && Number(it.price) > 0 ? ((Number(it.price) - Number(it.wac)) / Number(it.price)) * 100 : null;
  return (
    <div className="m-pad stack rise" style={{ gap: 14, flex: 1 }}>
      <div className="row" style={{ gap: 12 }}>
        <Thumb name={it.name} path={it.photo_path} size={64} radius={12} />
        <div className="grow"><div style={{ fontSize: 16, fontWeight: 600 }}>{it.name}</div><div className="muted mono" style={{ fontSize: 12 }}>{it.barcode || it.qr_code}</div></div>
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
        <Stat label={`On hand · ${branch}`} value={qtyLabel(it, here).split(' · ')[0]} sub={it.pack_size > 1 ? qtyLabel(it, here).split(' · ')[1] : undefined} />
        <Stat label="Sells at" value={`${N(it.price)} / ${suAbbr(it.selling_unit)}`} />
        {costs && <Stat label="Avg cost" value={N(it.wac)} />}
        {costs && <Stat label="Margin" value={P(margin)} color={marginColor(margin, Number(inv.org.margin_threshold))} />}
      </div>
      {fefo && days != null && days <= 90 && (
        <div className={'alert ' + (days < 0 ? 'alert-red' : 'alert-yellow')}>
          {days < 0 ? `Batch ${fefo.batch_no} expired on ${fmtDay(fefo.expiry_date)}. Do not sell it; tell the owner so it can be quarantined.`
            : `Batch ${fefo.batch_no} (${Number(fefo.qty_remaining)} ${pluralUnit(it.selling_unit, Number(fefo.qty_remaining))}) expires in ${days} day${days === 1 ? '' : 's'}. Sell this batch first.`}
        </div>
      )}
      <div className="muted" style={{ fontSize: 12 }}>{it.pack_size > 1 ? `1 ${it.purchase_unit.toLowerCase()} = ${it.pack_size} ${pluralUnit(it.selling_unit, it.pack_size)}` : `Sold by the ${it.selling_unit}`}{!costs ? ' · cost and margin hidden for your role' : ''}</div>
      <div className="stack" style={{ gap: 8, marginTop: 'auto' }}>
        {can(inv, 'record_sales') && <button className="m-btn" onClick={onSell}>Record sale</button>}
        {can(inv, 'receive_stock') && <button className="m-btn secondary" onClick={() => nav('/m/receive', { state: { item: it.id } })}>Receive stock</button>}
        <button className="m-btn ghost" onClick={onAgain}>Scan another</button>
      </div>
    </div>
  );
}
