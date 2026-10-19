// Sales and invoices: receipts, invoices, quotes and credit notes; payments waiting for confirmation; returns.
import React, { useEffect, useMemo, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { can, useInventory, useSession, useToast } from '../../state/session';
import { rpc } from '../../lib/supabase';
import { DOC_LABEL, METHOD_LABEL, VAT_STATUS, money, today, useChart, useCustomers, useSale, useSales, type Customer, type DocType, type Sale, type SaleRow, moneyAccounts } from '../../lib/api';
import { countryName, isExport } from '../../lib/countries';
import { N2, fmtDay, when } from '../../lib/format';
import { Icon } from '../../components/Icon';
import { ItemPicker } from '../../components/ItemPicker';
import { Alert, Drawer, Empty, Field, Modal, ModalHead, Pills, SkeletonRows, Spinner } from '../../components/ui';
import { ExportMenu, useMeta } from '../../components/Books';
import type { RCol } from '../../lib/reports';
import { useDraft, type Drafts } from '../../lib/drafts';
import { CustomerPicker, PaymentsList, PrintButtons, RecordPayment, RequestPayment, SaleLines, SendBox, StatusChip, docUrl, dueText } from './common';

type Tab = 'all' | 'invoice' | 'receipt' | 'quote' | 'credit_note' | 'unpaid' | 'confirm';

export default function Sales() {
  const { data: inv } = useInventory();
  const [params, setParams] = useSearchParams();
  const [tab, setTab] = useState<Tab>(() => (params.get('tab') as Tab) || 'all');
  const [q, setQ] = useState('');
  const [range, setRange] = useState({ from: '', to: '' });
  const [vs, setVs] = useState('');
  const [editing, setEditing] = useState<{ id?: string; type: 'invoice' | 'quote'; draft?: Drafts['invoice'] } | null>(null);
  // An invoice Martina prepared opens in the editor for the person to check.
  const draft = useDraft('invoice');
  useEffect(() => { if (draft) setEditing({ type: 'invoice', draft }); }, [draft]);
  const open = params.get('open');
  const filter = useMemo(() => ({
    q: q || null, from: range.from || null, to: range.to || null,
    doc_type: tab === 'all' || tab === 'unpaid' || tab === 'confirm' ? (tab === 'unpaid' ? 'invoice,receipt,order' : null) : tab,
    status: tab === 'unpaid' ? 'open,partially_paid' : null, vat_status: vs || null, limit: 500,
  }), [tab, q, range, vs]);
  const sales = useSales(filter);
  const meta = useMeta();
  if (!inv) return null;
  const rows = sales.data?.rows || [];
  const pending = sales.data?.pending_payments || [];
  const cols: RCol[] = [{ key: 'number', label: 'Number' }, { key: 'doc', label: 'Type' }, { key: 'issue_date', label: 'Date', type: 'date' }, { key: 'customer_name', label: 'Customer' },
    { key: 'status', label: 'Status' }, { key: 'subtotal', label: 'Before VAT', type: 'money', total: true }, { key: 'vat_total', label: 'VAT', type: 'money', total: true },
    { key: 'total', label: 'Total', type: 'money', total: true }, { key: 'balance', label: 'Balance', type: 'money', total: true }, { key: 'due_date', label: 'Due', type: 'date' },
    { key: 'vat_status', label: 'VAT status (0 VATable, 1 exempt, 2 zero-rated)' }, { key: 'export_to', label: 'Export to' }];
  return (
    <div className="container">
      <div className="row wrap" style={{ justifyContent: 'space-between', gap: 10 }}>
        <Pills value={tab} onChange={setTab} options={[
          { id: 'all', label: 'All' }, { id: 'invoice', label: 'Invoices' }, { id: 'receipt', label: 'Receipts' }, { id: 'quote', label: 'Quotes' },
          { id: 'credit_note', label: 'Credit notes' }, { id: 'unpaid', label: 'Unpaid' }, { id: 'confirm', label: 'Payments to confirm', count: pending.length || undefined },
        ]} />
        <div className="row wrap">
          <ExportMenu name={`${inv.org.name} sales ${today()}`} disabled={!rows.length}
            sheets={() => [{ meta: meta('Sales and invoices', range.from ? `${fmtDay(range.from)} to ${fmtDay(range.to || today())}` : 'Latest 500'), cols,
              rows: rows.map((r) => ({ ...r, doc: DOC_LABEL[r.doc_type], status: r.status.replace(/_/g, ' '), vat_status: (r.vat_statuses || []).slice().sort().join(', '),
                export_to: r.export ? countryName(r.customer_country) : '' })) }]} />
          <button className="btn btn-secondary btn-sm" onClick={() => setEditing({ type: 'quote' })}><Icon name="plus" size={14} />Quote</button>
          <button className="btn btn-primary btn-sm" onClick={() => setEditing({ type: 'invoice' })}><Icon name="plus" size={14} color="#fff" />Invoice</button>
        </div>
      </div>
      {tab === 'confirm' ? <PendingPayments rows={pending} /> : (
        <div className="card" style={{ overflow: 'hidden' }}>
          <div className="card-hd">
            <div className="row" style={{ flex: '1 1 260px' }}><Icon name="search" size={15} color="#9CA3AF" /><input className="input input-sm" style={{ border: 0, boxShadow: 'none' }} placeholder="Number, customer, phone or reference" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search sales" /></div>
            <div className="row wrap">
              <input className="input input-sm" type="date" value={range.from} onChange={(e) => setRange({ ...range, from: e.target.value })} style={{ width: 150 }} aria-label="From" />
              <span className="faint">to</span>
              <input className="input input-sm" type="date" value={range.to} onChange={(e) => setRange({ ...range, to: e.target.value })} style={{ width: 150 }} aria-label="To" />
              <select className="input input-sm" value={vs} onChange={(e) => setVs(e.target.value)} style={{ width: 170 }} aria-label="VAT status">
                <option value="">Any VAT status</option>{[0, 1, 2].map((k) => <option key={k} value={k}>{k} · {VAT_STATUS[k].label}</option>)}
              </select>
            </div>
          </div>
          <div className="faint" style={{ fontSize: 12, padding: '8px 20px', borderBottom: '1px solid var(--line)' }}>
            VAT status: <b>0</b> VATable (7.5%) · <b>1</b> Exempt · <b>2</b> Zero-rated. Sales to customers outside Nigeria are exports and always 2.
          </div>
          <div className="tbl">
            <div className="tr head shade th hide-sm" style={{ gridTemplateColumns: '130px 110px minmax(160px,1.4fr) 90px 130px 120px 120px 140px', minWidth: 990 }}>
              <span>Number</span><span>Date</span><span>Customer</span><span title="0 VATable · 1 Exempt · 2 Zero-rated">VAT status</span><span>Status</span><span className="right">Total</span><span className="right">Balance</span><span>Due</span>
            </div>
            {sales.isLoading ? <SkeletonRows n={8} /> : !rows.length ? <div style={{ padding: 20 }}><Empty>No sales match.</Empty></div> : rows.map((r) => (
              <div key={r.id} className="tr click" onClick={() => setParams({ open: r.id })} style={{ gridTemplateColumns: '130px 110px minmax(160px,1.4fr) 90px 130px 120px 120px 140px', minWidth: 990 }}>
                <span><b>{r.number}</b><span className="faint" style={{ display: 'block', fontSize: 11 }}>{DOC_LABEL[r.doc_type]}{r.channel === 'online' ? ' · shop' : ''}</span></span>
                <span className="muted">{fmtDay(r.issue_date)}</span>
                <span className="ellipsis">{r.customer_name}{r.export && <span className="faint" style={{ display: 'block', fontSize: 11 }}>Export · {countryName(r.customer_country)}</span>}</span>
                <span><VatStatusChips codes={r.vat_statuses} /></span>
                <span><StatusChip s={r.status} />{Number(r.pending) > 0 && <span className="chip t-amber" style={{ marginLeft: 4 }}>to confirm</span>}</span>
                <span className="right num">{N2(r.total)}</span>
                <span className="right num" style={{ color: Number(r.balance) > 0 ? '#C2410C' : undefined }}>{Number(r.balance) ? N2(r.balance) : '—'}</span>
                <span className="muted" style={{ fontSize: 12, color: r.overdue_days ? '#DC2626' : undefined }}>{dueText(r)}</span>
              </div>
            ))}
          </div>
        </div>
      )}
      {open && <SaleDrawer id={open} onClose={() => setParams({})} onEdit={(s) => setEditing({ id: s.id, type: s.doc_type as 'invoice' | 'quote' })} />}
      {editing && <DocEditor id={editing.id} type={editing.type} draft={editing.draft} onClose={() => setEditing(null)} onSaved={(id) => { setEditing(null); setParams({ open: id }); }} />}
    </div>
  );
}

export function VatStatusChips({ codes }: { codes?: number[] }) {
  const list = (codes || []).slice().sort();
  if (!list.length) return <span className="faint">—</span>;
  return (
    <span className="row" style={{ gap: 3 }}>
      {list.map((k) => <span key={k} className={'chip ' + VAT_STATUS[k].tone} title={VAT_STATUS[k].label} style={{ minWidth: 22, textAlign: 'center' }}>{k}</span>)}
    </span>
  );
}

// ---------------------------------------------------------------- one document
export function SaleDrawer({ id, onClose, onEdit, actions }: { id: string; onClose: () => void; onEdit?: (s: Sale) => void; actions?: (s: Sale, act: (fn: () => Promise<any>, ok: string) => Promise<void>, busy: boolean) => React.ReactNode }) {
  const { data: inv } = useInventory();
  const sale = useSale(id);
  const toast = useToast();
  const qc = useQueryClient();
  const [modal, setModal] = useState<'pay' | 'request' | 'return' | 'void' | 'credit' | 'export' | null>(null);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const s = sale.data;
  const refresh = () => Promise.all(['sale', 'sales', 'customers', 'till', 'inv'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
  async function act(fn: () => Promise<any>, ok: string) {
    setBusy(true);
    try { await fn(); toast(ok); await refresh(); setModal(null); setReason(''); } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  const owed = s ? Number(s.balance) > 0.004 && ['open', 'partially_paid', 'pending'].includes(s.status) : false;
  return (
    <Drawer onClose={onClose} width={640}>
      <div className="drawer-hd">
        <div className="grow" style={{ minWidth: 0 }}>
          <div className="row" style={{ gap: 8 }}><div className="drawer-title">{s ? `${DOC_LABEL[s.doc_type]} ${s.number}` : 'Loading…'}</div>{s && <StatusChip s={s.status} />}</div>
          {s && <div className="muted" style={{ fontSize: 13 }}>{s.customer_name} · {fmtDay(s.issue_date)}{s.due_date && s.doc_type !== 'receipt' ? ` · due ${fmtDay(s.due_date)}` : ''}{s.journal_ref ? ` · ${s.journal_ref}` : ''}</div>}
        </div>
        <button className="x-btn" onClick={onClose} aria-label="Close"><Icon name="x" size={18} /></button>
      </div>
      <div className="drawer-body stack" style={{ gap: 16 }}>
        {!s ? <Spinner /> : (
          <>
            {s.status === 'pending' && s.doc_type === 'receipt' && <Alert kind="yellow" icon="clock">Waiting for the customer's transfer. It posts the moment the money lands.</Alert>}
            {s.status === 'draft' && <Alert kind="grey" icon="pencil">Draft. Nothing is in the books until it is issued.</Alert>}
            {s.export ? (
              <Alert kind="blue" icon="truck">Export{isExport(s.customer_country) ? ` to ${countryName(s.customer_country)}` : ''}: every line is zero-rated (VAT status 2), whatever the item's usual treatment.{s.export_note ? ` Note: ${s.export_note}` : ''}</Alert>
            ) : isExport(s.customer_country) && s.export_note ? (
              <Alert kind="yellow" icon="info">The customer is in {countryName(s.customer_country)}, but this sale is treated as a local supply. Note: {s.export_note}</Alert>
            ) : null}
            {!s.journal_id && (s.status === 'draft' || (s.doc_type === 'quote' && s.status === 'open') || (s.doc_type === 'order' && s.status === 'pending')) && s.doc_type !== 'receipt'
              && (can(inv, 'approve_adjustments') || can(inv, 'keep_books')) && (
              <div><button className="link" style={{ fontSize: 13 }} onClick={() => { setReason(''); setModal('export'); }}>{s.export ? 'Not an export? Charge VAT as normal' : 'Exported? Zero-rate this sale'}</button></div>
            )}
            {s.viewed_at && <div className="faint" style={{ fontSize: 12 }}>The customer opened it {when(s.viewed_at)}.</div>}
            <SaleLines sale={s} />
            <PaymentsList sale={s} />
            {(s.credit_notes || []).length > 0 && <div className="stack" style={{ gap: 4 }}><div className="label">Credit notes</div>{s.credit_notes.map((c: any) => <div key={c.id} className="row" style={{ justifyContent: 'space-between', fontSize: 13 }}><span>{c.number} · {c.notes || ''}</span><b className="num">{N2(c.total)}</b></div>)}</div>}
            {(s.deliveries || []).length > 0 && <div className="stack" style={{ gap: 4 }}><div className="label">Delivery</div>{s.deliveries.map((d: any) => <div key={d.id} className="row" style={{ justifyContent: 'space-between', fontSize: 13 }}><span>{d.number} · {d.address || ''}</span><StatusChip s={d.status} /></div>)}</div>}
            {s.notes && <div className="muted" style={{ fontSize: 13 }}>{s.notes}</div>}
            <div className="row wrap">
              {s.status === 'draft' && onEdit && <button className="btn btn-secondary btn-sm" onClick={() => onEdit(s)}><Icon name="pencil" size={14} />Edit</button>}
              {s.status === 'draft' && s.doc_type === 'invoice' && <button className="btn btn-primary btn-sm" disabled={busy} onClick={() => act(() => rpc('issue_invoice', { p_sale: s.id }), `${s.number} issued`)}>Issue invoice</button>}
              {s.doc_type === 'quote' && s.status === 'open' && <>
                {onEdit && <button className="btn btn-secondary btn-sm" onClick={() => onEdit(s)}><Icon name="pencil" size={14} />Edit</button>}
                <button className="btn btn-primary btn-sm" disabled={busy} onClick={() => act(() => rpc('convert_quote', { p_sale: s.id }), 'Invoice drafted from the quote')}>Turn into an invoice</button>
                <button className="btn btn-ghost btn-sm" disabled={busy} onClick={() => act(() => rpc('cancel_order', { p_sale: s.id, p_reason: 'Quote withdrawn' }), 'Quote withdrawn')}>Withdraw</button>
              </>}
              {actions?.(s, act, busy)}
              {owed && (s.status !== 'pending' || s.doc_type === 'order') && <button className="btn btn-primary btn-sm" onClick={() => setModal('pay')}>{s.doc_type === 'order' && !s.journal_id ? 'Take a deposit' : 'Record a payment'}</button>}
              {owed && <button className="btn btn-secondary btn-sm" onClick={() => setModal('request')}><Icon name="card" size={14} />Get paid</button>}
              {owed && Number(s.customer_credit || 0) > 0 && <button className="btn btn-secondary btn-sm" onClick={() => setModal('credit')}>Use {N2(s.customer_credit)} credit</button>}
              {owed && s.doc_type !== 'receipt' && <button className="btn btn-secondary btn-sm" disabled={busy} onClick={() => act(() => rpc('send_reminder', { p_sale: s.id, p_channel: s.customer_phone ? 'whatsapp' : 'email' }), 'Reminder sent')}><Icon name="bell" size={14} />Remind</button>}
              {s.journal_id && ['open', 'partially_paid', 'paid'].includes(s.status) && can(inv, 'approve_adjustments') && <button className="btn btn-secondary btn-sm" onClick={() => setModal('return')}><Icon name="undo" size={14} />Return or credit</button>}
              {['open', 'partially_paid', 'paid', 'pending'].includes(s.status) && s.doc_type !== 'quote' && <button className="btn btn-ghost btn-sm" onClick={() => setModal('void')}>Void</button>}
            </div>
            {s.status !== 'draft' && <><PrintButtons sale={s} /><SendBox sale={s} onSent={() => qc.invalidateQueries({ queryKey: ['sale'] })} /></>}
            {s.status !== 'draft' && <div className="faint" style={{ fontSize: 12 }}>Customer's copy: <a href={docUrl(s.public_token)} target="_blank" rel="noreferrer">{docUrl(s.public_token).replace(/^https?:\/\//, '')}</a></div>}
          </>
        )}
      </div>
      {s && modal === 'pay' && <RecordPayment sale={s} onClose={() => setModal(null)} />}
      {s && modal === 'request' && <RequestPayment sale={s} onClose={() => { setModal(null); refresh(); }} />}
      {s && modal === 'return' && <ReturnModal sale={s} onClose={() => setModal(null)} onDone={refresh} />}
      {s && modal === 'credit' && (
        <Modal onClose={() => setModal(null)} width={420}><ModalHead title="Use the customer's credit" sub={`${N2(s.customer_credit)} available`} onClose={() => setModal(null)} />
          <div className="modal-body"><Field label="Amount"><input className="input" inputMode="decimal" value={reason || String(Math.min(Number(s.customer_credit), Number(s.balance)))} onChange={(e) => setReason(e.target.value)} /></Field></div>
          <div className="modal-ft"><button className="btn btn-primary" disabled={busy} onClick={() => act(() => rpc('apply_customer_credit', { p_sale: s.id, p_amount: money(reason) ?? Math.min(Number(s.customer_credit), Number(s.balance)) }), 'Credit applied')}>Apply</button></div>
        </Modal>
      )}
      {s && modal === 'export' && (
        <Modal onClose={() => setModal(null)} width={460}>
          <ModalHead title={s.export ? 'Treat as a local sale' : 'Treat as an export'} sub={s.export
            ? 'Each line goes back to its item\'s own VAT treatment (0, 1 or 2).'
            : 'Every line becomes zero-rated (VAT status 2). Keep the shipping or export papers with your VAT records.'} onClose={() => setModal(null)} />
          <div className="modal-body"><Field label="Why" hint="Saved with the sale for the VAT records."><input className="input" autoFocus value={reason} onChange={(e) => setReason(e.target.value)}
            placeholder={s.export ? 'Delivered and used in Nigeria' : 'Shipped to the buyer in Accra, bill of lading 1234'} /></Field></div>
          <div className="modal-ft"><button className="btn btn-primary" disabled={busy || reason.trim().length < 3}
            onClick={() => act(() => rpc('set_sale_export', { p_sale: s.id, p_export: !s.export, p_reason: reason }), s.export ? 'VAT charged as normal' : 'Zero-rated as an export')}>Save</button></div>
        </Modal>
      )}
      {s && modal === 'void' && (
        <Modal onClose={() => setModal(null)} width={440}><ModalHead title={`Void ${s.number}`} sub="Reverses it in the books and puts the stock back. Money already paid becomes the customer's credit unless it was cash on the same sale." onClose={() => setModal(null)} />
          <div className="modal-body"><Field label="Why"><input className="input" autoFocus value={reason} onChange={(e) => setReason(e.target.value)} /></Field></div>
          <div className="modal-ft"><button className="btn btn-danger" disabled={busy || reason.trim().length < 3} onClick={() => act(() => rpc(s.status === 'pending' ? 'cancel_order' : 'void_sale', { p_sale: s.id, p_reason: reason }), `${s.number} voided`)}>Void</button></div>
        </Modal>
      )}
    </Drawer>
  );
}

function ReturnModal({ sale, onClose, onDone }: { sale: Sale; onClose: () => void; onDone: () => void }) {
  const [mode, setMode] = useState<'goods' | 'amount'>((sale.lines || []).some((l) => l.kind === 'goods' && Number(l.qty) - Number(l.returned_qty) > 0) ? 'goods' : 'amount');
  if (mode === 'amount') return <CreditAmount sale={sale} onClose={onClose} onDone={onDone} onGoods={() => setMode('goods')} />;
  return <ReturnGoods sale={sale} onClose={onClose} onDone={onDone} onAmount={() => setMode('amount')} />;
}

// A credit note for an amount with nothing coming back: a price reduction, a discount agreed after the sale, a
// service not delivered. VAT comes back at each line's own rate.
function CreditAmount({ sale, onClose, onDone, onGoods }: { sale: Sale; onClose: () => void; onDone: () => void; onGoods: () => void }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const [info, setInfo] = useState<any>(null);
  const [byLine, setByLine] = useState(false);
  const [whole, setWhole] = useState('');
  const [amt, setAmt] = useState<Record<string, string>>({});
  const [reason, setReason] = useState('');
  const [refund, setRefund] = useState({ method: 'none', amount: '', bank_account_id: '' });
  const [own, setOwn] = useState<any[]>([]);
  const [busy, setBusy] = useState(false);
  useEffect(() => { rpc<any>('sale_creditable', { p_sale: sale.id }).then(setInfo).catch((e) => toast((e as Error).message, 'err')); }, [sale.id]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { moneyAccounts(orgId!).then((accounts) => setOwn(accounts || [])).catch(() => {}); }, [orgId]); // eslint-disable-line react-hooks/exhaustive-deps
  const lines: any[] = (info?.lines || []).filter((l: any) => Number(l.creditable) > 0);
  const pool = lines.reduce((a, l) => a + Number(l.creditable), 0);
  const total = byLine ? lines.reduce((a, l) => a + (money(amt[l.id]) || 0), 0) : money(whole) || 0;
  const vat = byLine ? lines.reduce((a, l) => a + (Number(l.gross) ? (money(amt[l.id]) || 0) * Number(l.vat) / Number(l.gross) : 0), 0)
    : pool ? lines.reduce((a, l) => a + total * (Number(l.creditable) / pool) * (Number(l.gross) ? Number(l.vat) / Number(l.gross) : 0), 0) : 0;
  const due = Number(info?.due ?? sale.balance);
  const over = Math.max(0, total - due);
  async function go() {
    setBusy(true);
    try {
      const r = await rpc<any>('credit_sale', { p_sale: sale.id, p: {
        reason, ...(byLine ? { lines: lines.filter((l) => (money(amt[l.id]) || 0) > 0).map((l) => ({ sale_line_id: l.id, amount: money(amt[l.id]) })) } : { amount: total }),
        refund: refund.method === 'none' ? {} : { method: refund.method, amount: money(refund.amount) ?? over, bank_account_id: refund.bank_account_id || null } } });
      toast(`${r.credit_note?.number || 'Credit note'} raised${Number(r.refunded) > 0 ? ` · ${N2(r.refunded)} refunded` : ''}${Number(r.store_credit) > 0 ? ` · ${N2(r.store_credit)} kept as credit` : ''}`);
      onDone(); onClose();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  return (
    <Modal onClose={onClose} width={600}>
      <ModalHead title={`Credit note on ${sale.number}`} sub="For a price reduction, a discount agreed after the sale or a service not delivered. Nothing comes back into stock." onClose={onClose} />
      <div className="modal-body">
        <div className="row wrap" style={{ gap: 6 }}>
          <button className="pill on" type="button">Credit an amount</button>
          {(sale.lines || []).some((l) => l.kind === 'goods') && <button className="pill" type="button" onClick={onGoods}>Goods came back</button>}
        </div>
        {!info ? <Spinner /> : !lines.length ? <Alert kind="yellow" icon="info">Everything on {sale.number} has already been credited.</Alert> : <>
          <label className="check" style={{ fontSize: 13 }}><input type="checkbox" checked={byLine} onChange={(e) => setByLine(e.target.checked)} />Say how much comes off each line</label>
          {byLine ? lines.map((l) => (
            <div key={l.id} className="row" style={{ justifyContent: 'space-between', gap: 10 }}>
              <span className="grow ellipsis">{l.description}<span className="faint" style={{ fontSize: 12 }}> · up to {N2(l.creditable)}{Number(l.vat) > 0 ? ` (VAT ${(Number(l.vat_rate) * 100).toFixed(1)}%)` : ''}</span></span>
              <input className="input input-sm num" inputMode="decimal" style={{ width: 120 }} placeholder="0.00" value={amt[l.id] || ''} onChange={(e) => setAmt({ ...amt, [l.id]: e.target.value })} aria-label={`Credit on ${l.description}`} />
            </div>
          )) : (
            <Field label="Amount to credit, VAT included" hint={`Up to ${N2(pool)}. Shared over the lines in proportion to their value.`}>
              <input className="input num" inputMode="decimal" autoFocus value={whole} onChange={(e) => setWhole(e.target.value)} />
            </Field>
          )}
          <Field label="Reason" hint="Printed on the credit note."><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Price agreed lower, installation not done…" /></Field>
          <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: refund.method !== 'none' ? '1fr 1fr' : '1fr', gap: 10 }}>
            <Field label="What happens to it"><select className="input" value={refund.method} onChange={(e) => setRefund({ ...refund, method: e.target.value })}>
              <option value="none">Reduce what they owe, keep the rest as their credit</option><option value="cash">Refund in cash</option><option value="transfer">Refund by transfer</option></select></Field>
            {refund.method !== 'none' && <Field label="Refund amount" hint={over > 0 ? `${N2(over)} is more than they still owe.` : 'What they still owe is cleared first.'}>
              <input className="input num" inputMode="decimal" value={refund.amount} placeholder={over.toFixed(2)} onChange={(e) => setRefund({ ...refund, amount: e.target.value })} /></Field>}
          </div>
          {refund.method === 'transfer' && <Field label="Paid from"><select className="input" value={refund.bank_account_id} onChange={(e) => setRefund({ ...refund, bank_account_id: e.target.value })}>
            <option value="">Choose the account</option>{own.filter((a) => a.kind !== 'cash').map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}</select></Field>}
          <div className="row" style={{ justifyContent: 'space-between', background: '#FAFAFA', borderRadius: 10, padding: 10, fontSize: 13 }}>
            <span>Credit note {N2(total)}{vat > 0 ? <span className="faint"> · output VAT reduced by about {N2(vat)}</span> : null}</span>
            <span className="faint">{due > 0 ? `${N2(Math.min(due, total))} comes off what is owed` : 'Nothing is owed on it'}</span>
          </div>
        </>}
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" disabled={busy || total <= 0 || total > pool + 0.004 || reason.trim().length < 3 || (refund.method === 'transfer' && !refund.bank_account_id)} onClick={go}>Raise credit note</button></div>
    </Modal>
  );
}

function ReturnGoods({ sale, onClose, onDone, onAmount }: { sale: Sale; onClose: () => void; onDone: () => void; onAmount: () => void }) {
  const toast = useToast();
  const { orgId } = useSession();
  const [own, setOwn] = useState<any[]>([]);
  useEffect(() => { moneyAccounts(orgId!).then((accounts) => setOwn(accounts || [])).catch(() => {}); }, [orgId]);
  const [qty, setQty] = useState<Record<string, string>>({});
  const [restock, setRestock] = useState(true);
  const [reason, setReason] = useState('');
  const [refund, setRefund] = useState({ method: 'none', amount: '', bank_account_id: '' });
  const [busy, setBusy] = useState(false);
  const lines = (sale.lines || []).filter((l) => Number(l.qty) - Number(l.returned_qty) > 0);
  const value = lines.reduce((a, l) => a + (Number(qty[l.id]) || 0) / Number(l.qty) * Number(l.gross), 0);
  async function go() {
    setBusy(true);
    try {
      await rpc('return_sale', { p_sale: sale.id, p_lines: lines.filter((l) => Number(qty[l.id]) > 0).map((l) => ({ sale_line_id: l.id, qty: Number(qty[l.id]) })),
        p_refund: refund.method === 'none' ? {} : { method: refund.method, amount: money(refund.amount) ?? Math.max(0, value - Number(sale.balance)), bank_account_id: refund.bank_account_id || null },
        p_reason: reason, p_restock: restock });
      toast('Credit note raised'); onDone(); onClose();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  return (
    <Modal onClose={onClose} width={560}>
      <ModalHead title={`Return from ${sale.number}`} sub="Raises a credit note. It clears what the customer still owes first; anything over that is refunded or kept as their credit." onClose={onClose} />
      <div className="modal-body">
        <div className="row wrap" style={{ gap: 6 }}>
          <button className="pill" type="button" onClick={onAmount}>Credit an amount</button>
          <button className="pill on" type="button">Goods came back</button>
        </div>
        {lines.map((l) => (
          <div key={l.id} className="row" style={{ justifyContent: 'space-between', gap: 10 }}>
            <span className="grow ellipsis">{l.description}<span className="faint" style={{ fontSize: 12 }}> · {Number(l.qty) - Number(l.returned_qty)} {l.unit_label} can come back</span></span>
            <input className="input input-sm num" inputMode="decimal" style={{ width: 90 }} placeholder="0" value={qty[l.id] || ''} onChange={(e) => setQty({ ...qty, [l.id]: e.target.value })} aria-label={`Quantity of ${l.description} returned`} />
          </div>
        ))}
        <label className="check"><input type="checkbox" checked={restock} onChange={(e) => setRestock(e.target.checked)} />The goods go back on the shelf</label>
        <Field label="Reason"><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Damaged, wrong size, changed mind…" /></Field>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
          <Field label="Refund"><select className="input" value={refund.method} onChange={(e) => setRefund({ ...refund, method: e.target.value })}><option value="none">Keep as credit / reduce what they owe</option><option value="cash">Cash</option><option value="transfer">Bank transfer</option></select></Field>
          {refund.method !== 'none' && <Field label="Refund amount"><input className="input" inputMode="decimal" value={refund.amount} placeholder={Math.max(0, value - Number(sale.balance)).toFixed(2)} onChange={(e) => setRefund({ ...refund, amount: e.target.value })} /></Field>}
        </div>
        {refund.method === 'transfer' && <Field label="Paid from"><select className="input" value={refund.bank_account_id} onChange={(e) => setRefund({ ...refund, bank_account_id: e.target.value })}>
          <option value="">Choose the account</option>{own.filter((a) => a.kind !== 'cash').map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}</select></Field>}
        <div style={{ fontWeight: 600 }}>Credit note about {N2(value)}</div>
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={busy || value <= 0 || !reason.trim() || (refund.method === 'transfer' && !refund.bank_account_id)} onClick={go}>Raise credit note</button></div>
    </Modal>
  );
}

// ---------------------------------------------------------------- confirming payments
function PendingPayments({ rows }: { rows: any[] }) {
  const { data: inv } = useInventory();
  const toast = useToast();
  const qc = useQueryClient();
  const [bank, setBank] = useState<Record<string, string>>({});
  const [accounts, setAccounts] = useState<any[]>([]);
  const { orgId } = useSession();
  useEffect(() => { moneyAccounts(orgId!).then((accounts) => setAccounts((accounts || []).filter((a: any) => a.kind !== 'cash'))).catch(() => {}); }, [orgId]); // eslint-disable-line react-hooks/exhaustive-deps
  const canConfirm = can(inv, 'keep_books') || can(inv, 'approve_adjustments');
  async function decide(id: string, yes: boolean, fallback?: string) {
    try {
      await rpc('confirm_payment', { p_collection: id, p_bank_account: bank[id] || fallback || null, p_confirm: yes, p_note: yes ? null : 'Not in the bank' });
      toast(yes ? 'Payment confirmed' : 'Payment rejected');
      await Promise.all(['sales', 'sale', 'customers', 'inbox'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
    } catch (e) { toast((e as Error).message, 'err'); }
  }
  if (!rows.length) return <Empty>No payments are waiting. Transfers, POS and cheques recorded at the till or on invoices land here until someone checks the bank.</Empty>;
  return (
    <div className="card" style={{ overflow: 'hidden' }}>
      {!canConfirm && <div style={{ padding: '12px 20px 0' }}><Alert kind="blue" icon="info">Someone who keeps the books, or a manager, confirms these against the bank.</Alert></div>}
      {rows.map((p) => (
        <div key={p.id} className="tr" style={{ gridTemplateColumns: 'minmax(0,1.4fr) 140px minmax(200px,1fr) auto', gap: 12 }}>
          <span style={{ minWidth: 0 }}><b>{p.customer_name}</b><span className="faint" style={{ display: 'block', fontSize: 12 }}>{METHOD_LABEL[p.method] || p.method} · {p.number}{p.reference ? ` · ${p.reference}` : ''} · {when(p.received_at)}{p.created_by_name ? ` · by ${p.created_by_name}` : ''}</span>
            <span className="faint" style={{ display: 'block', fontSize: 12 }}>{(p.sales || []).map((x: any) => x.number).join(', ')}</span></span>
          <b className="num right">{N2(p.amount)}</b>
          <select className="input input-sm" value={bank[p.id] || p.bank_account_id || ''} onChange={(e) => setBank({ ...bank, [p.id]: e.target.value })} disabled={!canConfirm} aria-label="Account it landed in">
            <option value="">Which account did it land in?</option>{accounts.map((a) => <option key={a.id} value={a.id}>{a.name}{a.account_number ? ` · ${a.account_number.slice(-4)}` : ''}</option>)}
          </select>
          <span className="row" style={{ gap: 6 }}>
            <button className="btn btn-primary btn-xs" disabled={!canConfirm || !(bank[p.id] || p.bank_account_id)} onClick={() => decide(p.id, true, p.bank_account_id)}>It's in the bank</button>
            <button className="btn btn-ghost btn-xs" disabled={!canConfirm} onClick={() => decide(p.id, false)}>Not received</button>
          </span>
        </div>
      ))}
    </div>
  );
}

// ---------------------------------------------------------------- invoice and quote editor
interface ELine { key: string; item_id: string | null; description: string; qty: string; unit: 'selling' | 'purchase'; unit_price: string; discount: string; vat_treatment: string; revenue_account: string; pack: number; units: [string, string] }

export function DocEditor({ id, type, draft, onClose, onSaved }: { id?: string; type: 'invoice' | 'quote'; draft?: Drafts['invoice']; onClose: () => void; onSaved: (id: string) => void }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const existing = useSale(id || null);
  const customers = useCustomers();
  const chart = useChart();
  const [customer, setCustomer] = useState<Customer | null>(null);
  const [f, setF] = useState({ issue_date: today(), due_date: '', prices_include_vat: !!inv?.org.prices_include_vat, delivery_fee: '', notes: '', terms: inv?.org.invoice_note || '', reference: '', price_list_id: '' });
  const [lines, setLines] = useState<ELine[]>([]);
  const [busy, setBusy] = useState(false);
  const revenue = (chart.data?.accounts || []).filter((a: any) => !a.is_group && a.active && /^4/.test(a.code));
  useEffect(() => {
    const s = existing.data;
    if (!s || !inv) return;
    setF({ issue_date: s.issue_date, due_date: s.due_date || '', prices_include_vat: s.prices_include_vat, delivery_fee: s.delivery_fee ? String(s.delivery_fee) : '', notes: s.notes || '', terms: s.terms || '', reference: s.reference || '', price_list_id: '' });
    setLines((s.lines || []).filter((l) => l.kind !== 'delivery').map((l) => {
      const it = inv.items.find((i) => i.id === l.item_id);
      return { key: l.id, item_id: l.item_id, description: l.description, qty: String(Number(l.qty)), unit: it && Number((l as any).unit_factor) > 1 ? 'purchase' : 'selling',
        unit_price: String(Number(l.unit_price)), discount: Number(l.discount) ? String(Number(l.discount)) : '', vat_treatment: l.item_vat_treatment || l.vat_treatment, revenue_account: l.revenue_account || '',
        pack: it?.pack_size || 1, units: [it?.selling_unit || l.unit_label, it?.purchase_unit || l.unit_label] };
    }));
  }, [existing.data?.id]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (existing.data && customers.data) setCustomer(customers.data.customers.find((c) => c.id === existing.data!.customer_id) || null);
  }, [existing.data?.id, customers.data]); // eslint-disable-line react-hooks/exhaustive-deps
  // Martina's draft: the lines she matched to products, the rest as service lines, and the customer when the name fits one.
  const [unmatched, setUnmatched] = useState<string | null>(null);
  useEffect(() => {
    if (!draft || id || !inv) return;
    setLines(draft.lines.map((d) => {
      const it = d.item_id ? inv.items.find((i) => i.id === d.item_id) : undefined;
      return it
        ? { key: crypto.randomUUID(), item_id: it.id, description: it.name, qty: String(d.qty || 1), unit: 'selling', unit_price: String(d.unit_price ?? Number(it.price)), discount: '',
            vat_treatment: it.vat_treatment, revenue_account: '', pack: it.pack_size, units: [it.selling_unit, it.purchase_unit] }
        : { key: crypto.randomUUID(), item_id: null, description: d.name, qty: String(d.qty || 1), unit: 'selling', unit_price: d.unit_price != null ? String(d.unit_price) : '', discount: '',
            vat_treatment: 'standard', revenue_account: '', pack: 1, units: ['unit', 'unit'] };
    }));
    setF((x) => ({ ...x, notes: draft.note || x.notes, due_date: draft.due_in_days ? new Date(Date.now() + draft.due_in_days * 86400_000).toISOString().slice(0, 10) : x.due_date }));
  }, [draft, inv?.org.id]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (!draft?.customer || id || !customers.data) return;
    const n = draft.customer.trim().toLowerCase();
    const list = customers.data.customers.filter((c) => !c.archived && !c.is_walk_in);
    const hit = list.find((c) => c.name.toLowerCase() === n) || list.find((c) => c.name.toLowerCase().includes(n) || n.includes(c.name.toLowerCase()));
    if (hit) setCustomer(hit); else setUnmatched(draft.customer);
  }, [draft, customers.data]); // eslint-disable-line react-hooks/exhaustive-deps
  if (!inv) return null;
  const set = (k: string, v: any) => setF((x) => ({ ...x, [k]: v }));
  const upd = (k: string, patch: Partial<ELine>) => setLines((ls) => ls.map((l) => (l.key === k ? { ...l, ...patch } : l)));
  const gross = (l: ELine) => Math.max(0, (Number(l.qty) || 0) * (money(l.unit_price) || 0) - (money(l.discount) || 0));
  const sum = lines.reduce((a, l) => a + gross(l), 0) + (money(f.delivery_fee) || 0);
  // A customer outside Nigeria makes the sale an export: zero-rated, unless a manager has said otherwise on this document.
  const exp = existing.data && existing.data.customer_id === customer?.id ? !!existing.data.export : isExport(customer?.country);
  const vat = inv.org.vat_registered && !exp ? lines.reduce((a, l) => a + (l.vat_treatment === 'standard' ? (f.prices_include_vat ? gross(l) - gross(l) / 1.075 : gross(l) * 0.075) : 0), 0) : 0;
  const total = f.prices_include_vat ? sum : sum + vat;
  async function save(issue: boolean) {
    if (!customer) { toast('Choose the customer.', 'err'); return; }
    if (!lines.length) { toast('Add at least one line.', 'err'); return; }
    setBusy(true);
    try {
      const r = await rpc<Sale>('save_sale_doc', { p_org: orgId, p_doc: {
        id: id || null, doc_type: type, status: issue && type === 'invoice' ? 'issue' : 'draft', customer_id: customer.id, issue_date: f.issue_date, due_date: f.due_date || null,
        prices_include_vat: f.prices_include_vat, delivery_fee: money(f.delivery_fee) || 0, notes: f.notes || null, terms: f.terms || null, reference: f.reference || null,
        lines: lines.map((l) => l.item_id
          ? { item_id: l.item_id, qty: Number(l.qty), unit: l.unit, unit_price: money(l.unit_price), discount: money(l.discount) || 0 }
          : { description: l.description, qty: Number(l.qty), unit_price: money(l.unit_price), discount: money(l.discount) || 0, vat_treatment: l.vat_treatment, revenue_account: l.revenue_account || null }),
      } });
      toast(issue && type === 'invoice' ? `${r.number} issued` : `${r.number} saved`);
      await Promise.all(['sales', 'sale', 'customers'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
      onSaved(r.id);
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  return (
    <Drawer onClose={onClose} width={860}>
      <div className="drawer-hd"><div className="grow"><div className="drawer-title">{id ? `Edit ${existing.data?.number || ''}` : type === 'invoice' ? 'New invoice' : 'New quote'}</div>
        <div className="muted" style={{ fontSize: 13 }}>{type === 'invoice' ? 'Issuing posts it: revenue, output VAT and the stock.' : 'A quote changes nothing in the books until it becomes an invoice.'}</div></div>
        <button className="x-btn" onClick={onClose} aria-label="Close"><Icon name="x" size={18} /></button></div>
      <div className="drawer-body stack" style={{ gap: 14 }}>
        {draft && !id && <Alert kind="blue" icon="sparkles">Martina prepared this {type}. Check the {unmatched ? 'customer, ' : ''}lines and prices, then save it or issue it. Nothing is posted until you do.</Alert>}
        {unmatched && !customer && <Alert kind="amber" icon="info">No customer called "{unmatched}" yet. Choose one, or add them from the customer box.</Alert>}
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1.4fr 1fr 1fr', gap: 12 }}>
          <Field label="Customer" req hint={exp ? `Export${isExport(customer?.country) ? ` to ${countryName(customer?.country)}` : ''}: zero-rated for VAT.` : undefined}>
            <CustomerPicker value={customer} onChange={setCustomer} walkIn={false} placeholder="Choose the customer" /></Field>
          <Field label="Date"><input className="input" type="date" value={f.issue_date} onChange={(e) => set('issue_date', e.target.value)} /></Field>
          <Field label={type === 'quote' ? 'Valid until' : 'Due'} hint={customer?.terms_days ? `${customer.terms_days} days for this customer` : undefined}><input className="input" type="date" value={f.due_date} onChange={(e) => set('due_date', e.target.value)} /></Field>
        </div>
        <div className="card" style={{ overflow: 'visible' }}>
          <div className="tr head shade th hide-sm" style={{ gridTemplateColumns: 'minmax(180px,2fr) 80px 120px 100px 110px 110px 30px' }}>
            <span>Item or service</span><span className="right">Qty</span><span>Unit</span><span className="right">Price</span><span className="right">Discount</span><span className="right">Amount</span><span />
          </div>
          {lines.map((l) => (
            <div key={l.key} className="tr" style={{ gridTemplateColumns: 'minmax(180px,2fr) 80px 120px 100px 110px 110px 30px', alignItems: 'start' }}>
              <span className="stack" style={{ gap: 4 }}>
                {l.item_id ? <b>{l.description}</b> : <input className="input input-sm" value={l.description} placeholder="Service or charge" onChange={(e) => upd(l.key, { description: e.target.value })} />}
                {!l.item_id && <div className="row" style={{ gap: 4 }}>
                  <select className="input input-sm" value={l.vat_treatment} onChange={(e) => upd(l.key, { vat_treatment: e.target.value })} aria-label="VAT"><option value="standard">VAT 7.5%</option><option value="zero">Zero-rated</option><option value="exempt">Exempt</option></select>
                  <select className="input input-sm" value={l.revenue_account} onChange={(e) => upd(l.key, { revenue_account: e.target.value })} aria-label="Income account"><option value="">Usual income account</option>{revenue.map((a: any) => <option key={a.code} value={a.code}>{a.code} {a.name}</option>)}</select>
                </div>}
                {exp ? <span className="faint" style={{ fontSize: 11 }}>Zero-rated export · VAT 2{l.vat_treatment !== 'zero' ? ` (normally ${l.vat_treatment === 'exempt' ? 'exempt' : 'VATable'})` : ''}</span>
                  : l.item_id && l.vat_treatment !== 'standard' && <span className="faint" style={{ fontSize: 11 }}>{l.vat_treatment === 'zero' ? 'Zero-rated · VAT 2' : 'Exempt · VAT 1'}</span>}
              </span>
              <input className="input input-sm num" inputMode="decimal" value={l.qty} onChange={(e) => upd(l.key, { qty: e.target.value })} aria-label="Quantity" />
              {l.item_id && l.pack > 1 ? <select className="input input-sm" value={l.unit} onChange={(e) => {
                const u = e.target.value as 'selling' | 'purchase';
                const it = inv.items.find((i) => i.id === l.item_id)!;
                upd(l.key, { unit: u, unit_price: String(Number(it.price) * (u === 'purchase' ? it.pack_size : 1)) });
              }}><option value="selling">{l.units[0]}</option><option value="purchase">{l.units[1]} of {l.pack}</option></select> : <span className="muted" style={{ fontSize: 12, paddingTop: 8 }}>{l.units[0] || 'unit'}</span>}
              <input className="input input-sm num" inputMode="decimal" value={l.unit_price} onChange={(e) => upd(l.key, { unit_price: e.target.value })} aria-label="Price" />
              <input className="input input-sm num" inputMode="decimal" value={l.discount} placeholder="0" onChange={(e) => upd(l.key, { discount: e.target.value })} aria-label="Discount" />
              <span className="right num" style={{ paddingTop: 8 }}>{N2(gross(l))}</span>
              <button className="btn btn-ghost btn-xs" onClick={() => setLines((ls) => ls.filter((x) => x.key !== l.key))} aria-label="Remove line"><Icon name="trash" size={13} /></button>
            </div>
          ))}
          <div className="row wrap" style={{ padding: 12, gap: 8 }}>
            <div style={{ flex: '1 1 300px' }}><ItemPicker items={inv.items} onPick={(it) => setLines((ls) => [...ls, { key: crypto.randomUUID(), item_id: it.id, description: it.name, qty: '1', unit: 'selling', unit_price: String(Number(it.price)), discount: '', vat_treatment: it.vat_treatment, revenue_account: '', pack: it.pack_size, units: [it.selling_unit, it.purchase_unit] }])} /></div>
            <button className="btn btn-secondary btn-sm" onClick={() => setLines((ls) => [...ls, { key: crypto.randomUUID(), item_id: null, description: '', qty: '1', unit: 'selling', unit_price: '', discount: '', vat_treatment: 'standard', revenue_account: '', pack: 1, units: ['unit', 'unit'] }])}><Icon name="plus" size={13} />Service or charge</button>
          </div>
        </div>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 280px', gap: 16 }}>
          <div className="stack" style={{ gap: 10 }}>
            <label className="check"><input type="checkbox" checked={f.prices_include_vat} onChange={(e) => set('prices_include_vat', e.target.checked)} />Prices include VAT</label>
            <Field label="Delivery charge"><input className="input" inputMode="decimal" value={f.delivery_fee} onChange={(e) => set('delivery_fee', e.target.value)} placeholder="0.00" style={{ maxWidth: 180 }} /></Field>
            <Field label="Customer's reference (PO number)"><input className="input" value={f.reference} onChange={(e) => set('reference', e.target.value)} style={{ maxWidth: 260 }} /></Field>
            <Field label="Note to the customer"><textarea className="input" value={f.notes} onChange={(e) => set('notes', e.target.value)} /></Field>
            <Field label="Terms"><textarea className="input" value={f.terms} onChange={(e) => set('terms', e.target.value)} placeholder="Bank details, payment terms" /></Field>
          </div>
          <div className="stack" style={{ gap: 6, background: '#FAFAFA', borderRadius: 12, padding: 14, alignSelf: 'start' }}>
            <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">Lines</span><span className="num">{N2(sum - (money(f.delivery_fee) || 0))}</span></div>
            {!!money(f.delivery_fee) && <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">Delivery</span><span className="num">{N2(money(f.delivery_fee))}</span></div>}
            <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">VAT {f.prices_include_vat ? '(included)' : ''}</span><span className="num">{N2(vat)}</span></div>
            <div className="row" style={{ justifyContent: 'space-between', fontWeight: 700, fontSize: 18 }}><span>Total</span><span className="num">{N2(total)}</span></div>
            <div className="faint" style={{ fontSize: 11 }}>Final figures come from the books when you save.</div>
          </div>
        </div>
      </div>
      <div className="drawer-ft">
        <button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-secondary" disabled={busy} onClick={() => save(false)}>{type === 'quote' ? 'Save quote' : 'Save draft'}</button>
        {type === 'invoice' && <button className="btn btn-primary" disabled={busy} onClick={() => save(true)}>Issue invoice</button>}
      </div>
    </Drawer>
  );
}

export type { SaleRow };
