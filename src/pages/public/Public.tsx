// Pages anyone with the link can open, without signing in: a branded document (invoice, receipt, order, quote) with a way
// to pay it and, for shop orders, where the order has got to. The online shop lives in ShopPage.tsx.
import { useEffect, useState } from 'react';
import { useParams, useSearchParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { rpc, photoUrl } from '../../lib/supabase';
import { edge } from '../../lib/api';
import { N2, fmtDay, when } from '../../lib/format';
import { InvoiceDoc, PrintPortal, cleanHex, onColor } from '../../components/InvoiceDoc';
import { qrSvg } from '../../lib/labels';
import { Icon } from '../../components/Icon';
import { Alert, Spinner } from '../../components/ui';

export function Frame({ children, org }: { children: React.ReactNode; org?: any }) {
  // A logo that will not load (removed, or not yet uploaded) falls back to the business's initials.
  const [noLogo, setNoLogo] = useState(false);
  return (
    <div style={{ minHeight: '100vh', background: '#F4F6F8', padding: '24px 12px 48px' }}>
      <div style={{ maxWidth: 760, margin: '0 auto' }} className="stack">
        {org && <div className="row" style={{ gap: 12, marginBottom: 14 }}>
          {org.logo_path && !noLogo ? <img src={photoUrl(org.logo_path) || ''} alt="" onError={() => setNoLogo(true)} style={{ width: 44, height: 44, borderRadius: 10, objectFit: 'cover' }} />
            : <span className="org-ini">{String(org.name || '').slice(0, 2).toUpperCase()}</span>}
          <div><div style={{ fontWeight: 700, fontSize: 17 }}>{org.name}</div><div className="muted" style={{ fontSize: 12 }}>{[org.address, org.phone, org.email].filter(Boolean).join(' · ')}</div></div>
        </div>}
        {children}
        <div className="faint" style={{ fontSize: 11, textAlign: 'center', marginTop: 24 }}>Powered by Counta · TaxStreem</div>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- document
export function PublicDoc() {
  const { token = '' } = useParams();
  const [params] = useSearchParams();
  const doc = useQuery({ queryKey: ['public-doc', token], queryFn: () => rpc<any>('public_document', { p_token: token }), retry: false });
  const [req, setReq] = useState<any>(null);
  const [status, setStatus] = useState<{ status: string; balance: number } | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [qr, setQr] = useState('');
  const d = doc.data;
  const balance = status ? Number(status.balance) : Number(d?.balance || 0);
  const paid = (status?.status || d?.status) === 'paid' || (d && balance <= 0.004 && ['receipt', 'invoice', 'order'].includes(d.doc_type));
  const waiting = req?.status === 'pending' || params.get('paid') === '1';
  // While a payment is on its way, ask every five seconds.
  useEffect(() => {
    if (!waiting || paid) return;
    const t = window.setInterval(async () => {
      const r = await edge<any>('payments', { action: 'public_check', token });
      if (r.ok !== false) { setStatus({ status: r.status, balance: r.balance }); if (r.request) setReq(r.request); }
    }, 5000);
    return () => window.clearInterval(t);
  }, [waiting, paid, token]);
  useEffect(() => { if (req?.method === 'qr' && req.link_url && !req.qr_image) qrSvg(req.link_url, 200).then(setQr); }, [req?.link_url]); // eslint-disable-line react-hooks/exhaustive-deps
  async function pay(method: 'account' | 'link' | 'qr') {
    setBusy(method); setErr(null);
    const r = await edge<any>('payments', { action: 'public_pay', token, method });
    if (r.ok === false) setErr(r.error || 'Paying online is not available right now. Pay by bank transfer to the business instead.');
    else { setReq(r.request); if (method === 'link' && r.request?.link_url) window.location.href = r.request.link_url; }
    setBusy(null);
  }
  if (doc.isLoading) return <Frame><div style={{ padding: 60, display: 'grid', placeItems: 'center' }}><Spinner /></div></Frame>;
  // An invoice to a business reaches its buyer once NRS has signed it.
  if (doc.error && /waiting for NRS/i.test(String((doc.error as Error).message || ''))) {
    return <Frame><Alert kind="blue" icon="clock">This document is waiting for NRS to sign it. Open the link again in a few minutes.</Alert></Frame>;
  }
  if (doc.error || !d) return <Frame><Alert kind="yellow" icon="alert">This link does not open a document. Ask the business to send it again.</Alert></Frame>;
  const owe = !paid && balance > 0.004 && !['void', 'cancelled', 'credited', 'converted', 'expired'].includes(d.status) && d.doc_type !== 'quote' && d.doc_type !== 'credit_note';
  const tracking = d.tracking;
  return (
    <Frame>
      {d.status === 'void' && <Alert kind="grey" icon="info">This document was cancelled.</Alert>}
      {tracking && <OrderTracking t={tracking} brand={d.org?.brand_color} />}
      {paid ? <Alert kind="green" icon="check">Paid. Thank you.</Alert> : owe && (
        <div className="stack no-print" style={{ gap: 10, background: '#fff', border: '1px solid var(--line)', borderRadius: 14, padding: 16 }}>
          <div className="row wrap" style={{ justifyContent: 'space-between' }}>
            <div style={{ fontWeight: 700, fontSize: 18 }}>{N2(balance)} to pay{d.pay_later ? (d.delivery_method === 'delivery' ? ' on delivery' : ' at pickup') : ''}</div>
            {d.due_date && !d.pay_later && <div className="muted" style={{ fontSize: 13 }}>Due {fmtDay(d.due_date)}</div>}
            {d.pay_later && <div className="muted" style={{ fontSize: 13, flexBasis: '100%' }}>Or pay now online and skip the wait.</div>}
          </div>
          {err && <Alert kind="red" icon="alert">{err}</Alert>}
          {req && req.status === 'pending' && req.method === 'account' ? (
            <div style={{ textAlign: 'center', background: '#F8FAFC', borderRadius: 12, padding: 16 }}>
              <div className="muted" style={{ fontSize: 13 }}>Transfer exactly {N2(req.amount)} to</div>
              <div style={{ fontSize: 30, fontWeight: 700, letterSpacing: '.06em', margin: '6px 0' }}>{req.account_number}</div>
              <div style={{ fontWeight: 600 }}>{req.bank_name}</div><div className="muted" style={{ fontSize: 13 }}>{req.account_name}</div>
              {req.direct && req.pay_ref && (
                <div style={{ marginTop: 10, fontSize: 14 }}>Write <b style={{ letterSpacing: '.02em' }}>{req.pay_ref}</b> in the transfer&apos;s description so it is matched to this {d.doc_type === 'order' ? 'order' : 'invoice'}.</div>
              )}
              <div className="row" style={{ justifyContent: 'center', gap: 8, marginTop: 12, color: '#6B7280', fontSize: 13 }}><Spinner small />This page updates when the money lands.</div>
            </div>
          ) : req && req.status === 'pending' && req.method === 'qr' ? (
            <div style={{ textAlign: 'center', background: '#F8FAFC', borderRadius: 12, padding: 16 }}>
              {req.qr_image ? <img src={req.qr_image} alt="QR code to pay" style={{ width: 200 }} /> : <div style={{ width: 200, margin: '0 auto' }} dangerouslySetInnerHTML={{ __html: qr }} />}
            </div>
          ) : waiting ? <div className="row" style={{ gap: 8, color: '#6B7280', fontSize: 13 }}><Spinner small />Checking your payment…</div> : (
            <div className="row wrap">
              <button className="btn btn-primary" style={brandBtn(d.org?.brand_color)} disabled={!!busy} onClick={() => pay('account')}><Icon name="building" size={16} color={onColor(cleanHex(d.org?.brand_color))} />{busy === 'account' ? 'Getting an account…' : 'Pay by bank transfer'}</button>
              <button className="btn btn-secondary" disabled={!!busy} onClick={() => pay('link')}><Icon name="card" size={16} />{busy === 'link' ? 'Opening…' : 'Card or USSD'}</button>
            </div>
          )}
        </div>
      )}
      <InvoiceDoc d={d} />
      <PrintPortal><InvoiceDoc d={d} fixed /></PrintPortal>
      <div className="row no-print" style={{ justifyContent: 'center' }}><button className="btn btn-secondary btn-sm" onClick={() => window.print()}><Icon name="printer" size={14} />Print or save as PDF</button></div>
    </Frame>
  );
}

const brandBtn = (c?: string | null) => ({ background: cleanHex(c), borderColor: cleanHex(c), color: onColor(cleanHex(c)) });

// Where an online order has got to: placed, confirmed, on its way (or ready for pickup), delivered.
function OrderTracking({ t, brand }: { t: any; brand?: string | null }) {
  const color = cleanHex(brand);
  const pickup = t.method === 'pickup';
  const steps = [
    { label: 'Order placed', at: t.placed_at, done: true },
    { label: 'Confirmed by the shop', at: t.confirmed_at, done: !!t.confirmed },
    pickup
      ? { label: 'Ready for pickup', at: t.dispatched_at, done: ['dispatched', 'delivered'].includes(t.delivery_status) }
      : { label: t.scheduled_for ? `On its way (planned ${fmtDay(t.scheduled_for)})` : 'On its way', at: t.dispatched_at, done: ['dispatched', 'delivered'].includes(t.delivery_status) },
    { label: pickup ? 'Collected' : 'Delivered', at: t.delivered_at, done: t.delivery_status === 'delivered' },
  ];
  if (t.cancelled) return <Alert kind="grey" icon="info">This order was cancelled.</Alert>;
  return (
    <div className="card card-pad no-print" style={{ padding: 16 }}>
      <div className="label" style={{ marginBottom: 10 }}>Your order</div>
      <div className="stack" style={{ gap: 0 }}>
        {steps.map((s, i) => (
          <div key={i} className="row" style={{ gap: 12, alignItems: 'flex-start' }}>
            <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', flex: 'none' }}>
              <span style={{ width: 22, height: 22, borderRadius: 11, display: 'grid', placeItems: 'center', background: s.done ? color : '#E5E7EB', color: onColor(color) }}>
                {s.done && <Icon name="check" size={13} color={onColor(color)} />}
              </span>
              {i < steps.length - 1 && <span style={{ width: 2, height: 22, background: steps[i + 1].done ? color : '#E5E7EB' }} />}
            </div>
            <div style={{ paddingTop: 1 }}>
              <div style={{ fontWeight: s.done ? 600 : 500, color: s.done ? '#111827' : '#6B7280', fontSize: 14 }}>{s.label}</div>
              {s.done && s.at && <div className="faint" style={{ fontSize: 12 }}>{when(s.at)}</div>}
            </div>
          </div>
        ))}
      </div>
      {pickup && t.pickup_address && <div className="muted" style={{ fontSize: 13, marginTop: 10 }}>Pick up from: {t.pickup_address}</div>}
    </div>
  );
}

export { ShopPage } from './ShopPage';
