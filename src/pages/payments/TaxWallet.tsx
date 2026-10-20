// The tax wallet: a second account number in the business's name that holds the tax it has collected or kept back (the
// VAT on what customers pay into the business wallet, and the WHT kept back when suppliers are paid from it). Money
// leaves it only to pay tax: to the account Rev360 gives for a return TaxStreem Flux filed (FluxPayments), or to an
// account TaxStreem lists for that tax, with the payment reference from the tax office.
import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useSession, useToast } from '../../state/session';
import { rpc } from '../../lib/supabase';
import { edge } from '../../lib/api';
import { N2, when } from '../../lib/format';
import { Icon } from '../../components/Icon';
import { Alert, Empty, Field, Modal, ModalHead, SkeletonRows, Spinner } from '../../components/ui';
import { StatusChip } from '../sell/common';
import { FluxPayments, useFluxTax } from './FluxPayments';

type Due = { kind: 'vat' | 'wht' | 'wvat'; period: string; amount: number; authority?: string | null };
const TAX: Record<string, string> = { vat: 'VAT', wht: 'WHT', wvat: 'Withholding VAT', cit: 'CIT' };
const monthOf = (d: string) => new Date(d + 'T00:00:00Z').toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' });

export function useTaxWallet(orgId: string | null, on = true) {
  return useQuery({ queryKey: ['tax_wallet', orgId], enabled: Boolean(orgId) && on, queryFn: () => rpc<any>('get_tax_wallet', { p_org: orgId }) });
}

