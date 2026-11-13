// A director confirms that the firm running their company's books may open its wallets: /confirm/<token> (the token then
// lives in this tab only, at /confirm). This is the one step of a full mandate that involves the client: the page names
// the firm and says plainly that TaxStreem provides the wallets through Flutterwave, because the director is agreeing to
// accounts that hold the company's money.
// Whoever opens the link proves they are a director: their NIN must match a director on the company's CAC record, and a
// 6-digit code then goes to the phone number NIMC holds for the NIN and to their email on the CAC record. With no way to
// send a code, they upload their NIN slip and TaxStreem checks it. They can decline at any step. No Counta name.
import { useCallback, useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { edge } from '../../lib/api';
import { Alert, Spinner } from '../../components/ui';
import { useLinkToken } from './linkToken';

type Step = 'nin' | 'code' | 'slip';
type Open = { ok: boolean; reason?: string; error?: string; firm_name?: string; business_name?: string; director_name?: string; status?: string;
  step?: Step | null; route?: 'code' | 'review' | 'slip' | null; sms?: string | null; email?: string | null };
type Sent = { route?: string | null; sms?: string | null; email?: string | null };

// Where the code went, in words: "+234 803 *** **67 and k***@g***.com".
function sentTo(s: Sent): string {
  const parts = [s.sms, s.email].filter(Boolean);
  return parts.length ? parts.join(' and ') : 'you';
}

const readFile = (f: File) => new Promise<string>((ok, ko) => {
  const r = new FileReader();
  r.onload = () => ok(String(r.result));
  r.onerror = () => ko(r.error);
  r.readAsDataURL(f);
});

export default function DirectorConfirmPage() {
  const { token: param } = useParams();
  const token = useLinkToken(param, 'counta.confirm', '/confirm');
  const [open, setOpen] = useState<Open | null>(null);
  const [step, setStep] = useState<Step>('nin');
  const [sent, setSent] = useState<Sent>({});
  const [nin, setNin] = useState('');
  const [code, setCode] = useState('');
  const [note, setNote] = useState<string | null>(null);
  const [declining, setDeclining] = useState(false);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [result, setResult] = useState<'confirmed' | 'review' | 'declined' | null>(null);

  const load = useCallback(async () => {
    if (!token) { setOpen({ ok: false, error: 'This link is not valid. Ask the firm to send it again.' }); return; }
    const o = await edge<Open>('practice', { action: 'director_open', token });
    setOpen(o);
    if (o?.ok && o.step) setStep(o.step);
    if (o?.ok) setSent({ route: o.route, sms: o.sms, email: o.email });
  }, [token]);
  useEffect(() => { load(); }, [load]);

  async function checkNin() {
    setBusy('nin'); setErr(null); setNote(null);
    const r = await edge<any>('practice', { action: 'director_nin', token, nin: nin.replace(/\D/g, '') });
    setBusy(null);
    if (r?.ok === false) { setErr(r.error || 'Your NIN could not be checked just now.'); return; }
    setNin('');
    setSent({ route: r.route, sms: r.sms, email: r.email });
    setStep(r.step === 'slip' ? 'slip' : 'code');
  }
  async function resend() {
    setBusy('code'); setErr(null);
    const r = await edge<any>('practice', { action: 'director_code', token });
    setBusy(null);
    if (r?.ok === false) {
      if (r.reason === 'expired' || r.reason === 'nin_first') { setStep('nin'); }
      setErr(r.error || 'The code could not be sent just now.');
      return;
    }
    setNote(`We sent a new code to ${sentTo(sent)}.${typeof r?.sends_left === 'number' ? ` You can ask for ${r.sends_left} more today.` : ''}`);
  }
  async function confirm() {
    setBusy('confirm'); setErr(null);
    const r = await edge<any>('practice', { action: 'director_confirm', token, code: code.replace(/\s/g, '') });
    setBusy(null);
    if (r?.ok === false) { setErr(`${r.error || 'That did not work just now.'}${r.tries_left ? ` ${r.tries_left} tries left for this code.` : ''}`); return; }
    setResult(r?.status === 'review' ? 'review' : 'confirmed');
  }
  async function sendSlip(f: File | undefined) {
    if (!f) return;
    setErr(null);
    if (f.size > 5 * 1024 * 1024) { setErr('The slip is larger than 5 MB. Take a smaller photo, or scan it as a PDF.'); return; }
    if (!/^(application\/pdf|image\/(jpeg|png|webp))$/.test(f.type)) { setErr('Upload the NIN slip as a PDF or a photo (JPG, PNG or WebP).'); return; }
    setBusy('slip');
    const r = await edge<any>('practice', { action: 'director_slip', token, file: await readFile(f) });
    setBusy(null);
    if (r?.ok === false) { setErr(r.error || 'The slip could not be sent just now.'); return; }
    setResult('review');
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
  const ninOk = nin.replace(/\D/g, '').length === 11;
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
            {open.director_name && <p className="muted" style={{ margin: 0, fontSize: 14 }}>This request is addressed to {open.director_name}. If you are not a director of {business}, decline it.</p>}

            {step === 'nin' && (
              <fieldset className="stack" style={{ gap: 10, border: 0, padding: 0, margin: 0 }} data-testid="director-step-nin">
                <legend style={{ fontWeight: 600, marginBottom: 6 }}>1. Your NIN</legend>
                <p className="muted" style={{ margin: 0, fontSize: 14 }}>
                  Your NIN is checked with NIMC against the directors on the company's CAC record. Only its last four digits are kept. A 6-digit code then goes
                  to the phone number on your NIN record and to your email on the CAC record.
                </p>
                <label className="stack" style={{ gap: 4 }}>
                  <span>National Identification Number</span>
                  <input className="input" inputMode="numeric" autoComplete="off" maxLength={13} placeholder="11 digits" value={nin}
                    onChange={(e) => setNin(e.target.value.replace(/[^\d ]/g, ''))} data-testid="director-nin" />
                </label>
                <button className="btn btn-primary" disabled={busy === 'nin' || !ninOk} onClick={checkNin} data-testid="director-nin-check">
                  {busy === 'nin' ? <Spinner small /> : null}Check my NIN
                </button>
              </fieldset>
            )}

            {step === 'code' && (
              <fieldset className="stack" style={{ gap: 10, border: 0, padding: 0, margin: 0 }} data-testid="director-step-code">
                <legend style={{ fontWeight: 600, marginBottom: 6 }}>2. The code</legend>
                <p style={{ margin: 0 }} role="status" data-testid="director-sent-to">
                  We sent a 6-digit code to {sentTo(sent)}. Check your SMS messages and your email, including the spam folder.
                </p>
                {sent.route === 'review' && (
                  <p className="muted" style={{ margin: 0, fontSize: 14 }} data-testid="director-review-note">
                    NIMC has no phone number for your NIN, so the code went to your contacts on the CAC record. Once you enter it, TaxStreem checks the
                    confirmation before the wallets open.
                  </p>
                )}
                <input className="input sign-code" inputMode="numeric" autoComplete="one-time-code" maxLength={7} placeholder="000000" aria-label="6-digit code"
                  value={code} onChange={(e) => setCode(e.target.value.replace(/[^\d ]/g, ''))} data-testid="director-code" />
                {note && <p className="muted" style={{ margin: 0, fontSize: 13 }} role="status">{note}</p>}
                <div className="row" style={{ gap: 8, flexWrap: 'wrap' }}>
                  <button className="btn btn-primary" disabled={busy === 'confirm' || code.replace(/\s/g, '').length !== 6} onClick={confirm} data-testid="director-confirm">
                    {busy === 'confirm' ? <Spinner small /> : null}Confirm
                  </button>
                  <button type="button" className="btn btn-secondary" disabled={busy === 'code'} onClick={resend} data-testid="director-send-code">
                    {busy === 'code' ? <Spinner small /> : null}Send the code again
                  </button>
                </div>
              </fieldset>
            )}

            {step === 'slip' && (
              <fieldset className="stack" style={{ gap: 10, border: 0, padding: 0, margin: 0 }} data-testid="director-step-slip">
                <legend style={{ fontWeight: 600, marginBottom: 6 }}>2. Your NIN slip</legend>
                <p style={{ margin: 0 }}>
                  Your NIN matches a director on the CAC record, but there is no phone number or email we can send a code to. Upload your NIN slip (or the
                  NIMC app's ID page) and TaxStreem will check it before the wallets open.
                </p>
                <label className="btn btn-secondary" style={{ alignSelf: 'flex-start', minHeight: 44 }}>
                  {busy === 'slip' ? <Spinner small /> : null}Upload the NIN slip
                  <input type="file" accept="application/pdf,image/jpeg,image/png,image/webp" hidden disabled={busy === 'slip'}
                    onChange={(e) => sendSlip(e.target.files?.[0])} data-testid="director-slip" />
                </label>
                <span className="muted" style={{ fontSize: 13 }}>A PDF or a photo, up to 5 MB.</span>
              </fieldset>
            )}

            {err && <Alert kind="red" icon="alert"><span role="alert" data-testid="director-error">{err}</span></Alert>}
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
