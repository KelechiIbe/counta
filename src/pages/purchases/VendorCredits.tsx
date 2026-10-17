// Supplier credit notes: what a supplier takes off a bill (a price reduction, short or damaged goods sent back, an
// allowance) or gives the business on account. Recording one reduces what is owed to them, takes the input VAT back and,
// for goods sent back, takes them out of stock at what they cost. What is left can be used on their next bill or paid back.
import { useEffect, useMemo, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { can, useInventory, useSession, useToast } from '../../state/session';
import { rpc } from '../../lib/supabase';
import { money, today, useBills, useChart } from '../../lib/api';
import { N2, fmtDay } from '../../lib/format';
import { Icon } from '../../components/Icon';
import { Alert, Empty, Field, Modal, ModalHead, SkeletonRows, Spinner } from '../../components/ui';
import { StatusChip } from '../sell/common';

export function useVendorCredits(vendorId?: string | null, enabled = true) {
  const { orgId } = useSession();
  return useQuery({ queryKey: ['vendor-credits', orgId, vendorId || null], enabled: enabled && !!orgId,
    queryFn: () => rpc<any[]>('get_vendor_credits', { p_org: orgId, p_vendor: vendorId || null }) });
}

const refreshKeys = ['bill', 'bills', 'vendor-credits', 'inbox', 'inv', 'report', 'assets'];

// From a bill (its lines, what each can still be credited) or on account (an amount against an account).
export function VendorCreditModal({ bill, onClose }: { bill?: any; onClose: () => void }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const bills = useBills({}, !bill);
  const chart = useChart();
  const [f, setF] = useState({ vendor_id: bill?.vendor_id || '', vendor_ref: '', credit_date: today(), reason: '' });
  const [amt, setAmt] = useState<Record<string, string>>({});
  const [ret, setRet] = useState<Record<string, { item_id: string; qty: string }>>({});
  const [free, setFree] = useState({ amount: '', account_code: '', vat_treatment: 'standard', description: '' });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const lines: any[] = (bill?.lines || []).filter((l: any) => Number(l.creditable) > 0);
  const accounts = useMemo(() => (chart.data?.accounts || []).filter((a: any) => !a.is_group && a.active && /^(5|6|1[25])/.test(a.code)), [chart.data]);
  const items = useMemo(() => [...(inv?.items || [])].sort((a, b) => a.name.localeCompare(b.name)), [inv]);
  const total = bill ? lines.reduce((a, l) => a + (money(amt[l.id]) || 0), 0) : money(free.amount) || 0;
  const vat = bill ? lines.reduce((a, l) => a + (Number(l.gross) ? (money(amt[l.id]) || 0) * Number(l.vat) / Number(l.gross) : 0), 0)
    : free.vat_treatment === 'standard' ? (money(free.amount) || 0) * 0.075 / 1.075 : 0;
  const isStock = (code: string) => /^120[1-7]/.test(code || '');
  async function go() {
    setBusy(true); setErr(null);
    try {
      const p: any = { reason: f.reason, vendor_ref: f.vendor_ref || null, credit_date: f.credit_date };
      if (bill) {
        p.bill_id = bill.id;
        p.lines = lines.filter((l) => (money(amt[l.id]) || 0) > 0).map((l) => {
          const r = ret[l.id];
          return { bill_line_id: l.id, amount: money(amt[l.id]), ...(r?.item_id && Number(r.qty) > 0 ? { item_id: r.item_id, qty: Number(r.qty), location_id: l.location_id || null } : {}) };
        });
      } else {
        p.vendor_id = f.vendor_id;
        p.lines = [{ account_code: free.account_code, vat_treatment: free.vat_treatment, amount: money(free.amount), description: free.description || null }];
      }
      const r = await rpc<any>('record_vendor_credit', { p_org: orgId, p });
      toast(`${r.number} recorded${Number(r.applied) > 0 ? ` · ${N2(r.applied)} taken off ${r.bill_number}` : ''}${Number(r.remaining) > 0 ? ` · ${N2(r.remaining)} left to use` : ''}`);
      await Promise.all(refreshKeys.map((k) => qc.invalidateQueries({ queryKey: [k] })));
      onClose();
    } catch (e) { setErr((e as Error).message); }
    setBusy(false);
  }
  const ok = f.reason.trim().length >= 3 && total > 0 && (bill || (f.vendor_id && free.account_code));
  return (
    <Modal onClose={onClose} width={720}>
      <ModalHead title={bill ? `Credit note on ${bill.number}` : 'Supplier credit note'} onClose={onClose}
        sub={bill ? `${bill.vendor?.name}. Enter what the supplier's credit note takes off each line, VAT included. It comes off what is owed on the bill first.`
          : 'A credit the supplier gave on account. It waits to be used on their next bill or paid back.'} />
      <div className="modal-body">
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: bill ? '1fr 1fr' : '1.4fr 1fr 1fr', gap: 10 }}>
          {!bill && <Field label="Supplier"><select className="input" value={f.vendor_id} onChange={(e) => setF({ ...f, vendor_id: e.target.value })}>
            <option value="">Choose</option>{(bills.data?.vendors || []).map((v: any) => <option key={v.id} value={v.id}>{v.name}</option>)}</select></Field>}
          <Field label="Their credit note number"><input className="input" value={f.vendor_ref} onChange={(e) => setF({ ...f, vendor_ref: e.target.value })} placeholder="As printed on it" /></Field>
          <Field label="Date on it"><input className="input" type="date" value={f.credit_date} max={today()} onChange={(e) => setF({ ...f, credit_date: e.target.value })} /></Field>
        </div>
        <Field label="Reason"><input className="input" value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })} placeholder="Damaged cartons sent back, price agreed lower, late delivery discount…" /></Field>
        {bill ? (
          !lines.length ? <Alert kind="yellow" icon="info">Every line on this bill has already been credited in full.</Alert> : (
            <div className="stack" style={{ gap: 8 }}>
              {lines.map((l) => (
                <div key={l.id} className="card" style={{ padding: 10, borderRadius: 10 }}>
                  <div className="row" style={{ justifyContent: 'space-between', gap: 10 }}>
                    <span className="grow" style={{ minWidth: 0 }}><span className="ellipsis" style={{ display: 'block' }}>{l.description}</span>
                      <span className="faint" style={{ fontSize: 12 }}>{l.account_code} {l.account_name} · up to {N2(l.creditable)}{Number(l.vat) > 0 ? ' with VAT' : ''}</span></span>
                    <input className="input input-sm num" style={{ width: 130 }} inputMode="decimal" placeholder="0.00" value={amt[l.id] || ''} aria-label={`Credit on ${l.description}`}
                      onChange={(e) => setAmt({ ...amt, [l.id]: e.target.value })} />
                    <button className="btn btn-ghost btn-xs" onClick={() => setAmt({ ...amt, [l.id]: String(l.creditable) })}>All</button>
                  </div>
                  {isStock(l.account_code) && (money(amt[l.id]) || 0) > 0 && (
                    <div className="row wrap" style={{ gap: 8, marginTop: 8 }}>
                      <span className="faint" style={{ fontSize: 12 }}>Goods sent back (leave empty for a price reduction)</span>
                      <select className="input input-sm" style={{ maxWidth: 240 }} value={ret[l.id]?.item_id || ''} onChange={(e) => setRet({ ...ret, [l.id]: { item_id: e.target.value, qty: ret[l.id]?.qty || '' } })}>
                        <option value="">No goods went back</option>{items.map((i) => <option key={i.id} value={i.id}>{i.name}</option>)}</select>
                      {ret[l.id]?.item_id && <input className="input input-sm num" style={{ width: 110 }} inputMode="decimal" placeholder={`Qty (${items.find((i) => i.id === ret[l.id].item_id)?.selling_unit || 'units'})`}
                        value={ret[l.id]?.qty || ''} onChange={(e) => setRet({ ...ret, [l.id]: { ...ret[l.id], qty: e.target.value } })} />}
                    </div>
                  )}
                </div>
              ))}
            </div>
          )
        ) : (
          <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1.4fr 1fr', gap: 10 }}>
            <Field label="Amount (with VAT)"><input className="input num" inputMode="decimal" value={free.amount} onChange={(e) => setFree({ ...free, amount: e.target.value })} /></Field>
            <Field label="It reduces"><select className="input" value={free.account_code} onChange={(e) => setFree({ ...free, account_code: e.target.value })}>
              <option value="">Choose the account</option>{accounts.map((a: any) => <option key={a.code} value={a.code}>{a.code} {a.name}</option>)}</select></Field>
            <Field label="VAT"><select className="input" value={free.vat_treatment} onChange={(e) => setFree({ ...free, vat_treatment: e.target.value })}>
              <option value="standard">7.5% included</option><option value="zero">Zero-rated</option><option value="exempt">Exempt</option><option value="none">No VAT</option></select></Field>
          </div>
        )}
        <div className="row" style={{ justifyContent: 'space-between', background: '#FAFAFA', borderRadius: 10, padding: 10, fontSize: 13 }}>
          <span>Credit note {N2(total)}{vat > 0 ? <span className="faint"> · input VAT given back {N2(vat)}</span> : null}</span>
          {bill && <span className="faint">Owed on {bill.number}: {N2(bill.balance)}</span>}
        </div>
        {bill && total > Number(bill.balance) + 0.004 && <div className="faint" style={{ fontSize: 12 }}>{N2(total - Number(bill.balance))} more than is owed on the bill stays as credit with {bill.vendor?.name}, to use on their next bill or to be paid back.</div>}
        {err && <Alert kind="red" icon="alert">{err}</Alert>}
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" disabled={busy || !ok || !can(inv, 'keep_books')} onClick={go}>{busy ? <Spinner small /> : null}Record credit note</button></div>
    </Modal>
  );
}

