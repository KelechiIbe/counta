// One client: how its books and tax stand, the returns the practice changed, requests to the business, the practice's own
// notes, and who works on it. "Open the books" switches Counta to the business, through the accountant's own place in it.
import { useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc } from '../../lib/supabase';
import { N2, fmtDay, when } from '../../lib/format';
import { useSession, useToast } from '../../state/session';
import { Icon } from '../../components/Icon';
import { Alert, Field, Pills, SkeletonRows, Spinner } from '../../components/ui';
import { Card, PageHead } from '../../admin/ui';
import { type ClientDetail, openDoc, ROLE_WORD, serviceLabel, serviceList, usePracticeClient, usePracticeHome } from '../api';
import { FilesPanel } from '../Files';
import { attention } from './Overview';
import { StartPaying } from './Billing';

type Tab = 'overview' | 'files' | 'requests' | 'notes' | 'team';

export default function ClientPage({ pid }: { pid: string }) {
  const { cid = '' } = useParams();
  const q = usePracticeClient(cid);
  const [tab, setTab] = useState<Tab>('overview');
  const d = q.data;
  if (q.isLoading) return <SkeletonRows n={8} />;
  if (q.isError || !d) return <Alert kind="red" icon="alert">{q.isError ? cleanError(q.error) : 'Not found.'}</Alert>;
  const active = d.client.status === 'active';
  const answered = d.requests.filter((r) => r.status === 'answered').length;
  return (
    <>
      <div><Link to={`/practice/${pid}`} className="faint" style={{ fontSize: 13 }}>← All clients</Link></div>
      <PageHead title={d.client.business_name || d.client.invite_email || 'Client'}
        sub={[d.business?.tin ? `TIN ${d.business.tin}` : 'No TIN yet', d.business?.vat_registered ? 'VAT registered' : 'Not VAT registered',
          d.client.started_at ? `client since ${fmtDay(d.client.started_at.slice(0, 10))}` : null, serviceList(d.client.services)].filter(Boolean).join(' · ')}
        right={active && <OpenBooks d={d} />} />
      {!active && <Alert kind="grey" icon="history">This work ended {d.client.ended_at ? when(d.client.ended_at) : ''}. The practice's notes stay; the books are closed to you.</Alert>}
      {active && (
        <Pills value={tab} onChange={setTab} options={[{ id: 'overview', label: 'Overview' }, { id: 'files', label: 'Returns and statements', count: d.files.filter((f) => f.status === 'review').length || undefined },
          { id: 'requests', label: 'Requests', count: answered || undefined }, { id: 'notes', label: 'Notes', count: d.notes.length || undefined }, { id: 'team', label: 'Team and billing' }]} />
      )}
      {(tab === 'overview' || !active) && <OverviewTab d={d} />}
      {active && tab === 'files' && <FilesPanel d={d} />}
      {active && tab === 'requests' && <Requests d={d} />}
      {(tab === 'notes' || !active) && <Notes d={d} />}
      {active && tab === 'team' && <TeamTab d={d} />}
    </>
  );
}

function OpenBooks({ d }: { d: ClientDetail }) {
  const { refreshMemberships, setOrgId } = useSession();
  const nav = useNavigate();
  const [busy, setBusy] = useState(false);
  const ok = d.my_seat?.status === 'active';
  async function go() {
    setBusy(true);
    await refreshMemberships().catch(() => []);
    setOrgId(d.client.org_id);
    nav('/home');
  }
  return ok ? <button className="btn btn-primary btn-sm" disabled={busy} onClick={go}>{busy ? <Spinner small /> : <Icon name="book" size={14} color="#fff" />}Open the books</button>
    : <span className="faint" style={{ fontSize: 13 }}>Not assigned to you: ask a partner</span>;
}

function OverviewTab({ d }: { d: ClientDetail }) {
  const h = d.health;
  if (!h) return null;
  const att = attention({ ...d.client, answered: d.requests.filter((r) => r.status === 'answered').length, health: h } as any);
  return (
    <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: 'minmax(0,1.3fr) minmax(0,1fr)', gap: 16, alignItems: 'start' }}>
      <Card title="Tax deadlines" sub="Returns and payments Counta expects, oldest first." pad={false}>
        {!h.deadlines.length ? <div className="card-pad faint">Nothing is due.</div> : h.deadlines.map((x, i) => (
          <div key={i} className="tr rsp" style={{ gridTemplateColumns: 'minmax(0,1fr) 110px 120px' }}>
            <span className="m-main">{x.label} <span className="faint">· {x.tax === 'cit' ? new Date(x.period).getUTCFullYear() : new Date(x.period + 'T12:00:00Z').toLocaleDateString('en-GB', { month: 'short', year: 'numeric' })}</span></span>
            <span className="right num">{x.amount != null ? N2(x.amount) : ''}</span>
            <span className="right"><span className={'chip ' + (x.overdue ? 't-red' : 't-grey')}>{x.overdue ? 'was due ' : 'due '}{fmtDay(x.due, false)}</span></span>
          </div>
        ))}
      </Card>
      <div className="stack" style={{ gap: 16 }}>
        <Card title="The books">
          <div className="stack" style={{ gap: 6, fontSize: 14 }}>
            {att.length ? att.map((a) => <div key={a.text}><span className={'chip ' + a.tone}>{a.text}</span></div>) : <span className="chip t-green">Nothing waiting</span>}
            <div className="faint" style={{ fontSize: 13 }}>Invoices overdue: {h.invoices_overdue} · bills overdue: {h.bills_overdue}</div>
            <div className="faint" style={{ fontSize: 13 }}>{h.closed_through ? `Closed to ${fmtDay(h.closed_through)}` : 'No period closed yet'}{h.last_entry ? ` · last entry ${when(h.last_entry)}` : ''}</div>
          </div>
        </Card>
        <Card title="The business">
          <div className="stack" style={{ gap: 4, fontSize: 14 }}>
            {d.business?.owner && <div>{d.business.owner.name}{d.business.owner.email ? <span className="faint"> · {d.business.owner.email}</span> : null}</div>}
            {d.business?.phone && <div className="faint">{d.business.phone}</div>}
            {d.business?.address && <div className="faint">{d.business.address}</div>}
            <div className="faint">Counta plan: {h.plan.name}{h.plan.paid_by ? ' · paid by you' : ''}{h.plan.status === 'past_due' ? ' · payment overdue' : ''}</div>
          </div>
        </Card>
      </div>
    </div>
  );
}