export function TaxWalletPanel() {
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const q = useTaxWallet(orgId);
  const flux = useFluxTax(orgId);
  const [busy, setBusy] = useState<string | null>(null);
  const [paying, setPaying] = useState<Due | null>(null);
  const [live, setLive] = useState<number | null>(null);
  const d = q.data;
  const t = d?.tax_wallet;
  const refresh = () => Promise.all(['tax_wallet', 'payments', 'attention'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
  async function open() {
    setBusy('open');
    const r = await edge('payments', { action: 'open_tax_wallet', org_id: orgId });
    if (r.ok === false) toast(r.reason === 'not_configured' ? 'Payments are not available yet. TaxStreem is setting them up.' : r.error || 'Could not open the tax wallet.', 'err');
    else toast('The tax wallet is open');
    await refresh(); setBusy(null);
  }
  async function check() {
    setBusy('check');
    const r = await edge<{ balance: { available: number; ledger: number }; reconciliation: any }>('payments', { action: 'tax_wallet_balance', org_id: orgId });
    if (r.ok === false) toast(r.error || 'Could not reach the tax wallet.', 'err');
    else { setLive(r.balance.ledger); toast(Math.abs(Number(r.reconciliation?.difference || 0)) < 0.01 ? 'The tax wallet agrees with the books' : `The tax wallet differs from the books by ${N2(r.reconciliation.difference)}`); }
    await refresh(); setBusy(null);
  }
  async function send(id: string) {
    setBusy(id);
    const r = await edge('payments', { action: 'send_tax_payment', payment_id: id });
    if (r.ok === false) toast(r.error || 'The payment did not go.', 'err'); else toast('Sent. It completes when the bank confirms.');
    await refresh(); setBusy(null);
  }
  if (q.isLoading) return <SkeletonRows n={4} />;
  if (q.error) return <Alert kind="grey" icon="shield">{(q.error as Error).message}</Alert>;
  if (!d) return null;
  const owed = Number(d.owed?.total || 0), held = Number(t?.books_balance || 0) + Number(d.waiting || 0);
  const short = Math.max(owed - held, 0);
  const due: Due[] = [
    ...(d.due?.vat || []).map((x: any) => ({ kind: 'vat' as const, period: x.period, amount: Number(x.payable) })),
    ...(d.due?.wht || []).map((x: any) => ({ kind: x.kind, period: x.period, amount: Number(x.amount), authority: x.authority })),
  ];
  // A return Flux filed whose payment request is open here: paid from that request, not from a listed account.
  const asked = (x: Due) => (flux.data?.instructions || []).find((i: any) => i.tax === x.kind && i.period === x.period && (x.kind !== 'wht' || x.authority === 'NRS')
    && ['received', 'needs_approval', 'paying', 'expired', 'renewing'].includes(i.status));
  if (!t || t.status !== 'active') {
    return (
      <div className="stack" style={{ gap: 16 }}>
      <FluxPayments />
      <div className="card card-pad stack" style={{ gap: 12, maxWidth: 760 }}>
        <div style={{ fontSize: 18, fontWeight: 600 }}>Open the tax wallet</div>
        <div className="muted" style={{ fontSize: 14, lineHeight: 1.6 }}>A second account number in your business&apos;s name, kept for tax. The VAT in every payment that reaches the business wallet moves into it on its own, with the WHT you keep back when you pay suppliers from the wallet. It pays only tax, to the tax offices&apos; accounts, so the money is there on the 21st.</div>
        {t?.status === 'failed' && <Alert kind="red" icon="alert">{t.error || 'The last attempt failed.'}</Alert>}
        {!d.business_wallet && <Alert kind="grey" icon="info">Open the business wallet first, above.</Alert>}
        {d.can?.open && d.business_wallet
          ? <div><button className="btn btn-primary" disabled={!!busy} onClick={open}>{busy === 'open' ? 'Opening…' : 'Open the tax wallet'}</button></div>
          : d.business_wallet && <Alert kind="grey" icon="shield">The owner or someone who keeps the books opens it.</Alert>}
      </div>
      </div>
    );
  }
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: 'minmax(0,1.2fr) minmax(0,1fr)', gap: 16 }}>
        <div className="card card-pad stack" style={{ gap: 6, background: 'linear-gradient(135deg,#14532D,#15803D)', color: '#fff', border: 0 }}>
          <div style={{ fontSize: 12, opacity: .85 }}>Tax wallet · {t.bank_name}</div>
          <div style={{ fontSize: 30, fontWeight: 700, letterSpacing: '.06em' }}>{t.account_number}</div>
          <div style={{ fontSize: 14, opacity: .9 }}>{t.account_name}</div>
          <div className="row" style={{ marginTop: 10, flexWrap: 'wrap' }}>
            <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,.15)', color: '#fff' }} onClick={() => navigator.clipboard?.writeText(t.account_number).then(() => toast('Copied'))}><Icon name="copy" size={14} color="#fff" />Copy</button>
            <span style={{ fontSize: 12, opacity: .85, flex: '1 1 220px' }}>Pays tax only. Top it up by transfer from your bank or the business wallet.</span>
          </div>
        </div>
        <div className="card card-pad stack" style={{ gap: 8 }}>
          <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">In the tax wallet</span><b className="num" style={{ fontSize: 20 }}>{N2(t.books_balance)}</b></div>
          <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">On its way from the business wallet</span><span className="num">{N2(d.waiting)}</span></div>
          <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">Tax owed in the books</span><span className="num">{N2(owed)}</span></div>
          <div className="faint" style={{ fontSize: 12 }}>VAT {N2(d.owed?.vat)} · WHT and withholding VAT {N2(d.owed?.wht)}</div>
          <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">At the rail{t.balance_at ? ` · ${when(t.balance_at)}` : ''}</span><span className="num">{live != null ? N2(live) : t.provider_balance != null ? N2(t.provider_balance) : '—'}</span></div>
          <div className="row wrap" style={{ marginTop: 4 }}>
            <button className="btn btn-secondary btn-sm" disabled={!!busy} onClick={check}>{busy === 'check' ? <Spinner small /> : <Icon name="refresh" size={14} />}Check the balance</button>
          </div>
        </div>
      </div>
      <FluxPayments />
      {short > 0.004 && (
        <Alert kind="amber" icon="info">The tax wallet holds {N2(held)} against {N2(owed)} owed. Top it up with {N2(short)}: transfer to {t.account_number} ({t.bank_name}). Tax collected into your bank accounts, not the wallet, stays there until you move it.</Alert>
      )}
      <div className="card" style={{ overflow: 'hidden' }}>
        <div className="card-hd"><b>Tax to pay</b><span className="faint" style={{ fontSize: 12, marginLeft: 8 }}>Filed VAT months and WHT deducted, not yet paid</span></div>
        {!due.length ? <div style={{ padding: 20 }}><Empty>Nothing filed is waiting to be paid. VAT shows here once its month is filed.</Empty></div> : due.map((x) => (
          <div key={`${x.kind}-${x.period}-${x.authority || ''}`} className="tr" style={{ gridTemplateColumns: 'minmax(0,1.4fr) 140px auto' }}>
            <span><b>{TAX[x.kind]}{x.authority && x.kind === 'wht' ? ` to ${x.authority}` : ''}</b><span className="faint" style={{ display: 'block', fontSize: 12 }}>{monthOf(x.period)} · due on the 21st of the next month</span></span>
            <span className="right num">{N2(x.amount)}</span>
            <span>{asked(x) ? <span className="faint" style={{ fontSize: 12 }}>Rev360 asked for it: see above</span>
              : d.can?.pay ? <button className="btn btn-primary btn-xs" onClick={() => setPaying(x)}>Pay from the tax wallet</button> : <span className="faint" style={{ fontSize: 12 }}>Paid by someone who approves payments</span>}</span>
          </div>
        ))}
      </div>
      <div className="card" style={{ overflow: 'hidden' }}>
        <div className="card-hd"><b>Tax payments</b></div>
        {!(d.payments || []).length ? <div style={{ padding: 20 }}><Empty>Tax paid from the tax wallet appears here with its reference.</Empty></div> : d.payments.map((p: any) => (
          <div key={p.id} className="tr" style={{ gridTemplateColumns: 'minmax(0,1.4fr) 120px 130px auto' }}>
            <span className="ellipsis"><b>{TAX[p.kind]} {p.kind === 'cit' ? p.period.slice(0, 4) : monthOf(p.period)}</b><span className="faint" style={{ display: 'block', fontSize: 12 }}>{p.account_name} · {p.account_number} · ref {p.tax_reference}</span>
              <span className="faint" style={{ display: 'block', fontSize: 12 }}>By {p.requested_by_name || '—'} · {when(p.created_at)}{p.journal_ref ? ` · ${p.journal_ref}` : ''}</span>
              {p.error && <span style={{ display: 'block', fontSize: 12, color: '#DC2626' }}>{p.error}</span>}</span>
            <span><StatusChip s={p.status} /></span>
            <span className="right num">{N2(p.amount)}{Number(p.fee) ? <span className="faint" style={{ display: 'block', fontSize: 11 }}>+ {N2(p.fee)} fee</span> : null}</span>
            <span>{p.status === 'approved' && d.can?.pay && <button className="btn btn-primary btn-xs" disabled={busy === p.id} onClick={() => send(p.id)}>{busy === p.id ? 'Sending…' : 'Send now'}</button>}</span>
          </div>
        ))}
      </div>
      <div className="card" style={{ overflow: 'hidden' }}>
        <div className="card-hd"><b>Moves</b><span className="faint" style={{ fontSize: 12, marginLeft: 8 }}>Set aside {N2(d.set_aside?.vat)} VAT and {N2(d.set_aside?.wht)} WHT · {N2(d.set_aside?.released)} returned to the business wallet</span></div>
        {!(d.moves || []).length ? <div style={{ padding: 20 }}><Empty>The VAT in each payment into the business wallet moves here on its own.</Empty></div> : d.moves.slice(0, 60).map((m: any) => (
          <div key={m.id} className="tr" style={{ gridTemplateColumns: 'minmax(0,1.4fr) 150px 120px' }}>
            <span className="ellipsis">{m.description}<span className="faint" style={{ display: 'block', fontSize: 12 }}>{when(m.created_at)}{m.period ? ` · ${monthOf(m.period)}` : ''}{m.error ? ` · ${m.error}` : ''}</span></span>
            <span className="faint" style={{ fontSize: 12 }}>{m.status === 'done' ? (m.direction === 'in' ? 'In the tax wallet' : 'Back in the business wallet') : m.status === 'cancelled' ? 'Not needed' : 'Waiting to move'}</span>
            <span className="right num" style={{ color: m.direction === 'out' ? '#6B7280' : undefined }}>{m.direction === 'out' ? '−' : ''}{N2(m.amount)}</span>
          </div>
        ))}
      </div>
      {paying && <PayTaxModal due={paying} payees={d.payees || []} spendable={Number(t.spendable || 0)} onClose={() => setPaying(null)} onDone={async () => { setPaying(null); await refresh(); }} />}
    </div>
  );
}

