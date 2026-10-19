// The page an invitation email opens: /join?t=<token>. It says who invited whom to which business, then the person signs
// in (or creates an account) with the invited email address and joins. The token works once, for seven days.
import { useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc } from '../../lib/supabase';
import { useSession } from '../../state/session';
import { Alert, Spinner } from '../../components/ui';
import { Icon } from '../../components/Icon';
import { BrandSide } from './Auth';

type Preview = { status: 'open' | 'used' | 'expired' | 'invalid'; business?: string; name?: string; email?: string; role_label?: string; invited_by?: string | null };

const roleWord = (r?: string) => {
  const w = String(r || '').toLowerCase();
  return w === 'admin' ? 'an admin' : w === 'accountant' ? 'the accountant' : w === 'staff' ? 'a member of staff' : w ? `a ${w}` : 'part of the team';
};

export default function JoinPage() {
  const [params] = useSearchParams();
  const token = (params.get('t') || '').trim().toLowerCase();
  const { session, ready, refreshMemberships, setOrgId, signOut } = useSession();
  const qc = useQueryClient();
  const nav = useNavigate();
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const preview = useQuery({ queryKey: ['invite', token], enabled: /^[0-9a-f]{48}$/.test(token), retry: 1,
    queryFn: () => rpc<Preview>('invite_preview', { p_token: token }) });
  const p: Preview | undefined = /^[0-9a-f]{48}$/.test(token) ? preview.data : { status: 'invalid' };
  const here = `/join?t=${token}`;
  const mine = (session?.user.email || '').toLowerCase();
  const matches = !!p?.email && mine === p.email.toLowerCase();

  async function join() {
    setBusy(true); setErr(null);
    try {
      const r = await rpc<{ org_id: string; business: string; role_label: string }>('accept_invite', { p_token: token });
      await refreshMemberships().catch(() => []);
      setOrgId(r.org_id);
      qc.clear();
      nav('/', { replace: true });
    } catch (e) { setErr(cleanError(e)); setBusy(false); }
  }

  let body;
  if (!ready || (preview.isLoading && p === undefined)) {
    body = <div className="row" style={{ justifyContent: 'center', padding: 30 }}><Spinner /></div>;
  } else if (preview.isError) {
    body = <Alert kind="red" icon="alert">The invitation could not be checked just now. Refresh the page to try again.</Alert>;
  } else if (!p || p.status === 'invalid') {
    body = <Alert kind="amber" icon="alert">This invitation link is not complete, or a newer invitation has replaced it. Open the latest email from Counta, or ask the person who invited you to send it again.</Alert>;
  } else if (p.status === 'used') {
    body = (
      <>
        <Alert kind="blue" icon="check">This invitation to {p.business} has already been used.</Alert>
        <Link className="btn btn-primary btn-block" to={session ? '/' : '/login'} style={{ padding: '12px 16px' }}>{session ? 'Open Counta' : 'Sign in'}</Link>
      </>
    );
  } else if (p.status === 'expired') {
    body = <Alert kind="amber" icon="clock">This invitation to {p.business} has expired. Ask {p.invited_by || 'the person who invited you'} to send a new one; it will work for seven days.</Alert>;
  } else if (!session) {
    const q = (path: string) => `${path}?${new URLSearchParams({ email: p.email || '', next: here }).toString()}`;
    body = (
      <>
        <div className="stack" style={{ gap: 10 }}>
          <Link className="btn btn-primary btn-block" to={q('/signup')} style={{ padding: '12px 16px', boxShadow: 'var(--shadow-cta)' }}>Create my account</Link>
          <Link className="btn btn-secondary btn-block" to={q('/login')} style={{ padding: '12px 16px' }}>I already have a Counta account</Link>
        </div>
        <div className="hint">Use {p.email}, the address this invitation went to.</div>
      </>
    );
  } else if (!matches) {
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
        <button className="btn btn-primary btn-block" disabled={busy} onClick={join} style={{ padding: '12px 16px', boxShadow: 'var(--shadow-cta)' }}>
          {busy ? <Spinner small /> : <Icon name="check" size={16} color="#fff" />}Join {p.business}
        </button>
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
              {p?.status === 'open' && p.business ? `Join ${p.business}` : 'Your invitation'}
            </h1>
            {p?.status === 'open' && (
              <div className="muted" style={{ fontSize: 14, marginTop: 6, lineHeight: 1.5 }}>
                {p.invited_by ? `${p.invited_by} invited you` : 'You have been invited'}{p.name ? `, ${p.name.split(' ')[0]},` : ''} to work in {p.business} on Counta as {roleWord(p.role_label)}.
              </div>
            )}
          </div>
          {body}
        </div>
      </div>
    </div>
  );
}