function Requests({ d }: { d: ClientDetail }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [f, setF] = useState({ kind: 'document', title: '', detail: '', due_date: '' });
  const [busy, setBusy] = useState<string | null>(null);
  async function ask() {
    setBusy('new');
    try {
      await rpc('practice_request_create', { p_client: d.client.id, p: f });
      setF({ kind: 'document', title: '', detail: '', due_date: '' });
      await qc.invalidateQueries({ queryKey: ['practice-client', d.client.id] });
      toast('Sent to the business');
    } catch (e) { toast(cleanError(e), 'err'); }
    setBusy(null);
  }
  async function close(id: string, status: string) {
    setBusy(id);
    try { await rpc('practice_request_close', { p_request: id, p_status: status }); await qc.invalidateQueries({ queryKey: ['practice-client', d.client.id] }); }
    catch (e) { toast(cleanError(e), 'err'); }
    setBusy(null);
  }
  return (
    <div className="stack" style={{ gap: 16 }}>
      <Card title="Ask the business" sub="The owner is told at once and answers in Counta, under Settings, Your accountant.">
        <div className="row wrap" style={{ gap: 8 }}>
          <select className="input input-sm" style={{ width: 150 }} value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value })} aria-label="Kind">
            <option value="document">A document</option><option value="question">A question</option><option value="approval">An approval</option>
          </select>
          <input className="input input-sm" style={{ flex: '1 1 260px', minWidth: 0 }} placeholder="What you need, e.g. September bank statement" maxLength={140}
            value={f.title} onChange={(e) => setF({ ...f, title: e.target.value })} aria-label="What you need" />
          <input className="input input-sm" type="date" value={f.due_date} onChange={(e) => setF({ ...f, due_date: e.target.value })} aria-label="Needed by" />
        </div>
        <textarea className="input" rows={2} maxLength={1500} placeholder="More detail (optional)" value={f.detail} onChange={(e) => setF({ ...f, detail: e.target.value })} />
        <div><button className="btn btn-primary btn-sm" disabled={busy !== null || f.title.trim().length < 3} onClick={ask}>{busy === 'new' ? <Spinner small /> : <Icon name="send" size={14} color="#fff" />}Send the request</button></div>
      </Card>
      <Card title="Requests" pad={false}>
        {!d.requests.length ? <div className="card-pad faint">None yet.</div> : d.requests.map((r) => (
          <div key={r.id} className="card-pad stack" style={{ gap: 6, borderTop: '1px solid var(--row)' }} data-testid="request">
            <div className="row wrap" style={{ gap: 8, justifyContent: 'space-between' }}>
              <b>{r.title}</b>
              <span className={'chip ' + (r.status === 'answered' ? 't-blue' : r.status === 'open' ? 't-amber' : 't-grey')}>{r.status === 'open' ? 'Waiting' : r.status === 'answered' ? 'Answered' : r.status === 'done' ? 'Done' : 'Cancelled'}</span>
            </div>
            <div className="faint" style={{ fontSize: 12 }}>{r.asked_by} · {when(r.created_at)}{r.due_date ? ` · by ${fmtDay(r.due_date)}` : ''}</div>
            {r.detail && <div style={{ fontSize: 14 }}>{r.detail}</div>}
            {(r.answer || r.file_path) && (
              <div className="card card-pad stack" style={{ gap: 6, background: 'var(--canvas)' }}>
                {r.answer && <div style={{ fontSize: 14 }}>{r.answer}</div>}
                {r.file_path && <button className="btn btn-secondary btn-sm" style={{ alignSelf: 'flex-start' }} onClick={() => openDoc(r.file_path!).catch((e) => toast(e.message, 'err'))}><Icon name="paperclip" size={14} />{r.file_name}</button>}
                <div className="faint" style={{ fontSize: 12 }}>{r.answered_by} · {when(r.answered_at)}</div>
              </div>
            )}
            <div className="row wrap" style={{ gap: 6 }}>
              {r.status === 'answered' && <button className="btn btn-primary btn-sm" disabled={busy !== null} onClick={() => close(r.id, 'done')}><Icon name="check" size={14} color="#fff" />Mark done</button>}
              {(r.status === 'open' || r.status === 'answered') && <button className="btn btn-ghost btn-sm" disabled={busy !== null} onClick={() => close(r.id, 'cancelled')}>Cancel it</button>}
              {(r.status === 'done' || r.status === 'cancelled') && <button className="btn btn-ghost btn-sm" disabled={busy !== null} onClick={() => close(r.id, 'open')}>Open again</button>}
            </div>
          </div>
        ))}
      </Card>
    </div>
  );
}

