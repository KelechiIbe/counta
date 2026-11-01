// Two-step sign-in with an authenticator app (TOTP, Supabase Auth). Owners, and anyone who can change a business's settings,
// must use it: TwoStepGate asks them to set one up before Counta opens, and asks everyone who has one for the code once a
// session. The database refuses changes to e-invoicing from a session without the code (mfa_status, require_mfa). Anyone
// else may turn it on under Settings, Your account (TwoStepSettings).
import { useEffect, useRef, useState, type ReactNode } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc, supabase } from '../lib/supabase';
import { useSession } from '../state/session';
import { Icon } from './Icon';
import { Alert, Spinner } from './ui';

export type TwoStep = { required: boolean; aal: 'aal1' | 'aal2'; hasFactor: boolean };

export function useTwoStep(enabled = true) {
  const { session } = useSession();
  return useQuery({
    queryKey: ['two-step', session?.user.id, session?.access_token?.slice(-16)],
    enabled: enabled && !!session,
    staleTime: 60_000,
    queryFn: async (): Promise<TwoStep> => {
      const lvl = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
      // Whether an authenticator is set up comes from the factors themselves: a session can stay at aal2 for a while after
      // its authenticator is removed, so the session's level alone would still say one is set up.
      const factors = await supabase.auth.mfa.listFactors();
      // Until the database knows about two-step sign-in, nobody is held at the door; the database still guards e-invoicing.
      const st = await rpc<{ required: boolean; aal: string }>('mfa_status').catch(() => ({ required: false, aal: 'aal1' }));
      return { required: Boolean(st.required), aal: lvl.data?.currentLevel === 'aal2' ? 'aal2' : 'aal1', hasFactor: (factors.data?.totp?.length ?? 0) > 0 };
    },
  });
}

// Holds the business app until the person has entered a code, when they have an authenticator or must set one up.
export function TwoStepGate({ children }: { children: ReactNode }) {
  const st = useTwoStep();
  const qc = useQueryClient();
  if (st.isLoading) return <div style={{ minHeight: '100vh', display: 'grid', placeItems: 'center' }}><Spinner /></div>;
  const s = st.data;
  if (!s || s.aal === 'aal2' || (!s.hasFactor && !s.required)) return <>{children}</>;
  return (
    <div style={{ minHeight: '100vh', display: 'grid', placeItems: 'center', padding: 20, background: 'var(--canvas)' }}>
      <CodeCard mode={s.hasFactor ? 'challenge' : 'enrol'} required={s.required} onDone={() => qc.invalidateQueries({ queryKey: ['two-step'] })} />
    </div>
  );
}

