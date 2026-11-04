// The business's logins to the tax portals (NRS Rev360, LIRS e-Tax and the other state revenue services), in Settings.
// Flux signs in with them to file the returns Counta prepares. A login goes straight to Flux through the tax-files
// function and is kept there; Counta keeps only which portal, a hint of the username, the tax office and Flux's reference.
// The owner saves and removes them; those who file tax see which are saved. See docs/flux-pit-handoff.md.
import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useSession, useToast } from '../../state/session';
import { rpc } from '../../lib/supabase';
import { edge } from '../../lib/api';
import { when } from '../../lib/format';
import { Icon } from '../../components/Icon';
import { Alert, Field, SkeletonRows, Spinner } from '../../components/ui';

type Authority = { code: string; name: string; short_name: string | null; state: string | null; kind: string; portal: string };
type Login = { authority: string; authority_name: string; short_name: string | null; portal: string; username_hint: string | null; tax_office: string | null;
  status: 'saved' | 'verified' | 'failed'; message: string | null; saved_at: string; checked_at: string | null; saved_by: string | null };
type Logins = { can_manage: boolean; logins: Login[]; authorities: Authority[] };

export const usePortalLogins = (enabled = true) => {
  const { orgId } = useSession();
  return useQuery({ queryKey: ['portal-logins', orgId], enabled: !!orgId && enabled, retry: false, queryFn: () => rpc<Logins>('portal_logins', { p_org: orgId }) });
};

const STATUS: Record<string, { label: string; tone: string }> = {
  saved: { label: 'With Flux', tone: 't-blue' }, verified: { label: 'Working', tone: 't-green' }, failed: { label: 'Did not work', tone: 't-red' },
};
const authorityLabel = (a: Authority) => (a.code === 'NRS' ? 'Nigeria Revenue Service (Rev360)' : `${a.state} · ${a.short_name || a.name}`);

