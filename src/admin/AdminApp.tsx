// TaxStreem's admin portal: /admin. Only TaxStreem's admins (and identity reviewers, who see the reviews only) get past the
// first screen, and only after a code from their authenticator app. Customers who find the address see a plain refusal.
import { useEffect, useRef, useState, type ReactNode } from 'react';
import { Link, Navigate, NavLink, Route, Routes } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { cleanError, supabase } from '../lib/supabase';
import { useSession } from '../state/session';
import { Icon } from '../components/Icon';
import { Alert, Spinner } from '../components/ui';
import { useAdminMe } from './api';
import Overview from './pages/Overview';
import Businesses, { Business } from './pages/Businesses';
import People from './pages/People';
import Activity from './pages/Activity';
import Reviews from './pages/Reviews';
import Keys from './pages/Keys';
import Martina from './pages/Martina';
import Currency from './pages/Currency';
import Limits from './pages/Limits';
import Tax from './pages/Tax';
import Team from './pages/Team';

const NAV: [string, string, string][] = [
  ['', 'Overview', 'house'], ['businesses', 'Businesses', 'building'], ['people', 'People', 'users'], ['activity', 'Activity', 'radar'],
  ['reviews', 'Identity reviews', 'shield'], ['keys', 'Keys and services', 'lock'], ['martina', 'Martina and voices', 'volume'],
  ['currency', 'Currency', 'dollar'], ['limits', 'Limits and switches', 'zap'], ['tax', 'Tax rules', 'landmark'], ['team', 'Admin team', 'history'],
];

function Centre({ children }: { children: ReactNode }) {
  return <div style={{ minHeight: '100vh', display: 'grid', placeItems: 'center', padding: 16, background: 'var(--canvas)' }}>{children}</div>;
}

// Asks for the code from the authenticator app; the first time, sets the app up with a QR code.
function CodeGate({ onDone }: { onDone: () => void }) {
  const { session, signOut } = useSession();
  const started = useRef(false);
  const [mode, setMode] = useState<'loading' | 'enrol' | 'challenge'>('loading');
  const [factorId, setFactorId] = useState('');
  const [qr, setQr] = useState('');
  const [secret, setSecret] = useState('');
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => {
    if (started.current) return;
    started.current = true;
    (async () => {
      const { data, error } = await supabase.auth.mfa.listFactors();
      if (error) { setErr(cleanError(error)); return; }
      const ready = data.totp?.[0];
      if (ready) { setFactorId(ready.id); setMode('challenge'); return; }
      // A setup left half-way is cleared so it can start again.
      for (const f of data.all.filter((x) => x.status !== 'verified')) await supabase.auth.mfa.unenroll({ factorId: f.id });
      const r = await supabase.auth.mfa.enroll({ factorType: 'totp', friendlyName: 'Counta admin', issuer: 'Counta' });
      if (r.error || !r.data) { setErr(cleanError(r.error) || 'The authenticator could not be set up just now.'); return; }
      setFactorId(r.data.id); setQr(r.data.totp.qr_code); setSecret(r.data.totp.secret); setMode('enrol');
    })();
  }, []);
  async function verify() {
    const c = code.replace(/\D/g, '');
    if (c.length !== 6) { setErr('Enter the six digits the app shows.'); return; }
    setBusy(true); setErr(null);
    const { error } = await supabase.auth.mfa.challengeAndVerify({ factorId, code: c });
    setBusy(false);
    if (error) {
      setErr(/invalid|incorrect|verif/i.test(error.message) ? 'That code did not work. The code changes every 30 seconds: enter the one showing now.' : cleanError(error));
      setCode('');
      return;
    }
    onDone();
  }
  return (
    <Centre>
      <div className="card card-pad stack" style={{ gap: 14, width: 'min(440px, 100%)' }}>
        <img src="/logo-brand.svg" alt="TaxStreem" style={{ height: 22, alignSelf: 'flex-start' }} />
        <div>
          <h1 style={{ fontFamily: 'var(--font-brand)', fontSize: 24, fontWeight: 600, margin: 0 }}>{mode === 'enrol' ? 'Set up your authenticator' : 'Admin portal'}</h1>
          <div className="muted" style={{ fontSize: 14, marginTop: 6, lineHeight: 1.5 }}>
            {mode === 'enrol'
              ? 'The admin portal changes keys and settings for every business, so it asks for a code from an authenticator app each time you open it. Scan this with Google Authenticator, Microsoft Authenticator or 1Password, then enter the code it shows.'
              : `Enter the six-digit code from your authenticator app for ${session?.user.email || 'your account'}.`}
          </div>
        </div>
        {mode === 'loading' && !err && <div className="row" style={{ justifyContent: 'center', padding: 20 }}><Spinner /></div>}
        {mode === 'enrol' && (
          <div className="stack" style={{ gap: 10, alignItems: 'center' }}>
            {qr && <img src={qr} alt="QR code for your authenticator app" style={{ width: 190, height: 190, background: '#fff', border: '1px solid var(--line)', borderRadius: 12, padding: 8 }} />}
            <div className="faint" style={{ fontSize: 12, textAlign: 'center' }}>Cannot scan it? Type this key into the app instead:</div>
            <code className="mono" data-testid="totp-secret" style={{ fontSize: 13, wordBreak: 'break-all', textAlign: 'center', background: 'var(--row)', padding: '6px 10px', borderRadius: 8 }}>{secret}</code>
          </div>
        )}
        {mode !== 'loading' && (
          <form className="stack" style={{ gap: 10 }} onSubmit={(e) => { e.preventDefault(); void verify(); }}>
            <input className="input num" autoFocus inputMode="numeric" autoComplete="one-time-code" maxLength={7} placeholder="123456" aria-label="Code from your authenticator app"
              value={code} onChange={(e) => setCode(e.target.value.replace(/[^\d ]/g, ''))} style={{ fontSize: 22, letterSpacing: '.3em', textAlign: 'center' }} />
            <button className="btn btn-primary btn-block" disabled={busy} type="submit" style={{ padding: '12px 16px' }}>{busy ? <Spinner small /> : <Icon name="lock" size={16} color="#fff" />}{mode === 'enrol' ? 'Confirm and open the portal' : 'Open the admin portal'}</button>
          </form>
        )}
        {err && <Alert kind="red" icon="alert">{err}</Alert>}
        {mode === 'challenge' && <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }}>Lost the phone with your authenticator? Another admin can't see your code. Remove the factor for your account in Supabase, under Authentication and Users, then set it up again here.</div>}
        <div className="row wrap" style={{ gap: 8 }}>
          <Link to="/" className="btn btn-ghost btn-sm"><Icon name="house" size={14} />Back to Counta</Link>
          <button className="btn btn-ghost btn-sm" onClick={signOut}><Icon name="logout" size={14} />Sign out</button>
        </div>
      </div>
    </Centre>
  );
}

