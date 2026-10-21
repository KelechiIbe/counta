import { useState } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { rpc } from '../../lib/supabase';
import { fmtDay, num, when } from '../../lib/format';
import { Icon } from '../../components/Icon';
import { Alert, Pills, SkeletonRows, Spinner } from '../../components/ui';
import { useToast } from '../../state/session';
import { FEATURES, featureLabel, tidyError } from '../api';
import { Card, grid, PageHead } from '../ui';
import { OrgPlan } from './OrgPlan';

type Row = {
  id: string; name: string; rc_number: string | null; created_at: string; is_sample: boolean; identity_status: string; offering: string | null; industry: string | null;
  owner: { name: string; email: string | null } | null; people: number; paused: string[]; last_activity: string | null;
};
const ID_TONE: Record<string, [string, string]> = {
  not_required: ['t-grey', 'Before the check'], pending: ['t-amber', 'NIN not checked'], review: ['t-amber', 'Slip waiting'],
  verified: ['t-green', 'Director confirmed'], approved: ['t-green', 'Slip approved'], rejected: ['t-red', 'Slip rejected'],
};
export const IdentityChip = ({ s }: { s: string }) => <span className={'chip ' + (ID_TONE[s]?.[0] || 't-grey')}>{ID_TONE[s]?.[1] || s}</span>;

export default function Businesses() {
  const nav = useNavigate();
  const [params, setParams] = useSearchParams();
  const [q, setQ] = useState(params.get('q') || '');
  const filter = (params.get('filter') || 'all') as 'all' | 'review' | 'locked' | 'paused' | 'sample';
  const [limit, setLimit] = useState(50);
  const list = useQuery({ queryKey: ['admin-businesses', params.get('q') || '', filter, limit],
    queryFn: () => rpc<{ total: number; rows: Row[] }>('admin_businesses', { p_search: params.get('q') || null, p_filter: filter, p_limit: limit, p_offset: 0 }) });
  const set = (k: string, v: string) => { const n = new URLSearchParams(params); if (v) n.set(k, v); else n.delete(k); setParams(n, { replace: true }); };
  return (
    <>
      <PageHead title="Businesses" sub="Every business on Counta. Search by name, RC number, or the name or email of anyone in it." />
      <form className="row wrap" style={{ gap: 8 }} onSubmit={(e) => { e.preventDefault(); set('q', q.trim()); }}>
        <input className="input" style={{ flex: '1 1 260px', minWidth: 0 }} placeholder="Search businesses" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search businesses" />
        <button className="btn btn-secondary" type="submit"><Icon name="search" size={14} />Search</button>
      </form>
      <div style={{ overflowX: 'auto' }}>
        <Pills value={filter} onChange={(v) => set('filter', v === 'all' ? '' : v)} options={[{ id: 'all', label: 'All' }, { id: 'review', label: 'Slip waiting' },
          { id: 'locked', label: 'Payments locked' }, { id: 'paused', label: 'Something paused' }, { id: 'sample', label: 'Sample' }]} />
      </div>
      <div className="card" style={{ overflow: 'hidden' }}>
        {list.isLoading ? <div className="card-pad"><SkeletonRows n={6} /></div> : list.isError ? <div className="card-pad"><Alert kind="red" icon="alert">{tidyError(list.error)}</Alert></div>
          : !list.data?.rows.length ? <div className="card-pad muted">No businesses match.</div> : (
          <div className="tbl">
            <div className="tr head rsp th" style={{ gridTemplateColumns: 'minmax(0,2fr) minmax(0,1.6fr) 80px 150px 120px' }}>
              <span>Business</span><span>Owner</span><span>People</span><span>Identity</span><span>Set up</span>
            </div>
            {list.data.rows.map((r) => (
              <div key={r.id} className="tr rsp click" style={{ gridTemplateColumns: 'minmax(0,2fr) minmax(0,1.6fr) 80px 150px 120px' }} onClick={() => nav(`/admin/businesses/${r.id}`)}
                role="link" tabIndex={0} onKeyDown={(e) => { if (e.key === 'Enter') nav(`/admin/businesses/${r.id}`); }}>
                <span className="m-main" style={{ minWidth: 0 }}>
                  <b className="ellipsis" style={{ display: 'block' }}>{r.name}</b>
                  <span className="faint" style={{ fontSize: 12 }}>{[r.rc_number && `RC ${r.rc_number}`, r.offering, r.is_sample && 'sample'].filter(Boolean).join(' · ') || '—'}
                    {r.paused.map((p) => <span key={p} className="chip t-red" style={{ marginLeft: 6 }}>{featureLabel(p)} off</span>)}</span>
                </span>
                <span className="ellipsis" style={{ minWidth: 0 }}>{r.owner ? `${r.owner.name}${r.owner.email ? ` · ${r.owner.email}` : ''}` : '—'}</span>
                <span data-label="People" className="num">{num(r.people)}</span>
                <span><IdentityChip s={r.identity_status} /></span>
                <span className="faint" data-label="Set up">{fmtDay(r.created_at)}</span>
              </div>
            ))}
          </div>
        )}
      </div>
      {list.data && list.data.total > list.data.rows.length && (
        <div className="row" style={{ gap: 10 }}>
          <span className="faint" style={{ fontSize: 13 }}>Showing {num(list.data.rows.length)} of {num(list.data.total)}</span>
          <button className="btn btn-secondary btn-sm" onClick={() => setLimit(limit + 50)}>Show more</button>
        </div>
      )}
    </>
  );
}

