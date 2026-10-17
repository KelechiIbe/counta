// The online shop in the business's colours: browse, a cart, then a checkout in four short steps
// (cart, your details, pickup or delivery, payment) and a confirmation with a link to pay and follow the order.
import { useEffect, useMemo, useRef, useState, type CSSProperties, type ReactNode } from 'react';
import { useParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { photoUrl, rpc } from '../../lib/supabase';
import { N2 } from '../../lib/format';
import { NG_STATES } from '../../lib/countries';
import { Icon } from '../../components/Icon';
import { Alert, Spinner } from '../../components/ui';
import { cleanHex, onColor, tint } from '../../components/InvoiceDoc';

interface CartLine { id: string; name: string; price: number; unit: string; qty: number; stock: number | null; photo_path?: string | null }
type Step = 'cart' | 'details' | 'delivery' | 'payment';
const STEPS: { id: Step; label: string }[] = [{ id: 'cart', label: 'Cart' }, { id: 'details', label: 'Your details' }, { id: 'delivery', label: 'Delivery' }, { id: 'payment', label: 'Payment' }];
const SOCIAL: Record<string, [string, (h: string) => string]> = {
  instagram: ['Instagram', (h) => `https://instagram.com/${h}`], facebook: ['Facebook', (h) => `https://facebook.com/${h}`],
  tiktok: ['TikTok', (h) => `https://www.tiktok.com/@${h}`], x: ['X', (h) => `https://x.com/${h}`],
};
const load = <T,>(k: string, d: T): T => { try { const v = localStorage.getItem(k); return v ? JSON.parse(v) as T : d; } catch { return d; } };
const save = (k: string, v: unknown) => { try { localStorage.setItem(k, JSON.stringify(v)); } catch { /* private window */ } };

export function ShopPage() {
  const { slug = '' } = useParams();
  const cat = useQuery({ queryKey: ['shop', slug], queryFn: () => rpc<any>('shop_catalog', { p_slug: slug }), retry: false });
  const [cart, setCart] = useState<CartLine[]>(() => load('counta.cart.' + slug, []));
  const [q, setQ] = useState('');
  const [category, setCategory] = useState('');
  const [step, setStep] = useState<Step | null>(null);
  const [f, setF] = useState(() => load('counta.buyer', { name: '', phone: '', email: '', address: '', city: '', state: '', note: '', delivery_method: 'pickup', payment: 'now' }));
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [placed, setPlaced] = useState<any>(null);
  const [logoBroken, setLogoBroken] = useState(false);
  const clientRef = useRef(crypto.randomUUID());
  useEffect(() => save('counta.cart.' + slug, cart), [cart, slug]);
  useEffect(() => save('counta.buyer', { ...f, note: '' }), [f]);
  const shop = cat.data?.shop;
  const items: any[] = cat.data?.items || [];
  const cats = useMemo(() => Array.from(new Set(items.map((i) => i.category).filter(Boolean))).sort(), [items]);
  const brand = cleanHex(shop?.brand_color);
  const on = onColor(brand);
  useEffect(() => { if (shop?.title) document.title = shop.title; }, [shop?.title]);
  if (cat.isLoading) return <Shell><div style={{ padding: 80, display: 'grid', placeItems: 'center' }}><Spinner /></div></Shell>;
  if (cat.error || !shop) return <Shell><div style={{ padding: 24 }}><Alert kind="yellow" icon="alert">This shop is not open right now.</Alert></div></Shell>;

  const shown = items.filter((i) => (!category || i.category === category) && (!q.trim() || `${i.name} ${i.brand || ''} ${i.category || ''}`.toLowerCase().includes(q.trim().toLowerCase())));
  const count = cart.reduce((a, l) => a + l.qty, 0);
  const subtotal = cart.reduce((a, l) => a + l.price * l.qty, 0);
  const method: 'pickup' | 'delivery' = !shop.pickup ? 'delivery' : !shop.delivery ? 'pickup' : (f.delivery_method as 'pickup' | 'delivery');
  const fee = method === 'delivery' ? Number(shop.delivery_fee || 0) : 0;
  const minShort = Number(shop.min_order || 0) > 0 && subtotal < Number(shop.min_order) ? Number(shop.min_order) - subtotal : 0;
  const payment = shop.pay_on_delivery ? f.payment : 'now';
  const set = (k: string, v: string) => setF((x: typeof f) => ({ ...x, [k]: v }));
  const add = (i: any, d = 1) => setCart((c) => {
    const x = c.find((l) => l.id === i.id);
    const next = Math.max(0, (x?.qty || 0) + d);
    const capped = i.stock != null ? Math.min(next, Number(i.stock)) : next;
    if (!x) return capped > 0 ? [...c, { id: i.id, name: i.name, price: Number(i.price), unit: i.unit, qty: capped, stock: i.stock ?? null, photo_path: i.photo_path }] : c;
    return capped > 0 ? c.map((l) => (l.id === i.id ? { ...l, qty: capped } : l)) : c.filter((l) => l.id !== i.id);
  });
  const okDetails = f.name.trim().length > 1 && f.phone.replace(/\D/g, '').length >= 10 && (!f.email.trim() || /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(f.email.trim()));
  const okDelivery = method === 'pickup' || f.address.trim().length > 4;
  async function place() {
    setBusy(true); setErr(null);
    try {
      const r = await rpc<any>('shop_place_order', { p_slug: slug, p_order: { client_uuid: clientRef.current, customer: { name: f.name, phone: f.phone, email: f.email || null },
        delivery_method: method, address: method === 'delivery' ? f.address : null, city: method === 'delivery' ? f.city || null : null, state: method === 'delivery' ? f.state || null : null,
        note: f.note || null, payment, lines: cart.map((l) => ({ item_id: l.id, qty: l.qty })) } });
      setPlaced(r); setCart([]); setStep(null); clientRef.current = crypto.randomUUID();
      window.scrollTo({ top: 0 });
    } catch (e) { setErr((e as Error).message); }
    setBusy(false);
  }

  const btn: CSSProperties = { background: brand, borderColor: brand, color: on };
  const header = (
    <header>
      <div style={{ position: 'relative', background: brand, minHeight: shop.banner_path ? 0 : 120 }}>
        {shop.banner_path && <img src={photoUrl(shop.banner_path) || ''} alt="" style={{ width: '100%', aspectRatio: '3 / 1', maxHeight: 260, objectFit: 'cover', display: 'block' }} />}
      </div>
      <div style={{ maxWidth: 1080, margin: '0 auto', padding: '0 16px' }}>
        <div className="row" style={{ gap: 14, alignItems: 'flex-start', flexWrap: 'wrap' }}>
          <div style={{ width: 76, height: 76, borderRadius: 18, background: '#fff', boxShadow: '0 4px 14px rgba(0,0,0,.12)', display: 'grid', placeItems: 'center', overflow: 'hidden', flex: 'none', position: 'relative', marginTop: -38 }}>
            {shop.logo_path && !logoBroken ? <img src={photoUrl(shop.logo_path) || ''} alt="" style={{ maxWidth: 64, maxHeight: 64, objectFit: 'contain' }} onError={() => setLogoBroken(true)} />
              : <span style={{ fontWeight: 800, fontSize: 24, color: brand }}>{String(shop.title || shop.name).slice(0, 2).toUpperCase()}</span>}
          </div>
          <div style={{ flex: '1 1 220px', minWidth: 0, paddingTop: 10 }}>
            <h1 style={{ margin: 0, fontSize: 24, lineHeight: 1.2, color: '#111827' }}>{shop.title || shop.name}</h1>
            {shop.tagline && <div className="muted" style={{ fontSize: 14 }}>{shop.tagline}</div>}
          </div>
        </div>
        <div className="row wrap" style={{ gap: 8, marginTop: 12 }}>
          {shop.whatsapp && <a className="pill" href={`https://wa.me/${String(shop.whatsapp).replace(/\D/g, '').replace(/^0/, '234')}`} target="_blank" rel="noreferrer"><Icon name="wa" size={14} />WhatsApp</a>}
          {Object.entries(shop.socials || {}).filter(([k, v]) => SOCIAL[k] && v).map(([k, v]) => (
            <a key={k} className="pill" href={SOCIAL[k][1](String(v))} target="_blank" rel="noreferrer">{SOCIAL[k][0]}<Icon name="external" size={12} /></a>
          ))}
          {shop.website && <a className="pill" href={shop.website} target="_blank" rel="noreferrer">{String(shop.website).replace(/^https?:\/\//, '')}<Icon name="external" size={12} /></a>}
        </div>
      </div>
    </header>
  );

  if (placed) {
    return (
      <Shell brand={brand}>
        {header}
        <main style={{ maxWidth: 560, margin: '24px auto', padding: '0 16px' }}>
          <div className="card card-pad stack" style={{ gap: 12, textAlign: 'center' }}>
            <span style={{ width: 56, height: 56, borderRadius: 28, background: tint(brand, 0.12), display: 'grid', placeItems: 'center', margin: '0 auto' }}><Icon name="check" size={30} color={brand} /></span>
            <div style={{ fontSize: 21, fontWeight: 700 }}>Thank you, order {placed.number} is in</div>
            <div className="muted">Total {N2(placed.total)}{Number(placed.vat) > 0 ? `, including ${N2(placed.vat)} VAT` : ''}.</div>
            <div className="muted" style={{ fontSize: 14 }}>
              {placed.pay_later
                ? `${shop.title || shop.name} will confirm it shortly. You pay ${method === 'delivery' ? 'when it is delivered' : 'when you pick it up'}.`
                : `Pay now and ${shop.title || shop.name} gets it ready as soon as the money lands.`}
            </div>
            {!placed.pay_later && <a className="btn btn-primary btn-block" style={btn} href={`/p/${placed.token}`}>Pay {N2(placed.total)} now</a>}
            <a className="btn btn-secondary btn-block" href={`/p/${placed.token}`}>{placed.pay_later ? 'Follow your order' : 'See your order'}</a>
            {shop.whatsapp && <a className="btn btn-ghost btn-block" href={`https://wa.me/${String(shop.whatsapp).replace(/\D/g, '').replace(/^0/, '234')}?text=${encodeURIComponent(`Hello, I just placed order ${placed.number}.`)}`} target="_blank" rel="noreferrer"><Icon name="wa" size={16} />Message the shop</a>}
            <button className="link" style={{ margin: '4px auto 0' }} onClick={() => setPlaced(null)}>Keep shopping</button>
          </div>
        </main>
      </Shell>
    );
  }

  return (
    <Shell brand={brand}>
      {header}
      <div style={{ position: 'sticky', top: 0, zIndex: 10, background: 'rgba(255,255,255,.96)', backdropFilter: 'blur(6px)', borderBottom: '1px solid var(--line)', marginTop: 14 }}>
        <div className="row" style={{ maxWidth: 1080, margin: '0 auto', padding: '10px 16px', gap: 10 }}>
          <div className="row" style={{ flex: 1, gap: 8, background: '#F3F4F6', borderRadius: 12, padding: '0 12px' }}>
            <Icon name="search" size={16} color="#9CA3AF" />
            <input className="input" style={{ border: 0, background: 'transparent', boxShadow: 'none', paddingLeft: 0 }} placeholder={`Search ${shop.title || shop.name}`} value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search the shop" />
          </div>
          <button className="btn" style={{ ...btn, position: 'relative', flex: 'none' }} onClick={() => setStep('cart')} disabled={!count} aria-label={`Cart, ${count} items`}>
            <Icon name="package" size={16} color={on} /><span className="hide-xs">{count ? N2(subtotal) : 'Cart'}</span>
            {count > 0 && <span style={{ position: 'absolute', top: -6, right: -6, background: '#111827', color: '#fff', fontSize: 11, fontWeight: 700, minWidth: 20, height: 20, borderRadius: 10, display: 'grid', placeItems: 'center', padding: '0 5px' }}>{count}</span>}
          </button>
        </div>
        {cats.length > 1 && (
          <div className="row" style={{ maxWidth: 1080, margin: '0 auto', padding: '0 16px 10px', gap: 6, overflowX: 'auto', scrollbarWidth: 'none' }}>
            {['', ...cats].map((c) => (
              <button key={c || 'all'} className="pill" onClick={() => setCategory(c)} style={category === c ? { background: brand, borderColor: brand, color: on, flex: 'none' } : { flex: 'none' }}>{c || 'Everything'}</button>
            ))}
          </div>
        )}
      </div>
      <main style={{ maxWidth: 1080, margin: '0 auto', padding: '16px 16px 120px' }} className="stack">
        {shop.note && <Alert kind="blue" icon="info">{shop.note}</Alert>}
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill,minmax(160px,1fr))', gap: 12 }}>
          {shown.map((i) => {
            const inCart = cart.find((l) => l.id === i.id)?.qty || 0;
            const out = i.available === false;
            return (
              <div key={i.id} className="card" style={{ overflow: 'hidden', display: 'flex', flexDirection: 'column', opacity: out ? 0.55 : 1 }}>
                <div style={{ aspectRatio: '1 / 1', background: tint(brand, 0.06), display: 'grid', placeItems: 'center' }}>
                  {i.photo_path ? <img src={photoUrl(i.photo_path) || ''} alt="" style={{ width: '100%', height: '100%', objectFit: 'cover' }} loading="lazy" /> : <Icon name="package" size={30} color={tint(brand, 0.5)} />}
                </div>
                <div className="stack" style={{ padding: 10, gap: 4, flex: 1 }}>
                  <div style={{ fontWeight: 600, fontSize: 14, lineHeight: 1.3 }}>{i.name}</div>
                  {i.description && <div className="faint" style={{ fontSize: 12, lineHeight: 1.35, display: '-webkit-box', WebkitLineClamp: 2, WebkitBoxOrient: 'vertical', overflow: 'hidden' }}>{i.description}</div>}
                  <div className="row" style={{ justifyContent: 'space-between', marginTop: 2 }}><b>{N2(i.price)}</b><span className="faint" style={{ fontSize: 11 }}>per {i.unit}</span></div>
                  {i.stock != null && !out && <div className="faint" style={{ fontSize: 11 }}>{Number(i.stock)} left</div>}
                  <div style={{ marginTop: 'auto', paddingTop: 4 }}>
                    {out ? <div className="faint" style={{ fontSize: 12, textAlign: 'center' }}>Sold out</div> : inCart ? (
                      <Stepper qty={inCart} onLess={() => add(i, -1)} onMore={() => add(i, 1)} brand={brand} />
                    ) : <button className="btn btn-sm btn-block" style={btn} onClick={() => add(i)}><Icon name="plus" size={13} color={on} />Add</button>}
                  </div>
                </div>
              </div>
            );
          })}
        </div>
        {!shown.length && <div className="empty">Nothing matches.</div>}
        <footer className="faint" style={{ fontSize: 12, textAlign: 'center', marginTop: 28 }}>
          {[shop.address, shop.phone, shop.email].filter(Boolean).join(' · ')}
          <div style={{ marginTop: 4 }}>Shop powered by Counta · TaxStreem</div>
        </footer>
      </main>
      {count > 0 && !step && (
        <button className="btn" style={{ ...btn, position: 'fixed', left: '50%', transform: 'translateX(-50%)', bottom: 'max(18px, env(safe-area-inset-bottom))', zIndex: 20, padding: '14px 22px', boxShadow: `0 12px 32px ${tint(brand, 0.3)}`, borderRadius: 14 }} onClick={() => setStep('cart')}>
          {count} {count === 1 ? 'item' : 'items'} · {N2(subtotal)} · Check out<Icon name="arrowR" size={16} color={on} />
        </button>
      )}
      {step && (
        <div className="modal-wrap" style={{ zIndex: 60 }}>
          <div className="scrim dark" onClick={() => !busy && setStep(null)} />
          <div className="modal shop-checkout" style={{ width: 520 }} role="dialog" aria-label="Checkout">
            <div className="modal-hd" style={{ flexDirection: 'column', alignItems: 'stretch', gap: 12 }}>
              <div className="row" style={{ justifyContent: 'space-between' }}>
                <div className="drawer-title">{STEPS.find((s) => s.id === step)!.label}</div>
                <button className="x-btn" onClick={() => setStep(null)} aria-label="Close"><Icon name="x" size={18} /></button>
              </div>
              <ol className="row" style={{ gap: 6, margin: 0, padding: 0, listStyle: 'none' }} aria-label="Checkout steps">
                {STEPS.map((s, i) => {
                  const idx = STEPS.findIndex((x) => x.id === step);
                  return (
                    <li key={s.id} style={{ flex: 1 }} aria-current={s.id === step ? 'step' : undefined}>
                      <div style={{ height: 4, borderRadius: 2, background: i <= idx ? brand : '#E5E7EB' }} />
                      <div style={{ fontSize: 11, marginTop: 4, color: i <= idx ? '#111827' : '#9CA3AF', fontWeight: i === idx ? 600 : 400 }}>{i + 1}. {s.label}</div>
                    </li>
                  );
                })}
              </ol>
            </div>
            <div className="modal-body">
              {step === 'cart' && (
                <div className="stack" style={{ gap: 10 }}>
                  {cart.map((l) => {
                    const it = items.find((x) => x.id === l.id) || l;
                    return (
                      <div key={l.id} className="row" style={{ gap: 10 }}>
                        <div style={{ width: 48, height: 48, borderRadius: 10, background: tint(brand, 0.06), overflow: 'hidden', flex: 'none', display: 'grid', placeItems: 'center' }}>
                          {l.photo_path ? <img src={photoUrl(l.photo_path) || ''} alt="" style={{ width: '100%', height: '100%', objectFit: 'cover' }} /> : <Icon name="package" size={18} color="#9CA3AF" />}
                        </div>
                        <div style={{ flex: 1, minWidth: 0 }}>
                          <div className="ellipsis" style={{ fontWeight: 600, fontSize: 14 }}>{l.name}</div>
                          <div className="faint" style={{ fontSize: 12 }}>{N2(l.price)} per {l.unit}</div>
                        </div>
                        <div style={{ width: 112 }}><Stepper qty={l.qty} onLess={() => add(it, -1)} onMore={() => add(it, 1)} brand={brand} /></div>
                        <div className="num" style={{ width: 92, textAlign: 'right', fontWeight: 600 }}>{N2(l.qty * l.price)}</div>
                      </div>
                    );
                  })}
                  {!cart.length && <div className="empty">Your cart is empty.</div>}
                  <Totals rows={[['Items', N2(subtotal)]]} total={N2(subtotal)} label="Subtotal" />
                  {minShort > 0 && <Alert kind="amber" icon="info">The smallest order here is {N2(shop.min_order)}. Add {N2(minShort)} more to check out.</Alert>}
                </div>
              )}
              {step === 'details' && (
                <div className="stack" style={{ gap: 10 }}>
                  <Lbl text="Your name"><input className="input" autoComplete="name" value={f.name} onChange={(e) => set('name', e.target.value)} /></Lbl>
                  <Lbl text="Phone (WhatsApp)" hint="The shop confirms your order on this number."><input className="input" autoComplete="tel" inputMode="tel" value={f.phone} onChange={(e) => set('phone', e.target.value)} placeholder="0803 123 4567" /></Lbl>
                  <Lbl text="Email (optional)" hint="For your receipt."><input className="input" autoComplete="email" inputMode="email" value={f.email} onChange={(e) => set('email', e.target.value)} /></Lbl>
                </div>
              )}
              {step === 'delivery' && (
                <div className="stack" style={{ gap: 10 }}>
                  {shop.pickup && shop.delivery && (
                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8 }}>
                      {(['pickup', 'delivery'] as const).map((m) => (
                        <button key={m} type="button" className="card" onClick={() => set('delivery_method', m)}
                          style={{ padding: 12, textAlign: 'left', cursor: 'pointer', background: '#fff', borderColor: method === m ? brand : undefined, boxShadow: method === m ? `0 0 0 2px ${brand}` : undefined }}>
                          <div style={{ fontWeight: 600 }}><Icon name={m === 'pickup' ? 'building' : 'truck'} size={15} /> {m === 'pickup' ? 'Pick up' : 'Deliver to me'}</div>
                          <div className="faint" style={{ fontSize: 12 }}>{m === 'pickup' ? 'Free' : Number(shop.delivery_fee) ? `${N2(shop.delivery_fee)}` : 'Free delivery'}</div>
                        </button>
                      ))}
                    </div>
                  )}
                  {method === 'pickup' ? (
                    <Alert kind="grey" icon="pin">Pick up from {shop.pickup_address || shop.address || shop.title}. The shop tells you when it is ready.</Alert>
                  ) : (
                    <>
                      <Lbl text="Delivery address"><textarea className="input" autoComplete="street-address" value={f.address} onChange={(e) => set('address', e.target.value)} placeholder="House number, street, nearest bus stop or landmark" style={{ minHeight: 64 }} /></Lbl>
                      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8 }}>
                        <Lbl text="City or area"><input className="input" autoComplete="address-level2" value={f.city} onChange={(e) => set('city', e.target.value)} /></Lbl>
                        <Lbl text="State"><input className="input" list="shop-states" autoComplete="address-level1" value={f.state} onChange={(e) => set('state', e.target.value)} />
                          <datalist id="shop-states">{NG_STATES.map((s) => <option key={s} value={s} />)}</datalist></Lbl>
                      </div>
                    </>
                  )}
                  <Lbl text="Note for the shop (optional)"><input className="input" value={f.note} onChange={(e) => set('note', e.target.value)} placeholder={method === 'delivery' ? 'Call when you get to the gate' : 'I will come after 4pm'} /></Lbl>
                </div>
              )}
              {step === 'payment' && (
                <div className="stack" style={{ gap: 10 }}>
                  <div style={{ display: 'grid', gap: 8 }}>
                    <PayOption on={payment === 'now'} brand={brand} onClick={() => set('payment', 'now')} title="Pay now"
                      sub={shop.online_payments ? 'Bank transfer to an account made for this order, card or USSD. Your order is confirmed the moment the money lands.' : 'By bank transfer. The shop sends the account details with your order.'} />
                    {shop.pay_on_delivery && <PayOption on={payment === 'later'} brand={brand} onClick={() => set('payment', 'later')} title={method === 'delivery' ? 'Pay on delivery' : 'Pay when I pick it up'}
                      sub="Cash, transfer or POS when you receive your order." />}
                  </div>
                  <div className="card" style={{ padding: 12, borderRadius: 12 }}>
                    <div className="mini-label" style={{ marginBottom: 6 }}>Order summary</div>
                    {cart.map((l) => <div key={l.id} className="row" style={{ justifyContent: 'space-between', fontSize: 13 }}><span className="ellipsis">{l.qty} × {l.name}</span><span className="num">{N2(l.qty * l.price)}</span></div>)}
                    <Totals rows={[['Items', N2(subtotal)], ...(method === 'delivery' ? [['Delivery', fee ? N2(fee) : 'Free'] as [string, string]] : [])]} total={N2(subtotal + fee)}
                      note={shop.vat_registered && !shop.prices_include_vat ? 'VAT is added where it applies and shown on your order.' : undefined} />
                    <div className="faint" style={{ fontSize: 12, marginTop: 6 }}>
                      {f.name} · {f.phone}{method === 'delivery' ? ` · ${[f.address, f.city, f.state].filter(Boolean).join(', ')}` : ` · pickup`}
                    </div>
                  </div>
                </div>
              )}
              {err && <Alert kind="red" icon="alert">{err}</Alert>}
            </div>
            <div className="modal-ft" style={{ gap: 8 }}>
              {step !== 'cart' && <button className="btn btn-secondary" disabled={busy} onClick={() => { setErr(null); setStep(STEPS[STEPS.findIndex((s) => s.id === step) - 1].id); }}>Back</button>}
              {step === 'cart' && <button className="btn btn-primary grow" style={btn} disabled={!cart.length || minShort > 0} onClick={() => setStep('details')}>Continue</button>}
              {step === 'details' && <button className="btn btn-primary grow" style={btn} disabled={!okDetails} onClick={() => setStep('delivery')}>Continue</button>}
              {step === 'delivery' && <button className="btn btn-primary grow" style={btn} disabled={!okDelivery} onClick={() => setStep('payment')}>Continue</button>}
              {step === 'payment' && <button className="btn btn-primary grow" style={btn} disabled={busy} onClick={place}>{busy ? 'Placing your order…' : payment === 'now' ? `Place order and pay ${N2(subtotal + fee)}` : `Place order · ${N2(subtotal + fee)}`}</button>}
            </div>
          </div>
        </div>
      )}
    </Shell>
  );
}

