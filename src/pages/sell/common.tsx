// Pieces the till, sales and orders share: choosing a customer, waiting for a transfer, and the receipt once paid.
import { useEffect, useMemo, useRef, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { can, useInventory, useSession, useToast } from '../../state/session';
import { rpc } from '../../lib/supabase';
import { DOC_LABEL, edge, edgeOk, METHOD_LABEL, STATUS_TONE, VAT_STATUS, statusLabel, useCustomers, vatStatusOf, type Customer, type PayRequest, type Sale, moneyAccounts } from '../../lib/api';
import { N2, fmtDay, when } from '../../lib/format';
import { qrSvg } from '../../lib/labels';
import { bluetoothSupported, connectPrinter, printBluetooth, printBrowser, printerName } from '../../lib/printer';
import { Icon } from '../../components/Icon';
import { Alert, Field, Modal, ModalHead, Spinner } from '../../components/ui';
import { taxIdError } from '../../lib/taxid';
import { COUNTRIES, isExport } from '../../lib/countries';
import { InvoiceDoc, PrintPortal, type DocData } from '../../components/InvoiceDoc';

export const docUrl = (token: string) => `${window.location.origin}/p/${token}`;

export function StatusChip({ s }: { s: string }) {
  return <span className={'chip ' + (STATUS_TONE[s] || 't-grey')}>{statusLabel(s)}</span>;
}

// ---------------------------------------------------------------- customers
export function CustomerPicker({ value, onChange, allowNew = true, walkIn = true, placeholder = 'Walk-in customer' }: {
  value: Customer | null; onChange: (c: Customer | null, draft?: { name: string; phone: string }) => void; allowNew?: boolean; walkIn?: boolean; placeholder?: string;
}) {
  const { data } = useCustomers();
  const [q, setQ] = useState('');
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const h = (e: MouseEvent) => { if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false); };
    document.addEventListener('mousedown', h); return () => document.removeEventListener('mousedown', h);
  }, [open]);
  const hits = useMemo(() => {
    const s = q.trim().toLowerCase();
    const list = (data?.customers || []).filter((c) => !c.archived && !c.is_walk_in);
    if (!s) return list.slice(0, 8);
    return list.filter((c) => c.name.toLowerCase().includes(s) || (c.phone || '').replace(/\D/g, '').includes(s.replace(/\D/g, '') || '~')).slice(0, 8);
  }, [data, q]);
  return (
    <div ref={ref} style={{ position: 'relative' }}>
      <button type="button" className="input row" style={{ justifyContent: 'space-between', cursor: 'pointer', textAlign: 'left' }} onClick={() => setOpen(!open)} aria-expanded={open}>
        <span className="ellipsis">
          <span style={{ fontWeight: value ? 600 : 400, color: value ? '#111827' : '#6B7280' }}>{value?.name || placeholder}</span>
          {value && <span className="faint" style={{ fontSize: 12 }}> · {Number(value.balance) > 0 ? `owes ${N2(value.balance)}` : Number(value.balance) < 0 ? `${N2(-value.balance)} credit` : 'nothing owed'}</span>}
        </span>
        <Icon name="chevD" size={14} color="#9CA3AF" />
      </button>
      {open && (
        <div className="card rise" style={{ position: 'absolute', left: 0, right: 0, top: 'calc(100% + 4px)', zIndex: 35, padding: 6, boxShadow: 'var(--shadow-drawer)' }}>
          <input className="input input-sm" autoFocus placeholder="Name or phone" value={q} onChange={(e) => setQ(e.target.value)} style={{ marginBottom: 4 }} />
          {walkIn && <button className="nav-item" style={{ fontSize: 13.5, padding: '8px 10px' }} onClick={() => { onChange(null); setOpen(false); setQ(''); }}>Walk-in customer</button>}
          {hits.map((c) => (
            <button key={c.id} className="nav-item" style={{ fontSize: 13.5, padding: '8px 10px', justifyContent: 'space-between' }} onClick={() => { onChange(c); setOpen(false); setQ(''); }}>
              <span className="ellipsis">{c.name}{c.price_list_name ? <span className="faint"> · {c.price_list_name}</span> : null}</span>
              <span className="faint" style={{ fontSize: 12, flex: 'none' }}>{c.phone || ''}</span>
            </button>
          ))}
          {allowNew && q.trim().length > 1 && !hits.some((c) => c.name.toLowerCase() === q.trim().toLowerCase()) && (
            <NewCustomerInline name={q.trim()} onDone={(c) => { onChange(c); setOpen(false); setQ(''); }} />
          )}
        </div>
      )}
    </div>
  );
}

