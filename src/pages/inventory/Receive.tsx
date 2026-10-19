import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { useLocation, useNavigate, useSearchParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { can, useInventory, useSession, useToast } from '../../state/session';
import { useReceipts } from '../../lib/queries';
import { cleanError, signedDoc, supabase } from '../../lib/supabase';
import { N, N2, fmtDay, num, plural } from '../../lib/format';
import { qtyLabel } from '../../lib/domain';
import type { Item, Receipt } from '../../lib/types';
import {
  DOUBT, blankLine, compressImage, lineItem, lineProblems, loadReceipt, postReceipt, readInvoice, saveDraft, startReceipt,
  toDraft, totals, unitLabel, unitOptions, uploadDocument, vatTreatment, type DraftLine, type Source,
} from '../../lib/receive';
import { Icon } from '../../components/Icon';
import { Alert, Chip, Empty, Label, Modal, SkeletonRows, Spinner, XButton } from '../../components/ui';
import JournalDrawer from '../../components/JournalDrawer';
import { acct, accountName, useAccounts, useItemAccounts, usePostingMap } from '../../lib/accounts';
import { vatPct } from '../../lib/vat';

const STATUS: Record<string, string> = { reading: 'Reading', needs_review: 'Needs review', posted: 'Posted', discarded: 'Discarded' };
const SRC: Record<string, string> = { pdf: 'Typed · PDF', photo_typed: 'Typed · photo', photo_handwritten: 'Handwritten · OCR', manual: 'Manual' };
const COLS = '110px 120px minmax(200px,1.5fr) 150px 70px 120px 110px 130px';

function EntryCard({ icon, title, body, onClick, disabled }: { icon: string; title: string; body: string; onClick: () => void; disabled?: boolean }) {
  return (
    <button className="card entry-card" onClick={onClick} disabled={disabled}
      style={{ padding: 20, cursor: disabled ? 'not-allowed' : 'pointer', display: 'flex', gap: 14, alignItems: 'flex-start', textAlign: 'left', background: '#fff', opacity: disabled ? 0.6 : 1 }}>
      <span style={{ width: 44, height: 44, borderRadius: 12, background: '#F0F7FF', display: 'grid', placeItems: 'center', flex: 'none' }}><Icon name={icon} size={20} color="#0072F5" /></span>
      <span><span style={{ display: 'block', fontSize: 15, fontWeight: 600, color: '#111827' }}>{title}</span><span style={{ display: 'block', fontSize: 13, color: '#6B7280', marginTop: 4, lineHeight: 1.45 }}>{body}</span></span>
    </button>
  );
}

export default function Receive() {
  const { data: inv } = useInventory();
  const location = useLocation();
  const nav = useNavigate();
  const st = (location.state || {}) as { open?: string; manualItem?: string; po?: string };
  const [params, setParams] = useSearchParams();
  const receipts = useReceipts();
  const [flow, setFlow] = useState<{ mode: Source; receiptId?: string; po?: string; itemId?: string } | null>(null);
  const [journal, setJournal] = useState<string | null>(null);

  useEffect(() => {
    const q = params.get('open');
    if (q) { setFlow({ mode: 'manual', receiptId: q }); setParams({}, { replace: true }); }
  }, [params.get('open')]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (st.open) setFlow({ mode: 'manual', receiptId: st.open });
    else if (st.po) setFlow({ mode: 'manual', po: st.po });
    else if (st.manualItem) setFlow({ mode: 'manual', itemId: st.manualItem });
    if (st.open || st.po || st.manualItem) nav(location.pathname, { replace: true, state: null });
  }, [st.open, st.po, st.manualItem]); // eslint-disable-line react-hooks/exhaustive-deps

  if (!inv) return null;
  const allowed = can(inv, 'receive_stock');
  const rows = receipts.data || [];
  return (
    <div className="container">
      {!allowed && <Alert kind="yellow" icon="shield">Your role can see receipts but not post them. Ask the owner for the Receive stock permission.</Alert>}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(260px,1fr))', gap: 14 }}>
        <EntryCard icon="file" title="Typed invoice" disabled={!allowed} onClick={() => setFlow({ mode: 'typed' })}
          body="PDF or photo of a distributor bill. Prism reads every line and splits input VAT." />
        <EntryCard icon="camera" title="Handwritten sheet" disabled={!allowed} onClick={() => setFlow({ mode: 'hand' })}
          body={'Market duplicate-booklet invoice. OCR trained on "2 doz", "5 ctn", "half bag".'} />
        <EntryCard icon="pencil" title="Enter manually" disabled={!allowed} onClick={() => setFlow({ mode: 'manual' })}
          body="Type the lines yourself. Same journal preview before anything posts." />
      </div>
      <div className="card" style={{ overflow: 'hidden' }}>
        <div className="card-hd"><Label>Recent receipts</Label><span className="faint" style={{ fontSize: 12 }}>Needs review rows reopen the flow · posted rows open their journal</span></div>
        <div className="tbl">
          <div className="tr head th rsp" style={{ gridTemplateColumns: COLS, minWidth: 960 }}>
            <span>Ref</span><span>Date</span><span>Vendor</span><span>Source</span><span>Lines</span><span className="right">Total</span><span className="right">Input VAT</span><span>Status</span>
          </div>
          {receipts.isLoading && <SkeletonRows n={4} />}
          {rows.map((r) => {
            const open = r.status === 'needs_review' || r.status === 'reading';
            const click = open ? () => allowed && setFlow({ mode: r.source === 'photo_handwritten' ? 'hand' : r.source === 'manual' ? 'manual' : 'typed', receiptId: r.id })
              : () => inv.can_see_costs && setJournal(r.ref);
            return (
              <div key={r.id} className="tr click rsp" onClick={click} style={{ gridTemplateColumns: COLS, minWidth: 960 }}>
                <span style={{ fontWeight: 600, color: '#0072F5' }}>{r.ref}</span>
                <span className="muted">{fmtDay(r.invoice_date || r.created_at)}</span>
                <span style={{ fontWeight: 500 }} className="ellipsis m-main m-first">{r.vendor_name || 'Vendor not set'}</span>
                <span className="ink3 hide-sm">{SRC[r.source]}</span>
                <span className="ink3" data-label="Lines">{r.receipt_lines?.length ?? '—'}</span>
                <span className={'right num' + (r.status === 'posted' ? '' : ' hide-sm')} style={{ fontWeight: 600 }}>{r.status === 'posted' ? N(r.gross) : '—'}</span>
                <span className="right num ink3 hide-sm">{r.status === 'posted' && Number(r.input_vat) ? N(r.input_vat) : '—'}</span>
                <span className="m-end"><Chip label={STATUS[r.status]} /></span>
              </div>
            );
          })}
          {receipts.data && !rows.length && <div className="muted" style={{ padding: 24, fontSize: 14 }}>No receipts yet. Photograph a supplier invoice to get started.</div>}
        </div>
      </div>
      {flow && <ReceiveFlow key={flow.receiptId || flow.mode + (flow.po || '') + (flow.itemId || '')} {...flow} onClose={() => setFlow(null)}
        onAnother={(m) => setFlow({ mode: m })} onJournal={(ref) => setJournal(ref)} />}
      {journal && <JournalDrawer journalRef={journal} onClose={() => setJournal(null)} />}
    </div>
  );
}