// Open credits for one supplier, offered on their bill.
export function UseCredits({ bill }: { bill: any }) {
  const toast = useToast();
  const qc = useQueryClient();
  const credits = useVendorCredits(bill.vendor_id);
  const open = (credits.data || []).filter((c) => c.status === 'open');
  const [busy, setBusy] = useState(false);
  if (!open.length || !(Number(bill.balance) > 0)) return null;
  async function use(c: any) {
    setBusy(true);
    try { await rpc('use_vendor_credit', { p_credit: c.id, p_bill: bill.id, p_amount: null }); toast(`${c.number} used on ${bill.number}`); await Promise.all(refreshKeys.map((k) => qc.invalidateQueries({ queryKey: [k] }))); }
    catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  return (
    <Alert kind="blue" icon="info">
      <div className="stack" style={{ gap: 6 }}>
        <div>{bill.vendor?.name} has {N2(open.reduce((a, c) => a + Number(c.remaining), 0))} of credit to use.</div>
        {open.map((c) => <div key={c.id} className="row wrap" style={{ gap: 8 }}><span>{c.number}{c.vendor_ref ? ` (their ${c.vendor_ref})` : ''} · {N2(c.remaining)} left</span>
          <button className="btn btn-secondary btn-xs" disabled={busy} onClick={() => use(c)}>Use on {bill.number}</button></div>)}
      </div>
    </Alert>
  );
}

// The list on the Bills page.
export function CreditsList() {
  const { data: inv } = useInventory();
  const credits = useVendorCredits();
  const [adding, setAdding] = useState(false);
  const [refund, setRefund] = useState<any | null>(null);
  const [useOn, setUseOn] = useState<any | null>(null);
  const rows = credits.data || [];
  return (
    <div className="stack" style={{ gap: 12 }}>
      <div className="row wrap" style={{ justifyContent: 'space-between' }}>
        <div className="muted" style={{ fontSize: 13, maxWidth: 640 }}>Credit notes from suppliers. One raised from a bill comes off that bill first; what is left is used on their next bill or paid back to you.</div>
        {can(inv, 'keep_books') && <button className="btn btn-secondary btn-sm" onClick={() => setAdding(true)}><Icon name="plus" size={14} />Credit on account</button>}
      </div>
      <div className="card" style={{ overflow: 'hidden' }}>
        <div className="tbl">
          <div className="tr head shade th hide-sm" style={{ gridTemplateColumns: '100px minmax(160px,1.3fr) 110px minmax(140px,1fr) 110px 110px 100px auto', minWidth: 940 }}>
            <span>Credit</span><span>Supplier</span><span>Date</span><span>Reason</span><span className="right">Total</span><span className="right">Left</span><span>Status</span><span />
          </div>
          {credits.isLoading ? <SkeletonRows n={4} /> : credits.error ? <div style={{ padding: 20 }}><Alert kind="yellow" icon="shield">{(credits.error as Error).message}</Alert></div>
            : !rows.length ? <div style={{ padding: 20 }}><Empty>No supplier credit notes yet. Open a bill and choose Credit note when a supplier sends one.</Empty></div> : rows.map((c) => (
            <div key={c.id} className="tr" style={{ gridTemplateColumns: '100px minmax(160px,1.3fr) 110px minmax(140px,1fr) 110px 110px 100px auto', minWidth: 940 }}>
              <span><b>{c.number}</b><span className="faint" style={{ display: 'block', fontSize: 11 }}>{c.vendor_ref ? `their ${c.vendor_ref}` : ''}</span></span>
              <span className="ellipsis">{c.vendor_name}{c.bill_number ? <span className="faint" style={{ fontSize: 12 }}> · on {c.bill_number}</span> : null}</span>
              <span className="muted">{fmtDay(c.credit_date)}</span>
              <span className="ellipsis muted" title={c.reason}>{c.reason}</span>
              <span className="right num">{N2(c.total)}</span>
              <span className="right num" style={{ fontWeight: 600 }}>{Number(c.remaining) > 0 ? N2(c.remaining) : '—'}</span>
              <span><StatusChip s={c.status === 'open' ? 'open' : c.status === 'used' ? 'paid' : 'void'} /></span>
              <span className="row" style={{ gap: 4 }}>{c.status === 'open' && can(inv, 'keep_books') && <>
                <button className="btn btn-ghost btn-xs" onClick={() => setUseOn(c)}>Use on a bill</button>
                <button className="btn btn-ghost btn-xs" onClick={() => setRefund(c)}>Paid back</button></>}</span>
            </div>
          ))}
        </div>
      </div>
      {adding && <VendorCreditModal onClose={() => setAdding(false)} />}
      {refund && <RefundCredit credit={refund} onClose={() => setRefund(null)} />}
      {useOn && <UseOnBill credit={useOn} onClose={() => setUseOn(null)} />}
    </div>
  );
}

function UseOnBill({ credit, onClose }: { credit: any; onClose: () => void }) {
  const toast = useToast();
  const qc = useQueryClient();
  const bills = useBills({}, true);
  const open = (bills.data?.bills || []).filter((b) => b.vendor_id === credit.vendor_id && ['approved', 'partially_paid'].includes(b.status));
  const [bill, setBill] = useState('');
  const [amount, setAmount] = useState('');
  async function go() {
    try { await rpc('use_vendor_credit', { p_credit: credit.id, p_bill: bill, p_amount: money(amount) }); toast('Credit used'); await Promise.all(refreshKeys.map((k) => qc.invalidateQueries({ queryKey: [k] }))); onClose(); }
    catch (e) { toast((e as Error).message, 'err'); }
  }
  return (
    <Modal onClose={onClose} width={460}>
      <ModalHead title={`Use ${credit.number}`} sub={`${N2(credit.remaining)} left from ${credit.vendor_name}`} onClose={onClose} />
      <div className="modal-body">
        {!open.length ? <Alert kind="blue" icon="info">{credit.vendor_name} has no bill waiting to be paid.</Alert> : <>
          <Field label="Bill"><select className="input" value={bill} onChange={(e) => setBill(e.target.value)}><option value="">Choose</option>
            {open.map((b) => <option key={b.id} value={b.id}>{b.number}{b.vendor_ref ? ` · ${b.vendor_ref}` : ''} · {N2(b.balance)} owed</option>)}</select></Field>
          <Field label="Amount" hint="Leave empty to use as much as the bill takes."><input className="input" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} /></Field>
        </>}
      </div>
      <div className="modal-ft"><button className="btn btn-primary" disabled={!bill} onClick={go}>Use the credit</button></div>
    </Modal>
  );
}

