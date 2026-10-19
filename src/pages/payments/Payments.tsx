// Payments: the business wallet (a Flutterwave payout subaccount, or the partner's own rail), money collected by
// transfer, link and QR, payouts with approval, and the nightly reconciliation of the wallet against the books.
import { useEffect, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { PaymentsLock } from '../onboarding/Identity';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { can, useInventory, useSession, useToast } from '../../state/session';
import { rpc } from '../../lib/supabase';
import { METHOD_LABEL, edge, edgeOk, money, useChart, useCustomers, usePayments, moneyAccounts } from '../../lib/api';
import { N2, fmtDay, when } from '../../lib/format';
import { Icon } from '../../components/Icon';
import { Alert, Empty, Field, Modal, ModalHead, Pills, SkeletonRows, Spinner } from '../../components/ui';
import { CustomerPicker, PayWait, StatusChip } from '../sell/common';
import { useDraft, type Drafts } from '../../lib/drafts';
import type { Customer, PayRequest } from '../../lib/api';
import { BatchList, BatchModal, BulkPayModal, TemplateButton } from './BulkPay';

export default function Payments() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const pay = usePayments();
  type Tab = 'collections' | 'payouts' | 'bulk' | 'reconciliations' | 'settings';
  const [params, setParams] = useSearchParams();
  const [tab, setTabState] = useState<Tab>(() => (['collections', 'payouts', 'bulk', 'reconciliations', 'settings'].includes(params.get('tab') || '') ? params.get('tab') as Tab : 'collections'));
  const setTab = (t: Tab) => { setTabState(t); const n = new URLSearchParams(params); n.set('tab', t); n.delete('batch'); setParams(n, { replace: true }); };
  const openBatch = params.get('batch');
  const setOpenBatch = (id: string | null) => { const n = new URLSearchParams(params); if (id) { n.set('tab', 'bulk'); n.set('batch', id); } else n.delete('batch'); setParams(n, { replace: true }); };
  const [payout, setPayout] = useState(false);
  // A payment link Martina prepared opens for the person to check the customer and amount before it is made.
  const linkDraft = useDraft('payment_link');
  const [link, setLink] = useState<Drafts['payment_link'] | 'new' | null>(null);
  useEffect(() => { if (linkDraft) setLink(linkDraft); }, [linkDraft]);
  const [bulk, setBulk] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [live, setLive] = useState<{ available: number; ledger: number } | null>(null);
  const d = pay.data;
  const w = d?.wallet;
  const refresh = () => qc.invalidateQueries({ queryKey: ['payments'] });
  async function openWallet() {
    setBusy('open');
    const r = await edge('payments', { action: 'open_wallet', org_id: orgId });
    if (r.ok === false) toast(r.reason === 'not_configured' ? 'Payments are not switched on for TaxStreem yet. Add the Flutterwave keys first.' : r.error || 'Could not open the wallet.', 'err');
    else toast('The wallet is open');
    await refresh(); setBusy(null);
  }
  async function checkBalance() {
    setBusy('balance');
    const r = await edge<{ balance: { available: number; ledger: number }; reconciliation: any }>('payments', { action: 'balance', org_id: orgId });
    if (r.ok === false) toast(r.error || 'Could not reach the wallet.', 'err');
    else { setLive(r.balance); await refresh(); toast(r.reconciliation?.status === 'matched' ? 'The wallet agrees with the books' : 'The wallet differs from the books; see Reconciliations'); }
    setBusy(null);
  }
  async function act(fn: () => Promise<any>, ok: string) {
    try { await fn(); toast(ok); await Promise.all(['payments', 'inbox'].map((k) => qc.invalidateQueries({ queryKey: [k] }))); } catch (e) { toast((e as Error).message, 'err'); }
  }
  if (!inv) return null;
  const money_ = can(inv, 'keep_books') || can(inv, 'make_payments') || can(inv, 'see_margins');
  return (
    <div className="container">
      <PaymentsLock />
      {pay.isLoading ? <SkeletonRows n={4} /> : !w || w.status !== 'active' ? (
        <div className="card card-pad stack" style={{ gap: 12, maxWidth: 760 }}>
          <div style={{ fontSize: 18, fontWeight: 600 }}>Open the business wallet</div>
          <div className="muted" style={{ fontSize: 14, lineHeight: 1.6 }}>The wallet is an account number in your business's name{d?.rail ? ` at ${d.rail.name}` : ''}. Money customers pay by transfer, link or QR lands in it and is confirmed the moment it arrives; you pay suppliers and staff from it, and withdraw to your bank whenever you like. TaxStreem holds the funds with {d?.rail?.code === 'flutterwave' || !d?.rail ? 'Flutterwave' : d.rail.name}, a licensed payments company.</div>
          {w?.status === 'failed' && <Alert kind="red" icon="alert">{w.error || 'The last attempt failed.'}</Alert>}
          {w?.status === 'creating' && <Alert kind="blue" icon="clock">Opening…</Alert>}
          {d?.can?.open_wallet ? <div><button className="btn btn-primary" disabled={!!busy || inv.org.payments_open === false} onClick={openWallet}>{busy === 'open' ? 'Opening…' : 'Open the wallet'}</button></div>
            : <Alert kind="grey" icon="shield">The owner or someone who keeps the books opens the wallet.</Alert>}
        </div>
      ) : (
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: 'minmax(0,1.2fr) minmax(0,1fr)', gap: 16 }}>
          <div className="card card-pad stack" style={{ gap: 6, background: 'linear-gradient(135deg,#0A2444,#0056BE)', color: '#fff', border: 0 }}>
            <div style={{ fontSize: 12, opacity: .8 }}>Business wallet · {w.bank_name}</div>
            <div style={{ fontSize: 30, fontWeight: 700, letterSpacing: '.06em' }}>{w.account_number}</div>
            <div style={{ fontSize: 14, opacity: .9 }}>{w.account_name}</div>
            <div className="row" style={{ marginTop: 10 }}>
              <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,.15)', color: '#fff' }} onClick={() => navigator.clipboard?.writeText(w.account_number).then(() => toast('Copied'))}><Icon name="copy" size={14} color="#fff" />Copy</button>
              <span style={{ fontSize: 12, opacity: .8 }}>Customers can pay straight into this account. Atlas matches each payment to the customer.</span>
            </div>
          </div>
          <div className="card card-pad stack" style={{ gap: 8 }}>
            {money_ ? (
              <>
                <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">In the books</span><b className="num" style={{ fontSize: 20 }}>{N2(w.books_balance)}</b></div>
                <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">Available to pay out</span><span className="num">{N2(w.available)}</span></div>
                <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">At {d.rail?.name || 'the rail'}{w.balance_at ? ` · ${when(w.balance_at)}` : ''}</span><span className="num">{live ? N2(live.ledger) : w.provider_balance != null ? N2(w.provider_balance) : '—'}</span></div>
                <div className="row wrap" style={{ marginTop: 6 }}>
                  {d.can?.pay_out && <button className="btn btn-primary btn-sm" onClick={() => setPayout(true)}><Icon name="send" size={14} color="#fff" />Pay out</button>}
                  {d.can?.pay_out && <button className="btn btn-secondary btn-sm" onClick={() => setBulk(true)}><Icon name="list" size={14} />Bulk payment</button>}
                  <button className="btn btn-secondary btn-sm" disabled={!!busy} onClick={checkBalance}>{busy === 'balance' ? <Spinner small /> : <Icon name="refresh" size={14} />}Check with {d.rail?.code === 'flutterwave' ? 'Flutterwave' : 'the rail'}</button>
                </div>
              </>
            ) : <Alert kind="grey" icon="shield">Balances show to people who keep the books or make payments.</Alert>}
          </div>
        </div>
      )}
      <Pills value={tab} onChange={setTab} options={[
        { id: 'collections', label: 'Collections' },
        ...(money_ ? [{ id: 'payouts' as const, label: 'Payouts', count: (d?.payouts || []).filter((p: any) => p.status === 'pending_approval').length || undefined },
          { id: 'bulk' as const, label: 'Bulk payments', count: (d?.batches || []).filter((b: any) => b.status === 'pending_approval').length || undefined },
          { id: 'reconciliations' as const, label: 'Reconciliations' }] : []),
        ...(d?.can?.settings ? [{ id: 'settings' as const, label: 'Settings' }] : []),
      ]} />
      {tab === 'collections' && can(inv, 'record_sales') && inv.org.payments_open !== false && w?.status === 'active' && (
        <div><button className="btn btn-secondary btn-sm" onClick={() => setLink('new')}><Icon name="link" size={14} />Payment link</button></div>
      )}
      {link && <LinkModal draft={link === 'new' ? null : link} onClose={() => { setLink(null); void refresh(); }} />}
      {tab === 'collections' && (
        <div className="card" style={{ overflow: 'hidden' }}>
          {!(d?.requests || []).length ? <div style={{ padding: 20 }}><Empty>Payments asked for at the till, on invoices and in the online shop appear here with their status.</Empty></div> : d.requests.map((r: any) => (
            <div key={r.id} className="tr" style={{ gridTemplateColumns: 'minmax(0,1.4fr) 140px 130px 120px 130px' }}>
              <span className="ellipsis"><b>{r.customer_name || 'Customer'}</b><span className="faint" style={{ display: 'block', fontSize: 12 }}>{METHOD_LABEL[r.method]} · {r.sale_number || 'on account'} · {when(r.created_at)}{r.created_by_name ? ` · ${r.created_by_name}` : ''}</span></span>
              <span><StatusChip s={r.status} />{r.status === 'paid' && r.payer && <span className="faint" style={{ display: 'block', fontSize: 11 }}>from {r.payer}</span>}</span>
              <span className="right num">{N2(r.paid_amount || r.amount)}</span>
              <span className="right num faint">{r.fee ? `fee ${N2(r.fee)}` : ''}</span>
              <span className="faint" style={{ fontSize: 12 }}>{r.sweep_status === 'done' ? 'In the wallet' : r.sweep_status === 'sent' ? 'On its way to the wallet' : r.sweep_status === 'failed' ? 'Sweep retrying' : r.status === 'pending' && r.expires_at ? `until ${new Date(r.expires_at).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', timeZone: 'Africa/Lagos' })}` : ''}</span>
            </div>
          ))}
        </div>
      )}
      {tab === 'payouts' && (
        <div className="card" style={{ overflow: 'hidden' }}>
          {!(d?.payouts || []).length ? <div style={{ padding: 20 }}><Empty>No payouts yet.</Empty></div> : d.payouts.map((p: any) => (
            <div key={p.id} className="tr" style={{ gridTemplateColumns: 'minmax(0,1.4fr) 140px 130px auto' }}>
              <span className="ellipsis"><b>{p.account_name}</b><span className="faint" style={{ display: 'block', fontSize: 12 }}>{p.number} · {p.purpose} · {p.bank_name || p.bank_code} {p.account_number} · {p.narration}</span>
                <span className="faint" style={{ display: 'block', fontSize: 12 }}>Asked by {p.requested_by_name || '—'}{p.approved_by_name ? ` · approved by ${p.approved_by_name}` : ''} · {when(p.created_at)}{p.journal_ref ? ` · ${p.journal_ref}` : ''}</span>
                {p.error && <span style={{ display: 'block', fontSize: 12, color: '#DC2626' }}>{p.error}</span>}</span>
              <span><StatusChip s={p.status} /></span>
              <span className="right num">{N2(p.amount)}{Number(p.fee) ? <span className="faint" style={{ display: 'block', fontSize: 11 }}>+ {N2(p.fee)} fee</span> : null}</span>
              <span className="row" style={{ gap: 4 }}>
                {p.status === 'pending_approval' && d.can?.pay_out && <>
                  <button className="btn btn-primary btn-xs" onClick={() => act(() => rpc('approve_payout', { p_payout: p.id, p_approve: true }), 'Approved')}>Approve</button>
                  <button className="btn btn-ghost btn-xs" onClick={() => act(() => rpc('approve_payout', { p_payout: p.id, p_approve: false, p_note: 'Not approved' }), 'Declined')}>Decline</button></>}
                {p.status === 'approved' && d.can?.pay_out && <>
                  <button className="btn btn-primary btn-xs" onClick={() => act(() => edgeOk('payments', { action: 'send_payout', payout_id: p.id }), 'Sent. It completes when the bank confirms.')}>Send now</button>
                  <button className="btn btn-ghost btn-xs" onClick={() => act(() => rpc('cancel_payout', { p_payout: p.id }), 'Cancelled')}>Cancel</button></>}
              </span>
            </div>
          ))}
        </div>
      )}
      {tab === 'bulk' && money_ && (
        <div className="card" style={{ overflow: 'hidden' }}>
          <div className="card-hd row wrap" style={{ justifyContent: 'space-between', gap: 8 }}>
            <span className="faint" style={{ fontSize: 13, flex: '1 1 260px' }}>Pay suppliers' bills, salaries and other costs from one sheet. Every account is checked with the bank first, the batch is approved once, and each row has its own result.</span>
            <span className="row wrap" style={{ gap: 8 }}>
              <TemplateButton small />
              {d?.can?.pay_out && w?.status === 'active' && <button className="btn btn-primary btn-sm" onClick={() => setBulk(true)}><Icon name="upload" size={14} color="#fff" />Upload a bulk payment</button>}
            </span>
          </div>
          <BatchList batches={d?.batches || []} onOpen={setOpenBatch} />
        </div>
      )}
      {tab === 'reconciliations' && (
        <div className="card" style={{ overflow: 'hidden' }}>
          <div className="faint" style={{ fontSize: 12, padding: '12px 20px 0' }}>Every night Counta reads the wallet's balance and statement at the rail and compares them with the books. Sweeps on their way and payouts still processing are allowed for.</div>
          {!(d?.reconciliations || []).length ? <div style={{ padding: 20 }}><Empty>The first reconciliation runs tonight.</Empty></div> : d.reconciliations.map((r: any) => (
            <div key={r.id} className="tr" style={{ gridTemplateColumns: '170px repeat(4,minmax(0,1fr)) 120px' }}>
              <span className="muted">{when(r.at)}</span>
              <span className="num">Wallet {N2(r.provider_balance)}</span><span className="num">Books {N2(r.books_balance)}</span><span className="num faint">In transit {N2(r.in_transit)}</span>
              <span className="num" style={{ color: Math.abs(Number(r.difference)) >= 0.01 ? '#DC2626' : '#15803D' }}>{Math.abs(Number(r.difference)) < 0.01 ? 'Agrees' : `Differs by ${N2(r.difference)}`}</span>
              <span><StatusChip s={r.status === 'matched' ? 'confirmed' : 'failed'} /></span>
            </div>
          ))}
        </div>
      )}
      {tab === 'settings' && d?.can?.settings && <PaymentSettings data={d} onSaved={refresh} />}
      {payout && <PayoutModal onClose={() => setPayout(false)} />}
      {bulk && <BulkPayModal onClose={() => setBulk(false)} onCreated={(b) => { setBulk(false); setTabState('bulk'); setOpenBatch(b.id); }} />}
      {openBatch && <BatchModal id={openBatch} onClose={() => setOpenBatch(null)} />}
    </div>
  );
}