// ---------------------------------------------------------------- the flow
type Step = 'capture' | 'reading' | 'lines' | 'journal' | 'posting' | 'posted';
const STEPS: [Step[], string][] = [[['capture'], 'Capture'], [['reading'], 'Read'], [['lines'], 'Confirm lines'], [['journal', 'posting', 'posted'], 'Post']];

export function ReceiveFlow({ mode, receiptId, po, itemId, onClose, onAnother, onJournal }: {
  mode: Source; receiptId?: string; po?: string; itemId?: string; onClose: () => void; onAnother: (m: Source) => void; onJournal: (ref: string) => void;
}) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const nav = useNavigate();
  const [step, setStep] = useState<Step>(receiptId || mode === 'manual' ? 'reading' : 'capture');
  const [receipt, setReceipt] = useState<Receipt | null>(null);
  const [lines, setLines] = useState<DraftLine[]>([]);
  const [removed, setRemoved] = useState<string[]>([]);
  const [header, setHeader] = useState({ vendor_id: null as string | null, vendor_name: '' as string, invoice_no: '', location_id: inv?.me.location_id || inv?.locations.find((l) => l.is_main)?.id || inv?.locations[0]?.id || null, vendor_vat_registered: false });
  const [docUrl, setDocUrl] = useState<string | null>(null);
  const [aiNote, setAiNote] = useState<{ kind: 'blue' | 'yellow' | 'red'; text: string } | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<{ journal_ref: string; gross: number; proposals: number } | null>(null);
  const [showDoc, setShowDoc] = useState(false);
  const [confirmDiscard, setConfirmDiscard] = useState(false);
  const [readingLabel, setReadingLabel] = useState('Reading the invoice…');
  const dirty = useRef(false);
  const started = useRef(false);

  const refresh = () => Promise.all(['receipts', 'inv', 'ledger', 'activity', 'proposals', 'pos'].map((k) => qc.invalidateQueries({ queryKey: [k] })));

  function adopt(r: Receipt, note?: typeof aiNote) {
    setReceipt(r);
    let ls = toDraft(r.receipt_lines);
    if (!ls.length && r.status !== 'reading') ls = [blankLine(1, itemId ? inv?.items.find((i) => i.id === itemId) : null)];
    setLines(ls);
    setHeader({
      vendor_id: r.vendor_id, vendor_name: r.vendor_name || '', invoice_no: r.invoice_no || '', vendor_vat_registered: r.vendor_vat_registered,
      location_id: r.location_id || inv?.me.location_id || inv?.locations[0]?.id || null,
    });
    if (r.document_path) signedDoc(r.document_path).then(setDocUrl);
    if (note) setAiNote(note);
    else if (r.ai_error) setAiNote({ kind: /not switched on/.test(r.ai_error) ? 'blue' : 'yellow', text: r.ai_error + (r.document_path ? ' The image stays attached; add the lines by hand below.' : '') });
  }

  async function read(r: Receipt) {
    setStep('reading');
    setReadingLabel(r.source === 'photo_handwritten' ? 'Reading the handwriting…' : 'Reading the invoice…');
    const res = await readInvoice(r.id);
    const fresh = await loadReceipt(r.id);
    let note: typeof aiNote = null;
    if (!res.ok) note = { kind: res.reason === 'not_configured' ? 'blue' : 'yellow', text: (res.error || 'Could not read the invoice.') + ' The image stays attached; add the lines by hand below.' };
    else if (res.other_charges?.length) note = { kind: 'blue', text: `The invoice also lists ${res.other_charges.map((c) => `${c.label} ${N(c.amount)}`).join(', ')}. Charges like these belong in landed cost on the Pricing page after you post.` };
    adopt(fresh, note);
    setStep('lines');
  }

  useEffect(() => {
    if (started.current || !orgId) return;
    started.current = true;
    (async () => {
      try {
        if (receiptId) {
          const r = await loadReceipt(receiptId);
          if (r.status === 'reading' && r.document_path) { await read(r); return; }
          if (r.status === 'posted' || r.status === 'discarded') { toast(`This receipt is already ${STATUS[r.status].toLowerCase()}.`, 'err'); onClose(); return; }
          adopt(r); setStep('lines');
        } else if (mode === 'manual') {
          const r = await startReceipt({ orgId, mode: 'manual', location: header.location_id, po: po || null });
          const full = await loadReceipt(r.id);
          adopt(full); setStep('lines'); qc.invalidateQueries({ queryKey: ['receipts'] });
        }
      } catch (e) { toast(cleanError(e), 'err'); onClose(); }
    })();
  }, [orgId]); // eslint-disable-line react-hooks/exhaustive-deps

  async function onFile(file: File) {
    if (!orgId) return;
    if (mode === 'hand' && !file.type.startsWith('image/')) { setErr('Handwritten sheets need a photo (JPG or PNG).'); return; }
    if (file.size > 20 * 1024 * 1024) { setErr('That file is over 20MB. Use a smaller photo or PDF.'); return; }
    setErr(null); setStep('reading'); setReadingLabel('Uploading…');
    try {
      const blob = await compressImage(file);
      const { path, mime } = await uploadDocument(orgId, blob, file.name);
      const r = await startReceipt({ orgId, mode, path, mime, location: header.location_id, vendor: header.vendor_id });
      qc.invalidateQueries({ queryKey: ['receipts'] });
      await read(r);
    } catch (e) { setErr(cleanError(e)); setStep('capture'); }
  }

  const items = inv?.items || [];
  const t = totals(inv, lines, header.vendor_vat_registered, receipt?.invoice_date);
  const postingMap = usePostingMap();
  const itemAccounts = useItemAccounts();
  const accounts = useAccounts();
  const map = postingMap.data;
  const invDefault = acct(map, 'inventory').code;
  const stockByAcct: Record<string, number> = {};
  for (const l of lines) {
    const code = (l.item_id && itemAccounts.data?.[l.item_id]) || invDefault;
    stockByAcct[code] = Math.round(((stockByAcct[code] || 0) + Math.round(Number(l.qty || 0) * Number(l.unit_cost || 0) * 100) / 100) * 100) / 100;
  }
  const doubt = lines.filter((l) => !l.confirmed).length;
  const vendors = inv?.vendors || [];
  const locName = inv?.locations.find((l) => l.id === header.location_id)?.name || 'the branch';

  function patch(id: string, p: Partial<DraftLine>, confirm = true) {
    dirty.current = true; setErr(null);
    setLines((ls) => ls.map((l) => (l.id === id ? { ...l, ...p, ...(confirm ? { confirmed: true, touched: l.model_reading ? true : l.touched } : {}) } : l)));
  }

  function headerOk(): string | null {
    if (!header.location_id) return 'Choose the branch receiving this stock.';
    if (!header.vendor_id && !header.vendor_name.trim()) return 'Choose or name the vendor.';
    return null;
  }

  async function persist(): Promise<boolean> {
    if (!receipt || !inv) return false;
    await saveDraft({
      receipt, lines, removed, memberId: inv.me.id,
      header: { vendor_id: header.vendor_id, vendor_name: header.vendor_id ? vendors.find((v) => v.id === header.vendor_id)?.name || header.vendor_name : header.vendor_name.trim() || null,
        invoice_no: header.invoice_no.trim() || null, location_id: header.location_id, vendor_vat_registered: header.vendor_vat_registered },
    });
    setRemoved([]); dirty.current = false;
    setLines((ls) => ls.map((l) => ({ ...l, receipt_id: receipt.id })));
    return true;
  }

  async function review() {
    const p = lineProblems(lines) || headerOk();
    if (p) { setErr(p); return; }
    setBusy(true);
    try { await persist(); setStep('journal'); } catch (e) { setErr(cleanError(e)); } finally { setBusy(false); }
  }

  async function post() {
    if (!receipt) return;
    setStep('posting'); setErr(null);
    try {
      if (dirty.current) await persist();
      const r = await postReceipt(receipt.id);
      setResult({ journal_ref: r.journal_ref, gross: Number(r.gross), proposals: Number(r.proposals) });
      setStep('posted');
      toast(`Posted ${r.journal_ref} · ${N(r.gross)}`);
      refresh();
    } catch (e) { setErr(cleanError(e)); setStep('journal'); }
  }

  async function close() {
    if (step === 'lines' && receipt && dirty.current) {
      try { await persist(); toast(`${receipt.ref} saved · finish it from Recent receipts`); } catch { /* keep going */ }
    }
    refresh();
    onClose();
  }

  async function discard() {
    if (!receipt) { onClose(); return; }
    if (!confirmDiscard) { setConfirmDiscard(true); return; }
    try {
      await supabase.from('receipts').update({ status: 'discarded' }).eq('id', receipt.id);
      toast(`${receipt.ref} discarded`); refresh(); onClose();
    } catch (e) { toast(cleanError(e), 'err'); }
  }

  const sub = receipt
    ? [receipt.ref, header.vendor_id ? vendors.find((v) => v.id === header.vendor_id)?.name : header.vendor_name || null, receipt.invoice_no, SRC[receipt.source], receipt.invoice_date ? fmtDay(receipt.invoice_date) : null].filter(Boolean).join(' · ')
    : mode === 'typed' ? 'Typed invoice · PDF or photo' : mode === 'hand' ? 'Handwritten sheet · photo' : 'Manual entry';
  const stepIdx = STEPS.findIndex(([s]) => s.includes(step));

  return (
    <Modal onClose={close} width={960} fixed={step !== 'capture' && step !== 'reading' && step !== 'posted'}>
      <div className="modal-hd" style={{ alignItems: 'center', flexWrap: 'wrap' }}>
        <div style={{ flex: 1, minWidth: 200 }}>
          <div className="drawer-title">Receive stock</div>
          <div className="muted" style={{ fontSize: 13, marginTop: 2 }}>{sub}</div>
        </div>
        <div className="row hide-sm" style={{ gap: 14 }}>
          {STEPS.map(([, label], i) => (
            <div key={label} className="row" style={{ gap: 6, fontSize: 12, color: i <= stepIdx ? '#111827' : '#9CA3AF' }}>
              <span style={{ width: 20, height: 20, borderRadius: 10, background: i < stepIdx ? '#15803D' : i === stepIdx ? '#0072F5' : '#F3F4F6', color: i <= stepIdx ? '#fff' : '#9CA3AF', fontSize: 11, fontWeight: 700, display: 'grid', placeItems: 'center' }}>
                {i < stepIdx ? <Icon name="check" size={12} color="#fff" sw={3} /> : i + 1}
              </span>{label}
            </div>
          ))}
        </div>
        <XButton onClick={close} />
      </div>
      <div className="m-pad16" style={{ flex: 1, overflowY: 'auto', padding: '20px 24px', minHeight: 320 }}>
        {step === 'capture' && <Capture mode={mode} header={header} setHeader={setHeader} onFile={onFile} err={err} />}
        {(step === 'reading') && (
          <Centered>
            <Spinner />
            <div style={{ fontSize: 15, fontWeight: 600 }}>{readingLabel}</div>
            <div className="muted" style={{ fontSize: 13, maxWidth: 440, lineHeight: 1.5 }}>Matching each line to your item master and this vendor's last invoices. Lines under {DOUBT}% confidence will be shown beside the image for you to confirm.</div>
          </Centered>
        )}
        {step === 'lines' && receipt && (
          <div className="stack" style={{ gap: 12 }}>
            {aiNote && <Alert kind={aiNote.kind} icon="info">{aiNote.text}</Alert>}
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(180px,1fr))', gap: 10 }}>
              <div>
                <label className="field-label">Vendor</label>
                <select className="input" value={header.vendor_id || '__new'} onChange={(e) => {
                  dirty.current = true;
                  const v = vendors.find((x) => x.id === e.target.value);
                  setHeader((h) => ({ ...h, vendor_id: v?.id || null, vendor_name: v?.name || (h.vendor_id ? '' : h.vendor_name), vendor_vat_registered: v ? v.vat_registered : h.vendor_vat_registered }));
                }}>
                  {vendors.map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}
                  <option value="__new">{header.vendor_name && !header.vendor_id ? `New: ${header.vendor_name}` : 'New vendor…'}</option>
                </select>
                {!header.vendor_id && <input className="input" style={{ marginTop: 6 }} placeholder="Vendor name as on the invoice" value={header.vendor_name} onChange={(e) => { dirty.current = true; setHeader((h) => ({ ...h, vendor_name: e.target.value })); }} />}
              </div>
              <div>
                <label className="field-label">Invoice no.</label>
                <input className="input" value={header.invoice_no} placeholder="Optional" onChange={(e) => { dirty.current = true; setHeader((h) => ({ ...h, invoice_no: e.target.value })); }} />
              </div>
              <div>
                <label className="field-label">Received at</label>
                <select className="input" value={header.location_id || ''} onChange={(e) => { dirty.current = true; setHeader((h) => ({ ...h, location_id: e.target.value })); }}>
                  {inv?.locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}
                </select>
              </div>
              <div style={{ display: 'flex', flexDirection: 'column', justifyContent: 'flex-end', gap: 6 }}>
                <label className="check" style={{ fontSize: 13 }}><input type="checkbox" checked={header.vendor_vat_registered} onChange={(e) => { dirty.current = true; setHeader((h) => ({ ...h, vendor_vat_registered: e.target.checked })); }} />Vendor charges VAT</label>
                {docUrl && <button className="btn btn-secondary btn-xs" style={{ alignSelf: 'flex-start' }} onClick={() => setShowDoc(true)}><Icon name="image" size={14} />View {receipt.document_mime === 'application/pdf' ? 'PDF' : 'photo'}</button>}
              </div>
            </div>
            <div className="row wrap" style={{ justifyContent: 'space-between', marginTop: 4 }}>
              <div className="ink3" style={{ fontSize: 13 }}>{plural(lines.length, 'line')}{doubt ? <> · <b style={{ color: '#C2410C' }}>{doubt} need{doubt === 1 ? 's' : ''} confirmation</b></> : lines.length ? ' · all confirmed' : ''}</div>
              <button className="btn btn-secondary btn-sm" onClick={() => { dirty.current = true; setLines((ls) => [...ls, blankLine(ls.length + 1)]); }}><Icon name="plus" size={14} />Add line</button>
            </div>
            <div className="tbl">
              <div className="th hide-sm" style={{ display: 'grid', gridTemplateColumns: LINE_COLS, gap: 10, padding: '6px 14px', minWidth: 820 }}>
                <span>Item</span><span>Qty</span><span>Unit</span><span>Unit cost</span><span className="right">Line total</span><span>Confidence</span><span />
              </div>
              <div className="stack m-minw0" style={{ gap: 8, minWidth: 820 }}>
                {lines.map((l) => (
                  <LineRow key={l.id} l={l} items={items} item={lineItem(inv, l)} docUrl={docUrl} hand={receipt.source === 'photo_handwritten'}
                    canPrice={can(inv, 'edit_prices')} onPatch={(p, c) => patch(l.id, p, c)}
                    onRemove={() => { dirty.current = true; setLines((ls) => ls.filter((x) => x.id !== l.id)); if (l.receipt_id) setRemoved((r) => [...r, l.id]); }} />
                ))}
              </div>
            </div>
            {!lines.length && <Empty>No lines yet. Add the first line from the invoice.</Empty>}
            {err && <Alert kind="red" icon="alert">{err}</Alert>}
          </div>
        )}
        {(step === 'journal' || step === 'posting') && receipt && (
          <div className="sec" style={{ display: 'grid', gridTemplateColumns: 'minmax(0,1.35fr) minmax(0,1fr)', gap: 20 }}>
            <div>
              <Label>Journal preview · one confirmed action</Label>
              <div className="card" style={{ borderRadius: 12, marginTop: 10, overflow: 'hidden' }}>
                <div className="tr head shade th jr-grid" style={{ gridTemplateColumns: '60px 1fr 110px 110px', padding: '8px 14px' }}><span>Acct</span><span>Account</span><span className="right">Debit</span><span className="right">Credit</span></div>
                <JRow code={acct(map, 'purchases').code} name={acct(map, 'purchases').name} dr={t.net} />
                {header.vendor_vat_registered && t.vat > 0 && <JRow code={acct(map, 'input_vat').code} name={`${acct(map, 'input_vat').name} · ${vatPct(receipt?.invoice_date)}`} dr={t.vat} />}
                <JRow code={acct(map, 'payables').code} name={`${acct(map, 'payables').name} · ${header.vendor_id ? vendors.find((v) => v.id === header.vendor_id)?.name : header.vendor_name || 'vendor'}`} cr={t.gross} />
                {Object.entries(stockByAcct).sort(([a], [b]) => a.localeCompare(b)).map(([code, amt]) => (
                  <JRow key={code} code={code} name={`${code === invDefault ? acct(map, 'inventory').name : accountName(accounts.data, code)} · ${locName}`} dr={amt} />
                ))}
                <JRow code={acct(map, 'inventory_movement').code} name={acct(map, 'inventory_movement').name} cr={t.net} />
              </div>
              <div className="muted" style={{ marginTop: 10, fontSize: 12, lineHeight: 1.45 }}>
                {header.vendor_vat_registered
                  ? `Input VAT flows into this month's VAT position. ${t.vatBase < t.net ? 'Zero-rated and exempt lines are excluded from the ${vatPct(receipt?.invoice_date)} by their item master treatment.' : 'Every line on this invoice is standard-rated.'}`
                  : 'Vendor is not VAT-registered, so no input VAT is claimable on this receipt.'}
                {receipt.document_path ? ' The source image stays attached to the journal as audit evidence.' : ''}
                {` Accounts follow the TaxStreem chart. Purchases and the stock movement both sit in cost of sales, so the profit and loss shows what you bought less what is still on the shelf.`}
              </div>
            </div>
            <div className="stack" style={{ gap: 12 }}>
              <div className="card" style={{ borderRadius: 12, padding: 14 }}>
                <Label>What happens on post</Label>
                <div className="stack" style={{ gap: 8, marginTop: 10, fontSize: 13, color: '#242527', lineHeight: 1.45 }}>
                  <Tick>Stock on hand increases at {locName}; weighted average cost recalculates per item.</Tick>
                  <Tick>Payable to the vendor appears in Bills to be paid.</Tick>
                  <Tick>Any line costing more than last time creates a price proposal. Nothing reprices silently.</Tick>
                  {lines.some((l) => !l.item_id) && <Tick>{plural(lines.filter((l) => !l.item_id).length, 'new item')} will be created with this cost, pack size, VAT treatment and vendor.</Tick>}
                  <Tick>{receipt.document_path ? 'Source image and your corrections are stored with the journal.' : 'Your entries are stored with the journal.'}</Tick>
                </div>
              </div>
              <div style={{ background: '#FAFAFA', borderRadius: 12, padding: 14, display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
                <span className="muted" style={{ fontSize: 13 }}>Total payable</span>
                <span style={{ fontFamily: 'var(--font-brand)', fontSize: 24, fontWeight: 600, letterSpacing: '-.01em' }}>{N2(t.gross)}</span>
              </div>
              {err && <Alert kind="red" icon="alert">{err}</Alert>}
            </div>
          </div>
        )}
        {step === 'posted' && result && (
          <Centered>
            <div style={{ width: 64, height: 64, borderRadius: '50%', background: '#F0FDF4', display: 'grid', placeItems: 'center' }}><Icon name="check" size={28} color="#15803D" sw={2.5} /></div>
            <div style={{ fontSize: 17, fontWeight: 600 }}>Posted · {result.journal_ref}</div>
            <div className="muted" style={{ fontSize: 13, lineHeight: 1.5, maxWidth: 460 }}>
              {plural(lines.length, 'line')} received at {locName} for {N2(result.gross)}.{result.proposals ? ` ${plural(result.proposals, 'price proposal')} opened because costs went up.` : ''} The ledger shows it now.
            </div>
            <div className="row wrap" style={{ justifyContent: 'center', marginTop: 8 }}>
              {inv?.can_see_costs && <button className="btn btn-secondary btn-sm" onClick={() => onJournal(result.journal_ref)}><Icon name="book" size={14} />Open journal</button>}
              {result.proposals > 0 && can(inv, 'edit_prices') && <button className="btn btn-secondary btn-sm" onClick={() => nav('/inventory/pricing')}><Icon name="tag" size={14} />Review prices</button>}
              {can(inv, 'edit_prices') && <button className="btn btn-secondary btn-sm" onClick={() => nav('/inventory/pricing', { state: { landed: receipt?.id } })}>Add landed cost</button>}
              <button className="btn btn-primary btn-sm" onClick={() => onAnother(mode)}>Receive another</button>
            </div>
          </Centered>
        )}
      </div>
      {(step === 'lines' || step === 'journal' || step === 'posting') && (
        <div className="modal-ft" style={{ justifyContent: 'space-between', alignItems: 'center' }}>
          <div className="muted" style={{ fontSize: 13 }}>Net {N2(t.net)} · VAT {N2(t.vat)} · <b style={{ color: '#111827' }}>Total {N2(t.gross)}</b></div>
          <div className="row">
            {step === 'lines' && <button className={'btn ' + (confirmDiscard ? 'btn-danger' : 'btn-ghost')} onClick={discard}>{confirmDiscard ? 'Tap again to discard' : 'Discard'}</button>}
            {step === 'lines' && <button className="btn btn-secondary" onClick={close}>Save for later</button>}
            {step === 'lines' && <button className="btn btn-primary" onClick={review} disabled={busy}>{busy ? <Spinner small /> : null}Review journal</button>}
            {step !== 'lines' && <button className="btn btn-secondary" onClick={() => { setErr(null); setStep('lines'); }} disabled={step === 'posting'}>Back to lines</button>}
            {step !== 'lines' && <button className="btn btn-primary" onClick={post} disabled={step === 'posting'}>{step === 'posting' ? <><Spinner small />Posting…</> : 'Post receipt'}</button>}
          </div>
        </div>
      )}
      {showDoc && docUrl && (
        <Modal onClose={() => setShowDoc(false)} width={760} z={70}>
          <div className="modal-hd"><div className="drawer-title">{receipt?.ref} · source</div><XButton onClick={() => setShowDoc(false)} /></div>
          <div style={{ padding: 16, overflow: 'auto' }}>
            {receipt?.document_mime === 'application/pdf'
              ? <iframe title="Invoice PDF" src={docUrl} style={{ width: '100%', height: '70vh', border: '1px solid #E6E6E6', borderRadius: 12 }} />
              : <img src={docUrl} alt="Invoice" style={{ width: '100%', borderRadius: 12, border: '1px solid #E6E6E6' }} />}
          </div>
        </Modal>
      )}
    </Modal>
  );
}