export function PortalLoginsPanel() {
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const q = usePortalLogins();
  const [f, setF] = useState({ authority: 'SIRS:LA', username: '', password: '', tax_office: '' });
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [removing, setRemoving] = useState<string | null>(null);
  if (q.isLoading) return <SkeletonRows n={3} />;
  if (q.error) return <Alert kind="grey" icon="lock">{(q.error as Error).message}</Alert>;
  const d = q.data!;
  const list = d.logins || [];
  const auths = d.authorities || [];
  const chosen = auths.find((a) => a.code === f.authority);
  const existing = list.find((l) => l.authority === f.authority);
  const refresh = () => Promise.all([qc.invalidateQueries({ queryKey: ['portal-logins'] }), qc.invalidateQueries({ queryKey: ['pit-year'] })]);

  async function save() {
    setBusy('save'); setErr(null);
    try {
      const r = await edge<any>('tax-files', { action: 'portal_login_save', org_id: orgId, authority: f.authority, username: f.username, password: f.password, tax_office: f.tax_office });
      if (r.ok === false) { setErr(r.error || 'The login was not saved.'); return; }
      setF((x) => ({ ...x, username: '', password: '', tax_office: '' }));
      toast(`The ${chosen?.short_name || chosen?.name || 'portal'} login is with Flux`);
      await refresh();
    } finally { setBusy(null); }
  }
  async function remove(code: string) {
    setBusy('rm-' + code); setErr(null);
    try {
      const r = await edge<any>('tax-files', { action: 'portal_login_remove', org_id: orgId, authority: code });
      if (r.ok === false) { setErr(r.error || 'The login was not removed.'); return; }
      toast('Login removed'); setRemoving(null); await refresh();
    } finally { setBusy(null); }
  }

  return (
    <div className="stack" style={{ gap: 14 }} data-testid="portal-logins">
      {list.length === 0 ? <div className="faint" style={{ fontSize: 13 }}>No login saved yet.</div> : (
        <div className="stack" style={{ gap: 0 }}>
          {list.map((l) => {
            const s = STATUS[l.status] || STATUS.saved;
            return (
              <div key={l.authority} className="row wrap" data-testid="portal-login-row" data-authority={l.authority}
                style={{ gap: 10, justifyContent: 'space-between', alignItems: 'flex-start', padding: '10px 0', borderTop: '1px solid var(--line, #EEE)' }}>
                <div style={{ minWidth: 0, flex: '1 1 240px' }}>
                  <div style={{ fontSize: 14, fontWeight: 600 }}>{l.authority === 'NRS' ? 'NRS' : `${auths.find((a) => a.code === l.authority)?.state || ''} ${l.short_name || l.authority_name}`.trim()} <span className="faint" style={{ fontWeight: 400 }}>· {l.portal}</span></div>
                  <div className="muted" style={{ fontSize: 13 }}>Username {l.username_hint || 'saved'}{l.tax_office ? ` · ${l.tax_office} tax office` : ''}</div>
                  <div className="faint" style={{ fontSize: 12 }}>Saved{l.saved_by ? ` by ${l.saved_by}` : ''} {when(l.saved_at)}{l.checked_at ? ` · checked ${when(l.checked_at)}` : ''}</div>
                  {l.status === 'failed' && l.message && <div style={{ fontSize: 12, color: '#B91C1C', marginTop: 2 }}>{l.message}</div>}
                </div>
                <span className="row" style={{ gap: 6 }}>
                  <span className={'chip ' + s.tone}>{s.label}</span>
                  {d.can_manage && (removing === l.authority ? (
                    <>
                      <button className="btn btn-ghost btn-xs" disabled={!!busy} onClick={() => remove(l.authority)} style={{ color: '#B91C1C' }}>
                        {busy === 'rm-' + l.authority ? <Spinner small /> : <Icon name="trash" size={12} />}Remove from Flux</button>
                      <button className="btn btn-ghost btn-xs" disabled={!!busy} onClick={() => setRemoving(null)}>Keep</button>
                    </>
                  ) : (
                    <>
                      <button className="btn btn-ghost btn-xs" disabled={!!busy} onClick={() => setF({ authority: l.authority, username: '', password: '', tax_office: l.tax_office || '' })}>Replace</button>
                      <button className="btn btn-ghost btn-xs" disabled={!!busy} onClick={() => setRemoving(l.authority)} aria-label={`Remove the ${l.short_name || l.authority_name} login`}>Remove</button>
                    </>
                  ))}
                </span>
              </div>
            );
          })}
        </div>
      )}

      {d.can_manage ? (
        <div className="card" style={{ padding: 14, borderRadius: 10 }} data-testid="portal-login-form">
          <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
            <Field label="Tax authority" style={{ gridColumn: '1 / -1' }}>
              <select className="input" aria-label="Tax authority" value={f.authority} onChange={(e) => setF({ ...f, authority: e.target.value })}>
                {auths.map((a) => <option key={a.code} value={a.code}>{authorityLabel(a)}</option>)}
              </select>
            </Field>
            <Field label={`Username on ${chosen?.portal || 'the portal'}`}>
              <input className="input" aria-label="Username" autoComplete="off" spellCheck={false} value={f.username} onChange={(e) => setF({ ...f, username: e.target.value })} />
            </Field>
            <Field label="Password">
              <input className="input" aria-label="Password" type="password" autoComplete="new-password" value={f.password} onChange={(e) => setF({ ...f, password: e.target.value })} />
            </Field>
            <Field label="Tax office (optional)" hint="The office the business files with, as the portal names it." style={{ gridColumn: '1 / -1' }}>
              <input className="input" aria-label="Tax office" value={f.tax_office} onChange={(e) => setF({ ...f, tax_office: e.target.value })} placeholder={f.authority === 'SIRS:LA' ? 'For example, Ikeja' : undefined} />
            </Field>
          </div>
          {err && <div style={{ marginTop: 10 }}><Alert kind="red" icon="info">{err}</Alert></div>}
          <div className="row wrap" style={{ gap: 10, marginTop: 12, alignItems: 'center' }}>
            <button className="btn btn-primary btn-sm" disabled={!!busy || !f.username.trim() || !f.password} onClick={save} data-testid="portal-login-save">
              {busy === 'save' ? <Spinner small /> : <Icon name="lock" size={14} color="#fff" />}{existing ? 'Replace the login' : 'Save to Flux'}</button>
            <span className="faint" style={{ fontSize: 12, lineHeight: 1.5, flex: '1 1 260px' }}>The password goes straight to TaxStreem Flux and is not kept in Counta. Nobody here can see it again.</span>
          </div>
        </div>
      ) : <div className="faint" style={{ fontSize: 12 }}>Only the owner saves or removes the business's tax portal logins.</div>}
    </div>
  );
}