// A payment link for a customer, on their account: card, transfer or USSD on a checkout page.
function LinkModal({ draft, onClose }: { draft: Drafts['payment_link'] | null; onClose: () => void }) {
  const { orgId } = useSession();
  const customers = useCustomers();
  const [customer, setCustomer] = useState<Customer | null>(null);
  const [amount, setAmount] = useState(draft?.amount ? String(draft.amount) : '');
  const [miss, setMiss] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [req, setReq] = useState<PayRequest | null>(null);
  useEffect(() => {
    if (!draft?.customer || !customers.data || customer) return;
    const q = draft.customer.trim().toLowerCase();
    const hit = customers.data.customers.find((c) => !c.archived && !c.is_walk_in && (c.name.toLowerCase() === q || c.name.toLowerCase().includes(q)));
    if (hit) setCustomer(hit); else setMiss(draft.customer);
  }, [draft, customers.data]); // eslint-disable-line react-hooks/exhaustive-deps
  async function make() {
    const a = money(amount);
    if (!customer) { setErr('Choose who is paying.'); return; }
    if (!a || a <= 0) { setErr('Enter the amount.'); return; }
    setBusy(true); setErr(null);
    try { const r = await edgeOk<{ request: PayRequest }>('payments', { action: 'request', org_id: orgId, customer_id: customer.id, method: 'link', amount: a }); setReq(r.request); }
    catch (e) { setErr((e as Error).message); }
    setBusy(false);
  }
  if (req) return <PayWait request={req} onPaid={() => {}} onClose={onClose} />;
  return (
    <Modal onClose={onClose} width={460}>
      <ModalHead title="Payment link" sub="The customer pays by card, transfer or USSD. It lands in the wallet and on their account." onClose={onClose} />
      <div className="modal-body">
        {draft && <Alert kind="blue" icon="sparkles">Martina filled this in{draft.description ? ` for ${draft.description}` : ''}. Check it, then make the link.</Alert>}
        <Field label="Customer" req><CustomerPicker value={customer} onChange={(c) => { setCustomer(c); setMiss(null); }} walkIn={false} placeholder="Choose the customer" /></Field>
        {miss && !customer && <Alert kind="amber" icon="info">No customer called "{miss}" yet. Choose one, or add them from the box above.</Alert>}
        <Field label="Amount (₦)" req><input className="input num" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0.00" /></Field>
        {err && <Alert kind="red" icon="alert">{err}</Alert>}
      </div>
      <div className="modal-ft">
        <button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" disabled={busy} onClick={make}>{busy ? <Spinner small /> : <Icon name="link" size={14} color="#fff" />}Make the link</button>
      </div>
    </Modal>
  );
}