const LINE_COLS = 'minmax(220px,1.7fr) 90px 92px 120px 120px 90px 28px';

function Centered({ children }: { children: ReactNode }) {
  return <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 14, padding: '64px 0', textAlign: 'center' }}>{children}</div>;
}
function Tick({ children }: { children: ReactNode }) {
  return <div className="row" style={{ alignItems: 'flex-start' }}><Icon name="check" size={16} color="#15803D" sw={2.5} style={{ marginTop: 2 }} /><span>{children}</span></div>;
}
function JRow({ code, name, dr, cr }: { code: string; name: string; dr?: number; cr?: number }) {
  return (
    <div className="tr jr-grid" style={{ gridTemplateColumns: '60px 1fr 110px 110px', padding: '10px 14px' }}>
      <span className="mono ink3">{code}</span><span>{name}</span>
      <span className="right num" style={{ fontWeight: 600 }}>{dr != null ? N2(dr) : ''}</span>
      <span className="right num" style={{ fontWeight: 600 }}>{cr != null ? N2(cr) : ''}</span>
    </div>
  );
}

// What makes an invoice photo readable, shown before the camera opens. Every point is something the reader needs to
// fill a line or the journal: who sold it, which invoice, and each product's quantity, unit and price.
const CAPTURE_TIPS: [string, string][] = [
  ['Whole page in the frame', 'All four corners showing, the page flat on a table, the phone straight above it.'],
  ['Good light, no shadow or glare', 'Daylight or a bright room. Switch the flash off if it leaves a white patch on glossy paper.'],
  ['The supplier and the invoice', 'Supplier name, invoice number and date, and their Tax ID or VAT number when it is printed.'],
  ['Every product line', 'Product name and size, quantity, unit (carton, bag, pack, tin), unit price and line amount.'],
  ['The totals', 'VAT and the invoice total, so the reader can check the lines add up.'],
  ['One page per photo', 'For an invoice of several pages, receive each page on its own or scan them into one PDF.'],
];

