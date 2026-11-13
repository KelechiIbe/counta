// The holder's side of a director's recovery of a business (20261125000200_account_recovery.sql): the owner in Settings,
// or the firm's partners and managers on a full-mandate client. A director proved with their NIN that they are on the
// company's CAC record and asked to take the business over; the holder has 30 minutes to hand it over or say why not, and
// no money leaves the business's wallets until it is settled.
import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc } from '../lib/supabase';
import { when } from '../lib/format';
import { Alert, Spinner } from './ui';

export type HolderRecovery = {
  id: string; status: 'verified' | 'handover_sent' | 'disputed'; business: string; created_at: string; matched_name: string | null; matched_role: string | null;
  verified_at: string | null; handover_due: string | null; handover_at: string | null; dispute_reason: string | null;
  claimant: { name: string | null; email: string | null };
};

export const useHolderRecovery = (orgId: string | null | undefined, enabled = true) => useQuery({
  queryKey: ['recovery-for-org', orgId], enabled: !!orgId && enabled, staleTime: 30_000, refetchInterval: 60_000,
  queryFn: () => rpc<HolderRecovery | null>('recovery_for_org', { p_org: orgId }),
});

// Minutes left of the holder's 30, or 0.
export function minutesLeft(due: string | null | undefined, now = Date.now()): number {
  if (!due) return 0;
  return Math.max(0, Math.ceil((Date.parse(due) - now) / 60_000));
}

export function RecoveryHolderCard({ orgId, firm = false }: { orgId: string; firm?: boolean }) {
  const q = useHolderRecovery(orgId);
  const qc = useQueryClient();
  const [mode, setMode] = useState<'idle' | 'dispute'>('idle');
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const r = q.data;
  if (!r) return null;
  const who = r.claimant?.name || 'A director';
  async function act(fn: 'recovery_handover_start' | 'recovery_dispute') {
    setBusy(fn); setErr(null);
    try {
      await rpc(fn, fn === 'recovery_dispute' ? { p_id: r!.id, p_reason: reason.trim() } : { p_id: r!.id });
      await qc.invalidateQueries({ queryKey: ['recovery-for-org', orgId] });
      setMode('idle');
    } catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }
  const left = minutesLeft(r.handover_due);
  return (
    <section className="card card-pad stack" style={{ gap: 12, borderColor: '#F79009' }} id="ownership" aria-labelledby="recovery-h" data-testid="recovery-holder">
      <div>
        <h2 id="recovery-h" style={{ fontWeight: 700, fontSize: 15, margin: 0 }}>A director asked to take this business over</h2>
        <div className="muted" style={{ fontSize: 13, marginTop: 4, lineHeight: 1.5 }}>
          {who}{r.claimant?.email ? ` (${r.claimant.email})` : ''} proved with their NIN that they are {r.matched_name ? <>{r.matched_name}, </> : null}a director of {r.business} on its CAC record.
          Until this is settled, no money leaves the business's wallets.
        </div>
      </div>
      {r.status === 'verified' && (
        <Alert kind="amber" icon="clock">
          <span data-testid="recovery-due">
            {left > 0 ? `Answer within ${left} minute${left === 1 ? '' : 's'}.` : 'The 30 minutes have passed, so the director may ask TaxStreem to decide.'} Hand the business over,
            or say why it should not go to them. {firm ? 'Handed over, the business leaves the firm and the firm\'s places in it end.' : 'Handed over, your place in the business ends.'}
          </span>
        </Alert>
      )}
      {r.status === 'handover_sent' && (
        <Alert kind="blue" icon="mail"><span data-testid="recovery-sent">Handed over {when(r.handover_at)}. {who} has a link to take the business, signed in with their own login.</span></Alert>
      )}
      {r.status === 'disputed' && (
        <Alert kind="blue" icon="clock"><span data-testid="recovery-disputed">You said no: “{r.dispute_reason}”. TaxStreem will decide and write to you both.</span></Alert>
      )}
      {err && <Alert kind="red" icon="alert"><span role="alert">{err}</span></Alert>}
      {r.status !== 'disputed' && mode === 'idle' && (
        <div className="row wrap" style={{ gap: 8 }}>
          {r.status === 'verified' && (
            <button className="btn btn-primary btn-sm" style={{ minHeight: 40 }} disabled={!!busy} onClick={() => act('recovery_handover_start')} data-testid="recovery-handover">
              {busy === 'recovery_handover_start' ? <Spinner small /> : null}Hand it over to {who}
            </button>
          )}
          {r.status === 'handover_sent' && (
            <button className="btn btn-secondary btn-sm" style={{ minHeight: 40 }} disabled={!!busy} onClick={() => act('recovery_handover_start')} data-testid="recovery-resend">
              {busy === 'recovery_handover_start' ? <Spinner small /> : null}Send the link again
            </button>
          )}
          <button className="btn btn-ghost btn-sm" style={{ minHeight: 40 }} onClick={() => setMode('dispute')} data-testid="recovery-dispute-open">This should not go to them</button>
        </div>
      )}
      {mode === 'dispute' && (
        <form className="stack" style={{ gap: 8 }} onSubmit={(e) => { e.preventDefault(); void act('recovery_dispute'); }}>
          <label className="stack" style={{ gap: 4, fontSize: 14 }}>
            <span>Why should the business not go to {who}? TaxStreem reads this before it decides.</span>
            <textarea className="input" rows={3} maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} data-testid="recovery-dispute-reason" />
          </label>
          <div className="row wrap" style={{ gap: 8 }}>
            <button className="btn btn-primary btn-sm" disabled={busy === 'recovery_dispute' || reason.trim().length < 10} data-testid="recovery-dispute">
              {busy === 'recovery_dispute' ? <Spinner small /> : null}Send to TaxStreem
            </button>
            <button type="button" className="btn btn-ghost btn-sm" onClick={() => setMode('idle')}>Back</button>
          </div>
        </form>
      )}
    </section>
  );
}
