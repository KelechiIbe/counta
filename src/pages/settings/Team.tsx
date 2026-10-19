// The team and what each role may do. A business keeps its own defaults per role; changing a role reaches everyone in it,
// and one person can still have their own exceptions. Invitations go by email with a one-time link. The database checks
// all of it again: nobody can hand out a permission they do not hold, and only the owner sets up admins.
import { useEffect, useMemo, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { useInventory, useSession } from '../../state/session';
import { useAction } from '../../lib/queries';
import { rpc } from '../../lib/supabase';
import { initials, when } from '../../lib/format';
import { PERMS, ROLE_LABEL, type Perm, type Role } from '../../lib/types';
import { Icon } from '../../components/Icon';
import { Alert, Field, Modal, ModalHead, SkeletonRows } from '../../components/ui';

type Perms = Record<Perm, boolean>;
export type TeamMember = {
  id: string; display_name: string; email: string | null; phone: string | null; role: Role; role_label: string; title: string | null; location_id: string | null;
  status: 'active' | 'invited' | 'disabled'; has_login: boolean; is_me: boolean; perms: Perms; overrides: Partial<Perms>;
  invite: { sent_at: string | null; expires_at: string | null; sent_count: number; expired: boolean } | null;
};
type RoleRow = { role: Exclude<Role, 'owner'>; label: string; perms: Perms; standard: Perms; changed: boolean; people: number };
export type Team = { can_manage: boolean; is_owner: boolean; me: string; my_perms: Perms; roles: RoleRow[]; members: TeamMember[] };

export const ROLE_BLURB: Record<string, string> = {
  admin: 'Runs the business with the owner: every permission, including the team and settings.',
  manager: 'Runs a branch day to day: sells, receives, counts and moves stock, sees margins.',
  accountant: 'Keeps the books, approves adjustments and files tax returns.',
  staff: 'Sells, receives and counts stock. Costs and margins stay hidden.',
  cashier: 'Records sales only.',
};
const GROUPS = [...new Set(PERMS.map((p) => p.group))];

export function useTeam() {
  const { orgId } = useSession();
  return useQuery({ queryKey: ['team', orgId], enabled: !!orgId, queryFn: () => rpc<Team>('get_team', { p_org: orgId }) });
}

// Sales and approving stock changes never sit with one person below admin.
const splitBroken = (role: string, p: Partial<Perms>) => role !== 'admin' && role !== 'owner' && !!p.record_sales && (!!p.edit_prices || !!p.approve_adjustments);

function Toggle({ on, onChange, disabled, label }: { on: boolean; onChange: (v: boolean) => void; disabled?: boolean; label: string }) {
  return (
    <button type="button" role="switch" aria-checked={on} aria-label={label} disabled={disabled} className={'tgl' + (on ? ' on' : '')} onClick={() => onChange(!on)}>
      <span />
    </button>
  );
}

// ---------------------------------------------------------------- roles
export function RolesCard() {
  const team = useTeam();
  const t = team.data;
  const [role, setRole] = useState<RoleRow['role']>('manager');
  const [draft, setDraft] = useState<Perms | null>(null);
  const row = t?.roles.find((r) => r.role === role);
  useEffect(() => { setDraft(row ? { ...row.perms } : null); }, [row?.role, JSON.stringify(row?.perms)]); // eslint-disable-line react-hooks/exhaustive-deps
  if (team.isLoading) return <SkeletonRows n={4} />;
  if (!t || !row || !draft) return null;
  const mine = t.roles.find((r) => r.role === (t.members.find((m) => m.is_me)?.role as any));
  const locked = !t.can_manage || (role === 'admin' && !t.is_owner) || (!t.is_owner && mine?.role === role);
  const dirty = PERMS.some((p) => draft[p.key] !== row.perms[p.key]);
  const broken = splitBroken(role, draft);
  const why = !t.can_manage ? 'Only someone who manages the team changes roles.' : role === 'admin' && !t.is_owner ? 'Only the owner changes what admins can do.'
    : !t.is_owner && mine?.role === role ? 'Ask the owner to change your own role.' : '';
  return (
    <div className="stack" style={{ gap: 14 }}>
      <div className="row wrap" style={{ gap: 6 }} role="tablist" aria-label="Role">
        {t.roles.map((r) => (
          <button key={r.role} role="tab" aria-selected={r.role === role} className={'pill' + (r.role === role ? ' on' : '')} onClick={() => setRole(r.role)}>
            {r.label}<span className="faint" style={{ marginLeft: 6, fontSize: 11 }}>{r.people}</span>
          </button>
        ))}
      </div>
      <div className="muted" style={{ fontSize: 13, lineHeight: 1.5 }}>
        {ROLE_BLURB[role]} {row.people ? `${row.people} ${row.people === 1 ? 'person has' : 'people have'} this role; a change reaches all of them, keeping anyone's own exceptions.` : 'Nobody has this role yet.'}
      </div>
      {why && <Alert kind="grey" icon="lock">{why}</Alert>}
      <div className="perm-list">
        {GROUPS.map((g) => (
          <div key={g} className="perm-group">
            <div className="mini-label">{g}</div>
            {PERMS.filter((p) => p.group === g).map((p) => {
              const cant = !t.is_owner && !t.my_perms[p.key] && !draft[p.key];
              return (
                <div key={p.key} className="perm-line">
                  <div style={{ minWidth: 0 }}>
                    <div style={{ fontWeight: 600, fontSize: 14 }}>{p.label}{draft[p.key] !== row.standard[p.key] && <span className="chip t-blue" style={{ marginLeft: 8, fontSize: 10 }}>changed</span>}</div>
                    <div className="faint" style={{ fontSize: 12, lineHeight: 1.45 }}>{p.hint}</div>
                  </div>
                  <Toggle on={!!draft[p.key]} disabled={locked || cant} label={`${p.label} for ${row.label}`}
                    onChange={(v) => setDraft((d) => ({ ...(d as Perms), [p.key]: v }))} />
                </div>
              );
            })}
          </div>
        ))}
      </div>
      {broken && <Alert kind="amber" icon="shield">Someone who records sales cannot also edit prices or approve adjustments. Turn one of them off.</Alert>}
      {!locked && (
        <div className="row wrap" style={{ gap: 8 }}>
          <SaveRole role={role} draft={draft} disabled={!dirty || broken} people={row.people} label={row.label} />
          {dirty && <button className="btn btn-ghost" onClick={() => setDraft({ ...row.perms })}>Undo</button>}
          {row.changed && !dirty && <ResetRole role={role} standard={row.standard} label={row.label} />}
        </div>
      )}
    </div>
  );
}

function SaveRole({ role, draft, disabled, people, label }: { role: string; draft: Perms; disabled: boolean; people: number; label: string }) {
  const { orgId } = useSession();
  const { run, busy } = useAction();
  return (
    <button className="btn btn-primary" disabled={disabled || busy}
      onClick={() => run(() => rpc('save_role_permissions', { p_org: orgId, p_role: role, p_perms: draft }),
        { ok: people ? `${label} saved · ${people} ${people === 1 ? 'person' : 'people'} updated` : `${label} saved`, invalidate: ['team', 'inv'] })}>
      Save {label}{people ? ` · ${people} ${people === 1 ? 'person' : 'people'}` : ''}
    </button>
  );
}

function ResetRole({ role, standard, label }: { role: string; standard: Perms; label: string }) {
  const { orgId } = useSession();
  const { run, busy } = useAction();
  return (
    <button className="btn btn-secondary" disabled={busy}
      onClick={() => run(() => rpc('save_role_permissions', { p_org: orgId, p_role: role, p_perms: standard }), { ok: `${label} is back to Counta's standard`, invalidate: ['team', 'inv'] })}>
      Back to Counta's standard
    </button>
  );
}

// ---------------------------------------------------------------- people
export function inviteStatus(m: TeamMember) {
  if (m.status === 'disabled') return { text: 'No access', tone: 'grey' };
  if (m.status === 'invited') {
    if (!m.invite?.sent_at) return { text: 'Invitation not sent yet', tone: 'amber' };
    if (m.invite.expired) return { text: 'Invitation expired', tone: 'red' };
    return { text: `Invited ${when(m.invite.sent_at)}`, tone: 'amber' };
  }
  return m.has_login ? { text: 'Joined', tone: 'green' } : { text: 'No login', tone: 'grey' };
}

export function PeopleCard({ compact, onCall }: { compact?: boolean; onCall?: (m: TeamMember) => void }) {
  const team = useTeam();
  const { data: inv } = useInventory();
  const { run, busy } = useAction();
  const [person, setPerson] = useState<TeamMember | 'new' | null>(null);
  const t = team.data;
  if (team.isLoading) return <SkeletonRows n={4} />;
  if (!t) return null;
  const loc = (id: string | null) => inv?.locations.find((l) => l.id === id)?.name || 'All branches';
  const shown = t.members.filter((m) => m.status !== 'disabled');
  const gone = t.members.filter((m) => m.status === 'disabled');
  return (
    <div className="stack" style={{ gap: 10 }}>
      {t.can_manage && <div><button className="btn btn-primary btn-sm" onClick={() => setPerson('new')}><Icon name="plus" size={14} color="#fff" />Invite person</button></div>}
      <div className="people">
        {shown.map((m) => {
          const s = inviteStatus(m);
          const own = Object.keys(m.overrides || {}).length;
          return (
            <div key={m.id} className="person-row">
              <span className="org-ini" style={{ width: 34, height: 34, fontSize: 11, borderRadius: 9, flex: 'none' }}>{initials(m.display_name)}</span>
              <div style={{ minWidth: 0, flex: 1 }}>
                <div style={{ fontWeight: 600 }} className="ellipsis">{m.display_name}{m.is_me ? ' (you)' : ''}</div>
                <div className="faint ellipsis" style={{ fontSize: 12 }}>{m.role_label}{m.title && m.title !== m.role_label ? ` · ${m.title}` : ''}{compact ? '' : ` · ${loc(m.location_id)}`}{m.email ? ` · ${m.email}` : ''}{own ? ` · ${own} own permission${own === 1 ? '' : 's'}` : ''}</div>
              </div>
              <span className={'chip t-' + s.tone} style={{ flex: 'none' }}>{s.text}</span>
              {t.can_manage && m.status === 'invited' && m.email && (
                <button className="btn btn-ghost btn-xs" disabled={busy} onClick={() => run(() => rpc('resend_invite', { p_member: m.id }), { ok: `Invitation sent to ${m.email}`, invalidate: ['team'] })}>
                  {m.invite?.sent_at ? 'Send again' : 'Send invitation'}
                </button>
              )}
              {onCall && !m.is_me && m.status === 'active' && m.phone && (
                <button className="icon-btn" title={`Have Martina call ${m.display_name.split(' ')[0]}`} aria-label={`Call ${m.display_name}`} onClick={() => onCall(m)}><Icon name="call" size={15} color="#6B7280" /></button>
              )}
              {t.can_manage && m.role !== 'owner' && !(m.role === 'admin' && !t.is_owner) && <button className="btn btn-ghost btn-xs" onClick={() => setPerson(m)}>Edit</button>}
            </div>
          );
        })}
      </div>
      {gone.length > 0 && <div className="faint" style={{ fontSize: 12 }}>No longer with access: {gone.map((m) => m.display_name).join(', ')}.</div>}
      {person && <PersonModal team={t} member={person === 'new' ? null : person} onClose={() => setPerson(null)} />}
    </div>
  );
}

export function PersonModal({ team, member, onClose }: { team: Team; member: TeamMember | null; onClose: () => void }) {
  const { orgId } = useSession();
  const { data: inv } = useInventory();
  const { run, busy } = useAction();
  const [f, setF] = useState({ name: member?.display_name || '', email: member?.email || '', phone: member?.phone || '', title: member?.title || '',
    role: (member?.role || 'staff') as Exclude<Role, 'owner'>, location_id: member?.location_id || '' });
  const roleRow = team.roles.find((r) => r.role === f.role)!;
  // What this person will hold: the role's permissions, with their own exceptions (cleared when the role changes).
  const [own, setOwn] = useState<Partial<Perms>>(member?.overrides || {});
  const [err, setErr] = useState<string | null>(null);
  const [confirmOff, setConfirmOff] = useState(false);
  const roleChanged = !!member && f.role !== member.role;
  useEffect(() => { if (roleChanged) setOwn({}); }, [f.role]); // eslint-disable-line react-hooks/exhaustive-deps
  const effective = useMemo(() => ({ ...roleRow.perms, ...own }) as Perms, [roleRow, own]);
  const set = (k: keyof typeof f, v: string) => setF((x) => ({ ...x, [k]: v }));
  const roles = team.roles.filter((r) => r.role !== 'admin' || team.is_owner);
  const broken = splitBroken(f.role, effective);
  async function save() {
    setErr(null);
    if (!f.name.trim()) { setErr("Enter the person's name."); return; }
    if (!member && f.email && !/^\S+@\S+\.\S+$/.test(f.email.trim())) { setErr('That email address does not look right.'); return; }
    if (broken) { setErr('Someone who records sales cannot also edit prices or approve adjustments.'); return; }
    const r = await run(() => member
      ? rpc('update_member', { p_member: member.id, p_patch: { display_name: f.name, role: f.role, title: f.title, phone: f.phone, location_id: f.location_id || '',
          reset_perms: true, perms: own } })
      : rpc('invite_member', { p_org: orgId, p_name: f.name, p_email: f.email.trim() || null, p_role: f.role, p_title: f.title || null, p_location: f.location_id || null, p_phone: f.phone || null }),
    { ok: member ? 'Saved' : f.email.trim() ? `Invitation sent to ${f.email.trim()} · the link works for seven days` : `${f.name.split(' ')[0]} added without a login`, invalidate: ['team', 'inv'] });
    if (r !== undefined) onClose();
  }
  async function disable() {
    if (!member) return;
    if (!confirmOff) { setConfirmOff(true); return; }
    const r = await run(() => rpc('update_member', { p_member: member.id, p_patch: { status: 'disabled' } }), { ok: `${member.display_name.split(' ')[0]} no longer has access`, invalidate: ['team', 'inv'] });
    if (r !== undefined) onClose();
  }
  return (
    <Modal onClose={onClose} width={560}>
      <ModalHead title={member ? member.display_name : 'Invite person'} sub={member ? `${member.role_label}${member.email ? ' · ' + member.email : ''}` : 'They get an email with a link to join. It works once, for seven days.'} onClose={onClose} />
      <div className="modal-body">
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <Field label="Full name" req><input className="input" value={f.name} onChange={(e) => set('name', e.target.value)} /></Field>
          <Field label="Job title"><input className="input" value={f.title} onChange={(e) => set('title', e.target.value)} placeholder="e.g. Store assistant" /></Field>
        </div>
        {!member && <Field label="Email" hint="The invitation goes here. Leave it blank for someone who will not sign in (their name still shows on counts and voice entries)."><input className="input" type="email" value={f.email} onChange={(e) => set('email', e.target.value)} placeholder="name@business.com" /></Field>}
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <Field label="Role">
            <select className="input" value={f.role} onChange={(e) => set('role', e.target.value)}>
              {roles.map((r) => <option key={r.role} value={r.role}>{r.label}</option>)}
            </select>
          </Field>
          <Field label="Branch">
            <select className="input" value={f.location_id} onChange={(e) => set('location_id', e.target.value)}>
              <option value="">All branches</option>
              {(inv?.locations || []).map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}
            </select>
          </Field>
        </div>
        <Field label="Mobile number" hint="For Martina's reminder calls."><input className="input" type="tel" value={f.phone} onChange={(e) => set('phone', e.target.value)} placeholder="0803 123 4567" /></Field>
        <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }}>{ROLE_BLURB[f.role]}</div>
        {member && (
          <details className="perm-own" open={Object.keys(own).length > 0}>
            <summary>Permissions for {f.name.split(' ')[0] || 'this person'} {Object.keys(own).length ? `· ${Object.keys(own).length} of their own` : '· as the role'}</summary>
            <div className="stack" style={{ gap: 4, marginTop: 8 }}>
              {PERMS.map((p) => {
                const differs = p.key in own;
                const cant = !team.is_owner && !team.my_perms[p.key] && !effective[p.key];
                return (
                  <div key={p.key} className="perm-line" style={{ padding: '6px 0' }}>
                    <div style={{ minWidth: 0, fontSize: 13 }}><b style={{ fontWeight: 600 }}>{p.label}</b>{differs && <span className="chip t-blue" style={{ marginLeft: 8, fontSize: 10 }}>own</span>}</div>
                    <Toggle on={!!effective[p.key]} disabled={cant || busy} label={`${p.label} for ${f.name}`}
                      onChange={(v) => setOwn((o) => { const n = { ...o }; if (v === roleRow.perms[p.key]) delete n[p.key]; else n[p.key] = v; return n; })} />
                  </div>
                );
              })}
              {Object.keys(own).length > 0 && <div><button className="btn btn-ghost btn-xs" onClick={() => setOwn({})}>Use the {roleRow.label.toLowerCase()} role's permissions</button></div>}
            </div>
          </details>
        )}
        {broken && <Alert kind="amber" icon="shield">Someone who records sales cannot also edit prices or approve adjustments.</Alert>}
        {err && <Alert kind="red" icon="alert">{err}</Alert>}
      </div>
      <div className="modal-ft">
        {member && member.status !== 'disabled' && <button className="btn btn-danger" onClick={disable} disabled={busy} style={{ marginRight: 'auto' }}>{confirmOff ? 'Tap again to remove access' : 'Remove access'}</button>}
        <button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" onClick={save} disabled={busy || broken}>{member ? 'Save' : f.email.trim() ? 'Send invitation' : 'Add person'}</button>
      </div>
    </Modal>
  );
}
