// The business's Counta plan: what it includes and how much of it has been used this month, the plans it can move to, and
// paying for them by card (Flutterwave keeps the card for renewals) or from the business wallet.
import { useEffect, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { can, useInventory, useSession, useToast } from '../../state/session';
import { rpc } from '../../lib/supabase';
import { edge } from '../../lib/api';
import { N2, fmtDay, when } from '../../lib/format';
import { Alert, Field, Modal, ModalHead, SkeletonRows, Spinner } from '../../components/ui';
import { StatusChip } from '../sell/common';
import { OfferNote } from './Partners';

const nf = (n: number) => n.toLocaleString('en-NG', { maximumFractionDigits: 2 });
const limitText = (e: any) => (e.kind === 'feature' ? (e.included ? 'Included' : 'Not included') : !e.included ? 'Not included' : e.quota == null ? 'No limit' : `${nf(Number(e.quota))} ${e.unit || ''}`.trim());

export default function Subscription() {
  const { orgId } = useSession();
  const { data: inv } = useInventory();
  const toast = useToast();
  const qc = useQueryClient();
  const [params, setParams] = useSearchParams();
  // The plan is for people who manage the business's settings; anyone else who opens the page is told so, and nothing is asked.
  const allowed = !!inv && can(inv, 'manage_settings');
  const st = useQuery({ queryKey: ['subscription', orgId], enabled: !!orgId && allowed, queryFn: () => rpc<any>('subscription_state', { p_org: orgId }) });
  const [choosing, setChoosing] = useState<any | null>(null);
  const [busy, setBusy] = useState(false);
  const [checking, setChecking] = useState(false);
  const s = st.data;
  const refresh = () => qc.invalidateQueries({ queryKey: ['subscription'] });
  // Back from Flutterwave's checkout: Counta asks Flutterwave about the payment before saying anything.
  const ref = params.get('ref');
  useEffect(() => {
    if (!ref || !orgId || !allowed) return;
    setChecking(true);
    (async () => {
      for (let i = 0; i < 6; i++) {
        const r = await edge<any>('payments', { action: 'subscription_verify', org_id: orgId, tx_ref: ref });
        if (r.ok === false) { toast(r.error || 'Counta could not check the payment.', 'err'); break; }
        const status = r.result?.status;
        if (status === 'successful') { toast('Paid. The new plan is on.'); break; }
        if (status === 'failed' || status === 'cancelled') { toast('The card payment did not go through. Nothing was charged.', 'err'); break; }
        await new Promise((res) => setTimeout(res, 3000));
      }
      setChecking(false); setParams({}, { replace: true }); await refresh();
    })();
  }, [ref, orgId, allowed]); // eslint-disable-line react-hooks/exhaustive-deps
  async function act(fn: () => Promise<any>, ok: string) {
    setBusy(true);
    try { await fn(); toast(ok); await refresh(); } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  if (inv && !allowed) return <div className="container" style={{ maxWidth: 1000 }}><Alert kind="grey" icon="shield">The owner, or someone who manages the business's settings, looks after its Counta plan.</Alert></div>;
  if (st.isLoading) return <div className="container" style={{ maxWidth: 1000 }}><SkeletonRows n={6} /></div>;
  if (st.error) return <div className="container" style={{ maxWidth: 1000 }}><Alert kind="yellow" icon="shield">{(st.error as Error).message}</Alert></div>;
  if (!s) return null;
  const plan = s.plan, sub = s.subscription || {};
  const price = sub.billing === 'year' ? Number(plan.price_year) : Number(plan.price_month);
  const features = (s.entitlements || []).filter((e: any) => e.kind === 'feature');
  const quotas = (s.entitlements || []).filter((e: any) => e.kind === 'quota');
  const others = (s.plans || []).filter((p: any) => p.id !== plan.id || sub.billing !== 'month' || sub.status === 'past_due');
  return (
    <div className="container stack" style={{ maxWidth: 1000, gap: 16 }}>
      {checking && <Alert kind="blue" icon="clock"><span className="row" style={{ gap: 8 }}><Spinner small />Checking the payment with Flutterwave…</span></Alert>}
      {s.is_sample && <Alert kind="grey" icon="info">This is the sample business. Its plan does not change; set up your own business to choose one.</Alert>}
      {!s.can_change && <Alert kind="grey" icon="shield">Only the owner or an admin of the business changes its plan.</Alert>}
      {!s.is_sample && <OfferNote />}
      <div className="card card-pad stack" style={{ gap: 10 }}>
        <div className="row wrap" style={{ justifyContent: 'space-between', gap: 10 }}>
          <div>
            <div className="label">Your plan</div>
            <div className="row" style={{ gap: 8, marginTop: 4 }}><span style={{ fontSize: 22, fontWeight: 700 }}>{plan.name}</span><StatusChip s={sub.status || 'active'} />{sub.comp && <span className="chip t-purple">from TaxStreem</span>}</div>
            <div className="muted" style={{ fontSize: 13, marginTop: 2 }}>{price > 0 ? `${N2(price)} ${sub.billing === 'year' ? 'a year' : 'a month'}, VAT included` : 'Free'}</div>
          </div>
          <div className="stack" style={{ gap: 4, fontSize: 13, textAlign: 'right' }}>
            {sub.status === 'trialing' && sub.trial_ends_at && <span>Trial ends {fmtDay(sub.trial_ends_at)}</span>}
            {sub.status !== 'trialing' && sub.current_period_end && price > 0 && <span>{sub.cancel_at_period_end ? 'Ends' : 'Renews'} {fmtDay(sub.current_period_end)}</span>}
            {sub.next_plan && <span>Moves to {sub.next_plan.name} on {fmtDay(sub.current_period_end)}</span>}
            {price > 0 && <span className="muted">{sub.pay_method === 'card' && sub.card ? `Card ${sub.card.brand || ''} •••• ${sub.card.last4 || ''}` : sub.pay_method === 'wallet' ? 'From the business wallet' : 'No way to pay chosen'}</span>}
          </div>
        </div>
        {sub.status === 'past_due' && <Alert kind="red" icon="alert">The last payment did not go through{sub.retry_at ? `. Counta tries again ${when(sub.retry_at)}` : ''}. After three days unpaid the business moves to the standard plan. Check the card, or fund the wallet.</Alert>}
        {s.can_change && price > 0 && !sub.comp && (
          <div className="row wrap" style={{ gap: 8 }}>
            {sub.cancel_at_period_end ? <button className="btn btn-secondary btn-sm" disabled={busy} onClick={() => act(() => rpc('subscription_cancel', { p_org: orgId, p_on: false }), 'The plan renews again')}>Keep the plan</button>
              : <button className="btn btn-ghost btn-sm" disabled={busy} onClick={() => { if (window.confirm(`Stop renewing ${plan.name}? It runs to ${fmtDay(sub.current_period_end)}, then the business moves to the standard plan.`)) void act(() => rpc('subscription_cancel', { p_org: orgId, p_on: true }), 'The plan will not renew'); }}>Stop renewing</button>}
            {sub.pay_method === 'card' && <button className="btn btn-ghost btn-sm" disabled={busy || !s.wallet} onClick={() => act(() => rpc('subscription_method', { p_org: orgId, p: { method: 'wallet' } }), 'Renewals come from the wallet')}>Pay renewals from the wallet</button>}
            {sub.pay_method !== 'card' && sub.card && <button className="btn btn-ghost btn-sm" disabled={busy} onClick={() => act(() => rpc('subscription_method', { p_org: orgId, p: { method: 'card' } }), `Renewals go on the card ending ${sub.card.last4}`)}>Pay renewals by card</button>}
            {sub.card && <button className="btn btn-ghost btn-sm" disabled={busy} onClick={() => { if (window.confirm('Remove the saved card? Renewals then need the wallet or a new card.')) void act(() => rpc('subscription_method', { p_org: orgId, p: { remove_card_id: sub.card.id } }), 'Card removed'); }}>Remove the card</button>}
          </div>
        )}
      </div>

      <div className="card card-pad stack" style={{ gap: 12 }}>
        <div className="label">This month</div>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(230px, 1fr))', gap: 12 }}>
          {quotas.map((e: any) => {
            const used = Number(e.used || 0), q = e.quota == null ? null : Number(e.quota);
            const share = q ? Math.min(used / q, 1) : 0;
            const tone = !e.included ? '#9CA3AF' : q != null && used >= q ? '#DC2626' : share >= 0.8 ? '#D97706' : '#0072F5';
            return (
              <div key={e.module} className="stack" style={{ gap: 4 }}>
                <div className="row" style={{ justifyContent: 'space-between', fontSize: 13 }}><span>{e.name}</span><span className="num" style={{ color: tone }}>{e.included ? `${nf(used)}${q != null ? ` of ${nf(q)}` : ''}` : 'Not included'}</span></div>
                <div style={{ height: 6, background: '#F3F4F6', borderRadius: 4, overflow: 'hidden' }}><div style={{ width: `${q ? share * 100 : e.included ? 4 : 0}%`, height: '100%', background: tone }} /></div>
                {q != null && e.included && used >= q && <div className="faint" style={{ fontSize: 11 }}>{e.enforce === 'block' ? 'Used up: waits for next month or a bigger plan.' : 'Past the limit; it still works this month.'}</div>}
              </div>
            );
          })}
        </div>
        <div className="row wrap" style={{ gap: 6 }}>
          {features.map((e: any) => <span key={e.module} className={'chip ' + (e.included ? 't-green' : 't-grey')} title={e.what || undefined}>{e.included ? '✓' : '✗'} {e.name}</span>)}
        </div>
      </div>

      {others.length > 0 && (
        <div className="stack" style={{ gap: 10 }}>
          <div className="label">Plans</div>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(260px, 1fr))', gap: 12 }}>
            {(s.plans || []).map((p: any) => {
              const current = p.id === plan.id;
              return (
                <div key={p.id} className="card card-pad stack" style={{ gap: 8, borderColor: current ? '#0072F5' : undefined }}>
                  <div className="row" style={{ justifyContent: 'space-between' }}><b style={{ fontSize: 16 }}>{p.name}</b>{current && <span className="chip t-blue">Your plan</span>}</div>
                  <div><span style={{ fontSize: 20, fontWeight: 700 }}>{Number(p.price_month) > 0 ? N2(p.price_month) : 'Free'}</span>{Number(p.price_month) > 0 && <span className="muted" style={{ fontSize: 12 }}> a month · {N2(p.price_year)} a year</span>}</div>
                  {p.description && <div className="muted" style={{ fontSize: 13 }}>{p.description}</div>}
                  {p.trial_days > 0 && !sub.trial_used && <div style={{ fontSize: 12, color: '#15803D' }}>{p.trial_days}-day trial before the first payment</div>}
                  <div className="stack" style={{ gap: 3, fontSize: 12.5 }}>
                    {(p.entitlements || []).filter((e: any) => e.kind === 'quota' || !e.included).slice(0, 9).map((e: any) => (
                      <div key={e.module} className="row" style={{ justifyContent: 'space-between', gap: 8 }}><span className="muted">{e.name}</span><span style={{ color: e.included ? undefined : '#9CA3AF' }}>{limitText(e)}</span></div>
                    ))}
                  </div>
                  {s.can_change && !s.is_sample && (!current || sub.status === 'past_due' || sub.cancel_at_period_end) && (
                    <button className={'btn btn-sm ' + (current ? 'btn-secondary' : 'btn-primary')} style={{ marginTop: 'auto' }} disabled={busy} onClick={() => setChoosing(p)}>{current ? 'Pay for it again' : `Move to ${p.name}`}</button>
                  )}
                </div>
              );
            })}
          </div>
        </div>
      )}

      <div className="card" style={{ overflow: 'hidden' }}>
        <div className="card-hd"><div className="label">Payments for the plan</div></div>
        {!(s.charges || []).length ? <div style={{ padding: 16 }} className="faint">None yet.</div> : (s.charges || []).map((c: any) => (
          <div key={c.id} className="tr" style={{ gridTemplateColumns: 'minmax(0,1fr) 120px 110px', gap: 10 }}>
            <span>{c.plan} · {c.billing === 'year' ? 'a year' : 'a month'} · {c.method === 'card' ? 'by card' : 'from the wallet'}{c.kind === 'renewal' ? ' · renewal' : ''}
              <span className="faint" style={{ display: 'block', fontSize: 12 }}>{when(c.paid_at || c.at)}{c.error ? ` · ${c.error}` : ''}</span></span>
            <span className="right num">{N2(c.amount)}</span>
            <span><StatusChip s={c.status === 'sent' ? 'processing' : c.status} /></span>
          </div>
        ))}
      </div>
      {choosing && <ChoosePlan plan={choosing} state={s} onClose={() => setChoosing(null)} onDone={refresh} />}
    </div>
  );
}

