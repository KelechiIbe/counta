// TaxStreem's identity reviews: NIN slips whose name did not match a director on the CAC record, and businesses handed
// over by a firm to someone other than the director who confirmed their wallets. Approving opens the business's payments
// (a handed-over business never confirmed before goes back to the ordinary NIN check); rejecting tells the owner why. A
// rejected handover can be decided again. Reviewers and admins see this, after an authenticator code.
import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc, supabase } from '../../lib/supabase';
import { Link } from 'react-router-dom';
import { when } from '../../lib/format';
import { Icon } from '../../components/Icon';
import { Alert, Spinner } from '../../components/ui';
import { PageHead } from '../ui';

type Row = {
  org_id: string; business: string; rc_number: string | null; legal_form: string | null; status: 'review' | 'approved' | 'rejected'; attempts: number;
  people: { name: string; role: string }[];
  slip: { path: string; file_name?: string; at?: string; read_at?: string; name?: string; last4?: string; is_nin_document?: boolean; warnings?: string[] } | null;
  review: { approved: boolean; note: string | null; at: string } | null;
  owner: { name: string; email: string | null } | null;
  // reason 'handover' while a handover waits or was rejected; handover: its record (kept after it is approved).
  reason?: string | null; handover?: { id: string; at: string; status_before: string | null } | null;
};
const BEFORE: Record<string, string> = { pending: 'not checked', review: 'in review', verified: 'verified', approved: 'approved', rejected: 'rejected', not_required: 'not needed' };

export default function Reviews() {
  const list = useQuery({ queryKey: ['identity-reviews'], queryFn: () => rpc<Row[]>('identity_reviews') });
  return (
    <>
      <PageHead title="Identity reviews" sub="NIN slips that did not match a director on the CAC record, businesses handed over by a firm, and the decisions of the last 30 days." />
      {list.isLoading ? <div className="row" style={{ justifyContent: 'center', padding: 40 }}><Spinner /></div>
        : list.isError ? <Alert kind="red" icon="alert">{cleanError(list.error)}</Alert>
        : !list.data?.length ? <Alert kind="green" icon="check">Nothing waiting. Slips that need a person to look at them appear here.</Alert>
        : <div className="stack" style={{ gap: 14 }}>{list.data.map((r) => <ReviewCard key={r.org_id} r={r} />)}</div>}
    </>
  );
}

