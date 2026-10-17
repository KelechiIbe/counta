// Bills: what the business owes suppliers. Entered by hand, from a stock receipt, or sent over from Prism. Approving one
// posts it (expense or stock, recoverable input VAT, payables); paying it from the wallet or the bank deducts withholding tax.
import { useEffect, useMemo, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { can, useInventory, useSession, useToast } from '../../state/session';
import { rpc } from '../../lib/supabase';
import { edge, money, today, useBill, useBills, useChart, type Bill } from '../../lib/api';
import { N2, fmtDay, when } from '../../lib/format';
import { Icon } from '../../components/Icon';
import { Alert, Drawer, Empty, Field, Modal, ModalHead, Pills, SkeletonRows, Spinner } from '../../components/ui';
import { ExportMenu, useMeta } from '../../components/Books';
import type { RCol } from '../../lib/reports';
import { StatusChip } from '../sell/common';

type Tab = 'all' | 'draft' | 'unpaid' | 'overdue' | 'paid';

export default function Bills() {
  const { data: inv } = useInventory();
  const [params, setParams] = useSearchParams();
  const [tab, setTab] = useState<Tab>('unpaid');
  const [q, setQ] = useState('');
  const [editing, setEditing] = useState<string | 'new' | null>(null);
  const bills = useBills({}, true);
  const meta = useMeta();
  const open = params.get('open');
  const rows = useMemo(() => (bills.data?.bills || []).filter((b) =>
    (tab === 'all' || (tab === 'draft' && b.status === 'draft') || (tab === 'unpaid' && ['approved', 'partially_paid'].includes(b.status))
      || (tab === 'overdue' && Number(b.overdue_days) > 0) || (tab === 'paid' && b.status === 'paid'))
    && (!q.trim() || `${b.number} ${b.vendor_name} ${b.vendor_ref || ''}`.toLowerCase().includes(q.trim().toLowerCase()))), [bills.data, tab, q]);
  if (!inv) return null;
  const all = bills.data?.bills || [];
  const owed = all.filter((b) => ['approved', 'partially_paid'].includes(b.status)).reduce((a, b) => a + Number(b.balance), 0);
  const overdue = all.filter((b) => Number(b.overdue_days) > 0).reduce((a, b) => a + Number(b.balance), 0);
  const cols: RCol[] = [{ key: 'number', label: 'Bill' }, { key: 'vendor_name', label: 'Vendor' }, { key: 'vendor_ref', label: 'Their invoice' }, { key: 'bill_date', label: 'Date', type: 'date' },
    { key: 'due_date', label: 'Due', type: 'date' }, { key: 'status', label: 'Status' }, { key: 'subtotal', label: 'Before VAT', type: 'money', total: true }, { key: 'vat_total', label: 'VAT', type: 'money', total: true },
    { key: 'total', label: 'Total', type: 'money', total: true }, { key: 'wht_expected', label: 'WHT', type: 'money', total: true }, { key: 'balance', label: 'Balance', type: 'money', total: true }];
  return (
    <div className="container">
      <div className="m-2" style={{ display: 'grid', gridTemplateColumns: 'repeat(3,minmax(0,1fr))', gap: 12 }}>
        <div className="card card-pad"><div className="label">We owe suppliers</div><div style={{ fontSize: 26, fontWeight: 700, marginTop: 6 }}>{N2(owed)}</div></div>
        <div className="card card-pad"><div className="label">Overdue</div><div style={{ fontSize: 26, fontWeight: 700, marginTop: 6, color: overdue ? '#DC2626' : undefined }}>{N2(overdue)}</div></div>
        <div className="card card-pad"><div className="label">To approve</div><div style={{ fontSize: 26, fontWeight: 700, marginTop: 6 }}>{all.filter((b) => b.status === 'draft').length}</div></div>
      </div>
      <div className="row wrap" style={{ justifyContent: 'space-between' }}>
        <Pills value={tab} onChange={setTab} options={[{ id: 'unpaid', label: 'To pay' }, { id: 'draft', label: 'To approve', count: all.filter((b) => b.status === 'draft').length || undefined }, { id: 'overdue', label: 'Overdue' }, { id: 'paid', label: 'Paid' }, { id: 'all', label: 'All' }]} />
        <div className="row wrap">
          <ExportMenu name={`${inv.org.name} bills ${today()}`} disabled={!rows.length} sheets={() => [{ meta: meta('Bills', `As at ${fmtDay(today())}`), cols, rows: rows as any }]} />
          {(can(inv, 'keep_books') || can(inv, 'approve_pos')) && <button className="btn btn-primary btn-sm" onClick={() => setEditing('new')}><Icon name="plus" size={14} color="#fff" />Bill</button>}
        </div>
      </div>
      <div className="card" style={{ overflow: 'hidden' }}>
        <div className="card-hd"><div className="row" style={{ flex: 1 }}><Icon name="search" size={15} color="#9CA3AF" /><input className="input input-sm" style={{ border: 0, boxShadow: 'none' }} placeholder="Bill, vendor or their invoice number" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search bills" /></div></div>
        <div className="tbl">
          <div className="tr head shade th hide-sm" style={{ gridTemplateColumns: '110px minmax(160px,1.4fr) 110px 120px 120px 120px 120px', minWidth: 900 }}>
            <span>Bill</span><span>Vendor</span><span>Date</span><span>Status</span><span className="right">Total</span><span className="right">To pay</span><span>Due</span>
          </div>
          {bills.isLoading ? <SkeletonRows n={6} /> : bills.error ? <div style={{ padding: 20 }}><Alert kind="yellow" icon="shield">{(bills.error as Error).message}</Alert></div> : !rows.length ? <div style={{ padding: 20 }}><Empty>No bills here.</Empty></div> : rows.map((b) => (
            <div key={b.id} className="tr click" onClick={() => setParams({ open: b.id })} style={{ gridTemplateColumns: '110px minmax(160px,1.4fr) 110px 120px 120px 120px 120px', minWidth: 900 }}>
              <span><b>{b.number}</b><span className="faint" style={{ display: 'block', fontSize: 11 }}>{b.source === 'receipt' ? 'from stock' : b.source === 'prism' ? 'from Prism' : b.source === 'ai' ? 'read by AI' : ''}</span></span>
              <span className="ellipsis">{b.vendor_name}{b.vendor_ref ? <span className="faint" style={{ fontSize: 12 }}> · {b.vendor_ref}</span> : null}</span>
              <span className="muted">{fmtDay(b.bill_date)}</span>
              <span><StatusChip s={b.status} />{Number(b.in_progress) > 0 && <span className="chip t-amber" style={{ marginLeft: 4 }}>paying</span>}</span>
              <span className="right num">{N2(b.total)}</span>
              <span className="right num" style={{ color: Number(b.balance) ? '#C2410C' : undefined }}>{Number(b.balance) ? N2(b.balance) : '—'}</span>
              <span className="muted" style={{ fontSize: 12, color: Number(b.overdue_days) ? '#DC2626' : undefined }}>{Number(b.overdue_days) ? `${b.overdue_days} days late` : fmtDay(b.due_date)}</span>
            </div>
          ))}
        </div>
      </div>
      {open && <BillDrawer id={open} onClose={() => setParams({})} onEdit={(id) => setEditing(id)} />}
      {editing && <BillEditor id={editing === 'new' ? null : editing} vendors={bills.data?.vendors || []} whtRates={bills.data?.wht_rates || []} assetClasses={bills.data?.asset_classes || []}
        onClose={() => setEditing(null)} onSaved={(id) => { setEditing(null); setParams({ open: id }); }} />}
    </div>
  );
}

function BillDrawer({ id, onClose, onEdit }: { id: string; onClose: () => void; onEdit: (id: string) => void }) {
  const { data: inv } = useInventory();
  const bill = useBill(id);
  const toast = useToast();
  const qc = useQueryClient();
  const [pay, setPay] = useState(false);
  const [voiding, setVoiding] = useState(false);
  const [reason, setReason] = useState('');
  const b = bill.data;
  const refresh = () => Promise.all(['bill', 'bills', 'inbox', 'payments', 'assets'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
  async function act(fn: () => Promise<any>, ok: string) {
    try { await fn(); toast(ok); await refresh(); } catch (e) { toast((e as Error).message, 'err'); }
  }
  return (
    <Drawer onClose={onClose} width={640}>
      <div className="drawer-hd"><div className="grow">
        <div className="row" style={{ gap: 8 }}><div className="drawer-title">{b ? `${b.number} · ${b.vendor?.name || ''}` : 'Loading…'}</div>{b && <StatusChip s={b.status} />}</div>
        {b && <div className="muted" style={{ fontSize: 13 }}>{b.vendor_ref ? `Their invoice ${b.vendor_ref} · ` : ''}{fmtDay(b.bill_date)} · due {fmtDay(b.due_date)}{b.journal_ref ? ` · ${b.journal_ref}` : ''}</div>}
      </div><button className="x-btn" onClick={onClose} aria-label="Close"><Icon name="x" size={18} /></button></div>
      <div className="drawer-body stack" style={{ gap: 14 }}>
        {!b ? <Spinner /> : (
          <>
            {b.status === 'draft' && <Alert kind="grey" icon="pencil">{b.source === 'prism' ? 'Sent from Prism. ' : b.source === 'ai' ? 'Read by AI. ' : ''}Check it and approve it to put it in the books.</Alert>}
            <div className="card" style={{ overflow: 'hidden', borderRadius: 12 }}>
              {(b.lines || []).map((l: any) => (
                <div key={l.id} className="tr" style={{ gridTemplateColumns: 'minmax(0,1fr) 120px', padding: '9px 14px' }}>
                  <span style={{ minWidth: 0 }}>{l.description}<span className="faint" style={{ display: 'block', fontSize: 12 }}>{l.account_code} {l.account_name} · {Number(l.qty)} × {N2(l.unit_cost)}{l.vat_treatment === 'standard' ? ` · VAT ${N2(l.vat)}${l.vat_recoverable ? '' : ' (not recoverable)'}` : l.vat_treatment === 'none' ? '' : ` · ${l.vat_treatment}`}</span></span>
                  <span className="right num">{N2(l.gross)}</span>
                </div>
              ))}
              <div className="stack" style={{ padding: '10px 14px', gap: 4, borderTop: '1px solid #F3F4F6', fontSize: 13 }}>
                <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">Before VAT</span><span className="num">{N2(b.subtotal)}</span></div>
                <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">VAT</span><span className="num">{N2(b.vat_total)}</span></div>
                <div className="row" style={{ justifyContent: 'space-between', fontWeight: 700 }}><span>Total</span><span className="num">{N2(b.total)}</span></div>
                <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">Withholding tax ({(Number(b.wht_rate) * 100).toFixed(1)}%, {b.wht_category})</span><span className="num">{N2(b.wht_expected)}</span></div>
                {Number(b.amount_paid) > 0 && <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">Paid</span><span className="num">{N2(b.amount_paid)}</span></div>}
                {Number(b.balance) > 0 && <div className="row" style={{ justifyContent: 'space-between', color: '#C2410C', fontWeight: 600 }}><span>Still owed</span><span className="num">{N2(b.balance)}</span></div>}
              </div>
            </div>
            {(b.payments || []).length > 0 && <div className="stack" style={{ gap: 4 }}><div className="label">Payments</div>{b.payments.map((p: any) => (
              <div key={p.id} className="row" style={{ justifyContent: 'space-between', fontSize: 13 }}><span>{p.method === 'wallet' ? 'From the wallet' : p.method === 'bank' ? 'From the bank' : p.method} · {when(p.paid_at)}{p.reference ? ` · ${p.reference}` : ''}</span>
                <span className="row" style={{ gap: 6 }}><StatusChip s={p.status} /><span className="num">{N2(p.net)} + WHT {N2(p.wht)}</span></span></div>
            ))}</div>}
            {(b.assets || []).length > 0 && <Alert kind="blue" icon="info">{b.assets.length} fixed asset{b.assets.length === 1 ? '' : 's'} from this bill wait in Fixed assets to be confirmed.</Alert>}
            <div className="row wrap">
              {b.status === 'draft' && <button className="btn btn-secondary btn-sm" onClick={() => onEdit(b.id)}><Icon name="pencil" size={14} />Edit</button>}
              {b.status === 'draft' && can(inv, 'keep_books') && <button className="btn btn-primary btn-sm" onClick={() => act(() => rpc('approve_bill', { p_bill: b.id }), `${b.number} approved and in the books`)}>Approve</button>}
              {['approved', 'partially_paid'].includes(b.status) && can(inv, 'make_payments') && <button className="btn btn-primary btn-sm" onClick={() => setPay(true)}><Icon name="send" size={14} color="#fff" />Pay</button>}
              {['draft', 'approved'].includes(b.status) && can(inv, 'keep_books') && <button className="btn btn-ghost btn-sm" onClick={() => setVoiding(true)}>Void</button>}
            </div>
            {voiding && <div className="row"><input className="input input-sm" autoFocus placeholder="Why is it voided?" value={reason} onChange={(e) => setReason(e.target.value)} />
              <button className="btn btn-danger btn-sm" disabled={reason.trim().length < 3} onClick={() => act(() => rpc('void_bill', { p_bill: b.id, p_reason: reason }), 'Bill voided')}>Void</button></div>}
          </>
        )}
      </div>
      {pay && b && <PayBill bill={b} onClose={() => setPay(false)} onDone={refresh} />}
    </Drawer>
  );
}

function PayBill({ bill, onClose, onDone }: { bill: any; onClose: () => void; onDone: () => void }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const v = bill.vendor || {};
  const due = Number(bill.balance) - Number(bill.in_progress || 0);
  const [f, setF] = useState({ method: 'wallet', amount: String(due.toFixed(2)), bank_account_id: '', reference: '', bank_code: v.bank_code || '', account_number: v.account_number || '', account_name: v.account_name || '', narration: `${bill.number}${bill.vendor_ref ? ' ' + bill.vendor_ref : ''}` });
  const [banks, setBanks] = useState<{ code: string; name: string }[]>([]);
  const [own, setOwn] = useState<any[]>([]);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    edge<{ banks: any[] }>('payments', { action: 'banks' }).then((r) => setBanks(r.banks || []));
    rpc<any>('get_till', { p_org: orgId, p_location: inv?.locations[0]?.id }).then((t) => setOwn(t.accounts || [])).catch(() => {});
  }, [orgId]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (f.method !== 'wallet' || !/^\d{10}$/.test(f.account_number) || !f.bank_code || f.account_name) return;
    edge<{ account_name: string }>('payments', { action: 'resolve_account', account_number: f.account_number, bank_code: f.bank_code }).then((r) => r.account_name && setF((x) => ({ ...x, account_name: r.account_name })));
  }, [f.account_number, f.bank_code, f.method]); // eslint-disable-line react-hooks/exhaustive-deps
  const gross = money(f.amount) || 0;
  const wht = gross >= due - 0.004 ? Number(bill.wht_expected) - Number(bill.wht_withheld || 0) : Number(bill.wht_expected) * gross / Number(bill.total || 1);
  async function go() {
    setBusy(true);
    try {
      const r = await rpc<any>('pay_bill', { p_bill: bill.id, p: { method: f.method, amount: gross, bank_account_id: f.bank_account_id || null, reference: f.reference || null,
        bank_code: f.bank_code || null, bank_name: banks.find((b) => b.code === f.bank_code)?.name || null, account_number: f.account_number || null, account_name: f.account_name || null,
        narration: f.narration, client_uuid: crypto.randomUUID() } });
      if (f.method === 'wallet' && r?.payout?.status === 'approved') {
        const s = await edge('payments', { action: 'send_payout', payout_id: r.payout.id });
        toast(s.ok === false ? `Saved; not sent yet: ${s.error}` : 'Sent from the wallet. The bill clears when the bank confirms.', s.ok === false ? 'err' : undefined);
      } else toast(f.method === 'wallet' ? 'Waiting for a second person to approve the payout' : 'Payment recorded');
      onDone(); onClose();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  return (
    <Modal onClose={onClose} width={520}>
      <ModalHead title={`Pay ${bill.vendor?.name}`} sub={`${bill.number} · ${N2(due)} owed`} onClose={onClose} />
      <div className="modal-body">
        <Field label="Pay from"><select className="input" value={f.method} onChange={(e) => setF({ ...f, method: e.target.value })}><option value="wallet">The business wallet (sent now)</option><option value="bank">Our bank (already paid)</option><option value="cash">Cash</option></select></Field>
        <Field label="Amount of the bill this settles"><input className="input" inputMode="decimal" value={f.amount} onChange={(e) => setF({ ...f, amount: e.target.value })} /></Field>
        <div className="row" style={{ justifyContent: 'space-between', background: '#FAFAFA', borderRadius: 10, padding: 10, fontSize: 13 }}>
          <span>Withholding tax kept back <span className="faint">(pay to NRS by the 21st)</span></span><b className="num">{N2(wht)}</b>
        </div>
        <div className="row" style={{ justifyContent: 'space-between', fontWeight: 700 }}><span>The supplier receives</span><span className="num">{N2(gross - wht)}</span></div>
        {f.method === 'wallet' ? (
          <>
            <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
              <Field label="Bank"><select className="input" value={f.bank_code} onChange={(e) => setF({ ...f, bank_code: e.target.value, account_name: '' })}><option value="">Choose</option>{banks.map((b) => <option key={b.code} value={b.code}>{b.name}</option>)}</select></Field>
              <Field label="Account number"><input className="input" inputMode="numeric" maxLength={10} value={f.account_number} onChange={(e) => setF({ ...f, account_number: e.target.value.replace(/\D/g, ''), account_name: '' })} /></Field>
            </div>
            <Field label="Account name" hint="Confirmed by the bank."><input className="input" value={f.account_name} onChange={(e) => setF({ ...f, account_name: e.target.value })} /></Field>
            <Field label="Narration"><input className="input" maxLength={80} value={f.narration} onChange={(e) => setF({ ...f, narration: e.target.value })} /></Field>
          </>
        ) : (
          <>
            <Field label={f.method === 'cash' ? 'From which drawer' : 'From which account'}><select className="input" value={f.bank_account_id} onChange={(e) => setF({ ...f, bank_account_id: e.target.value })}><option value="">Choose</option>{own.filter((a) => (f.method === 'cash' ? a.kind === 'cash' : a.kind !== 'cash')).map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}</select></Field>
            <Field label="Reference"><input className="input" value={f.reference} onChange={(e) => setF({ ...f, reference: e.target.value })} /></Field>
          </>
        )}
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={busy || gross <= 0 || (f.method === 'wallet' ? !f.account_name || !f.bank_code : !f.bank_account_id)} onClick={go}>{f.method === 'wallet' ? `Send ${N2(gross - wht)}` : 'Record payment'}</button></div>
    </Modal>
  );
}

interface BLine { key: string; description: string; account_code: string; qty: string; unit_cost: string; vat_treatment: string; vat_recoverable: boolean; asset_life_months: string }

function BillEditor({ id, vendors, whtRates, assetClasses, onClose, onSaved }: { id: string | null; vendors: any[]; whtRates: any[]; assetClasses: any[]; onClose: () => void; onSaved: (id: string) => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const existing = useBill(id);
  const chart = useChart();
  const [vendor, setVendor] = useState({ id: '', name: '', tin: '' });
  const [f, setF] = useState({ vendor_ref: '', bill_date: today(), due_date: '', vat_charged: true, prices_include_vat: false, wht_category: '', notes: '' });
  const [lines, setLines] = useState<BLine[]>([{ key: crypto.randomUUID(), description: '', account_code: '', qty: '1', unit_cost: '', vat_treatment: 'standard', vat_recoverable: true, asset_life_months: '' }]);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    const b = existing.data;
    if (!b) return;
    setVendor({ id: b.vendor_id, name: b.vendor?.name || '', tin: b.vendor?.tin || '' });
    setF({ vendor_ref: b.vendor_ref || '', bill_date: b.bill_date, due_date: b.due_date || '', vat_charged: b.vat_charged, prices_include_vat: b.prices_include_vat, wht_category: b.wht_category || '', notes: b.notes || '' });
    setLines((b.lines || []).map((l: any) => ({ key: l.id, description: l.description, account_code: l.account_code, qty: String(Number(l.qty)), unit_cost: String(Number(l.unit_cost)),
      vat_treatment: l.vat_treatment === 'none' ? 'standard' : l.vat_treatment, vat_recoverable: l.vat_recoverable, asset_life_months: l.asset_life_months ? String(l.asset_life_months) : '' })));
  }, [existing.data?.id]); // eslint-disable-line react-hooks/exhaustive-deps
  const accounts = (chart.data?.accounts || []).filter((a: any) => !a.is_group && a.active && (/^[56]/.test(a.code) || /^(120[1-6]|15[0-2]|160)/.test(a.code)));
  const assetCodes = new Set(assetClasses.map((c) => c.cost_account));
  const upd = (k: string, p: Partial<BLine>) => setLines((ls) => ls.map((l) => (l.key === k ? { ...l, ...p } : l)));
  const net = lines.reduce((a, l) => a + (Number(l.qty) || 0) * (money(l.unit_cost) || 0), 0);
  async function save() {
    setBusy(true);
    try {
      const r = await rpc<any>('save_bill', { p_org: orgId, p_bill: { id: id || null, vendor_id: vendor.id || null, vendor: vendor.id ? undefined : { name: vendor.name, tin: vendor.tin || null },
        ...f, due_date: f.due_date || null, wht_category: f.wht_category || null,
        lines: lines.filter((l) => l.description || l.unit_cost).map((l) => ({ description: l.description, account_code: l.account_code, qty: Number(l.qty) || 1, unit_cost: money(l.unit_cost),
          vat_treatment: l.vat_treatment, vat_recoverable: l.vat_recoverable, asset_life_months: assetCodes.has(l.account_code) ? Number(l.asset_life_months) || null : null })) } });
      toast('Bill saved'); await qc.invalidateQueries({ queryKey: ['bills'] }); await qc.invalidateQueries({ queryKey: ['bill'] });
      onSaved(r?.id || id!);
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  return (
    <Drawer onClose={onClose} width={860}>
      <div className="drawer-hd"><div className="grow"><div className="drawer-title">{id ? `Edit ${existing.data?.number || ''}` : 'New bill'}</div><div className="muted" style={{ fontSize: 13 }}>Stock you received is billed from Receive stock; this is for everything else.</div></div>
        <button className="x-btn" onClick={onClose} aria-label="Close"><Icon name="x" size={18} /></button></div>
      <div className="drawer-body stack" style={{ gap: 14 }}>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1.4fr 1fr 1fr', gap: 12 }}>
          <Field label="Vendor" req>
            <input className="input" list="bill-vendors" value={vendor.name} onChange={(e) => { const v = vendors.find((x) => x.name === e.target.value); setVendor(v ? { id: v.id, name: v.name, tin: v.tin || '' } : { id: '', name: e.target.value, tin: vendor.tin }); if (v?.wht_category) setF((x) => ({ ...x, wht_category: v.wht_category })); }} placeholder="Type or pick" />
            <datalist id="bill-vendors">{vendors.map((v) => <option key={v.id} value={v.name} />)}</datalist>
          </Field>
          <Field label="Their invoice number"><input className="input" value={f.vendor_ref} onChange={(e) => setF({ ...f, vendor_ref: e.target.value })} /></Field>
          {!vendor.id ? <Field label="Vendor TIN" hint="Without a TIN the WHT rate doubles."><input className="input" value={vendor.tin} onChange={(e) => setVendor({ ...vendor, tin: e.target.value })} /></Field> : <span />}
        </div>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1.4fr', gap: 12 }}>
          <Field label="Bill date"><input className="input" type="date" value={f.bill_date} onChange={(e) => setF({ ...f, bill_date: e.target.value })} /></Field>
          <Field label="Due"><input className="input" type="date" value={f.due_date} onChange={(e) => setF({ ...f, due_date: e.target.value })} /></Field>
          <Field label="Withholding tax"><select className="input" value={f.wht_category} onChange={(e) => setF({ ...f, wht_category: e.target.value })}><option value="">The vendor's usual</option>{whtRates.map((w) => <option key={w.code} value={w.code}>{w.name} · {(Number(w.rate_company) * 100).toFixed(0)}%</option>)}</select></Field>
        </div>
        <div className="row wrap" style={{ gap: 16 }}>
          <label className="check"><input type="checkbox" checked={f.vat_charged} onChange={(e) => setF({ ...f, vat_charged: e.target.checked })} />The vendor charged VAT</label>
          {f.vat_charged && <label className="check"><input type="checkbox" checked={f.prices_include_vat} onChange={(e) => setF({ ...f, prices_include_vat: e.target.checked })} />Amounts include VAT</label>}
        </div>
        <div className="card" style={{ overflow: 'hidden' }}>
          <div className="tr head shade th hide-sm" style={{ gridTemplateColumns: 'minmax(160px,1.5fr) minmax(180px,1.4fr) 70px 120px 120px 30px' }}><span>Description</span><span>Account</span><span className="right">Qty</span><span className="right">Unit cost</span><span>VAT</span><span /></div>
          {lines.map((l) => (
            <div key={l.key} className="tr" style={{ gridTemplateColumns: 'minmax(160px,1.5fr) minmax(180px,1.4fr) 70px 120px 120px 30px', alignItems: 'start' }}>
              <input className="input input-sm" value={l.description} onChange={(e) => upd(l.key, { description: e.target.value })} placeholder="What it was for" />
              <span className="stack" style={{ gap: 4 }}>
                <select className="input input-sm" value={l.account_code} onChange={(e) => upd(l.key, { account_code: e.target.value })}><option value="">Choose the account</option>{accounts.map((a: any) => <option key={a.code} value={a.code}>{a.code} {a.name}</option>)}</select>
                {assetCodes.has(l.account_code) && <input className="input input-sm" inputMode="numeric" placeholder={`Useful life in months (default ${assetClasses.find((c) => c.cost_account === l.account_code)?.default_life_months || '—'})`} value={l.asset_life_months} onChange={(e) => upd(l.key, { asset_life_months: e.target.value })} />}
              </span>
              <input className="input input-sm num" inputMode="decimal" value={l.qty} onChange={(e) => upd(l.key, { qty: e.target.value })} aria-label="Quantity" />
              <input className="input input-sm num" inputMode="decimal" value={l.unit_cost} onChange={(e) => upd(l.key, { unit_cost: e.target.value })} aria-label="Unit cost" />
              <span className="stack" style={{ gap: 4 }}>
                <select className="input input-sm" disabled={!f.vat_charged} value={l.vat_treatment} onChange={(e) => upd(l.key, { vat_treatment: e.target.value })}><option value="standard">7.5%</option><option value="zero">Zero-rated</option><option value="exempt">Exempt</option></select>
                {f.vat_charged && l.vat_treatment === 'standard' && <label className="check" style={{ fontSize: 11 }}><input type="checkbox" checked={l.vat_recoverable} onChange={(e) => upd(l.key, { vat_recoverable: e.target.checked })} />Claim back</label>}
              </span>
              <button className="btn btn-ghost btn-xs" onClick={() => setLines((ls) => ls.filter((x) => x.key !== l.key))} aria-label="Remove line"><Icon name="trash" size={13} /></button>
            </div>
          ))}
          <div style={{ padding: 12 }}><button className="btn btn-secondary btn-sm" onClick={() => setLines((ls) => [...ls, { key: crypto.randomUUID(), description: '', account_code: '', qty: '1', unit_cost: '', vat_treatment: 'standard', vat_recoverable: true, asset_life_months: '' }])}><Icon name="plus" size={13} />Line</button></div>
        </div>
        <div className="row" style={{ justifyContent: 'flex-end', fontWeight: 600 }}>Lines {N2(net)}{f.vat_charged && !f.prices_include_vat ? ' + VAT' : ''}</div>
        <Field label="Notes"><input className="input" value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} /></Field>
        <Alert kind="grey" icon="info">Items bought for the business above the capitalisation threshold and coded to an asset account become fixed assets once you confirm them.</Alert>
      </div>
      <div className="drawer-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={busy || !vendor.name.trim() || !lines.some((l) => l.account_code && money(l.unit_cost))} onClick={save}>Save draft</button></div>
    </Drawer>
  );
}

export type { Bill };
