// A director recovers a business someone else set up on Counta (20261125000200_account_recovery.sql):
//   /recover               starts (or carries on) the recovery of the company on the person's business profile draft
//   /recover/:id           the recovery: the NIN, then the code, then the holder's 30 minutes, the handover or TaxStreem
//   /recover/accept/:token the handover link, taken signed in with the login that asked
// The person proves they are a director: their NIN must match a director on the company's CAC record, and a code goes to
// the phone NIMC holds for the NIN and their email on the CAC record (never to an address of the business's people). The
// holder is then told and has 30 minutes; no money leaves the business meanwhile. TaxStreem's support helps when the
// holder does not answer, says no, or the person cannot get the code.
import { useEffect, useRef, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc } from '../../lib/supabase';
import { edge } from '../../lib/api';
import { useSession } from '../../state/session';
import { Icon } from '../../components/Icon';
import { Alert, Spinner } from '../../components/ui';

export type Recovery = {
  id: string; status: 'started' | 'review' | 'verified' | 'handover_sent' | 'completed' | 'disputed' | 'rejected' | 'cancelled'; business: string;
  created_at: string; matched_name: string | null; verified_at: string | null; handover_due: string | null; handover_at: string | null; completed_at: string | null;
  review_reason: string | null; dispute_reason: string | null; decision_note: string | null; holder_email: string | null;
  step: 'nin' | 'code' | 'support' | null; route: 'code' | 'review' | 'slip' | null; sms: string | null; email: string | null; support_open: boolean;
  support: { id: string; status: 'open' | 'closed'; kind: string; at: string } | null;
};
const OPEN = ['started', 'review', 'verified', 'handover_sent', 'disputed'];
const clock = (iso: string | null) => (iso ? new Date(iso).toLocaleTimeString('en-NG', { hour: 'numeric', minute: '2-digit', hour12: true }) : '');

function Frame({ title, lead, children }: { title: string; lead?: React.ReactNode; children: React.ReactNode }) {
  return (
    <div className="sign-wrap">
      <div className="sign-card stack" style={{ gap: 16 }}>
        <img src="/logo-brand.svg" alt="TaxStreem" style={{ height: 22, alignSelf: 'flex-start' }} />
        <div>
          <h1 style={{ fontSize: 22, margin: 0 }}>{title}</h1>
          {lead && <div className="muted" style={{ fontSize: 14, marginTop: 6, lineHeight: 1.5 }}>{lead}</div>}
        </div>
        {children}
      </div>
    </div>
  );
}

// /recover: the recovery of the company on the draft, then its own page.
export function RecoverStart() {
  const nav = useNavigate();
  const [err, setErr] = useState<string | null>(null);
  const once = useRef(false);
  useEffect(() => {
    if (once.current) return;
    once.current = true;
    rpc<Recovery>('recovery_start').then((r) => nav(`/recover/${r.id}`, { replace: true })).catch((e) => setErr(cleanError(e)));
  }, [nav]);
  return (
    <Frame title="Recover a business">
      {err ? <>
        <Alert kind="amber" icon="alert"><span role="alert">{err}</span></Alert>
        <SupportForm kinds={['other']} />
        <Link to="/onboarding" className="btn btn-secondary">Back to setting up</Link>
      </> : <div className="row" style={{ justifyContent: 'center', padding: 24 }}><Spinner /></div>}
    </Frame>
  );
}

