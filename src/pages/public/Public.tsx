// Pages anyone with the link can open, without signing in: a document (invoice, receipt, order, quote) with a way to pay it,
// and the online shop.
import { useEffect, useMemo, useRef, useState } from 'react';
import { useParams, useSearchParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { rpc, photoUrl } from '../../lib/supabase';
import { edge } from '../../lib/api';
import { N2, fmtDay, when } from '../../lib/format';
import { InvoiceDoc, PrintPortal, cleanHex, onColor } from '../../components/InvoiceDoc';
import { qrSvg } from '../../lib/labels';
import { Icon } from '../../components/Icon';
import { Alert, Spinner } from '../../components/ui';

const LABEL: Record<string, string> = { receipt: 'Receipt', invoice: 'Invoice', quote: 'Quote', order: 'Order', credit_note: 'Credit note' };

function Frame({ children, org }: { children: React.ReactNode; org?: any }) {
  return (
    <div style={{ minHeight: '100vh', background: '#F4F6F8', padding: '24px 12px 48px' }}>
      <div style={{ maxWidth: 760, margin: '0 auto' }} className="stack">
        {org && <div className="row" style={{ gap: 12, marginBottom: 14 }}>
          {org.logo_path ? <img src={photoUrl(org.logo_path) || ''} alt="" style={{ width: 44, height: 44, borderRadius: 10, objectFit: 'cover' }} /> : <span className="org-ini">{String(org.name || '').slice(0, 2).toUpperCase()}</span>}
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
            <div style={{ fontWeight: 700, fontSize: 18 }}>{N2(balance)} to pay</div>
            {d.due_date && <div className="muted" style={{ fontSize: 13 }}>Due {fmtDay(d.due_date)}</div>}
          </div>
          {err && <Alert kind="red" icon="alert">{err}</Alert>}
          {req && req.status === 'pending' && req.method === 'account' ? (
            <div style={{ textAlign: 'center', background: '#F8FAFC', borderRadius: 12, padding: 16 }}>
              <div className="muted" style={{ fontSize: 13 }}>Transfer exactly {N2(req.amount)} to</div>
              <div style={{ fontSize: 30, fontWeight: 700, letterSpacing: '.06em', margin: '6px 0' }}>{req.account_number}</div>
              <div style={{ fontWeight: 600 }}>{req.bank_name}</div><div className="muted" style={{ fontSize: 13 }}>{req.account_name}</div>
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

// ---------------------------------------------------------------- shop
interface CartLine { id: string; name: string; price: number; unit: string; qty: number; stock: number | null }
export function ShopPage() {
  const { slug = '' } = useParams();
  const cat = useQuery({ queryKey: ['shop', slug], queryFn: () => rpc<any>('shop_catalog', { p_slug: slug }), retry: false });
  const [cart, setCart] = useState<CartLine[]>(() => { try { return JSON.parse(localStorage.getItem('counta.cart.' + slug) || '[]'); } catch { return []; } });
  const [q, setQ] = useState('');
  const [category, setCategory] = useState('');
  const [checkout, setCheckout] = useState(false);
  const [f, setF] = useState({ name: '', phone: '', email: '', delivery_method: 'pickup', address: '' });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [placed, setPlaced] = useState<any>(null);
  const clientRef = useRef(crypto.randomUUID());
  useEffect(() => { try { localStorage.setItem('counta.cart.' + slug, JSON.stringify(cart)); } catch { /* private window */ } }, [cart, slug]);
  const shop = cat.data?.shop;
  const items: any[] = cat.data?.items || [];
  const cats = useMemo(() => Array.from(new Set(items.map((i) => i.category))).sort(), [items]);
  const shown = items.filter((i) => (!category || i.category === category) && (!q.trim() || i.name.toLowerCase().includes(q.trim().toLowerCase())));
  const total = cart.reduce((a, l) => a + l.price * l.qty, 0);
  const method = shop && !shop.pickup ? 'delivery' : shop && !shop.delivery ? 'pickup' : f.delivery_method;
  const fee = method === 'delivery' ? Number(shop?.delivery_fee || 0) : 0;
  const add = (i: any, d = 1) => setCart((c) => {
    const x = c.find((l) => l.id === i.id);
    const next = Math.max(0, (x?.qty || 0) + d);
    const capped = i.stock != null ? Math.min(next, Number(i.stock)) : next;
    if (!x) return capped > 0 ? [...c, { id: i.id, name: i.name, price: Number(i.price), unit: i.unit, qty: capped, stock: i.stock }] : c;
    return capped > 0 ? c.map((l) => (l.id === i.id ? { ...l, qty: capped } : l)) : c.filter((l) => l.id !== i.id);
  });
  async function place() {
    setBusy(true); setErr(null);
    try {
      const r = await rpc<any>('shop_place_order', { p_slug: slug, p_order: { client_uuid: clientRef.current, customer: { name: f.name, phone: f.phone, email: f.email || null },
        delivery_method: method, address: method === 'delivery' ? f.address : null, lines: cart.map((l) => ({ item_id: l.id, qty: l.qty })) } });
      setPlaced(r); setCart([]);
    } catch (e) { setErr((e as Error).message); }
    setBusy(false);
  }
  if (cat.isLoading) return <Frame><div style={{ padding: 60, display: 'grid', placeItems: 'center' }}><Spinner /></div></Frame>;
  if (cat.error || !shop) return <Frame><Alert kind="yellow" icon="alert">This shop is not open right now.</Alert></Frame>;
  if (placed) return (
    <Frame org={shop}>
      <div className="card card-pad stack" style={{ gap: 12, textAlign: 'center' }}>
        <Icon name="check" size={36} color="#15803D" />
        <div style={{ fontSize: 20, fontWeight: 700 }}>Order {placed.number} received</div>
        <div className="muted">{shop.name} will confirm it shortly{shop.whatsapp ? ' on WhatsApp' : ''}. You can pay now so it goes out faster.</div>
        <a className="btn btn-primary" href={`/p/${placed.token}`}>Pay {N2(placed.total)} now</a>
        {shop.whatsapp && <a className="btn btn-secondary" href={`https://wa.me/${String(shop.whatsapp).replace(/\D/g, '')}?text=${encodeURIComponent(`Hello, I just placed order ${placed.number}.`)}`} target="_blank" rel="noreferrer"><Icon name="wa" size={16} />Message the shop</a>}
      </div>
    </Frame>
  );
  return (
    <Frame org={shop}>
      <div className="stack" style={{ gap: 12 }}>
        {shop.note && <Alert kind="blue" icon="info">{shop.note}</Alert>}
        <div className="row wrap" style={{ gap: 8 }}>
          <input className="input" placeholder="Search" value={q} onChange={(e) => setQ(e.target.value)} style={{ flex: '1 1 200px' }} />
          {cats.length > 1 && <select className="input" style={{ width: 'auto' }} value={category} onChange={(e) => setCategory(e.target.value)}><option value="">Everything</option>{cats.map((c) => <option key={c} value={c}>{c}</option>)}</select>}
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill,minmax(170px,1fr))', gap: 10 }}>
          {shown.map((i) => {
            const inCart = cart.find((l) => l.id === i.id)?.qty || 0;
            return (
              <div key={i.id} className="card" style={{ overflow: 'hidden', display: 'flex', flexDirection: 'column' }}>
                <div style={{ aspectRatio: '4/3', background: '#EFF2FA', display: 'grid', placeItems: 'center' }}>
                  {i.photo_path ? <img src={photoUrl(i.photo_path) || ''} alt="" style={{ width: '100%', height: '100%', objectFit: 'cover' }} loading="lazy" /> : <Icon name="package" size={28} color="#9CA3AF" />}
                </div>
                <div className="stack" style={{ padding: 10, gap: 4, flex: 1 }}>
                  <div style={{ fontWeight: 600, fontSize: 14 }}>{i.name}</div>
                  <div className="row" style={{ justifyContent: 'space-between' }}><b>{N2(i.price)}</b><span className="faint" style={{ fontSize: 11 }}>per {i.unit}</span></div>
                  {i.stock != null && <div className="faint" style={{ fontSize: 11 }}>{Number(i.stock)} left</div>}
                  <div style={{ marginTop: 'auto' }}>{inCart ? (
                    <div className="row" style={{ justifyContent: 'space-between' }}><button className="btn btn-secondary btn-xs" onClick={() => add(i, -1)} aria-label="One less"><Icon name="minus" size={13} /></button><b>{inCart}</b><button className="btn btn-secondary btn-xs" onClick={() => add(i, 1)} aria-label="One more"><Icon name="plus" size={13} /></button></div>
                  ) : <button className="btn btn-primary btn-sm btn-block" onClick={() => add(i)}>Add</button>}</div>
                </div>
              </div>
            );
          })}
        </div>
        {!shown.length && <div className="empty">Nothing matches.</div>}
      </div>
      {cart.length > 0 && !checkout && (
        <button className="btn btn-dark" style={{ position: 'fixed', left: '50%', transform: 'translateX(-50%)', bottom: 20, zIndex: 20, padding: '14px 22px', boxShadow: 'var(--shadow-cta)' }} onClick={() => setCheckout(true)}>
          {cart.reduce((a, l) => a + l.qty, 0)} items · {N2(total)} · Check out
        </button>
      )}
      {checkout && (
        <div className="modal-wrap"><div className="scrim dark" onClick={() => setCheckout(false)} />
          <div className="modal" style={{ width: 480 }}>
            <div className="modal-hd"><div className="drawer-title">Your order</div><button className="x-btn" onClick={() => setCheckout(false)} aria-label="Close"><Icon name="x" size={18} /></button></div>
            <div className="modal-body">
              {cart.map((l) => <div key={l.id} className="row" style={{ justifyContent: 'space-between', fontSize: 14 }}><span>{l.qty} × {l.name}</span><span className="num">{N2(l.qty * l.price)}</span></div>)}
              <input className="input" placeholder="Your name" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} />
              <input className="input" placeholder="Phone (WhatsApp)" inputMode="tel" value={f.phone} onChange={(e) => setF({ ...f, phone: e.target.value })} />
              <input className="input" placeholder="Email (optional)" inputMode="email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} />
              {(shop.pickup && shop.delivery) && <div className="row" style={{ gap: 8 }}>
                <button className={'pill' + (f.delivery_method === 'pickup' ? ' on' : '')} onClick={() => setF({ ...f, delivery_method: 'pickup' })}>I'll pick it up</button>
                <button className={'pill' + (f.delivery_method === 'delivery' ? ' on' : '')} onClick={() => setF({ ...f, delivery_method: 'delivery' })}>Deliver it{Number(shop.delivery_fee) ? ` (+${N2(shop.delivery_fee)})` : ''}</button>
              </div>}
              {method === 'delivery' && <textarea className="input" placeholder="Delivery address" value={f.address} onChange={(e) => setF({ ...f, address: e.target.value })} />}
              <div className="row" style={{ justifyContent: 'space-between', fontWeight: 700, fontSize: 17 }}><span>Total</span><span className="num">{N2(total + fee)}</span></div>
              {err && <Alert kind="red" icon="alert">{err}</Alert>}
            </div>
            <div className="modal-ft"><button className="btn btn-primary btn-block" disabled={busy || !f.name.trim() || f.phone.replace(/\D/g, '').length < 10 || (method === 'delivery' && !f.address.trim())} onClick={place}>{busy ? 'Placing…' : 'Place order'}</button></div>
          </div>
        </div>
      )}
    </Frame>
  );
}
