// The director's approvals: /approve/<token> (the token then lives in this tab only, at /approve). Under full mandate the
// firm keeps a client's books with no one at the client involved, except here: invoices, credit notes, refunds, payments
// out of the wallet and recurring invoices the firm asks for wait for the director who confirmed the wallets. The link
// comes by email; a 6-digit code to the director's phone and email then lets them approve or reject for 15 minutes.
// Approved, each is carried out as the person at the firm who asked. Rejecting takes a reason, which the firm sees. The
// page speaks for the firm and names TaxStreem's Counta only as where the books are kept.
import { useCallback, useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { edge } from '../../lib/api';
import { Alert, Spinner } from '../../components/ui';
import { useLinkToken } from './linkToken';
import { titleName, type Approval } from '../../lib/approvals';
import { ApprovalDetail } from '../approvals/ApprovalDetail';

type Open = { ok: boolean; reason?: string; error?: string; business?: string; firm?: string; director?: string; verified?: boolean; code_sent?: boolean;
  sms?: string | null; email?: string | null; items?: Approval[]; done?: Approval[]; locked?: boolean; results?: { id: string; status: string; error: string | null }[] };

export default function ApprovePage() {
  const { token: param } = useParams();
  const token = useLinkToken(param, 'counta.approve', '/approve');
  const [open, setOpen] = useState<Open | null>(null);
  const [sent, setSent] = useState(false);
  const [code, setCode] = useState('');
  const [picked, setPicked] = useState<Set<string>>(new Set());
  const [rejecting, setRejecting] = useState(false);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);

  const take = (o: Open) => {
    setOpen((prev) => ({ ...(prev || {}), ...o }));
    setPicked(new Set((o.items || []).map((a) => a.id)));
  };
  const load = useCallback(async () => {
    if (!token) { setOpen({ ok: false, error: 'This link is not valid. Ask the firm to send it again.' }); return; }
    const o = await edge<Open>('practice', { action: 'approval_open', token });
    if (o?.ok) { take(o); setSent(!!o.code_sent); } else setOpen(o);
  }, [token]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { load(); }, [load]);

  async function sendCode() {
    setBusy('code'); setErr(null); setNote(null);
    const r = await edge<any>('practice', { action: 'approval_code', token });
    setBusy(null);
    if (r?.ok === false) { setErr(r.error || 'The code could not be sent just now.'); return; }
    setSent(true);
    setNote(`We sent a 6-digit code to ${[open?.sms, open?.email].filter(Boolean).join(' and ') || 'you'}.${typeof r?.sends_left === 'number' ? ` You can ask for ${r.sends_left} more today.` : ''}`);
  }
  async function verify() {
    setBusy('verify'); setErr(null);
    const r = await edge<Open & { tries_left?: number }>('practice', { action: 'approval_verify', token, code: code.replace(/\s/g, '') });
    setBusy(null);
    if (r?.ok === false) { setErr(`${r.error || 'That did not work just now.'}${r.tries_left ? ` ${r.tries_left} tries left for this code.` : ''}`); return; }
    setCode(''); setNote(null); take(r);
  }
  async function decide(approve: boolean) {
    setBusy(approve ? 'approve' : 'reject'); setErr(null); setNote(null);
    const r = await edge<Open>('practice', { action: 'approval_decide', token, ids: [...picked], approve, note: approve ? null : reason.trim() });
    setBusy(null);
    if (r?.ok === false) {
      if (r.reason === 'approval_code_first') setOpen((o) => (o ? { ...o, verified: false } : o));
      setErr(r.error || 'That did not work just now.');
      return;
    }
    const failed = (r.results || []).filter((x) => x.status === 'failed');
    setRejecting(false); setReason('');
    take(r);
    setNote(failed.length ? `Approved, but ${failed.length === 1 ? 'one did' : `${failed.length} did`} not go through: ${failed.map((x) => x.error).join(' ')} The firm has been told.`
      : approve ? 'Approved. The firm has been told.' : 'Rejected. The firm has been told why.');
  }

  const firm = open?.firm || 'The firm';
  const business = open?.business || 'the company';
  const items = open?.items || [];
  const toggle = (id: string) => setPicked((p) => { const n = new Set(p); if (n.has(id)) n.delete(id); else n.add(id); return n; });
  return (
    <div className="sign-wrap">
      <div className="sign-card stack" style={{ gap: 16, maxWidth: 720 }}>
        {!open ? <div className="row" style={{ justifyContent: 'center', padding: 32 }}><Spinner /></div> : !open.ok ? (
          <Alert kind="amber" icon="alert"><span role="alert" data-testid="approve-refused">{open.error || 'This link cannot be used now.'}</span></Alert>
        ) : (
          <>
            <div>
              <div className="muted" style={{ fontSize: 13 }} data-testid="approve-firm">{firm}</div>
              <h1 style={{ fontSize: 22, margin: '4px 0 0' }}>Approve for {business}</h1>
            </div>
            <p style={{ margin: 0 }}>
              {firm} keeps the books of {business} under your full mandate{open.director ? `, ${titleName(open.director)}` : ''}. What it asks for below is not issued or paid until you
              approve it. Once approved, each goes ahead as the person at {firm} who asked.
            </p>
            {open.locked && <Alert kind="red" icon="alert">Too many wrong codes were entered. Ask {firm} to send the link again.</Alert>}

            {!open.verified && !open.locked && items.length > 0 && (
              <fieldset className="stack" style={{ gap: 10, border: 0, padding: 0, margin: 0 }} data-testid="approve-step-code">
                <legend style={{ fontWeight: 600, marginBottom: 6 }}>Your code</legend>
                <p className="muted" style={{ margin: 0, fontSize: 14 }}>
                  To approve or reject, enter the 6-digit code we send to {[open.sms, open.email].filter(Boolean).join(' and ') || 'your phone and email'}. It lets you decide for 15 minutes.
                </p>
                {sent && <>
                  <input className="input sign-code" inputMode="numeric" autoComplete="one-time-code" maxLength={7} placeholder="000000" aria-label="6-digit code"
                    value={code} onChange={(e) => setCode(e.target.value.replace(/[^\d ]/g, ''))} data-testid="approve-code" />
                </>}
                {note && <p className="muted" style={{ margin: 0, fontSize: 13 }} role="status" data-testid="approve-note">{note}</p>}
                <div className="row" style={{ gap: 8, flexWrap: 'wrap' }}>
                  {sent && <button className="btn btn-primary" disabled={busy === 'verify' || code.replace(/\s/g, '').length !== 6} onClick={verify} data-testid="approve-verify">
                    {busy === 'verify' ? <Spinner small /> : null}Continue</button>}
                  <button type="button" className={sent ? 'btn btn-secondary' : 'btn btn-primary'} disabled={busy === 'code'} onClick={sendCode} data-testid="approve-send-code">
                    {busy === 'code' ? <Spinner small /> : null}{sent ? 'Send the code again' : 'Send me a code'}</button>
                </div>
              </fieldset>
            )}

            {!items.length ? (
              <p style={{ margin: 0 }} data-testid="approve-nothing">Nothing waits for your approval now.{open.verified && note ? ` ${note}` : ''}</p>
            ) : (
              <div className="stack" style={{ gap: 10 }}>
                <div style={{ fontWeight: 600 }}>{items.length === 1 ? 'One item waits for you' : `${items.length} items wait for you`}</div>
                {items.map((a) => (
                  <label key={a.id} className="row" style={{ gap: 10, alignItems: 'flex-start', border: '1px solid var(--line, #E5E7EB)', borderRadius: 12, padding: 12 }}>
                    {open.verified && <input type="checkbox" checked={picked.has(a.id)} onChange={() => toggle(a.id)} style={{ marginTop: 4 }} aria-label={`Choose ${a.summary?.title || a.kind}`} />}
                    <span className="grow" style={{ minWidth: 0 }}><ApprovalDetail a={a} /></span>
                  </label>
                ))}
                {open.verified && (rejecting ? (
                  <div className="stack" style={{ gap: 8 }}>
                    <label className="stack" style={{ gap: 4 }}>
                      <span>Why are you not approving {picked.size === 1 ? 'it' : 'them'}? {firm} sees this.</span>
                      <textarea className="input" rows={3} maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} data-testid="approve-reason" />
                    </label>
                    <div className="row" style={{ gap: 8 }}>
                      <button className="btn btn-secondary" onClick={() => setRejecting(false)}>Back</button>
                      <button className="btn btn-primary" style={{ background: '#B42318', borderColor: '#B42318' }} disabled={!!busy || !picked.size || reason.trim().length < 3}
                        onClick={() => decide(false)} data-testid="approve-reject-go">{busy === 'reject' ? <Spinner small /> : null}Reject {picked.size}</button>
                    </div>
                  </div>
                ) : (
                  <div className="row" style={{ gap: 8, flexWrap: 'wrap' }}>
                    <button className="btn btn-primary" disabled={!!busy || !picked.size} onClick={() => decide(true)} data-testid="approve-go">
                      {busy === 'approve' ? <Spinner small /> : null}Approve {picked.size === items.length ? (items.length === 1 ? 'it' : `all ${items.length}`) : picked.size}</button>
                    <button className="btn btn-ghost" disabled={!!busy || !picked.size} onClick={() => setRejecting(true)} data-testid="approve-reject">Reject</button>
                  </div>
                ))}
              </div>
            )}
            {open.verified && note && items.length > 0 && <p className="muted" style={{ margin: 0, fontSize: 13 }} role="status" data-testid="approve-note">{note}</p>}
            {err && <Alert kind="red" icon="alert"><span role="alert" data-testid="approve-error">{err}</span></Alert>}
            {(open.done || []).length > 0 && (
              <div className="stack" style={{ gap: 8, borderTop: '1px solid var(--line, #E5E7EB)', paddingTop: 14 }}>
                <div className="muted" style={{ fontSize: 13 }}>Decided today</div>
                {(open.done || []).map((a) => <ApprovalDetail key={a.id} a={a} open={false} />)}
              </div>
            )}
          </>
        )}
      </div>
    </div>
  );
}
