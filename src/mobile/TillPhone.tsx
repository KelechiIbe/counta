// The phone as a till: point the camera at each product's barcode and it goes into the basket, the way a POS scanner
// works. An unknown barcode offers to add the product there and then. The basket posts as one receipt; offline it waits
// on the phone and posts in order when data returns.
import { useEffect, useMemo, useRef, useState } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { can, useInventory } from '../state/session';
import { N, num } from '../lib/format';
import { pluralUnit } from '../lib/domain';
import type { Item } from '../lib/types';
import { Icon } from '../components/Icon';
import { Thumb } from '../components/ui';
import { BranchChip, MTop, QueueBanner, useM } from './ctx';
import { Done, ItemSearch } from './common';
import { enqueue } from './queue';
import { Camera } from './Scan';

type Line = { item: Item; qty: number };
type Method = 'cash' | 'transfer' | 'pos';
const METHODS: [Method, string][] = [['cash', 'Cash'], ['transfer', 'Transfer'], ['pos', 'POS']];
const KEY = 'counta.m.basket';

// A short beep for each scan, so the cashier hears it went in without looking.
function beep(ok: boolean) {
  try {
    const A = (window as any).AudioContext || (window as any).webkitAudioContext;
    if (!A) return;
    const ctx = new A(); const o = ctx.createOscillator(); const g = ctx.createGain();
    o.frequency.value = ok ? 1320 : 300; g.gain.value = 0.08; o.connect(g); g.connect(ctx.destination);
    o.start(); o.stop(ctx.currentTime + (ok ? 0.09 : 0.25)); o.onended = () => ctx.close();
  } catch { /* no sound */ }
}

