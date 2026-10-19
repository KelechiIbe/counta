// TaxStreem's own people in the portal (admins see everything, reviewers only identity reviews), and the record of every
// change anyone made here.
import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { rpc } from '../../lib/supabase';
import { fmtDay, when } from '../../lib/format';
import { useToast } from '../../state/session';
import { Icon } from '../../components/Icon';
import { Alert, Pills, SkeletonRows, Spinner } from '../../components/ui';
import { featureLabel, pct, tidyError } from '../api';
import { Card, PageHead } from '../ui';

type Staff = { user_id: string; email: string; role: 'admin' | 'reviewer'; added_at: string; me: boolean; authenticator: boolean };
type Audit = { at: string; email: string | null; action: string; target: string | null; detail: any };

const yesNo = (v: unknown) => (v === true ? 'on' : v === false ? 'off' : 'as everyone');
function describe(a: Audit): string {
  const d = a.detail || {};
  switch (a.action) {
    case 'set_key': return `Set the key ${a.target}`;
    case 'clear_key': return `Removed the key ${a.target}`;
    case 'save_martina': return `Changed Martina: ${[d.to?.tone !== d.from?.tone ? `tone ${d.to?.tone}` : '', d.to?.default_voice_id !== d.from?.default_voice_id ? 'default voice' : ''].filter(Boolean).join(', ') || 'no change'}`;
    case 'save_switches': {
      const ch = Object.keys(d.to || {}).filter((k) => d.from?.[k] !== d.to?.[k]);
      return ch.length ? `Turned ${ch.map((k) => `${featureLabel(k).toLowerCase()} ${d.to[k] ? 'on' : 'off'}`).join(', ')} for everyone` : 'Saved the switches';
    }
    case 'save_limits': return 'Changed the daily limits';
    case 'org_switch': return `${featureLabel(d.feature)} ${yesNo(d.enabled)} for one business${d.note ? ` (${d.note})` : ''}`;
    case 'set_voice': return `${d.active === false ? 'Took a voice off offer' : 'Put a voice on offer'}${d.name ? `: ${d.name}` : ''}`;
    case 'set_currency': return `${d.allowed ? 'Took' : 'Stopped taking'} ${a.target}`;
    case 'set_rate': return `Set ${a.target} to ₦${d.rate} from ${fmtDay(d.day)}`;
    case 'clear_rate': return `Removed the ${a.target} rate set for ${fmtDay(d.day)}`;
    case 'set_tax_rule': return `Set ${a.target} to ${/rate|cap|ca_/.test(a.target || '') ? pct(d.value) : d.value} from ${fmtDay(d.from)}`;
    case 'remove_tax_rule': return `Removed ${a.target} from ${fmtDay(d.from)}`;
    case 'set_wht_rate': return `Withholding tax ${a.target}: company ${pct(d.company)}, individual ${pct(d.individual)}`;
    case 'add_staff': return `Added ${a.target} as ${d.role}`;
    case 'remove_staff': return `Removed ${a.target} as ${d.role}`;
    case 'review_identity': return `${d.approved === false ? 'Turned down' : 'Approved'} an identity check${d.note ? `: ${d.note}` : ''}`;
    default: return a.action.replace(/_/g, ' ') + (a.target ? ` ${a.target}` : '');
  }
}