function PayTaxModal({ due, payees, spendable, onClose, onDone }: { due: Due; payees: any[]; spendable: number; onClose: () => void; onDone: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const fit = payees.filter((p) => (p.kinds || []).includes(due.kind) && (!p.authority || due.kind !== 'wht' || p.authority === due.authority));
  const [payee, setPayee] = useState<string>(fit[0]?.id || '');
  const [ref, setRef] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function go() {
    setBusy(true); setErr(null);
    try {
      const p = await rpc<any>('request_tax_payment', { p_org: orgId, p: { kind: due.kind, period: due.period, authority: due.authority || null, payee_id: payee, tax_reference: ref.trim() } });
      const s = await edge('payments', { action: 'send_tax_payment', payment_id: p.id });
      if (s.ok === false) toast(s.reason === 'not_configured' ? `Saved. ${s.error}` : s.error || 'Saved, but it did not go yet.', s.reason === 'not_configured' ? undefined : 'err');
      else toast('Sent. It completes when the bank confirms.');
      onDone();
    } catch (e) { setErr((e as Error).message); }
    setBusy(false);
  }
  return (
    <Modal onClose={onClose} width={480}>
      <ModalHead title={`Pay ${TAX[due.kind]}${due.authority && due.kind === 'wht' ? ` to ${due.authority}` : ''}`} sub={`${monthOf(due.period)} · ${N2(due.amount)}`} onClose={onClose} />
      <div className="modal-body">
        {!fit.length ? <Alert kind="amber" icon="info">TaxStreem has not listed an account for this tax yet. Pay it from your bank for now, then record it on the return.</Alert> : (
          <>
            <Field label="Pay to" hint="Only the accounts TaxStreem lists for this tax.">
              <select className="input" value={payee} onChange={(e) => setPayee(e.target.value)}>{fit.map((p) => <option key={p.id} value={p.id}>{p.name} · {p.account_number} · {p.account_name}</option>)}</select>
            </Field>
            <Field label="Payment reference" req hint="The reference the tax office gave for this payment (for example the PRN from the NRS or the state's assessment number).">
              <input className="input" value={ref} onChange={(e) => setRef(e.target.value)} maxLength={60} />
            </Field>
            {spendable + 0.004 < due.amount && <Alert kind="amber" icon="info">The tax wallet can pay {N2(spendable)}. Top it up with {N2(due.amount - spendable)} first.</Alert>}
          </>
        )}
        {err && <Alert kind="red" icon="alert">{err}</Alert>}
      </div>
      <div className="modal-ft">
        <button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        {fit.length > 0 && <button className="btn btn-primary" disabled={busy || !payee || !ref.trim()} onClick={go}>{busy ? 'Paying…' : `Pay ${N2(due.amount)}`}</button>}
      </div>
    </Modal>
  );
}
