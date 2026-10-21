// The page the accountant portal's emails open: /practice/join?t=<token>. Three kinds of invitation share it: joining a
// practice's team, a business owner connecting a business to a practice, and an accountant taking on a business that
// asked for them. Each says what it is before anyone signs in.
import { useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc } from '../lib/supabase';
import { useSession } from '../state/session';
import { Alert, Spinner } from '../components/ui';
import { Icon } from '../components/Icon';
import { BrandSide } from '../pages/auth/Auth';
import { ROLE_WORD, savePractice, servicesText, usePracticesMine } from './api';

type Preview = {
  kind?: 'member' | 'client' | 'accountant'; status: 'open' | 'used' | 'expired' | 'invalid'; practice?: string; practice_verified?: boolean; business?: string | null;
  email?: string; name?: string; role?: 'partner' | 'manager' | 'staff'; services?: string[]; billing?: string; note?: string | null;
  partners?: { name: string; licence: string }[];
};

export default function PracticeJoin() {
  const [params] = useSearchParams();
  const token = (params.get('t') || '').trim().toLowerCase();
  const valid = /^p[mc]_[0-9a-f]{48}$/.test(token);
  const { session, ready, memberships, refreshMemberships, setOrgId, signOut } = useSession();
  const qc = useQueryClient();
  const nav = useNavigate();
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [org, setOrg] = useState('');
  const [practice, setPractice] = useState('');
  const preview = useQuery({ queryKey: ['practice-invite', token], enabled: valid, retry: 1, queryFn: () => rpc<Preview>('practice_invite_preview', { p_token: token }) });
  const p: Preview | undefined = valid ? preview.data : { status: 'invalid' };
  const mine = usePracticesMine(!!session && p?.kind === 'accountant');
  const here = `/practice/join?t=${token}`;
  const myEmail = (session?.user.email || '').toLowerCase();
  const emailOk = p?.kind === 'client' || (!!p?.email && myEmail === p.email.toLowerCase());
  const owned = memberships.filter((m) => m.role === 'owner' && !m.is_sample);
  const practices = (mine.data?.practices || []).filter((x) => x.role !== 'staff');

  async function accept() {
    setBusy(true); setErr(null);
    try {
      const r = await rpc<any>('practice_accept', { p_token: token, p: p?.kind === 'client' ? { org_id: org || owned[0]?.org_id } : p?.kind === 'accountant' ? { practice_id: practice || practices[0]?.id } : {} });
      qc.clear();
      if (r.kind === 'member' || r.kind === 'accountant') { savePractice(r.practice_id); nav(`/practice/${r.practice_id}`, { replace: true }); return; }
      await refreshMemberships().catch(() => []);
      setOrgId(r.org_id);
      nav('/settings#accountant', { replace: true });
    } catch (e) { setErr(cleanError(e)); setBusy(false); }
  }
  async function decline() {
    setBusy(true); setErr(null);
    try { await rpc('practice_decline', { p_token: token }); await preview.refetch(); } catch (e) { setErr(cleanError(e)); }
    setBusy(false);
  }

  const title = !p || p.status !== 'open' ? 'Your invitation'
    : p.kind === 'member' ? `Join ${p.practice}` : p.kind === 'client' ? `Work with ${p.practice}` : `Be ${p.business}'s accountant`;
  let lead = '';
  if (p?.status === 'open') {
    lead = p.kind === 'member' ? `${p.practice} has added you to its accountant portal as ${p.role === 'staff' ? 'a member of staff' : `a ${ROLE_WORD[p.role || 'staff'].toLowerCase()}`}.`
      : p.kind === 'client' ? `${p.practice} would like to keep your books and handle your tax in Counta${p.services?.length ? `: ${servicesText(p.services)}` : ''}. Their accountants get an Accountant's place in the business you choose, and never move money. You can end it at any time.`
      : `${p.business} has invited you to look after its books and tax in Counta's accountant portal${p.services?.length ? `: ${servicesText(p.services)}` : ''}.`;
  }

  let body;
  if (!ready || (valid && preview.isLoading)) body = <div className="row" style={{ justifyContent: 'center', padding: 30 }}><Spinner /></div>;
  else if (preview.isError) body = <Alert kind="red" icon="alert">The invitation could not be checked just now. Refresh the page to try again.</Alert>;
  else if (!p || p.status === 'invalid') body = <Alert kind="amber" icon="alert">This invitation link is not complete, or a newer one has replaced it. Open the latest email, or ask for it to be sent again.</Alert>;
  else if (p.status === 'used') body = <><Alert kind="blue" icon="check">This invitation has already been used, or was declined.</Alert><Link className="btn btn-primary btn-block" to={session ? '/' : '/login'}>{session ? 'Open Counta' : 'Sign in'}</Link></>;
  else if (p.status === 'expired') body = <Alert kind="amber" icon="clock">This invitation has expired. Ask for a new one; it works for fourteen days.</Alert>;
  else if (!session) {
    const q = (path: string) => `${path}?${new URLSearchParams({ ...(p.email && p.kind !== 'client' ? { email: p.email } : {}), next: here }).toString()}`;
    body = (
      <>
        <div className="stack" style={{ gap: 10 }}>
          <Link className="btn btn-primary btn-block" to={q('/signup')} style={{ padding: '12px 16px' }}>Create my account</Link>
          <Link className="btn btn-secondary btn-block" to={q('/login')} style={{ padding: '12px 16px' }}>I already have a Counta account</Link>
        </div>
        {p.kind !== 'client' && <div className="hint">Use {p.email}, the address this invitation went to.</div>}
      </>
    );
  } else if (!emailOk) {
    body = (
      <>
        <Alert kind="amber" icon="alert">You are signed in as {session.user.email}. This invitation is for {p.email}. Sign out, then open the link again and sign in with that address.</Alert>
        <button className="btn btn-secondary btn-block" onClick={async () => { await signOut(); qc.clear(); }}>Sign out</button>
      </>
    );
  } else if (p.kind === 'client' && !owned.length) {
    body = (
      <>
        <Alert kind="amber" icon="building">You do not own a business on Counta yet. Set yours up, then open this link again to connect it.</Alert>
        <Link className="btn btn-primary btn-block" to="/onboarding">Set up my business</Link>
      </>
    );
  } else if (p.kind === 'accountant' && !mine.isLoading && !practices.length) {
    body = (
      <>
        <Alert kind="blue" icon="building">Set up your practice in the accountant portal first. {p.business}'s invitation waits there for you to accept.</Alert>
        <Link className="btn btn-primary btn-block" to="/practice">Set up my practice</Link>
      </>
    );
  } else {
    body = (
      <>
        {p.kind === 'client' && owned.length > 1 && (
          <label className="stack" style={{ gap: 4 }}><span className="mini-label">Which business</span>
            <select className="input" value={org || owned[0].org_id} onChange={(e) => setOrg(e.target.value)}>{owned.map((m) => <option key={m.org_id} value={m.org_id}>{m.name}</option>)}</select></label>
        )}
        {p.kind === 'accountant' && practices.length > 1 && (
          <label className="stack" style={{ gap: 4 }}><span className="mini-label">Into which practice</span>
            <select className="input" value={practice || practices[0].id} onChange={(e) => setPractice(e.target.value)}>{practices.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</select></label>
        )}
        {err && <Alert kind="red" icon="alert">{err}</Alert>}
        <button className="btn btn-primary btn-block" disabled={busy} onClick={accept} style={{ padding: '12px 16px' }} data-testid="accept-invite">
          {busy ? <Spinner small /> : <Icon name="check" size={16} color="#fff" />}
          {p.kind === 'member' ? `Join ${p.practice}` : p.kind === 'client' ? `Connect ${owned.length === 1 ? owned[0].name : 'the business'}` : `Take on ${p.business}`}
        </button>
        {p.kind !== 'member' && <button className="btn btn-ghost btn-block" disabled={busy} onClick={decline}>Decline</button>}
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
            <h1 style={{ fontFamily: 'var(--font-brand)', fontSize: 28, fontWeight: 600, letterSpacing: '-.01em', margin: 0 }}>{title}</h1>
            {lead && <div className="muted" style={{ fontSize: 14, marginTop: 6, lineHeight: 1.5 }}>{lead}</div>}
            {p?.status === 'open' && p.kind === 'client' && (p.partners || []).length > 0 && (
              <div className="faint" style={{ fontSize: 13, marginTop: 8 }}>{(p.partners || []).map((x) => `${x.name}, ${x.licence}`).join(' · ')}</div>
            )}
            {p?.status === 'open' && p.kind === 'client' && p.billing === 'practice' && <div className="faint" style={{ fontSize: 13, marginTop: 4 }}>{p.practice} pays for your Counta plan.</div>}
            {p?.status === 'open' && p.note && <div className="faint" style={{ fontSize: 13, marginTop: 4 }}>“{p.note}”</div>}
          </div>
          {body}
        </div>
      </div>
    </div>
  );
}
