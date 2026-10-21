// Paying for clients' Counta plans with the practice's own card. The first payment goes through Flutterwave's page, which
// keeps the card for renewals; the client's owner sees that the practice pays.
import { useEffect, useRef, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc } from '../../lib/supabase';
import { edge } from '../../lib/api';
import { N2, fmtDay, when } from '../../lib/format';
import { useToast } from '../../state/session';
import { Icon } from '../../components/Icon';
import { Alert, SkeletonRows, Spinner } from '../../components/ui';
import { Card, PageHead } from '../../admin/ui';
import { type Plan, usePracticeBilling } from '../api';

export function StartPaying({ clientId, name, plans }: { clientId: string; name: string; plans: Plan[] }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [plan, setPlan] = useState(plans[0]?.id || '');
  const [cycle, setCycle] = useState<'month' | 'year'>('month');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const p = plans.find((x) => x.id === plan);
  const price = p ? (cycle === 'year' ? Number(p.price_year ?? p.price_month * 12) : Number(p.price_month)) : 0;
  async function pay() {
    setBusy(true); setErr(null);
    const r = await edge<any>('payments', { action: 'practice_plan_start', client_id: clientId, plan_id: plan, billing: cycle });
    if (r.ok === false) { setErr(r.error || 'The payment did not start.'); setBusy(false); return; }
    if (r.action === 'checkout' && r.link) { window.location.href = r.link; return; }
    await Promise.all(['practice-client', 'practice-billing', 'practice-home'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
    toast(r.result?.status === 'successful' ? `Paid with your saved card. ${name} is on ${p?.name}.` : 'The card payment is being confirmed.', r.result?.status === 'failed' ? 'err' : undefined);
    setBusy(false);
  }
  if (!plans.length) return <div className="faint" style={{ fontSize: 13 }}>No paid plans are offered at the moment.</div>;
  return (
    <div className="stack" style={{ gap: 8 }} data-testid="start-paying">
      <div className="row wrap" style={{ gap: 8 }}>
        <select className="input input-sm" style={{ width: 'auto' }} value={plan} onChange={(e) => setPlan(e.target.value)} aria-label="Plan">
          {plans.map((x) => <option key={x.id} value={x.id}>{x.name} · {N2(x.price_month)} a month</option>)}
        </select>
        <select className="input input-sm" style={{ width: 'auto' }} value={cycle} onChange={(e) => setCycle(e.target.value as 'month' | 'year')} aria-label="How often">
          <option value="month">Monthly</option>{p?.price_year != null && <option value="year">Yearly</option>}
        </select>
        <button className="btn btn-primary btn-sm" disabled={busy || !plan} onClick={pay}>{busy ? <Spinner small /> : <Icon name="card" size={14} color="#fff" />}Pay {N2(price)} for {name}</button>
      </div>
      {err && <Alert kind="red" icon="alert">{err}</Alert>}
    </div>
  );
}

export default function BillingPage({ pid }: { pid: string }) {
  const q = usePracticeBilling(pid);
  const qc = useQueryClient();
  const toast = useToast();
  const [params, setParams] = useSearchParams();
  const ref = params.get('ref');
  const checked = useRef(false);
  const [busy, setBusy] = useState<string | null>(null);
  // Back from Flutterwave's page: ask what happened, once.
  useEffect(() => {
    if (!ref || checked.current) return;
    checked.current = true;
    (async () => {
      const r = await edge<any>('payments', { action: 'practice_plan_verify', tx_ref: ref });
      await Promise.all(['practice-billing', 'practice-home', 'practice-client'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
      const st = r.result?.status;
      toast(r.ok === false ? (r.error || 'Could not check the payment.') : st === 'successful' ? 'Paid. The card is kept for renewals.' : st === 'failed' ? 'The card payment did not go through.' : 'The payment is still being confirmed.',
        r.ok === false || st === 'failed' ? 'err' : undefined);
      params.delete('ref'); setParams(params, { replace: true });
    })();
  }, [ref]); // eslint-disable-line react-hooks/exhaustive-deps
  async function removeCard(id: string) {
    setBusy(id);
    try { await rpc('practice_card_remove', { p_practice: pid, p_card: id }); await qc.invalidateQueries({ queryKey: ['practice-billing', pid] }); toast('Card removed'); }
    catch (e) { toast(cleanError(e), 'err'); }
    setBusy(null);
  }
  async function stop(clientId: string) {
    setBusy(clientId);
    try { await rpc('practice_set_billing', { p_client: clientId, p_billing: 'business' }); await qc.invalidateQueries({ queryKey: ['practice-billing', pid] }); toast('It runs to the end of the period, then the business pays.'); }
    catch (e) { toast(cleanError(e), 'err'); }
    setBusy(null);
  }
  const b = q.data;
  return (
    <>
      <PageHead title="Billing" sub="Pay for clients' Counta plans with the practice's card. Each client's owner sees that you pay, and can take it back at any time." />
      {q.isLoading ? <SkeletonRows n={5} /> : q.isError ? <Alert kind="red" icon="alert">{cleanError(q.error)}</Alert> : b && (
        <>
          <Card title="Clients" pad={false}>
            {!b.clients.length ? <div className="card-pad faint">No clients yet.</div> : b.clients.map((c) => (
              <div key={c.client_id} className="card-pad stack" style={{ gap: 8, borderTop: '1px solid var(--row)' }}>
                <div className="row wrap" style={{ gap: 8, justifyContent: 'space-between' }}>
                  <span><b>{c.business_name}</b> <span className="faint">· {c.plan?.name || 'Standard'}</span></span>
                  {c.subscription?.paid_by_us
                    ? <span className="row" style={{ gap: 6 }}><span className={'chip ' + (c.subscription.cancel_at_period_end ? 't-grey' : 't-green')}>
                        {c.subscription.cancel_at_period_end ? `You pay until ${fmtDay(c.subscription.period_end?.slice(0, 10))}` : `You pay · renews ${fmtDay(c.subscription.period_end?.slice(0, 10))}`}</span>
                        {!c.subscription.cancel_at_period_end && <button className="btn btn-ghost btn-sm" disabled={busy !== null} onClick={() => stop(c.client_id)}>Stop</button>}</span>
                    : <span className="chip t-grey">{c.subscription?.paid_by_other ? 'Another accountant pays' : 'The business pays'}</span>}
                </div>
                {!c.subscription?.paid_by_us && !c.subscription?.paid_by_other && <StartPaying clientId={c.client_id} name={c.business_name} plans={b.plans} />}
              </div>
            ))}
          </Card>
          <Card title="Cards" sub="Counta keeps a card after its first payment and uses it for renewals.">
            {!b.cards.length ? <div className="faint" style={{ fontSize: 14 }}>No card yet. The first payment asks for one.</div> : b.cards.map((k) => (
              <div key={k.id} className="row wrap" style={{ gap: 8, justifyContent: 'space-between', fontSize: 14 }}>
                <span>{k.brand || 'Card'} ending {k.last4} <span className="faint">· expires {k.expiry}</span></span>
                <button className="btn btn-ghost btn-sm" disabled={busy !== null} onClick={() => removeCard(k.id)}>Remove</button>
              </div>
            ))}
          </Card>
          <Card title="Payments" pad={false}>
            {!b.charges.length ? <div className="card-pad faint">None yet.</div> : b.charges.map((c) => (
              <div key={c.id} className="tr rsp" style={{ gridTemplateColumns: 'minmax(160px,1fr) 120px 110px 140px' }}>
                <span className="m-main">{c.business_name} <span className="faint">· {c.plan}, {c.billing === 'year' ? 'a year' : 'a month'}{c.kind === 'renewal' ? ', renewal' : ''}</span>
                  {c.error && <span className="faint" style={{ display: 'block', fontSize: 12, color: '#B91C1C' }}>{c.error}</span>}</span>
                <span className="right num">{N2(c.amount)}</span>
                <span><span className={'chip ' + (c.status === 'successful' ? 't-green' : c.status === 'failed' ? 't-red' : 't-grey')}>{c.status}</span></span>
                <span className="faint right" style={{ fontSize: 12 }}>{when(c.paid_at || c.created_at)}</span>
              </div>
            ))}
          </Card>
        </>
      )}
    </>
  );
}
