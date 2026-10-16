import { useState, type FormEvent } from 'react';
import { Link, Navigate, useNavigate, useSearchParams } from 'react-router-dom';
import { supabase, cleanError } from '../../lib/supabase';
import { useSession } from '../../state/session';
import { Alert, Field, Spinner } from '../../components/ui';
import { Icon } from '../../components/Icon';

function BrandSide() {
  return (
    <div className="auth-side">
      <img src="/logo-brand.svg" alt="TaxStreem" style={{ height: 26, filter: 'brightness(0) invert(1)', alignSelf: 'flex-start' }} />
      <div style={{ maxWidth: 460 }}>
        <div style={{ fontSize: 12, fontWeight: 600, letterSpacing: '.12em', textTransform: 'uppercase', opacity: 0.7 }}>Counta · Inventory</div>
        <div style={{ fontFamily: 'var(--font-brand)', fontSize: 40, fontWeight: 600, lineHeight: 1.12, letterSpacing: '-.02em', marginTop: 14 }}>
          Stock that keeps its own books.
        </div>
        <div style={{ fontSize: 16, lineHeight: 1.55, opacity: 0.85, marginTop: 16 }}>
          Photograph a vendor invoice, count a shelf on your phone, approve a reorder. Every movement posts to your ledger with the receipt attached.
        </div>
        <div style={{ display: 'grid', gap: 12, marginTop: 28 }}>
          {[
            ['camera', 'Typed and handwritten invoices read line by line'],
            ['shield', 'Staff see what their role allows, nothing more'],
            ['wifiOff', 'Phone capture keeps working when data drops'],
          ].map(([ic, t]) => (
            <div key={t} className="row" style={{ gap: 12, fontSize: 14 }}>
              <span style={{ width: 32, height: 32, borderRadius: 10, background: 'rgba(255,255,255,.12)', display: 'grid', placeItems: 'center' }}><Icon name={ic} size={16} color="#fff" /></span>
              {t}
            </div>
          ))}
        </div>
      </div>
      <div style={{ fontSize: 12, opacity: 0.6 }}>TaxStreem Technologies Limited · Lagos</div>
    </div>
  );
}

