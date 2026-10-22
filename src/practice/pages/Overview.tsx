// Every client on one screen: what needs doing in its books and tax, sorted so the most urgent comes first. Invitations the
// practice sent, and businesses that asked for this accountant, sit above.
import { useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc } from '../../lib/supabase';
import { fmtDay, when } from '../../lib/format';
import { useToast } from '../../state/session';
import { Icon } from '../../components/Icon';
import { Alert, Field, Modal, ModalHead, Spinner } from '../../components/ui';
import { PageHead, Tile, grid } from '../../admin/ui';
import { type ClientRow, type Home, sendInvite, SERVICES, serviceLabel, serviceList, usePracticeHome } from '../api';
import { RequestsNote } from './Earnings';

// How urgent a client is: overdue tax first, then what is due soon, then the books.
function weight(c: ClientRow) {
  const h = c.health;
  if (!h) return -1;
  return h.overdue * 1000 + h.due_soon * 100 + h.files_review * 50 + c.answered * 40 + Math.min(h.proposals, 50) + Math.min(h.bank_lines, 50) / 2 + h.invoices_overdue / 4;
}
export function attention(c: ClientRow): { text: string; tone: string }[] {
  const h = c.health;
  if (!h) return [];
  const out: { text: string; tone: string }[] = [];
  if (h.overdue) out.push({ text: `${h.overdue} tax ${h.overdue === 1 ? 'deadline' : 'deadlines'} passed`, tone: 't-red' });
  if (h.due_soon) out.push({ text: `${h.due_soon} due in 14 days`, tone: 't-amber' });
  if (h.files_review) out.push({ text: `${h.files_review} changed ${h.files_review === 1 ? 'file' : 'files'} to book`, tone: 't-amber' });
  if (c.answered) out.push({ text: `${c.answered} ${c.answered === 1 ? 'answer' : 'answers'} from the client`, tone: 't-blue' });
  if (h.proposals) out.push({ text: `${h.proposals} questions in the books`, tone: 't-grey' });
  if (h.bank_lines) out.push({ text: `${h.bank_lines} bank lines to match`, tone: 't-grey' });
  if (h.plan.status === 'past_due') out.push({ text: 'Counta plan unpaid', tone: 't-red' });
  return out;
}

