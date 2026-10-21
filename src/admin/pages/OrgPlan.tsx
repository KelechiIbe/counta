// A business's plan on its admin page: what it includes and has used, putting it on a plan without a charge (complimentary
// when TaxStreem says so), and limits set for this business alone.
import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { rpc } from '../../lib/supabase';
import { N2, fmtDay, when } from '../../lib/format';
import { useToast } from '../../state/session';
import { Alert, Field, Modal, ModalHead, Spinner } from '../../components/ui';
import { tidyError } from '../api';
import { Card } from '../ui';

const nf = (n: number) => n.toLocaleString('en-NG', { maximumFractionDigits: 2 });

export function OrgPlan({ orgId }: { orgId: string }) {
  const toast = useToast();
  const qc = useQueryClient();
  const q = useQuery({ queryKey: ['admin-org-plan', orgId], queryFn: () => rpc<any>('admin_org_plan', { p_org: orgId }) });
  const plans = useQuery({ queryKey: ['admin-plans'], queryFn: () => rpc<any>('admin_plans') });
  const [moving, setMoving] = useState(false);
  const [override, setOverride] = useState<any | null>(null);
  const [f, setF] = useState({ plan_id: '', months: '1', comp: true, note: '' });
  const [busy, setBusy] = useState(false);
  const d = q.data;
  async function act(fn: () => Promise<any>, ok: string) {
    setBusy(true);
    try { await fn(); toast(ok); await qc.invalidateQueries({ queryKey: ['admin-org-plan', orgId] }); await qc.invalidateQueries({ queryKey: ['admin-business', orgId] }); setMoving(false); setOverride(null); }
    catch (e) { toast(tidyError(e), 'err'); }
    setBusy(false);
  }
  if (q.isLoading) return <Card title="Plan"><Spinner /></Card>;
  if (!d) return <Card title="Plan"><Alert kind="red" icon="alert">{tidyError(q.error)}</Alert></Card>;
  const sub = d.subscription || {};
  return (
    <Card title={`Plan: ${d.plan.name}`} sub={`${sub.status || 'active'}${sub.comp ? ', complimentary' : ''}${sub.current_period_end ? ` · period ends ${fmtDay(sub.current_period_end)}` : ''}${sub.pay_method ? ` · pays by ${sub.pay_method}` : ''}${sub.card ? ` •••• ${sub.card.last4}` : ''}`}
      right={<button className="btn btn-secondary btn-sm" onClick={() => setMoving(true)}>Put on a plan</button>} pad={false}>
      <div className="tbl">
        {(d.entitlements || []).map((e: any) => (
          <div key={e.module} className="adm-row" style={{ gridTemplateColumns: 'minmax(0,1.4fr) 160px 150px 90px' }}>
            <span className="ellipsis"><b>{e.name}</b>{e.source === 'override' && <span className="chip t-purple" style={{ marginLeft: 6 }}>for this business{e.until ? ` to ${fmtDay(e.until)}` : ''}</span>}</span>
            <span className="muted">{e.kind === 'feature' ? (e.included ? 'Included' : `Not included${e.enforce === 'block' ? '' : ' (left on)'}`) : !e.included ? 'Not included' : e.quota == null ? 'No limit' : `${nf(Number(e.quota))}${e.enforce === 'block' ? '' : ', warn'}`}</span>
            <span className="num">{e.kind === 'quota' ? `${nf(Number(e.used || 0))} used` : ''}</span>
            <span><button className="btn btn-ghost btn-xs" onClick={() => setOverride({ module: e.module, name: e.name, kind: e.kind, included: e.included, quota: e.quota != null ? String(Number(e.quota)) : '', enforce: e.enforce, until: e.until || '', note: '', has: e.source === 'override' })}>Change</button></span>
          </div>
        ))}
      </div>
      {(d.charges || []).length > 0 && <div className="card-pad faint" style={{ fontSize: 12 }}>Last payments: {(d.charges || []).slice(0, 4).map((c: any) => `${c.plan} ${N2(c.amount)} ${c.status} ${when(c.at)}`).join(' · ')}</div>}
      {moving && (
        <Modal onClose={() => setMoving(false)} width={480}>
          <ModalHead title="Put the business on a plan" sub="No charge is taken. Complimentary plans roll on without payment." onClose={() => setMoving(false)} />
          <div className="modal-body stack" style={{ gap: 10 }}>
            <Field label="Plan"><select className="input" value={f.plan_id} onChange={(e) => setF({ ...f, plan_id: e.target.value })}><option value="">Choose</option>
              {(plans.data?.plans || []).filter((p: any) => p.active).map((p: any) => <option key={p.id} value={p.id}>{p.name}{Number(p.price_month) > 0 ? ` · ${N2(p.price_month)} a month` : ''}</option>)}</select></Field>
            <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
              <Field label="For (months)"><input className="input num" inputMode="numeric" value={f.months} onChange={(e) => setF({ ...f, months: e.target.value })} /></Field>
              <label className="check" style={{ marginTop: 22 }}><input type="checkbox" checked={f.comp} onChange={(e) => setF({ ...f, comp: e.target.checked })} />Complimentary</label>
            </div>
            <Field label="Why"><input className="input" value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} placeholder="Pilot customer" /></Field>
          </div>
          <div className="modal-ft"><button className="btn btn-secondary" onClick={() => setMoving(false)}>Cancel</button>
            <button className="btn btn-primary" disabled={busy || !f.plan_id} onClick={() => act(() => rpc('admin_set_org_plan', { p_org: orgId, p: f }), 'Plan changed')}>Save</button></div>
        </Modal>
      )}
      {override && (
        <Modal onClose={() => setOverride(null)} width={480}>
          <ModalHead title={override.name} sub="For this business only, whatever its plan says." onClose={() => setOverride(null)} />
          <div className="modal-body stack" style={{ gap: 10 }}>
            <label className="check"><input type="checkbox" checked={override.included} onChange={(e) => setOverride({ ...override, included: e.target.checked })} />Included</label>
            {override.kind === 'quota' && override.included && <Field label="Limit" hint="Empty for no limit"><input className="input num" inputMode="numeric" value={override.quota} onChange={(e) => setOverride({ ...override, quota: e.target.value })} /></Field>}
            <Field label={override.kind === 'quota' ? 'Past the limit' : 'When not included'}><select className="input" value={override.enforce} onChange={(e) => setOverride({ ...override, enforce: e.target.value })}>
              <option value="block">{override.kind === 'quota' ? 'Stop' : 'Turned off'}</option><option value="warn">{override.kind === 'quota' ? 'Warn only' : 'Left on'}</option></select></Field>
            <Field label="Until" hint="Empty: until removed"><input className="input" type="date" value={override.until} onChange={(e) => setOverride({ ...override, until: e.target.value })} /></Field>
            <Field label="Why"><input className="input" value={override.note} onChange={(e) => setOverride({ ...override, note: e.target.value })} /></Field>
          </div>
          <div className="modal-ft">
            {override.has && <button className="btn btn-ghost" disabled={busy} onClick={() => act(() => rpc('admin_set_override', { p_org: orgId, p: { module: override.module, remove: true } }), 'Back to the plan')}>Back to the plan</button>}
            <button className="btn btn-secondary" onClick={() => setOverride(null)}>Cancel</button>
            <button className="btn btn-primary" disabled={busy} onClick={() => act(() => rpc('admin_set_override', { p_org: orgId, p: { module: override.module, included: override.included,
              quota: override.kind === 'quota' ? override.quota : null, enforce: override.enforce, until: override.until || null, note: override.note } }), 'Saved for this business')}>Save</button>
          </div>
        </Modal>
      )}
    </Card>
  );
}
