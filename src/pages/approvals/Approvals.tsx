// Approvals: what waits before it goes into the books or leaves the wallet, and what was decided in the last 30 days.
// The owner and admins approve what waits for them (a credit note by someone else, an invoice past the discount limit or
// marked exempt by someone else, and, for a client who is involved, what the firm that keeps the books asks for). Under
// full mandate the director who confirmed the wallets approves what the firm asks for, from the link Counta emails them;
// the firm sees here what waits and can send the link again. Everyone else sees what they asked for.
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { useInventory, useSession, useToast } from '../../state/session';
import { cleanError, rpc } from '../../lib/supabase';
import { when } from '../../lib/format';
import { Alert, Empty, Field, Modal, ModalHead, SkeletonRows, Spinner } from '../../components/ui';
import { titleName, useApprovals, waitsFor, type Approval } from '../../lib/approvals';
import { ApprovalDetail } from './ApprovalDetail';

const openLink = (a: Approval) => a.sale_id ? `/sell/sales?open=${a.sale_id}` : a.batch_id ? `/payments?tab=bulk&batch=${a.batch_id}`
  : a.payout_id ? '/payments?tab=payouts' : a.recurring_id ? '/sell/recurring' : a.kind === 'refund' ? '/sell/customers' : null;

export default function Approvals() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const q = useApprovals(orgId);
  const [busy, setBusy] = useState<string | null>(null);
  const [rejecting, setRejecting] = useState<Approval | null>(null);
  const [note, setNote] = useState('');
  const d = q.data;
  const refresh = () => Promise.all(['approvals', 'attention', 'sale', 'sales', 'payments', 'recurring', 'customers'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
  async function decide(a: Approval, approve: boolean, why?: string) {
    setBusy(a.id);
    try {
      const r = await rpc<Approval>('approval_decide', { p_id: a.id, p_approve: approve, p_note: why || null });
      toast(r.status === 'failed' ? `Approved, but it did not go through: ${r.error}` : approve ? 'Approved and carried out' : 'Not approved. They have been told why.',
        r.status === 'failed' ? 'err' : undefined);
      setRejecting(null); setNote('');
      await refresh();
    } catch (e) { toast(cleanError(e), 'err'); }
    setBusy(null);
  }
  async function remind() {
    setBusy('remind');
    try {
      const r = await rpc<{ email: string | null; phone: string | null }>('approvals_remind', { p_org: orgId });
      toast(`Link sent to ${[r.email, r.phone].filter(Boolean).join(' and ') || 'the director'}`);
      await refresh();
    } catch (e) { toast(cleanError(e), 'err'); }
    setBusy(null);
  }
  if (!inv) return null;
  const items = d?.items || [];
  const waiting = items.filter((a) => a.status === 'pending');
  const done = items.filter((a) => a.status !== 'pending');
  const forDirector = waiting.filter((a) => a.approver === 'director');
  return (
    <div className="container stack" style={{ gap: 16 }}>
      <p className="muted" style={{ margin: 0, maxWidth: 760 }}>
        {d?.owner_or_admin
          ? `What waits for your approval before it goes into the books or leaves the wallet: credit notes raised by others, invoices with more than ${d.limit_pct}% off or marked exempt from VAT by others, and what the firm that keeps your books asks for.`
          : d?.firm ? 'What the firm asked for here waits for the client: the director who confirmed the wallets under full mandate, otherwise the owner or an admin.'
          : 'What you asked for that waits for the owner or an admin, and what they decided.'}
      </p>
      {d?.firm && (d.director ? (
        <div className="card card-pad row wrap" style={{ justifyContent: 'space-between', gap: 12 }} data-testid="approvals-director">
          <span className="stack" style={{ gap: 2, minWidth: 0 }}>
            <b>{titleName(d.director.name)} approves for the client</b>
            <span className="faint" style={{ fontSize: 13 }}>Links and codes go to {[d.director.email, d.director.phone].filter(Boolean).join(' and ')}.
              {d.director.last_link ? ` The last link went ${when(d.director.last_link)}.` : ''}</span>
          </span>
          {forDirector.length > 0 && <button className="btn btn-secondary btn-sm" disabled={busy === 'remind'} onClick={remind} data-testid="approvals-remind">
            {busy === 'remind' ? <Spinner small /> : null}Send the link again</button>}
        </div>
      ) : (
        <Alert kind="amber" icon="alert">Counta cannot reach a director of this client for approvals yet. Ask a director to confirm the wallets by code, on the client's Full mandate tab in the accountant portal.</Alert>
      ))}
      <div className="card" style={{ overflow: 'hidden' }}>
        <div className="card-hd"><b>Waiting{waiting.length ? ` (${waiting.length})` : ''}</b></div>
        {q.isLoading ? <SkeletonRows n={3} /> : q.isError ? <div style={{ padding: 16 }}><Alert kind="red" icon="alert">{cleanError(q.error)}</Alert></div>
          : !waiting.length ? <div style={{ padding: 20 }}><Empty>Nothing waits for approval.</Empty></div> : waiting.map((a) => (
            <div key={a.id} className="tr" style={{ display: 'block', padding: '14px 20px' }}>
              <ApprovalDetail a={a} />
              <div className="row wrap" style={{ gap: 8, marginTop: 10 }}>
                {a.can_decide ? <>
                  <button className="btn btn-primary btn-sm" disabled={!!busy} onClick={() => decide(a, true)} data-testid="approval-approve">{busy === a.id ? <Spinner small /> : null}Approve</button>
                  <button className="btn btn-ghost btn-sm" disabled={!!busy} onClick={() => { setNote(''); setRejecting(a); }} data-testid="approval-reject">Reject</button>
                </> : <span className="faint" style={{ fontSize: 13 }}>Waits for {waitsFor(a)}.</span>}
                {openLink(a) && <Link className="link" style={{ fontSize: 13 }} to={openLink(a)!}>Open it</Link>}
              </div>
            </div>
          ))}
      </div>
      {done.length > 0 && (
        <div className="card" style={{ overflow: 'hidden' }}>
          <div className="card-hd"><b>Decided in the last 30 days</b></div>
          {done.map((a) => (
            <div key={a.id} className="tr" style={{ display: 'block', padding: '12px 20px' }}><ApprovalDetail a={a} open={false} /></div>
          ))}
        </div>
      )}
      {rejecting && (
        <Modal onClose={() => setRejecting(null)} width={440}>
          <ModalHead title="Reject" sub="Say why, so the person who asked knows what to change." onClose={() => setRejecting(null)} />
          <div className="modal-body"><Field label="Why"><input className="input" autoFocus value={note} maxLength={500} onChange={(e) => setNote(e.target.value)} data-testid="approval-note" /></Field></div>
          <div className="modal-ft"><button className="btn btn-danger" disabled={!!busy || note.trim().length < 3} onClick={() => decide(rejecting, false, note.trim())} data-testid="approval-reject-go">Reject</button></div>
        </Modal>
      )}
    </div>
  );
}
