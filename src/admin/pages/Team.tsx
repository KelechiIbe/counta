// TaxStreem's own people in the portal (admins see everything, reviewers only identity reviews), the invitations still
// waiting, and the record of every change anyone made here. Adding someone goes through the admin function, which sends
// the welcome (or the invitation, to someone not on Counta yet) and tells every other admin.
import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { rpc } from '../../lib/supabase';
import { edge } from '../../lib/api';
import { fmtDay, when } from '../../lib/format';
import { useToast } from '../../state/session';
import { Icon } from '../../components/Icon';
import { Alert, Pills, SkeletonRows, Spinner } from '../../components/ui';
import { featureLabel, pct, tidyError } from '../api';
import { Card, PageHead } from '../ui';

type Staff = { user_id: string; email: string; role: 'admin' | 'reviewer'; added_at: string; me: boolean; authenticator: boolean; welcomed_at: string | null };
type Invite = { id: string; email: string; role: 'admin' | 'reviewer'; invited_at: string; invited_by: string | null; sent_at: string | null; expires: string | null;
  expired: boolean; last_error: string | null };
type Added = { ok?: boolean; error?: string; status?: 'added' | 'invited' | 'already'; email?: string; role?: string; sent?: boolean; mail_error?: string };
const roleWord = (r: string) => (r === 'admin' ? 'an admin' : 'a reviewer');
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
    case 'invite_staff': return `Invited ${a.target} to be ${roleWord(d.role)}`;
    case 'resend_staff_invite': return `Sent the invitation to ${a.target} again`;
    case 'withdraw_staff_invite': return `Withdrew the invitation to ${a.target}`;
    case 'accept_staff_invite': return `Accepted the invitation as ${roleWord(d.role)}`;
    case 'resend_staff_welcome': return `Sent ${a.target} the welcome again`;
    case 'delete_business': return `Deleted the business ${d.name}${d.logins_removed ? `, with ${d.logins_removed} login${d.logins_removed === 1 ? '' : 's'}` : ''}${d.samples ? ` and ${d.samples === 1 ? 'a sample business' : `${d.samples} sample businesses`}` : ''}${d.finished ? '' : ' (not finished)'}`;
    case 'review_identity': return `${d.approved === false ? 'Turned down' : 'Approved'} an identity check${d.note ? `: ${d.note}` : ''}`;
    default: return a.action.replace(/_/g, ' ') + (a.target ? ` ${a.target}` : '');
  }
}

