// Accountants' licence numbers (ICAN, ANAN, CITN) waiting for TaxStreem to check them against the professional body's
// register. Verified numbers show to the accountant's clients and in the statement they accept when they change a return.
import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc } from '../../lib/supabase';
import { when } from '../../lib/format';
import { Icon } from '../../components/Icon';
import { Alert, Seg, Spinner } from '../../components/ui';
import { PageHead } from '../ui';

type Row = { id: string; name: string; email: string; role: string; practice: string; practice_id: string; firm_reg: string | null; licence_body: string; licence_no: string;
  licence_status: 'pending' | 'verified' | 'rejected'; licence_note: string | null; verified_at: string | null; created_at: string; clients: number };

const REGISTER: Record<string, string> = { ICAN: 'ICAN members directory', ANAN: 'ANAN register', CITN: 'CITN members list' };

export default function Accountants() {
  const [status, setStatus] = useState<'pending' | 'all'>('pending');
  const list = useQuery({ queryKey: ['admin-licences', status], queryFn: () => rpc<Row[]>('admin_licences', { p_status: status }) });
  return (
    <>
      <PageHead title="Accountants" sub="Licence numbers accountants gave in the accountant portal. Check each against the professional body's register, then verify it or say why not." />
      <Seg value={status} onChange={setStatus} options={[{ id: 'pending', label: 'Waiting' }, { id: 'all', label: 'All' }]} />
      {list.isLoading ? <div className="row" style={{ justifyContent: 'center', padding: 40 }}><Spinner /></div>
        : list.isError ? <Alert kind="red" icon="alert">{cleanError(list.error)}</Alert>
        : !list.data?.length ? <Alert kind="green" icon="check">{status === 'pending' ? 'Nothing waiting.' : 'No licence numbers yet.'}</Alert>
        : <div className="stack" style={{ gap: 12 }}>{list.data.map((r) => <LicenceCard key={r.id} r={r} />)}</div>}
    </>
  );
}

function LicenceCard({ r }: { r: Row }) {
  const qc = useQueryClient();
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState<'yes' | 'no' | null>(null);
  const [err, setErr] = useState<string | null>(null);
  async function decide(ok: boolean) {
    if (!ok && note.trim().length < 5) { setErr('Say why, so the accountant can put it right.'); return; }
    setBusy(ok ? 'yes' : 'no'); setErr(null);
    try { await rpc('admin_licence_decide', { p_member: r.id, p_status: ok ? 'verified' : 'rejected', p_note: note.trim() || null }); await qc.invalidateQueries({ queryKey: ['admin-licences'] }); }
    catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }
  const tone = r.licence_status === 'pending' ? 't-amber' : r.licence_status === 'verified' ? 't-green' : 't-red';
  return (
    <div className="card card-pad stack" style={{ gap: 10 }} data-testid="licence-card">
      <div className="row wrap" style={{ gap: 10, alignItems: 'flex-start' }}>
        <div style={{ flex: '1 1 260px', minWidth: 0 }}>
          <div style={{ fontWeight: 700, fontSize: 16 }}>{r.name} <span className="faint" style={{ fontWeight: 400, fontSize: 14 }}>· {r.role} at {r.practice}</span></div>
          <div className="faint" style={{ fontSize: 13 }}>{[r.email, r.firm_reg && `firm ${r.firm_reg}`, `${r.clients} ${r.clients === 1 ? 'client' : 'clients'}`, `added ${when(r.created_at)}`].filter(Boolean).join(' · ')}</div>
        </div>
        <span className={'chip ' + tone}>{r.licence_status === 'pending' ? 'Waiting' : r.licence_status === 'verified' ? 'Verified' : 'Not confirmed'}</span>
      </div>
      <div style={{ fontSize: 15 }}><b>{r.licence_body}</b> <span className="mono">{r.licence_no}</span> <span className="faint" style={{ fontSize: 12 }}>· check it in the {REGISTER[r.licence_body] || 'register'}</span></div>
      {r.licence_note && <div className="faint" style={{ fontSize: 13 }}>Note: {r.licence_note}</div>}
      {r.verified_at && <div className="faint" style={{ fontSize: 12 }}>Decided {when(r.verified_at)}</div>}
      {err && <Alert kind="red" icon="alert">{err}</Alert>}
      <div className="row wrap" style={{ gap: 8 }}>
        <input className="input" style={{ flex: '1 1 220px', minWidth: 0, height: 34 }} placeholder="Note to the accountant (needed to reject)" value={note} onChange={(e) => setNote(e.target.value)} maxLength={300} />
        <button className="btn btn-primary btn-sm" disabled={busy !== null || r.licence_status === 'verified'} onClick={() => decide(true)}>{busy === 'yes' ? <Spinner small /> : <Icon name="check" size={14} color="#fff" />}Verify</button>
        <button className="btn btn-danger btn-sm" disabled={busy !== null} onClick={() => decide(false)}>{busy === 'no' ? <Spinner small /> : null}Not confirmed</button>
      </div>
    </div>
  );
}