type Detail = {
  org: Record<string, any>;
  identity: { status: string; last4: string | null; checked_at: string | null; slip: boolean; review: { approved: boolean; note: string | null; at: string } | null; attempts: number };
  people: { name: string; role: string; title: string | null; status: string; email: string | null; joined: string; last_sign_in: string | null }[];
  onboarding: { steps: { id: string; label?: string; done: boolean; skipped: boolean }[]; last_seen: string | null; completed: string | null; language: string } | null;
  wallet: { status: string; rail: string; bank: string | null; account_number: string | null; error: string | null; opened: string } | null;
  payments_open: boolean;
  switches: { feature: string; on: boolean; override: { enabled: boolean; note: string | null; at: string; by: string | null } | null }[];
  usage: { sales: number; messages: Record<string, number>; calls: Record<string, number>; ai_reads: number; martina: number };
  failures: { at: string; kind: string; what: string; error: string }[];
};

function SwitchRow({ orgId, s }: { orgId: string; s: Detail['switches'][number] }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState(s.override?.note || '');
  const f = FEATURES.find((x) => x.id === s.feature);
  const value = s.override ? (s.override.enabled ? 'on' : 'off') : 'default';
  async function choose(v: 'default' | 'on' | 'off') {
    setBusy(true);
    try {
      await rpc('admin_org_switch', { p_org: orgId, p_feature: s.feature, p_enabled: v === 'default' ? null : v === 'on', p_note: note || null });
      await qc.invalidateQueries({ queryKey: ['admin-business', orgId] });
      toast(v === 'default' ? `${f?.label} follows everyone again` : `${f?.label} ${v} for this business`);
    } catch (e) { toast(tidyError(e), 'err'); }
    setBusy(false);
  }
  return (
    <div className="adm-row" style={{ gridTemplateColumns: 'minmax(0,1fr) auto' }}>
      <div style={{ minWidth: 0 }}>
        <div className="row wrap" style={{ gap: 8 }}><b>{f?.label || s.feature}</b><span className={'chip ' + (s.on ? 't-green' : 't-red')}>{s.on ? 'On' : 'Off'}</span>
          {s.override && <span className="faint" style={{ fontSize: 12 }}>Set for this business {when(s.override.at)}{s.override.by ? ` by ${s.override.by}` : ''}{s.override.note ? `: ${s.override.note}` : ''}</span>}</div>
        <input className="input" style={{ marginTop: 6, height: 32, fontSize: 13 }} placeholder="Note (why), shown to admins only" value={note} onChange={(e) => setNote(e.target.value)} maxLength={300} />
      </div>
      <div className="row" style={{ gap: 4 }} role="radiogroup" aria-label={`${f?.label} for this business`}>
        {(['default', 'on', 'off'] as const).map((v) => (
          <button key={v} role="radio" aria-checked={value === v} disabled={busy} className={'pill' + (value === v ? ' on' : '')} onClick={() => choose(v)}>
            {v === 'default' ? 'As everyone' : v === 'on' ? 'On' : 'Off'}
          </button>
        ))}
      </div>
    </div>
  );
}

