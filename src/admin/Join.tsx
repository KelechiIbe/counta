// The page an admin portal invitation opens: /admin/join?t=<token>. It says who sent it and for which role before anyone
// signs in, sends a new person to sign up with the invited address (and back here), and accepts for the person it was for.
// Accepting goes through the admin function, which tells every admin; the portal then asks them to set up an authenticator.
import { useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { rpc } from '../lib/supabase';
import { edge } from '../lib/api';
import { useSession } from '../state/session';
import { Alert, Spinner } from '../components/ui';
import { Icon } from '../components/Icon';
import { BrandSide } from '../pages/auth/Auth';

type Preview = { status: 'open' | 'used' | 'expired' | 'withdrawn' | 'invalid'; email?: string; role?: 'admin' | 'reviewer'; invited_by?: string | null };

export default function AdminJoin() {
  const [params] = useSearchParams();
  const token = (params.get('t') || '').trim().toLowerCase();
  const valid = /^sa_[0-9a-f]{48}$/.test(token);
  const { session, ready, signOut } = useSession();
  const qc = useQueryClient();
  const nav = useNavigate();
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const preview = useQuery({ queryKey: ['admin-invite', token], enabled: valid, retry: 1, queryFn: () => rpc<Preview>('admin_staff_invite_preview', { p_token: token }) });
  const p: Preview | undefined = valid ? preview.data : { status: 'invalid' };
  const here = `/admin/join?t=${token}`;
  const myEmail = (session?.user.email || '').toLowerCase();
  const role = p?.role === 'admin' ? 'an admin' : 'a reviewer';

  async function accept() {
    setBusy(true); setErr(null);
    const r = await edge<{ ok?: boolean; error?: string }>('admin', { action: 'accept_staff_invite', token });
    if (r.ok === false) { setErr(r.error || 'The invitation could not be accepted just now.'); setBusy(false); return; }
    // The link is used now: coming back to it says so.
    qc.setQueryData(['admin-invite', token], (old: Preview | undefined) => (old ? { ...old, status: 'used' } : old));
    await qc.invalidateQueries({ queryKey: ['admin-me'] });
    nav('/admin', { replace: true });
  }

  let body;
  if (!ready || (valid && preview.isLoading)) body = <div className="row" style={{ justifyContent: 'center', padding: 30 }}><Spinner /></div>;
  else if (preview.isError) body = <Alert kind="red" icon="alert">The invitation could not be checked just now. Refresh the page to try again.</Alert>;
  else if (!p || p.status === 'invalid') body = <Alert kind="amber" icon="alert">This invitation link is not complete, or a newer one has replaced it. Open the latest email, or ask a TaxStreem admin to send it again.</Alert>;
  else if (p.status === 'used') body = <><Alert kind="blue" icon="check">This invitation has already been accepted.</Alert><Link className="btn btn-primary btn-block" to="/admin">Open the admin portal</Link></>;
  else if (p.status === 'withdrawn') body = <Alert kind="amber" icon="alert">This invitation was withdrawn. Ask a TaxStreem admin if you think that is a mistake.</Alert>;
  else if (p.status === 'expired') body = <Alert kind="amber" icon="clock">This invitation has expired. Ask a TaxStreem admin to send it again; each link works for seven days.</Alert>;
  else if (!session) {
    const q = (path: string) => `${path}?${new URLSearchParams({ ...(p.email ? { email: p.email } : {}), next: here }).toString()}`;
    body = (
      <>
        <div className="stack" style={{ gap: 10 }}>
          <Link className="btn btn-primary btn-block" to={q('/signup')} style={{ padding: '12px 16px' }} data-testid="admin-join-signup">Create my account</Link>
          <Link className="btn btn-secondary btn-block" to={q('/login')} style={{ padding: '12px 16px' }}>I already have a Counta account</Link>
        </div>
        <div className="hint">Use {p.email}, the address this invitation went to.</div>
      </>
    );
  } else if (myEmail !== (p.email || '').toLowerCase()) {
    body = (
      <>
        <Alert kind="amber" icon="alert">You are signed in as {session.user.email}. This invitation is for {p.email}. Sign out, then open the link again and sign in with that address.</Alert>
        <button className="btn btn-secondary btn-block" onClick={async () => { await signOut(); qc.clear(); }}>Sign out</button>
      </>
    );
  } else {
    body = (
      <>
        {err && <Alert kind="red" icon="alert">{err}</Alert>}
        <button className="btn btn-primary btn-block" disabled={busy} onClick={accept} style={{ padding: '12px 16px' }} data-testid="admin-join-accept">
          {busy ? <Spinner small /> : <Icon name="check" size={16} color="#fff" />}Accept and open the portal
        </button>
        <div className="hint">The portal asks you to set up an authenticator app next, such as Google Authenticator, Microsoft Authenticator or 1Password.</div>
      </>
    );
  }

  return (
    <div className="auth-wrap">
      <BrandSide />
      <div className="auth-form">
        <div className="auth-card">
          <img src="/logo-brand.svg" alt="TaxStreem" style={{ height: 22, alignSelf: 'flex-start', marginBottom: 12 }} />
          <div>
            <h1 style={{ fontFamily: 'var(--font-brand)', fontSize: 28, fontWeight: 600, letterSpacing: '-.01em', margin: 0 }}>
              {p?.status === 'open' ? 'Join the Counta admin portal' : 'Your invitation'}
            </h1>
            {p?.status === 'open' && (
              <div className="muted" style={{ fontSize: 14, marginTop: 6, lineHeight: 1.5 }}>
                {p.invited_by || 'A TaxStreem admin'} has invited you to be {role} in TaxStreem's admin portal
                {p.role === 'admin' ? ', where TaxStreem runs Counta for every business.' : ', where TaxStreem checks identity documents and accountants’ licences.'}
              </div>
            )}
          </div>
          {body}
        </div>
      </div>
    </div>
  );
}