export async function photoCheck(file: Blob): Promise<string[]> {
  if (!file.type.startsWith('image/')) return [];
  try {
    const bmp = await createImageBitmap(file);
    const out: string[] = [];
    if (Math.max(bmp.width, bmp.height) < 1000) out.push(`The photo is small (${bmp.width} × ${bmp.height}), so small print may not be readable. Take it closer or at a higher setting.`);
    const c = document.createElement('canvas'); c.width = 64; c.height = 64;
    const g = c.getContext('2d')!; g.drawImage(bmp, 0, 0, 64, 64); bmp.close?.();
    const px = g.getImageData(0, 0, 64, 64).data;
    let sum = 0; let sq = 0;
    for (let i = 0; i < px.length; i += 4) { const y = 0.299 * px[i] + 0.587 * px[i + 1] + 0.114 * px[i + 2]; sum += y; sq += y * y; }
    const n = px.length / 4; const mean = sum / n; const sd = Math.sqrt(Math.max(sq / n - mean * mean, 0));
    if (mean < 70) out.push('The photo is dark. Move to better light or near a window.');
    else if (sd < 18) out.push('The photo has very little contrast, as if it is blurred or washed out. Hold the phone steady and take it again.');
    return out;
  } catch { return []; }
}

function Capture({ mode, header, setHeader, onFile, err }: {
  mode: Source; header: { vendor_id: string | null; location_id: string | null }; setHeader: (f: (h: any) => any) => void; onFile: (f: File) => void; err: string | null;
}) {
  const { data: inv } = useInventory();
  const input = useRef<HTMLInputElement>(null);
  const camera = useRef<HTMLInputElement>(null);
  const [over, setOver] = useState(false);
  const [held, setHeld] = useState<{ file: File; problems: string[] } | null>(null);
  async function take(f: File) {
    const problems = await photoCheck(f);
    if (problems.length) setHeld({ file: f, problems }); else onFile(f);
  }
  return (
    <div className="stack" style={{ gap: 16, maxWidth: 680, margin: '0 auto' }}>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
        <div>
          <label className="field-label">Received at</label>
          <select className="input" value={header.location_id || ''} onChange={(e) => setHeader((h: any) => ({ ...h, location_id: e.target.value }))}>
            {inv?.locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}
          </select>
        </div>
        <div>
          <label className="field-label">Vendor</label>
          <select className="input" value={header.vendor_id || ''} onChange={(e) => setHeader((h: any) => ({ ...h, vendor_id: e.target.value || null }))}>
            <option value="">Read it from the invoice</option>
            {inv?.vendors.map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}
          </select>
        </div>
      </div>
      {held ? (
        <div className="stack" style={{ gap: 10 }}>
          <Alert kind="yellow" icon="camera">{held.problems.join(' ')}</Alert>
          <div className="row wrap">
            <button className="btn btn-primary btn-sm" onClick={() => { setHeld(null); camera.current?.click(); }}><Icon name="camera" size={14} />Take it again</button>
            <button className="btn btn-secondary btn-sm" onClick={() => { const f = held.file; setHeld(null); onFile(f); }}>Read it anyway</button>
          </div>
        </div>
      ) : (
        <div role="button" tabIndex={0} onClick={() => input.current?.click()} onKeyDown={(e) => e.key === 'Enter' && input.current?.click()}
          onDragOver={(e) => { e.preventDefault(); setOver(true); }} onDragLeave={() => setOver(false)}
          onDrop={(e) => { e.preventDefault(); setOver(false); const f = e.dataTransfer.files?.[0]; if (f) take(f); }}
          style={{ border: '1.5px dashed ' + (over ? '#0072F5' : '#D1D5DB'), background: over ? '#F0F7FF' : '#fff', borderRadius: 16, padding: '32px 20px', textAlign: 'center', cursor: 'pointer' }}>
          <div style={{ width: 52, height: 52, margin: '0 auto', borderRadius: 14, background: '#F0F7FF', display: 'grid', placeItems: 'center' }}><Icon name={mode === 'hand' ? 'camera' : 'upload'} size={24} color="#0072F5" /></div>
          <div style={{ fontSize: 15, marginTop: 14 }}><span style={{ color: '#0072F5', textDecoration: 'underline' }}>{mode === 'hand' ? 'Take or choose a photo' : 'Choose a file'}</span> or drag & drop it here</div>
          <div className="muted" style={{ fontSize: 13, marginTop: 4 }}>{mode === 'hand' ? 'JPG or PNG · hold the sheet flat, all lines in frame' : 'PDF, JPG or PNG · up to 20MB'}</div>
          {mode !== 'hand' && (
            <button type="button" className="btn btn-secondary btn-sm" style={{ marginTop: 12 }} onClick={(e) => { e.stopPropagation(); camera.current?.click(); }}>
              <Icon name="camera" size={14} />Take a photo
            </button>
          )}
        </div>
      )}
      <input ref={input} type="file" hidden accept={mode === 'hand' ? 'image/*' : 'image/*,application/pdf'} capture={mode === 'hand' ? 'environment' : undefined}
        onChange={(e) => { const f = e.target.files?.[0]; if (f) take(f); e.target.value = ''; }} />
      <input ref={camera} type="file" hidden accept="image/*" capture="environment" aria-label="Take a photo of the invoice"
        onChange={(e) => { const f = e.target.files?.[0]; if (f) take(f); e.target.value = ''; }} />
      <div className="card" style={{ borderRadius: 12, padding: '12px 14px', background: '#FAFAFA' }}>
        <div style={{ fontSize: 13, fontWeight: 600, marginBottom: 8 }}>What the photo needs to show</div>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(240px,1fr))', gap: '8px 16px' }}>
          {CAPTURE_TIPS.map(([t, d]) => (
            <div key={t} className="row" style={{ alignItems: 'flex-start', gap: 8 }}>
              <Icon name="check" size={14} color="#15803D" sw={2.5} style={{ marginTop: 2, flex: 'none' }} />
              <span style={{ fontSize: 12, lineHeight: 1.45 }}><b>{t}.</b> <span className="muted">{d}</span></span>
            </div>
          ))}
        </div>
        <div className="faint" style={{ fontSize: 12, marginTop: 8, lineHeight: 1.45 }}>
          Delivery and transport charges on the invoice are not stock: add them as landed cost after you post. Products the shop has never stocked
          become new items, so check their name, pack size, selling unit and VAT on the next screen.
        </div>
      </div>
      {mode === 'hand' && <div className="hint" style={{ textAlign: 'center' }}>We read market shorthand like "doz", "ctn" and "half bag", then show any line we are unsure of beside the photo.</div>}
      {err && <Alert kind="red" icon="alert">{err}</Alert>}
    </div>
  );
}

