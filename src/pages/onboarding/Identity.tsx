// The director's NIN check: typed here or said to Martina. When the NIN does not match a director on the CAC record, an
// NIN slip is read instead, and TaxStreem reviews one that still does not match. Until then the books work as normal and
// only payments (the wallet, payment links, payouts) wait.
import { useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { Link } from 'react-router-dom';
import { useInventory } from '../../state/session';
import { edge, edgeOk } from '../../lib/api';
import { rpc, supabase } from '../../lib/supabase';
import { Icon } from '../../components/Icon';
import { Alert, Spinner } from '../../components/ui';

export type Identity = {
  status: 'not_required' | 'pending' | 'verified' | 'review' | 'approved' | 'rejected'; payments_open: boolean; can_check: boolean;
  method: string | null; matched: string | null; matched_role: string | null; last4: string | null; at: string | null; attempts: number; registered: boolean;
  people: { name: string; role: string }[];
  slip: { path: string; file_name: string; at: string; read: boolean; name?: string; last4?: string; is_nin_document?: boolean; warnings?: string[] } | null;
  review: { approved: boolean; note: string | null; at: string } | null;
};

export function useIdentity(orgId: string | null | undefined) {
  return useQuery({ queryKey: ['identity', orgId], enabled: !!orgId, queryFn: () => rpc<Identity>('identity_state', { p_org: orgId }) });
}

export async function checkNin(orgId: string, nin: string, conversationId?: string | null) {
  return edgeOk<{ result: { verified: boolean; matched?: string; reason?: string; people?: string[]; already?: boolean }; identity: Identity }>('mono',
    { action: 'nin_check', org_id: orgId, nin, ...(conversationId ? { conversation_id: conversationId } : {}) });
}

export async function uploadNinSlip(orgId: string, file: File) {
  if (file.size > 10 * 1024 * 1024) throw new Error('That file is larger than 10 MB. Take a photo of the slip instead.');
  if (!/^(application\/pdf|image\/(jpeg|png|webp))$/.test(file.type)) throw new Error('Add the slip as a PDF or a photo (JPG or PNG).');
  const ext = file.type === 'application/pdf' ? 'pdf' : file.type.split('/')[1].replace('jpeg', 'jpg');
  const path = `${orgId}/kyc/nin-slip-${Date.now()}.${ext}`;
  const { error } = await supabase.storage.from('documents').upload(path, file, { contentType: file.type, upsert: false });
  if (error) throw new Error(error.message);
  await rpc('identity_slip', { p_org: orgId, p_path: path, p_file_name: file.name.slice(0, 120) });
  const r = await edge<{ identity: Identity }>('ai', { action: 'read_nin_slip', org_id: orgId });
  if (!r.ok) throw new Error(r.error || 'The slip could not be read just now. Try again.');
  return r.identity;
}

const group = (d: string) => d.replace(/\D/g, '').slice(0, 11).replace(/^(\d{3})(\d{0,4})(\d{0,4}).*$/, (_m, a, b, c) => [a, b, c].filter(Boolean).join(' '));
const listNames = (names: string[]) => names.length <= 1 ? names.join('') : `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}`;

export function IdentityPanel({ orgId, onDone, onSkip, live, askOpen }: { orgId: string; onDone?: () => void; onSkip?: () => void; live?: boolean; askOpen?: number }) {
  const id = useIdentity(orgId);
  const qc = useQueryClient();
  const [nin, setNin] = useState('');
  const [busy, setBusy] = useState<'nin' | 'slip' | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [miss, setMiss] = useState<string | null>(null);
  const file = useRef<HTMLInputElement>(null);
  const s = id.data;
  if (id.isLoading || !s) return <div className="row" style={{ justifyContent: 'center', padding: 30 }}><Spinner /></div>;
  const refresh = () => Promise.all(['identity', 'inv', 'guide'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
  const directors = s.people.filter((p) => p.role === 'director').map((p) => p.name);
  const names = directors.length ? directors : s.people.map((p) => p.name);
  const ok = s.status === 'verified' || s.status === 'approved' || s.status === 'not_required';

  async function check() {
    setErr(null); setMiss(null);
    const d = nin.replace(/\D/g, '');
    if (d.length !== 11) { setErr('An NIN has 11 digits.'); return; }
    setBusy('nin');
    try {
      const r = await checkNin(orgId, d);
      setNin('');
      if (!r.result.verified) setMiss(r.result.reason === 'not_account_holder' ? 'The name on that NIN is not the name on your Counta account.'
        : r.result.reason === 'no_directors_on_record' ? 'CAC has no directors on record for the business, so the NIN cannot be matched.'
        : `The name on that NIN does not match ${names.length ? listNames(names) : 'the directors CAC lists'}.`);
      await refresh();
    } catch (e) { setErr((e as Error).message); }
    setBusy(null);
  }
  async function slip(f: File | undefined) {
    if (!f) return;
    setErr(null); setBusy('slip');
    try { await uploadNinSlip(orgId, f); await refresh(); } catch (e) { setErr((e as Error).message); }
    setBusy(null);
    if (file.current) file.current.value = '';
  }

  if (ok) {
    return (
      <div className="stack" style={{ gap: 12 }}>
        <Alert kind="green" icon="check">
          {s.status === 'not_required' ? 'Nothing to check for this business: payments are open.'
            : s.status === 'approved' ? 'TaxStreem confirmed the director\'s identity. Payments are open.'
            : `Confirmed: ${s.matched || 'a director'}${s.last4 ? `, NIN ending ${s.last4}` : ''}${s.method === 'slip' ? ', from the NIN slip' : ''}. Payments are open.`}
        </Alert>
        {onDone && <div><button className="btn btn-primary" onClick={onDone}>Continue<Icon name="arrow" size={16} color="#fff" /></button></div>}
      </div>
    );
  }
  if (s.status === 'review') {
    return (
      <div className="stack" style={{ gap: 12 }}>
        <Alert kind="blue" icon="clock">TaxStreem is checking the NIN slip{s.slip?.name ? ` (${s.slip.name})` : ''}. It usually takes a working day. Your books work meanwhile; payments open once it is approved.</Alert>
        {onDone && <div><button className="btn btn-primary" onClick={onDone}>Carry on<Icon name="arrow" size={16} color="#fff" /></button></div>}
      </div>
    );
  }
  if (!s.can_check) {
    return <Alert kind="amber" icon="lock">Payments open once the owner, as a director, confirms their NIN. Ask them to do it in Settings, Business identity.</Alert>;
  }
  return (
    <div className="stack" style={{ gap: 14 }}>
      {s.status === 'rejected' && s.review?.note && <Alert kind="red" icon="alert">TaxStreem could not confirm the slip: {s.review.note}</Alert>}
      {names.length > 0 && (
        <div className="ink3" style={{ fontSize: 14, lineHeight: 1.5 }}>
          {s.registered ? (directors.length ? `CAC lists ${listNames(directors)} as ${directors.length === 1 ? 'the director' : 'directors'}.` : `CAC lists ${listNames(names)}.`)
            : 'The NIN must be your own, as the business is not on CAC.'}
        </div>
      )}
      <form className="row wrap" style={{ gap: 8, alignItems: 'flex-end' }} onSubmit={(e) => { e.preventDefault(); void check(); }}>
        <label style={{ flex: '1 1 220px', minWidth: 0 }}>
          <span className="label" style={{ display: 'block', marginBottom: 6 }}>Your NIN</span>
          <input className="input mono" inputMode="numeric" autoComplete="off" aria-label="Your 11-digit NIN" placeholder="123 4567 8901" value={group(nin)}
            onChange={(e) => setNin(e.target.value.replace(/\D/g, '').slice(0, 11))} style={{ fontSize: 18, letterSpacing: '.08em' }} />
        </label>
        <button className="btn btn-primary" disabled={busy !== null || nin.replace(/\D/g, '').length !== 11}>{busy === 'nin' ? <Spinner small /> : <Icon name="shield" size={16} color="#fff" />}Check my NIN</button>
      </form>
      <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }}>
        Counta asks NIMC for the name on the NIN and compares it with the directors on the CAC record. Only the result and the last four digits are kept.
        {live ? ' You can also read it out to Martina.' : ''}
      </div>
      {miss && <Alert kind="amber" icon="alert">{miss} Add your NIN slip instead, and TaxStreem will check it if it still does not match.</Alert>}
      {err && <Alert kind="red" icon="alert">{err}</Alert>}
      <div className="row wrap" style={{ gap: 8 }}>
        <input ref={file} type="file" accept="image/*,application/pdf" hidden onChange={(e) => slip(e.target.files?.[0])} />
        <button className={'btn ' + (miss || askOpen ? 'btn-primary' : 'btn-secondary')} disabled={busy !== null} onClick={() => file.current?.click()}>
          {busy === 'slip' ? <><Spinner small />Reading the slip…</> : <><Icon name="upload" size={16} color={miss || askOpen ? '#fff' : undefined} />Add my NIN slip</>}
        </button>
        {onSkip && <button className="btn btn-ghost" onClick={onSkip}>I'm not a director · skip for now</button>}
      </div>
      {onSkip && <div className="faint" style={{ fontSize: 12 }}>Skipping keeps payments locked until a director does the check in Settings. Everything else works.</div>}
    </div>
  );
}

// Shown on Home and Payments while the director's identity is not confirmed: the wallet, payment links and payouts wait.
export function PaymentsLock() {
  const { data: inv } = useInventory();
  if (!inv || inv.org.payments_open !== false) return null;
  const owner = inv.me.role === 'owner';
  const st = inv.org.identity_status;
  const text = st === 'review' ? 'TaxStreem is checking the NIN slip. The wallet, payment links and payouts open once it is approved; everything else works.'
    : st === 'rejected' ? `TaxStreem could not confirm the NIN slip, so the wallet, payment links and payouts stay locked. ${owner ? 'Add a clearer slip or check your NIN again.' : 'The owner can add a clearer slip in Settings.'}`
    : owner ? 'The wallet, payment links and payouts open once a director confirms their NIN. It takes a minute.'
    : 'The wallet, payment links and payouts open once the owner, as a director, confirms their NIN in Settings.';
  return (
    <div className="alert alert-amber row wrap" role="status" style={{ gap: 10, alignItems: 'center' }}>
      <Icon name="lock" size={16} color="#C2410C" />
      <span style={{ flex: '1 1 240px', minWidth: 0, lineHeight: 1.5 }}>{text}</span>
      {owner && st !== 'review' && <Link className="btn btn-secondary btn-sm" to="/settings#identity">{st === 'rejected' ? 'Open identity' : 'Confirm my NIN'}</Link>}
    </div>
  );
}
