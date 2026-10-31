// Supplier invoices: sent by suppliers on the business's invoice portal, or uploaded here. Counta reads each one, adds the
// supplier when it is new, checks the invoice (sums, VAT, Tax ID, address, bank account) and writes a draft bill. Problems the
// supplier must fix go to them by email or WhatsApp; the business approves the bill for payment, or rejects the invoice and
// the supplier is told why.
import { useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { can, useInventory, useSession, useToast } from '../../state/session';
import { ai, rpc, signedDoc, supabase } from '../../lib/supabase';
import { N2, fmtDay, when } from '../../lib/format';
import { Icon } from '../../components/Icon';
import { Alert, Drawer, Empty, Field, Modal, ModalHead, Pills, SkeletonRows, Spinner } from '../../components/ui';
import { StatusChip } from '../sell/common';
import { isOn, offNote, useFeatures } from '../../lib/features';

type Filter = 'open' | 'approved' | 'rejected' | 'all';
export const portalUrl = (token: string) => `${window.location.origin}/v/${token}`;
const SEVERITY: Record<string, { tone: 'red' | 'amber' | 'grey'; icon: string; label: string }> = {
  block: { tone: 'red', icon: 'x', label: 'Stops payment' },
  warn: { tone: 'amber', icon: 'alert', label: 'To look at' },
  info: { tone: 'grey', icon: 'info', label: 'For information' },
};
const NOTICE: Record<string, string> = { sent: 'Supplier told', none: '', skipped: 'Not sent', off: 'Notices off', no_contact: 'No contact to tell' };

export function useSupplierInvoices(filter: Filter = 'open', on = true) {
  const { orgId } = useSession();
  return useQuery({ queryKey: ['supplier-invoices', orgId, filter], enabled: !!orgId && on, refetchInterval: 20_000, retry: 1,
    queryFn: () => rpc<any>('supplier_invoices_list', { p_org: orgId, p: { status: filter === 'all' ? null : filter } }) });
}

export function SupplierInvoices({ openId, onOpen, onClose, onOpenBill }: { openId: string | null; onOpen: (id: string) => void; onClose: () => void; onOpenBill: (id: string) => void }) {
  const { data: inv } = useInventory();
  const [filter, setFilter] = useState<Filter>('open');
  const list = useSupplierInvoices(filter);
  const rows: any[] = list.data?.rows || [];
  const counts = list.data?.counts || {};
  if (!inv) return null;
  return (
    <div className="stack" style={{ gap: 12 }}>
      {list.data?.portal && <PortalCard portal={list.data.portal} />}
      <div className="row wrap" style={{ justifyContent: 'space-between' }}>
        <Pills value={filter} onChange={setFilter} options={[{ id: 'open', label: 'To review', count: Number(counts.review || 0) + Number(counts.failed || 0) || undefined },
          { id: 'approved', label: 'Approved' }, { id: 'rejected', label: 'Rejected' }, { id: 'all', label: 'All' }]} />
        {can(inv, 'keep_books') && <UploadButton />}
      </div>
      <div className="card" style={{ overflow: 'hidden' }}>
        <div className="tbl">
          <div className="tr head shade th hide-sm" style={{ gridTemplateColumns: '110px minmax(170px,1.5fr) 150px 120px minmax(150px,1fr) 120px', minWidth: 860 }}>
            <span>Received</span><span>Supplier</span><span>Their invoice</span><span className="right">Total</span><span>Checks</span><span>Status</span>
          </div>
          {list.isLoading ? <SkeletonRows n={4} /> : list.error ? <div style={{ padding: 20 }}><Alert kind="yellow" icon="shield">{(list.error as Error).message}</Alert></div>
            : !rows.length ? <div style={{ padding: 20 }}><Empty>{filter === 'open' ? 'Nothing waiting. Invoices suppliers send on your link, and ones you upload, appear here once Counta has read them.' : 'No invoices here.'}</Empty></div>
            : rows.map((r) => (
              <div key={r.id} className="tr click" onClick={() => onOpen(r.id)} style={{ gridTemplateColumns: '110px minmax(170px,1.5fr) 150px 120px minmax(150px,1fr) 120px', minWidth: 860 }}>
                <span><b>{r.number}</b><span className="faint" style={{ display: 'block', fontSize: 11 }}>{r.source === 'portal' ? 'sent by the supplier' : r.source === 'nrs' ? 'received through NRS' : 'uploaded'} · {when(r.created_at)}</span></span>
                <span className="ellipsis">{r.vendor_name || '—'}{r.vendor_created && <span className="chip t-blue" style={{ marginLeft: 6 }}>new supplier</span>}</span>
                <span className="muted ellipsis">{r.invoice_no || '—'}{r.invoice_date ? ` · ${fmtDay(r.invoice_date)}` : ''}</span>
                <span className="right num">{r.total != null ? N2(r.total) : '—'}</span>
                <span style={{ fontSize: 12 }}>
                  {r.status === 'reading' ? <span className="faint">Reading…</span> : r.status === 'failed' ? <span style={{ color: '#B91C1C' }}>{r.error || 'Could not be read'}</span> : <>
                    {Number(r.blocks) > 0 && <span className="chip t-red" style={{ marginRight: 4 }}>{r.blocks} to fix before payment</span>}
                    {Number(r.warns) > 0 && <span className="chip t-amber" style={{ marginRight: 4 }}>{r.warns} to look at</span>}
                    {!Number(r.blocks) && !Number(r.warns) && <span style={{ color: '#15803D' }}>All checks passed</span>}
                    {NOTICE[r.notice_status] && <span className="faint" style={{ display: 'block', fontSize: 11 }}>{NOTICE[r.notice_status]}</span>}
                  </>}
                </span>
                <span><StatusChip s={r.status} /></span>
              </div>
            ))}
        </div>
      </div>
      {openId && <SupplierInvoiceDrawer id={openId} onClose={onClose} onOpenBill={onOpenBill} />}
    </div>
  );
}

// The business's own link for suppliers: copy or share it, switch it off, choose whether suppliers are told about problems.
function PortalCard({ portal }: { portal: { token: string; on: boolean; notices: boolean; allowed?: boolean } }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const feats = useFeatures();
  const [busy, setBusy] = useState(false);
  const url = portalUrl(portal.token);
  const keep = inv ? can(inv, 'keep_books') : false;
  // The sample business never takes invoices on its link (the link page says so); uploading still shows how it works.
  const sample = Boolean(inv?.org.is_sample);
  async function set(p: Record<string, unknown>, ok: string) {
    setBusy(true);
    try { await rpc('set_invoice_portal', { p_org: orgId, p }); toast(ok); await qc.invalidateQueries({ queryKey: ['supplier-invoices'] }); }
    catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  const share = `Send your invoices to ${inv?.org.name || 'us'} here: ${url}`;
  if (!isOn(feats.data, 'supplier_portal')) return <Alert kind="amber" icon="info">{offNote(feats.data, 'supplier_portal')}</Alert>;
  return (
    <div className="card card-pad stack" style={{ gap: 10 }}>
      <div className="row wrap" style={{ justifyContent: 'space-between', gap: 10 }}>
        <div className="grow" style={{ minWidth: 220 }}>
          <div style={{ fontWeight: 600 }}>Your invoice link for suppliers</div>
          <div className="faint" style={{ fontSize: 12.5 }}>Suppliers upload invoices here instead of emailing or sending them by WhatsApp. Counta reads and checks each one and writes the bill.</div>
        </div>
        <span className={'chip ' + (portal.on && !sample ? 't-green' : 't-grey')}>{sample ? 'Not on the sample business' : portal.on ? 'Taking invoices' : 'Switched off'}</span>
      </div>
      {sample && <div className="faint" style={{ fontSize: 12.5 }}>This is the sample business, so its link does not take invoices. Upload an invoice below to see how Counta reads and checks it; in your own business, suppliers can use the link.</div>}
      <div className="row wrap" style={{ gap: 8 }}>
        <input className="input input-sm mono grow" style={{ minWidth: 220 }} readOnly value={url} aria-label="Invoice link" onFocus={(e) => e.target.select()} />
        <button className="btn btn-secondary btn-sm" onClick={() => navigator.clipboard?.writeText(url).then(() => toast('Link copied'), () => toast('Select the link and copy it', 'err'))}><Icon name="copy" size={13} />Copy</button>
        <a className="btn btn-secondary btn-sm" href={`https://wa.me/?text=${encodeURIComponent(share)}`} target="_blank" rel="noreferrer"><Icon name="wa" size={13} />WhatsApp</a>
        <a className="btn btn-secondary btn-sm" href={`mailto:?subject=${encodeURIComponent(`Invoices to ${inv?.org.name || 'us'}`)}&body=${encodeURIComponent(share)}`}><Icon name="mail" size={13} />Email</a>
      </div>
      {keep && (
        <div className="row wrap" style={{ gap: 14, fontSize: 13 }}>
          <label className="check"><input type="checkbox" checked={portal.on} disabled={busy} onChange={(e) => set({ on: e.target.checked }, e.target.checked ? 'The link takes invoices again' : 'The link is switched off')} />Take invoices on this link</label>
          <label className="check"><input type="checkbox" checked={portal.notices} disabled={busy} onChange={(e) => set({ notices: e.target.checked }, e.target.checked ? 'Suppliers are told about problems' : 'Suppliers are not told automatically')} />Tell suppliers what to fix, by email or WhatsApp</label>
          <button className="btn btn-ghost btn-xs" disabled={busy} onClick={() => { if (window.confirm('Make a new link? The old one stops working, so send the new one to your suppliers.')) void set({ new_link: true }, 'New link made. The old one no longer works.'); }}>Make a new link</button>
        </div>
      )}
    </div>
  );
}

// Several invoices at once: each file is stored with the business's documents, then read and checked.
function UploadButton() {
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const input = useRef<HTMLInputElement>(null);
  const [progress, setProgress] = useState<{ name: string; state: 'waiting' | 'reading' | 'done' | 'failed'; note?: string }[]>([]);
  const busy = progress.some((p) => p.state === 'waiting' || p.state === 'reading');
  async function go(files: File[]) {
    const ok = files.filter((f) => /^(application\/pdf|image\/(jpeg|png|webp))$/.test(f.type) && f.size <= 8 * 1024 * 1024);
    if (ok.length < files.length) toast(`${files.length - ok.length} file${files.length - ok.length === 1 ? ' was' : 's were'} skipped: send PDFs or photos under 8 MB.`, 'err');
    if (!ok.length) return;
    setProgress(ok.map((f) => ({ name: f.name, state: 'waiting' })));
    const mark = (i: number, p: Partial<{ state: any; note: string }>) => setProgress((ps) => ps.map((x, j) => (j === i ? { ...x, ...p } : x)));
    let next = 0;
    async function worker() {
      while (next < ok.length) {
        const i = next++; const f = ok[i];
        mark(i, { state: 'reading' });
        try {
          const ext = f.type === 'application/pdf' ? 'pdf' : f.type.split('/')[1].replace('jpeg', 'jpg');
          const path = `${orgId}/bills/upload-${new Date().toISOString().slice(0, 10)}-${crypto.randomUUID()}.${ext}`;
          const up = await supabase.storage.from('documents').upload(path, f, { contentType: f.type, upsert: false });
          if (up.error) throw new Error(up.error.message.includes('row-level') ? 'Your role cannot upload invoices.' : up.error.message);
          const r = await ai<{ invoice: any }>('read_supplier_invoice', { org_id: orgId, path, file_name: f.name });
          if (r.ok === false) throw new Error(r.error || 'Could not read it.');
          const si = r.invoice || {};
          mark(i, { state: 'done', note: si.status === 'failed' ? si.error : Number(si.blocks) ? `${si.number}: ${si.blocks} to fix before payment` : `${si.number}: read` });
        } catch (e) { mark(i, { state: 'failed', note: (e as Error).message }); }
        await qc.invalidateQueries({ queryKey: ['supplier-invoices'] });
      }
    }
    await Promise.all(Array.from({ length: Math.min(2, ok.length) }, worker));
    await qc.invalidateQueries({ queryKey: ['bills'] });
  }
  return (
    <div className="stack" style={{ gap: 6, alignItems: 'flex-end' }}>
      <input ref={input} type="file" multiple accept="application/pdf,image/jpeg,image/png,image/webp" style={{ display: 'none' }}
        onChange={(e) => { const fs = Array.from(e.target.files || []); e.target.value = ''; void go(fs); }} />
      <button className="btn btn-primary btn-sm" disabled={busy} onClick={() => input.current?.click()}>{busy ? <Spinner small /> : <Icon name="upload" size={14} color="#fff" />}Upload invoices</button>
      {progress.length > 0 && (
        <div className="card" style={{ padding: '8px 10px', fontSize: 12, minWidth: 260, maxWidth: 420 }}>
          {progress.map((p, i) => (
            <div key={i} className="row" style={{ gap: 6, justifyContent: 'space-between' }}>
              <span className="ellipsis" style={{ minWidth: 0 }}>{p.name}</span>
              <span style={{ color: p.state === 'failed' ? '#B91C1C' : p.state === 'done' ? '#15803D' : '#6B7280', flex: 'none' }}>
                {p.state === 'waiting' ? 'waiting' : p.state === 'reading' ? 'reading…' : p.note}</span>
            </div>
          ))}
          {!busy && <button className="btn btn-ghost btn-xs" onClick={() => setProgress([])}>Clear</button>}
        </div>
      )}
    </div>
  );
}

function SupplierInvoiceDrawer({ id, onClose, onOpenBill }: { id: string; onClose: () => void; onOpenBill: (id: string) => void }) {
  const { data: inv } = useInventory();
  const toast = useToast();
  const qc = useQueryClient();
  const q = useQuery({ queryKey: ['supplier-invoice', id], queryFn: () => rpc<any>('supplier_invoice', { p_id: id }),
    refetchInterval: (query) => ((query.state.data as any)?.status === 'reading' ? 4000 : false) });
  const si = q.data;
  const [rejecting, setRejecting] = useState(false);
  const [busy, setBusy] = useState(false);
  const keep = inv ? can(inv, 'keep_books') : false;
  const x = si?.extract || {};
  const checks: any[] = si?.checks || [];
  async function act(fn: () => Promise<any>, ok: string) {
    setBusy(true);
    try { const r = await fn(); if (r?.id) qc.setQueryData(['supplier-invoice', id], r); toast(ok); await Promise.all(['supplier-invoices', 'supplier-invoice', 'bills', 'bill'].map((k) => qc.invalidateQueries({ queryKey: [k] }))); }
    catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  async function openFile() {
    const url = await signedDoc(si?.document_path);
    if (url) window.open(url, '_blank', 'noopener'); else toast('The file could not be opened.', 'err');
  }
  const order = (c: any) => (c.severity === 'block' ? 0 : c.severity === 'warn' ? 1 : 2);
  return (
    <Drawer onClose={onClose} width={680}>
      <div className="drawer-hd"><div className="grow">
        <div className="row" style={{ gap: 8 }}><div className="drawer-title">{si ? `${si.number} · ${si.vendor?.name || x.supplier?.name || 'Supplier invoice'}` : 'Loading…'}</div>{si && <StatusChip s={si.status} />}</div>
        {si && <div className="muted" style={{ fontSize: 13 }} data-testid="si-source">{si.source === 'portal' ? `Sent by ${si.submitter?.name || 'the supplier'}${si.submitter?.email ? ` (${si.submitter.email})` : si.submitter?.phone ? ` (${si.submitter.phone})` : ''}`
          : si.source === 'nrs' ? `Received through NRS e-invoicing, signed by NRS · IRN ${si.nrs_irn}` : `Uploaded by ${si.submitted_by_name || 'someone in the business'}`} · {when(si.created_at)}</div>}
      </div><button className="x-btn" onClick={onClose} aria-label="Close"><Icon name="x" size={18} /></button></div>
      <div className="drawer-body stack" style={{ gap: 14 }}>
        {!si ? <Spinner /> : si.status === 'reading' ? <Alert kind="blue" icon="clock"><span className="row" style={{ gap: 8 }}><Spinner small />Counta is reading the invoice.</span></Alert> : (
          <>
            {si.status === 'failed' && <Alert kind="red" icon="alert">{si.error || 'Counta could not read this file.'} Enter the bill by hand from the invoice.</Alert>}
            {si.status === 'rejected' && <Alert kind="grey" icon="undo">Rejected {when(si.decided_at)}{si.decided_by_name ? ` by ${si.decided_by_name}` : ''}{si.rejected_reason ? `: ${si.rejected_reason}` : '.'}</Alert>}
            {si.status === 'approved' && <Alert kind="green" icon="check">Approved for payment {when(si.decided_at)}{si.decided_by_name ? ` by ${si.decided_by_name}` : ''}. Pay it from the bill.</Alert>}
            <div className="row wrap" style={{ gap: 8 }}>
              {si.document_path && <button className="btn btn-secondary btn-sm" onClick={openFile}><Icon name="file" size={14} />{si.source === 'nrs' ? 'Open NRS\'s copy' : 'Open the invoice'}</button>}
              {si.bill && <button className="btn btn-secondary btn-sm" onClick={() => onOpenBill(si.bill.id)}><Icon name="receipt" size={14} />{si.bill.number} · {si.bill.status}</button>}
            </div>
            {checks.length > 0 && (
              <div className="stack" style={{ gap: 6 }}>
                <div className="label">What Counta checked</div>
                {[...checks].sort((a, b) => order(a) - order(b)).map((c, i) => {
                  const s = SEVERITY[c.severity] || SEVERITY.info;
                  return (
                    <Alert key={i} kind={s.tone} icon={s.icon}>
                      <span>{c.text}</span>
                      <span className="faint" style={{ display: 'block', fontSize: 11, marginTop: 2 }}>{s.label}{c.notify ? ' · the supplier is told' : ''}</span>
                    </Alert>
                  );
                })}
              </div>
            )}
            {si.status === 'review' && !checks.some((c) => c.severity !== 'info') && <Alert kind="green" icon="check">Every check passed.</Alert>}
            {si.notice && (
              <div className="faint" style={{ fontSize: 12 }}>{si.notice.channel === 'email' ? 'Emailed' : 'Sent by WhatsApp'} to {si.notice.to}{si.notice.status === 'failed' ? `, but it did not go: ${si.notice.error || 'failed'}` : si.notice.status === 'queued' ? ', waiting to send' : ''}.</div>
            )}
            <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
              <div className="card card-pad stack" style={{ gap: 4, fontSize: 13 }}>
                <div className="label">Supplier{si.vendor_created ? ' (added by Counta)' : ''}</div>
                <b>{si.vendor?.name || x.supplier?.name || '—'}</b>
                <span>Tax ID: {si.vendor?.tin ? <><span className="mono">{si.vendor.tin}</span> <span className={'chip ' + (si.vendor.tin_status === 'verified' || si.vendor.tin_status === 'confirmed' ? 't-green' : si.vendor.tin_status ? 't-red' : 't-grey')}>{si.vendor.tin_status || 'not checked'}</span></> : <span style={{ color: '#B91C1C' }}>none</span>}</span>
                <span>Address: {si.vendor?.address || x.supplier?.address || <span style={{ color: '#B91C1C' }}>none</span>}</span>
                <span>Bank: {x.bank?.account_number ? `${x.bank.bank_name || ''} ${x.bank.account_number}${si.bank_resolved_name ? ` · the bank says ${si.bank_resolved_name}` : ''}` : <span className="faint">none on the invoice</span>}</span>
              </div>
              <div className="card card-pad stack" style={{ gap: 4, fontSize: 13 }}>
                <div className="label">The invoice</div>
                <span>{x.invoice_no ? `No. ${x.invoice_no}` : 'No invoice number'} · {x.invoice_date ? fmtDay(x.invoice_date) : 'no date'}</span>
                <span>Before VAT {x.subtotal != null ? N2(x.subtotal) : '—'} · VAT {x.vat_amount != null ? N2(x.vat_amount) : '—'}{x.vat_rate != null ? ` (${x.vat_rate}%)` : ''}</span>
                <b>Total {x.total != null ? N2(x.total) : '—'}</b>
                {si.bill && <span className="faint">The bill: {N2(si.bill.total)}{Number(si.bill.wht_expected) > 0 ? `, WHT ${N2(si.bill.wht_expected)}` : ''}</span>}
              </div>
            </div>
            {(x.lines || []).length > 0 && (
              <div className="card" style={{ overflow: 'hidden', borderRadius: 12, flex: 'none' }}>
                {(x.lines || []).map((l: any, i: number) => (
                  <div key={i} className="tr" style={{ gridTemplateColumns: 'minmax(0,1fr) 140px', padding: '8px 14px' }}>
                    <span style={{ minWidth: 0 }}>{l.description}<span className="faint" style={{ display: 'block', fontSize: 12 }}>{l.qty != null ? `${Number(l.qty)} × ${N2(l.unit_price)}` : ''}{l.vat_treatment !== 'standard' ? ` · ${l.vat_treatment}` : ''}</span></span>
                    <span className="right num">{l.amount != null ? N2(l.amount) : '—'}</span>
                  </div>
                ))}
              </div>
            )}
            {keep && si.status === 'review' && (
              <div className="row wrap" style={{ gap: 8 }}>
                <button className="btn btn-primary btn-sm" disabled={busy || Number(si.blocks) > 0} title={Number(si.blocks) > 0 ? 'Fix the checks that stop payment first' : undefined}
                  onClick={() => act(() => rpc('approve_supplier_invoice', { p_id: si.id }), 'Approved for payment')}><Icon name="check" size={14} color="#fff" />Approve for payment</button>
                <button className="btn btn-secondary btn-sm" disabled={busy} onClick={() => setRejecting(true)}><Icon name="undo" size={14} />Reject</button>
                <button className="btn btn-ghost btn-sm" disabled={busy} onClick={() => act(() => rpc('recheck_supplier_invoice', { p_id: si.id }), 'Checked again')}>Check again</button>
                {si.bill && <button className="btn btn-ghost btn-sm" onClick={() => onOpenBill(si.bill.id)}>Edit the bill</button>}
              </div>
            )}
            {keep && si.status === 'review' && Number(si.blocks) > 0 && <div className="faint" style={{ fontSize: 12 }}>Mistakes in the sums or the VAT do not stop payment. A missing Tax ID where withholding tax applies, or a business with no address, does: add them to the supplier and check again, or reject the invoice.</div>}
          </>
        )}
      </div>
      {rejecting && si && <RejectModal si={si} onClose={() => setRejecting(false)} onDone={() => act(async () => null, 'Rejected')} />}
    </Drawer>
  );
}

function RejectModal({ si, onClose, onDone }: { si: any; onClose: () => void; onDone: () => void }) {
  const toast = useToast();
  const issues = (si.checks || []).filter((c: any) => c.notify && c.severity !== 'info').map((c: any) => `- ${c.text}`).join('\n');
  const [reason, setReason] = useState(issues ? `Please correct these and send the invoice again:\n${issues}` : '');
  const [send, setSend] = useState(true);
  const [busy, setBusy] = useState(false);
  return (
    <Modal onClose={onClose} width={540}>
      <ModalHead title={`Reject ${si.number}`} sub={si.vendor?.name || si.extract?.supplier?.name} onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 10 }}>
        <Field label="What the supplier reads"><textarea className="input" style={{ minHeight: 120 }} value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
        <label className="check"><input type="checkbox" checked={send} onChange={(e) => setSend(e.target.checked)} />Send it to the supplier{si.submitter?.email ? ` (${si.submitter.email})` : si.vendor?.email ? ` (${si.vendor.email})` : si.submitter?.phone || si.vendor?.phone ? ' by WhatsApp' : ''}</label>
        <div className="faint" style={{ fontSize: 12 }}>The draft bill is withdrawn. Nothing is paid.</div>
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-danger" disabled={busy || reason.trim().length < 3} onClick={async () => {
          setBusy(true);
          try { await rpc('reject_supplier_invoice', { p_id: si.id, p: { reason, send } }); onDone(); onClose(); }
          catch (e) { toast((e as Error).message, 'err'); }
          setBusy(false);
        }}>Reject{send ? ' and tell the supplier' : ''}</button></div>
    </Modal>
  );
}