function Layout({ admin, children }: { admin: boolean; children: ReactNode }) {
  const { session, signOut } = useSession();
  const items = admin ? NAV : NAV.filter(([p]) => p === 'reviews');
  return (
    <div className="adm">
      <header className="adm-top">
        <img src="/logo-brand.svg" alt="TaxStreem" style={{ height: 20 }} />
        <span className="chip t-purple">Admin</span>
        <span className="grow" />
        <span className="faint hide-xs ellipsis" style={{ fontSize: 13, maxWidth: 240 }}>{session?.user.email}</span>
        <Link to="/" className="btn btn-secondary btn-sm"><Icon name="house" size={14} /><span className="hide-xs">Counta</span></Link>
        <button className="btn btn-ghost btn-sm" onClick={signOut} aria-label="Sign out"><Icon name="logout" size={14} /></button>
      </header>
      <div className="adm-body">
        <nav className="adm-nav" aria-label="Admin portal">
          {items.map(([p, label, icon]) => (
            <NavLink key={p} to={p ? `/admin/${p}` : '/admin'} end={!p} className={({ isActive }) => 'nav-item' + (isActive ? ' active' : '')}>
              <Icon name={icon} size={18} color="#6B7280" /><span>{label}</span>
            </NavLink>
          ))}
        </nav>
        <main className="adm-main stack" style={{ gap: 20, minWidth: 0 }}>{children}</main>
      </div>
    </div>
  );
}

export default function AdminApp() {
  const qc = useQueryClient();
  const me = useAdminMe();
  if (me.isLoading) return <Centre><Spinner /></Centre>;
  if (!me.data?.staff) {
    return (
      <Centre>
        <div className="card card-pad stack" style={{ gap: 10, width: 'min(440px, 100%)', textAlign: 'center' }}>
          <b style={{ fontSize: 18 }}>This page is not available</b>
          <div className="muted" style={{ fontSize: 14 }}>There is nothing here for your account.</div>
          <div><Link className="btn btn-secondary btn-sm" to="/">Go to Counta</Link></div>
        </div>
      </Centre>
    );
  }
  if (!me.data.aal2) return <CodeGate onDone={() => { void qc.invalidateQueries(); }} />;
  const admin = me.data.admin;
  return (
    <Layout admin={admin}>
      <Routes>
        {admin ? (
          <>
            <Route index element={<Overview />} />
            <Route path="businesses" element={<Businesses />} />
            <Route path="businesses/:id" element={<Business />} />
            <Route path="people" element={<People />} />
            <Route path="activity" element={<Activity />} />
            <Route path="reviews" element={<Reviews />} />
            <Route path="keys" element={<Keys />} />
            <Route path="martina" element={<Martina />} />
            <Route path="currency" element={<Currency />} />
            <Route path="limits" element={<Limits />} />
            <Route path="tax" element={<Tax />} />
            <Route path="team" element={<Team />} />
            <Route path="*" element={<Navigate to="/admin" replace />} />
          </>
        ) : (
          <>
            <Route path="reviews" element={<Reviews />} />
            <Route path="*" element={<Navigate to="/admin/reviews" replace />} />
          </>
        )}
      </Routes>
    </Layout>
  );
}
