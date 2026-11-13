// A director confirms that the firm running their company's books may open its wallets: /confirm/<token> (the token then
// lives in this tab only, at /confirm). This is the one step of a full mandate that involves the client: the page names
// the firm and says plainly that TaxStreem provides the wallets through Flutterwave, because the director is agreeing to
// accounts that hold the company's money. They confirm with a code sent to their email, or decline with a reason.
import { useCallback, useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { edge } from '../../lib/api';
import { Alert, Spinner } from '../../components/ui';
import { useLinkToken } from './linkToken';

type Open = { ok: boolean; reason?: string; error?: string; firm_name?: string; business_name?: string; director_name?: string; status?: string };

export default function DirectorConfirmPage() {
  const { token: param } = useParams();
  const token = useLinkToken(param, 'counta.confirm', '/confirm');
  const [open, setOpen] = useState<Open | null>(null);
  const [codeSent, setCodeSent] = useState<string | null>(null);
  const [code, setCode] = useState('');
  const [declining, setDeclining] = useState(false);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [result, setResult] = useState<'confirmed' | 'review' | 'declined' | null>(null);

  const load = useCallback(async () => {
    if (!token) { setOpen({ ok: false, error: 'This link is not valid. Ask the firm to send it again.' }); return; }
    setOpen(await edge<Open>('practice', { action: 'director_open', token }));
  }, [token]);
  useEffect(() => { load(); }, [load]);

  async function sendCode() {
    setBusy('code'); setErr(null);
    const r = await edge<any>('practice', { action: 'director_code', token });
    setBusy(null);
    if (r?.ok === false) { setErr(r.error || 'The code could not be sent just now.'); return; }
    setCodeSent(`We sent a 6-digit code to your email.${typeof r?.sends_left === 'number' ? ` You can ask for ${r.sends_left} more today.` : ''}`);
  }
  async function confirm() {
    setBusy('confirm'); setErr(null);
    const r = await edge<any>('practice', { action: 'director_confirm', token, code: code.replace(/\s/g, '') });
    setBusy(null);
    if (r?.ok === false) { setErr(`${r.error || 'That did not work just now.'}${r.tries_left ? ` ${r.tries_left} tries left for this code.` : ''}`); return; }
    setResult(r?.status === 'review' ? 'review' : 'confirmed');
  }
  async function decline() {
    setBusy('decline'); setErr(null);
    const r = await edge<any>('practice', { action: 'director_decline', token, reason: reason.trim() || null });
    setBusy(null);
    if (r?.ok === false) { setErr(r.error || 'That did not work just now.'); return; }
    setResult('declined');
  }

  const firm = open?.firm_name || 'The firm';
  const business = open?.business_name || 'the company';
  const state = result || (open?.ok && ['confirmed', 'review', 'declined'].includes(String(open.status)) ? open!.status as 'confirmed' | 'review' | 'declined' : null);
  return (
    <div className="sign-wrap">
      <div className="sign-card stack" style={{ gap: 16 }}>
        {!open ? <div className="row" style={{ justifyContent: 'center', padding: 32 }}><Spinner /></div> : !open.ok ? (
          <Alert kind="amber" icon="alert"><span role="alert">{open.error || 'This link cannot be used now.'}</span></Alert>
        ) : state === 'review' ? (
          <p style={{ margin: 0 }} data-testid="director-review">Thank you. TaxStreem will check this confirmation and tell {firm}.</p>
        ) : state === 'confirmed' ? (
          <p style={{ margin: 0 }} data-testid="director-done">Thank you. {firm} can now open the wallets for {business}.</p>
        ) : state === 'declined' ? (
          <p style={{ margin: 0 }} data-testid="director-done">You declined. {firm} and TaxStreem have been told, and no wallet will be opened.</p>
        ) : (
          <>
            <div>
              <div className="muted" style={{ fontSize: 13 }} data-testid="director-firm">{firm}</div>
              <h1 style={{ fontSize: 22, margin: '4px 0 0' }}>Confirm the wallets for {business}</h1>
            </div>
            <p style={{ margin: 0 }} data-testid="director-provider">
              {firm} asks you, as a director of {business}, to confirm that it may open a business wallet and a tax wallet for {business}. The wallets are
              provided by TaxStreem through Flutterwave and hold the company's money.
            </p>
            {open.director_name && <p className="muted" style={{ margin: 0, fontSize: 14 }}>This request is addressed to {open.director_name}. If that is not you, decline it.</p>}
            <fieldset className="stack" style={{ gap: 10, border: 0, padding: 0, margin: 0 }}>
              <legend style={{ fontWeight: 600, marginBottom: 6 }}>Confirm with a code</legend>
              <div className="row" style={{ gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
                <button type="button" className="btn btn-secondary" disabled={busy === 'code'} onClick={sendCode} data-testid="director-send-code">
                  {busy === 'code' ? <Spinner small /> : null}{codeSent ? 'Send another code' : 'Email me a code'}
                </button>
                <input className="input sign-code" inputMode="numeric" autoComplete="one-time-code" maxLength={7} placeholder="000000" aria-label="6-digit code"
                  value={code} onChange={(e) => setCode(e.target.value.replace(/[^\d ]/g, ''))} data-testid="director-code" />
              </div>
              {codeSent && <p className="muted" style={{ margin: 0, fontSize: 13 }} role="status">{codeSent}</p>}
              <button className="btn btn-primary" disabled={busy === 'confirm' || code.replace(/\s/g, '').length !== 6} onClick={confirm} data-testid="director-confirm">
                {busy === 'confirm' ? <Spinner small /> : null}Confirm
              </button>
            </fieldset>
            {err && <Alert kind="red" icon="alert"><span role="alert">{err}</span></Alert>}
            <div className="stack" style={{ gap: 8, borderTop: '1px solid var(--line, #E5E7EB)', paddingTop: 14 }}>
              {declining ? (
                <>
                  <label className="stack" style={{ gap: 4 }}>
                    <span>Why are you declining? (optional)</span>
                    <textarea className="input" rows={3} maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} data-testid="director-decline-reason" />
                  </label>
                  <div className="row" style={{ gap: 8 }}>
                    <button className="btn btn-secondary" onClick={() => setDeclining(false)}>Back</button>
                    <button className="btn btn-primary" style={{ background: '#B42318', borderColor: '#B42318' }} disabled={busy === 'decline'} onClick={decline} data-testid="director-decline">
                      {busy === 'decline' ? <Spinner small /> : null}Decline the request
                    </button>
                  </div>
                </>
              ) : (
                <button className="btn btn-ghost" style={{ alignSelf: 'flex-start', minHeight: 44 }} onClick={() => setDeclining(true)} data-testid="director-decline">I do not agree</button>
              )}
            </div>
          </>
        )}
      </div>
    </div>
  );
}