function ReviewCard({ r }: { r: Row }) {
  const qc = useQueryClient();
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState<'open' | 'yes' | 'no' | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const directors = r.people.filter((p) => p.role === 'director');
  const others = r.people.filter((p) => p.role !== 'director');
  async function open() {
    if (!r.slip?.path) return;
    setBusy('open'); setErr(null);
    const { data, error } = await supabase.storage.from('documents').createSignedUrl(r.slip.path, 300);
    setBusy(null);
    if (error || !data?.signedUrl) { setErr(cleanError(error) || 'The slip could not be opened.'); return; }
    window.open(data.signedUrl, '_blank', 'noopener');
  }
  async function decide(approve: boolean) {
    if (!approve && note.trim().length < 5) { setErr('Say why, so the business knows what to do next.'); return; }
    setBusy(approve ? 'yes' : 'no'); setErr(null);
    try { await rpc('review_identity', { p_org: r.org_id, p_approve: approve, p_note: note.trim() || null }); await qc.invalidateQueries({ queryKey: ['identity-reviews'] }); await qc.invalidateQueries({ queryKey: ['admin-overview'] }); }
    catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }
  const tone = r.status === 'review' ? 't-amber' : r.status === 'approved' ? 't-green' : 't-red';
  const handover = r.reason === 'handover' && !!r.handover;
  const confirmedBefore = ['verified', 'approved', 'not_required'].includes(r.handover?.status_before || '');
  // A slip waits, or a handover waits or was rejected (TaxStreem may decide it again).
  const decidable = r.status === 'review' || (handover && r.status === 'rejected');
  return (
    <div className="card card-pad stack" style={{ gap: 12 }}>
      <div className="row wrap" style={{ gap: 10, alignItems: 'flex-start' }}>
        <div style={{ flex: '1 1 260px', minWidth: 0 }}>
          <div style={{ fontWeight: 700, fontSize: 16 }}>{r.business}</div>
          <div className="faint" style={{ fontSize: 13 }}>{[r.legal_form?.replace(/_/g, ' '), r.rc_number && `RC ${r.rc_number}`, r.owner && `${r.owner.name}${r.owner.email ? ` · ${r.owner.email}` : ''}`].filter(Boolean).join(' · ')}</div>
        </div>
        {r.handover && <span className="chip t-blue">Handover</span>}
        <span className={'chip ' + tone}>{r.status === 'review' ? 'Waiting' : r.status === 'approved' ? 'Approved' : 'Rejected'}</span>
      </div>
      {handover && (
        <Alert kind="blue" icon="users">
          A firm handed this business over {when(r.handover!.at)} to someone other than the director who confirmed its wallets. Its identity before the handover:
          {' '}{BEFORE[r.handover!.status_before || ''] || 'unknown'}. {confirmedBefore ? 'Approving opens payments.' : 'Approving sends it to the ordinary NIN check, which the new owner then does.'}
          {' '}<Link to="/admin/mandates">See the flag on Mandates</Link>
        </Alert>
      )}
      <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
        <div>
          <div className="mini-label">On the CAC record</div>
          <div style={{ fontSize: 14, lineHeight: 1.6 }}>
            {directors.length ? directors.map((p) => <div key={p.name}>{p.name} <span className="faint">· director</span></div>) : <div className="faint">No directors listed</div>}
            {others.slice(0, 6).map((p) => <div key={p.name + p.role} className="faint">{p.name} · {p.role.replace(/_/g, ' ')}</div>)}
          </div>
        </div>
        <div>
          <div className="mini-label">The slip, as read</div>
          <div style={{ fontSize: 14, lineHeight: 1.6 }}>
            <div>{r.slip?.name || <span className="faint">No name read</span>}{r.slip?.last4 ? <span className="faint"> · NIN ending {r.slip.last4}</span> : null}</div>
            {r.slip?.is_nin_document === false && <div style={{ color: '#B91C1C' }}>Does not look like an NIN slip</div>}
            {(r.slip?.warnings || []).map((w) => <div key={w} className="faint">{w}</div>)}
            <div className="faint">{r.slip?.at ? `Added ${when(r.slip.at)}` : ''}{r.attempts ? ` · ${r.attempts} NIN ${r.attempts === 1 ? 'check' : 'checks'} before` : ''}</div>
          </div>
        </div>
      </div>
      {r.review && <div className="faint" style={{ fontSize: 13 }}>{r.review.approved ? 'Approved' : 'Rejected'} {when(r.review.at)}{r.review.note ? `: ${r.review.note}` : ''}</div>}
      {err && <Alert kind="red" icon="alert">{err}</Alert>}
      <div className="row wrap" style={{ gap: 8 }}>
        <button className="btn btn-secondary btn-sm" disabled={!r.slip?.path || busy !== null} onClick={open}>{busy === 'open' ? <Spinner small /> : <Icon name="external" size={14} />}Open the slip</button>
        {decidable && (
          <>
            <input className="input" style={{ flex: '1 1 220px', minWidth: 0, height: 34 }} placeholder="Note to the owner (needed to reject)" value={note} onChange={(e) => setNote(e.target.value)} maxLength={500} />
            <button className="btn btn-primary btn-sm" disabled={busy !== null} onClick={() => decide(true)}>{busy === 'yes' ? <Spinner small /> : <Icon name="check" size={14} color="#fff" />}Approve</button>
            <button className="btn btn-danger btn-sm" disabled={busy !== null} onClick={() => decide(false)}>{busy === 'no' ? <Spinner small /> : null}Reject</button>
          </>
        )}
      </div>
    </div>
  );
}
