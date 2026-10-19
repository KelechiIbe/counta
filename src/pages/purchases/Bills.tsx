// Bills: what the business owes suppliers. Entered by hand, from a stock receipt, or sent over from Prism. Approving one
// posts it (expense or stock, recoverable input VAT, payables); paying it from the wallet or the bank deducts withholding tax.
import { useEffect, useMemo, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { can, useInventory, useSession, useToast } from '../../state/session';
import { rpc } from '../../lib/supabase';
import { edge, money, today, useBill, useBills, useChart, type Bill, moneyAccounts } from '../../lib/api';
import { N2, fmtDay, when } from '../../lib/format';
import { Icon } from '../../components/Icon';
import { Alert, Drawer, Empty, Field, Modal, ModalHead, Pills, SkeletonRows, Spinner } from '../../components/ui';
import { taxIdError } from '../../lib/taxid';
import { ExportMenu, useMeta } from '../../components/Books';
import type { RCol } from '../../lib/reports';
import { StatusChip } from '../sell/common';
import { authorityLabel, pct, useTaxProfile } from '../../lib/tax';
import { CreditsList, UseCredits, VendorCreditModal } from './VendorCredits';
import { useDraft, type Drafts } from '../../lib/drafts';
import { vatPct } from '../../lib/vat';

type Tab = 'all' | 'draft' | 'unpaid' | 'overdue' | 'paid' | 'credits' | 'returned';

export default function Bills() {
  const { data: inv } = useInventory();
  const [params, setParams] = useSearchParams();
  const [tab, setTab] = useState<Tab>('unpaid');
  const [q, setQ] = useState('');
  const [editing, setEditing] = useState<string | 'new' | null>(null);
  // A bill Martina prepared opens in the editor for the person to check and save.
  const draft = useDraft('bill');
  const [billDraft, setBillDraft] = useState<Drafts['bill'] | null>(null);
  useEffect(() => { if (draft) { setBillDraft(draft); setEditing('new'); } }, [draft]);
  const bills = useBills({}, true);
  const meta = useMeta();
  const open = params.get('open');
  const rows = useMemo(() => (bills.data?.bills || []).filter((b) =>
    (tab === 'all' || (tab === 'draft' && b.status === 'draft') || (tab === 'unpaid' && ['approved', 'partially_paid'].includes(b.status))
      || (tab === 'overdue' && Number(b.overdue_days) > 0) || (tab === 'paid' && b.status === 'paid') || (tab === 'returned' && !!(b as any).returned_reason))
    && (!q.trim() || `${b.number} ${b.vendor_name} ${b.vendor_ref || ''}`.toLowerCase().includes(q.trim().toLowerCase()))), [bills.data, tab, q]);
  if (!inv) return null;
  const all = bills.data?.bills || [];
  const owed = all.filter((b) => ['approved', 'partially_paid'].includes(b.status)).reduce((a, b) => a + Number(b.balance), 0);
  const overdue = all.filter((b) => Number(b.overdue_days) > 0).reduce((a, b) => a + Number(b.balance), 0);
  const returned = all.filter((b) => (b as any).returned_reason).length;
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
        <Pills value={tab} onChange={setTab} options={[{ id: 'unpaid', label: 'To pay' }, { id: 'draft', label: 'To approve', count: all.filter((b) => b.status === 'draft').length || undefined }, { id: 'overdue', label: 'Overdue' }, { id: 'paid', label: 'Paid' },
          ...(returned || tab === 'returned' ? [{ id: 'returned' as Tab, label: 'Sent back', count: returned || undefined }] : []), { id: 'all', label: 'All' }, { id: 'credits', label: 'Credit notes' }]} />
        <div className="row wrap">
          <ExportMenu name={`${inv.org.name} bills ${today()}`} disabled={!rows.length} sheets={() => [{ meta: meta('Bills', `As at ${fmtDay(today())}`), cols, rows: rows as any }]} />
          {(can(inv, 'keep_books') || can(inv, 'approve_pos')) && <button className="btn btn-primary btn-sm" onClick={() => setEditing('new')}><Icon name="plus" size={14} color="#fff" />Bill</button>}
        </div>
      </div>
      {tab === 'credits' ? <CreditsList /> : <div className="card" style={{ overflow: 'hidden' }}>
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
              <span><StatusChip s={(b as any).returned_reason ? 'returned' : b.status} />{Number(b.in_progress) > 0 && <span className="chip t-amber" style={{ marginLeft: 4 }}>paying</span>}</span>
              <span className="right num">{N2(b.total)}</span>
              <span className="right num" style={{ color: Number(b.balance) ? '#C2410C' : undefined }}>{Number(b.balance) ? N2(b.balance) : '—'}</span>
              <span className="muted" style={{ fontSize: 12, color: Number(b.overdue_days) ? '#DC2626' : undefined }}>{Number(b.overdue_days) ? `${b.overdue_days} days late` : fmtDay(b.due_date)}</span>
            </div>
          ))}
        </div>
      </div>}
      {open && <BillDrawer id={open} whtRates={bills.data?.wht_rates || []} onClose={() => setParams({})} onEdit={(id) => setEditing(id)} />}
      {editing && <BillEditor id={editing === 'new' ? null : editing} draft={editing === 'new' ? billDraft : null} vendors={bills.data?.vendors || []} whtRates={bills.data?.wht_rates || []} assetClasses={bills.data?.asset_classes || []}
        onClose={() => { setEditing(null); setBillDraft(null); }} onSaved={(id) => { setEditing(null); setBillDraft(null); setParams({ open: id }); }} />}
    </div>
  );
}