function NewCustomerInline({ name, onDone }: { name: string; onDone: (c: Customer) => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const [f, setF] = useState({ phone: '', email: '', tin: '', address: '', city: '', country: 'NG' });
  const [more, setMore] = useState(false);
  const [busy, setBusy] = useState(false);
  const set = (k: keyof typeof f, v: string) => setF((x) => ({ ...x, [k]: v }));
  const tinErr = f.country === 'NG' ? taxIdError(f.tin) : null;
  async function add() {
    if (tinErr) { toast(tinErr, 'err'); return; }
    setBusy(true);
    try {
      const id = await rpc<string>('save_customer', { p_org: orgId, p_customer: { name, phone: f.phone || null, email: f.email || null, tin: f.tin || null,
        address: f.address || null, city: f.city || null, country: f.country || 'NG' } });
      await qc.invalidateQueries({ queryKey: ['customers'] });
      const list = await rpc<{ customers: Customer[] }>('get_customers', { p_org: orgId });
      const c = list.customers.find((x) => x.id === id);
      if (c) onDone(c);
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  return (
    <div style={{ borderTop: '1px solid #F3F4F6', marginTop: 4, padding: '8px 6px 2px' }}>
      <div style={{ fontSize: 12, marginBottom: 6 }}>Add <b>{name}</b> as a new customer</div>
      <div className="row">
        <input className="input input-sm" placeholder="Phone (for WhatsApp receipts)" value={f.phone} onChange={(e) => set('phone', e.target.value)} inputMode="tel" />
        <button className="btn btn-primary btn-xs" disabled={busy} onClick={add}>Add</button>
      </div>
      {!more ? (
        <button type="button" className="link" style={{ fontSize: 12, marginTop: 6 }} onClick={() => setMore(true)}>Add email, Tax ID and address (optional)</button>
      ) : (
        <div className="stack" style={{ gap: 6, marginTop: 6 }}>
          <input className="input input-sm" placeholder="Email" value={f.email} onChange={(e) => set('email', e.target.value)} inputMode="email" />
          <input className={'input input-sm' + (tinErr ? ' err' : '')} placeholder={f.country === 'NG' ? 'Tax ID (13 digits)' : 'Tax number'} value={f.tin} onChange={(e) => set('tin', e.target.value)} title={tinErr || undefined} />
          {tinErr && <div className="err-text" style={{ fontSize: 12 }}>{tinErr}</div>}
          <input className="input input-sm" placeholder="Street address" value={f.address} onChange={(e) => set('address', e.target.value)} />
          <div className="row">
            <input className="input input-sm" placeholder="City" value={f.city} onChange={(e) => set('city', e.target.value)} />
            <select className="input input-sm" value={f.country} onChange={(e) => set('country', e.target.value)} aria-label="Country">{COUNTRIES.map((c) => <option key={c.code} value={c.code}>{c.name}</option>)}</select>
          </div>
          {isExport(f.country) && <div className="faint" style={{ fontSize: 12 }}>Outside Nigeria: their sales are exports and zero-rated for VAT.</div>}
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------- spoken confirmation
export function announce(text: string) {
  try {
    const ctx = new (window.AudioContext || (window as any).webkitAudioContext)();
    const o = ctx.createOscillator(), g = ctx.createGain();
    o.connect(g); g.connect(ctx.destination);
    o.frequency.setValueAtTime(880, ctx.currentTime); o.frequency.setValueAtTime(1320, ctx.currentTime + 0.12);
    g.gain.setValueAtTime(0.15, ctx.currentTime); g.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + 0.35);
    o.start(); o.stop(ctx.currentTime + 0.36);
  } catch { /* no audio */ }
  try {
    const u = new SpeechSynthesisUtterance(text);
    const voices = window.speechSynthesis.getVoices();
    u.voice = voices.find((v) => /en-NG/i.test(v.lang)) || voices.find((v) => /en-GB/i.test(v.lang)) || null;
    u.lang = u.voice?.lang || 'en-NG'; u.rate = 1;
    window.speechSynthesis.cancel(); setTimeout(() => window.speechSynthesis.speak(u), 380);
  } catch { /* no voice */ }
}
export const nairaWords = (n: number) => `${Math.round(n).toLocaleString('en-NG')} naira`;

// ---------------------------------------------------------------- waiting for a transfer
export function PayWait({ request, saleNumber, onPaid, onClose, onCancelSale }: {
  request: PayRequest; saleNumber?: string; onPaid: (r: PayRequest) => void; onClose: () => void; onCancelSale?: () => void;
}) {
  const [r, setR] = useState<PayRequest>(request);
  const [qr, setQr] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const toast = useToast();
  const done = useRef(false);
  // Ask Flutterwave (or the partner rail) for the account, link or QR if the database only opened the request.
  useEffect(() => {
    let live = true;
    if (r.status === 'creating') {
      edge('payments', { action: 'activate', request_id: r.id }).then((x) => {
        if (!live) return;
        if (x.ok === false) setErr(x.error || 'The payment provider did not answer.');
        else if ((x as any).request) setR((x as any).request);
      });
    }
    return () => { live = false; };
  }, []); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    const text = r.qr_image ? '' : r.method === 'qr' && r.link_url ? r.link_url : '';
    if (text) qrSvg(text, 220).then(setQr).catch(() => {});
  }, [r.link_url, r.qr_image, r.method]);
  // Check every four seconds; the webhook usually confirms first.
  useEffect(() => {
    if (r.status !== 'pending') return;
    const t = window.setInterval(async () => {
      const x = await edge<{ request: PayRequest }>('payments', { action: 'check', request_id: r.id });
      if (x.request) setR(x.request);
    }, 4000);
    return () => window.clearInterval(t);
  }, [r.id, r.status]);
  useEffect(() => {
    if (r.status === 'paid' && !done.current) {
      done.current = true;
      announce(`Payment received. ${nairaWords(Number(r.paid_amount || r.amount))}${r.payer ? ` from ${r.payer}` : ''}.`);
      onPaid(r);
    }
  }, [r.status]); // eslint-disable-line react-hooks/exhaustive-deps
  const copy = (t: string) => { navigator.clipboard?.writeText(t).then(() => toast('Copied')); };
  const expiry = r.expires_at ? new Date(r.expires_at) : null;
  return (
    <Modal onClose={onClose} width={460}>
      <ModalHead title={r.method === 'account' ? 'Pay by transfer' : r.method === 'qr' ? 'Scan to pay' : 'Payment link'} sub={`${saleNumber ? saleNumber + ' · ' : ''}${N2(r.amount)}`} onClose={onClose} />
      <div className="modal-body" style={{ alignItems: 'stretch' }}>
        {err ? <Alert kind="red" icon="alert">{err} Take another way of paying, or try again.</Alert>
          : r.status === 'creating' ? <div className="row" style={{ justifyContent: 'center', padding: 30 }}><Spinner /></div>
          : r.status === 'paid' ? <Alert kind="green" icon="check">Paid {N2(r.paid_amount || r.amount)}{r.payer ? ` by ${r.payer}` : ''}.</Alert>
          : r.status === 'failed' ? <Alert kind="red" icon="alert">{r.error || 'This way of paying is not available right now.'}</Alert>
          : r.method === 'account' ? (
            <div style={{ textAlign: 'center', padding: '6px 0' }}>
              <div className="muted" style={{ fontSize: 13 }}>Ask the customer to transfer exactly</div>
              <div style={{ fontSize: 32, fontWeight: 700, margin: '4px 0 14px' }}>{N2(r.amount)}</div>
              <div className="muted" style={{ fontSize: 13 }}>to</div>
              <button className="btn btn-ghost" onClick={() => r.account_number && copy(r.account_number)} style={{ fontSize: 34, fontWeight: 700, letterSpacing: '.06em', color: '#111827' }} aria-label="Copy account number">
                {r.account_number}<Icon name="copy" size={16} color="#9CA3AF" />
              </button>
              <div style={{ fontWeight: 600 }}>{r.bank_name}</div>
              <div className="muted" style={{ fontSize: 13 }}>{r.account_name}</div>
              {expiry && <div className="faint" style={{ fontSize: 12, marginTop: 10 }}>This account takes one payment and closes at {expiry.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', timeZone: 'Africa/Lagos' })}.</div>}
            </div>
          ) : (
            <div style={{ textAlign: 'center' }}>
              {r.qr_image ? <img src={r.qr_image} alt="Payment QR code" style={{ width: 220, height: 220 }} />
                : qr ? <div style={{ display: 'inline-block', width: 220 }} dangerouslySetInnerHTML={{ __html: qr }} /> : null}
              {r.link_url && (
                <div className="row" style={{ marginTop: 10, justifyContent: 'center' }}>
                  <input className="input input-sm" readOnly value={r.link_url} style={{ maxWidth: 300 }} onFocus={(e) => e.target.select()} />
                  <button className="btn btn-secondary btn-xs" onClick={() => copy(r.link_url!)}>Copy</button>
                </div>
              )}
              <div className="faint" style={{ fontSize: 12, marginTop: 8 }}>{r.method === 'qr' ? 'Any banking app that scans NQR or a phone camera opens the payment page.' : 'Send this link by WhatsApp or SMS. It opens a checkout for card, transfer or USSD.'}</div>
            </div>
          )}
        {r.status === 'pending' && <div className="row" style={{ justifyContent: 'center', gap: 8, color: '#6B7280', fontSize: 13 }}><Spinner small />Waiting for the money. Counta says it out loud when it lands.</div>}
      </div>
      <div className="modal-ft">
        {onCancelSale && r.status !== 'paid' && <button className="btn btn-ghost" onClick={onCancelSale}>Cancel this sale</button>}
        <button className="btn btn-secondary" onClick={onClose}>{r.status === 'paid' ? 'Done' : 'Keep waiting in the background'}</button>
      </div>
    </Modal>
  );
}

// ---------------------------------------------------------------- receipt / document actions
export function SendBox({ sale, onSent }: { sale: Sale; onSent?: () => void }) {
  const toast = useToast();
  const [to, setTo] = useState(sale.customer_phone || '');
  const [email, setEmail] = useState(sale.customer_email || '');
  const [busy, setBusy] = useState<string | null>(null);
  async function send(channel: 'whatsapp' | 'email') {
    setBusy(channel);
    try {
      await rpc('send_document', { p_sale: sale.id, p_channel: channel, p_to: channel === 'whatsapp' ? to : email });
      toast(channel === 'whatsapp' ? 'Sent by WhatsApp' : 'Sent by email'); onSent?.();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(null);
  }
  return (
    <div className="stack" style={{ gap: 8 }}>
      <div className="row"><input className="input input-sm" placeholder="WhatsApp number" value={to} onChange={(e) => setTo(e.target.value)} inputMode="tel" />
        <button className="btn btn-secondary btn-sm" disabled={!to.trim() || !!busy} onClick={() => send('whatsapp')}><Icon name="wa" size={14} />{busy === 'whatsapp' ? 'Sending…' : 'WhatsApp'}</button></div>
      <div className="row"><input className="input input-sm" placeholder="Email address" value={email} onChange={(e) => setEmail(e.target.value)} inputMode="email" />
        <button className="btn btn-secondary btn-sm" disabled={!email.trim() || !!busy} onClick={() => send('email')}><Icon name="mail" size={14} />{busy === 'email' ? 'Sending…' : 'Email'}</button></div>
    </div>
  );
}

export function PrintButtons({ sale }: { sale: Sale }) {
  const toast = useToast();
  const [name, setName] = useState(printerName());
  const [preview, setPreview] = useState(false);
  return (
    <div className="row wrap">
      <button className="btn btn-secondary btn-sm" onClick={() => setPreview(true)}><Icon name="file" size={14} />{sale.doc_type === 'receipt' ? 'A4 receipt or PDF' : 'View, print or PDF'}</button>
      {preview && <DocPreview sale={sale} onClose={() => setPreview(false)} />}
      {bluetoothSupported() && (
        <button className="btn btn-secondary btn-sm" onClick={async () => {
          try { if (!printerName()) setName(await connectPrinter()); await printBluetooth(sale); toast('Printed'); }
          catch (e) { if ((e as Error).name !== 'NotFoundError') toast((e as Error).message, 'err'); }
        }}><Icon name="printer" size={14} />{name ? `Print on ${name}` : 'Bluetooth printer'}</button>
      )}
      <button className="btn btn-secondary btn-sm" onClick={() => { try { printBrowser(sale); } catch (e) { toast((e as Error).message, 'err'); } }}><Icon name="printer" size={14} />Till slip</button>
      <a className="btn btn-ghost btn-sm" href={docUrl(sale.public_token)} target="_blank" rel="noreferrer"><Icon name="external" size={14} />Open the customer's copy</a>
    </div>
  );
}

// The branded A4 document as the customer sees it, with print and save as PDF.
export function DocPreview({ sale, onClose }: { sale: Sale; onClose: () => void }) {
  return (
    <Modal onClose={onClose} width={900}>
      <ModalHead title={`${DOC_LABEL[sale.doc_type]} ${sale.number}`} sub="As your customer sees it. Change the template and colour in Settings, Branding." onClose={onClose}
        extra={<button className="btn btn-primary btn-sm" onClick={() => window.print()}><Icon name="printer" size={14} color="#fff" />Print or save as PDF</button>} />
      <div className="modal-body" style={{ background: '#F4F6F8' }}><InvoiceDoc d={sale as unknown as DocData} /></div>
      <PrintPortal><InvoiceDoc d={sale as unknown as DocData} fixed /></PrintPortal>
    </Modal>
  );
}

export function ReceiptModal({ sale, change, onClose, onNew }: { sale: Sale; change?: number; onClose: () => void; onNew?: () => void }) {
  return (
    <Modal onClose={onClose} width={520}>
      <ModalHead title={`${DOC_LABEL[sale.doc_type]} ${sale.number}`} sub={`${sale.customer_name || ''} · ${N2(sale.total)}`} onClose={onClose} extra={<StatusChip s={sale.status} />} />
      <div className="modal-body">
        {!!change && change > 0.004 && <div style={{ background: '#F0FDF4', borderRadius: 12, padding: 16, textAlign: 'center' }}>
          <div className="muted" style={{ fontSize: 13 }}>Change to give</div><div style={{ fontSize: 30, fontWeight: 700, color: '#15803D' }}>{N2(change)}</div></div>}
        {sale.status === 'pending' && <Alert kind="yellow" icon="clock">Waiting for the transfer. The sale posts and the stock moves as soon as the money lands.</Alert>}
        {(sale.payments || []).some((p: any) => p.status === 'pending') && <Alert kind="blue" icon="info">A manager or the bookkeeper confirms bank transfers and POS payments once they show in the bank.</Alert>}
        <SaleLines sale={sale} compact />
        <PrintButtons sale={sale} />
        <SendBox sale={sale} />
      </div>
      <div className="modal-ft">
        {onNew && <button className="btn btn-primary" onClick={onNew}><Icon name="plus" size={14} color="#fff" />New sale</button>}
        <button className="btn btn-secondary" onClick={onClose}>Close</button>
      </div>
    </Modal>
  );
}

export function SaleLines({ sale, compact }: { sale: Sale; compact?: boolean }) {
  const { data: inv } = useInventory();
  return (
    <div className="card" style={{ overflow: 'hidden', borderRadius: 12 }}>
      {(sale.lines || []).map((l) => (
        <div key={l.id} className="tr" style={{ gridTemplateColumns: compact ? '1fr auto' : 'minmax(160px,2fr) 70px 110px 90px 110px', padding: '9px 14px' }}>
          <span style={{ minWidth: 0 }}>{l.description}{compact && <span className="faint" style={{ display: 'block', fontSize: 12 }}>{Number(l.qty)} {l.unit_label} × {N2(l.unit_price)}{Number(l.discount) ? ` − ${N2(l.discount)}` : ''}{` · VAT ${vatStatusOf(l.vat_treatment)}`}{l.vat_treatment !== 'standard' ? ` ${l.vat_treatment === 'zero' ? 'zero-rated' : 'exempt'}` : ''}{Number(l.returned_qty) ? ` · ${Number(l.returned_qty)} returned` : ''}</span>}</span>
          {!compact && <span className="right num">{Number(l.qty)}</span>}
          {!compact && <span className="right num">{N2(l.unit_price)}</span>}
          {!compact && <span className="right faint" title={`VAT status ${vatStatusOf(l.vat_treatment)}: ${VAT_STATUS[vatStatusOf(l.vat_treatment)].label}${sale.export && l.item_vat_treatment && l.item_vat_treatment !== 'zero' ? ` (export; normally ${l.item_vat_treatment === 'exempt' ? 'exempt' : 'VATable'})` : ''}`}>
            {l.vat_treatment === 'standard' ? N2(l.vat) : l.vat_treatment === 'zero' ? 'Zero-rated' : 'Exempt'}<span className={'chip ' + VAT_STATUS[vatStatusOf(l.vat_treatment)].tone} style={{ marginLeft: 6, fontSize: 10, padding: '1px 6px' }}>{vatStatusOf(l.vat_treatment)}</span>
          </span>}
          <span className="right num" style={{ fontWeight: 500 }}>{N2(l.gross)}</span>
        </div>
      ))}
      <div className="stack" style={{ padding: '10px 14px', gap: 4, borderTop: '1px solid #F3F4F6', fontSize: 13 }}>
        <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">Before VAT</span><span className="num">{N2(sale.subtotal)}</span></div>
        <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">VAT{inv?.org.vat_registered ? ' 7.5%' : ''}</span><span className="num">{N2(sale.vat_total)}</span></div>
        <div className="row" style={{ justifyContent: 'space-between', fontWeight: 700, fontSize: 15 }}><span>Total</span><span className="num">{N2(sale.total)}</span></div>
        {Number(sale.amount_paid) > 0 && <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">Paid</span><span className="num">{N2(sale.amount_paid)}</span></div>}
        {Number(sale.credited) > 0 && <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">Credited</span><span className="num">{N2(sale.credited)}</span></div>}
        {Number(sale.balance) > 0.004 && <div className="row" style={{ justifyContent: 'space-between', color: '#C2410C', fontWeight: 600 }}><span>Balance</span><span className="num">{N2(sale.balance)}</span></div>}
      </div>
    </div>
  );
}

export function PaymentsList({ sale }: { sale: Sale }) {
  const items = [...(sale.payments || []), ...(sale.refunds || []).map((r: any) => ({ ...r, direction: 'out' }))];
  if (!items.length && !(sale.credits || []).length) return null;
  return (
    <div className="stack" style={{ gap: 6 }}>
      {items.map((p: any) => (
        <div key={p.id} className="row" style={{ justifyContent: 'space-between', fontSize: 13, gap: 10 }}>
          <span className="ellipsis">{p.direction === 'out' ? 'Refund' : METHOD_LABEL[p.method] || p.method} · {p.number}{p.reference ? ` · ${p.reference}` : ''}<span className="faint"> · {when(p.received_at)}</span></span>
          <span className="row" style={{ gap: 8 }}>{p.status && p.status !== 'confirmed' && <StatusChip s={p.status} />}<b className="num">{p.direction === 'out' ? '−' : ''}{N2(p.amount)}</b></span>
        </div>
      ))}
      {(sale.credits || []).map((c: any) => (
        <div key={c.credit_note_id} className="row" style={{ justifyContent: 'space-between', fontSize: 13 }}><span>Credit note {c.number}</span><b className="num">{N2(c.amount)}</b></div>
      ))}
    </div>
  );
}

// Asks Flutterwave (or the partner rail) for a way to pay a document from the back office.
export function RequestPayment({ sale, onClose }: { sale: Sale; onClose: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const [req, setReq] = useState<PayRequest | null>(null);
  const [busy, setBusy] = useState(false);
  async function open(method: 'account' | 'link' | 'qr') {
    setBusy(true);
    try {
      const r = await edgeOk<{ request: PayRequest }>('payments', { action: 'request', org_id: orgId, sale_id: sale.id, method });
      setReq(r.request);
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  if (req) return <PayWait request={req} saleNumber={sale.number} onPaid={() => {}} onClose={onClose} />;
  return (
    <Modal onClose={onClose} width={440}>
      <ModalHead title="Get paid" sub={`${sale.number} · ${N2(sale.balance)} to pay`} onClose={onClose} />
      <div className="modal-body">
        {([['account', 'One-off account number', 'The customer transfers from any bank app. Confirmed the moment it lands.'],
          ['link', 'Payment link', 'Card, transfer or USSD on a Flutterwave checkout page. Send it by WhatsApp.'],
          ['qr', 'QR code', 'For a customer standing in front of you.']] as const).map(([m, t, d]) => (
          <button key={m} className="entry-card" disabled={busy} onClick={() => open(m)} style={{ textAlign: 'left', padding: 14, borderRadius: 12, background: '#fff', cursor: 'pointer' }}>
            <div style={{ fontWeight: 600 }}>{t}</div><div className="muted" style={{ fontSize: 13, marginTop: 2 }}>{d}</div>
          </button>
        ))}
        <div className="faint" style={{ fontSize: 12 }}>The customer can also pay from the document link: <a href={docUrl(sale.public_token)} target="_blank" rel="noreferrer">{docUrl(sale.public_token).replace(/^https?:\/\//, '')}</a></div>
      </div>
    </Modal>
  );
}

export function RecordPayment({ sale, onClose, onDone }: { sale: Sale; onClose: () => void; onDone?: () => void }) {
  const { orgId } = useSession();
  const { data: inv } = useInventory();
  const toast = useToast();
  const qc = useQueryClient();
  const [f, setF] = useState({ amount: String(Number(sale.balance) || ''), method: 'transfer', reference: '', bank_account_id: '', wht_amount: '', received_at: new Date().toLocaleDateString('en-CA', { timeZone: 'Africa/Lagos' }) });
  const [accounts, setAccounts] = useState<any[]>([]);
  const [busy, setBusy] = useState(false);
  const canConfirm = can(inv, 'keep_books') || can(inv, 'approve_adjustments');
  const [confirm, setConfirm] = useState(false);
  useEffect(() => { moneyAccounts(orgId!).then((accounts) => setAccounts(accounts || [])).catch(() => {}); }, [orgId]); // eslint-disable-line react-hooks/exhaustive-deps
  const set = (k: string, v: string) => setF((x) => ({ ...x, [k]: v }));
  async function save() {
    setBusy(true);
    try {
      await rpc('record_payment', { p_org: orgId, p_payment: { sale_id: sale.id, amount: Number(f.amount) || 0, method: f.method, confirmed: confirm,
        reference: f.reference || null, bank_account_id: f.bank_account_id || null, wht_amount: Number(f.wht_amount) || 0, received_at: f.received_at } });
      toast('Payment recorded');
      await Promise.all(['sale', 'sales', 'customers', 'inbox'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
      onDone?.(); onClose();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  const banks = accounts.filter((a) => a.kind === 'bank' || a.kind === 'wallet');
  const cash = accounts.filter((a) => a.kind === 'cash');
  return (
    <Modal onClose={onClose} width={480}>
      <ModalHead title="Record a payment" sub={`${sale.number} · ${sale.customer_name} · ${N2(sale.balance)} to pay`} onClose={onClose} />
      <div className="modal-body">
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <Field label="Amount received"><input className="input" inputMode="decimal" value={f.amount} onChange={(e) => set('amount', e.target.value)} /></Field>
          <Field label="Date"><input className="input" type="date" value={f.received_at} onChange={(e) => set('received_at', e.target.value)} /></Field>
        </div>
        <Field label="How it was paid">
          <select className="input" value={f.method} onChange={(e) => set('method', e.target.value)}>
            <option value="transfer">Bank transfer</option><option value="cash">Cash</option><option value="pos">POS</option><option value="card">Card</option><option value="cheque">Cheque</option><option value="other">Other</option>
          </select>
        </Field>
        {f.method !== 'cash' ? (
          <Field label="Into which account" hint="Transfers and POS wait for someone who keeps the books to confirm them against the bank, unless you are that person.">
            <select className="input" value={f.bank_account_id} onChange={(e) => set('bank_account_id', e.target.value)}>
              <option value="">Choose the account</option>{banks.map((a) => <option key={a.id} value={a.id}>{a.name}{a.account_number ? ` · ${a.account_number.slice(-4)}` : ''}</option>)}
            </select>
          </Field>
        ) : (
          <Field label="Into which cash drawer">
            <select className="input" value={f.bank_account_id} onChange={(e) => set('bank_account_id', e.target.value)}>
              <option value="">The branch drawer</option>{cash.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}
            </select>
          </Field>
        )}
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <Field label="Reference"><input className="input" value={f.reference} onChange={(e) => set('reference', e.target.value)} placeholder="Bank reference" /></Field>
          <Field label="WHT deducted by the customer" hint="Keep the credit note; it is your tax credit."><input className="input" inputMode="decimal" value={f.wht_amount} onChange={(e) => set('wht_amount', e.target.value)} placeholder="0.00" /></Field>
        </div>
        {canConfirm && f.method !== 'cash' && <label className="check"><input type="checkbox" checked={confirm} onChange={(e) => setConfirm(e.target.checked)} />I can see this money in the account: confirm it now</label>}
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={busy || !(Number(f.amount) > 0 || Number(f.wht_amount) > 0) || (confirm && !f.bank_account_id)} onClick={save}>Record payment</button></div>
    </Modal>
  );
}

export const dueText = (s: { due_date: string | null; overdue_days?: number; balance: number }) =>
  Number(s.balance) <= 0.004 ? '' : s.overdue_days ? `${s.overdue_days} day${s.overdue_days === 1 ? '' : 's'} overdue` : s.due_date ? `due ${fmtDay(s.due_date)}` : '';
