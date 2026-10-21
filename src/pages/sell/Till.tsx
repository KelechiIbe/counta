// The till: scan or search, a cart with wholesale and retail prices, discounts within the cashier's limit, split payment
// (cash, transfer, POS, pay-by-transfer with spoken confirmation, link, QR, on account, the customer's credit),
// receipts by Bluetooth printer or WhatsApp, and cash-up with float, drops and the closing count.
import { useEffect, useMemo, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { can, useInventory, useSession, useToast } from '../../state/session';
import { rpc } from '../../lib/supabase';
import { METHOD_LABEL, money, useChart, useCustomers, useSales, useTill, type Customer, type PayRequest, type Sale, type Shift } from '../../lib/api';
import { N2, uuid, when } from '../../lib/format';
import { store } from '../../lib/pwa';
import type { Item } from '../../lib/types';
import { Icon } from '../../components/Icon';
import { VatInfo } from '../../components/VatInfo';
import { ItemPicker } from '../../components/ItemPicker';
import { Alert, Drawer, Empty, Field, Modal, ModalHead, Spinner, Thumb } from '../../components/ui';
import { Camera } from '../../mobile/Scan';
import { CustomerPicker, PayWait, ReceiptModal, StatusChip } from './common';
import { useDraft } from '../../lib/drafts';

type Unit = 'selling' | 'purchase';
interface Line { key: string; item: Item; qty: number; unit: Unit; override: number | null; discount: number }
type Method = 'cash' | 'transfer' | 'pos' | 'card' | 'account' | 'link' | 'qr' | 'credit' | 'cheque' | 'other';
interface Tender { method: Method; amount: string; bank_account_id?: string; reference?: string }

const INSTANT: Method[] = ['account', 'link', 'qr'];
const TENDER_LABEL: Record<Method, string> = {
  cash: 'Cash', transfer: 'Transfer to our bank', pos: 'POS', card: 'Card', account: 'Pay by transfer', link: 'Payment link', qr: 'QR code',
  credit: "Customer's credit", cheque: 'Cheque', other: 'Other',
};

export default function Till() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const locKey = 'counta.till.loc.' + orgId;
  const [loc, setLocState] = useState<string | null>(() => store.get(locKey) || null);
  useEffect(() => {
    if (!inv) return;
    if (!loc || !inv.locations.some((l) => l.id === loc)) setLocState(inv.me.location_id || inv.locations.find((l) => l.is_main)?.id || inv.locations[0]?.id || null);
  }, [inv, loc]);
  const setLoc = (l: string) => { setLocState(l); store.set(locKey, l); };
  // A role without the Record sales permission sees the notice below, so the till is not read for it.
  const till = useTill(inv && can(inv, 'record_sales') ? loc : null);
  const shift = till.data?.shift || null;
  const settings = till.data?.settings || {};

  const [lines, setLines] = useState<Line[]>([]);
  const [customer, setCustomer] = useState<Customer | null>(null);
  const [listId, setListId] = useState<string>('');
  const [cartDiscount, setCartDiscount] = useState('');
  const [tenders, setTenders] = useState<Tender[]>([{ method: 'cash', amount: '' }]);
  const [busy, setBusy] = useState(false);
  const [paying, setPaying] = useState<{ sale: Sale; request: PayRequest } | null>(null);
  const [receipt, setReceipt] = useState<{ sale: Sale; change: number } | null>(null);
  const [scan, setScan] = useState(false);
  const [panel, setPanel] = useState<'shift' | 'sales' | null>(null);
  const [opening, setOpening] = useState(false);
  const clientRef = useRef(uuid());
  // A sale Martina prepared: its products go into the cart for the cashier to check and take payment.
  const draft = useDraft('sale');
  const customers = useCustomers();
  const [fromMartina, setFromMartina] = useState(0);

  // A customer's own price list applies unless the cashier picks another.
  useEffect(() => { setListId(customer?.price_list_id || ''); }, [customer?.id]); // eslint-disable-line react-hooks/exhaustive-deps

  const key = JSON.stringify(lines.map((l) => [l.item.id, l.qty, l.unit]));
  const prices = useQuery({
    queryKey: ['till-prices', orgId, listId, key],
    enabled: !!orgId && lines.length > 0,
    queryFn: () => rpc<{ item_id: string; unit: Unit; price: number }[]>('till_prices', { p_org: orgId, p_list: listId || null, p_lines: lines.map((l) => ({ item_id: l.item.id, qty: l.qty, unit: l.unit })) }),
    placeholderData: (prev) => prev,
    staleTime: 60_000,
  });
  const listPrice = (l: Line, i: number) => {
    const p = prices.data?.[i];
    if (p && p.item_id === l.item.id && p.unit === l.unit) return Number(p.price);
    return Number(l.item.price) * (l.unit === 'purchase' ? l.item.pack_size : 1);
  };
  const lineTotal = (l: Line, i: number) => Math.max(0, Math.round(((l.override ?? listPrice(l, i)) * l.qty - l.discount) * 100) / 100);
  const subtotal = lines.reduce((a, l, i) => a + lineTotal(l, i), 0);
  const cartDisc = Math.min(money(cartDiscount) || 0, subtotal);
  const total = Math.round((subtotal - cartDisc) * 100) / 100;
  const tendered = tenders.reduce((a, t) => a + (money(t.amount) || 0), 0);
  const cashIn = tenders.filter((t) => t.method === 'cash').reduce((a, t) => a + (money(t.amount) || 0), 0);
  const change = Math.max(0, Math.min(cashIn, tendered - total));
  const short = Math.max(0, Math.round((total - tendered) * 100) / 100);
  const discPct = subtotal > 0 ? ((lines.reduce((a, l) => a + l.discount, 0) + cartDisc) / (subtotal + lines.reduce((a, l) => a + l.discount, 0))) * 100 : 0;
  const maxPct = Number(settings.max_cashier_discount_pct ?? 0);
  const canPrice = !!settings.can_edit_prices;

  function add(it: Item, qty = 1) {
    setLines((ls) => {
      const i = ls.findIndex((l) => l.item.id === it.id && l.unit === 'selling' && l.override == null);
      if (i >= 0) { const c = [...ls]; c[i] = { ...c[i], qty: c[i].qty + qty }; return c; }
      return [...ls, { key: uuid(), item: it, qty, unit: 'selling', override: null, discount: 0 }];
    });
  }
  const update = (k: string, patch: Partial<Line>) => setLines((ls) => ls.map((l) => (l.key === k ? { ...l, ...patch } : l)));
  useEffect(() => {
    if (!draft || !inv) return;
    let n = 0;
    for (const d of draft.lines) {
      const it = d.item_id ? inv.items.find((i) => i.id === d.item_id) : undefined;
      if (!it) continue;
      n++;
      const price = d.unit_price != null && canPrice && Math.abs(Number(d.unit_price) - Number(it.price)) > 0.004 ? Number(d.unit_price) : null;
      if (price == null) add(it, d.qty || 1);
      else setLines((ls) => [...ls, { key: uuid(), item: it, qty: d.qty || 1, unit: 'selling', override: price, discount: 0 }]);
    }
    setFromMartina(n);
  }, [draft, inv?.org.id]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (!draft?.customer || !customers.data || customer) return;
    const q = draft.customer.trim().toLowerCase();
    const hit = customers.data.customers.find((c) => !c.archived && (c.name.toLowerCase() === q || c.name.toLowerCase().includes(q)));
    if (hit) setCustomer(hit);
  }, [draft, customers.data]); // eslint-disable-line react-hooks/exhaustive-deps
  const remove = (k: string) => setLines((ls) => ls.filter((l) => l.key !== k));
  function reset() {
    setLines([]); setCustomer(null); setListId(''); setCartDiscount(''); setTenders([{ method: 'cash', amount: '' }]); clientRef.current = uuid(); setFromMartina(0);
  }
  // With one way of paying, it covers the whole sale unless the cashier types an amount.
  const effTenders = tenders.length === 1 && !tenders[0].amount ? [{ ...tenders[0], amount: String(total) }] : tenders;

  async function checkout() {
    if (!shift) { setOpening(true); return; }
    if (!lines.length) return;
    const instant = effTenders.filter((t) => INSTANT.includes(t.method) && (money(t.amount) || 0) > 0);
    if (instant.length > 1) { toast('Use one of pay by transfer, link or QR per sale.', 'err'); return; }
    setBusy(true);
    try {
      const sale = await rpc<Sale>('till_checkout', { p_org: orgId, p_sale: {
        client_uuid: clientRef.current, location_id: loc, shift_id: shift.id, customer_id: customer?.id || null,
        price_list_id: listId || null, retail_only: !listId,
        lines: lines.map((l) => ({ item_id: l.item.id, qty: l.qty, unit: l.unit, unit_price: l.override, discount: l.discount || 0 })),
        cart_discount: cartDisc || 0,
        tenders: effTenders.filter((t) => (money(t.amount) || 0) > 0).map((t) => ({ method: t.method, amount: money(t.amount), bank_account_id: t.bank_account_id || null, reference: t.reference || null })),
      } });
      const chg = change;
      reset();
      qc.invalidateQueries({ queryKey: ['till'] }); qc.invalidateQueries({ queryKey: ['sales'] }); qc.invalidateQueries({ queryKey: ['inv'] });
      const req = (sale.requests || []).find((r) => r.status === 'creating' || r.status === 'pending');
      if (req) setPaying({ sale, request: req });
      else setReceipt({ sale, change: chg });
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }

  // Keyboard: F2 finds an item, F9 takes payment.
  useEffect(() => {
    const h = (e: KeyboardEvent) => {
      if (e.key === 'F2') { e.preventDefault(); (document.querySelector('[aria-label="Find an item"]') as HTMLInputElement | null)?.focus(); }
      if (e.key === 'F9') { e.preventDefault(); checkout(); }
    };
    window.addEventListener('keydown', h); return () => window.removeEventListener('keydown', h);
  });

  if (!inv) return null;
  if (!can(inv, 'record_sales')) return <div className="container"><Alert kind="yellow" icon="shield">Your role does not record sales. Ask the owner for the Record sales permission.</Alert></div>;
  const sellable = inv.items.filter((i) => Number(i.price) > 0 || i.item_type === 'merchandise' || i.item_type === 'finished_good');
  const priceLists = till.data?.price_lists || [];
  const accounts = till.data?.accounts || [];
  const banks = accounts.filter((a) => a.kind === 'bank');
  const methods: Method[] = ['cash', 'account', 'transfer', 'pos', 'link', 'qr', ...(customer && Number(customer.balance) < 0 ? ['credit' as Method] : []), 'cheque'];
  const onAccount = short > 0.004 && !!customer;

  return (
    <div className="container" style={{ maxWidth: 1400 }}>
      <div className="row wrap" style={{ justifyContent: 'space-between', gap: 10 }}>
        <div className="row wrap" style={{ gap: 8 }}>
          <select className="input input-sm" value={loc || ''} onChange={(e) => setLoc(e.target.value)} style={{ width: 'auto' }} aria-label="Branch">
            {inv.locations.map((l) => <option key={l.id} value={l.id}>{l.name}{(l as any).kind === 'van' ? ' (van)' : ''}</option>)}
          </select>
          {till.isLoading ? <Spinner small /> : shift ? (
            <button className="pill" onClick={() => setPanel('shift')}><span style={{ width: 8, height: 8, borderRadius: 4, background: '#22C55E' }} />{shift.number} · {shift.register} · {shift.opened_by_name.split(' ')[0]}</button>
          ) : <button className="btn btn-primary btn-sm" onClick={() => setOpening(true)}><Icon name="lock" size={14} color="#fff" />Open the till</button>}
          {shift && <button className="pill" onClick={() => setPanel('sales')}>{shift.sales_count} sales · {N2(shift.sales_total)}</button>}
        </div>
        <div className="row wrap faint" style={{ fontSize: 12 }}>F2 find · F9 pay</div>
      </div>

      <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: 'minmax(0,1.6fr) minmax(320px,1fr)', gap: 16, alignItems: 'start' }}>
        {/* ---------------- cart ---------------- */}
        <div className="card" style={{ overflow: 'visible' }}>
          <div className="card-hd" style={{ gap: 10 }}>
            <div className="grow"><ItemPicker items={sellable} onPick={(i) => add(i)} autoFocus placeholder="Scan a barcode, or type a name or SKU" /></div>
            <button className="btn btn-secondary btn-sm" onClick={() => setScan(!scan)}><Icon name="scan" size={14} />{scan ? 'Close camera' : 'Camera'}</button>
          </div>
          {fromMartina > 0 && lines.length > 0 && <div style={{ padding: '10px 16px 0' }}><Alert kind="blue" icon="sparkles">Martina put {fromMartina} {fromMartina === 1 ? 'product' : 'products'} in the cart. Check the quantities and prices, then take payment.</Alert></div>}
          {scan && <Camera paused={false} onCode={(code) => {
            const it = inv.items.find((i) => i.barcode === code || i.qr_code === code || i.sku === code);
            if (it) { add(it); navigator.vibrate?.(50); } else toast(`No item uses the code ${code}`, 'err');
          }} />}
          {!lines.length ? (
            <div style={{ padding: 20 }}>
              <Empty>Scan or search to add items. A barcode scanner works here as a keyboard.</Empty>
              <QuickPicks items={sellable} onPick={add} />
            </div>
          ) : (
            <div>
              {lines.map((l, i) => {
                const lp = listPrice(l, i);
                return (
                  <div key={l.key} className="tr" style={{ gridTemplateColumns: 'minmax(0,1fr) auto', gap: 10, padding: '12px 16px' }}>
                    <div className="row" style={{ gap: 10, minWidth: 0, alignItems: 'flex-start' }}>
                      <Thumb name={l.item.name} path={l.item.photo_path} size={40} />
                      <div style={{ minWidth: 0, flex: 1 }}>
                        <div style={{ fontWeight: 600 }} className="ellipsis">{l.item.name}</div>
                        <div className="row wrap" style={{ gap: 6, marginTop: 6 }}>
                          <div className="row" style={{ gap: 0, border: '1px solid #E6E6E6', borderRadius: 8 }}>
                            <button className="btn btn-ghost btn-xs" aria-label="One less" onClick={() => (l.qty > 1 ? update(l.key, { qty: l.qty - 1 }) : remove(l.key))}><Icon name="minus" size={13} /></button>
                            <input className="input input-sm num" inputMode="decimal" value={l.qty} onChange={(e) => update(l.key, { qty: Math.max(0, Number(e.target.value) || 0) })} style={{ width: 54, border: 0, textAlign: 'center', padding: 4 }} aria-label="Quantity" />
                            <button className="btn btn-ghost btn-xs" aria-label="One more" onClick={() => update(l.key, { qty: l.qty + 1 })}><Icon name="plus" size={13} /></button>
                          </div>
                          {l.item.pack_size > 1 ? (
                            <select className="input input-sm" style={{ width: 'auto' }} value={l.unit} onChange={(e) => update(l.key, { unit: e.target.value as Unit, override: null })} aria-label="Unit">
                              <option value="selling">{l.item.selling_unit}</option><option value="purchase">{l.item.purchase_unit} of {l.item.pack_size}</option>
                            </select>
                          ) : <span className="faint" style={{ fontSize: 12 }}>{l.item.selling_unit}</span>}
                          <span className="faint" style={{ fontSize: 12 }}>@</span>
                          {canPrice ? (
                            <input className="input input-sm num" inputMode="decimal" style={{ width: 100 }} value={l.override ?? lp} aria-label="Price"
                              onChange={(e) => { const v = money(e.target.value); update(l.key, { override: v == null || Math.abs(v - lp) < 0.005 ? null : v }); }} />
                          ) : <span className="num" style={{ fontSize: 13 }}>{N2(lp)}</span>}
                          <input className="input input-sm num" inputMode="decimal" placeholder="Discount" style={{ width: 90 }} value={l.discount || ''} aria-label="Line discount"
                            onChange={(e) => update(l.key, { discount: Math.max(0, money(e.target.value) || 0) })} />
                          {l.item.vat_treatment !== 'standard' && <span className="row" style={{ gap: 0 }}><span className="chip t-grey">{l.item.vat_treatment === 'zero' ? 'Zero-rated' : 'Exempt'}</span>
                            <VatInfo side="sale" treatment={l.item.vat_treatment} name={l.item.name} item={l.item} vatRegistered={inv.org.vat_registered} /></span>}
                        </div>
                      </div>
                    </div>
                    <div className="stack" style={{ alignItems: 'flex-end', gap: 6 }}>
                      <b className="num">{N2(lineTotal(l, i))}</b>
                      <button className="btn btn-ghost btn-xs" onClick={() => remove(l.key)} aria-label={`Remove ${l.item.name}`}><Icon name="trash" size={13} /></button>
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </div>

        {/* ---------------- payment ---------------- */}
        <div className="card card-pad stack" style={{ gap: 14, position: 'sticky', top: 0 }}>
          <Field label="Customer"><CustomerPicker value={customer} onChange={(c) => setCustomer(c)} /></Field>
          {priceLists.length > 0 && (
            <Field label="Prices">
              <select className="input" value={listId} onChange={(e) => setListId(e.target.value)}>
                <option value="">Retail</option>{priceLists.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
              </select>
            </Field>
          )}
          <div className="stack" style={{ gap: 6, fontSize: 14 }}>
            <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">Items</span><span className="num">{N2(subtotal)}</span></div>
            <div className="row" style={{ justifyContent: 'space-between', gap: 8 }}>
              <span className="muted">Discount on the sale</span>
              <input className="input input-sm num" inputMode="decimal" placeholder="0.00" value={cartDiscount} onChange={(e) => setCartDiscount(e.target.value)} style={{ width: 110, textAlign: 'right' }} aria-label="Discount on the sale" />
            </div>
            {!canPrice && discPct > maxPct + 0.001 && <Alert kind="yellow" icon="shield">Discounts above {maxPct}% need a manager.</Alert>}
            <div className="row" style={{ justifyContent: 'space-between', fontSize: 24, fontWeight: 700, marginTop: 4 }}><span>Total</span><span className="num">{N2(total)}</span></div>
            {settings.vat_registered && <div className="faint" style={{ fontSize: 12, textAlign: 'right' }}>VAT included where it applies</div>}
          </div>

          <div className="stack" style={{ gap: 8 }}>
            <div className="label">Payment</div>
            {tenders.map((t, i) => (
              <div key={i} className="stack" style={{ gap: 6, background: '#FAFAFA', borderRadius: 10, padding: 8 }}>
                <div className="row" style={{ gap: 6 }}>
                  <select className="input input-sm" value={t.method} onChange={(e) => setTenders((ts) => ts.map((x, j) => (j === i ? { ...x, method: e.target.value as Method } : x)))} aria-label="Way of paying">
                    {methods.map((m) => <option key={m} value={m}>{TENDER_LABEL[m]}</option>)}
                  </select>
                  <input className="input input-sm num" inputMode="decimal" placeholder={tenders.length === 1 ? String(total.toFixed(2)) : 'Amount'} value={t.amount} style={{ width: 120, textAlign: 'right' }} aria-label="Amount"
                    onChange={(e) => setTenders((ts) => ts.map((x, j) => (j === i ? { ...x, amount: e.target.value } : x)))} />
                  {tenders.length > 1 && <button className="btn btn-ghost btn-xs" onClick={() => setTenders((ts) => ts.filter((_, j) => j !== i))} aria-label="Remove this payment"><Icon name="x" size={13} /></button>}
                </div>
                {t.method === 'transfer' && (
                  <select className="input input-sm" value={t.bank_account_id || ''} onChange={(e) => setTenders((ts) => ts.map((x, j) => (j === i ? { ...x, bank_account_id: e.target.value } : x)))} aria-label="Bank account">
                    <option value="">Which of our accounts?</option>{banks.map((b) => <option key={b.id} value={b.id}>{b.name}{b.account_number ? ` · ${b.account_number}` : ''}</option>)}
                  </select>
                )}
                {INSTANT.includes(t.method) && <div className="faint" style={{ fontSize: 12 }}>{t.method === 'account' ? 'Your business account number appears for the customer, with the receipt number to quote. Counta confirms the money itself.' : t.method === 'qr' ? 'Show the QR code to the customer.' : 'Send the link to the customer.'}</div>}
                {t.method === 'transfer' && <div style={{ fontSize: 12, color: '#B45309' }}>A transfer to your own bank is not confirmed here: someone checks it against the bank later, and a delivery waits until then. To know before the goods leave, use Pay by transfer: Counta confirms it in seconds and says "payment received".</div>}
                {(t.method === 'pos' || t.method === 'card' || t.method === 'cheque') && <div className="faint" style={{ fontSize: 12 }}>Confirmed later by someone who keeps the books, against the bank.</div>}
              </div>
            ))}
            <button className="btn btn-ghost btn-sm" style={{ alignSelf: 'flex-start' }} onClick={() => setTenders((ts) => [...ts.map((t) => (t.amount ? t : { ...t, amount: '' })), { method: ts.some((x) => x.method === 'cash') ? 'account' : 'cash', amount: '' }])}>
              <Icon name="plus" size={13} />Split the payment
            </button>
            {change > 0.004 && <div className="row" style={{ justifyContent: 'space-between', color: '#15803D', fontWeight: 600 }}><span>Change</span><span className="num">{N2(change)}</span></div>}
            {short > 0.004 && tenders.some((t) => t.amount) && (
              customer ? <Alert kind="yellow" icon="info">{N2(short)} goes on {customer.name}'s account{Number(customer.credit_limit) > 0 ? ` (limit ${N2(customer.credit_limit)}, owes ${N2(Math.max(0, customer.balance))})` : ''}.</Alert>
                : <Alert kind="red" icon="alert">{N2(short)} is not covered. Take the rest, or choose the customer to sell on credit.</Alert>
            )}
          </div>
          <button className="btn btn-primary btn-block" style={{ padding: '14px 16px', fontSize: 16 }} disabled={busy || !lines.length || total <= 0 || (short > 0.004 && !onAccount && tenders.some((t) => t.amount))} onClick={checkout}>
            {busy ? 'Recording…' : !shift ? 'Open the till to sell' : `Take ${N2(total)}`}
          </button>
          {lines.length > 0 && <button className="btn btn-ghost btn-sm" onClick={reset}>Clear the sale</button>}
        </div>
      </div>

      {opening && loc && <OpenShift loc={loc} onClose={() => setOpening(false)} accounts={accounts} />}
      {panel === 'shift' && shift && <ShiftPanel shift={shift} accounts={accounts} onClose={() => setPanel(null)} />}
      {panel === 'sales' && shift && <ShiftSales shift={shift} onClose={() => setPanel(null)} onOpen={(s) => { setPanel(null); setReceipt({ sale: s, change: 0 }); }} />}
      {paying && <PayWait request={paying.request} saleNumber={paying.sale.number}
        onPaid={async () => { const s = await rpc<Sale>('get_sale', { p_sale: paying.sale.id }); setPaying(null); setReceipt({ sale: s, change: 0 }); qc.invalidateQueries({ queryKey: ['till'] }); }}
        onClose={() => { setPaying(null); toast(`${paying.sale.number} waits for the transfer. It completes on its own when the money lands.`); }}
        onCancelSale={async () => {
          try { await rpc('cancel_order', { p_sale: paying.sale.id, p_reason: 'Customer did not pay by transfer' }); toast(`${paying.sale.number} cancelled`); setPaying(null); qc.invalidateQueries({ queryKey: ['till'] }); }
          catch (e) { toast((e as Error).message, 'err'); }
        }} />}
      {receipt && <ReceiptModal sale={receipt.sale} change={receipt.change} onClose={() => setReceipt(null)} onNew={() => setReceipt(null)} />}
    </div>
  );
}

// Best sellers for one-tap adding.
function QuickPicks({ items, onPick }: { items: Item[]; onPick: (i: Item) => void }) {
  const top = useMemo(() => [...items].sort((a, b) => Number(b.sold_30) - Number(a.sold_30)).slice(0, 12), [items]);
  if (!top.length) return null;
  return (
    <div style={{ marginTop: 16 }}>
      <div className="label" style={{ marginBottom: 8 }}>Best sellers</div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill,minmax(140px,1fr))', gap: 8 }}>
        {top.map((i) => (
          <button key={i.id} className="entry-card" onClick={() => onPick(i)} style={{ textAlign: 'left', padding: 10, borderRadius: 10, background: '#fff', cursor: 'pointer' }}>
            <div className="ellipsis" style={{ fontSize: 13, fontWeight: 600 }}>{i.name}</div>
            <div className="faint" style={{ fontSize: 12 }}>{N2(i.price)} / {i.selling_unit}</div>
          </button>
        ))}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- shifts
function OpenShift({ loc, onClose, accounts }: { loc: string; onClose: () => void; accounts: any[] }) {
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const [count, setCount] = useState('');
  const [register, setRegister] = useState('');
  const [from, setFrom] = useState('');
  const [busy, setBusy] = useState(false);
  const banks = accounts.filter((a) => a.kind === 'bank' || a.kind === 'cash');
  async function open() {
    setBusy(true);
    try {
      await rpc('open_shift', { p_org: orgId, p_location: loc, p_opening_count: money(count) ?? 0, p_register: register || null, p_cash_account: null, p_float_from: from || null });
      toast('The till is open'); await qc.invalidateQueries({ queryKey: ['till'] }); onClose();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  return (
    <Modal onClose={onClose} width={440}>
      <ModalHead title="Open the till" sub="Count the cash in the drawer before the first sale." onClose={onClose} />
      <div className="modal-body">
        <Field label="Cash in the drawer now"><input className="input num" inputMode="decimal" autoFocus value={count} onChange={(e) => setCount(e.target.value)} placeholder="0.00" /></Field>
        <Field label="Till name" hint="For more than one till at the branch."><input className="input" value={register} onChange={(e) => setRegister(e.target.value)} placeholder="Till 1" /></Field>
        <Field label="Float taken from" hint="If the float came out of the bank or the safe today, Counta records the transfer.">
          <select className="input" value={from} onChange={(e) => setFrom(e.target.value)}>
            <option value="">It was already in the drawer</option>{banks.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}
          </select>
        </Field>
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={busy} onClick={open}>Open the till</button></div>
    </Modal>
  );
}

function ShiftPanel({ shift, accounts, onClose }: { shift: Shift; accounts: any[]; onClose: () => void }) {
  const { data: inv } = useInventory();
  const toast = useToast();
  const qc = useQueryClient();
  const chart = useChart();
  const [mode, setMode] = useState<'pay_in' | 'pay_out' | 'drop' | 'close' | null>(null);
  const [amount, setAmount] = useState('');
  const [reason, setReason] = useState('');
  const [account, setAccount] = useState('');
  const [bank, setBank] = useState('');
  const [result, setResult] = useState<any>(null);
  const [busy, setBusy] = useState(false);
  const expenses = (chart.data?.accounts || []).filter((a: any) => !a.is_group && a.active && /^6/.test(a.code));
  async function go() {
    setBusy(true);
    try {
      if (mode === 'close') {
        const r = await rpc<any>('close_shift', { p_shift: shift.id, p_counted: money(amount) ?? -1, p_notes: reason || null });
        setResult(r);
      } else {
        await rpc('cash_movement', { p_shift: shift.id, p_kind: mode, p_amount: money(amount), p_reason: reason, p_account: account || null, p_bank: bank || null });
        toast(mode === 'pay_in' ? 'Cash added' : mode === 'pay_out' ? 'Cash paid out' : 'Cash taken from the drawer');
        setMode(null); setAmount(''); setReason(''); setAccount(''); setBank('');
      }
      await qc.invalidateQueries({ queryKey: ['till'] });
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  const methods = Object.entries(shift.by_method || {});
  return (
    <Drawer onClose={onClose} width={520}>
      <div className="drawer-hd"><div className="grow"><div className="drawer-title">{shift.number} · {shift.register}</div>
        <div className="muted" style={{ fontSize: 13 }}>{shift.location_name} · opened {when(shift.opened_at)} by {shift.opened_by_name}</div></div>
        <button className="x-btn" onClick={onClose} aria-label="Close"><Icon name="x" size={18} /></button></div>
      <div className="drawer-body stack" style={{ gap: 16 }}>
        {result ? (
          <div className="stack" style={{ gap: 10 }}>
            <Alert kind={Math.abs(Number(result.difference || 0)) < 0.01 ? 'green' : 'yellow'} icon={Math.abs(Number(result.difference || 0)) < 0.01 ? 'check' : 'alert'}>
              {Math.abs(Number(result.difference || 0)) < 0.01 ? 'The drawer agrees to the books.' : Number(result.difference) > 0 ? `${N2(result.difference)} more cash than expected (cash over).` : `${N2(-result.difference)} less cash than expected (cash short).`}
            </Alert>
            <div className="muted" style={{ fontSize: 13 }}>Expected {N2(result.expected_cash)} · counted {N2(result.counted_cash)}. The difference is posted to cash over and short.</div>
            <button className="btn btn-primary" onClick={onClose}>Done</button>
          </div>
        ) : (
          <>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2,1fr)', gap: 10 }}>
              <div style={{ background: '#FAFAFA', borderRadius: 12, padding: 12 }}><div className="mini-label">Cash in the drawer</div><div style={{ fontSize: 22, fontWeight: 700 }}>{N2(shift.cash_balance)}</div></div>
              <div style={{ background: '#FAFAFA', borderRadius: 12, padding: 12 }}><div className="mini-label">Sales this shift</div><div style={{ fontSize: 22, fontWeight: 700 }}>{N2(shift.sales_total)}</div><div className="faint" style={{ fontSize: 12 }}>{shift.sales_count} sales{shift.voids ? ` · ${shift.voids} voided` : ''}</div></div>
            </div>
            {methods.length > 0 && <div className="stack" style={{ gap: 4 }}>{methods.map(([m, v]) => <div key={m} className="row" style={{ justifyContent: 'space-between', fontSize: 13 }}><span className="muted">{METHOD_LABEL[m] || m}</span><span className="num">{N2(v)}</span></div>)}
              {Number(shift.credit_sales) > 0 && <div className="row" style={{ justifyContent: 'space-between', fontSize: 13 }}><span className="muted">On account</span><span className="num">{N2(shift.credit_sales)}</span></div>}</div>}
            {(shift.movements || []).length > 0 && <div className="stack" style={{ gap: 4 }}><div className="label">Cash movements</div>{shift.movements.map((mv: any) => <div key={mv.id} className="row" style={{ justifyContent: 'space-between', fontSize: 13 }}><span className="ellipsis">{mv.kind === 'pay_in' ? 'In' : mv.kind === 'pay_out' ? 'Paid out' : 'Taken out'} · {mv.reason}</span><span className="num">{N2(mv.amount)}</span></div>)}</div>}
            {!mode ? (
              <div className="row wrap">
                <button className="btn btn-secondary btn-sm" onClick={() => setMode('pay_in')}>Cash in</button>
                <button className="btn btn-secondary btn-sm" onClick={() => setMode('pay_out')}>Pay out</button>
                <button className="btn btn-secondary btn-sm" onClick={() => setMode('drop')}>Take cash to bank or safe</button>
                <button className="btn btn-dark btn-sm" onClick={() => setMode('close')}><Icon name="lock" size={14} color="#fff" />Close the till</button>
              </div>
            ) : (
              <div className="card card-pad stack" style={{ gap: 10 }}>
                <div style={{ fontWeight: 600 }}>{mode === 'pay_in' ? 'Cash put into the drawer' : mode === 'pay_out' ? 'Cash paid out of the drawer' : mode === 'drop' ? 'Cash taken to the bank or safe' : 'Count the drawer'}</div>
                <Field label={mode === 'close' ? 'Cash counted' : 'Amount'}><input className="input num" inputMode="decimal" autoFocus value={amount} onChange={(e) => setAmount(e.target.value)} /></Field>
                {mode === 'pay_out' && <Field label="What it paid for"><select className="input" value={account} onChange={(e) => setAccount(e.target.value)}><option value="">General expenses</option>{expenses.map((a: any) => <option key={a.code} value={a.code}>{a.code} {a.name}</option>)}</select></Field>}
                {mode === 'drop' && <Field label="Where it went"><select className="input" value={bank} onChange={(e) => setBank(e.target.value)}><option value="">Choose</option>{accounts.filter((a) => a.id !== shift.cash_account_id && (a.kind === 'bank' || a.kind === 'cash')).map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}</select></Field>}
                <Field label={mode === 'close' ? 'Notes' : 'Reason'}><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} placeholder={mode === 'pay_out' ? 'Diesel for the generator' : mode === 'pay_in' ? 'Change from the bank' : ''} /></Field>
                <div className="row"><button className="btn btn-secondary btn-sm" onClick={() => setMode(null)}>Back</button><button className="btn btn-primary btn-sm" disabled={busy || money(amount) == null || (mode !== 'close' && !reason.trim())} onClick={go}>{mode === 'close' ? 'Close the till' : 'Record'}</button></div>
              </div>
            )}
            {!can(inv, 'approve_adjustments') && <div className="faint" style={{ fontSize: 12 }}>Only the cashier who opened this till or a manager can close it.</div>}
          </>
        )}
      </div>
    </Drawer>
  );
}

function ShiftSales({ shift, onClose, onOpen }: { shift: Shift; onClose: () => void; onOpen: (s: Sale) => void }) {
  const sales = useSales({ shift_id: shift.id });
  const toast = useToast();
  const qc = useQueryClient();
  const [voiding, setVoiding] = useState<string | null>(null);
  const [reason, setReason] = useState('');
  async function voidIt(id: string) {
    try { await rpc('void_sale', { p_sale: id, p_reason: reason }); toast('Sale voided'); setVoiding(null); setReason(''); qc.invalidateQueries({ queryKey: ['sales'] }); qc.invalidateQueries({ queryKey: ['till'] }); }
    catch (e) { toast((e as Error).message, 'err'); }
  }
  return (
    <Drawer onClose={onClose} width={560}>
      <div className="drawer-hd"><div className="grow"><div className="drawer-title">Sales on {shift.number}</div></div><button className="x-btn" onClick={onClose} aria-label="Close"><Icon name="x" size={18} /></button></div>
      <div className="drawer-body" style={{ padding: 0 }}>
        {sales.isLoading ? <div style={{ padding: 20 }}><Spinner /></div> : !(sales.data?.rows || []).length ? <div style={{ padding: 20 }}><Empty>No sales yet.</Empty></div> : (sales.data!.rows).map((s) => (
          <div key={s.id} className="tr" style={{ gridTemplateColumns: 'minmax(0,1fr) auto', padding: '12px 20px' }}>
            <div style={{ minWidth: 0 }}>
              <div className="row" style={{ gap: 8 }}><b>{s.number}</b><StatusChip s={s.status} /></div>
              <div className="faint" style={{ fontSize: 12 }}>{when(s.created_at)} · {s.customer_name}</div>
              {voiding === s.id && <div className="row" style={{ marginTop: 8 }}><input className="input input-sm" autoFocus placeholder="Why is it voided?" value={reason} onChange={(e) => setReason(e.target.value)} /><button className="btn btn-danger btn-xs" disabled={reason.trim().length < 3} onClick={() => voidIt(s.id)}>Void</button></div>}
            </div>
            <div className="stack" style={{ alignItems: 'flex-end', gap: 4 }}>
              <b className="num">{N2(s.total)}</b>
              <div className="row" style={{ gap: 4 }}>
                <button className="btn btn-ghost btn-xs" onClick={async () => onOpen(await rpc<Sale>('get_sale', { p_sale: s.id }))}>Receipt</button>
                {s.status !== 'void' && s.status !== 'cancelled' && <button className="btn btn-ghost btn-xs" onClick={() => setVoiding(voiding === s.id ? null : s.id)}>Void</button>}
                <Link className="btn btn-ghost btn-xs" to={`/sell/sales?open=${s.id}`}>Return</Link>
              </div>
            </div>
          </div>
        ))}
      </div>
    </Drawer>
  );
}