function BillDrawer({ id, whtRates, onClose, onEdit }: { id: string; whtRates: any[]; onClose: () => void; onEdit: (id: string) => void }) {
  const { data: inv } = useInventory();
  const bill = useBill(id);
  const toast = useToast();
  const qc = useQueryClient();
  const [pay, setPay] = useState(false);
  const [voiding, setVoiding] = useState(false);
  const [crediting, setCrediting] = useState(false);
  const [sendBack, setSendBack] = useState<string | null>(null);
  const [noTin, setNoTin] = useState(false);
  const [reason, setReason] = useState('');
  const b = bill.data;
  const flags = b?.tax_flags || {};
  const refresh = () => Promise.all(['bill', 'bills', 'inbox', 'payments', 'assets'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
  async function act(fn: () => Promise<any>, ok: string) {
    try { await fn(); toast(ok); await refresh(); } catch (e) { toast((e as Error).message, 'err'); }
  }
  return (
    <Drawer onClose={onClose} width={640}>
      <div className="drawer-hd"><div className="grow">
        <div className="row" style={{ gap: 8 }}><div className="drawer-title">{b ? `${b.number} · ${b.vendor?.name || ''}` : 'Loading…'}</div>{b && <StatusChip s={b.returned_reason ? 'returned' : b.status} />}</div>
        {b && <div className="muted" style={{ fontSize: 13 }}>{b.vendor_ref ? `Their invoice ${b.vendor_ref} · ` : ''}{fmtDay(b.bill_date)} · due {fmtDay(b.due_date)}{b.journal_ref ? ` · ${b.journal_ref}` : ''}</div>}
      </div><button className="x-btn" onClick={onClose} aria-label="Close"><Icon name="x" size={18} /></button></div>
      <div className="drawer-body stack" style={{ gap: 14 }}>
        {!b ? <Spinner /> : (
          <>
            {b.status === 'draft' && <Alert kind="grey" icon="pencil">{b.source === 'prism' ? 'Sent from Prism. ' : b.source === 'ai' ? 'Read by AI. ' : ''}Check it and approve it to put it in the books.</Alert>}
            {b.returned_reason && <Returned b={b} canKeep={can(inv, 'keep_books')} onReopen={() => act(() => rpc('reopen_bill', { p_bill: b.id }), `${b.number} is a draft again`)} />}
            {flags.missing_state && ['draft', 'approved', 'partially_paid'].includes(b.status) && (
              <MissingState b={b} canKeep={can(inv, 'keep_books')} onSendBack={() => setSendBack('missing_state')} onDone={refresh} />
            )}
            {flags.missing_tin && ['draft', 'approved'].includes(b.status) && (
              <Alert kind="amber" icon="alert">
                {b.vendor?.name} has no Tax ID, so the withholding tax is doubled to {N2(b.wht_expected)}. Send the bill back for the Tax ID, or keep it and withhold at the double rate.
                {flags.can_return && can(inv, 'keep_books') && <div style={{ marginTop: 8 }}><button className="btn btn-secondary btn-xs" onClick={() => setSendBack('missing_tin')}><Icon name="undo" size={12} />Send back for the Tax ID</button></div>}
              </Alert>
            )}
            <div className="card" style={{ overflow: 'hidden', borderRadius: 12 }}>
              {(b.lines || []).map((l: any) => (
                <div key={l.id} className="tr" style={{ gridTemplateColumns: 'minmax(0,1fr) 120px', padding: '9px 14px' }}>
                  <span style={{ minWidth: 0 }}>{l.description}<span className="faint" style={{ display: 'block', fontSize: 12 }}>{l.account_code} {l.account_name} · {Number(l.qty)} × {N2(l.unit_cost)}{l.vat_treatment === 'standard' ? ` · VAT ${N2(l.vat)}${l.vat_recoverable ? '' : ' (not recoverable)'}` : l.vat_treatment === 'none' ? '' : ` · ${l.vat_treatment}`}
                    {Number(l.wht) > 0 ? ` · WHT ${pct(l.wht_rate)} ${N2(l.wht)}${l.wht_category_effective && l.wht_category_effective !== b.wht_category ? ` (${whtRates.find((w) => w.code === l.wht_category_effective)?.name || l.wht_category_effective})` : ''}` : ''}
                    {Number(l.reverse_charge_vat) > 0 ? ` · VAT self-charged ${N2(l.reverse_charge_vat)}` : ''}</span></span>
                  <span className="right num">{N2(l.gross)}</span>
                </div>
              ))}
              <div className="stack" style={{ padding: '10px 14px', gap: 4, borderTop: '1px solid #F3F4F6', fontSize: 13 }}>
                <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">Before VAT</span><span className="num">{N2(b.subtotal)}</span></div>
                <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">VAT</span><span className="num">{N2(b.vat_total)}</span></div>
                <div className="row" style={{ justifyContent: 'space-between', fontWeight: 700 }}><span>Total</span><span className="num">{N2(b.total)}</span></div>
                <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">Withholding tax{b.wht_category && b.wht_category !== 'none' ? ` (${whtRates.find((w) => w.code === b.wht_category)?.name || b.wht_category})` : ''}</span><span className="num">{N2(b.wht_expected)}</span></div>
                {b.wht_note && <div className="faint" style={{ fontSize: 12, marginTop: -2 }}>{b.wht_note}</div>}
                {Number(b.wvat_expected) > 0 && <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">VAT we withhold as an agent <span className="faint">(to the NRS by the 14th)</span></span><span className="num">{N2(b.wvat_expected)}</span></div>}
                {Number(b.reverse_charge_vat) > 0 && <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">VAT self-charged on services from abroad <span className="faint">(paid to the NRS, claimed back as input VAT)</span></span><span className="num">{N2(b.reverse_charge_vat)}</span></div>}
                {Number(b.amount_paid) > 0 && <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">Paid</span><span className="num">{N2(b.amount_paid)}</span></div>}
                {Number(b.balance) > 0 && <div className="row" style={{ justifyContent: 'space-between', color: '#C2410C', fontWeight: 600 }}><span>Still owed</span><span className="num">{N2(b.balance)}</span></div>}
              </div>
            </div>
            {(b.payments || []).length > 0 && <div className="stack" style={{ gap: 4 }}><div className="label">Payments</div>{b.payments.map((p: any) => (
              <div key={p.id} className="row" style={{ justifyContent: 'space-between', fontSize: 13 }}><span>{p.method === 'wallet' ? 'From the wallet' : p.method === 'bank' ? 'From the bank' : p.method} · {when(p.paid_at)}{p.reference ? ` · ${p.reference}` : ''}</span>
                <span className="row" style={{ gap: 6 }}><StatusChip s={p.status} /><span className="num">{N2(p.net)} + WHT {N2(p.wht)}{Number(p.wvat) > 0 ? ` + VAT ${N2(p.wvat)}` : ''}</span></span></div>
            ))}</div>}
            {(b.deductions || []).length > 0 && <div className="stack" style={{ gap: 4 }}><div className="label">Withheld</div>{b.deductions.map((x: any) => (
              <div key={x.id} className="row" style={{ justifyContent: 'space-between', fontSize: 13 }}>
                <span>{x.kind === 'wht' ? `WHT ${pct(x.rate)}` : x.kind === 'wvat' ? 'VAT withheld' : 'VAT self-charged'} · {x.authority_name || authorityLabel(x.authority)}{x.receipt_no ? ` · receipt ${x.receipt_no}` : ''}</span>
                <span className="row" style={{ gap: 6 }}><span className={'chip ' + (x.status === 'remitted' ? 't-green' : x.status === 'pending' ? 't-grey' : 't-amber')}>{x.status === 'remitted' ? 'paid over' : x.status === 'pending' ? 'on payment' : `due ${fmtDay(x.due_date)}`}</span><span className="num">{N2(x.amount)}</span></span></div>
            ))}</div>}
            {(b.credit_notes || []).length > 0 && <div className="stack" style={{ gap: 4 }}><div className="label">Credit notes</div>{b.credit_notes.map((c: any) => (
              <div key={c.id} className="row" style={{ justifyContent: 'space-between', fontSize: 13 }}><span>{c.number}{c.vendor_ref ? ` (their ${c.vendor_ref})` : ''} · {fmtDay(c.credit_date)} · {c.reason}</span><span className="num">{N2(c.total)}</span></div>
            ))}</div>}
            {can(inv, 'keep_books') && <UseCredits bill={b} />}
            {(b.assets || []).length > 0 && <Alert kind="blue" icon="info">{b.assets.length} fixed asset{b.assets.length === 1 ? '' : 's'} from this bill wait in Fixed assets to be confirmed.</Alert>}
            <div className="row wrap">
              {b.status === 'draft' && <button className="btn btn-secondary btn-sm" onClick={() => onEdit(b.id)}><Icon name="pencil" size={14} />Edit</button>}
              {b.status === 'draft' && can(inv, 'keep_books') && <button className="btn btn-primary btn-sm" disabled={!!flags.missing_state} title={flags.missing_state ? 'Add the supplier\'s state first' : undefined}
                onClick={() => (flags.missing_tin ? setNoTin(true) : act(() => rpc('approve_bill', { p_bill: b.id }), `${b.number} approved and in the books`))}>Approve</button>}
              {['approved', 'partially_paid'].includes(b.status) && can(inv, 'make_payments') && <button className="btn btn-primary btn-sm" disabled={!!flags.missing_state} title={flags.missing_state ? 'Add the supplier\'s state first' : undefined} onClick={() => setPay(true)}><Icon name="send" size={14} color="#fff" />Pay</button>}
              {flags.can_return && can(inv, 'keep_books') && !flags.missing_tin && !flags.missing_state && <button className="btn btn-ghost btn-sm" onClick={() => setSendBack('other')}><Icon name="undo" size={14} />Send back</button>}
              {['approved', 'partially_paid', 'paid'].includes(b.status) && can(inv, 'keep_books') && <button className="btn btn-secondary btn-sm" onClick={() => setCrediting(true)}><Icon name="undo" size={14} />Credit note</button>}
              {['draft', 'approved'].includes(b.status) && can(inv, 'keep_books') && <button className="btn btn-ghost btn-sm" onClick={() => setVoiding(true)}>Void</button>}
            </div>
            {voiding && <div className="row"><input className="input input-sm" autoFocus placeholder="Why is it voided?" value={reason} onChange={(e) => setReason(e.target.value)} />
              <button className="btn btn-danger btn-sm" disabled={reason.trim().length < 3} onClick={() => act(() => rpc('void_bill', { p_bill: b.id, p_reason: reason }), 'Bill voided')}>Void</button></div>}
          </>
        )}
      </div>
      {pay && b && <PayBill bill={b} onClose={() => setPay(false)} onDone={refresh} />}
      {sendBack && b && <SendBack b={b} reason={sendBack} onClose={() => setSendBack(null)} onDone={refresh} />}
      {noTin && b && (
        <Modal onClose={() => setNoTin(false)} width={480}>
          <ModalHead title={`${b.vendor?.name} has no Tax ID`} sub={b.number} onClose={() => setNoTin(false)} />
          <div className="modal-body stack" style={{ gap: 10, fontSize: 14 }}>
            <div>Without a Tax ID the withholding tax on this bill is doubled: <b className="num">{N2(b.wht_expected)}</b> instead of <b className="num">{N2(Number(b.wht_expected) / 2)}</b>.</div>
            <div className="muted" style={{ fontSize: 13 }}>Send the bill back and the supplier is told to get the Tax ID at taxid.nrs.gov.ng. Or approve it now and withhold at the double rate.</div>
          </div>
          <div className="modal-ft">
            <button className="btn btn-secondary" onClick={() => { setNoTin(false); setSendBack('missing_tin'); }}><Icon name="undo" size={14} />Send back for the Tax ID</button>
            <button className="btn btn-primary" onClick={async () => { setNoTin(false); await act(() => rpc('approve_bill', { p_bill: b.id }), `${b.number} approved, WHT at the double rate`); }}>Approve at the double rate</button>
          </div>
        </Modal>
      )}
      {crediting && b && <VendorCreditModal bill={b} onClose={() => setCrediting(false)} />}
    </Drawer>
  );
}

const RETURN_REASON: Record<string, string> = { missing_tin: 'No Tax ID', missing_state: 'No address for the state revenue service', other: 'Another reason' };

// A bill sent back to the supplier: why, what they were told and how, and opening it again once they answer.
function Returned({ b, canKeep, onReopen }: { b: any; canKeep: boolean; onReopen: () => void }) {
  const msg = (b.messages || []).filter((m: any) => m.template === 'bill_returned').at(-1);
  return (
    <Alert kind="red" icon="undo">
      <b>Sent back to the supplier</b> {when(b.returned_at)}{b.returned_by_name ? ` by ${b.returned_by_name}` : ''}: {RETURN_REASON[b.returned_reason] || b.returned_reason}.
      {msg ? ` ${msg.channel === 'email' ? 'Emailed' : 'Sent by WhatsApp'} to ${msg.to}${msg.status === 'failed' ? `, but it did not go: ${msg.error || 'failed'}` : msg.status === 'queued' ? ', waiting to send' : ''}.` : ' Not sent from Counta.'}
      {b.returned_note && <div className="faint" style={{ fontSize: 12, marginTop: 6, whiteSpace: 'pre-wrap' }}>{b.returned_note}</div>}
      {canKeep && <div style={{ marginTop: 8 }}><button className="btn btn-secondary btn-xs" onClick={onReopen}>Open it again</button></div>}
    </Alert>
  );
}

// WHT for a business name, sole trader, partnership or individual goes to its state's revenue service, so the bill waits
// for the state (TaxStreem sign-off W-2): add it here, or send the bill back to ask for the address.
function MissingState({ b, canKeep, onSendBack, onDone }: { b: any; canKeep: boolean; onSendBack: () => void; onDone: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const prof = useTaxProfile();
  const [state, setState] = useState('');
  const [busy, setBusy] = useState(false);
  const states: string[] = (prof.data?.authorities || []).filter((a: any) => a.state).map((a: any) => a.state);
  return (
    <Alert kind="amber" icon="alert">
      {b.vendor?.name}'s withholding tax goes to the revenue service of its state, and its state is not known. Add it, or send the bill back to ask for the address.
      <div className="row wrap" style={{ marginTop: 8, gap: 6 }}>
        <select className="input input-sm" style={{ width: 180 }} value={state} onChange={(e) => setState(e.target.value)} aria-label="Supplier's state"><option value="">Choose the state</option>{states.map((x) => <option key={x} value={x}>{x}</option>)}</select>
        <button className="btn btn-secondary btn-xs" disabled={!state || busy} onClick={async () => {
          setBusy(true);
          try { await rpc('save_vendor_details', { p_org: orgId, p_vendor: b.vendor_id, p_patch: { state } }); toast(`${b.vendor?.name} is in ${state}`); await onDone(); }
          catch (e) { toast((e as Error).message, 'err'); }
          setBusy(false);
        }}>Save the state</button>
        {b.tax_flags?.can_return && canKeep && <button className="btn btn-ghost btn-xs" onClick={onSendBack}><Icon name="undo" size={12} />Send back for the address</button>}
      </div>
    </Alert>
  );
}

// Sending a bill back: the reason, the note the supplier reads, and how it goes.
function SendBack({ b, reason: first, onClose, onDone }: { b: any; reason: string; onClose: () => void; onDone: () => void }) {
  const toast = useToast();
  const v = b.vendor || {};
  const [reason, setReason] = useState(first);
  const [note, setNote] = useState(b.return_notes?.[first] || '');
  const [send, setSend] = useState<'email' | 'whatsapp' | ''>(v.email ? 'email' : v.phone ? 'whatsapp' : '');
  const [to, setTo] = useState(v.email || v.phone || '');
  const [busy, setBusy] = useState(false);
  function pick(r: string) { setReason(r); setNote(b.return_notes?.[r] || (r === 'other' ? '' : note)); }
  async function go() {
    setBusy(true);
    try {
      await rpc('return_bill', { p_bill: b.id, p: { reason, note, send: send || null, to: send ? to : null } });
      toast(send ? `${b.number} sent back; the note is on its way to ${v.name}` : `${b.number} sent back`); await onDone(); onClose();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  return (
    <Modal onClose={onClose} width={560}>
      <ModalHead title={`Send ${b.number} back to ${v.name}`} sub={`${b.vendor_ref ? `Their invoice ${b.vendor_ref} · ` : ""}${N2(b.total)}`} onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 10 }}>
        <Field label="Why"><select className="input" value={reason} onChange={(e) => pick(e.target.value)}>
          <option value="missing_tin">No Tax ID</option><option value="missing_state">No address for the state revenue service</option><option value="other">Another reason</option></select></Field>
        <Field label="What the supplier reads"><textarea className="input" style={{ minHeight: 110 }} value={note} onChange={(e) => setNote(e.target.value)} /></Field>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1.4fr', gap: 10 }}>
          <Field label="Send it by"><select className="input" value={send} onChange={(e) => { const s = e.target.value as any; setSend(s); setTo(s === 'email' ? v.email || '' : s === 'whatsapp' ? v.phone || '' : ''); }}>
            <option value="email">Email</option><option value="whatsapp">WhatsApp</option><option value="">I'll send it myself</option></select></Field>
          {send ? <Field label={send === 'email' ? 'Email address' : 'WhatsApp number'}><input className="input" value={to} onChange={(e) => setTo(e.target.value)} inputMode={send === 'email' ? 'email' : 'tel'} /></Field>
            : <Field label="Copy the note"><button className="btn btn-secondary btn-sm" onClick={() => { navigator.clipboard?.writeText(note).then(() => toast('Copied'), () => toast('Select the note and copy it', 'err')); }}><Icon name="copy" size={13} />Copy</button></Field>}
        </div>
        <div className="faint" style={{ fontSize: 12 }}>The bill leaves the books as a void bill does{b.source === 'prism' ? ', and Prism sees why when it checks the bill' : ''}. Open it again when the supplier answers.</div>
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" disabled={busy || note.trim().length < 3 || (!!send && !to.trim())} onClick={go}>{send ? 'Send back' : 'Send back without a message'}</button></div>
    </Modal>
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
    moneyAccounts(orgId!).then((accounts) => setOwn(accounts || [])).catch(() => {});
  }, [orgId]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (f.method !== 'wallet' || !/^\d{10}$/.test(f.account_number) || !f.bank_code || f.account_name) return;
    edge<{ account_name: string }>('payments', { action: 'resolve_account', account_number: f.account_number, bank_code: f.bank_code }).then((r) => r.account_name && setF((x) => ({ ...x, account_name: r.account_name })));
  }, [f.account_number, f.bank_code, f.method]); // eslint-disable-line react-hooks/exhaustive-deps
  const gross = money(f.amount) || 0;
  // What the payment keeps back, as the database will: in proportion to what it settles, the rest when it settles the bill.
  const tw = bill.to_withhold || {};
  const full = gross >= due - 0.004;
  const share = (expected: number, left: number) => (full ? left : Math.min(Math.round(expected * gross / Number(bill.total || 1) * 100) / 100, left));
  const wht = share(Number(bill.wht_expected || 0), Number(tw.wht_left ?? bill.wht_expected ?? 0));
  const wvat = share(Number(bill.wvat_expected || 0), Number(tw.wvat_left ?? bill.wvat_expected ?? 0));
  const pf = v.wht_profile || {};
  const whtTo = pf.corporate !== false || pf.resident === false ? 'pay to the NRS by the 21st' : 'pay to the state revenue service by the 30th';
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
          <span>Withholding tax kept back <span className="faint">({whtTo})</span></span><b className="num">{N2(wht)}</b>
        </div>
        {wvat > 0 && <div className="row" style={{ justifyContent: 'space-between', background: '#FAFAFA', borderRadius: 10, padding: 10, fontSize: 13 }}>
          <span>VAT kept back as a withholding VAT agent <span className="faint">(pay to the NRS by the 14th)</span></span><b className="num">{N2(wvat)}</b></div>}
        <div className="row" style={{ justifyContent: 'space-between', fontWeight: 700 }}><span>The supplier receives</span><span className="num">{N2(gross - wht - wvat)}</span></div>
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
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={busy || gross <= 0 || (f.method === 'wallet' ? !f.account_name || !f.bank_code : !f.bank_account_id)} onClick={go}>{f.method === 'wallet' ? `Send ${N2(gross - wht - wvat)}` : 'Record payment'}</button></div>
    </Modal>
  );
}

interface BLine { key: string; description: string; account_code: string; qty: string; unit_cost: string; vat_treatment: string; vat_recoverable: boolean; asset_life_months: string; wht_category: string }

function BillEditor({ id, draft, vendors, whtRates, assetClasses, onClose, onSaved }: { id: string | null; draft?: Drafts['bill'] | null; vendors: any[]; whtRates: any[]; assetClasses: any[]; onClose: () => void; onSaved: (id: string) => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const existing = useBill(id);
  const chart = useChart();
  const [vendor, setVendor] = useState({ id: '', name: '', tin: '' });
  const [f, setF] = useState({ vendor_ref: '', bill_date: today(), due_date: '', vat_charged: true, prices_include_vat: false, wht_category: '', notes: '' });
  const [lines, setLines] = useState<BLine[]>([{ key: crypto.randomUUID(), description: '', account_code: '', qty: '1', unit_cost: '', vat_treatment: 'standard', vat_recoverable: true, asset_life_months: '', wht_category: '' }]);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    const b = existing.data;
    if (!b) return;
    setVendor({ id: b.vendor_id, name: b.vendor?.name || '', tin: b.vendor?.tin || '' });
    setF({ vendor_ref: b.vendor_ref || '', bill_date: b.bill_date, due_date: b.due_date || '', vat_charged: b.vat_charged, prices_include_vat: b.prices_include_vat, wht_category: b.wht_category || '', notes: b.notes || '' });
    setLines((b.lines || []).map((l: any) => ({ key: l.id, description: l.description, account_code: l.account_code, qty: String(Number(l.qty)), unit_cost: String(Number(l.unit_cost)),
      vat_treatment: l.vat_treatment === 'none' ? 'standard' : l.vat_treatment, vat_recoverable: l.vat_recoverable, asset_life_months: l.asset_life_months ? String(l.asset_life_months) : '',
      wht_category: l.wht_category && l.wht_category !== b.wht_category ? l.wht_category : '' })));
  }, [existing.data?.id]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (!draft || id) return;
    const n = draft.vendor.trim().toLowerCase();
    const v = vendors.find((x) => x.name.toLowerCase() === n) || vendors.find((x) => n && (x.name.toLowerCase().includes(n) || n.includes(x.name.toLowerCase())));
    setVendor(v ? { id: v.id, name: v.name, tin: v.tin || '' } : { id: '', name: draft.vendor, tin: '' });
    setF((x) => ({ ...x, due_date: draft.due_date || x.due_date, ...(v?.wht_category ? { wht_category: v.wht_category } : {}) }));
    setLines([{ key: crypto.randomUUID(), description: draft.description, account_code: '', qty: '1', unit_cost: String(draft.amount || ''), vat_treatment: 'standard', vat_recoverable: true, asset_life_months: '', wht_category: '' }]);
  }, [draft, vendors.length]); // eslint-disable-line react-hooks/exhaustive-deps
  const accounts = (chart.data?.accounts || []).filter((a: any) => !a.is_group && a.active && (/^[56]/.test(a.code) || /^(120[1-6]|15[0-2]|160)/.test(a.code)));
  const assetCodes = new Set(assetClasses.map((c) => c.cost_account));
  const upd = (k: string, p: Partial<BLine>) => setLines((ls) => ls.map((l) => (l.key === k ? { ...l, ...p } : l)));
  const net = lines.reduce((a, l) => a + (Number(l.qty) || 0) * (money(l.unit_cost) || 0), 0);
  const tinErr = vendor.id ? null : taxIdError(vendor.tin);
  async function save() {
    if (tinErr) { toast(tinErr, 'err'); return; }
    setBusy(true);
    try {
      const r = await rpc<any>('save_bill', { p_org: orgId, p_bill: { id: id || null, vendor_id: vendor.id || null, vendor: vendor.id ? undefined : { name: vendor.name, tin: vendor.tin || null },
        ...f, due_date: f.due_date || null, wht_category: f.wht_category || null,
        lines: lines.filter((l) => l.description || l.unit_cost).map((l) => ({ description: l.description, account_code: l.account_code, qty: Number(l.qty) || 1, unit_cost: money(l.unit_cost),
          vat_treatment: l.vat_treatment, vat_recoverable: l.vat_recoverable, asset_life_months: assetCodes.has(l.account_code) ? Number(l.asset_life_months) || null : null,
          wht_category: l.wht_category || null })) } });
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
        {draft && !id && <Alert kind="blue" icon="sparkles">Martina prepared this bill{vendor.id ? '' : ' for a new vendor'}. Choose the account it belongs to, check VAT and the amount, then save it. Nothing is posted or paid until it is approved.</Alert>}
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1.4fr 1fr 1fr', gap: 12 }}>
          <Field label="Vendor" req>
            <input className="input" list="bill-vendors" value={vendor.name} onChange={(e) => { const v = vendors.find((x) => x.name === e.target.value); setVendor(v ? { id: v.id, name: v.name, tin: v.tin || '' } : { id: '', name: e.target.value, tin: vendor.tin }); if (v?.wht_category) setF((x) => ({ ...x, wht_category: v.wht_category })); }} placeholder="Type or pick" />
            <datalist id="bill-vendors">{vendors.map((v) => <option key={v.id} value={v.name} />)}</datalist>
          </Field>
          <Field label="Their invoice number"><input className="input" value={f.vendor_ref} onChange={(e) => setF({ ...f, vendor_ref: e.target.value })} /></Field>
          {!vendor.id ? <Field label="Vendor's Tax ID" error={tinErr} hint={tinErr ? undefined : 'Without a Tax ID the WHT rate doubles.'}><input className="input" inputMode="numeric" maxLength={20} placeholder="13 digits" value={vendor.tin} onChange={(e) => setVendor({ ...vendor, tin: e.target.value })} /></Field> : <span />}
        </div>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1.4fr', gap: 12 }}>
          <Field label="Bill date"><input className="input" type="date" value={f.bill_date} onChange={(e) => setF({ ...f, bill_date: e.target.value })} /></Field>
          <Field label="Due"><input className="input" type="date" value={f.due_date} onChange={(e) => setF({ ...f, due_date: e.target.value })} /></Field>
          <Field label="Withholding tax" hint="The rate follows the supplier: company or not, in Nigeria or abroad, with a Tax ID or not."><select className="input" value={f.wht_category} onChange={(e) => setF({ ...f, wht_category: e.target.value })}><option value="">The vendor's usual</option>{whtRates.map((w) => <option key={w.code} value={w.code}>{w.name}{w.code === 'none' || w.exemption ? '' : ` · ${pct(w.rate_corp_res ?? w.rate_company)} for a company`}</option>)}</select></Field>
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
                <select className="input input-sm" value={l.wht_category} onChange={(e) => upd(l.key, { wht_category: e.target.value })} aria-label="Withholding tax on this line" style={{ color: l.wht_category ? undefined : '#6B7280' }}>
                  <option value="">WHT as the bill</option>{whtRates.filter((w) => w.code !== 'none').map((w) => <option key={w.code} value={w.code}>WHT: {w.name}</option>)}</select>
              </span>
              <input className="input input-sm num" inputMode="decimal" value={l.qty} onChange={(e) => upd(l.key, { qty: e.target.value })} aria-label="Quantity" />
              <input className="input input-sm num" inputMode="decimal" value={l.unit_cost} onChange={(e) => upd(l.key, { unit_cost: e.target.value })} aria-label="Unit cost" />
              <span className="stack" style={{ gap: 4 }}>
                <select className="input input-sm" disabled={!f.vat_charged} value={l.vat_treatment} onChange={(e) => upd(l.key, { vat_treatment: e.target.value })}><option value="standard">{vatPct(f.bill_date)}</option><option value="zero">Zero-rated</option><option value="exempt">Exempt</option></select>
                {f.vat_charged && l.vat_treatment === 'standard' && <label className="check" style={{ fontSize: 11 }}><input type="checkbox" checked={l.vat_recoverable} onChange={(e) => upd(l.key, { vat_recoverable: e.target.checked })} />Claim back</label>}
              </span>
              <button className="btn btn-ghost btn-xs" onClick={() => setLines((ls) => ls.filter((x) => x.key !== l.key))} aria-label="Remove line"><Icon name="trash" size={13} /></button>
            </div>
          ))}
          <div style={{ padding: 12 }}><button className="btn btn-secondary btn-sm" onClick={() => setLines((ls) => [...ls, { key: crypto.randomUUID(), description: '', account_code: '', qty: '1', unit_cost: '', vat_treatment: 'standard', vat_recoverable: true, asset_life_months: '', wht_category: '' }])}><Icon name="plus" size={13} />Line</button></div>
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
