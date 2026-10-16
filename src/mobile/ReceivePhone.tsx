import { useEffect, useRef, useState } from 'react';
import { useLocation } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { can, useInventory, useSession } from '../state/session';
import { cleanError } from '../lib/supabase';
import { N, N2 } from '../lib/format';
import { puAbbr, suAbbr } from '../lib/domain';
import type { Receipt } from '../lib/types';
import {
  blankLine, compressImage, lineItem, loadReceipt, postReceipt, readInvoice, readingLabel, saveDraft, startReceipt, toDraft, totals, unitLabel, uploadDocument,
  type DraftLine, type Source,
} from '../lib/receive';
import { Icon } from '../components/Icon';
import { Spinner } from '../components/ui';
import { BranchChip, MTop, QueueBanner, useM } from './ctx';
import { Done } from './common';
import { enqueue } from './queue';

type Stage = 'pick' | 'reading' | 'review' | 'posting' | 'posted' | 'queued' | 'sent';

export default function ReceiveScreen() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const { loc, queue } = useM();
  const qc = useQueryClient();
  const location = useLocation();
  const manualItem = (location.state as any)?.item as string | undefined;
  const [mode, setMode] = useState<Source>('hand');
  const [stage, setStage] = useState<Stage>('pick');
  const [receipt, setReceipt] = useState<Receipt | null>(null);
  const [lines, setLines] = useState<DraftLine[]>([]);
  const [vendor, setVendor] = useState<{ id: string | null; name: string }>({ id: null, name: '' });
  const [note, setNote] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [posted, setPosted] = useState<{ ref: string; gross: number } | null>(null);
  const [editing, setEditing] = useState<string | null>(null);
  const cam = useRef<HTMLInputElement>(null);
  const pdf = useRef<HTMLInputElement>(null);
  const started = useRef(false);

  useEffect(() => {
    if (!manualItem || started.current || !inv || !orgId || !queue.online) return;
    started.current = true;
    (async () => {
      setStage('reading');
      try {
        const r = await startReceipt({ orgId, mode: 'manual', location: loc });
        const it = inv.items.find((i) => i.id === manualItem) || null;
        setReceipt(await loadReceipt(r.id)); setLines([blankLine(1, it)]); setVendor({ id: it?.preferred_vendor_id || null, name: inv.vendors.find((v) => v.id === it?.preferred_vendor_id)?.name || '' });
        setStage('review');
      } catch (e) { setErr(cleanError(e)); setStage('pick'); }
    })();
  }, [manualItem, inv, orgId, queue.online]); // eslint-disable-line react-hooks/exhaustive-deps

  if (!inv) return null;
  if (!can(inv, 'receive_stock')) return <><MTop title="Receive stock" /><div className="m-pad muted">Your role does not receive stock.</div></>;

  async function onFile(file: File) {
    if (!orgId) return;
    setErr(null);
    const blob = await compressImage(file);
    if (!navigator.onLine) {
      await enqueue({ org: orgId, kind: 'receipt', label: 'Invoice photo', detail: mode === 'hand' ? 'Handwritten sheet' : 'Typed invoice', payload: { mode: file.type === 'application/pdf' ? 'typed' : mode, location_id: loc, name: file.name }, author: inv!.me.display_name }, blob);
      setStage('queued'); return;
    }
    setStage('reading');
    try {
      const { path, mime } = await uploadDocument(orgId, blob, file.name);
      const r = await startReceipt({ orgId, mode: file.type === 'application/pdf' ? 'typed' : mode, path, mime, location: loc, device: 'phone' });
      const res = await readInvoice(r.id);
      const full = await loadReceipt(r.id);
      setReceipt(full);
      const ls = toDraft(full.receipt_lines);
      setLines(ls.length ? ls : [blankLine(1)]);
      setVendor({ id: full.vendor_id, name: full.vendor_name || '' });
      setNote(res.ok ? null : (res.error || 'Could not read the invoice.') + ' The photo is saved; the owner can type the lines on the desktop.');
      setStage('review');
      qc.invalidateQueries({ queryKey: ['receipts'] });
    } catch (e) {
      if (!navigator.onLine) {
        await enqueue({ org: orgId, kind: 'receipt', label: 'Invoice photo', detail: mode === 'hand' ? 'Handwritten sheet' : 'Typed invoice', payload: { mode, location_id: loc, name: file.name }, author: inv!.me.display_name }, blob);
        setStage('queued');
      } else { setErr(cleanError(e)); setStage('pick'); }
    }
  }

  const patch = (id: string, p: Partial<DraftLine>) => setLines((ls) => ls.map((l) => (l.id === id ? { ...l, ...p, confirmed: true, touched: !!l.model_reading } : l)));
  const doubt = lines.filter((l) => !l.confirmed).length;
  const newItems = lines.filter((l) => !l.item_id).length;
  const bad = lines.filter((l) => !(Number(l.qty) > 0) || !(Number(l.unit_cost) > 0)).length;
  const vat = vendor.id ? !!inv.vendors.find((v) => v.id === vendor.id)?.vat_registered : !!receipt?.vendor_vat_registered;
  const t = totals(inv, lines, vat);
  const branch = inv.locations.find((l) => l.id === (receipt?.location_id || loc))?.name || '';

  async function finish(post: boolean) {
    if (!receipt) return;
    if (!vendor.id && !vendor.name.trim()) { setErr('Choose or type the vendor first.'); return; }
    setErr(null); setStage('posting');
    try {
      await saveDraft({ receipt, lines, removed: [], memberId: inv!.me.id, header: { vendor_id: vendor.id, vendor_name: vendor.id ? inv!.vendors.find((v) => v.id === vendor.id)?.name || null : vendor.name.trim(), invoice_no: receipt.invoice_no, location_id: receipt.location_id || loc, vendor_vat_registered: vat } });
      if (post) {
        const r = await postReceipt(receipt.id);
        setPosted({ ref: r.journal_ref, gross: Number(r.gross) }); setStage('posted');
      } else setStage('sent');
      ['receipts', 'inv', 'ledger', 'proposals'].forEach((k) => qc.invalidateQueries({ queryKey: [k] }));
    } catch (e) { setErr(cleanError(e)); setStage('review'); }
  }
  const reset = () => { setStage('pick'); setReceipt(null); setLines([]); setNote(null); setErr(null); setPosted(null); setVendor({ id: null, name: '' }); };

  return (
    <>
      <MTop title="Receive stock" right={<BranchChip />} />
      <QueueBanner />
      {stage === 'pick' && (
        <div className="stack" style={{ flex: 1 }}>
          <div className="m-pad"><div className="seg" style={{ width: '100%' }}>
            <button className={mode === 'hand' ? 'on' : ''} style={{ flex: 1 }} onClick={() => setMode('hand')}>Handwritten sheet</button>
            <button className={mode === 'typed' ? 'on' : ''} style={{ flex: 1 }} onClick={() => setMode('typed')}>Typed invoice</button>
          </div></div>
          <div style={{ flex: 1, minHeight: 280, background: '#1F2937', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 16, padding: 24, textAlign: 'center' }}>
            <div style={{ width: '70%', maxWidth: 240, aspectRatio: '3/4', border: '2px solid rgba(255,255,255,.7)', borderRadius: 12, display: 'grid', placeItems: 'center', color: 'rgba(255,255,255,.75)', fontSize: 13, padding: 16 }}>
              {mode === 'hand' ? 'Hold the sheet flat with every line in frame' : 'Fit the whole invoice in frame'}
            </div>
          </div>
          <div className="m-pad stack" style={{ alignItems: 'center', gap: 10 }}>
            <div className="muted" style={{ fontSize: 12 }}>{mode === 'hand' ? 'We read "doz", "ctn", "half bag"' : 'Prism reads every line and splits input VAT'}{!queue.online ? ' · saved on the phone until data returns' : ''}</div>
            <button aria-label="Take photo" onClick={() => cam.current?.click()} style={{ width: 68, height: 68, borderRadius: '50%', border: '4px solid #E6E6E6', background: '#0072F5', display: 'grid', placeItems: 'center', cursor: 'pointer' }}><Icon name="camera" size={26} color="#fff" /></button>
            {mode === 'typed' && <button className="btn btn-ghost btn-sm" onClick={() => pdf.current?.click()}>Choose a PDF instead</button>}
            {err && <div className="alert alert-red" style={{ width: '100%' }}>{err}</div>}
            <input ref={cam} type="file" accept="image/*" capture="environment" hidden onChange={(e) => { const f = e.target.files?.[0]; if (f) onFile(f); e.target.value = ''; }} />
            <input ref={pdf} type="file" accept="application/pdf,image/*" hidden onChange={(e) => { const f = e.target.files?.[0]; if (f) onFile(f); e.target.value = ''; }} />
          </div>
        </div>
      )}
      {stage === 'reading' && (
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 14, padding: 24, textAlign: 'center' }}>
          <Spinner /><div style={{ fontSize: 15, fontWeight: 600 }}>{manualItem ? 'Opening a receipt…' : 'Reading the lines…'}</div>
          <div className="muted" style={{ fontSize: 13, lineHeight: 1.5 }}>Matching handwriting against your item master and this vendor's last invoices.</div>
        </div>
      )}
      {(stage === 'review' || stage === 'posting') && receipt && (
        <>
          <div className="m-pad stack" style={{ gap: 10, flex: 1, overflowY: 'auto' }}>
            <div className="muted" style={{ fontSize: 12 }}>{receipt.ref} · {branch} · {lines.length} line{lines.length === 1 ? '' : 's'}{doubt ? ` · ${doubt} need${doubt === 1 ? 's' : ''} a tap` : ''}</div>
            {note && <div className="alert alert-blue">{note}</div>}
            <select className="input" value={vendor.id || ''} onChange={(e) => setVendor({ id: e.target.value || null, name: inv.vendors.find((v) => v.id === e.target.value)?.name || vendor.name })} aria-label="Vendor">
              <option value="">{vendor.name && !vendor.id ? `New vendor: ${vendor.name}` : 'Choose vendor…'}</option>
              {inv.vendors.map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}
            </select>
            {!vendor.id && <input className="input" placeholder="Vendor name" value={vendor.name} onChange={(e) => setVendor({ id: null, name: e.target.value })} />}
            {lines.map((l) => {
              const it = lineItem(inv, l);
              const c = Number(l.confidence);
              return (
                <div key={l.id} className="m-card" style={{ borderColor: !l.confirmed ? '#FDE68A' : '#E6E6E6' }}>
                  <div className="row" style={{ justifyContent: 'space-between' }}>
                    {l.raw_text ? <span className={receipt.source === 'photo_handwritten' ? 'handwrite' : 'mono'} style={{ fontSize: 12, color: '#6B7280', background: '#F5F1E6', borderRadius: 6, padding: '3px 8px' }}>{l.raw_text}</span> : <span className="faint" style={{ fontSize: 12 }}>Entered by hand</span>}
                    <span style={{ fontSize: 11, fontWeight: 700, color: c >= 85 ? '#15803D' : c >= 60 ? '#A16207' : '#DC2626' }}>{c}%</span>
                  </div>
                  {editing === l.id || !l.item_id && !l.new_item ? (
                    <div className="stack" style={{ gap: 8, marginTop: 8 }}>
                      <select className="input" value={l.item_id || ''} onChange={(e) => patch(l.id, { item_id: e.target.value || null, new_item: null })} aria-label="Item">
                        <option value="">{l.new_item ? `New: ${l.new_item.name}` : 'Choose item…'}</option>
                        {inv.items.map((i) => <option key={i.id} value={i.id}>{i.name}</option>)}
                      </select>
                      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 8 }}>
                        <input className="input" type="number" inputMode="decimal" value={l.qty} onChange={(e) => patch(l.id, { qty: e.target.value as any })} aria-label="Quantity" />
                        <select className="input" value={l.unit_kind} onChange={(e) => patch(l.id, { unit_kind: e.target.value as any })} aria-label="Unit">
                          <option value="purchase">{it ? puAbbr(it.purchase_unit) : 'ctn'}</option><option value="selling">{it ? suAbbr(it.selling_unit) : 'unit'}</option>
                        </select>
                        <input className="input" type="number" inputMode="decimal" value={l.unit_cost} onChange={(e) => patch(l.id, { unit_cost: e.target.value as any })} aria-label="Unit cost" placeholder="₦ each" />
                      </div>
                      <button className="btn btn-xs btn-secondary" style={{ alignSelf: 'flex-start' }} onClick={() => setEditing(null)}>Done</button>
                    </div>
                  ) : (
                    <button onClick={() => setEditing(l.id)} style={{ display: 'block', width: '100%', textAlign: 'left', border: 0, background: 'transparent', padding: 0, marginTop: 8, font: 'inherit', cursor: 'pointer' }}>
                      <div style={{ fontSize: 13, fontWeight: 600 }}>{readingLabel(it, l)}</div>
                      <div className="muted" style={{ fontSize: 12, marginTop: 2 }}>{N2(l.unit_cost)} per {unitLabel(it, l)} · {N(Number(l.qty) * Number(l.unit_cost))}{!l.item_id ? ' · new item, finish on desktop' : ''}</div>
                    </button>
                  )}
                  {!l.confirmed && editing !== l.id && (
                    <div className="row" style={{ gap: 6, marginTop: 10 }}>
                      <button className="btn btn-xs" style={{ flex: 1, border: '1px solid #0072F5', background: '#F0F7FF', color: '#0072F5' }} onClick={() => patch(l.id, {})}>Looks right</button>
                      {l.alt_reading ? <button className="btn btn-xs btn-secondary" style={{ flex: 1 }} onClick={() => patch(l.id, { qty: Number(l.alt_reading!.qty), unit_kind: l.alt_reading!.unit_kind || l.unit_kind })}>{l.alt_reading.label}</button>
                        : <button className="btn btn-xs btn-secondary" style={{ flex: 1 }} onClick={() => setEditing(l.id)}>Fix it</button>}
                    </div>
                  )}
                  {l.confirmed && l.touched && <div style={{ fontSize: 12, color: '#15803D', marginTop: 8, fontWeight: 600 }}>Confirmed · saved as a training correction</div>}
                </div>
              );
            })}
            <button className="btn btn-ghost btn-sm" style={{ alignSelf: 'flex-start' }} onClick={() => { const nl = blankLine(lines.length + 1); setLines((ls) => [...ls, nl]); setEditing(nl.id); }}><Icon name="plus" size={14} />Add a line</button>
            {err && <div className="alert alert-red">{err}</div>}
          </div>
          <div className="m-foot stack" style={{ gap: 8 }}>
            {doubt ? <button className="m-btn" disabled>Confirm doubtful lines first</button>
              : newItems || bad ? <>
                  <div className="muted" style={{ fontSize: 12, textAlign: 'center' }}>{newItems ? `${newItems} new item${newItems === 1 ? ' needs' : 's need'} pack size and price on the desktop.` : `${bad} line${bad === 1 ? ' needs' : 's need'} a quantity and cost.`}</div>
                  <button className="m-btn" disabled={stage === 'posting' || !!bad && !newItems} onClick={() => finish(false)}>{stage === 'posting' ? 'Saving…' : 'Send to the owner for review'}</button>
                </>
              : <button className="m-btn" disabled={stage === 'posting'} onClick={() => finish(true)}>{stage === 'posting' ? 'Posting…' : `Post ${N(t.gross)} to books`}</button>}
          </div>
        </>
      )}
      {stage === 'posted' && posted && <Done title={`Posted · ${posted.ref}`} body={`${lines.length} item${lines.length === 1 ? '' : 's'} received at ${branch}${receipt?.document_path ? '. Photo attached to the journal' : ''}. The owner sees it in the ledger.`} action="Receive another" onAction={reset} />}
      {stage === 'sent' && <Done title="Sent for review" body={`${receipt?.ref} is waiting in Receive stock on the desktop. Nothing is in stock until it is posted.`} action="Receive another" onAction={reset} icon="clock" tone="amber" />}
      {stage === 'queued' && <Done title="Saved on this phone" body="No data right now. The photo will upload, be read and land in Receive stock for review as soon as data returns." action="Photograph another" onAction={reset} icon="clock" tone="amber" />}
    </>
  );
}