export function Business() {
  const { id = '' } = useParams();
  const q = useQuery({ queryKey: ['admin-business', id], queryFn: () => rpc<Detail>('admin_business', { p_org: id }) });
  const d = q.data;
  if (q.isLoading) return <div className="row" style={{ justifyContent: 'center', padding: 40 }}><Spinner /></div>;
  if (q.isError || !d) return <Alert kind="red" icon="alert">{tidyError(q.error) || 'Business not found.'}</Alert>;
  const o = d.org;
  const steps = d.onboarding?.steps || [];
  const stepsDone = steps.filter((s) => s.done || s.skipped).length;
  return (
    <>
      <div><Link to="/admin/businesses" className="btn btn-ghost btn-sm"><span style={{ display: 'inline-flex', transform: 'rotate(180deg)' }}><Icon name="arrow" size={14} /></span>All businesses</Link></div>
      <PageHead title={o.name} sub={[o.legal_form?.replace(/_/g, ' '), o.rc_number && `RC ${o.rc_number}`, o.tin && `Tax ID ${o.tin}`, `set up ${fmtDay(o.created_at)}`, o.is_sample && 'sample business'].filter(Boolean).join(' · ')}
        right={<IdentityChip s={d.identity.status} />} />
      <div style={grid(300)}>
        <Card title="Identity and payments">
          <div style={{ fontSize: 14, lineHeight: 1.7 }}>
            <div><IdentityChip s={d.identity.status} />{d.identity.last4 ? <span className="faint"> · NIN ending {d.identity.last4}</span> : null}{d.identity.attempts ? <span className="faint"> · {d.identity.attempts} checks</span> : null}</div>
            {d.identity.review && <div className="faint">{d.identity.review.approved ? 'Approved' : 'Rejected'} {when(d.identity.review.at)}{d.identity.review.note ? `: ${d.identity.review.note}` : ''}</div>}
            <div>Payments {d.payments_open ? <span className="chip t-green">open</span> : <span className="chip t-red">locked</span>} <span className="faint">on {o.payment_rail}</span></div>
            {d.wallet ? <div className="faint">Wallet {d.wallet.status}{d.wallet.account_number ? ` · ${d.wallet.bank || ''} ${d.wallet.account_number}` : ''}{d.wallet.error ? ` · ${d.wallet.error}` : ''}</div>
              : <div className="faint">No wallet yet</div>}
            {d.identity.status === 'review' && <Link to="/admin/reviews" className="btn btn-secondary btn-sm" style={{ marginTop: 8 }}>Open the review</Link>}
          </div>
        </Card>
        <Card title="Last 30 days">
          <div style={{ fontSize: 14, lineHeight: 1.8 }}>
            <div>{num(d.usage.sales)} sales and invoices</div>
            <div>{num(Object.values(d.usage.messages).reduce((a, b) => a + b, 0))} messages{d.usage.messages.failed ? <span style={{ color: 'var(--red)' }}> · {d.usage.messages.failed} failed</span> : null}</div>
            <div>{num(Object.values(d.usage.calls).reduce((a, b) => a + b, 0))} calls · {num(d.usage.ai_reads)} invoices read · {num(d.usage.martina)} Martina conversations</div>
          </div>
        </Card>
        <Card title="Onboarding" sub={d.onboarding ? `${stepsDone} of ${steps.length} steps${d.onboarding.completed ? ', finished' : ''}${d.onboarding.last_seen ? ` · last seen ${when(d.onboarding.last_seen)}` : ''}` : 'No owner has signed in.'}>
          <div className="row wrap" style={{ gap: 6 }}>
            {steps.map((s) => <span key={s.id} className={'chip ' + (s.done ? 't-green' : s.skipped ? 't-grey' : 't-amber')}>{(s.label || s.id).replace(/_/g, ' ')}</span>)}
          </div>
        </Card>
      </div>
      <Card title="People" pad={false}>
        {d.people.map((p) => (
          <div key={(p.email || '') + p.name + p.role} className="adm-row" style={{ gridTemplateColumns: 'minmax(0,1.4fr) minmax(0,1.6fr) 120px 160px' }}>
            <span className="ellipsis"><b>{p.name}</b> <span className="faint">· {p.role}{p.title ? `, ${p.title}` : ''}</span></span>
            <span className="ellipsis">{p.email || <span className="faint">No login</span>}</span>
            <span><span className={'chip ' + (p.status === 'active' ? 't-green' : p.status === 'invited' ? 't-amber' : 't-grey')}>{p.status}</span></span>
            <span className="faint">{p.last_sign_in ? `Signed in ${when(p.last_sign_in)}` : 'Never signed in'}</span>
          </div>
        ))}
      </Card>
      <OrgPlan orgId={id} />
      <Card title="Switches for this business" sub="As everyone follows the setting under Limits and switches. On or Off holds for this business whatever everyone else has." pad={false}>
        {d.switches.map((s) => <SwitchRow key={s.feature} orgId={id} s={s} />)}
      </Card>
      <Card title="What failed, last 30 days" pad={false}>
        {!d.failures.length ? <div className="card-pad muted" style={{ fontSize: 14 }}>Nothing failed.</div> : d.failures.map((f, i) => (
          <div key={i} className="adm-row" style={{ gridTemplateColumns: '140px 110px minmax(0,1fr)' }}>
            <span className="faint">{when(f.at)}</span><span><span className="chip t-red">{f.kind}</span></span>
            <span style={{ minWidth: 0 }}><b>{f.what}</b> <span className="muted" style={{ wordBreak: 'break-word' }}>· {f.error}</span></span>
          </div>
        ))}
      </Card>
    </>
  );
}