function DocCrop({ url, bbox, raw, hand }: { url: string | null; bbox: number[] | null; raw: string | null; hand: boolean }) {
  const [dim, setDim] = useState<{ w: number; h: number } | null>(null);
  if (!url || !bbox || bbox.length !== 4) {
    return <div className={hand ? 'handwrite' : 'mono'} style={{ background: '#F5F1E6', borderRadius: 8, padding: '8px 12px', fontSize: 13, color: '#374151', display: 'flex', alignItems: 'center', gap: 8, maxWidth: 360 }}><Icon name="image" size={16} color="#6B7280" />{raw || 'No source text'}</div>;
  }
  const pad = 14;
  const y0 = Math.max(0, bbox[0] - pad), x0 = Math.max(0, bbox[1] - pad), y1 = Math.min(1000, bbox[2] + pad), x1 = Math.min(1000, bbox[3] + pad);
  const W = 300; const fw = Math.max(0.05, (x1 - x0) / 1000); const fh = Math.max(0.01, (y1 - y0) / 1000);
  const imgW = W / fw; const imgH = dim ? (imgW * dim.h) / dim.w : 0;
  const H = dim ? Math.min(150, Math.max(34, fh * imgH)) : 48;
  return (
    <div title={raw || ''} style={{ width: W, height: H, overflow: 'hidden', borderRadius: 8, position: 'relative', background: '#F5F1E6', border: '1px solid #FDE68A', flex: 'none' }}>
      <img src={url} alt={raw || 'Invoice line'} onLoad={(e) => setDim({ w: e.currentTarget.naturalWidth, h: e.currentTarget.naturalHeight })}
        style={{ position: 'absolute', width: imgW, maxWidth: 'none', left: (-x0 / 1000) * imgW, top: (-y0 / 1000) * imgH, visibility: dim ? 'visible' : 'hidden' }} />
    </div>
  );
}

