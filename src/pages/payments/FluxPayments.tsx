// What Rev360 asks to be paid after TaxStreem Flux files a return: the payment reference (PRN), the amount and the account its
// payment page gives for that one payment. Counta pays it from the tax wallet by itself when it agrees with the return; anything
// else waits here for the owner, who pays it from the tax wallet with a tap, or by transfer from a bank and marks it paid, or
// asks Flux for a new account when the last one expired. Also the line on the VAT and WHT returns that sends them to Flux.
import { useEffect, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useSession, useToast } from '../../state/session';
import { rpc } from '../../lib/supabase';
import { edge, moneyAccounts, today } from '../../lib/api';
import { N2, when } from '../../lib/format';
import { TAX_KEYS } from '../../lib/tax';
import { Icon } from '../../components/Icon';
import { Alert, Empty, Field, Modal, ModalHead, Spinner } from '../../components/ui';

type Instruction = {
  id: string; tax: 'vat' | 'wht' | 'wvat' | 'cit'; period: string; accounting_year: number | null; prn: string; amount: number; expected: number | null;
  bank_name: string; account_number: string; account_name: string; resolved_name: string | null; expires_at: string | null; status: string; reason: string | null;
  auto: boolean; paid_outside: boolean; receipt_ref: string | null; confirmed_at: string | null; received_at: string; label: string; when: string;
  payment_status: string | null; payment_error: string | null; journal_ref: string | null; journal_id: string | null; expired: boolean; message: string | null;
  wallet_ok: boolean;
};

const STATE: Record<string, { label: string; tone: string }> = {
  received: { label: 'Checking', tone: 't-grey' }, paying: { label: 'Paying', tone: 't-amber' }, needs_approval: { label: 'Waiting for you', tone: 't-red' },
  paid: { label: 'Paid', tone: 't-green' }, confirmed: { label: 'Confirmed by Rev360', tone: 't-green' }, expired: { label: 'Account expired', tone: 't-red' },
  renewing: { label: 'New account asked for', tone: 't-amber' },
};
const RETURN_STATE: Record<string, string> = { sending: 'Being sent to Flux', send_failed: 'Not sent', sent: 'With Flux', processing: 'Flux is filing it', filed: 'Filed on Rev360', rejected: 'Sent back by Flux' };

export function useFluxTax(orgId: string | null, on = true) {
  return useQuery({ queryKey: ['flux_tax', orgId], enabled: Boolean(orgId) && on, queryFn: () => rpc<any>('get_flux_tax', { p_org: orgId }), retry: false });
}
function useRefresh() {
  const qc = useQueryClient();
  return () => Promise.all(['flux_tax', 'tax_wallet', 'payments', 'attention', ...TAX_KEYS].map((k) => qc.invalidateQueries({ queryKey: [k] })));
}
const copy = (text: string, toast: (m: string) => void) => navigator.clipboard?.writeText(text).then(() => toast('Copied'));

