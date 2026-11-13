// Recoveries and support, for TaxStreem (20261125000200_account_recovery.sql). A director who found their company already
// on Counta under someone else proves with their NIN that they are on its CAC record, and the holder has 30 minutes to
// hand it over. TaxStreem checks the recoveries the code could not settle (no phone on the NIN record, or another
// director's recovery open), decides disputes, and hands a business over itself when the holder does not answer (admins).
// Support requests from the app land here too. Every decision takes a note and is in the audit log.
import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc } from '../../lib/supabase';
import { when } from '../../lib/format';
import { useToast } from '../../state/session';
import { Alert, Spinner } from '../../components/ui';
import { Card, PageHead } from '../ui';
import { type AdminRecovery, type SupportCase, skippedText, useAdminRecoveries } from '../api';

const STATUS: Record<string, [string, string]> = {
  started: ['Proving who they are', 't-grey'], review: ['For TaxStreem to check', 't-amber'], verified: ['Holder has 30 minutes', 't-blue'],
  handover_sent: ['Link with the director', 't-blue'], disputed: ['Disputed: TaxStreem decides', 't-red'], completed: ['Taken over', 't-green'],
  rejected: ['Rejected', 't-grey'], cancelled: ['Stopped by the director', 't-grey'],
};
const REVIEW: Record<string, string> = {
  no_nin_phone: 'NIMC holds no phone for the NIN, so the code went only to the CAC record\'s contacts. The holder has not been told yet.',
  sms_not_ready: 'SMS is not set up (Keys and services, SMS), so the code went by email only. The holder has not been told yet.',
  another_recovery: 'Another director\'s recovery of this business is open. Decide that one first.',
};
const KIND: Record<string, string> = {
  recovery_waiting: 'The holder has not handed the business over', recovery_no_access: 'The director cannot get their code',
  recovery_dispute: 'The holder disputes a recovery', other: 'Help needed',
};

export default function Recoveries({ admin }: { admin: boolean }) {
  const q = useAdminRecoveries();
  const d = q.data;
  const open = (d?.recoveries || []).filter((r) => ['review', 'verified', 'handover_sent', 'disputed'].includes(r.status));
  const past = (d?.recoveries || []).filter((r) => !open.includes(r));
  const cases = (d?.cases || []).filter((c) => c.status === 'open');
  return (
    <>
      <PageHead title="Recoveries and support" sub="Directors taking over businesses someone else set up on Counta. A company is on Counta once; the director proves with their NIN that they are on its CAC record." />
      {q.isLoading ? <div className="row" style={{ justifyContent: 'center', padding: 40 }}><Spinner /></div>
        : q.isError || !d ? <Alert kind="red" icon="alert">{cleanError(q.error)}</Alert> : (
        <>
          <section className="stack" style={{ gap: 12 }} aria-labelledby="rc-h" data-testid="recoveries-open">
            <h2 id="rc-h" style={{ fontSize: 17, margin: 0 }}>Open recoveries {open.length ? <span className="chip t-amber">{open.length}</span> : null}</h2>
            {!open.length ? <Alert kind="green" icon="check">Nothing open.</Alert> : open.map((r) => <RecoveryRow key={r.id} r={r} admin={admin} />)}
          </section>
          <section className="stack" style={{ gap: 12 }} aria-labelledby="sc-h" data-testid="support-cases">
            <h2 id="sc-h" style={{ fontSize: 17, margin: 0 }}>Support requests {cases.length ? <span className="chip t-amber">{cases.length}</span> : null}</h2>
            {!cases.length ? <Alert kind="green" icon="check">No open requests.</Alert> : cases.map((c) => <CaseRow key={c.id} c={c} />)}
          </section>
          {past.length > 0 && (
            <section className="stack" style={{ gap: 12 }} aria-labelledby="rp-h">
              <h2 id="rp-h" style={{ fontSize: 17, margin: 0 }}>The last 30 days</h2>
              <Card pad={false}>
                {past.map((r) => (
                  <div key={r.id} className="card-pad row wrap" style={{ gap: 10, borderTop: '1px solid var(--line)', fontSize: 14 }}>
                    <span style={{ flex: '1 1 240px', minWidth: 0 }}><b>{r.business}</b> · {r.claimant?.name || r.claimant_email}</span>
                    <span className={'chip ' + (STATUS[r.status]?.[1] || 't-grey')}>{STATUS[r.status]?.[0] || r.status}</span>
                    <span className="faint">{when(r.completed_at || r.created_at)}</span>
                  </div>
                ))}
              </Card>
            </section>
          )}
        </>
      )}
    </>
  );
}

function Note({ actions, placeholder }: { actions: { label: string; tone: 'primary' | 'danger' | 'secondary'; run: (note: string) => Promise<void>; testid: string }[]; placeholder: string }) {
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  async function go(a: (typeof actions)[number]) {
    if (note.trim().length < 5) { setErr('Write a note of at least 5 characters first.'); return; }
    setBusy(a.label); setErr(null);
    try { await a.run(note.trim()); setNote(''); } catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }
  return (
    <div className="stack" style={{ gap: 6 }}>
      <div className="row wrap" style={{ gap: 8 }}>
        <input className="input" style={{ flex: '1 1 260px', minWidth: 0, minHeight: 40 }} placeholder={placeholder} aria-label="Note" maxLength={1000}
          value={note} onChange={(e) => setNote(e.target.value)} />
        {actions.map((a) => (
          <button key={a.label} type="button" className={`btn btn-sm btn-${a.tone}`} style={{ minHeight: 40 }} disabled={busy !== null} onClick={() => go(a)} data-testid={a.testid}>
            {busy === a.label ? <Spinner small /> : null}{a.label}
          </button>
        ))}
      </div>
      {err && <Alert kind="red" icon="alert"><span role="alert">{err}</span></Alert>}
    </div>
  );
}