export default function Team() {
  const qc = useQueryClient();
  const toast = useToast();
  const q = useQuery({ queryKey: ['admin-staff'], queryFn: () => rpc<{ staff: Staff[]; invites: Invite[]; audit: Audit[] }>('admin_staff') });
  const [email, setEmail] = useState('');
  const [role, setRole] = useState<'admin' | 'reviewer'>('reviewer');
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [warn, setWarn] = useState<string | null>(null);
  const [confirm, setConfirm] = useState<string | null>(null);
  const [filter, setFilter] = useState('');
  const refresh = () => qc.invalidateQueries({ queryKey: ['admin-staff'] });
  async function add(e: React.FormEvent) {
    e.preventDefault();
    if (!/^\S+@\S+\.\S+$/.test(email.trim())) { setErr('Enter their email address.'); return; }
    setBusy('add'); setErr(null); setWarn(null);
    const r = await edge<Added>('admin', { action: 'add_staff', email: email.trim(), role });
    setBusy(null);
    if (r.ok === false) { setErr(tidyError(r.error)); return; }
    const who = r.email || email.trim();
    if (r.status === 'already') toast(`${who} is already ${roleWord(role)}`);
    else if (!r.sent) setWarn(`${r.status === 'invited' ? `${who} is invited to be ${roleWord(role)}` : `${who} is now ${roleWord(role)}`}, but the email did not go: ${r.mail_error || 'no reason given'}`);
    else toast(r.status === 'invited' ? `Invitation sent to ${who}` : `${who} is now ${roleWord(role)}. We emailed them the link.`);
    setEmail('');
    await refresh();
  }
  // The invitation or the welcome, again.
  async function again(id: string, body: Record<string, unknown>, done: string) {
    setBusy(id);
    const r = await edge<{ ok?: boolean; error?: string; email?: string }>('admin', body);
    setBusy(null);
    if (r.ok === false) toast(tidyError(r.error), 'err'); else toast(done);
    await refresh();
  }
  async function withdraw(i: Invite) {
    const id = 'w' + i.id;
    if (confirm !== id) { setConfirm(id); return; }
    setBusy(id); setConfirm(null);
    try { await rpc('admin_withdraw_staff_invite', { p_id: i.id }); toast('Invitation withdrawn'); await refresh(); }
    catch (x) { toast(tidyError(x), 'err'); }
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
            <div style={{ minWidth: 0 }}><b className="ellipsis" style={{ display: 'block' }}>{s.email}{s.me ? ' (you)' : ''}</b><span className="faint" style={{ fontSize: 12 }}>
              Added {fmtDay(s.added_at)}{!s.authenticator ? (s.welcomed_at ? ` · Emailed ${fmtDay(s.welcomed_at)}` : ' · Not emailed yet') : ''}</span></div>
            <div className="row wrap" style={{ gap: 6 }}>
              <span className={'chip ' + (s.role === 'admin' ? 't-purple' : 't-blue')}>{s.role === 'admin' ? 'Admin' : 'Reviewer'}</span>
              <span className={'chip ' + (s.authenticator ? 't-green' : 't-amber')}>{s.authenticator ? 'Authenticator set' : 'No authenticator yet'}</span>
            </div>
            <div className="row" style={{ gap: 4, justifyContent: 'flex-end' }}>
              {!s.authenticator && !s.me && (
                <button className="btn btn-sm btn-ghost" disabled={busy !== null} data-testid="staff-email-again"
                  onClick={() => again('e' + s.user_id + s.role, { action: 'resend_staff_welcome', user_id: s.user_id, role: s.role }, `Emailed ${s.email} the link again`)}>
                  {busy === 'e' + s.user_id + s.role ? <Spinner small /> : <Icon name="mail" size={14} />}Email again
                </button>
              )}
              {s.me && s.role === 'admin' ? null : (
                <button className={'btn btn-sm ' + (confirm === s.user_id + s.role ? 'btn-danger' : 'btn-ghost')} disabled={busy !== null} onClick={() => remove(s)} onBlur={() => setConfirm(null)}>
                  {busy === s.user_id + s.role ? <Spinner small /> : null}{confirm === s.user_id + s.role ? 'Remove them' : 'Remove'}
                </button>
              )}
            </div>
          </div>
        ))}
        {(q.data?.invites || []).length > 0 && (
          <div style={{ borderTop: '1px solid var(--line)' }} data-testid="staff-invites">
            <div className="mini-label" style={{ padding: '12px 16px 0' }}>Invitations waiting</div>
            {(q.data?.invites || []).map((i) => (
              <div key={i.id} className="adm-row" style={{ gridTemplateColumns: 'minmax(0,1.6fr) minmax(0,1fr) auto' }}>
                <div style={{ minWidth: 0 }}>
                  <b className="ellipsis" style={{ display: 'block' }}>{i.email}</b>
                  <span className="faint" style={{ fontSize: 12 }}>Invited {fmtDay(i.invited_at)}{i.invited_by ? ` by ${i.invited_by}` : ''}
                    {i.sent_at && !i.last_error ? (i.expired ? ' · The link has expired' : ` · Link works until ${fmtDay(i.expires)}`) : ''}</span>
                  {i.last_error && <div style={{ fontSize: 12, color: 'var(--red)', marginTop: 2 }}>The email did not go: {i.last_error}</div>}
                </div>
                <div className="row wrap" style={{ gap: 6 }}>
                  <span className={'chip ' + (i.role === 'admin' ? 't-purple' : 't-blue')}>{i.role === 'admin' ? 'Admin' : 'Reviewer'}</span>
                  <span className={'chip ' + (i.expired || i.last_error ? 't-amber' : 't-grey')}>{i.expired ? 'Expired' : i.last_error ? 'Not sent' : 'Waiting'}</span>
                </div>
                <div className="row" style={{ gap: 4, justifyContent: 'flex-end' }}>
                  <button className="btn btn-sm btn-ghost" disabled={busy !== null} data-testid="invite-resend"
                    onClick={() => again('r' + i.id, { action: 'resend_staff_invite', id: i.id }, `Invitation sent to ${i.email} again`)}>
                    {busy === 'r' + i.id ? <Spinner small /> : <Icon name="mail" size={14} />}Resend
                  </button>
                  <button className={'btn btn-sm ' + (confirm === 'w' + i.id ? 'btn-danger' : 'btn-ghost')} disabled={busy !== null} data-testid="invite-withdraw"
                    onClick={() => withdraw(i)} onBlur={() => setConfirm(null)}>
                    {busy === 'w' + i.id ? <Spinner small /> : null}{confirm === 'w' + i.id ? 'Withdraw it' : 'Withdraw'}
                  </button>
                </div>
              </div>
            ))}
          </div>
        )}
        <form onSubmit={add} className="stack" style={{ gap: 10, padding: 16, borderTop: '1px solid var(--line)' }}>
          <div className="row wrap" style={{ gap: 8, alignItems: 'center' }}>
            <input className="input" style={{ flex: '1 1 240px', minWidth: 0 }} type="email" placeholder="Their email" value={email} onChange={(e) => setEmail(e.target.value)} aria-label="Email" />
            <Pills value={role} onChange={setRole} options={[{ id: 'reviewer', label: 'Reviewer' }, { id: 'admin', label: 'Admin' }]} />
            <button className="btn btn-primary" type="submit" disabled={busy !== null}>{busy === 'add' ? <Spinner small /> : <Icon name="plus" size={14} color="#fff" />}Add</button>
          </div>
          <div className="faint" style={{ fontSize: 12 }}>Someone with a Counta account gets the role at once and an email with the link to the portal. Anyone else gets an
            invitation by email: they sign up with that address, and the link works once, for seven days. Every admin is emailed when someone is added or accepts.
            An admin cannot remove themselves. Reviewers get an email whenever a NIN slip waits for review, as does the address under Keys and services, Counta
            (admin@taxstreem.com unless changed).</div>
          {warn && <Alert kind="amber" icon="alert">{warn}</Alert>}
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