// The payment requests from Flux. With `taxes` (and `year` for CIT) it shows only those, and nothing at all when there are none.
export function FluxPayments({ taxes, year, period }: { taxes?: string[]; year?: number | null; period?: string }) {
  const { orgId } = useSession();
  const toast = useToast();
  const refresh = useRefresh();
  const q = useFluxTax(orgId);
  const [busy, setBusy] = useState<string | null>(null);
  const [mark, setMark] = useState<Instruction | null>(null);
  const [auto, setAuto] = useState<boolean | null>(null);
  const d = q.data;
  const all: Instruction[] = d?.instructions || [];
  const list = all.filter((i) => (!taxes || taxes.includes(i.tax)) && (year == null || i.accounting_year === year) && (!period || i.period === period));
  const filtered = Boolean(taxes || period);
  if (q.isLoading || q.error || !d) return null;
  if (filtered && !list.length) return null;
  const can = d.can || {};
  const spendable = d.tax_wallet ? Number(d.tax_wallet.spendable) : null;

  async function payNow(i: Instruction) {
    setBusy(i.id);
    try {
      const p = await rpc<any>('approve_tax_instruction', { p_id: i.id });
      const s = await edge('payments', { action: 'send_tax_payment', payment_id: p.id });
      if (s.ok === false) toast(s.reason === 'not_configured' ? `Approved. ${s.error}` : s.error || 'Approved, but it did not go yet.', s.reason === 'not_configured' ? undefined : 'err');
      else toast('Sent. It completes when the bank confirms.');
    } catch (e) { toast((e as Error).message, 'err'); }
    await refresh(); setBusy(null);
  }
  async function renew(i: Instruction) {
    setBusy(i.id);
    const r = await edge('tax-files', { action: 'flux_new_account', instruction_id: i.id });
    if (r.ok === false) toast(r.error || 'Flux did not take the request.', 'err'); else toast('Asked Flux for a new account. Counta pays it when it comes.');
    await refresh(); setBusy(null);
  }
  async function autopay(on: boolean) {
    setBusy('autopay'); setAuto(on);
    try { await rpc('set_tax_autopay', { p_org: orgId, p_on: on }); toast(on ? 'Counta pays these by itself when they agree' : 'Each one now waits for you'); }
    catch (e) { toast((e as Error).message, 'err'); setAuto(null); }
    await refresh(); setBusy(null); setAuto(null);
  }

  return (
    <div className="card" style={{ overflow: 'hidden' }}>
      <div className="card-hd row wrap" style={{ justifyContent: 'space-between', gap: 8 }}>
        <span><b>Payments Rev360 asked for</b>{!filtered && <span className="faint" style={{ fontSize: 12, marginLeft: 8 }}>From returns TaxStreem Flux filed</span>}</span>
        {!filtered && can.autopay && (
          <label className="check" style={{ fontSize: 13, alignItems: 'flex-start', maxWidth: 420 }}>
            <input type="checkbox" checked={auto ?? !!d.autopay} disabled={busy === 'autopay'} onChange={(e) => autopay(e.target.checked)} style={{ flexShrink: 0, marginTop: 2 }} />
            <span>Pay from the tax wallet by itself when the amount agrees with the return</span>
          </label>
        )}
      </div>
      {!list.length ? (
        <div style={{ padding: 20 }}><Empty>When Flux files a VAT, WHT or CIT return on Rev360, the payment it asks for comes here with its PRN and the account to pay.
          {d.autopay ? ' If it agrees with the return and the tax wallet holds enough, Counta pays it by itself.' : ''}</Empty></div>
      ) : list.map((i) => {
        const st = STATE[i.status] || { label: i.status, tone: 't-grey' };
        const open = ['received', 'needs_approval', 'expired', 'renewing'].includes(i.status);
        const differs = i.expected != null && Math.abs(Number(i.amount) - Number(i.expected)) >= 1;
        const recorded = Boolean(i.journal_id) || i.status === 'paid';
        const canRecord = can.record && !recorded && i.status !== 'paying';
        const canPay = can.approve && d.tax_wallet && i.wallet_ok && ['needs_approval', 'received'].includes(i.status) && !i.expired;
        return (
          <div key={i.id} className="tr" style={{ gridTemplateColumns: 'minmax(0,1fr)', gap: 8, alignItems: 'start' }}>
            <div className="row wrap" style={{ justifyContent: 'space-between', gap: 8 }}>
              <span><b>{i.label} · {i.when}</b> <span className={'chip ' + st.tone} style={{ marginLeft: 4 }}>{st.label}</span>
                {i.auto && ['paying', 'paid', 'confirmed'].includes(i.status) && <span className="faint" style={{ fontSize: 12, marginLeft: 6 }}>paid by Counta</span>}
                {i.paid_outside && <span className="faint" style={{ fontSize: 12, marginLeft: 6 }}>paid from a bank</span>}</span>
              <span className="num" style={{ fontWeight: 700, fontSize: 16 }}>{N2(i.amount)}</span>
            </div>
            <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: 'minmax(0,1fr) minmax(0,1fr)', gap: 8, fontSize: 13 }}>
              <div className="stack" style={{ gap: 2 }}>
                <span className="faint" style={{ fontSize: 12 }}>PRN</span>
                <span className="row" style={{ gap: 6 }}><b style={{ letterSpacing: '.03em', wordBreak: 'break-all' }}>{i.prn}</b>
                  <button className="btn btn-ghost btn-xs" aria-label="Copy the PRN" onClick={() => copy(i.prn, toast)}><Icon name="copy" size={12} /></button></span>
                {differs && !(i.reason && open) && <span style={{ fontSize: 12, color: '#B45309' }}>The return in Counta came to {N2(i.expected)}</span>}
              </div>
              <div className="stack" style={{ gap: 2 }}>
                <span className="faint" style={{ fontSize: 12 }}>Pay to</span>
                <span className="row" style={{ gap: 6 }}><b className="num" style={{ letterSpacing: '.04em' }}>{i.account_number}</b>
                  <button className="btn btn-ghost btn-xs" aria-label="Copy the account number" onClick={() => copy(i.account_number, toast)}><Icon name="copy" size={12} /></button></span>
                <span className="faint" style={{ fontSize: 12, overflowWrap: 'anywhere' }}>{i.bank_name} · {i.resolved_name || i.account_name}</span>
                {i.expires_at && open && i.status !== 'renewing' && <span style={{ fontSize: 12, color: i.expired || i.status === 'expired' ? '#DC2626' : undefined }}
                  className={i.expired || i.status === 'expired' ? undefined : 'faint'}>{i.expired || i.status === 'expired' ? 'Expired' : 'Expires'} {when(i.expires_at)}</span>}
              </div>
            </div>
            {i.reason && open && <Alert kind={i.status === 'renewing' ? 'blue' : 'amber'} icon="info">{i.reason}</Alert>}
            {i.reason && i.status === 'confirmed' && !i.journal_id && <Alert kind="amber" icon="info">{i.reason}</Alert>}
            {i.payment_status === 'failed' && i.payment_error && open && !i.reason?.includes(i.payment_error) && <Alert kind="red" icon="alert">{i.payment_error}</Alert>}
            {(i.journal_ref || i.receipt_ref) && <div className="faint" style={{ fontSize: 12 }}>{i.journal_ref ? `In the books as ${i.journal_ref}` : ''}{i.journal_ref && i.receipt_ref ? ' · ' : ''}{i.receipt_ref ? `Rev360 receipt ${i.receipt_ref}` : ''}</div>}
            {(canPay || canRecord || (can.renew && ['expired', 'needs_approval'].includes(i.status))) && (
              <div className="row wrap" style={{ gap: 6 }}>
                {canPay && <button className="btn btn-primary btn-sm" disabled={!!busy || (spendable != null && spendable + 0.004 < Number(i.amount))}
                  title={spendable != null && spendable + 0.004 < Number(i.amount) ? `The tax wallet can pay ${N2(spendable)}` : undefined}
                  onClick={() => payNow(i)}>{busy === i.id ? <Spinner small /> : <Icon name="send" size={14} color="#fff" />}Pay {N2(i.amount)} from the tax wallet</button>}
                {canRecord && <button className="btn btn-secondary btn-sm" disabled={!!busy} onClick={() => setMark(i)}><Icon name="check" size={14} />I paid it from a bank</button>}
                {can.renew && ['expired', 'needs_approval'].includes(i.status) && <button className="btn btn-ghost btn-sm" disabled={!!busy} onClick={() => renew(i)}>
                  {busy === i.id ? <Spinner small /> : <Icon name="refresh" size={14} />}Ask Flux for a new account</button>}
              </div>
            )}
          </div>
        );
      })}
      {!filtered && spendable != null && list.some((i) => ['needs_approval', 'received'].includes(i.status) && Number(i.amount) > spendable + 0.004) && (
        <div style={{ padding: '0 20px 16px' }}><Alert kind="grey" icon="info">The tax wallet can pay {N2(spendable)}. To pay more from it, top it up by transfer to {d.tax_wallet.account_number} ({d.tax_wallet.bank_name}).</Alert></div>
      )}
      {mark && <MarkPaid i={mark} onClose={() => setMark(null)} onDone={async () => { setMark(null); await refresh(); }} />}
    </div>
  );
}