export function RecoverPage() {
  const { id = '' } = useParams();
  const qc = useQueryClient();
  const q = useQuery({ queryKey: ['recovery', id], enabled: /^[0-9a-f-]{36}$/i.test(id), retry: 1,
    refetchInterval: (query) => (OPEN.includes(String((query.state.data as Recovery | undefined)?.status)) ? 20_000 : false),
    queryFn: () => rpc<Recovery>('recovery_get', { p_id: id }) });
  const r = q.data;
  const [nin, setNin] = useState('');
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const reload = () => qc.invalidateQueries({ queryKey: ['recovery', id] });

  async function checkNin() {
    setBusy('nin'); setErr(null); setNote(null);
    const x = await edge<any>('mono', { action: 'recovery_nin', recovery_id: id, nin: nin.replace(/\D/g, '') });
    setBusy(null);
    if (x?.ok === false) { setErr(x.error || 'Your NIN could not be checked just now.'); return; }
    setNin('');
    qc.setQueryData(['recovery', id], x);
  }
  async function resend() {
    setBusy('code'); setErr(null);
    try {
      const x = await rpc<{ sends_left?: number }>('recovery_code', { p_id: id });
      setNote(`We sent a new code.${typeof x?.sends_left === 'number' ? ` You can ask for ${x.sends_left} more today.` : ''}`);
    } catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }
  async function verify() {
    setBusy('verify'); setErr(null);
    try {
      const x = await rpc<any>('recovery_verify', { p_id: id, p_code: code.replace(/\s/g, '') });
      if (x?.ok === false) {
        setErr(x.reason === 'wrong_code' ? `That code is not right.${x.tries_left ? ` ${x.tries_left} tries left for this code.` : ''}`
          : x.reason === 'locked' ? 'Too many wrong codes were entered. Ask TaxStreem\'s support for help.'
          : 'That code has expired or was used already. Ask for a new code.');
      } else { setCode(''); qc.setQueryData(['recovery', id], x); }
    } catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }
  async function cancel() {
    if (!window.confirm('Stop recovering this business?')) return;
    setBusy('cancel'); setErr(null);
    try { qc.setQueryData(['recovery', id], await rpc<Recovery>('recovery_cancel', { p_id: id })); } catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }

  if (q.isLoading) return <Frame title="Recover a business"><div className="row" style={{ justifyContent: 'center', padding: 24 }}><Spinner /></div></Frame>;
  if (!r) return <Frame title="Recover a business"><Alert kind="amber" icon="alert"><span role="alert">{q.isError ? cleanError(q.error) : 'Recovery not found.'}</span></Alert></Frame>;
  const lead = <>{r.business} is on Counta under another account{r.holder_email ? <> ({r.holder_email})</> : null}. If you are a director on its CAC record, you can take it over.</>;
  return (
    <Frame title={`Recover ${r.business}`} lead={r.status === 'started' ? lead : undefined}>
      {r.status === 'started' && r.step === 'nin' && (
        <fieldset className="stack" style={{ gap: 10, border: 0, padding: 0, margin: 0 }} data-testid="recover-step-nin">
          <legend style={{ fontWeight: 600, marginBottom: 6 }}>1. Your NIN</legend>
          <p className="muted" style={{ margin: 0, fontSize: 14 }}>
            Counta checks it with NIMC against the directors on the company's CAC record and keeps only its last four digits. A 6-digit code then goes to the
            phone number on your NIN record and to your email on the CAC record.
          </p>
          <label className="stack" style={{ gap: 4 }}>
            <span>National Identification Number</span>
            <input className="input" inputMode="numeric" autoComplete="off" maxLength={13} placeholder="11 digits" value={nin}
              onChange={(e) => setNin(e.target.value.replace(/[^\d ]/g, ''))} data-testid="recover-nin" />
          </label>
          <button className="btn btn-primary" disabled={busy === 'nin' || nin.replace(/\D/g, '').length !== 11} onClick={checkNin} data-testid="recover-nin-check">
            {busy === 'nin' ? <Spinner small /> : null}Check my NIN
          </button>
        </fieldset>
      )}
      {r.status === 'started' && r.step === 'code' && (
        <fieldset className="stack" style={{ gap: 10, border: 0, padding: 0, margin: 0 }} data-testid="recover-step-code">
          <legend style={{ fontWeight: 600, marginBottom: 6 }}>2. The code</legend>
          <p style={{ margin: 0 }} role="status" data-testid="recover-sent-to">
            {r.matched_name ? <>Your NIN matches {r.matched_name} on the CAC record. </> : null}
            We sent a 6-digit code to {[r.sms, r.email].filter(Boolean).join(' and ') || 'you'}. Check your SMS messages and your email, including the spam folder.
          </p>
          {r.route === 'review' && (
            <p className="muted" style={{ margin: 0, fontSize: 14 }}>NIMC has no phone number for your NIN, so the code went to your contacts on the CAC record. TaxStreem checks the recovery before the holder is told.</p>
          )}
          <input className="input sign-code" inputMode="numeric" autoComplete="one-time-code" maxLength={7} placeholder="000000" aria-label="6-digit code"
            value={code} onChange={(e) => setCode(e.target.value.replace(/[^\d ]/g, ''))} data-testid="recover-code" />
          {note && <p className="muted" style={{ margin: 0, fontSize: 13 }} role="status">{note}</p>}
          <div className="row wrap" style={{ gap: 8 }}>
            <button className="btn btn-primary" disabled={busy === 'verify' || code.replace(/\s/g, '').length !== 6} onClick={verify} data-testid="recover-verify">
              {busy === 'verify' ? <Spinner small /> : null}Confirm
            </button>
            <button className="btn btn-secondary" disabled={busy === 'code'} onClick={resend} data-testid="recover-resend">{busy === 'code' ? <Spinner small /> : null}Send the code again</button>
          </div>
        </fieldset>
      )}
      {r.status === 'started' && r.step === 'support' && (
        <Alert kind="amber" icon="alert"><span data-testid="recover-no-channel">
          Your NIN matches a director on the CAC record, but there is no phone number or email of yours we can send a code to: the ones on record belong to the
          account that holds the business. Ask TaxStreem's support below and they will check who you are.
        </span></Alert>
      )}
      {r.status === 'review' && (
        <Alert kind="blue" icon="clock"><span data-testid="recover-review">TaxStreem is checking your recovery{r.review_reason === 'another_recovery' ? ', because another director asked for this business too' : ''}. We will email you when it has decided.</span></Alert>
      )}
      {r.status === 'verified' && (
        <Alert kind="blue" icon="clock"><span data-testid="recover-waiting">
          You proved who you are. The account that holds {r.business}{r.holder_email ? ` (${r.holder_email})` : ''} has been told and has until {clock(r.handover_due)} to hand it over.
          No money leaves the business meanwhile. {r.support_open ? 'The 30 minutes have passed: you can ask TaxStreem\'s support to step in.' : 'This page updates by itself.'}
        </span></Alert>
      )}
      {r.status === 'handover_sent' && (
        <Alert kind="green" icon="mail"><span data-testid="recover-handover">The holder handed the business over. Open the link we emailed you, signed in with this login, to take it.</span></Alert>
      )}
      {r.status === 'disputed' && (
        <Alert kind="amber" icon="alert"><span data-testid="recover-disputed">The holder said no{r.dispute_reason ? `: “${r.dispute_reason}”` : ''}. TaxStreem will decide and write to you. No money leaves the business meanwhile.</span></Alert>
      )}
      {r.status === 'completed' && <Done orgName={r.business} />}
      {r.status === 'rejected' && (
        <Alert kind="red" icon="alert"><span data-testid="recover-rejected">TaxStreem did not approve the recovery{r.decision_note ? `: “${r.decision_note}”` : '.'}</span></Alert>
      )}
      {r.status === 'cancelled' && <Alert kind="grey" icon="info">You stopped this recovery.</Alert>}
      {err && <Alert kind="red" icon="alert"><span role="alert" data-testid="recover-error">{err}</span></Alert>}
      {r.support_open && OPEN.includes(r.status) && (
        r.support?.status === 'open'
          ? <Alert kind="blue" icon="check"><span data-testid="recover-support-sent">TaxStreem's support has your request and will write to you.</span></Alert>
          : <SupportForm recoveryId={r.id} kinds={r.status === 'started' ? ['recovery_no_access'] : ['recovery_waiting']} onSent={reload} />
      )}
      {['started', 'review', 'verified', 'disputed'].includes(r.status) && (
        <button className="btn btn-ghost btn-sm" style={{ alignSelf: 'flex-start', minHeight: 40 }} disabled={busy === 'cancel'} onClick={cancel} data-testid="recover-cancel">Stop this recovery</button>
      )}
    </Frame>
  );
}

