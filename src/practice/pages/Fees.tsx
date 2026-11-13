// Fees: the firm bills its clients from its own Counta business (the firm business), an ordinary business with its own
// identity check, business wallet and tax wallet. Each client gets a customer there; fee invoices and retainers on a
// schedule are made in the firm business (the buttons switch Counta to it). For a client the firm runs under full mandate,
// each fee invoice is also posted as a bill in the client's own books: this page shows each such bill and lets a lead try a
// failed one again, or a partner give up on one that can never be posted. A credit note on such an invoice waits here
// until a lead confirms it into the client's books (as the firm's credit note against the bill), or a partner leaves it out.
import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc } from '../../lib/supabase';
import { N2, fmtDay } from '../../lib/format';
import { useSession, useToast } from '../../state/session';
import { Icon } from '../../components/Icon';
import { Alert, Field, SkeletonRows, Spinner } from '../../components/ui';
import { Card, PageHead } from '../../admin/ui';
import { type FeeBillStatus, type FeeCredit, type PracticeFees, usePracticeFees, usePracticeHome } from '../api';

type Client = PracticeFees['clients'][number];
const FREQ = { monthly: 'Monthly', quarterly: 'Every three months', annually: 'Every year' } as const;
const ord = (n: number) => `${n}${n % 10 === 1 && n !== 11 ? 'st' : n % 10 === 2 && n !== 12 ? 'nd' : n % 10 === 3 && n !== 13 ? 'rd' : 'th'}`;
const BILL: Record<FeeBillStatus, [string, string]> = {
  posted: ['Posted in the client\'s books', 't-green'], failed: ['Not posted', 't-red'], voided: ['Voided with the invoice', 't-grey'],
  skipped: ['Not posted: the engagement had ended', 't-grey'], dismissed: ['Dismissed', 't-grey'],
};
const CREDIT: Record<FeeCredit['status'], [string, string]> = {
  pending: ['Waiting to be confirmed', 't-amber'], posted: ['In the client\'s books', 't-green'], dismissed: ['Left out of the books', 't-grey'],
};
const INV: Record<string, [string, string]> = {
  open: ['Unpaid', 't-amber'], partially_paid: ['Part paid', 't-amber'], paid: ['Paid', 't-green'], void: ['Void', 't-grey'], draft: ['Draft', 't-grey'], credited: ['Credited', 't-grey'],
};