function LineRow({ l, items, item, docUrl, hand, canPrice, onPatch, onRemove }: {
  l: DraftLine; items: Item[]; item: Item | null; docUrl: string | null; hand: boolean; canPrice: boolean;
  onPatch: (p: Partial<DraftLine>, confirm?: boolean) => void; onRemove: () => void;
}) {
  const doubtful = !l.confirmed;
  const nw = l.item_id ? null : l.new_item;
  const opts = unitOptions(item, nw);
  const total = Math.round(Number(l.qty || 0) * Number(l.unit_cost || 0) * 100) / 100;
  const conf = Number(l.confidence);
  const confTone = conf >= DOUBT ? ['#F0FDF4', '#15803D'] : conf >= 60 ? ['#FEFCE8', '#A16207'] : ['#FEF2F2', '#DC2626'];
  const tracks = item ? item.track_batches : !!nw?.track_batches;
  const sorted = useMemo(() => [...items].sort((a, b) => a.name.localeCompare(b.name)), [items]);
  const suQty = item ? Number(l.qty) * (l.unit_kind === 'purchase' ? item.pack_size : 1) : null;
  return (
    <div style={{ border: '1px solid ' + (doubtful ? '#FDE68A' : '#E6E6E6'), background: doubtful ? '#FFFDF5' : '#fff', borderRadius: 12, padding: '10px 14px' }}>
      <div className="line-grid" style={{ display: 'grid', gridTemplateColumns: LINE_COLS, gap: 10, alignItems: 'center', fontSize: 13 }}>
        <div className="m-full" style={{ minWidth: 0 }}>
          <select className="input input-sm" value={l.item_id || (nw ? '__new' : '')} aria-label="Item"
            onChange={(e) => {
              const v = e.target.value;
              if (v === '__new') onPatch({ item_id: null, new_item: { name: l.new_item?.name || (l.raw_text || '').slice(0, 80), purchase_unit: 'Carton', pack_size: 1, selling_unit: 'piece', category: 'General', vat_treatment: 'standard', track_batches: false } });
              else {
                const it = items.find((i) => i.id === v) || null;
                const fill = it && !(Number(l.unit_cost) > 0) ? Math.round(Number(it.last_cost ?? it.wac ?? 0) * (l.unit_kind === 'purchase' ? it.pack_size : 1) * 100) / 100 : l.unit_cost;
                onPatch({ item_id: v || null, new_item: null, unit_cost: fill, unit_kind: it && it.pack_size <= 1 ? 'purchase' : l.unit_kind });
              }
            }}>
            <option value="">Choose item…</option>
            {sorted.map((i) => <option key={i.id} value={i.id}>{i.name}</option>)}
            <option value="__new">{nw ? `New item: ${nw.name || '…'}` : '+ New item…'}</option>
          </select>
          {(l.raw_text || suQty != null) && <div className="faint mono ellipsis" style={{ fontSize: 11, marginTop: 3 }} title={l.raw_text || ''}>
            {l.raw_text ? `read: "${l.raw_text}"` : ''}{item && suQty != null && item.pack_size > 1 ? `${l.raw_text ? ' · ' : ''}${qtyLabel(item, suQty)}` : ''}
          </div>}
        </div>
        <span className="show-sm faint" style={{ fontSize: 11, marginBottom: -6 }}>Quantity</span>
        <span className="show-sm faint" style={{ fontSize: 11, marginBottom: -6 }}>Unit</span>
        <span className="show-sm faint" style={{ fontSize: 11, marginBottom: -6 }}>Cost per unit</span>
        <input className="input input-sm" type="number" inputMode="decimal" min={0} step="any" value={l.qty} aria-label="Quantity" placeholder="Qty" onChange={(e) => onPatch({ qty: e.target.value as any })} />
        {opts.length > 1 ? (
          <select className="input input-sm" value={l.unit_kind} aria-label="Unit" onChange={(e) => onPatch({ unit_kind: e.target.value as any, unit_label: opts.find((o) => o.kind === e.target.value)?.label || null })}>
            {opts.map((o) => <option key={o.kind} value={o.kind} title={o.hint}>{o.label}</option>)}
          </select>
        ) : <span className="ink3">{opts[0].label}</span>}
        <input className="input input-sm" type="number" inputMode="decimal" min={0} step="any" value={l.unit_cost} aria-label="Unit cost" placeholder="₦ each" onChange={(e) => onPatch({ unit_cost: e.target.value as any })} />
        <span className="right num m-left" style={{ fontWeight: 600 }}>{N2(total)}</span>
        <span><span className="chip" style={{ background: confTone[0], color: confTone[1], fontWeight: 700 }}>{conf}%</span></span>
        <button className="x-btn" onClick={onRemove} aria-label="Remove line"><Icon name="x" size={14} color="#9CA3AF" /></button>
      </div>
      {doubtful && (
        <div className="row wrap" style={{ gap: 12, marginTop: 10, paddingTop: 10, borderTop: '1px dashed #FDE68A' }}>
          <DocCrop url={docUrl} bbox={l.bbox} raw={l.raw_text} hand={hand} />
          <div style={{ fontSize: 13, color: '#92400E', flex: 1, minWidth: 160 }}>Not sure about this one. Which reading is right?</div>
          <div className="row">
            <button className="btn btn-primary btn-xs" onClick={() => onPatch({})}>Keep {num(Number(l.qty), 3)} {unitLabel(item, l)}</button>
            {l.alt_reading && (
              <button className="btn btn-secondary btn-xs" onClick={() => {
                // Another unit for the same goods (16 tins or 1 carton of 16) keeps the line's total; another count of the same unit keeps the price.
                const alt = l.alt_reading!; const kind = alt.unit_kind || l.unit_kind; const q = Number(alt.qty);
                const cost = kind !== l.unit_kind && q > 0 ? Math.round((Number(l.qty) * Number(l.unit_cost) / q) * 100) / 100 : l.unit_cost;
                onPatch({ qty: q, unit_kind: kind, unit_cost: cost });
              }}>{l.alt_reading.label}</button>
            )}
          </div>
        </div>
      )}
      {nw && <NewItemFields nw={nw} canPrice={canPrice} cost={Number(l.unit_cost) / (l.unit_kind === 'purchase' ? Math.max(1, Number(nw.pack_size) || 1) : 1)} onChange={(p) => onPatch({ new_item: { ...nw, ...p } }, false)} />}
      {tracks && (
        <div className="row wrap" style={{ gap: 10, marginTop: 8 }}>
          <span className="faint" style={{ fontSize: 12 }}>Batch tracking</span>
          <input className="input input-sm" style={{ width: 150 }} placeholder="Batch no." value={l.batch_no || ''} onChange={(e) => onPatch({ batch_no: e.target.value }, false)} />
          <input className="input input-sm" style={{ width: 160 }} type="date" aria-label="Expiry date" value={l.expiry_date || ''} onChange={(e) => onPatch({ expiry_date: e.target.value || null }, false)} />
          {!l.batch_no && <span className="hint">Leave blank and we number the batch from the journal.</span>}
        </div>
      )}
    </div>
  );
}

