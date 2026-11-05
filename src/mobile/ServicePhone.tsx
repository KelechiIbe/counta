// The phone screens for a business that sells services: issue an invoice, record a payment against one, photograph a
// supplier's invoice or receipt, and the day's numbers. These need data: an invoice is numbered and posted by the books.
import { useMemo, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { can, useInventory, useSession, useToast } from '../state/session';
import { ai, rpc, supabase } from '../lib/supabase';
import { money, today, useSale, useSales, type Customer, type Sale } from '../lib/api';
import { N2, when } from '../lib/format';
import { compressImage } from '../lib/receive';
import { cap, useWords } from '../lib/wording';
import { vatInside, vatPct, vatRateOn } from '../lib/vat';
import { Icon } from '../components/Icon';
import { Spinner } from '../components/ui';
import { CustomerPicker, RecordPayment, SendBox } from '../pages/sell/common';
import { MTop, QueueBanner, useM } from './ctx';
import { Done } from './common';

function NeedsData({ title }: { title: string }) {
  return (<><MTop title={title} /><QueueBanner /><div className="m-pad muted" style={{ fontSize: 14, lineHeight: 1.5 }}>This needs a data connection: the books number and post it straight away. Try again when you are back online.</div></>);
}

// ---------------------------------------------------------------- today's numbers
export function TodayNumbers() {
  const { queue } = useM();
  const w = useWords();
  const day = today();
  const todays = useSales({ from: day, to: day, limit: 200 });
  const open = useSales({ doc_type: 'invoice', status: 'open,partially_paid', limit: 500 });
  if (!queue.online && !todays.data && !open.data) return null;
  const issued = (todays.data?.rows || []).filter((r) => (r.doc_type === 'invoice' || r.doc_type === 'receipt') && !['draft', 'void', 'cancelled'].includes(r.status));
  const rows = open.data?.rows || [];
  const owed = rows.reduce((a, r) => a + Number(r.balance || 0), 0);
  const late = rows.filter((r) => Number(r.overdue_days) > 0);
  const cell = (label: string, value: string, sub: string, tone?: string) => (
    <div className="m-card" style={{ padding: '10px 12px' }}>
      <div className="faint" style={{ fontSize: 11 }}>{label}</div>
      <div style={{ fontSize: 16, fontWeight: 700, marginTop: 2, color: tone }}>{value}</div>
      <div className="faint" style={{ fontSize: 11, marginTop: 1 }}>{sub}</div>
    </div>
  );
  return (
    <div className="stack" style={{ gap: 6 }}>
      <div className="label">Today</div>
      {todays.isLoading || open.isLoading ? <div className="m-card row" style={{ justifyContent: 'center' }}><Spinner small /></div> : (
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 8 }} data-testid="today-numbers">
          {cell('Issued today', N2(issued.reduce((a, r) => a + Number(r.total || 0), 0)), `${issued.length} ${issued.length === 1 ? w.sale : w.sales}`)}
          {cell(`${cap(w.customers)} owe you`, N2(owed), `${rows.length} unpaid`)}
          {cell('Overdue', N2(late.reduce((a, r) => a + Number(r.balance || 0), 0)), `${late.length} late`, late.length ? '#C2410C' : undefined)}
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------- issue an invoice
type Line = { key: string; description: string; amount: string };
const newLine = (): Line => ({ key: crypto.randomUUID(), description: '', amount: '' });

export function InvoicePhone() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const { queue } = useM();
  const toast = useToast();
  const qc = useQueryClient();
  const w = useWords();
  const [customer, setCustomer] = useState<Customer | null>(null);
  const [lines, setLines] = useState<Line[]>([newLine()]);
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [issuedId, setIssuedId] = useState<string | null>(null);
  const issued = useSale(issuedId);
  if (!inv) return null;
  if (!can(inv, 'record_sales')) return <><MTop title="Issue an invoice" /><div className="m-pad muted">Your role does not issue invoices.</div></>;
  if (!queue.online && !issuedId) return <NeedsData title="Issue an invoice" />;
  const incl = !!inv.org.prices_include_vat;
  const day = today();
  const sum = lines.reduce((a, l) => a + (money(l.amount) || 0), 0);
  const vat = inv.org.vat_registered ? (incl ? vatInside(sum, day) : sum * vatRateOn(day)) : 0;
  const total = incl ? sum : sum + vat;
  const filled = lines.filter((l) => l.description.trim() || l.amount.trim());
  const problem = !customer ? `Choose the ${w.customer}.` : !filled.length ? 'Describe the work and its price.'
    : filled.some((l) => !l.description.trim()) ? 'Describe the service on each line.' : filled.some((l) => !((money(l.amount) || 0) > 0)) ? 'Give each line a price above zero.' : null;
  const upd = (k: string, p: Partial<Line>) => setLines((ls) => ls.map((l) => (l.key === k ? { ...l, ...p } : l)));
  async function save(issue: boolean) {
    if (problem || !customer) { toast(problem || 'Check the invoice.', 'err'); return; }
    setBusy(true);
    try {
      const due = customer.terms_days ? new Date(Date.parse(day + 'T12:00:00Z') + customer.terms_days * 86400_000).toISOString().slice(0, 10) : null;
      const r = await rpc<Sale>('save_sale_doc', { p_org: orgId, p_doc: {
        id: null, doc_type: 'invoice', status: issue ? 'issue' : 'draft', customer_id: customer.id, issue_date: day, due_date: due, prices_include_vat: incl, delivery_fee: 0,
        notes: note.trim() || null, terms: inv!.org.invoice_note || null, reference: null,
        lines: filled.map((l) => ({ description: l.description.trim(), qty: 1, unit_price: money(l.amount), discount: 0, vat_treatment: 'standard', revenue_account: null })),
      } });
      await Promise.all(['sales', 'sale', 'customers'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
      if (!issue) { toast(`${r.number} saved as a draft. Issue it from Sales when it is ready.`); setLines([newLine()]); setNote(''); setCustomer(null); }
      else setIssuedId(r.id);
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  if (issuedId) {
    const s = issued.data;
    const held = s && s.status === 'draft';
    return (
      <>
        <MTop title="Invoice issued" />
        <div className="m-pad stack" style={{ gap: 14 }}>
          <Done title={s ? (held ? `${s.number} sent to NRS` : `${s.number} issued`) : 'Issued'} body={s ? (held ? `It is issued once NRS signs it. Total ${N2(s.total)}.` : `${s.customer_name} · ${N2(s.total)}. It is in your books.`) : ''}
            action="Issue another" onAction={() => { setIssuedId(null); setLines([newLine()]); setNote(''); setCustomer(null); }} />
          {s && !held && <div className="m-card stack" style={{ gap: 8 }}><b style={{ fontSize: 13 }}>Send it to {s.customer_name}</b><SendBox sale={s} /></div>}
        </div>
      </>
    );
  }
  return (
    <>
      <MTop title="Issue an invoice" />
      <QueueBanner />
      <div className="m-pad stack" style={{ gap: 12, paddingBottom: 24 }}>
        <div className="stack" style={{ gap: 6 }}>
          <div className="label">{cap(w.customer)}</div>
          <CustomerPicker value={customer} onChange={(c) => setCustomer(c)} walkIn={false} placeholder={`Choose the ${w.customer}`} />
        </div>
        <div className="stack" style={{ gap: 8 }}>
          <div className="label">The work</div>
          {lines.map((l, i) => (
            <div key={l.key} className="m-card stack" style={{ gap: 8 }}>
              <textarea className="input" rows={2} value={l.description} onChange={(e) => upd(l.key, { description: e.target.value })} placeholder="Describe the service rendered" aria-label={`Service ${i + 1}`} autoFocus={i === 0 && lines.length === 1} />
              <div className="row" style={{ gap: 8 }}>
                <input className="input" inputMode="decimal" value={l.amount} onChange={(e) => upd(l.key, { amount: e.target.value })} placeholder="Price (₦)" aria-label={`Price of service ${i + 1}`} style={{ fontSize: 16, fontWeight: 600 }} />
                {lines.length > 1 && <button className="btn btn-ghost btn-sm" onClick={() => setLines((ls) => ls.filter((x) => x.key !== l.key))} aria-label="Remove this line"><Icon name="trash" size={14} /></button>}
              </div>
            </div>
          ))}
          <button className="btn btn-secondary btn-sm" style={{ alignSelf: 'flex-start' }} onClick={() => setLines((ls) => [...ls, newLine()])}><Icon name="plus" size={13} />Add another service</button>
        </div>
        <textarea className="input" rows={2} value={note} onChange={(e) => setNote(e.target.value)} placeholder={`Note to the ${w.customer} (optional)`} aria-label="Note" />
        <div className="m-card stack" style={{ gap: 4, fontSize: 13 }}>
          {inv.org.vat_registered && <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">VAT {vatPct(day)}{incl ? ' (included)' : ''}</span><span>{N2(vat)}</span></div>}
          <div className="row" style={{ justifyContent: 'space-between', fontSize: 17, fontWeight: 700 }}><span>Total</span><span data-testid="invoice-total">{N2(total)}</span></div>
        </div>
        {problem && filled.length > 0 && <div className="faint" style={{ fontSize: 12 }}>{problem}</div>}
        <div className="row" style={{ gap: 8 }}>
          <button className="m-btn secondary" style={{ flex: 1 }} disabled={busy} onClick={() => save(false)}>Save draft</button>
          <button className="m-btn" style={{ flex: 1 }} disabled={busy || !!problem} onClick={() => save(true)}>{busy ? 'Issuing…' : 'Issue invoice'}</button>
        </div>
      </div>
    </>
  );
}

// ---------------------------------------------------------------- record a payment received
export function PaymentPhone() {
  const { data: inv } = useInventory();
  const { queue } = useM();
  const w = useWords();
  const [q, setQ] = useState('');
  const [pick, setPick] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);
  const open = useSales({ doc_type: 'invoice,receipt,order', status: 'open,partially_paid', limit: 500 });
  const sale = useSale(pick);
  const rows = useMemo(() => {
    const s = q.trim().toLowerCase();
    return (open.data?.rows || []).filter((r) => !s || (r.customer_name || '').toLowerCase().includes(s) || r.number.toLowerCase().includes(s))
      .sort((a, b) => Number(b.overdue_days) - Number(a.overdue_days) || b.issue_date.localeCompare(a.issue_date));
  }, [open.data, q]);
  if (!inv) return null;
  if (!can(inv, 'record_sales')) return <><MTop title="Record a payment" /><div className="m-pad muted">Your role does not record payments.</div></>;
  if (!queue.online) return <NeedsData title="Record a payment" />;
  if (done) return <><MTop title="Payment recorded" /><Done title="Payment recorded" body={done} action="Record another" onAction={() => { setDone(null); setPick(null); }} /></>;
  return (
    <>
      <MTop title="Record a payment" />
      <QueueBanner />
      <div className="m-pad stack" style={{ gap: 10, paddingBottom: 24 }}>
        <div className="muted" style={{ fontSize: 13 }}>Choose the invoice the {w.customer} paid. If they kept withholding tax, enter it with the payment.</div>
        <div className="row" style={{ border: '1px solid #E6E6E6', borderRadius: 10, padding: '10px 12px' }}>
          <Icon name="search" size={16} color="#9CA3AF" />
          <input value={q} onChange={(e) => setQ(e.target.value)} placeholder={`${cap(w.customer)} or invoice number`} aria-label="Search unpaid invoices" style={{ border: 'none', fontSize: 15, flex: 1, minWidth: 0, outline: 'none', boxShadow: 'none' }} />
        </div>
        {open.isLoading ? <div className="row" style={{ justifyContent: 'center', padding: 20 }}><Spinner /></div>
          : !rows.length ? <div className="muted" style={{ fontSize: 13, padding: '8px 0' }}>{q ? 'Nothing unpaid matches.' : 'Nothing is waiting to be paid.'}</div>
          : rows.slice(0, 40).map((r) => (
            <button key={r.id} className="m-card row" style={{ cursor: 'pointer', font: 'inherit', textAlign: 'left' }} onClick={() => setPick(r.id)} disabled={pick === r.id && sale.isLoading}>
              <span className="grow" style={{ minWidth: 0 }}>
                <span className="ellipsis" style={{ display: 'block', fontSize: 13, fontWeight: 600 }}>{r.customer_name}</span>
                <span className="faint" style={{ fontSize: 11 }}>{r.number} · {when(r.issue_date)}{Number(r.overdue_days) > 0 ? ` · ${r.overdue_days} days late` : ''}</span>
              </span>
              <span style={{ fontSize: 13, fontWeight: 700, color: Number(r.overdue_days) > 0 ? '#C2410C' : undefined }}>{N2(r.balance)}</span>
              {pick === r.id && sale.isLoading ? <Spinner small /> : <Icon name="chevR" size={16} color="#9CA3AF" />}
            </button>
          ))}
      </div>
      {pick && sale.data && sale.data.id === pick && (
        <RecordPayment sale={sale.data} onClose={() => setPick(null)} onDone={() => setDone(`${sale.data!.number} · ${sale.data!.customer_name}. It is in your books.`)} />
      )}
    </>
  );
}

// ---------------------------------------------------------------- photograph a supplier's invoice or receipt
const SI_STATE: Record<string, [string, string]> = { reading: ['Reading', '#0072F5'], review: ['To review', '#A16207'], approved: ['Approved', '#15803D'], rejected: ['Returned', '#6B7280'], failed: ['Could not read', '#B91C1C'] };
export function BillPhone() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const { queue } = useM();
  const nav = useNavigate();
  const qc = useQueryClient();
  const cam = useRef<HTMLInputElement>(null);
  const file = useRef<HTMLInputElement>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [sent, setSent] = useState<string | null>(null);
  const allowed = !!inv && can(inv, 'keep_books');
  const list = useQuery({ queryKey: ['supplier-invoices', orgId, 'phone'], enabled: !!orgId && allowed && queue.online, retry: 1,
    queryFn: () => rpc<any>('supplier_invoices_list', { p_org: orgId, p: { status: null } }),
    refetchInterval: (query) => (((query.state.data as any)?.rows || []).some((r: any) => r.status === 'reading') ? 5000 : 30_000) });
  if (!inv) return null;
  if (!allowed) return <><MTop title="Supplier invoice" /><div className="m-pad muted">Your role does not enter bills. Ask the owner for "Keep the books".</div></>;
  if (!queue.online) return <NeedsData title="Supplier invoice" />;
  async function go(f: File) {
    setErr(null); setSent(null);
    if (!/^(application\/pdf|image\/(jpeg|png|webp))$/.test(f.type)) { setErr('Send a PDF or a photo (JPEG, PNG or WebP).'); return; }
    setBusy(true);
    try {
      const body = f.type.startsWith('image/') ? await compressImage(f) : f;
      if (body.size > 8 * 1024 * 1024) throw new Error('The file is larger than 8 MB. Take the photo again, or send a smaller PDF.');
      const type = body.type || f.type;
      const ext = type === 'application/pdf' ? 'pdf' : type.split('/')[1].replace('jpeg', 'jpg');
      const path = `${orgId}/bills/upload-${today()}-${crypto.randomUUID()}.${ext}`;
      const up = await supabase.storage.from('documents').upload(path, body, { contentType: type, upsert: false });
      if (up.error) throw new Error(up.error.message.includes('row-level') ? 'Your role cannot upload invoices.' : up.error.message);
      const r = await ai<{ invoice: any }>('read_supplier_invoice', { org_id: orgId, path, file_name: f.name || `photo.${ext}` });
      if (r.ok === false) throw new Error(r.error || 'Could not send it.');
      setSent(r.invoice?.number || 'The invoice');
      await qc.invalidateQueries({ queryKey: ['supplier-invoices'] });
    } catch (e) { setErr((e as Error).message); }
    setBusy(false);
  }
  const rows: any[] = (list.data?.rows || []).slice(0, 8);
  return (
    <>
      <MTop title="Supplier invoice" />
      <QueueBanner />
      <div className="m-pad stack" style={{ gap: 12, paddingBottom: 24 }}>
        <div className="muted" style={{ fontSize: 13, lineHeight: 1.5 }}>Photograph a supplier's invoice or receipt, or pick the PDF. Counta reads it, finds the supplier and writes the bill for you to check.</div>
        <input ref={cam} type="file" accept="image/*" capture="environment" style={{ display: 'none' }} onChange={(e) => { const f = e.target.files?.[0]; e.target.value = ''; if (f) void go(f); }} />
        <input ref={file} type="file" accept="application/pdf,image/jpeg,image/png,image/webp" style={{ display: 'none' }} onChange={(e) => { const f = e.target.files?.[0]; e.target.value = ''; if (f) void go(f); }} />
        <button className="m-btn" disabled={busy} onClick={() => cam.current?.click()}>{busy ? 'Sending…' : 'Take a photo'}</button>
        <button className="m-btn secondary" disabled={busy} onClick={() => file.current?.click()}>Pick a PDF or photo</button>
        {sent && <div className="alert alert-green" style={{ fontSize: 13 }} data-testid="bill-sent">{sent} received. Counta is reading it now; it shows below as soon as it is read.</div>}
        {err && <div className="alert alert-red" style={{ fontSize: 13 }}>{err}</div>}
        {rows.length > 0 && (
          <div className="stack" style={{ gap: 6 }}>
            <div className="label">Latest</div>
            {rows.map((r) => {
              const st = SI_STATE[r.status] || [r.status, '#6B7280'];
              return (
                <button key={r.id} className="m-card row" style={{ cursor: 'pointer', font: 'inherit', textAlign: 'left' }} onClick={() => nav(`/purchases/bills?tab=invoices&open=${r.id}`)}>
                  <span className="grow" style={{ minWidth: 0 }}>
                    <span className="ellipsis" style={{ display: 'block', fontSize: 13, fontWeight: 600 }}>{r.vendor_name || r.number}</span>
                    <span className="faint" style={{ fontSize: 11 }}>{r.number} · {when(r.created_at)}{Number(r.total) ? ` · ${N2(r.total)}` : ''}</span>
                  </span>
                  <span style={{ fontSize: 11, fontWeight: 600, color: st[1] }}>{r.status === 'reading' && <Spinner small />} {st[0]}</span>
                </button>
              );
            })}
          </div>
        )}
      </div>
    </>
  );
}