export function TillScreen() {
  const { data: inv } = useInventory();
  const { loc, queue } = useM();
  const nav = useNavigate();
  const where = useLocation();
  // The basket survives a trip to add a product it did not know.
  const [lines, setLines] = useState<Line[]>(() => {
    try { const raw = JSON.parse(sessionStorage.getItem(KEY) || '[]') as { id: string; qty: number }[]; return raw.map((r) => ({ item: { id: r.id } as Item, qty: r.qty })); } catch { return []; }
  });
  const [unknown, setUnknown] = useState<string | null>(null);
  const [method, setMethod] = useState<Method>('cash');
  const [camera, setCamera] = useState(true);
  const [done, setDone] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const flash = useRef<string | null>(null);
  const [, force] = useState(0);
  // Items stored by id are matched to the live list once it loads (and after a product is added).
  const live = useMemo(() => lines.map((l) => ({ ...l, item: inv?.items.find((i) => i.id === l.item.id) || l.item })).filter((l) => l.item.name), [lines, inv]);
  useEffect(() => { try { sessionStorage.setItem(KEY, JSON.stringify(lines.map((l) => ({ id: l.item.id, qty: l.qty })))); } catch { /* ignore */ } }, [lines]);
  const byCode = (code: string) => inv?.items.find((i) => i.barcode === code || i.qr_code === code || i.sku === code) || null;
  const add = (it: Item, n = 1) => {
    setLines((ls) => {
      const i = ls.findIndex((l) => l.item.id === it.id);
      if (i >= 0) { const c = [...ls]; c[i] = { ...c[i], qty: c[i].qty + n }; return c; }
      return [...ls, { item: it, qty: n }];
    });
    flash.current = it.id; force((x) => x + 1);
    window.setTimeout(() => { flash.current = null; force((x) => x + 1); }, 700);
  };
  // Coming back from adding a product, or from "Sell it", the code goes straight into the basket.
  useEffect(() => {
    const code = new URLSearchParams(where.search).get('code');
    if (!code || !inv) return;
    const it = byCode(code);
    if (it) add(it);
    nav('/m/till', { replace: true });
  }, [where.search, !!inv]); // eslint-disable-line react-hooks/exhaustive-deps
  if (!inv) return null;
  if (!can(inv, 'record_sales')) return <><MTop title="Scan to sell" /><div className="m-pad muted">Your role does not record sales.</div></>;
  const total = live.reduce((a, l) => a + l.qty * Number(l.item.price), 0);
  const noPrice = live.filter((l) => !(Number(l.item.price) > 0));
  const canAdd = can(inv, 'add_items') || can(inv, 'edit_prices');

  function scanned(code: string) {
    const it = byCode(code);
    if (it) { add(it); setUnknown(null); beep(true); navigator.vibrate?.(40); }
    else { setUnknown(code); beep(false); navigator.vibrate?.([60, 60, 60]); }
  }
  async function checkout() {
    if (!live.length || noPrice.length || busy || !inv) return;
    setBusy(true);
    const n = live.reduce((a, l) => a + l.qty, 0);
    await enqueue({
      org: inv.org.id, kind: 'till', label: 'Till sale', author: inv.me.display_name,
      detail: `${num(n)} ${n === 1 ? 'item' : 'items'} · ${N(total)} · ${METHODS.find((m) => m[0] === method)![1]}`,
      payload: { location_id: loc, method, lines: live.map((l) => ({ item_id: l.item.id, qty: l.qty, unit: 'selling' })) },
    });
    setBusy(false);
    setDone(`${num(n)} ${n === 1 ? 'item' : 'items'}, ${N(total)} by ${METHODS.find((m) => m[0] === method)![1].toLowerCase()}.${method === 'cash' ? '' : ' Confirm the money in Sales once it lands.'}`);
    setLines([]); setUnknown(null); setMethod('cash');
  }

  if (done) return <><MTop title="Scan to sell" right={<BranchChip />} /><QueueBanner /><Done title="Sold" body={done + ' It posts to the books as soon as there is data.'} action="Next customer" onAction={() => setDone(null)} /></>;
  return (
    <>
      <MTop title="Scan to sell" right={<BranchChip />} />
      <QueueBanner />
      {camera && <Camera height={200} paused={busy} onCode={scanned} />}
      <div className="m-pad stack" style={{ gap: 10, paddingBottom: 140 }}>
        <div className="row" style={{ gap: 8 }}>
          <div className="grow" style={{ minWidth: 0 }}><ItemSearch onPick={(i) => add(i)} placeholder="Or search by name" /></div>
          <button className="btn btn-secondary btn-sm" onClick={() => setCamera(!camera)} aria-label={camera ? 'Hide the camera' : 'Show the camera'}><Icon name="scan" size={14} />{camera ? 'Hide' : 'Camera'}</button>
          <button className="btn btn-secondary btn-sm" onClick={() => nav('/m/sell')} aria-label="Record a sale by voice" title="Talk instead"><Icon name="mic" size={14} /></button>
        </div>
        {unknown && (
          <div className="alert alert-yellow row" style={{ gap: 10, alignItems: 'center' }}>
            <span className="grow" style={{ minWidth: 0 }}>No product uses <span className="mono">{unknown}</span>.</span>
            {canAdd ? <button className="btn btn-primary btn-xs" onClick={() => nav(`/m/add?barcode=${encodeURIComponent(unknown)}&then=sell`)}>Add it</button>
              : <span className="faint" style={{ fontSize: 11 }}>Ask someone who adds products.</span>}
          </div>
        )}
        {!live.length ? (
          <div className="muted" style={{ textAlign: 'center', fontSize: 13, padding: '18px 0' }}>Scan each product. Scanning one twice adds another.</div>
        ) : live.map((l) => (
          <div key={l.item.id} className="m-card row" style={{ gap: 10, padding: 10, transition: 'background .3s', background: flash.current === l.item.id ? '#ECFDF3' : undefined }}>
            <Thumb name={l.item.name} path={l.item.photo_path} size={40} radius={8} />
            <div className="grow" style={{ minWidth: 0 }}>
              <div className="ellipsis" style={{ fontSize: 14, fontWeight: 600 }}>{l.item.name}</div>
              <div className="faint" style={{ fontSize: 11 }}>{Number(l.item.price) > 0 ? `${N(l.item.price)} per ${l.item.selling_unit}` : 'No selling price yet'}</div>
            </div>
            <div className="row" style={{ gap: 4, flex: 'none' }}>
              <button className="btn btn-secondary btn-xs" aria-label={`One less ${l.item.name}`} onClick={() => setLines((ls) => ls.flatMap((x) => (x.item.id !== l.item.id ? [x] : x.qty > 1 ? [{ ...x, qty: x.qty - 1 }] : [])))}><Icon name="minus" size={12} /></button>
              <b className="num" style={{ minWidth: 26, textAlign: 'center' }}>{l.qty}</b>
              <button className="btn btn-secondary btn-xs" aria-label={`One more ${l.item.name}`} onClick={() => add(l.item)}><Icon name="plus" size={12} /></button>
            </div>
          </div>
        ))}
        {noPrice.length > 0 && <div className="alert alert-yellow" style={{ fontSize: 12 }}>{noPrice.map((l) => l.item.name).join(', ')} {noPrice.length === 1 ? 'has' : 'have'} no selling price. Remove {noPrice.length === 1 ? 'it' : 'them'}, or ask the owner to set one.</div>}
      </div>
      {live.length > 0 && (
        <div style={{ position: 'sticky', bottom: 0, background: '#fff', borderTop: '1px solid #E6E6E6', padding: '10px 16px', display: 'flex', flexDirection: 'column', gap: 8 }}>
          <div className="row" style={{ justifyContent: 'space-between' }}>
            <span className="muted" style={{ fontSize: 13 }}>{num(live.reduce((a, l) => a + l.qty, 0))} {pluralUnit('item', live.reduce((a, l) => a + l.qty, 0))}</span>
            <b className="num" style={{ fontSize: 20 }}>{N(total)}</b>
          </div>
          <div className="row" style={{ gap: 6 }} role="radiogroup" aria-label="How they paid">
            {METHODS.map(([m, l]) => <button key={m} role="radio" aria-checked={method === m} className={'pill' + (method === m ? ' on' : '')} style={{ flex: 1, justifyContent: 'center' }} onClick={() => setMethod(m)}>{l}</button>)}
          </div>
          <div className="row" style={{ gap: 8 }}>
            <button className="m-btn secondary" style={{ flex: 1 }} onClick={() => { setLines([]); setUnknown(null); }}>Clear</button>
            <button className="m-btn" style={{ flex: 2 }} disabled={busy || noPrice.length > 0} onClick={checkout}>Charge {N(total)}</button>
          </div>
          {!queue.online && <div className="faint" style={{ fontSize: 11, textAlign: 'center' }}>Offline: the sale saves on this phone and posts when data returns.</div>}
        </div>
      )}
    </>
  );
}