function Notes({ d }: { d: ClientDetail }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [text, setText] = useState('');
  const [busy, setBusy] = useState(false);
  async function add() {
    setBusy(true);
    try { await rpc('practice_note_add', { p_client: d.client.id, p_text: text }); setText(''); await qc.invalidateQueries({ queryKey: ['practice-client', d.client.id] }); }
    catch (e) { toast(cleanError(e), 'err'); }
    setBusy(false);
  }
  async function remove(id: string) {
    try { await rpc('practice_note_delete', { p_note: id }); await qc.invalidateQueries({ queryKey: ['practice-client', d.client.id] }); } catch (e) { toast(cleanError(e), 'err'); }
  }
  return (
    <Card title="The practice's notes" sub="Only your practice sees these. The business never does.">
      <div className="row wrap" style={{ gap: 8 }}>
        <input className="input input-sm" style={{ flex: '1 1 300px', minWidth: 0 }} maxLength={2000} placeholder="A note for the team" value={text} onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter' && text.trim()) void add(); }} />
        <button className="btn btn-secondary btn-sm" disabled={busy || !text.trim()} onClick={add}>{busy ? <Spinner small /> : <Icon name="plus" size={14} />}Add</button>
      </div>
      {d.notes.map((n) => (
        <div key={n.id} className="row" style={{ gap: 8, alignItems: 'flex-start', fontSize: 14 }}>
          <div className="grow"><div>{n.text}</div><div className="faint" style={{ fontSize: 12 }}>{n.author} · {when(n.created_at)}</div></div>
          {(n.mine || d.can_lead) && <button className="btn btn-ghost btn-sm" onClick={() => remove(n.id)} aria-label="Remove the note"><Icon name="trash" size={14} /></button>}
        </div>
      ))}
    </Card>
  );
}