function MarkPaid({ i, onClose, onDone }: { i: Instruction; onClose: () => void; onDone: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const [accounts, setAccounts] = useState<any[]>([]);
  const [f, setF] = useState({ bank_account_id: '', paid_at: today() });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => { if (orgId) moneyAccounts(orgId).then((a) => setAccounts((a || []).filter((x: any) => x.kind !== 'cash'))).catch(() => {}); }, [orgId]);
  async function go() {
    setBusy(true); setErr(null);
    try {
      const r = await rpc<any>('mark_tax_instruction_paid', { p_id: i.id, p: { bank_account_id: f.bank_account_id, paid_at: f.paid_at + 'T12:00:00+01:00' } });
      toast(`Recorded${r.journal_ref ? ` as ${r.journal_ref}` : ''}`);
      onDone();
    } catch (e) { setErr((e as Error).message); }
    setBusy(false);
  }
  return (
    <Modal onClose={onClose} width={460}>
      <ModalHead title={`${i.label} paid from a bank`} sub={`${i.when} · PRN ${i.prn} · ${N2(i.amount)}`} onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 10 }}>
        <div className="muted" style={{ fontSize: 13, lineHeight: 1.5 }}>For a transfer you made yourself to {i.account_number} ({i.bank_name}). Counta books it from the account you choose and marks the return paid.</div>
        <Field label="Paid from"><select className="input" value={f.bank_account_id} onChange={(e) => setF({ ...f, bank_account_id: e.target.value })}>
          <option value="">Choose</option>{accounts.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}</select></Field>
        <Field label="Paid on"><input className="input" type="date" max={today()} value={f.paid_at} onChange={(e) => setF({ ...f, paid_at: e.target.value })} /></Field>
        {err && <Alert kind="red" icon="alert">{err}</Alert>}
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" disabled={busy || !f.bank_account_id} onClick={go}>{busy ? 'Recording…' : 'Record payment'}</button></div>
    </Modal>
  );
}

