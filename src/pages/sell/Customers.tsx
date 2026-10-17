// Customers: who owes what, credit limits and terms, price lists, statements, payments on account, refunds and reminders.
import { useEffect, useMemo, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { can, useInventory, useSession, useToast } from '../../state/session';
import { rpc } from '../../lib/supabase';
import { money, today, useCustomers, useSales, type Customer } from '../../lib/api';
import { N2, fmtDay, when } from '../../lib/format';
import { Icon } from '../../components/Icon';
import { Alert, Drawer, Empty, Field, Modal, ModalHead, Pills, SkeletonRows } from '../../components/ui';
import { ExportMenu, acc, useMeta } from '../../components/Books';
import type { RCol } from '../../lib/reports';
import { StatusChip, docUrl } from './common';
import { COUNTRIES, NG_STATES, countryName, isExport } from '../../lib/countries';
import { SaleDrawer } from './Sales';

type Tab = 'all' | 'owing' | 'overdue' | 'credit';

export default function Customers() {
  const { data: inv } = useInventory();
  const customers = useCustomers();
  const [tab, setTab] = useState<Tab>('all');
  const [q, setQ] = useState('');
  const [open, setOpen] = useState<Customer | 'new' | null>(null);
  const meta = useMeta();
  const list = useMemo(() => {
    const s = q.trim().toLowerCase();
    return (customers.data?.customers || []).filter((c) => !c.is_walk_in && !c.archived)
      .filter((c) => tab === 'all' || (tab === 'owing' && Number(c.balance) > 0) || (tab === 'overdue' && Number(c.overdue) > 0) || (tab === 'credit' && Number(c.balance) < 0))
      .filter((c) => !s || c.name.toLowerCase().includes(s) || (c.phone || '').includes(s) || (c.email || '').toLowerCase().includes(s))
      .sort((a, b) => Number(b.balance) - Number(a.balance) || a.name.localeCompare(b.name));
  }, [customers.data, tab, q]);
  if (!inv) return null;
  const all = (customers.data?.customers || []).filter((c) => !c.is_walk_in);
  const owed = all.reduce((a, c) => a + Math.max(0, Number(c.balance)), 0);
  const overdue = all.reduce((a, c) => a + Number(c.overdue || 0), 0);
  const cols: RCol[] = [{ key: 'name', label: 'Customer' }, { key: 'phone', label: 'Phone' }, { key: 'email', label: 'Email' }, { key: 'price_list_name', label: 'Price list' },
    { key: 'credit_limit', label: 'Credit limit', type: 'money' }, { key: 'terms_days', label: 'Terms (days)', type: 'int' }, { key: 'balance', label: 'Balance', type: 'money', total: true },
    { key: 'overdue', label: 'Overdue', type: 'money', total: true }, { key: 'sales_12m', label: 'Sales (12 months)', type: 'money', total: true }, { key: 'last_sale', label: 'Last sale', type: 'date' }];
  return (
    <div className="container">
      <div className="m-2" style={{ display: 'grid', gridTemplateColumns: 'repeat(3,minmax(0,1fr))', gap: 12 }}>
        <div className="card card-pad"><div className="label">Customers owe</div><div style={{ fontSize: 26, fontWeight: 700, marginTop: 6 }}>{N2(owed)}</div></div>
        <div className="card card-pad"><div className="label">Overdue</div><div style={{ fontSize: 26, fontWeight: 700, marginTop: 6, color: overdue > 0 ? '#DC2626' : undefined }}>{N2(overdue)}</div></div>
        <div className="card card-pad"><div className="label">Customers</div><div style={{ fontSize: 26, fontWeight: 700, marginTop: 6 }}>{all.length}</div></div>
      </div>
      <div className="row wrap" style={{ justifyContent: 'space-between' }}>
        <Pills value={tab} onChange={setTab} options={[{ id: 'all', label: 'All' }, { id: 'owing', label: 'Owe money' }, { id: 'overdue', label: 'Overdue' }, { id: 'credit', label: 'Hold credit' }]} />
        <div className="row wrap">
          <ExportMenu name={`${inv.org.name} customers ${today()}`} disabled={!list.length} sheets={() => [{ meta: meta('Customers', `As at ${fmtDay(today())}`), cols, rows: list as any }]} />
          <button className="btn btn-primary btn-sm" onClick={() => setOpen('new')}><Icon name="plus" size={14} color="#fff" />Customer</button>
        </div>
      </div>
      <div className="card" style={{ overflow: 'hidden' }}>
        <div className="card-hd"><div className="row" style={{ flex: 1 }}><Icon name="search" size={15} color="#9CA3AF" /><input className="input input-sm" style={{ border: 0, boxShadow: 'none' }} placeholder="Name, phone or email" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search customers" /></div></div>
        <div className="tbl">
          <div className="tr head shade th hide-sm" style={{ gridTemplateColumns: 'minmax(180px,1.6fr) 140px 120px 130px 120px 110px', minWidth: 820 }}>
            <span>Customer</span><span>Phone</span><span>Price list</span><span className="right">Balance</span><span className="right">Overdue</span><span className="right">Limit</span>
          </div>
          {customers.isLoading ? <SkeletonRows n={6} /> : !list.length ? <div style={{ padding: 20 }}><Empty>No customers here.</Empty></div> : list.map((c) => (
            <div key={c.id} className="tr click" onClick={() => setOpen(c)} style={{ gridTemplateColumns: 'minmax(180px,1.6fr) 140px 120px 130px 120px 110px', minWidth: 820 }}>
              <span className="ellipsis"><b>{c.name}</b>{isExport(c.country) ? <span className="chip t-blue" style={{ marginLeft: 6, fontSize: 11 }} title="Sales to this customer are exports, zero-rated for VAT">Export · {countryName(c.country)}</span> : null}{c.open_count ? <span className="faint" style={{ fontSize: 12 }}> · {c.open_count} open</span> : null}</span>
              <span className="muted">{c.phone || '—'}</span>
              <span className="muted">{c.price_list_name || 'Retail'}</span>
              <span className="right num" style={{ color: Number(c.balance) > 0 ? '#C2410C' : Number(c.balance) < 0 ? '#15803D' : undefined }}>{Number(c.balance) ? (Number(c.balance) < 0 ? `${N2(-c.balance)} credit` : N2(c.balance)) : '—'}</span>
              <span className="right num" style={{ color: Number(c.overdue) > 0 ? '#DC2626' : undefined }}>{Number(c.overdue) ? N2(c.overdue) : '—'}</span>
              <span className="right num muted">{Number(c.credit_limit) ? N2(c.credit_limit) : '—'}</span>
            </div>
          ))}
        </div>
      </div>
      {open && <CustomerDrawer customer={open === 'new' ? null : open} priceLists={customers.data?.price_lists || []} onClose={() => setOpen(null)} />}
    </div>
  );
}

function CustomerDrawer({ customer, priceLists, onClose }: { customer: Customer | null; priceLists: any[]; onClose: () => void }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const [tab, setTab] = useState<'details' | 'statement' | 'documents'>(customer ? 'statement' : 'details');
  const [f, setF] = useState({ name: '', phone: '', email: '', address: '', tin: '', kind: 'business', credit_limit: '', terms_days: '', price_list_id: '', whatsapp_opt_in: true,
    city: '', state: '', country: 'NG', contact_person: '', cc_emails: '' });
  const [busy, setBusy] = useState(false);
  const [modal, setModal] = useState<'pay' | 'refund' | null>(null);
  const [doc, setDoc] = useState<string | null>(null);
  const [range, setRange] = useState({ from: '', to: today() });
  useEffect(() => {
    if (customer) setF({ name: customer.name, phone: customer.phone || '', email: customer.email || '', address: customer.address || '', tin: customer.tin || '', kind: customer.kind || 'business',
      credit_limit: String(Number(customer.credit_limit) || ''), terms_days: String(customer.terms_days || ''), price_list_id: customer.price_list_id || '', whatsapp_opt_in: customer.whatsapp_opt_in,
      city: customer.city || '', state: customer.state || '', country: customer.country || 'NG', contact_person: customer.contact_person || '', cc_emails: (customer.cc_emails || []).join(', ') });
  }, [customer?.id]); // eslint-disable-line react-hooks/exhaustive-deps
  const statement = useQuery({ queryKey: ['statement', customer?.id, range.from, range.to], enabled: !!customer && tab === 'statement',
    queryFn: () => rpc<any>('customer_statement', { p_customer: customer!.id, p_from: range.from || null, p_to: range.to || null }) });
  const docs = useSales({ customer_id: customer?.id, limit: 200 });
  const meta = useMeta();
  const canCredit = can(inv, 'approve_adjustments') || can(inv, 'keep_books');
  const set = (k: string, v: any) => setF((x) => ({ ...x, [k]: v }));
  async function save() {
    setBusy(true);
    try {
      await rpc('save_customer', { p_org: orgId, p_customer: { id: customer?.id || null, name: f.name, phone: f.phone || null, email: f.email || null, address: f.address || null, tin: f.tin || null,
        kind: f.kind, price_list_id: f.price_list_id || null, whatsapp_opt_in: f.whatsapp_opt_in, city: f.city || null, state: f.state || null, country: f.country || 'NG',
        contact_person: f.contact_person || null, cc_emails: f.cc_emails.split(/[,;\s]+/).map((x) => x.trim()).filter(Boolean),
        ...(canCredit ? { credit_limit: money(f.credit_limit) ?? 0, terms_days: Number(f.terms_days) || 0 } : {}) } });
      toast('Customer saved'); await qc.invalidateQueries({ queryKey: ['customers'] }); if (!customer) onClose();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  async function sendStatement(channel: 'whatsapp' | 'email') {
    try { await rpc('send_statement', { p_customer: customer!.id, p_channel: channel }); toast('Statement sent'); } catch (e) { toast((e as Error).message, 'err'); }
  }
  const st = statement.data;
  return (
    <Drawer onClose={onClose} width={680}>
      <div className="drawer-hd"><div className="grow"><div className="drawer-title">{customer?.name || 'New customer'}</div>
        {customer && <div className="muted" style={{ fontSize: 13 }}>{Number(customer.balance) > 0 ? `Owes ${N2(customer.balance)}` : Number(customer.balance) < 0 ? `Holds ${N2(-customer.balance)} credit` : 'Owes nothing'}{Number(customer.overdue) ? ` · ${N2(customer.overdue)} overdue` : ''}</div>}</div>
        <button className="x-btn" onClick={onClose} aria-label="Close"><Icon name="x" size={18} /></button></div>
      <div className="drawer-body stack" style={{ gap: 14 }}>
        {customer && <Pills value={tab} onChange={setTab} options={[{ id: 'statement', label: 'Statement' }, { id: 'documents', label: 'Documents' }, { id: 'details', label: 'Details' }]} />}
        {tab === 'details' && (
          <div className="stack" style={{ gap: 12 }}>
            <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
              <Field label="Name" req><input className="input" value={f.name} onChange={(e) => set('name', e.target.value)} /></Field>
              <Field label="Kind"><select className="input" value={f.kind} onChange={(e) => set('kind', e.target.value)}><option value="business">Business</option><option value="individual">Individual</option></select></Field>
              <Field label="Phone (WhatsApp)"><input className="input" value={f.phone} onChange={(e) => set('phone', e.target.value)} inputMode="tel" /></Field>
              <Field label="Email" hint="Invoices and statements go here."><input className="input" value={f.email} onChange={(e) => set('email', e.target.value)} inputMode="email" placeholder="accounts@customer.com" /></Field>
              <Field label="Tax ID (TIN)" hint="Printed on your invoices to them. Needed when they deduct WHT."><input className="input" value={f.tin} onChange={(e) => set('tin', e.target.value)} /></Field>
              <Field label="Contact person"><input className="input" value={f.contact_person} onChange={(e) => set('contact_person', e.target.value)} placeholder="Who you deal with there" /></Field>
              <Field label="Copy emails to" hint="Up to 5 more addresses, separated by commas."><input className="input" value={f.cc_emails} onChange={(e) => set('cc_emails', e.target.value)} inputMode="email" placeholder="finance@customer.com" /></Field>
              <Field label="Price list"><select className="input" value={f.price_list_id} onChange={(e) => set('price_list_id', e.target.value)}><option value="">Retail</option>{priceLists.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</select></Field>
            </div>
            <Field label="Street address"><textarea className="input" value={f.address} onChange={(e) => set('address', e.target.value)} style={{ minHeight: 56 }} placeholder="12 Adeola Odeku Street, Victoria Island" /></Field>
            <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 12 }}>
              <Field label="City or town"><input className="input" value={f.city} onChange={(e) => set('city', e.target.value)} /></Field>
              <Field label={f.country === 'NG' ? 'State' : 'State or region'}>
                <input className="input" value={f.state} onChange={(e) => set('state', e.target.value)} list={f.country === 'NG' ? 'ng-states' : undefined} />
                <datalist id="ng-states">{NG_STATES.map((x) => <option key={x} value={x} />)}</datalist>
              </Field>
              <Field label="Country"><select className="input" value={f.country} onChange={(e) => set('country', e.target.value)}>{COUNTRIES.map((c) => <option key={c.code} value={c.code}>{c.name}</option>)}</select></Field>
            </div>
            {isExport(f.country) && <Alert kind="blue" icon="info">This customer is in {countryName(f.country)}, so what you sell them is an export. Counta zero-rates the VAT on their invoices (VAT status 2), even for items that are normally VATable or exempt.</Alert>}
            <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
              <Field label="Credit limit" hint={canCredit ? '0 means a manager approves each credit sale.' : 'Set by a manager or the bookkeeper.'}><input className="input" inputMode="decimal" disabled={!canCredit} value={f.credit_limit} onChange={(e) => set('credit_limit', e.target.value)} /></Field>
              <Field label="Payment terms (days)"><input className="input" inputMode="numeric" disabled={!canCredit} value={f.terms_days} onChange={(e) => set('terms_days', e.target.value)} /></Field>
            </div>
            <label className="check"><input type="checkbox" checked={f.whatsapp_opt_in} onChange={(e) => set('whatsapp_opt_in', e.target.checked)} />Send receipts and reminders by WhatsApp</label>
            <div><button className="btn btn-primary" disabled={busy || !f.name.trim()} onClick={save}>Save customer</button></div>
          </div>
        )}
        {tab === 'statement' && customer && (
          <div className="stack" style={{ gap: 12 }}>
            <div className="row wrap" style={{ justifyContent: 'space-between' }}>
              <div className="row wrap">
                <input className="input input-sm" type="date" value={range.from} onChange={(e) => setRange({ ...range, from: e.target.value })} style={{ width: 150 }} aria-label="From" />
                <span className="faint">to</span><input className="input input-sm" type="date" value={range.to} onChange={(e) => setRange({ ...range, to: e.target.value })} style={{ width: 150 }} aria-label="To" />
              </div>
              <div className="row wrap">
                <ExportMenu name={`${customer.name} statement ${range.to}`} disabled={!st} sheets={() => [{ meta: meta(`Statement · ${customer.name}`, `${fmtDay(st.from)} to ${fmtDay(st.to)}`),
                  cols: [{ key: 'date', label: 'Date', type: 'date' }, { key: 'ref', label: 'Journal' }, { key: 'memo', label: 'Details' }, { key: 'debit', label: 'Charged', type: 'money' }, { key: 'credit', label: 'Paid or credited', type: 'money' }, { key: 'balance', label: 'Balance', type: 'money' }],
                  rows: [{ memo: 'Opening balance', balance: st.opening, _style: 'subheading' }, ...st.lines, { memo: 'Closing balance', balance: st.closing, _style: 'total' }] }]} />
                <button className="btn btn-secondary btn-sm" onClick={() => sendStatement(customer.phone ? 'whatsapp' : 'email')}><Icon name="send" size={14} />Send statement</button>
              </div>
            </div>
            {statement.isLoading ? <SkeletonRows n={5} /> : st && (
              <div className="card" style={{ overflow: 'hidden' }}>
                <div className="tr head shade th" style={{ gridTemplateColumns: '100px minmax(0,1fr) 110px 110px 120px' }}><span>Date</span><span>Details</span><span className="right">Charged</span><span className="right">Paid</span><span className="right">Balance</span></div>
                <div className="tr" style={{ gridTemplateColumns: '100px minmax(0,1fr) 110px 110px 120px', fontWeight: 600 }}><span>{fmtDay(st.from)}</span><span>Opening balance</span><span /><span /><span className="right num">{acc(st.opening)}</span></div>
                {(st.lines || []).map((l: any, i: number) => (
                  <div key={i} className="tr" style={{ gridTemplateColumns: '100px minmax(0,1fr) 110px 110px 120px' }}>
                    <span className="muted">{fmtDay(l.date)}</span><span className="ellipsis">{l.memo}</span>
                    <span className="right num">{Number(l.debit) ? acc(l.debit) : ''}</span><span className="right num">{Number(l.credit) ? acc(l.credit) : ''}</span><span className="right num">{acc(l.balance)}</span>
                  </div>
                ))}
                <div className="tr" style={{ gridTemplateColumns: '100px minmax(0,1fr) 110px 110px 120px', fontWeight: 700, background: '#FAFAFA' }}><span>{fmtDay(st.to)}</span><span>Closing balance</span><span /><span /><span className="right num">{acc(st.closing)}</span></div>
              </div>
            )}
            {st && (st.open_items || []).length > 0 && (
              <div className="stack" style={{ gap: 6 }}>
                <div className="label">Open invoices</div>
                {st.open_items.map((o: any) => (
                  <div key={o.id} className="row" style={{ justifyContent: 'space-between', fontSize: 13 }}>
                    <button className="btn btn-ghost btn-xs" onClick={() => setDoc(o.id)}>{o.number}</button>
                    <span className="muted">due {fmtDay(o.due_date)}{o.days_overdue ? <b style={{ color: '#DC2626' }}> · {o.days_overdue} days late</b> : ''}</span>
                    <b className="num">{N2(o.balance)}</b>
                    <a className="btn btn-ghost btn-xs" href={docUrl(o.token)} target="_blank" rel="noreferrer">Pay link</a>
                  </div>
                ))}
              </div>
            )}
            <div className="row wrap">
              <button className="btn btn-primary btn-sm" onClick={() => setModal('pay')}>Payment on account</button>
              {Number(customer.balance) < 0 && canCredit && <button className="btn btn-secondary btn-sm" onClick={() => setModal('refund')}>Refund credit</button>}
            </div>
          </div>
        )}
        {tab === 'documents' && customer && (
          <div className="card" style={{ overflow: 'hidden' }}>
            {(docs.data?.rows || []).length === 0 ? <div style={{ padding: 16 }}><Empty>No documents yet.</Empty></div> : docs.data!.rows.map((s) => (
              <div key={s.id} className="tr click" onClick={() => setDoc(s.id)} style={{ gridTemplateColumns: '120px 100px minmax(0,1fr) 110px' }}>
                <b>{s.number}</b><span className="muted">{fmtDay(s.issue_date)}</span><span><StatusChip s={s.status} /></span><span className="right num">{N2(s.total)}</span>
              </div>
            ))}
          </div>
        )}
      </div>
      {modal === 'pay' && customer && <AccountPayment customer={customer} onClose={() => setModal(null)} />}
      {modal === 'refund' && customer && <RefundCredit customer={customer} onClose={() => setModal(null)} />}
      {doc && <SaleDrawer id={doc} onClose={() => setDoc(null)} />}
    </Drawer>
  );
}

function useAccounts() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  return useQuery({ queryKey: ['till-accounts', orgId], enabled: !!orgId && !!inv, queryFn: async () => (await rpc<any>('get_till', { p_org: orgId, p_location: inv!.locations[0]?.id })).accounts as any[] });
}

// A payment not tied to one invoice: spread over the oldest open invoices, the rest held as the customer's credit.
function AccountPayment({ customer, onClose }: { customer: Customer; onClose: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const accts = useAccounts();
  const [f, setF] = useState({ amount: '', method: 'transfer', bank_account_id: '', reference: '', received_at: today() });
  const [busy, setBusy] = useState(false);
  async function go() {
    setBusy(true);
    try {
      await rpc('record_payment', { p_org: orgId, p_payment: { customer_id: customer.id, amount: money(f.amount), method: f.method, bank_account_id: f.bank_account_id || null, reference: f.reference || null, received_at: f.received_at } });
      toast('Payment recorded'); await Promise.all(['customers', 'statement', 'sales'].map((k) => qc.invalidateQueries({ queryKey: [k] }))); onClose();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  return (
    <Modal onClose={onClose} width={440}>
      <ModalHead title="Payment on account" sub="It settles the oldest invoices first; anything over becomes the customer's credit." onClose={onClose} />
      <div className="modal-body">
        <Field label="Amount"><input className="input" inputMode="decimal" autoFocus value={f.amount} onChange={(e) => setF({ ...f, amount: e.target.value })} /></Field>
        <Field label="How"><select className="input" value={f.method} onChange={(e) => setF({ ...f, method: e.target.value })}><option value="transfer">Bank transfer</option><option value="cash">Cash</option><option value="pos">POS</option><option value="cheque">Cheque</option></select></Field>
        {f.method !== 'cash' && <Field label="Into"><select className="input" value={f.bank_account_id} onChange={(e) => setF({ ...f, bank_account_id: e.target.value })}><option value="">Choose the account</option>{(accts.data || []).filter((a) => a.kind !== 'cash').map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}</select></Field>}
        <Field label="Reference"><input className="input" value={f.reference} onChange={(e) => setF({ ...f, reference: e.target.value })} /></Field>
        <Field label="Date"><input className="input" type="date" value={f.received_at} onChange={(e) => setF({ ...f, received_at: e.target.value })} /></Field>
      </div>
      <div className="modal-ft"><button className="btn btn-primary" disabled={busy || !(money(f.amount)! > 0)} onClick={go}>Record</button></div>
    </Modal>
  );
}

function RefundCredit({ customer, onClose }: { customer: Customer; onClose: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const accts = useAccounts();
  const [f, setF] = useState({ amount: String(-Number(customer.balance)), method: 'transfer', bank_account_id: '', reason: '' });
  const [busy, setBusy] = useState(false);
  async function go() {
    setBusy(true);
    try {
      await rpc('refund_customer', { p_org: orgId, p_customer: customer.id, p_amount: money(f.amount), p_method: f.method, p_bank_account: f.bank_account_id || null, p_reason: f.reason });
      toast('Refund recorded'); await Promise.all(['customers', 'statement'].map((k) => qc.invalidateQueries({ queryKey: [k] }))); onClose();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  return (
    <Modal onClose={onClose} width={440}>
      <ModalHead title="Refund the customer's credit" sub={`${N2(-customer.balance)} available. To pay it from the wallet, use Payments.`} onClose={onClose} />
      <div className="modal-body">
        <Field label="Amount"><input className="input" inputMode="decimal" value={f.amount} onChange={(e) => setF({ ...f, amount: e.target.value })} /></Field>
        <Field label="Paid by"><select className="input" value={f.method} onChange={(e) => setF({ ...f, method: e.target.value })}><option value="transfer">Bank transfer</option><option value="cash">Cash</option><option value="cheque">Cheque</option></select></Field>
        <Field label="From"><select className="input" value={f.bank_account_id} onChange={(e) => setF({ ...f, bank_account_id: e.target.value })}><option value="">{f.method === 'cash' ? 'The branch drawer' : 'Choose the account'}</option>{(accts.data || []).map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}</select></Field>
        <Field label="Reason"><input className="input" value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })} /></Field>
        <Alert kind="grey" icon="info">Recorded as paid now. Make the transfer from your bank yourself.</Alert>
      </div>
      <div className="modal-ft"><button className="btn btn-primary" disabled={busy || !f.reason.trim()} onClick={go}>Record refund</button></div>
    </Modal>
  );
}

export { when };
