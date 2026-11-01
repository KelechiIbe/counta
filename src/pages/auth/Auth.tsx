import { useEffect, useRef, useState, type FormEvent } from 'react';
import { Link, Navigate, useNavigate, useSearchParams } from 'react-router-dom';
import { supabase, cleanError } from '../../lib/supabase';
import { localPhone } from '../../lib/format';
import { refCode, REF_RE } from '../../lib/partners';
import { useSession } from '../../state/session';
import { Alert, Field, Spinner } from '../../components/ui';
import { Icon } from '../../components/Icon';

export function BrandSide() {
  return (
    <div className="auth-side">
      <img src="/logo-brand.svg" alt="TaxStreem" style={{ height: 26, filter: 'brightness(0) invert(1)', alignSelf: 'flex-start' }} />
      <div style={{ maxWidth: 460 }}>
        <div style={{ fontSize: 12, fontWeight: 600, letterSpacing: '.12em', textTransform: 'uppercase', opacity: 0.7 }}>Counta · Books, sales and stock</div>
        <div style={{ fontFamily: 'var(--font-brand)', fontSize: 40, fontWeight: 600, lineHeight: 1.12, letterSpacing: '-.02em', marginTop: 14 }}>
          Books that keep themselves.
        </div>
        <div style={{ fontSize: 16, lineHeight: 1.55, opacity: 0.85, marginTop: 16 }}>
          Sell at the till or by invoice, get paid by transfer, link or QR, and keep stock in step. Atlas posts every sale, bill and bank line to your ledger and asks you only when it is unsure.
        </div>
        <div style={{ display: 'grid', gap: 12, marginTop: 28 }}>
          {[
            ['receipt', 'Till, invoices and an online shop that follow live stock'],
            ['card', 'Payments by transfer, link and QR, confirmed for you'],
            ['sparkles', 'IFRS statements and CFO reports, ready to export'],
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
  // Signing in or confirming the code makes a session, and this page then moves on by itself (the Navigate below). The
  // navigation after the businesses load is only for when it has not, so a late one cannot pull the person back from the
  // page they went on to (an invitation they have already accepted, say).
  const alive = useRef(true);
  useEffect(() => { alive.current = true; return () => { alive.current = false; }; }, []);
  const [name, setName] = useState('');
  const [email, setEmail] = useState(params.get('email') || '');
  const [phone, setPhone] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [sent, setSent] = useState<string | null>(null);
  // After sign-up: the code from the confirmation email (the link in it works too). Supabase sends 6 to 10 digits, as the
  // project is set (8 on Counta's project), so the field takes any of those lengths.
  const [codeFor, setCodeFor] = useState<string | null>(null);
  // Where to go afterwards: a path inside Counta only (an invitation link brings people back to /join, or to /admin/join for
  // the admin portal's team, rather than on to setting up a business).
  const asked = params.get('next') || '';
  const next = asked.startsWith('/') && !asked.startsWith('//') ? asked : '/';
  const joining = next.startsWith('/join') || next.startsWith('/admin/join');
  const after = mode === 'signup' && !joining ? '/onboarding' : next;
  // An accountant's link (/r/CODE) sends people here with its code, kept for Home to offer connecting the accountant.
  const ref = params.get('ref') || '';
  useEffect(() => { if (REF_RE.test(ref)) refCode.set(ref); }, [ref]);

  if (ready && session && mode !== 'reset') return <Navigate to={after} replace />;
  if (codeFor) return <CodeStep email={codeFor} redirect={after} onBack={() => setCodeFor(null)} onDone={async () => { await refreshMemberships().catch(() => []); if (alive.current) nav(after, { replace: true }); }} />;

  async function submit(e: FormEvent) {
    e.preventDefault(); setErr(null);
    if (!/^\S+@\S+\.\S+$/.test(email.trim())) { setErr('Enter a valid email address.'); return; }
    if (mode !== 'reset' && password.length < 8) { setErr('Use at least 8 characters for the password.'); return; }
    if (mode === 'signup' && !name.trim()) { setErr('Enter your name.'); return; }
    const tel = phone.replace(/[\s()-]/g, '');
    if (mode === 'signup' && tel && !/^(\+?234|0)[789][01]\d{8}$/.test(tel)) { setErr('Enter a Nigerian mobile number, for example 0803 123 4567, or leave it blank.'); return; }
    setBusy(true);
    try {
      if (mode === 'login') {
        const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
        if (error) throw error;
        await refreshMemberships().catch(() => []);
        if (alive.current) nav(next, { replace: true });
      } else if (mode === 'signup') {
        const { data, error } = await supabase.auth.signUp({
          email: email.trim(), password,
          options: { data: { full_name: name.trim(), ...(tel ? { phone: localPhone(tel) } : {}), ...(refCode.get() ? { ref: refCode.get() } : {}) }, emailRedirectTo: window.location.origin + after },
        });
        if (error) throw error;
        if (data.session) nav(after, { replace: true });
        else setCodeFor(email.trim());
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
              {joining && mode !== 'reset' ? (mode === 'login' ? 'Sign in with the email your invitation went to, then join the team.' : 'Create your account with the email your invitation went to, then join the team.')
                : mode === 'login' ? 'Owners and staff use the same sign-in. Your role decides what you see.'
                : mode === 'signup' ? 'One minute here, then Martina, your guide, sets up your business with you. By voice if you like.'
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
              {mode === 'signup' && (
                <Field label="Mobile number" hint="Optional. Only used if you ask Martina, your guide, to call you.">
                  <input className="input" type="tel" value={phone} onChange={(e) => setPhone(e.target.value)} autoComplete="tel" placeholder="0803 123 4567" inputMode="tel" />
                </Field>
              )}
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
              <><span>New to Counta? <Link to={'/signup?' + carry(email, joining ? next : '')}>Create an account</Link></span><Link to="/reset">Forgot password?</Link></>
            ) : (
              <span>Already have an account? <Link to={'/login?' + carry(email, joining ? next : '')}>Sign in</Link></span>
            )}
          </div>
          {mode === 'signup' && !joining && (
            <div className="hint">Joining a team? Open the link in your invitation email. It brings you back here and then into the business.</div>
          )}
          <div className="hint" data-testid="auth-legal" style={{ display: 'flex', gap: 14, flexWrap: 'wrap' }}>
            <Link to="/privacy">Privacy notice</Link><Link to="/sla">Service levels</Link><Link to="/developers">E-invoicing API</Link>
          </div>
        </form>
      </div>
    </div>
  );
}

// The code from the confirmation email. Supabase's "Confirm signup" email carries both the code ({{ .Token }}) and the link.
const carry = (email: string, next: string) => new URLSearchParams({ ...(email ? { email } : {}), ...(next ? { next } : {}) }).toString();

function CodeStep({ email, redirect, onBack, onDone }: { email: string; redirect: string; onBack: () => void; onDone: () => Promise<void> }) {
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [wait, setWait] = useState(45);
  const [note, setNote] = useState<string | null>(null);
  useEffect(() => { const t = window.setInterval(() => setWait((w) => (w > 0 ? w - 1 : 0)), 1000); return () => window.clearInterval(t); }, []);
  async function verify(v = code) {
    const token = v.replace(/\D/g, '');
    if (token.length < 6 || token.length > 10) { setErr('Enter the code from the email: all of its digits.'); return; }
    setBusy(true); setErr(null);
    const { error } = await supabase.auth.verifyOtp({ email, token, type: 'signup' });
    if (error) { setBusy(false); setErr(/expired|invalid/i.test(error.message) ? 'That code has expired or is not right. Check the latest email, or send a new code.' : cleanError(error)); return; }
    await onDone();
  }
  async function resend() {
    setErr(null); setNote(null);
    const { error } = await supabase.auth.resend({ type: 'signup', email, options: { emailRedirectTo: window.location.origin + redirect } });
    if (error) setErr(cleanError(error)); else { setNote('A new code is on its way.'); setWait(45); }
  }
  return (
    <div className="auth-wrap">
      <BrandSide />
      <div className="auth-form">
        <form className="auth-card" onSubmit={(e) => { e.preventDefault(); void verify(); }} noValidate>
          <img src="/logo-brand.svg" alt="TaxStreem" style={{ height: 22, alignSelf: 'flex-start', marginBottom: 12 }} />
          <div>
            <h1 style={{ fontFamily: 'var(--font-brand)', fontSize: 28, fontWeight: 600, letterSpacing: '-.01em', margin: 0 }}>Check your email</h1>
            <div className="muted" style={{ fontSize: 14, marginTop: 6, lineHeight: 1.5 }}>We sent a code to <b>{email}</b>. Type it here, or tap the link in the email.</div>
          </div>
          <Field label="Code" req>
            <input className="input" value={code} autoFocus inputMode="numeric" autoComplete="one-time-code" maxLength={14} placeholder="12345678" aria-label="Code from the email"
              style={{ fontSize: 26, letterSpacing: '.3em', textAlign: 'center', fontVariantNumeric: 'tabular-nums' }}
              onChange={(e) => {
                const v = e.target.value.replace(/\D/g, '').slice(0, 10);
                const filled = v.length - code.length > 1;
                setCode(v);
                // Typed: checks itself at 8 digits, the length Counta's project sends. Filled in by the phone: at once.
                if (!busy && (v.length === 8 || (filled && v.length >= 6))) void verify(v);
              }}
              onPaste={(e) => {
                // A pasted code replaces whatever was typed and is checked at once, whatever its length.
                const v = e.clipboardData.getData('text').replace(/\D/g, '').slice(0, 10);
                if (v.length < 6) return;
                e.preventDefault(); setCode(v);
                if (!busy) void verify(v);
              }} />
          </Field>
          {err && <Alert kind="red" icon="alert">{err}</Alert>}
          {note && <Alert kind="green" icon="mail">{note}</Alert>}
          <button className="btn btn-primary btn-block" disabled={busy || code.length < 6} style={{ padding: '12px 16px', boxShadow: 'var(--shadow-cta)' }}>{busy && <Spinner small />}Confirm and continue</button>
          <div style={{ fontSize: 14, color: '#4B5563', display: 'flex', justifyContent: 'space-between', flexWrap: 'wrap', gap: 8 }}>
            <button type="button" className="link" onClick={onBack} style={{ border: 0, background: 'none', padding: 0, cursor: 'pointer', color: 'var(--primary)' }}>Wrong email?</button>
            {wait > 0 ? <span className="faint">New code in {wait}s</span>
              : <button type="button" className="link" onClick={resend} style={{ border: 0, background: 'none', padding: 0, cursor: 'pointer', color: 'var(--primary)' }}>Send a new code</button>}
          </div>
          <div className="hint">Not in your inbox? Check Spam or Promotions. The code works for an hour.</div>
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