function TeamTab({ d }: { d: ClientDetail }) {
  const qc = useQueryClient();
  const toast = useToast();
  const nav = useNavigate();
  const [busy, setBusy] = useState<string | null>(null);
  const [ending, setEnding] = useState(false);
  async function assign(member: string, on: boolean) {
    setBusy(member);
    try { await rpc('practice_assign', { p_client: d.client.id, p_member: member, p_on: on }); await qc.invalidateQueries({ queryKey: ['practice-client', d.client.id] }); }
    catch (e) { toast(cleanError(e), 'err'); }
    setBusy(null);
  }
  async function billing(b: 'business' | 'practice') {
    setBusy('billing');
    try { await rpc('practice_set_billing', { p_client: d.client.id, p_billing: b }); await qc.invalidateQueries({ queryKey: ['practice-client', d.client.id] }); toast('Saved'); }
    catch (e) { toast(cleanError(e), 'err'); }
    setBusy(null);
  }
  async function end() {
    setBusy('end');
    try {
      await rpc('practice_end', { p_client: d.client.id });
      await Promise.all([qc.invalidateQueries({ queryKey: ['practice-home'] }), qc.invalidateQueries({ queryKey: ['practice-client'] })]);
      toast('Ended. Your places in the business are switched off.');
      nav(`/practice/${d.client.practice_id}`);
    } catch (e) { toast(cleanError(e), 'err'); }
    setBusy(null);
  }
  const paidByUs = !!d.health?.plan.paid_by;
  const plans = usePracticeHome(d.client.practice_id).data?.plans || [];
  return (
    <div className="stack" style={{ gap: 16 }}>
      <Card title="Who works on it" sub="Partners and managers work on every client. Staff get a place in the business when you assign them, and lose it when you take them off." pad={false}>
        {d.team.map((t) => (
          <div key={t.member.id} className="tr rsp" style={{ gridTemplateColumns: 'minmax(0,1fr) 120px 140px' }}>
            <span className="m-main">{t.member.display_name} <span className="faint">· {ROLE_WORD[t.member.role]}{t.member.licence_body ? ` · ${t.member.licence_text}` : ''}</span></span>
            <span className="faint" style={{ fontSize: 12 }}>{t.seat === 'active' ? 'Has a place' : t.seat === 'disabled' ? 'Place switched off' : 'No place'}</span>
            <span className="right">
              {t.member.role === 'staff' && d.can_lead
                ? <label className="row" style={{ gap: 6, justifyContent: 'flex-end', fontSize: 13 }}><input type="checkbox" checked={t.assigned} disabled={busy !== null}
                    onChange={(e) => assign(t.member.id, e.target.checked)} aria-label={`Assign ${t.member.display_name}`} />Assigned</label>
                : <span className="faint" style={{ fontSize: 12 }}>{t.member.role === 'staff' ? (t.assigned ? 'Assigned' : 'Not assigned') : 'Every client'}</span>}
            </span>
          </div>
        ))}
      </Card>
      {d.can_lead && (
        <Card title="Counta plan" sub={paidByUs ? `You pay for ${d.client.business_name}'s ${d.health?.plan.name} plan${d.health?.plan.period_end ? `, paid to ${fmtDay(d.health.plan.period_end.slice(0, 10))}` : ''}.`
          : `The business pays for its own plan (${d.health?.plan.name}).`}>
          {paidByUs
            ? <div><button className="btn btn-secondary btn-sm" disabled={busy !== null} onClick={() => billing('business')}>Stop paying at the end of the period</button></div>
            : <StartPaying clientId={d.client.id} name={d.client.business_name || ''} plans={plans} />}
        </Card>
      )}
      {d.can_lead && (
        <Card title="End the work" sub="Your places in the business switch off at once. Your notes stay. A plan you paid for runs to the end of its period.">
          {!ending ? <div><button className="btn btn-ghost btn-sm" onClick={() => setEnding(true)}>End our work for {d.client.business_name}</button></div> : (
            <div className="row wrap" style={{ gap: 8 }}>
              <span style={{ fontSize: 14 }}>Are you sure?</span>
              <button className="btn btn-danger btn-sm" disabled={busy !== null} onClick={end}>{busy === 'end' ? <Spinner small /> : null}Yes, end it</button>
              <button className="btn btn-ghost btn-sm" onClick={() => setEnding(false)}>Keep working</button>
            </div>
          )}
        </Card>
      )}
      <Field label="Services"><div style={{ fontSize: 14 }}>{serviceList(d.client.services)}</div></Field>
    </div>
  );
}