export default function Team() {
  const qc = useQueryClient();
  const toast = useToast();
  const q = useQuery({ queryKey: ['admin-staff'], queryFn: () => rpc<{ staff: Staff[]; audit: Audit[] }>('admin_staff') });
  const [email, setEmail] = useState('');
  const [role, setRole] = useState<'admin' | 'reviewer'>('reviewer');
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [confirm, setConfirm] = useState<string | null>(null);
  const [filter, setFilter] = useState('');
  async function add(e: React.FormEvent) {
    e.preventDefault();
    if (!/^\S+@\S+\.\S+$/.test(email.trim())) { setErr('Enter their email address.'); return; }
    setBusy('add'); setErr(null);
    try { await rpc('admin_add_staff', { p_email: email.trim(), p_role: role }); toast(`${email.trim()} added as ${role === 'admin' ? 'an admin' : 'a reviewer'}`); setEmail(''); await qc.invalidateQueries({ queryKey: ['admin-staff'] }); }
    catch (x) { setErr(tidyError(x)); }
    setBusy(null);
  }
  async function remove(s: Staff) {
    const id = s.user_id + s.role;
    if (confirm !== id) { setConfirm(id); return; }
    setBusy(id); setConfirm(null);
    try { await rpc('admin_remove_staff', { p_user: s.user_id, p_role: s.role }); toast('Removed'); await qc.invalidateQueries({ queryKey: ['admin-staff'] }); }
    catch (x) { toast(tidyError(x), 'err'); }
    setBusy(null);
  }
  const audit = (q.data?.audit || []).filter((a) => !filter || (a.email || '').toLowerCase().includes(filter.toLowerCase()) || describe(a).toLowerCase().includes(filter.toLowerCase()));
  return (
    <>
      <PageHead title="Admin team" sub="Admins can change everything in the portal. Reviewers see identity reviews only. Both need an authenticator app, which the portal sets up the first time they open it." />
      {q.isError && <Alert kind="red" icon="alert">{tidyError(q.error)}</Alert>}
      <Card title="People in the portal" pad={false}>
        {q.isLoading ? <div className="card-pad"><SkeletonRows n={3} /></div> : (q.data?.staff || []).map((s) => (
          <div key={s.user_id + s.role} className="adm-row" style={{ gridTemplateColumns: 'minmax(0,1.6fr) minmax(0,1fr) auto' }}>
            <div style={{ minWidth: 0 }}><b className="ellipsis" style={{ display: 'block' }}>{s.email}{s.me ? ' (you)' : ''}</b><span className="faint" style={{ fontSize: 12 }}>Added {fmtDay(s.added_at)}</span></div>
            <div className="row wrap" style={{ gap: 6 }}>
              <span className={'chip ' + (s.role === 'admin' ? 't-purple' : 't-blue')}>{s.role === 'admin' ? 'Admin' : 'Reviewer'}</span>
              <span className={'chip ' + (s.authenticator ? 't-green' : 't-amber')}>{s.authenticator ? 'Authenticator set' : 'No authenticator yet'}</span>
            </div>
            {s.me && s.role === 'admin' ? <span /> : (
              <button className={'btn btn-sm ' + (confirm === s.user_id + s.role ? 'btn-danger' : 'btn-ghost')} disabled={busy !== null} onClick={() => remove(s)} onBlur={() => setConfirm(null)}>
                {busy === s.user_id + s.role ? <Spinner small /> : null}{confirm === s.user_id + s.role ? 'Remove them' : 'Remove'}
              </button>
            )}
          </div>
        ))}
        <form onSubmit={add} className="stack" style={{ gap: 10, padding: 16, borderTop: '1px solid var(--line)' }}>
          <div className="row wrap" style={{ gap: 8, alignItems: 'center' }}>
            <input className="input" style={{ flex: '1 1 240px', minWidth: 0 }} type="email" placeholder="Their Counta email" value={email} onChange={(e) => setEmail(e.target.value)} aria-label="Email" />
            <Pills value={role} onChange={setRole} options={[{ id: 'reviewer', label: 'Reviewer' }, { id: 'admin', label: 'Admin' }]} />
            <button className="btn btn-primary" type="submit" disabled={busy !== null}>{busy === 'add' ? <Spinner small /> : <Icon name="plus" size={14} color="#fff" />}Add</button>
          </div>
          <div className="faint" style={{ fontSize: 12 }}>They need a Counta account first. An admin cannot remove themselves.</div>
          {err && <Alert kind="red" icon="alert">{err}</Alert>}
        </form>
      </Card>
      <Card title="Changes made in the portal" sub="The latest 200. Key values are never recorded, only that a key was set or removed."
        right={<input className="input" style={{ width: 220, maxWidth: '100%' }} placeholder="Filter" value={filter} onChange={(e) => setFilter(e.target.value)} aria-label="Filter changes" />} pad={false}>
        {q.isLoading ? <div className="card-pad"><SkeletonRows n={6} /></div> : !audit.length ? <div className="card-pad muted" style={{ fontSize: 14 }}>Nothing yet.</div> : audit.map((a, i) => (
          <div key={i} className="adm-row" style={{ gridTemplateColumns: '130px minmax(0,1fr)' }}>
            <span className="faint">{when(a.at)}</span>
            <span style={{ minWidth: 0 }}>{describe(a)}<div className="faint ellipsis" style={{ fontSize: 12 }}>{a.email || 'Counta'}</div></span>
          </div>
        ))}
      </Card>
    </>
  );
}