function RecoveryRow({ r, admin }: { r: AdminRecovery; admin: boolean }) {
  const qc = useQueryClient();
  const toast = useToast();
  const decide = (action: 'approve' | 'reject' | 'transfer') => async (note: string) => {
    if (action === 'transfer' && !window.confirm(`Hand ${r.business} to ${r.claimant?.name || 'the director'} now? The holder's place ends.`)) return;
    await rpc('admin_recovery_decide', { p_id: r.id, p_action: action, p_note: note });
    await qc.invalidateQueries({ queryKey: ['admin-recoveries'] });
    toast(action === 'approve' ? 'Approved: the holder is told and has 30 minutes' : action === 'reject' ? 'Rejected: the director is told why' : `${r.business} handed over`);
  };
  const actions: { label: string; tone: 'primary' | 'danger' | 'secondary'; run: (note: string) => Promise<void>; testid: string }[] = [];
  if (r.status === 'review') actions.push({ label: 'Approve', tone: 'primary', run: decide('approve'), testid: 'recovery-approve' });
  if (admin && ['verified', 'handover_sent', 'disputed'].includes(r.status)) actions.push({ label: 'Hand it over now', tone: 'primary', run: decide('transfer'), testid: 'recovery-transfer' });
  actions.push({ label: 'Reject', tone: 'danger', run: decide('reject'), testid: 'recovery-reject' });
  const due = r.handover_due ? Date.parse(r.handover_due) : null;
  return (
    <div className="card card-pad stack" style={{ gap: 10 }} data-testid="recovery-row">
      <div className="row wrap" style={{ gap: 10, alignItems: 'flex-start' }}>
        <div style={{ flex: '1 1 260px', minWidth: 0 }}>
          <div style={{ fontWeight: 700, fontSize: 16 }}>{r.business}</div>
          <div className="faint" style={{ fontSize: 13 }}>Asked {when(r.created_at)}{r.status === 'verified' && due ? ` · holder's time ${due > Date.now() ? 'runs out' : 'ran out'} ${when(r.handover_due!)}` : ''}</div>
        </div>
        <span className={'chip ' + (STATUS[r.status]?.[1] || 't-grey')}>{STATUS[r.status]?.[0] || r.status}</span>
      </div>
      <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14, fontSize: 14, lineHeight: 1.6 }}>
        <div>
          <div className="mini-label">The director</div>
          <div>{r.claimant?.name}{r.matched_name ? ` (NIN matched ${r.matched_name}${r.matched_role === 'owner' ? ', a proprietor' : ''})` : ''}</div>
          <div className="faint" style={{ wordBreak: 'break-all' }}>{r.claimant_email}{r.nin_last4 ? ` · NIN ending ${r.nin_last4}` : ''}</div>
          {r.code_went && <div className="faint">Code to {[r.code_went.sms, r.code_went.email].filter(Boolean).join(' and ') || 'nowhere'}{skippedText(r.code_went.skipped) ? `. ${skippedText(r.code_went.skipped)}` : ''}.</div>}
        </div>
        <div>
          <div className="mini-label">The holder</div>
          <div style={{ wordBreak: 'break-all' }}>{r.holder_emails.join(', ') || 'No owner with a login'}</div>
          {r.status === 'review' && <div className="faint">{REVIEW[r.review_reason || ''] || 'For a check.'}</div>}
          {r.dispute_reason && <div>Said no: “{r.dispute_reason}”</div>}
        </div>
      </div>
      <Note placeholder="Note (what you checked, e.g. called the director on the CAC phone number)" actions={actions} />
    </div>
  );
}

function CaseRow({ c }: { c: SupportCase }) {
  const qc = useQueryClient();
  const toast = useToast();
  const close = async (note: string) => {
    await rpc('admin_support_close', { p_id: c.id, p_note: note });
    await qc.invalidateQueries({ queryKey: ['admin-recoveries'] });
    toast('Request closed');
  };
  return (
    <div className="card card-pad stack" style={{ gap: 8 }} data-testid="support-row">
      <div className="row wrap" style={{ gap: 10 }}>
        <span style={{ fontWeight: 700, flex: '1 1 240px', minWidth: 0 }}>{KIND[c.kind] || c.kind}{c.business ? ` · ${c.business}` : ''}</span>
        <span className="faint" style={{ fontSize: 13 }}>{when(c.created_at)}</span>
      </div>
      <div style={{ fontSize: 14, wordBreak: 'break-word' }}>{c.message || 'No message.'}</div>
      <div className="faint" style={{ fontSize: 13 }}>Reply to {c.contact_email || 'no address'}. The request was emailed to the support address too.</div>
      <Note placeholder="Note (what you did)" actions={[{ label: 'Close the request', tone: 'secondary', run: close, testid: 'support-close' }]} />
    </div>
  );
}