export default function Fees({ pid }: { pid: string }) {
  const q = usePracticeFees(pid);
  const home = usePracticeHome(pid);
  const { memberships } = useSession();
  const d = q.data;
  if (q.isLoading) return <SkeletonRows n={6} />;
  if (q.isError || !d) return <Alert kind="red" icon="alert">{q.isError ? cleanError(q.error) : 'Not found.'}</Alert>;
  const partner = home.data?.me.role === 'partner';
  const firm = d.firm_org;
  // Raising invoices happens inside the firm business, so only its own people can go there.
  const inFirm = !!firm && memberships.some((m) => m.org_id === firm.id);
  const owed = d.clients.reduce((t, c) => t + Number(c.outstanding || 0), 0);
  const waiting = d.clients.reduce((t, c) => t + (c.fee_credits || []).filter((k) => k.status === 'pending').length, 0);
  return (
    <>
      <PageHead title="Fees" sub="Bill clients from the firm's own Counta business: fee invoices, retainers on a schedule, and the money they pay into its wallet." />
      {!firm ? <FirmSetup pid={pid} partner={partner} practiceName={home.data?.practice.name || ''} /> : (
        <>
          {waiting > 0 && (
            <div data-testid="fees-credits-waiting">
              <Alert kind="amber" icon="alert">
                {waiting === 1 ? 'A credit note on a fee invoice waits' : `${waiting} credit notes on fee invoices wait`} to be confirmed before {waiting === 1 ? 'it goes' : 'they go'} into
                your client's books. Open the client below to confirm or dismiss {waiting === 1 ? 'it' : 'them'}.
              </Alert>
            </div>
          )}
          {!['verified', 'approved', 'not_required'].includes(firm.identity_status) && (
            <div data-testid="fees-firm-identity">
              <Alert kind="amber" icon="lock">
                Verify the firm business's identity before fee invoices can be paid online.
                {inFirm && <div style={{ marginTop: 8 }}><GoTo org={firm.id} to="/settings#identity" label="Verify it" icon="shield" /></div>}
              </Alert>
            </div>
          )}
          <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: d.wallets ? 'minmax(0,1.2fr) minmax(0,1fr)' : 'minmax(0,1fr)', gap: 16, alignItems: 'start' }}>
            <Card title={firm.name} sub={inFirm ? 'The firm business. Fee invoices and retainers are made there.' : `The firm business. Ask the partner who set it up to add you to ${firm.name} to raise fee invoices.`}>
              <div className="row wrap" style={{ gap: 16, alignItems: 'baseline' }}>
                <span style={{ fontSize: 13 }} className="muted">Owed by clients</span>
                <b className="num" style={{ fontSize: 22 }}>{N2(owed)}</b>
              </div>
              {inFirm && <div className="row wrap" style={{ gap: 8 }}>
                <GoTo org={firm.id} to="/sell/sales?new=invoice" label="New fee invoice" icon="plus" primary />
                <GoTo org={firm.id} to="/sell/recurring" label="Recurring invoices" icon="refresh" />
              </div>}
            </Card>
            {d.wallets && (
              <section className="card card-pad stack" style={{ gap: 10 }} data-testid="fees-wallets" aria-label="Wallets">
                <b style={{ fontSize: 15 }}>Wallets</b>
                {([['Business wallet', d.wallets.wallet], ['Tax wallet', d.wallets.tax_wallet]] as const).map(([l, w]) => (
                  <div key={l} className="row" style={{ justifyContent: 'space-between', gap: 8, fontSize: 14 }}>
                    <span>{l}{!w.status ? <span className="faint"> · not opened</span> : w.status !== 'active' ? <span className="faint"> · {w.status}</span> : null}</span>
                    <b className="num">{N2(Number(w.balance || 0))}</b>
                  </div>
                ))}
                <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }}>Fees paid online land in the business wallet; the VAT on them moves to the tax wallet. Balances as the firm business's books have them.</div>
                {inFirm && <div><GoTo org={firm.id} to="/payments" label="Open payments" icon="card" /></div>}
              </section>
            )}
          </div>
          <Card title="Clients" pad={false}>
            {!d.clients.length ? <div className="card-pad faint">No clients to bill yet.</div> : d.clients.map((c) => (
              <ClientFees key={c.client_id} pid={pid} c={c} firmId={firm.id} inFirm={inFirm} partner={partner} />
            ))}
          </Card>
        </>
      )}
    </>
  );
}

// Switches Counta to the firm business and opens a screen there.
function GoTo({ org, to, label, icon, primary }: { org: string; to: string; label: string; icon: string; primary?: boolean }) {
  const { setOrgId } = useSession();
  const nav = useNavigate();
  return (
    <button type="button" className={'btn btn-sm ' + (primary ? 'btn-primary' : 'btn-secondary')} style={{ minHeight: 40 }} onClick={() => { setOrgId(org); nav(to); }}>
      <Icon name={icon} size={14} color={primary ? '#fff' : undefined} />{label}
    </button>
  );
}