function Done({ orgName, orgId }: { orgName: string; orgId?: string }) {
  const { refreshMemberships, setOrgId } = useSession();
  const nav = useNavigate();
  const qc = useQueryClient();
  async function open() {
    qc.clear();
    const ms = await refreshMemberships().catch(() => []);
    const m = orgId ? { org_id: orgId } : (ms as { org_id: string; name: string }[]).find((x) => x.name === orgName);
    if (m) setOrgId(m.org_id);
    nav('/home', { replace: true });
  }
  return (
    <>
      <Alert kind="green" icon="check"><span data-testid="recover-done">{orgName} is yours on Counta now. Its previous owner's place has ended.</span></Alert>
      <button className="btn btn-primary" onClick={open} data-testid="recover-open"><Icon name="building" size={16} color="#fff" />Open {orgName}</button>
    </>
  );
}

const KIND_WORD: Record<string, string> = {
  recovery_waiting: 'The holder has not handed the business over',
  recovery_no_access: 'I cannot get the code (I no longer have the phone on my NIN record or the email on the CAC record)',
  other: 'Something else',
};
function SupportForm({ recoveryId, kinds, onSent }: { recoveryId?: string; kinds: string[]; onSent?: () => void }) {
  const [kind, setKind] = useState(kinds[0]);
  const [message, setMessage] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [sent, setSent] = useState(false);
  const all = recoveryId ? [...new Set([...kinds, 'recovery_waiting', 'recovery_no_access'])] : kinds;
  async function send() {
    setBusy(true); setErr(null);
    try {
      await rpc('support_request', { p: { kind, recovery_id: recoveryId ?? null, message: message.trim() || null } });
      setSent(true); onSent?.();
    } catch (e) { setErr(cleanError(e)); }
    setBusy(false);
  }
  if (sent) return <Alert kind="blue" icon="check"><span data-testid="recover-support-sent">TaxStreem's support has your request and will write to you.</span></Alert>;
  return (
    <form className="stack" style={{ gap: 8, borderTop: '1px solid var(--line, #E5E7EB)', paddingTop: 14 }} onSubmit={(e) => { e.preventDefault(); void send(); }} data-testid="recover-support">
      <div style={{ fontWeight: 600 }}>Ask TaxStreem's support</div>
      {all.length > 1 && (
        <select className="input" value={kind} onChange={(e) => setKind(e.target.value)} aria-label="What the request is about" data-testid="recover-support-kind">
          {all.map((k) => <option key={k} value={k}>{KIND_WORD[k]}</option>)}
        </select>
      )}
      <textarea className="input" rows={3} maxLength={2000} value={message} placeholder="Anything that helps TaxStreem check who you are (optional)"
        onChange={(e) => setMessage(e.target.value)} aria-label="Your message" data-testid="recover-support-message" />
      {err && <Alert kind="red" icon="alert"><span role="alert">{err}</span></Alert>}
      <button className="btn btn-secondary" style={{ alignSelf: 'flex-start' }} disabled={busy || (kind === 'other' && message.trim().length < 10)} data-testid="recover-support-send">
        {busy ? <Spinner small /> : <Icon name="send" size={14} />}Send to support
      </button>
    </form>
  );
}