// Sets up an authenticator (QR code and key, then a code) or asks for the code from the one set up.
export function CodeCard({ mode: start, required, onDone, onCancel }: { mode: 'enrol' | 'challenge'; required: boolean; onDone: () => void; onCancel?: () => void }) {
  const { session, signOut } = useSession();
  const began = useRef(false);
  const [mode, setMode] = useState<'loading' | 'enrol' | 'challenge'>('loading');
  const [factorId, setFactorId] = useState('');
  const [qr, setQr] = useState('');
  const [secret, setSecret] = useState('');
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => {
    if (began.current) return;
    began.current = true;
    (async () => {
      const { data, error } = await supabase.auth.mfa.listFactors();
      if (error) { setErr(cleanError(error)); return; }
      const ready = data.totp?.[0];
      if (start === 'challenge' && ready) { setFactorId(ready.id); setMode('challenge'); return; }
      // A set-up left half-way is cleared so it can start again.
      for (const f of data.all.filter((x) => x.status !== 'verified')) await supabase.auth.mfa.unenroll({ factorId: f.id });
      const r = await supabase.auth.mfa.enroll({ factorType: 'totp', friendlyName: `Counta ${new Date().toISOString().slice(0, 16)}`, issuer: 'Counta' });
      if (r.error || !r.data) { setErr(cleanError(r.error) || 'The authenticator could not be set up just now.'); return; }
      setFactorId(r.data.id); setQr(r.data.totp.qr_code); setSecret(r.data.totp.secret); setMode('enrol');
    })();
  }, []); // eslint-disable-line react-hooks/exhaustive-deps
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
    <div className="card card-pad stack" style={{ gap: 14, width: 'min(440px, 100%)' }} data-testid="two-step" data-mode={mode}>
      <img src="/logo-brand.svg" alt="TaxStreem" style={{ height: 22, alignSelf: 'flex-start' }} />
      <div>
        <h1 style={{ fontFamily: 'var(--font-brand)', fontSize: 24, fontWeight: 600, margin: 0 }}>{mode === 'challenge' ? 'Enter your code' : 'Set up two-step sign-in'}</h1>
        <div className="muted" style={{ fontSize: 14, marginTop: 6, lineHeight: 1.5 }}>
          {mode === 'challenge'
            ? `Enter the six-digit code from your authenticator app for ${session?.user.email || 'your account'}.`
            : required
              ? 'You can change your business\'s settings and its NRS e-invoicing keys, so Counta asks for a code from an authenticator app each time you sign in. Scan this with Google Authenticator, Microsoft Authenticator or 1Password, then enter the code it shows.'
              : 'Counta will ask for a code from an authenticator app each time you sign in. Scan this with Google Authenticator, Microsoft Authenticator or 1Password, then enter the code it shows.'}
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
          <button className="btn btn-primary btn-block" disabled={busy} type="submit" style={{ padding: '12px 16px' }}>
            {busy ? <Spinner small /> : <Icon name="lock" size={16} color="#fff" />}{mode === 'enrol' ? 'Confirm and continue' : 'Continue'}
          </button>
        </form>
      )}
      {err && <Alert kind="red" icon="alert">{err}</Alert>}
      {mode === 'challenge' && <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }}>Lost the phone with your authenticator? Write to support@taxstreem.com from your account's email address, and TaxStreem will remove it so you can set up a new one.</div>}
      <div className="row wrap" style={{ gap: 8 }}>
        {onCancel
          ? <button type="button" className="btn btn-ghost btn-sm" onClick={onCancel}>Cancel</button>
          : <button type="button" className="btn btn-ghost btn-sm" onClick={signOut}><Icon name="logout" size={14} />Sign out</button>}
      </div>
    </div>
  );
}

// Settings, Your account: whether two-step sign-in is on, setting it up, and turning it off when it is not required.
export function TwoStepSettings() {
  const st = useTwoStep();
  const qc = useQueryClient();
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [sure, setSure] = useState(false);
  const s = st.data;
  if (!s) return null;
  const refresh = () => qc.invalidateQueries({ queryKey: ['two-step'] });
  async function turnOff() {
    if (!sure) { setSure(true); return; }
    setBusy(true); setErr(null);
    const { data, error } = await supabase.auth.mfa.listFactors();
    if (!error) for (const f of data.all) {
      const r = await supabase.auth.mfa.unenroll({ factorId: f.id });
      if (r.error) { setErr(cleanError(r.error)); break; }
    } else setErr(cleanError(error));
    await supabase.auth.refreshSession().catch(() => null);
    setBusy(false); setSure(false); refresh();
  }
  return (
    <div className="stack" style={{ gap: 8 }} data-testid="two-step-settings" data-on={s.hasFactor ? 'yes' : 'no'}>
      <div className="row wrap" style={{ gap: 10, alignItems: 'center' }}>
        <b style={{ fontSize: 14 }}>Two-step sign-in</b>
        <span className={`chip ${s.hasFactor ? 't-green' : 't-grey'}`}>{s.hasFactor ? 'On' : 'Off'}</span>
      </div>
      <div className="faint" style={{ fontSize: 13, lineHeight: 1.5 }}>
        {s.required
          ? 'Required for you: you can change this business\'s settings or its NRS keys. Counta asks for a code from your authenticator app each time you sign in.'
          : s.hasFactor ? 'Counta asks for a code from your authenticator app each time you sign in.' : 'Add a code from an authenticator app to your password, so a stolen password alone cannot open your account.'}
      </div>
      {!s.hasFactor && !open && <div><button className="btn btn-secondary btn-sm" onClick={() => setOpen(true)}><Icon name="lock" size={14} />Set up two-step sign-in</button></div>}
      {open && <CodeCard mode="enrol" required={s.required} onCancel={() => setOpen(false)} onDone={() => { setOpen(false); refresh(); }} />}
      {s.hasFactor && !s.required && s.aal === 'aal2' && (
        <div><button className="btn btn-secondary btn-sm" disabled={busy} onClick={turnOff}>{busy ? <Spinner small /> : null}{sure ? 'Tap again to turn it off' : 'Turn off two-step sign-in'}</button></div>
      )}
      {err && <Alert kind="red" icon="alert">{err}</Alert>}
    </div>
  );
}