// No firm business yet: a partner creates one, or links a business they own.
function FirmSetup({ pid, partner, practiceName }: { pid: string; partner: boolean; practiceName: string }) {
  const qc = useQueryClient();
  const toast = useToast();
  const { memberships, refreshMemberships } = useSession();
  const owned = memberships.filter((m) => m.role === 'owner' && !m.is_sample);
  const [mode, setMode] = useState<'create' | 'link'>(owned.length ? 'link' : 'create');
  const [f, setF] = useState({ name: practiceName, email: '', org: owned[0]?.org_id || '' });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function go() {
    setErr(null); setBusy(true);
    try {
      await rpc('practice_firm_business', { p_practice: pid, p: mode === 'link' ? { org_id: f.org } : { name: f.name.trim(), ...(f.email.trim() ? { email: f.email.trim() } : {}) } });
      await refreshMemberships().catch(() => []);
      await qc.invalidateQueries({ queryKey: ['practice-fees', pid] });
      toast('The firm business is set up');
    } catch (e) { setErr(cleanError(e)); }
    setBusy(false);
  }
  return (
    <Card title="Set up the firm business" sub="Fee invoices are issued from the firm's own Counta business, with its own business wallet and tax wallet. Its identity is checked like any business's before it takes payments online.">
      <div data-testid="fees-firm-setup" className="stack" style={{ gap: 12 }}>
        {!partner ? <div className="muted" style={{ fontSize: 14 }}>A partner sets it up.</div> : (
          <>
            {owned.length > 0 && (
              <div className="row wrap" role="radiogroup" aria-label="How" style={{ gap: 8 }}>
                <button type="button" role="radio" aria-checked={mode === 'link'} className={'btn btn-sm ' + (mode === 'link' ? 'btn-primary' : 'btn-secondary')} onClick={() => setMode('link')}>Use a business I own</button>
                <button type="button" role="radio" aria-checked={mode === 'create'} className={'btn btn-sm ' + (mode === 'create' ? 'btn-primary' : 'btn-secondary')} onClick={() => setMode('create')}>Create a new one</button>
              </div>
            )}
            {mode === 'link' ? (
              <Field label="The firm's business" hint="One you own. Not a client's business." style={{ maxWidth: 420 }}>
                <select className="input" value={f.org} onChange={(e) => setF({ ...f, org: e.target.value })}>{owned.map((m) => <option key={m.org_id} value={m.org_id}>{m.name}</option>)}</select>
              </Field>
            ) : (
              <div className="row wrap" style={{ gap: 8 }}>
                <Field label="Business name" style={{ flex: '2 1 260px' }}><input className="input" value={f.name} maxLength={120} onChange={(e) => setF({ ...f, name: e.target.value })} /></Field>
                <Field label="Its email (optional)" hint="Yours if left empty." style={{ flex: '1 1 220px' }}><input className="input" type="email" value={f.email} maxLength={254} onChange={(e) => setF({ ...f, email: e.target.value })} /></Field>
              </div>
            )}
            {err && <Alert kind="red" icon="alert"><span role="alert">{err}</span></Alert>}
            <div>
              {mode === 'link'
                ? <button className="btn btn-primary btn-sm" style={{ minHeight: 40 }} disabled={busy || !f.org} onClick={go} data-testid="fees-firm-link">{busy ? <Spinner small /> : null}Use this business</button>
                : <button className="btn btn-primary btn-sm" style={{ minHeight: 40 }} disabled={busy || f.name.trim().length < 2} onClick={go} data-testid="fees-firm-create">{busy ? <Spinner small /> : null}Create the firm business</button>}
            </div>
          </>
        )}
      </div>
    </Card>
  );
}

