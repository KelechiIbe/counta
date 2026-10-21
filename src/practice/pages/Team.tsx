// The practice's people: partners and managers see every client and run the practice; staff work on the clients they are
// assigned. Each person's professional licence number shows with TaxStreem's check of it.
import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc } from '../../lib/supabase';
import { when } from '../../lib/format';
import { useToast } from '../../state/session';
import { Icon } from '../../components/Icon';
import { Alert, Field, Modal, ModalHead, Spinner } from '../../components/ui';
import { Card, PageHead } from '../../admin/ui';
import { type Member, ROLE_WORD, sendInvite, usePracticeHome } from '../api';

const LICENCE_CHIP: Record<Member['licence_status'], [string, string]> = {
  none: ['No licence number', 't-grey'], pending: ['Waiting for TaxStreem', 't-amber'], verified: ['Verified', 't-green'], rejected: ['Not confirmed', 't-red'],
};

export default function TeamPage({ pid }: { pid: string }) {
  const h = usePracticeHome(pid).data!;
  const qc = useQueryClient();
  const toast = useToast();
  const [adding, setAdding] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const lead = h.me.role !== 'staff';
  async function update(m: Member, p: Record<string, string>) {
    setBusy(m.id);
    try { await rpc('practice_update_member', { p_member: m.id, p }); await qc.invalidateQueries({ queryKey: ['practice-home', pid] }); toast('Saved'); }
    catch (e) { toast(cleanError(e), 'err'); }
    setBusy(null);
  }
  async function resend(m: Member) {
    setBusy(m.id);
    const r = await sendInvite('member', m.id);
    setBusy(null);
    if (r.ok) { toast(`Sent to ${r.sent_to}`); await qc.invalidateQueries({ queryKey: ['practice-home', pid] }); } else toast(r.error || 'Not sent.', 'err');
  }
  return (
    <>
      <PageHead title="Team" sub="Partners and managers see every client. Staff see the clients you assign them, and get a place in those businesses only." right={lead && (
        <button className="btn btn-primary btn-sm" onClick={() => setAdding(true)}><Icon name="plus" size={14} color="#fff" />Add a person</button>)} />
      <Card pad={false}>
        {h.members.map((m) => {
          const [lt, lc] = LICENCE_CHIP[m.licence_status];
          const me = m.id === h.me.id;
          return (
            <div key={m.id} className="tr rsp" style={{ gridTemplateColumns: 'minmax(200px,1fr) minmax(160px,auto) auto' }} data-testid="practice-member">
              <span className="m-main" style={{ minWidth: 0 }}>
                <b>{m.display_name}</b>{me && <span className="faint"> (you)</span>}
                <span className="faint" style={{ display: 'block', fontSize: 12 }}>{m.email || ''}{m.status === 'invited' ? ` · invited${m.sent_at ? `, sent ${when(m.sent_at)}` : ', not sent yet'}` : m.status === 'disabled' ? ' · switched off' : ` · ${m.clients} assigned`}</span>
              </span>
              <span className="row wrap" style={{ gap: 4 }}>
                {m.licence_body && <span className="faint" style={{ fontSize: 12 }}>{m.licence_body} {m.licence_no}</span>}
                <span className={'chip ' + lc}>{lt}</span>
              </span>
              <span className="row" style={{ gap: 6, justifyContent: 'flex-end' }}>
                {lead && !me && m.status !== 'disabled' && (
                  <select className="input input-sm" style={{ width: 120 }} value={m.role} disabled={busy !== null || (m.role === 'partner' && h.me.role !== 'partner')}
                    onChange={(e) => update(m, { role: e.target.value })} aria-label={`Role of ${m.display_name}`}>
                    {(['partner', 'manager', 'staff'] as const).map((r) => <option key={r} value={r} disabled={r === 'partner' && h.me.role !== 'partner'}>{ROLE_WORD[r]}</option>)}
                  </select>
                )}
                {(!lead || me || m.status === 'disabled') && <span className="chip t-grey">{ROLE_WORD[m.role]}</span>}
                {lead && m.status === 'invited' && <button className="btn btn-secondary btn-sm" disabled={busy !== null} onClick={() => resend(m)}>{busy === m.id ? <Spinner small /> : <Icon name="send" size={14} />}Send</button>}
                {lead && !me && m.status !== 'disabled' && <button className="btn btn-ghost btn-sm" disabled={busy !== null} onClick={() => update(m, { status: 'disabled' })}>Switch off</button>}
                {lead && !me && m.status === 'disabled' && m.joined && <button className="btn btn-ghost btn-sm" disabled={busy !== null} onClick={() => update(m, { status: 'active' })}>Switch on</button>}
              </span>
            </div>
          );
        })}
      </Card>
      {adding && <AddPerson pid={pid} partner={h.me.role === 'partner'} onClose={() => setAdding(false)} />}
    </>
  );
}

function AddPerson({ pid, partner, onClose }: { pid: string; partner: boolean; onClose: () => void }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [f, setF] = useState({ name: '', email: '', role: 'staff' });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function add() {
    setBusy(true); setErr(null);
    try {
      const id = await rpc<string>('practice_invite_member', { p_practice: pid, p: f });
      const r = await sendInvite('member', id);
      await qc.invalidateQueries({ queryKey: ['practice-home', pid] });
      if (r.ok) toast(`Invitation sent to ${r.sent_to}`); else toast(`Added, but the email did not go: ${r.error}`, 'err');
      onClose();
    } catch (e) { setErr(cleanError(e)); }
    setBusy(false);
  }
  return (
    <Modal onClose={onClose} width={480}>
      <ModalHead title="Add a person" sub="They get an email with a link to join the practice." onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 12 }}>
        <Field label="Name" req><input className="input" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} maxLength={80} autoFocus /></Field>
        <Field label="Email" req><input className="input" type="email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} /></Field>
        <Field label="Role">
          <select className="input" value={f.role} onChange={(e) => setF({ ...f, role: e.target.value })}>
            {partner && <option value="partner">Partner: runs the practice, every client</option>}
            <option value="manager">Manager: every client, can invite and assign</option>
            <option value="staff">Staff: the clients you assign</option>
          </select>
        </Field>
        {err && <Alert kind="red" icon="alert">{err}</Alert>}
      </div>
      <div className="modal-ft">
        <button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" disabled={busy || f.name.trim().length < 2 || !/\S+@\S+\.\S+/.test(f.email)} onClick={add}>{busy ? <Spinner small /> : <Icon name="send" size={14} color="#fff" />}Add and send</button>
      </div>
    </Modal>
  );
}