// /recover/accept/:token: the handover link.
export function RecoverAccept() {
  const { token = '' } = useParams();
  const [state, setState] = useState<{ busy: boolean; err: string | null; org: { id: string; name: string } | null }>({ busy: false, err: null, org: null });
  async function take() {
    setState({ busy: true, err: null, org: null });
    try {
      const r = await rpc<{ org_id: string; recovery: Recovery }>('recovery_accept', { p_token: token });
      setState({ busy: false, err: null, org: { id: r.org_id, name: r.recovery.business } });
    } catch (e) { setState({ busy: false, err: cleanError(e), org: null }); }
  }
  return (
    <Frame title="Take over the business" lead="The holder handed the business over to you. Take it with this login: you become its owner, and the previous owner's place ends.">
      {state.org ? <Done orgName={state.org.name} orgId={state.org.id} /> : <>
        {state.err && <Alert kind="red" icon="alert"><span role="alert" data-testid="recover-accept-error">{state.err}</span></Alert>}
        <button className="btn btn-primary" disabled={state.busy || !/^rh_[0-9a-f]{48}$/.test(token)} onClick={take} data-testid="recover-accept">
          {state.busy ? <Spinner small /> : <Icon name="check" size={16} color="#fff" />}Take over the business
        </button>
      </>}
    </Frame>
  );
}
