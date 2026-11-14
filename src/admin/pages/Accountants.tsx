// Accountants' licence numbers (ICAN, ANAN, CITN) and FRC numbers waiting for TaxStreem to check them against the
// professional body's register and the FRC's. Verified licence numbers show to the accountant's clients and in the statement
// they accept when they change a return; a partner with an ICAN or ANAN number and an FRC number, both verified, signs audits.
import { useState, type ReactNode } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc } from '../../lib/supabase';
import { when } from '../../lib/format';
import { Icon } from '../../components/Icon';
import { Alert, Seg, Spinner } from '../../components/ui';
import { PageHead } from '../ui';

type Row = { id: string; name: string; email: string; role: string; practice: string; practice_id: string; firm_reg: string | null; licence_body: string; licence_no: string;
  licence_status: 'none' | 'pending' | 'verified' | 'rejected'; licence_note: string | null; verified_at: string | null; created_at: string; clients: number;
  frc_no: string | null; frc_status: 'none' | 'pending' | 'verified' | 'rejected'; frc_note: string | null; frc_verified_at: string | null };

const REGISTER: Record<string, string> = { ICAN: 'ICAN members directory', ANAN: 'ANAN register', CITN: 'CITN members list' };

export default function Accountants() {
  const [status, setStatus] = useState<'pending' | 'all'>('pending');
  const list = useQuery({ queryKey: ['admin-licences', status], queryFn: () => rpc<Row[]>('admin_licences', { p_status: status }) });
  return (
    <>
      <PageHead title="Accountants" sub="Licence and FRC numbers accountants gave in the accountant portal. Check each against the professional body's register or the FRC's, then verify it or say why not." />
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
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  async function decide(what: 'licence' | 'frc', ok: boolean) {
    if (!ok && note.trim().length < 5) { setErr('Say why, so the accountant can put it right.'); return; }
    setBusy(what + (ok ? '-yes' : '-no')); setErr(null);
    try {
      await rpc(what === 'frc' ? 'admin_frc_decide' : 'admin_licence_decide', { p_member: r.id, p_status: ok ? 'verified' : 'rejected', p_note: note.trim() || null });
      await qc.invalidateQueries({ queryKey: ['admin-licences'] }); setNote('');
    } catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }
  return (
    <div className="card card-pad stack" style={{ gap: 10 }} data-testid="licence-card">
      <div className="row wrap" style={{ gap: 10, alignItems: 'flex-start' }}>
        <div style={{ flex: '1 1 260px', minWidth: 0 }}>
          <div style={{ fontWeight: 700, fontSize: 16 }}>{r.name} <span className="faint" style={{ fontWeight: 400, fontSize: 14 }}>· {r.role} at {r.practice}</span></div>
          <div className="faint" style={{ fontSize: 13 }}>{[r.email, r.firm_reg && `firm ${r.firm_reg}`, `${r.clients} ${r.clients === 1 ? 'client' : 'clients'}`, `added ${when(r.created_at)}`].filter(Boolean).join(' · ')}</div>
        </div>
      </div>
      <input className="input" style={{ minWidth: 0, height: 34 }} placeholder="Note to the accountant (needed to reject)" value={note} onChange={(e) => setNote(e.target.value)} maxLength={300} />
      {err && <Alert kind="red" icon="alert">{err}</Alert>}
      {r.licence_no && (
        <Check label={<><b>{r.licence_body}</b> <span className="mono">{r.licence_no}</span> <span className="faint" style={{ fontSize: 12 }}>· check it in the {REGISTER[r.licence_body] || 'register'}</span></>}
          status={r.licence_status} note={r.licence_note} at={r.verified_at} busy={busy} what="licence" onDecide={decide} />
      )}
      {r.frc_no && (
        <Check label={<><b>FRC</b> <span className="mono">{r.frc_no}</span> <span className="faint" style={{ fontSize: 12 }}>· check it in the FRC's register of professionals</span></>}
          status={r.frc_status} note={r.frc_note} at={r.frc_verified_at} busy={busy} what="frc" onDecide={decide} />
      )}
    </div>
  );
}

const TONE: Record<string, [string, string]> = { pending: ['Waiting', 't-amber'], verified: ['Verified', 't-green'], rejected: ['Not confirmed', 't-red'], none: ['', 't-grey'] };

function Check({ label, status, note, at, busy, what, onDecide }: { label: ReactNode; status: string; note: string | null; at: string | null; busy: string | null;
  what: 'licence' | 'frc'; onDecide: (what: 'licence' | 'frc', ok: boolean) => void }) {
  const [t, c] = TONE[status] || TONE.none;
  return (
    <div className="stack" style={{ gap: 6, borderTop: '1px solid var(--row)', paddingTop: 10 }} data-testid={`check-${what}`}>
      <div className="row wrap" style={{ gap: 8, justifyContent: 'space-between' }}><span style={{ fontSize: 15 }}>{label}</span>{t && <span className={'chip ' + c}>{t}</span>}</div>
      {note && <div className="faint" style={{ fontSize: 13 }}>Note: {note}</div>}
      {at && <div className="faint" style={{ fontSize: 12 }}>Decided {when(at)}</div>}
      <div className="row wrap" style={{ gap: 8 }}>
        <button className="btn btn-primary btn-sm" disabled={busy !== null || status === 'verified'} onClick={() => onDecide(what, true)}>{busy === what + '-yes' ? <Spinner small /> : <Icon name="check" size={14} color="#fff" />}Verify</button>
        <button className="btn btn-danger btn-sm" disabled={busy !== null} onClick={() => onDecide(what, false)}>{busy === what + '-no' ? <Spinner small /> : null}Not confirmed</button>
      </div>
    </div>
  );
}