function ChoosePlan({ plan, state, onClose, onDone }: { plan: any; state: any; onClose: () => void; onDone: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const sub = state.subscription || {};
  const [billing, setBilling] = useState<'month' | 'year'>(sub.billing === 'year' ? 'year' : 'month');
  const [method, setMethod] = useState<'card' | 'wallet'>(sub.pay_method === 'wallet' ? 'wallet' : 'card');
  const [busy, setBusy] = useState(false);
  const price = billing === 'year' ? Number(plan.price_year) : Number(plan.price_month);
  const free = price === 0;
  const trial = plan.trial_days > 0 && !sub.trial_used;
  const wallet = state.wallet ? Number(state.wallet.available) : null;
  async function go() {
    setBusy(true);
    const r = await edge<any>('payments', { action: 'subscription_start', org_id: orgId, plan_id: plan.id, billing, method: free ? null : method, use_saved: true });
    setBusy(false);
    if (r.ok === false) { toast(r.error || 'That did not go through.', 'err'); return; }
    if (r.action === 'checkout' && r.link) { window.location.href = r.link; return; }
    const st = r.result?.status;
    if (r.action === 'done') toast(r.trial ? `${plan.name} trial started` : `Now on ${plan.name}`);
    else if (r.action === 'scheduled') toast(`${plan.name} starts when the current period ends`);
    else if (st === 'successful') toast(`Paid. Now on ${plan.name}`);
    else if (st === 'sent' || st === 'pending') toast('The payment is on its way. The plan changes once Flutterwave confirms it.');
    else toast(r.result?.error || 'The payment did not go through.', 'err');
    onDone(); onClose();
  }
  return (
    <Modal onClose={onClose} width={500}>
      <ModalHead title={`Move to ${plan.name}`} sub={free ? 'Free' : `${N2(price)} ${billing === 'year' ? 'a year' : 'a month'}, VAT included`} onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 12 }}>
        {!free && (
          <>
            <Field label="Pay"><div className="row" style={{ gap: 6 }}>
              {(['month', 'year'] as const).map((b) => <button key={b} className={'pill' + (billing === b ? ' on' : '')} onClick={() => setBilling(b)}>{b === 'month' ? `Monthly · ${N2(plan.price_month)}` : `Yearly · ${N2(plan.price_year)}`}</button>)}
            </div></Field>
            <Field label="How"><div className="stack" style={{ gap: 6 }}>
              <label className="check"><input type="radio" checked={method === 'card'} onChange={() => setMethod('card')} />By card{sub.card ? ` (•••• ${sub.card.last4} saved)` : ', on Flutterwave\'s secure page'}</label>
              <label className="check"><input type="radio" checked={method === 'wallet'} disabled={wallet == null} onChange={() => setMethod('wallet')} />From the business wallet{wallet != null ? ` (${N2(wallet)} available)` : ' (open the wallet in Payments first)'}</label>
            </div></Field>
            {method === 'wallet' && wallet != null && wallet < price && <Alert kind="red" icon="alert">The wallet has {N2(wallet)}. Fund it first, or pay by card.</Alert>}
            {trial ? <Alert kind="green" icon="clock">{plan.trial_days} days free first. The first payment is taken when the trial ends, by the way you choose here.</Alert>
              : <div className="faint" style={{ fontSize: 12 }}>A dearer plan starts now, for a full {billing}. A cheaper one starts when the current period ends. Renewals use the same way of paying, and the card is kept by Flutterwave, not Counta.</div>}
          </>
        )}
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" disabled={busy || (!free && method === 'wallet' && (wallet == null || wallet < price))} onClick={go}>
          {busy ? 'Working…' : free ? `Move to ${plan.name}` : trial ? 'Start the trial' : method === 'card' && !sub.card ? 'Continue to pay by card' : `Pay ${N2(price)}`}</button></div>
    </Modal>
  );
}