export default function Overview({ pid }: { pid: string }) {
  const home = usePracticeHome(pid);
  const h = home.data!;
  const [inviting, setInviting] = useState(false);
  const [q, setQ] = useState('');
  const lead = h.me.role !== 'staff';
  const active = useMemo(() => h.clients.filter((c) => c.status === 'active').sort((a, b) => weight(b) - weight(a)), [h.clients]);
  const shown = active.filter((c) => !q || (c.business_name || '').toLowerCase().includes(q.toLowerCase()));
  const invited = h.clients.filter((c) => c.status === 'invited');
  const totals = active.reduce((a, c) => ({ overdue: a.overdue + (c.health?.overdue || 0), soon: a.soon + (c.health?.due_soon || 0),
    files: a.files + (c.health?.files_review || 0), answered: a.answered + c.answered }), { overdue: 0, soon: 0, files: 0, answered: 0 });

  return (
    <>
      <PageHead title="Clients" sub={`${h.practice.name}: ${active.length} ${active.length === 1 ? 'business' : 'businesses'} you look after${h.me.role === 'staff' ? ' (the ones assigned to you)' : ''}.`}
        right={lead && <button className="btn btn-primary btn-sm" onClick={() => setInviting(true)}><Icon name="plus" size={14} color="#fff" />Invite a business</button>} />
      {lead && <RequestsNote pid={pid} />}
      {h.me.licence_status === 'rejected' && <Alert kind="red" icon="alert">TaxStreem could not confirm your licence number{h.me.licence_note ? `: ${h.me.licence_note}` : ''}. Correct it under Practice.</Alert>}
      <div style={grid(170)}>
        <Tile label="Tax deadlines passed" value={totals.overdue} tone={totals.overdue ? '#B91C1C' : undefined} sub="across your clients" />
        <Tile label="Due in 14 days" value={totals.soon} tone={totals.soon ? '#B45309' : undefined} sub="returns and payments" />
        <Tile label="Changed files to book" value={totals.files} sub="uploaded, not yet in use" />
        <Tile label="Answers from clients" value={totals.answered} sub="to your requests" />
      </div>
      {h.business_invitations.length > 0 && <BusinessInvitations pid={pid} h={h} />}
      {invited.length > 0 && <Invited pid={pid} rows={invited} />}
      <section className="card" style={{ overflow: 'hidden' }}>
        <div className="card-hd" style={{ gap: 10, flexWrap: 'wrap' }}>
          <b>Your clients</b>
          <input className="input input-sm" style={{ width: 220 }} placeholder="Find a client" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Find a client" />
        </div>
        {!active.length ? (
          <div className="card-pad faint" style={{ fontSize: 14, lineHeight: 1.6 }}>
            {lead ? 'No clients yet. Invite a business by its owner\'s email, or ask your clients to invite you from Counta, under Settings, Your accountant.' : 'No clients are assigned to you yet.'}
          </div>
        ) : shown.map((c) => (
          <Link key={c.id} to={`/practice/${pid}/clients/${c.id}`} className="tr click rsp" style={{ gridTemplateColumns: 'minmax(200px,1.1fr) minmax(240px,2fr) 150px', minWidth: 0, color: 'inherit' }}
            data-testid="client-row">
            <span className="m-main" style={{ minWidth: 0 }}>
              <b className="ellipsis" style={{ display: 'block' }}>{c.business_name}</b>
              <span className="faint" style={{ fontSize: 12 }}>{serviceList(c.services)}</span>
            </span>
            <span className="row wrap" style={{ gap: 4 }}>
              {attention(c).length ? attention(c).slice(0, 4).map((a) => <span key={a.text} className={'chip ' + a.tone}>{a.text}</span>) : <span className="chip t-green">Up to date</span>}
            </span>
            <span className="faint" style={{ fontSize: 12, textAlign: 'right' }}>
              {c.health?.deadlines.find((d) => !d.overdue) ? `Next: ${c.health.deadlines.find((d) => !d.overdue)!.label} ${fmtDay(c.health.deadlines.find((d) => !d.overdue)!.due, false)}` : ''}
              {c.health?.last_entry ? <span style={{ display: 'block' }}>Books touched {when(c.health.last_entry)}</span> : null}
            </span>
          </Link>
        ))}
      </section>
      {lead && h.past_clients.length > 0 && (
        <details className="card card-pad">
          <summary className="faint" style={{ cursor: 'pointer', fontSize: 13 }}>Past clients and declined invitations ({h.past_clients.length})</summary>
          <div className="stack" style={{ gap: 4, marginTop: 8, fontSize: 13 }}>
            {h.past_clients.map((c) => <div key={c.id}>{c.business_name || c.invite_email} <span className="faint">· {c.status} {c.ended_at ? when(c.ended_at) : ''}</span></div>)}
          </div>
        </details>
      )}
      {inviting && <InviteClient pid={pid} onClose={() => setInviting(false)} />}
    </>
  );
}

function BusinessInvitations({ pid, h }: { pid: string; h: Home }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [busy, setBusy] = useState<string | null>(null);
  async function act(id: string, take: boolean) {
    setBusy(id);
    try {
      if (take) await rpc('practice_take_request', { p_client: id, p_practice: pid }); else await rpc('practice_decline_request', { p_client: id });
      await Promise.all([qc.invalidateQueries({ queryKey: ['practice-home'] }), qc.invalidateQueries({ queryKey: ['practices-mine'] })]);
      toast(take ? 'Added to your clients.' : 'Declined.');
    } catch (e) { toast(cleanError(e), 'err'); }
    setBusy(null);
  }
  return (
    <section className="card card-pad stack" style={{ gap: 10, borderColor: '#BFDBFE' }} data-testid="business-invitations">
      <b>Businesses asking you to be their accountant</b>
      {h.business_invitations.map((i) => (
        <div key={i.id} className="row wrap" style={{ gap: 10, justifyContent: 'space-between' }}>
          <span style={{ minWidth: 0 }}>
            <b>{i.business}</b> <span className="faint" style={{ fontSize: 13 }}>· {serviceList(i.services)}{i.billing === 'practice' ? ' · they would like you to pay for Counta' : ''} · {when(i.created_at)}</span>
            {i.note && <span className="faint" style={{ display: 'block', fontSize: 13 }}>“{i.note}”</span>}
          </span>
          <span className="row" style={{ gap: 6 }}>
            <button className="btn btn-ghost btn-sm" disabled={busy !== null} onClick={() => act(i.id, false)}>Decline</button>
            <button className="btn btn-primary btn-sm" disabled={busy !== null} onClick={() => act(i.id, true)}>{busy === i.id ? <Spinner small /> : <Icon name="check" size={14} color="#fff" />}Take them on</button>
          </span>
        </div>
      ))}
    </section>
  );
}

