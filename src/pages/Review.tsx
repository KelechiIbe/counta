// TaxStreem's reviewers: NIN slips whose name did not match a director on the CAC record. Approving opens the business's
// payments; rejecting tells the owner why. Only accounts listed as platform reviewers can open this page or the slips.
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc, supabase } from '../lib/supabase';
import { when } from '../lib/format';
import { Icon } from '../components/Icon';
import { Alert, Spinner } from '../components/ui';

type Row = {
  org_id: string; business: string; rc_number: string | null; legal_form: string | null; status: 'review' | 'approved' | 'rejected'; attempts: number;
  people: { name: string; role: string }[];
  slip: { path: string; file_name?: string; at?: string; read_at?: string; name?: string; last4?: string; is_nin_document?: boolean; warnings?: string[] } | null;
  review: { approved: boolean; note: string | null; at: string } | null;
  owner: { name: string; email: string | null } | null;
};

export function useAmReviewer(enabled = true) {
  return useQuery({ queryKey: ['am-reviewer'], enabled, staleTime: 10 * 60_000, queryFn: () => rpc<boolean>('am_reviewer').catch(() => false) });
}

export default function Review() {
  const me = useAmReviewer();
  const list = useQuery({ queryKey: ['identity-reviews'], enabled: me.data === true, queryFn: () => rpc<Row[]>('identity_reviews') });
  return (
    <div className="container" style={{ maxWidth: 880, padding: '24px 16px 60px' }}>
      <div className="row wrap" style={{ gap: 12, marginBottom: 18 }}>
        <Link to="/" className="btn btn-ghost btn-sm"><Icon name="house" size={14} />Counta</Link>
        <h1 style={{ fontFamily: 'var(--font-brand)', fontSize: 26, fontWeight: 600, margin: 0 }}>Identity reviews</h1>
      </div>
      {me.isLoading ? <div className="row" style={{ justifyContent: 'center', padding: 40 }}><Spinner /></div>
        : me.data !== true ? <Alert kind="grey" icon="lock">This page is for TaxStreem's reviewers.</Alert>
        : list.isLoading ? <div className="row" style={{ justifyContent: 'center', padding: 40 }}><Spinner /></div>
        : list.isError ? <Alert kind="red" icon="alert">{cleanError(list.error)}</Alert>
        : !list.data?.length ? <Alert kind="green" icon="check">Nothing waiting. Slips that need a person to look at them appear here.</Alert>
        : <div className="stack" style={{ gap: 14 }}>{list.data.map((r) => <ReviewCard key={r.org_id} r={r} />)}</div>}
    </div>
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
    try { await rpc('review_identity', { p_org: r.org_id, p_approve: approve, p_note: note.trim() || null }); await qc.invalidateQueries({ queryKey: ['identity-reviews'] }); }
    catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }
  const tone = r.status === 'review' ? 't-amber' : r.status === 'approved' ? 't-green' : 't-red';
  return (
    <div className="card card-pad stack" style={{ gap: 12 }}>
      <div className="row wrap" style={{ gap: 10, alignItems: 'flex-start' }}>
        <div style={{ flex: '1 1 260px', minWidth: 0 }}>
          <div style={{ fontWeight: 700, fontSize: 16 }}>{r.business}</div>
          <div className="faint" style={{ fontSize: 13 }}>{[r.legal_form?.replace(/_/g, ' '), r.rc_number && `RC ${r.rc_number}`, r.owner && `${r.owner.name}${r.owner.email ? ` · ${r.owner.email}` : ''}`].filter(Boolean).join(' · ')}</div>
        </div>
        <span className={'chip ' + tone}>{r.status === 'review' ? 'Waiting' : r.status === 'approved' ? 'Approved' : 'Rejected'}</span>
      </div>
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
        {r.status === 'review' && (
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