function RefundCredit({ credit, onClose }: { credit: any; onClose: () => void }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const [own, setOwn] = useState<any[]>([]);
  const [f, setF] = useState({ bank_account_id: '', amount: String(credit.remaining), received_at: today(), reference: '' });
  useEffect(() => { rpc<any>('get_till', { p_org: orgId, p_location: inv?.locations[0]?.id }).then((t) => setOwn(t.accounts || [])).catch(() => {}); }, [orgId]); // eslint-disable-line react-hooks/exhaustive-deps
  async function go() {
    try {
      await rpc('refund_vendor_credit', { p_credit: credit.id, p: { bank_account_id: f.bank_account_id, amount: money(f.amount), received_at: f.received_at, reference: f.reference || null } });
      toast('Refund recorded'); await Promise.all([...refreshKeys, 'banking'].map((k) => qc.invalidateQueries({ queryKey: [k] }))); onClose();
    } catch (e) { toast((e as Error).message, 'err'); }
  }
  return (
    <Modal onClose={onClose} width={460}>
      <ModalHead title={`${credit.vendor_name} paid back ${credit.number}`} sub="Record money the supplier returned for the credit." onClose={onClose} />
      <div className="modal-body">
        <Field label="Into"><select className="input" value={f.bank_account_id} onChange={(e) => setF({ ...f, bank_account_id: e.target.value })}><option value="">Choose the account</option>{own.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}</select></Field>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
          <Field label="Amount"><input className="input" inputMode="decimal" value={f.amount} onChange={(e) => setF({ ...f, amount: e.target.value })} /></Field>
          <Field label="Received on"><input className="input" type="date" max={today()} value={f.received_at} onChange={(e) => setF({ ...f, received_at: e.target.value })} /></Field>
        </div>
        <Field label="Reference"><input className="input" value={f.reference} onChange={(e) => setF({ ...f, reference: e.target.value })} /></Field>
      </div>
      <div className="modal-ft"><button className="btn btn-primary" disabled={!f.bank_account_id || !(money(f.amount) || 0)} onClick={go}>Record refund</button></div>
    </Modal>
  );
}