export function AuthPage({ mode }: { mode: 'login' | 'signup' | 'reset' }) {
  const { session, ready, refreshMemberships } = useSession();
  const [params] = useSearchParams();
  const nav = useNavigate();
  const [name, setName] = useState('');
  const [email, setEmail] = useState(params.get('email') || '');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [sent, setSent] = useState<string | null>(null);
  const next = params.get('next') || '/';

  if (ready && session && mode !== 'reset') return <Navigate to={next} replace />;

  async function submit(e: FormEvent) {
    e.preventDefault(); setErr(null);
    if (!/^\S+@\S+\.\S+$/.test(email.trim())) { setErr('Enter a valid email address.'); return; }
    if (mode !== 'reset' && password.length < 8) { setErr('Use at least 8 characters for the password.'); return; }
    if (mode === 'signup' && !name.trim()) { setErr('Enter your name.'); return; }
    setBusy(true);
    try {
      if (mode === 'login') {
        const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
        if (error) throw error;
        await refreshMemberships().catch(() => []);
        nav(next, { replace: true });
      } else if (mode === 'signup') {
        const { data, error } = await supabase.auth.signUp({
          email: email.trim(), password,
          options: { data: { full_name: name.trim() }, emailRedirectTo: window.location.origin + '/onboarding' },
        });
        if (error) throw error;
        if (data.session) nav('/onboarding', { replace: true });
        else setSent('We sent a confirmation link to ' + email.trim() + '. Open it on this device to finish setting up.');
      } else {
        const { error } = await supabase.auth.resetPasswordForEmail(email.trim(), { redirectTo: window.location.origin + '/update-password' });
        if (error) throw error;
        setSent('If an account exists for ' + email.trim() + ', a reset link is on its way.');
      }
    } catch (e: any) {
      const m = cleanError(e);
      setErr(/Invalid login/i.test(m) ? 'That email and password do not match.' : /Email not confirmed/i.test(m) ? 'Confirm your email first. Check your inbox for the link.' : m);
    } finally { setBusy(false); }
  }

  const title = mode === 'login' ? 'Sign in to Counta' : mode === 'signup' ? 'Create your Counta account' : 'Reset your password';
  return (
    <div className="auth-wrap">
      <BrandSide />
      <div className="auth-form">
        <form className="auth-card" onSubmit={submit} noValidate>
          <img src="/logo-brand.svg" alt="TaxStreem" style={{ height: 22, alignSelf: 'flex-start', marginBottom: 12 }} />
          <div>
            <h1 style={{ fontFamily: 'var(--font-brand)', fontSize: 28, fontWeight: 600, letterSpacing: '-.01em', margin: 0 }}>{title}</h1>
            <div className="muted" style={{ fontSize: 14, marginTop: 6, lineHeight: 1.5 }}>
              {mode === 'login' ? 'Owners and staff use the same sign-in. Your role decides what you see.'
                : mode === 'signup' ? 'Start with your own business or explore a sample shop first.'
                : 'We will email you a link to choose a new password.'}
            </div>
          </div>
          {sent ? (
            <Alert kind="green" icon="mail">{sent}</Alert>
          ) : (
            <>
              {mode === 'signup' && (
                <Field label="Your name" req><input className="input" value={name} onChange={(e) => setName(e.target.value)} autoComplete="name" placeholder="e.g. Kelechi Ibe" /></Field>
              )}
              <Field label="Email" req><input className="input" type="email" value={email} onChange={(e) => setEmail(e.target.value)} autoComplete="email" placeholder="you@business.com" /></Field>
              {mode !== 'reset' && (
                <Field label="Password" req hint={mode === 'signup' ? 'At least 8 characters.' : undefined}>
                  <input className="input" type="password" value={password} onChange={(e) => setPassword(e.target.value)} autoComplete={mode === 'login' ? 'current-password' : 'new-password'} />
                </Field>
              )}
              {err && <Alert kind="red" icon="alert">{err}</Alert>}
              <button className="btn btn-primary btn-block" disabled={busy} style={{ padding: '12px 16px', boxShadow: 'var(--shadow-cta)' }}>
                {busy && <Spinner small />}{mode === 'login' ? 'Sign in' : mode === 'signup' ? 'Create account' : 'Send reset link'}
              </button>
            </>
          )}
          <div style={{ fontSize: 14, color: '#4B5563', display: 'flex', justifyContent: 'space-between', flexWrap: 'wrap', gap: 8 }}>
            {mode === 'login' ? (
              <><span>New to Counta? <Link to={'/signup' + (email ? '?email=' + encodeURIComponent(email) : '')}>Create an account</Link></span><Link to="/reset">Forgot password?</Link></>
            ) : (
              <span>Already have an account? <Link to="/login">Sign in</Link></span>
            )}
          </div>
          {mode === 'signup' && (
            <div className="hint">Joining a team? Sign up with the email your manager added, and you will land straight in their business.</div>
          )}
        </form>
      </div>
    </div>
  );
}

export function UpdatePasswordPage() {
  const nav = useNavigate();
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function submit(e: FormEvent) {
    e.preventDefault();
    if (password.length < 8) { setErr('Use at least 8 characters.'); return; }
    setBusy(true); setErr(null);
    const { error } = await supabase.auth.updateUser({ password });
    setBusy(false);
    if (error) setErr(cleanError(error)); else nav('/', { replace: true });
  }
  return (
    <div className="auth-wrap">
      <BrandSide />
      <div className="auth-form">
        <form className="auth-card" onSubmit={submit}>
          <h1 style={{ fontFamily: 'var(--font-brand)', fontSize: 28, fontWeight: 600, margin: 0 }}>Choose a new password</h1>
          <Field label="New password" req><input className="input" type="password" value={password} onChange={(e) => setPassword(e.target.value)} autoComplete="new-password" /></Field>
          {err && <Alert kind="red" icon="alert">{err}</Alert>}
          <button className="btn btn-primary btn-block" disabled={busy}>{busy && <Spinner small />}Save password</button>
        </form>
      </div>
    </div>
  );
}