function Invited({ pid, rows }: { pid: string; rows: ClientRow[] }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [busy, setBusy] = useState<string | null>(null);
  async function resend(id: string) {
    setBusy(id);
    const r = await sendInvite('client', id);
    setBusy(null);
    if (r.ok) { toast(`Sent to ${r.sent_to}`); await qc.invalidateQueries({ queryKey: ['practice-home', pid] }); } else toast(r.error || 'Not sent.', 'err');
  }
  async function withdraw(id: string) {
    setBusy(id);
    try { await rpc('practice_withdraw', { p_client: id }); await qc.invalidateQueries({ queryKey: ['practice-home', pid] }); toast('Withdrawn'); } catch (e) { toast(cleanError(e), 'err'); }
    setBusy(null);
  }
  return (
    <section className="card card-pad stack" style={{ gap: 8 }}>
      <b>Invitations waiting</b>
      {rows.map((c) => (
        <div key={c.id} className="row wrap" style={{ gap: 10, justifyContent: 'space-between', fontSize: 14 }}>
          <span>{c.business_name || c.invite_email} <span className="faint">· {c.invite_email} · {c.sent_at ? `sent ${when(c.sent_at)}` : 'not sent yet'}</span></span>
          <span className="row" style={{ gap: 6 }}>
            <button className="btn btn-ghost btn-sm" disabled={busy !== null} onClick={() => withdraw(c.id)}>Withdraw</button>
            <button className="btn btn-secondary btn-sm" disabled={busy !== null} onClick={() => resend(c.id)}>{busy === c.id ? <Spinner small /> : <Icon name="send" size={14} />}{c.sent_at ? 'Send again' : 'Send'}</button>
          </span>
        </div>
      ))}
    </section>
  );
}

function InviteClient({ pid, onClose }: { pid: string; onClose: () => void }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [f, setF] = useState({ email: '', name: '', business_name: '', billing: 'business', note: '' });
  const [services, setServices] = useState<string[]>(['bookkeeping', 'vat', 'wht', 'cit', 'statements']);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function send() {
    setBusy(true); setErr(null);
    try {
      const id = await rpc<string>('practice_invite_client', { p_practice: pid, p: { ...f, services } });
      const r = await sendInvite('client', id);
      await qc.invalidateQueries({ queryKey: ['practice-home', pid] });
      if (r.ok) toast(`Invitation sent to ${r.sent_to}`); else toast(`Saved, but the email did not go: ${r.error}`, 'err');
      onClose();
    } catch (e) { setErr(cleanError(e)); }
    setBusy(false);
  }
  return (
    <Modal onClose={onClose} width={560}>
      <ModalHead title="Invite a business" sub="The owner gets an email, signs in to Counta (or signs up) and chooses which of their businesses to connect." onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 12 }}>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <Field label="Owner's email" req><input className="input" type="email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} autoFocus /></Field>
          <Field label="Owner's name"><input className="input" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} maxLength={80} /></Field>
          <Field label="Business"><input className="input" value={f.business_name} onChange={(e) => setF({ ...f, business_name: e.target.value })} maxLength={120} /></Field>
          <Field label="Who pays for Counta">
            <select className="input" value={f.billing} onChange={(e) => setF({ ...f, billing: e.target.value })}><option value="business">The business</option><option value="practice">My practice</option></select>
          </Field>
        </div>
        <div>
          <div className="mini-label" style={{ marginBottom: 6 }}>What you will do for them</div>
          <div className="row wrap" style={{ gap: 6 }}>
            {SERVICES.map(([k, l]) => (
              <button key={k} type="button" className={'chip ' + (services.includes(k) ? 't-blue' : 't-grey')} style={{ cursor: 'pointer', border: 0 }}
                onClick={() => setServices((s) => (s.includes(k) ? s.filter((x) => x !== k) : [...s, k]))}>{services.includes(k) ? '✓ ' : ''}{l}</button>
            ))}
          </div>
        </div>
        <Field label="A note to the owner"><textarea className="input" rows={2} maxLength={500} value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} /></Field>
        <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }}>Once they accept, you and your partners and managers get an Accountant's place in the business: books and tax returns, never moving money. Staff get a place when you assign them.</div>
        {err && <Alert kind="red" icon="alert">{err}</Alert>}
      </div>
      <div className="modal-ft">
        <button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" disabled={busy || !/\S+@\S+\.\S+/.test(f.email)} onClick={send}>{busy ? <Spinner small /> : <Icon name="send" size={14} color="#fff" />}Send the invitation</button>
      </div>
    </Modal>
  );
}