function ClientFees({ pid, c, firmId, inFirm, partner }: { pid: string; c: Client; firmId: string; inFirm: boolean; partner: boolean }) {
  const qc = useQueryClient();
  const toast = useToast();
  const { setOrgId } = useSession();
  const nav = useNavigate();
  const [busy, setBusy] = useState<string | null>(null);
  const [dismiss, setDismiss] = useState<{ id: string; reason: string } | null>(null);
  const refresh = () => qc.invalidateQueries({ queryKey: ['practice-fees', pid] });
  const failed = c.fee_bills.filter((b) => b.status === 'failed').length;
  const credits = c.fee_credits || [];
  const waiting = credits.filter((k) => k.status === 'pending').length;
  const number = (sale: string) => c.invoices.find((i) => i.id === sale)?.number || 'Fee invoice';
  // What was credited on a bill's invoice beyond the credit notes posted against the bill.
  const unposted = (bill: string, credited: number) => credited - credits.filter((k) => k.fee_bill_id === bill && k.status === 'posted').reduce((t, k) => t + Number(k.amount), 0);
  async function customer(): Promise<string | null> {
    if (c.fee_customer_id) return c.fee_customer_id;
    setBusy('customer');
    try {
      const r = await rpc<{ customer_id: string }>('practice_fee_customer', { p_client: c.client_id, p: {} });
      await refresh();
      return r.customer_id;
    } catch (e) { toast(cleanError(e), 'err'); return null; } finally { setBusy(null); }
  }
  async function schedule() {
    const id = await customer();
    if (!id) return;
    setOrgId(firmId);
    nav(`/sell/recurring?customer=${id}&client=${c.client_id}`);
  }
  async function retry(id: string) {
    setBusy(id);
    try {
      const r = await rpc<{ status: FeeBillStatus; error: string | null }>('practice_fee_bill_retry', { p_id: id });
      await refresh();
      toast(r.status === 'posted' ? 'Posted in the client\'s books' : `Still not posted: ${r.error || 'try again later.'}`, r.status === 'posted' ? undefined : 'err');
    } catch (e) { toast(cleanError(e), 'err'); }
    setBusy(null);
  }
  async function dismissIt() {
    if (!dismiss) return;
    setBusy(dismiss.id);
    try { await rpc('practice_fee_bill_dismiss', { p_id: dismiss.id, p_reason: dismiss.reason.trim() }); setDismiss(null); await refresh(); toast('Dismissed'); }
    catch (e) { toast(cleanError(e), 'err'); }
    setBusy(null);
  }
  return (
    <details className="fee-row" data-testid="fees-client-row" open={waiting > 0 || undefined}>
      <summary className="fee-sum">
        <span style={{ minWidth: 0 }}>
          <b>{c.business_name}</b>
          <span className="faint" style={{ display: 'block', fontSize: 12 }}>
            {c.mode === 'full' ? 'Full mandate' : 'Involved'} · {c.invoices.length} {c.invoices.length === 1 ? 'invoice' : 'invoices'}
            {c.schedules.filter((s) => s.status === 'active').length ? ` · ${c.schedules.filter((s) => s.status === 'active').length} on a schedule` : ''}
          </span>
        </span>
        <span className="row wrap" style={{ gap: 8, justifyContent: 'flex-end', alignItems: 'center' }}>
          {failed > 0 && <span className="chip t-red">{failed} bill{failed === 1 ? '' : 's'} not posted</span>}
          {waiting > 0 && <span className="chip t-amber" data-testid="fees-credits-chip">{waiting} credit note{waiting === 1 ? '' : 's'} to confirm</span>}
          <span className="num" data-testid="fees-outstanding">{Number(c.outstanding) > 0 ? <b>{N2(Number(c.outstanding))}</b> : <span className="faint">Nothing owed</span>}</span>
          <span className="fee-chev" aria-hidden="true" style={{ display: 'inline-flex' }}><Icon name="chevron" size={14} /></span>
        </span>
      </summary>
      <div className="stack" style={{ gap: 14, padding: '4px 16px 16px' }}>
        <div className="row wrap" style={{ gap: 8, alignItems: 'center' }} data-testid="fees-customer">
          {c.fee_customer_id ? <span className="chip t-green">A customer in the firm business</span>
            : <button type="button" className="btn btn-secondary btn-sm" disabled={busy !== null} onClick={() => void customer()}>{busy === 'customer' ? <Spinner small /> : <Icon name="plus" size={14} />}Set up as a customer</button>}
          {inFirm && <button type="button" className="btn btn-secondary btn-sm" disabled={busy !== null} onClick={schedule} data-testid="fees-schedule-new"><Icon name="refresh" size={14} />New retainer</button>}
        </div>
        {c.schedules.length > 0 && (
          <div className="stack" style={{ gap: 6 }}>
            <div className="label">Retainers</div>
            {c.schedules.map((s) => (
              <div key={s.id} className="row wrap" style={{ gap: 8, justifyContent: 'space-between', fontSize: 14 }} data-testid="fees-schedule-row">
                <span>{s.frequency === 'annually' ? `Every year on ${s.day_of_month}` : `${FREQ[s.frequency]} on the ${ord(s.day_of_month)}`}{s.status !== 'ended' ? <span className="faint"> · next {fmtDay(s.next_run)}</span> : null}</span>
                <span className="row" style={{ gap: 8 }}><b className="num">{N2(Number(s.total))}</b><span className={'chip ' + (s.status === 'active' ? 't-green' : s.status === 'paused' ? 't-amber' : 't-grey')}>{s.status === 'active' ? 'Active' : s.status === 'paused' ? 'Paused' : 'Ended'}</span></span>
              </div>
            ))}
          </div>
        )}
        {c.invoices.length > 0 && (
          <div className="stack" style={{ gap: 6 }}>
            <div className="label">Fee invoices</div>
            <div className="card" style={{ overflow: 'hidden' }}>
              {c.invoices.slice(0, 12).map((i) => {
                const [label, tone] = INV[i.status] || [i.status, 't-grey'];
                return (
                  <div key={i.id} className="tr rsp" style={{ gridTemplateColumns: 'minmax(0,1fr) 110px 130px 110px' }}>
                    <span className="m-main">{i.number} <span className="faint">· {fmtDay(i.issue_date)}</span>{Number(i.credited) > 0 && <span className="faint" style={{ display: 'block', fontSize: 12 }}>{N2(Number(i.credited))} credited</span>}</span>
                    <span className="right num">{N2(Number(i.total))}</span>
                    <span className="right num">{Number(i.balance) > 0 ? `${N2(Number(i.balance))} due` : ''}</span>
                    <span className="right"><span className={'chip ' + tone}>{label}</span></span>
                  </div>
                );
              })}
            </div>
            {c.invoices.length > 12 && <div className="faint" style={{ fontSize: 12 }}>The latest 12 of {c.invoices.length}. The rest are in the firm business's invoices.</div>}
          </div>
        )}
        {c.fee_bills.length > 0 && (
          <div className="stack" style={{ gap: 6 }}>
            <div className="label">Bills in the client's books</div>
            {c.fee_bills.map((b) => {
              const [label, tone] = BILL[b.status];
              return (
                <div key={b.id} className="stack" style={{ gap: 4, fontSize: 14, borderTop: '1px solid var(--row)', paddingTop: 8 }}>
                  <div className="row wrap" style={{ gap: 8, justifyContent: 'space-between', alignItems: 'center' }}>
                    <span>{number(b.sale_id)}</span>
                    <span className={'chip ' + tone} data-testid="fee-bill-status">{label}</span>
                  </div>
                  {b.status === 'failed' && b.error && <div className="faint" style={{ fontSize: 12 }}>{b.error}</div>}
                  {b.status === 'dismissed' && b.dismiss_reason && <div className="faint" style={{ fontSize: 12 }}>Dismissed: {b.dismiss_reason}</div>}
                  {b.note === 'a credit note waits to be confirmed for the bill'
                    ? <div className="faint" style={{ fontSize: 12 }}>A credit note on this invoice waits to be confirmed (below).</div>
                    : b.note && <div className="faint" style={{ fontSize: 12 }}>{N2(unposted(b.id, Number(b.credited)))} credited on the invoice, not on the bill. Adjust the client's bill by hand.</div>}
                  {b.status === 'failed' && (
                    dismiss?.id === b.id ? (
                      <div className="row wrap" style={{ gap: 8, alignItems: 'flex-end' }}>
                        <Field label="Why it can never be posted" style={{ flex: '1 1 260px' }}>
                          <input className="input input-sm" value={dismiss.reason} maxLength={500} onChange={(e) => setDismiss({ id: b.id, reason: e.target.value })} />
                        </Field>
                        <button type="button" className="btn btn-danger btn-sm" disabled={busy !== null || dismiss.reason.trim().length < 5} onClick={dismissIt}>Dismiss it</button>
                        <button type="button" className="btn btn-ghost btn-sm" onClick={() => setDismiss(null)}>Cancel</button>
                      </div>
                    ) : (
                      <div className="row wrap" style={{ gap: 8 }}>
                        <button type="button" className="btn btn-secondary btn-sm" disabled={busy !== null} onClick={() => retry(b.id)} data-testid="fee-bill-retry">
                          {busy === b.id ? <Spinner small /> : <Icon name="refresh" size={14} />}Try again
                        </button>
                        {partner && <button type="button" className="btn btn-ghost btn-sm" disabled={busy !== null} onClick={() => setDismiss({ id: b.id, reason: '' })}>Dismiss</button>}
                      </div>
                    )
                  )}
                </div>
              );
            })}
          </div>
        )}
        {credits.length > 0 && <Credits pid={pid} credits={credits} partner={partner} />}
      </div>
    </details>
  );
}

// Credit notes on the client's fee invoices whose bills are in its books: waiting first. A lead confirms one into the
// client's books (the firm's credit note against the bill); a partner can leave one out, with a reason.
function Credits({ pid, credits, partner }: { pid: string; credits: FeeCredit[]; partner: boolean }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [busy, setBusy] = useState<string | null>(null);
  const [dismiss, setDismiss] = useState<{ id: string; reason: string } | null>(null);
  const refresh = () => qc.invalidateQueries({ queryKey: ['practice-fees', pid] });
  async function confirm(id: string) {
    setBusy(id);
    try {
      const r = await rpc<{ ok: boolean; error?: string }>('practice_fee_credit_confirm', { p_id: id, p_note: null });
      await refresh();
      if (r.ok) toast('Recorded in the client\'s books');
      else toast(`Not recorded: ${r.error || 'try again later.'}`, 'err');
    } catch (e) { toast(cleanError(e), 'err'); }
    setBusy(null);
  }
  async function dismissIt() {
    if (!dismiss) return;
    setBusy(dismiss.id);
    try { await rpc('practice_fee_credit_dismiss', { p_id: dismiss.id, p_reason: dismiss.reason.trim() }); setDismiss(null); await refresh(); toast('Left out of the books'); }
    catch (e) { toast(cleanError(e), 'err'); }
    setBusy(null);
  }
  return (
    <div className="stack" style={{ gap: 6 }} data-testid="fee-credits">
      <div className="label">Credit notes on fee invoices</div>
      <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }}>Each waits for you before it goes into the client's books, where it is recorded as your firm's credit note against the bill.</div>
      {credits.map((k) => {
        const [label, tone] = CREDIT[k.status];
        return (
          <div key={k.id} className="stack" style={{ gap: 4, fontSize: 14, borderTop: '1px solid var(--row)', paddingTop: 8 }} data-testid="fee-credit-row">
            <div className="row wrap" style={{ gap: 8, justifyContent: 'space-between', alignItems: 'center' }}>
              <span>{k.credit_note} <span className="faint">on {k.invoice} · {fmtDay(k.issue_date)}</span></span>
              <span className="row" style={{ gap: 8 }}><b className="num">{N2(Number(k.amount))}</b><span className={'chip ' + tone} data-testid="fee-credit-status">{label}</span></span>
            </div>
            {k.status === 'pending' && k.error && <div className="faint" style={{ fontSize: 12 }}>Last try: {k.error}</div>}
            {k.status === 'posted' && <div className="faint" style={{ fontSize: 12 }}>Confirmed{k.decided_by_name ? ` by ${k.decided_by_name}` : ''}{k.decided_at ? ` on ${fmtDay(k.decided_at)}` : ''}.</div>}
            {k.status === 'dismissed' && <div className="faint" style={{ fontSize: 12 }}>Left out{k.decided_by_name ? ` by ${k.decided_by_name}` : ''}: {k.note}</div>}
            {k.status === 'pending' && (
              dismiss?.id === k.id ? (
                <div className="row wrap" style={{ gap: 8, alignItems: 'flex-end' }}>
                  <Field label="Why it stays out of the client's books" style={{ flex: '1 1 260px' }}>
                    <input className="input input-sm" data-testid="fee-credit-reason" value={dismiss.reason} maxLength={500} onChange={(e) => setDismiss({ id: k.id, reason: e.target.value })} />
                  </Field>
                  <button type="button" className="btn btn-danger btn-sm" disabled={busy !== null || dismiss.reason.trim().length < 5} onClick={dismissIt}>Leave it out</button>
                  <button type="button" className="btn btn-ghost btn-sm" onClick={() => setDismiss(null)}>Cancel</button>
                </div>
              ) : (
                <div className="row wrap" style={{ gap: 8 }}>
                  <button type="button" className="btn btn-primary btn-sm" style={{ minHeight: 40 }} disabled={busy !== null} onClick={() => confirm(k.id)} data-testid="fee-credit-confirm">
                    {busy === k.id ? <Spinner small /> : <Icon name="check" size={14} color="#fff" />}Confirm into their books
                  </button>
                  {partner && <button type="button" className="btn btn-ghost btn-sm" style={{ minHeight: 40 }} disabled={busy !== null} onClick={() => setDismiss({ id: k.id, reason: '' })} data-testid="fee-credit-dismiss">Dismiss</button>}
                </div>
              )
            )}
          </div>
        );
      })}
    </div>
  );
}