function NewItemFields({ nw, canPrice, cost, onChange }: { nw: NonNullable<DraftLine['new_item']>; canPrice: boolean; cost: number; onChange: (p: Partial<NonNullable<DraftLine['new_item']>>) => void }) {
  const pack = Number(nw.pack_size);
  const packErr = !(pack >= 1 && Number.isInteger(pack));
  return (
    <div style={{ marginTop: 8, background: '#F0F7FF', borderRadius: 10, padding: '10px 12px' }}>
      <div style={{ fontSize: 12, color: '#1E3A8A', marginBottom: 8 }}>New item will be created with this cost, pack size, VAT treatment and vendor.</div>
      <div className="m-2" style={{ display: 'grid', gridTemplateColumns: 'minmax(180px,2fr) repeat(3,minmax(90px,1fr)) minmax(120px,1.2fr) minmax(130px,1.2fr)', gap: 8, alignItems: 'end' }}>
        <div className="m-full"><label className="field-label" style={{ fontSize: 12 }}>Name</label><input className="input input-sm" value={nw.name} onChange={(e) => onChange({ name: e.target.value })} /></div>
        <div><label className="field-label" style={{ fontSize: 12 }}>Buy by the</label>
          <select className="input input-sm" value={nw.purchase_unit || 'Carton'} onChange={(e) => onChange({ purchase_unit: e.target.value })}>{['Carton', 'Bag', 'Bale', 'Pack', 'Crate', 'Roll', 'Sack', 'Tray', 'Dozen'].map((u) => <option key={u}>{u}</option>)}</select></div>
        <div><label className="field-label" style={{ fontSize: 12 }}>Contains</label><input className={'input input-sm' + (packErr ? ' err' : '')} type="number" min={1} step={1} value={nw.pack_size ?? 1} onChange={(e) => onChange({ pack_size: e.target.value as any })} /></div>
        <div><label className="field-label" style={{ fontSize: 12 }}>Sell by the</label>
          <select className="input input-sm" value={nw.selling_unit || 'piece'} onChange={(e) => onChange({ selling_unit: e.target.value })}>{['piece', 'pack', 'sachet', 'tin', 'bottle', 'derica', 'mudu', 'paint bucket', 'kg', 'roll'].map((u) => <option key={u}>{u}</option>)}</select></div>
        <div><label className="field-label" style={{ fontSize: 12 }}>VAT</label>
          <select className="input input-sm" value={nw.vat_treatment || 'standard'} onChange={(e) => onChange({ vat_treatment: e.target.value as any })}><option value="standard">Standard {vatPct()}</option><option value="zero">Zero-rated</option><option value="exempt">Exempt</option></select></div>
        {canPrice ? (
          <div><label className="field-label" style={{ fontSize: 12 }}>Selling price / {nw.selling_unit || 'piece'}</label>
            <input className="input input-sm" type="number" min={0} placeholder={cost > 0 ? `≈ ${Math.round(cost * 1.15)}` : '₦'} value={nw.price ?? ''} onChange={(e) => onChange({ price: e.target.value === '' ? null : (e.target.value as any) })} /></div>
        ) : <div className="hint">Price is set by the owner. We start it at cost + 15% and flag it for a check.</div>}
      </div>
      <div className="row wrap" style={{ gap: 16, marginTop: 8 }}>
        <label className="check" style={{ fontSize: 12 }}><input type="checkbox" checked={!!nw.track_batches} onChange={(e) => onChange({ track_batches: e.target.checked })} />Track batches and expiry</label>
        <input className="input input-sm" style={{ maxWidth: 180 }} placeholder="Category (e.g. Dairy)" value={nw.category || ''} onChange={(e) => onChange({ category: e.target.value })} />
        <input className="input input-sm" style={{ maxWidth: 180 }} placeholder="Barcode (optional)" value={nw.barcode || ''} onChange={(e) => onChange({ barcode: e.target.value })} />
        {packErr && <span className="err-text" style={{ margin: 0 }}>Pack size must be a whole number of at least 1.</span>}
      </div>
    </div>
  );
}
