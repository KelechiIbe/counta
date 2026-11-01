import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { rpc } from '../../lib/supabase';
import { edge } from '../../lib/api';
import { fmtDay, num, when } from '../../lib/format';
import { Icon } from '../../components/Icon';
import { Alert, SkeletonRows, Spinner } from '../../components/ui';
import { tidyError } from '../api';
import { PageHead } from '../ui';

type Person = {
  id: string; email: string | null; name: string | null; created_at: string; last_sign_in: string | null; confirmed: boolean; staff: 'admin' | 'reviewer' | null;
  authenticator: boolean; businesses: { org_id: string; name: string; role: string; status: string; sample: boolean }[];
};

export default function People() {
  const [q, setQ] = useState('');
  const [search, setSearch] = useState('');
  const [limit, setLimit] = useState(50);
  const list = useQuery({ queryKey: ['admin-people', search, limit], queryFn: () => rpc<{ total: number; rows: Person[] }>('admin_people', { p_search: search || null, p_limit: limit, p_offset: 0 }) });
  return (
    <>
      <PageHead title="People" sub="Everyone with a Counta account, the businesses they belong to and when they last signed in." />
      <form className="row wrap" style={{ gap: 8 }} onSubmit={(e) => { e.preventDefault(); setSearch(q.trim()); }}>
        <input className="input" style={{ flex: '1 1 260px', minWidth: 0 }} placeholder="Search by email, name or business" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search people" />
        <button className="btn btn-secondary" type="submit"><Icon name="search" size={14} />Search</button>
      </form>
      <div className="card" style={{ overflow: 'hidden' }}>
        {list.isLoading ? <div className="card-pad"><SkeletonRows n={6} /></div> : list.isError ? <div className="card-pad"><Alert kind="red" icon="alert">{tidyError(list.error)}</Alert></div>
          : !list.data?.rows.length ? <div className="card-pad muted">Nobody matches.</div> : (
          <div className="tbl">
            <div className="tr head rsp th" style={{ gridTemplateColumns: 'minmax(0,1.6fr) minmax(0,2fr) 130px 150px' }}>
              <span>Person</span><span>Businesses</span><span>Joined</span><span>Last signed in</span>
            </div>
            {list.data.rows.map((p) => (
              <div key={p.id} className="tr rsp" style={{ gridTemplateColumns: 'minmax(0,1.6fr) minmax(0,2fr) 130px 150px' }}>
                <span className="m-main" style={{ minWidth: 0 }}>
                  <b className="ellipsis" style={{ display: 'block' }}>{p.name || p.email}</b>
                  <span className="faint ellipsis" style={{ fontSize: 12, display: 'block' }}>{p.name ? p.email : ''}{!p.confirmed ? ' · email not confirmed' : ''}</span>
                  {p.staff && <span className="chip t-purple" style={{ marginTop: 4 }}>{p.staff}{p.authenticator ? ' · authenticator set' : ' · no authenticator yet'}</span>}
                  {!p.staff && p.authenticator && <span className="chip t-grey" style={{ marginTop: 4 }}>two-step sign-in on</span>}
                  <ResetAuthenticator person={p} />
                </span>
                <span style={{ minWidth: 0 }}>
                  {p.businesses.length ? p.businesses.map((b) => (
                    <Link key={b.org_id} to={`/admin/businesses/${b.org_id}`} className="chip t-grey" style={{ marginRight: 4, marginBottom: 4, textDecoration: 'none' }}>
                      {b.name}{b.sample ? ' (sample)' : ''} · {b.role}{b.status !== 'active' ? ` · ${b.status}` : ''}
                    </Link>
                  )) : <span className="faint">No business yet</span>}
                </span>
                <span className="faint" data-label="Joined">{fmtDay(p.created_at)}</span>
                <span className="faint" data-label="Last signed in">{p.last_sign_in ? when(p.last_sign_in) : 'Never'}</span>
              </div>
            ))}
          </div>
        )}
      </div>
      {list.data && list.data.total > list.data.rows.length && (
        <div className="row" style={{ gap: 10 }}>
          <span className="faint" style={{ fontSize: 13 }}>Showing {num(list.data.rows.length)} of {num(list.data.total)}</span>
          <button className="btn btn-secondary btn-sm" onClick={() => setLimit(limit + 50)}>Show more</button>
        </div>
      )}
    </>
  );
}

// For someone who lost the phone with their authenticator app: removes it, and they set up a new one at their next sign-in.
function ResetAuthenticator({ person }: { person: Person }) {
  const qc = useQueryClient();
  const [sure, setSure] = useState(false);
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<{ ok: boolean; text: string } | null>(null);
  async function go() {
    if (!sure) { setSure(true); return; }
    setBusy(true); setNote(null);
    const r = await edge<{ removed?: number }>('admin', { action: 'mfa_reset', user_id: person.id });
    setBusy(false); setSure(false);
    setNote(r.ok === false ? { ok: false, text: r.error || 'It could not be removed.' } : { ok: true, text: 'Removed. They set up a new one at their next sign-in.' });
    if (r.ok !== false) qc.invalidateQueries({ queryKey: ['admin-people'] });
  }
  // Kept on the row after the list reloads without the authenticator, so the note that it was removed stays in view.
  if (!person.authenticator && !note) return null;
  return (
    <span className="row wrap" style={{ gap: 6, marginTop: 6, alignItems: 'center' }} data-testid="mfa-reset">
      {person.authenticator && <button className="btn btn-ghost btn-sm" disabled={busy} onClick={go}>{busy ? <Spinner small /> : <Icon name="lock" size={13} />}{sure ? `Tap again to remove ${person.email}'s authenticator` : 'Reset authenticator'}</button>}
      {note && <span className={note.ok ? 'faint' : 't-red'} style={{ fontSize: 12 }}>{note.text}</span>}
    </span>
  );
}