function Shell({ children, brand }: { children: ReactNode; brand?: string }) {
  return <div style={{ minHeight: '100vh', background: brand ? tint(brand, 0.03) : '#F4F6F8' }}>{children}</div>;
}
function Stepper({ qty, onLess, onMore, brand }: { qty: number; onLess: () => void; onMore: () => void; brand: string }) {
  return (
    <div className="row" style={{ justifyContent: 'space-between', border: `1px solid ${tint(brand, 0.35)}`, borderRadius: 10, padding: 2 }}>
      <button className="btn btn-ghost btn-xs" onClick={onLess} aria-label="One less" style={{ color: brand }}><Icon name="minus" size={14} color={brand} /></button>
      <b className="num">{qty}</b>
      <button className="btn btn-ghost btn-xs" onClick={onMore} aria-label="One more" style={{ color: brand }}><Icon name="plus" size={14} color={brand} /></button>
    </div>
  );
}
function Lbl({ text, hint, children }: { text: string; hint?: string; children: ReactNode }) {
  return <label className="stack" style={{ gap: 4 }}><span style={{ fontSize: 13, fontWeight: 600 }}>{text}</span>{children}{hint && <span className="faint" style={{ fontSize: 12 }}>{hint}</span>}</label>;
}
function Totals({ rows, total, label = 'Total', note }: { rows: [string, string][]; total: string; label?: string; note?: string }) {
  return (
    <div className="stack" style={{ gap: 4, borderTop: '1px solid #F3F4F6', paddingTop: 8, marginTop: 4, fontSize: 14 }}>
      {rows.length > 1 && rows.map(([k, v]) => <div key={k} className="row" style={{ justifyContent: 'space-between' }}><span className="muted">{k}</span><span className="num">{v}</span></div>)}
      <div className="row" style={{ justifyContent: 'space-between', fontWeight: 700, fontSize: 16 }}><span>{label}</span><span className="num">{total}</span></div>
      {note && <div className="faint" style={{ fontSize: 12 }}>{note}</div>}
    </div>
  );
}
function PayOption({ on, brand, onClick, title, sub }: { on: boolean; brand: string; onClick: () => void; title: string; sub: string }) {
  return (
    <button type="button" className="card" onClick={onClick} style={{ padding: 12, textAlign: 'left', cursor: 'pointer', background: '#fff', borderColor: on ? brand : undefined, boxShadow: on ? `0 0 0 2px ${brand}` : undefined }}>
      <div className="row" style={{ gap: 8 }}>
        <span style={{ width: 18, height: 18, borderRadius: 9, border: `2px solid ${on ? brand : '#D1D5DB'}`, display: 'grid', placeItems: 'center', flex: 'none' }}>{on && <span style={{ width: 8, height: 8, borderRadius: 4, background: brand }} />}</span>
        <b>{title}</b>
      </div>
      <div className="faint" style={{ fontSize: 12.5, marginTop: 4, paddingLeft: 26 }}>{sub}</div>
    </button>
  );
}