function PaymentSettings({ data, onSaved }: { data: any; onSaved: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const [f, setF] = useState({ payment_rail: data.rail?.code || 'flutterwave', payment_methods: data.settings?.payment_methods || ['account', 'link', 'qr'], payout_approval_threshold: String(data.settings?.payout_approval_threshold ?? 0) });
  const rail = (data.rails || []).find((r: any) => r.code === f.payment_rail);
  async function save() {
    try {
      await rpc('update_payment_settings', { p_org: orgId, p_patch: { payment_rail: f.payment_rail, payment_methods: f.payment_methods, payout_approval_threshold: money(f.payout_approval_threshold) || 0 } });
      toast('Saved'); onSaved();
    } catch (e) { toast((e as Error).message, 'err'); }
  }
  const toggle = (m: string) => setF((x) => ({ ...x, payment_methods: x.payment_methods.includes(m) ? x.payment_methods.filter((y: string) => y !== m) : [...x.payment_methods, m] }));
  return (
    <div className="card card-pad stack" style={{ gap: 14, maxWidth: 760 }}>
      <RailConnection />
      <Field label="Payment rail" hint="Flutterwave unless a partner has connected its own rail through TaxStreem. Empty the wallet before moving.">
        <select className="input" value={f.payment_rail} onChange={(e) => setF({ ...f, payment_rail: e.target.value })}>{(data.rails || []).map((r: any) => <option key={r.code} value={r.code}>{r.name}</option>)}</select>
      </Field>
      <div className="stack" style={{ gap: 6 }}>
        <div className="field-label">Ways customers can pay</div>
        {[['account', 'Pay by transfer to a one-off account number'], ['link', 'Payment link (card, transfer, USSD)'], ['qr', 'QR code']].map(([m, l]) => (
          <label key={m} className="check"><input type="checkbox" disabled={!rail?.capabilities?.includes(m)} checked={f.payment_methods.includes(m)} onChange={() => toggle(m)} />{l}{!rail?.capabilities?.includes(m) ? ' (not offered by this rail)' : ''}</label>
        ))}
      </div>
      <Field label="Payouts that need a second person (₦ and above)" hint="0 means anyone who can make payments sends them on their own. The owner's payouts never wait.">
        <input className="input" inputMode="decimal" value={f.payout_approval_threshold} onChange={(e) => setF({ ...f, payout_approval_threshold: e.target.value })} style={{ maxWidth: 220 }} />
      </Field>
      <div><button className="btn btn-primary" onClick={save}>Save</button></div>
    </div>
  );
}

// Whether the rail can reach Counta: its keys, the shared webhook secret, and the last verified event it sent.
type RailStatus = { configured: boolean; payments?: any; webhook?: { url: string; secret_set: boolean; last_event: { received_at: string; event: string; outcome: string | null } | null } };
function RailConnection() {
  const { orgId } = useSession();
  const toast = useToast();
  const q = useQuery({ queryKey: ['payments-status', orgId], queryFn: () => edge<RailStatus>('payments', { action: 'status', org_id: orgId }), staleTime: 30_000 });
  const r = q.data;
  if (q.isLoading) return <SkeletonRows n={2} />;
  if (!r || r.ok === false || !r.webhook) return null;
  const name = r.payments?.rail?.name || 'the rail';
  const wh = r.webhook;
  return (
    <div className="stack" style={{ gap: 8, paddingBottom: 14, borderBottom: '1px solid var(--line)' }}>
      <div className="field-label">Connection to {name}</div>
      <div className="row wrap" style={{ gap: 8 }}>
        <span className={'chip ' + (r.configured ? 't-green' : 't-grey')}>Keys {r.configured ? 'set' : 'missing'}</span>
        <span className={'chip ' + (wh.secret_set ? 't-green' : 't-amber')}>Webhook secret {wh.secret_set ? 'set' : 'missing'}</span>
        <span className={'chip ' + (wh.last_event ? 't-green' : 't-grey')}>{wh.last_event ? `Last heard from ${name} ${when(wh.last_event.received_at)}` : `Nothing received from ${name} yet`}</span>
      </div>
      <div className="row" style={{ gap: 8, minWidth: 0 }}>
        <code className="ellipsis" style={{ fontSize: 12, minWidth: 0, flex: 1 }}>{wh.url}</code>
        <button className="btn btn-secondary btn-sm" onClick={() => navigator.clipboard?.writeText(wh.url).then(() => toast('Copied'))}><Icon name="copy" size={14} />Copy</button>
      </div>
      <div className="muted" style={{ fontSize: 13, lineHeight: 1.5 }}>{name} sends every payment to this address. Its dashboard must use this address and the same secret hash, or payments are confirmed only by the check Counta runs every few minutes.{!wh.last_event ? ` ${name} only sends something once money moves, so this stays empty until the first payment.` : ''}</div>
    </div>
  );
}

// Withdraw to the business's bank, pay an expense, or refund a customer from the wallet.
function PayoutModal({ onClose }: { onClose: () => void }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const chart = useChart();
  const customers = useCustomers();
  const [f, setF] = useState({ purpose: 'withdrawal', amount: '', to_bank_account_id: '', bank_code: '', bank_name: '', account_number: '', account_name: '', narration: '', expense_account: '', customer_id: '' });
  const [banks, setBanks] = useState<{ code: string; name: string }[]>([]);
  const [own, setOwn] = useState<any[]>([]);
  const [resolving, setResolving] = useState(false);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    edge<{ banks: any[] }>('payments', { action: 'banks' }).then((r) => setBanks(r.banks || []));
    moneyAccounts(orgId!).then((accounts) => setOwn((accounts || []).filter((a: any) => a.kind === 'bank'))).catch(() => {});
  }, [orgId]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (!/^\d{10}$/.test(f.account_number) || !f.bank_code) return;
    setResolving(true);
    edge<{ account_name: string }>('payments', { action: 'resolve_account', account_number: f.account_number, bank_code: f.bank_code })
      .then((r) => { if (r.account_name) setF((x) => ({ ...x, account_name: r.account_name })); else if (r.error) toast(r.error, 'err'); }).finally(() => setResolving(false));
  }, [f.account_number, f.bank_code]); // eslint-disable-line react-hooks/exhaustive-deps
  const set = (k: string, v: string) => setF((x) => ({ ...x, [k]: v }));
  const expenses = (chart.data?.accounts || []).filter((a: any) => !a.is_group && a.active && /^[56]/.test(a.code));
  const creditors = (customers.data?.customers || []).filter((c) => Number(c.balance) < 0);
  async function go() {
    setBusy(true);
    try {
      const po = await rpc<any>('request_payout', { p_org: orgId, p_payout: { ...f, amount: money(f.amount), bank_name: f.bank_name || banks.find((b) => b.code === f.bank_code)?.name || null, client_uuid: crypto.randomUUID() } });
      if (po.status === 'approved') {
        const r = await edge('payments', { action: 'send_payout', payout_id: po.id });
        toast(r.ok === false ? `Saved but not sent: ${r.error}` : 'Sent. It completes when the bank confirms.', r.ok === false ? 'err' : undefined);
      } else toast('Waiting for a second person to approve it');
      await qc.invalidateQueries({ queryKey: ['payments'] }); onClose();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  return (
    <Modal onClose={onClose} width={520}>
      <ModalHead title="Pay out from the wallet" sub="Suppliers are paid from their bill (Purchases), so withholding tax is deducted and the bill is cleared." onClose={onClose} />
      <div className="modal-body">
        <Field label="What for"><select className="input" value={f.purpose} onChange={(e) => set('purpose', e.target.value)}><option value="withdrawal">Move money to our bank account</option><option value="expense">Pay an expense</option><option value="refund">Refund a customer</option></select></Field>
        {f.purpose === 'withdrawal' && <Field label="Our bank account"><select className="input" value={f.to_bank_account_id} onChange={(e) => {
          const b = own.find((x) => x.id === e.target.value);
          setF((x) => ({ ...x, to_bank_account_id: e.target.value, account_number: b?.account_number || '', account_name: b?.account_name || '', bank_name: b?.bank_name || '' }));
        }}><option value="">Choose</option>{own.map((b) => <option key={b.id} value={b.id}>{b.name}{b.account_number ? ` · ${b.account_number}` : ''}</option>)}</select></Field>}
        {f.purpose === 'expense' && <Field label="Expense account"><select className="input" value={f.expense_account} onChange={(e) => set('expense_account', e.target.value)}><option value="">Choose</option>{expenses.map((a: any) => <option key={a.code} value={a.code}>{a.code} {a.name}</option>)}</select></Field>}
        {f.purpose === 'refund' && <Field label="Customer"><select className="input" value={f.customer_id} onChange={(e) => set('customer_id', e.target.value)}><option value="">Choose</option>{creditors.map((c) => <option key={c.id} value={c.id}>{c.name} · {N2(-c.balance)} credit</option>)}</select></Field>}
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
          <Field label="Bank"><select className="input" value={f.bank_code} onChange={(e) => set('bank_code', e.target.value)}><option value="">Choose the bank</option>{banks.map((b) => <option key={b.code} value={b.code}>{b.name}</option>)}</select></Field>
          <Field label="Account number"><input className="input" inputMode="numeric" maxLength={10} value={f.account_number} onChange={(e) => set('account_number', e.target.value.replace(/\D/g, ''))} /></Field>
        </div>
        <Field label="Account name" hint={resolving ? 'Checking with the bank…' : 'Filled in from the bank. Check it is who you mean to pay.'}><input className="input" value={f.account_name} onChange={(e) => set('account_name', e.target.value)} /></Field>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
          <Field label="Amount"><input className="input" inputMode="decimal" value={f.amount} onChange={(e) => set('amount', e.target.value)} /></Field>
          <Field label="Narration"><input className="input" value={f.narration} maxLength={80} onChange={(e) => set('narration', e.target.value)} /></Field>
        </div>
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={busy || !(money(f.amount)! > 0) || !f.bank_code || !f.account_name} onClick={go}>{busy ? 'Sending…' : 'Pay out'}</button></div>
    </Modal>
  );
}

export { fmtDay };