// On a month's VAT return or NRS withholding schedule: where it stands with Flux, and the button that sends it.
export function FluxSend({ tax, period, ready, notReady }: { tax: 'vat' | 'wht' | 'wvat'; period: string; ready: boolean; notReady?: string }) {
  const { orgId } = useSession();
  const toast = useToast();
  const refresh = useRefresh();
  const q = useFluxTax(orgId);
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  if (q.isLoading || q.error || !q.data) return null;
  const r = (q.data.returns || []).find((x: any) => x.tax === tax && String(x.period).slice(0, 7) === period.slice(0, 7) && x.authority === 'NRS');
  const can = q.data.can || {};
  const locked = r && (['sent', 'processing', 'filed'].includes(r.status) || (r.status === 'sending' && Date.now() - Date.parse(r.updated_at) < 5 * 60_000));
  async function send() {
    setBusy(true); setNote(null);
    const x = await edge<any>('tax-files', { action: 'flux_send', org_id: orgId, tax, period: period.slice(0, 7) });
    if (x.ok === false) { if (x.reason === 'not_configured') setNote(x.error); else toast(x.error || 'Flux did not take it.', 'err'); }
    else toast(`Sent to TaxStreem Flux${x.flux_ref ? ` (${x.flux_ref})` : ''}`);
    await refresh(); setBusy(false);
  }
  const text = r && `${RETURN_STATE[r.status] || r.status}${r.status === 'filed' && r.acknowledgement_ref ? ` · acknowledgement ${r.acknowledgement_ref}` : ''}${r.flux_ref && r.status !== 'filed' ? ` (${r.flux_ref})` : ''}${r.sent_at ? ` · sent ${when(r.sent_at)}${r.sent_by_name ? ` by ${r.sent_by_name}` : ''}` : ''}${r.message && r.status !== 'filed' ? ` · ${r.message}` : ''}`;
  return (
    <div className="card card-pad stack" style={{ gap: 8 }}>
      <div className="row wrap" style={{ justifyContent: 'space-between', gap: 8 }}>
        <span style={{ fontSize: 13 }}><b>TaxStreem Flux</b><span className="muted" style={{ display: 'block', fontSize: 12, lineHeight: 1.5 }}>Flux files it on Rev360, then the payment Rev360 asks for comes to Payments, Tax wallet.</span></span>
        {can.send && !locked && <button className="btn btn-primary btn-sm" disabled={busy || !ready} title={!ready ? notReady : undefined} onClick={send}>
          {busy ? <Spinner small /> : <Icon name="send" size={14} color="#fff" />}{r && ['send_failed', 'rejected'].includes(r.status) ? 'Send again' : 'Send to Flux'}</button>}
      </div>
      {!ready && notReady && !r && <div className="faint" style={{ fontSize: 12 }}>{notReady}</div>}
      {text && <Alert kind={r.status === 'filed' ? 'green' : ['send_failed', 'rejected'].includes(r.status) ? 'red' : 'blue'} icon={r.status === 'filed' ? 'check' : 'send'}>{text}</Alert>}
      {note && <Alert kind="blue" icon="info">{note}</Alert>}
    </div>
  );
}
