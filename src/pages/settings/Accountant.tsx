// Settings, Your accountant: invite an accountant by email, see the practice and the people with places in the business,
// answer their requests, see the returns they changed (and withdraw one), and end the work at any time.
import { useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc, supabase } from '../../lib/supabase';
import { fmtDay, uuid, when } from '../../lib/format';
import { useInventory, useSession, useToast } from '../../state/session';
import { Icon } from '../../components/Icon';
import { Alert, Field, Spinner } from '../../components/ui';
import { type FileBrief, openDoc, type RequestRow, sendInvite, serviceLabel, serviceList, STATUS_CHIP } from '../../practice/api';
import { FileReview } from '../../practice/FileReview';

type OrgAccountants = {
  can_manage: boolean;
  practices: { client_id: string; status: string; practice: { id: string; name: string; email: string | null; phone: string | null; firm_reg: string | null; kind: string };
    partners: { name: string; licence: string; verified: boolean }[]; people: { member_id: string; name: string; status: string; title: string | null; licence: string | null }[];
    services: string[]; billing: string; started_at: string; pays_plan: boolean }[];
  invitations: { client_id: string; email: string; name: string | null; note: string | null; billing: string; services: string[]; created_at: string; sent_at: string | null; expired: boolean }[];
  requests: RequestRow[]; files: FileBrief[];
};

export function useOrgAccountants() {
  const { orgId } = useSession();
  return useQuery({ queryKey: ['org-accountants', orgId], enabled: !!orgId, queryFn: () => rpc<OrgAccountants>('org_accountants', { p_org: orgId }) });
}

export function AccountantSection() {
  const q = useOrgAccountants();
  const { data: inv } = useInventory();
  const d = q.data;
  const [open, setOpen] = useState<string | null>(null);
  if (q.isLoading || !d || !inv) return <Spinner small />;
  const owner = inv.me.role === 'owner';
  const waiting = d.requests.filter((r) => r.status === 'open');
  return (
    <div className="stack" style={{ gap: 14 }} data-testid="accountant-section">
      {d.practices.map((p) => <Practice key={p.client_id} p={p} canManage={d.can_manage} />)}
      {!d.practices.length && <div className="muted" style={{ fontSize: 14, lineHeight: 1.55 }}>
        Invite your accountant by email. Once they accept in Counta's accountant portal, they keep your books and prepare your returns from inside Counta, alongside their
        other clients. They never move money, and you can end it at any time.</div>}
      {d.can_manage && <Invite d={d} />}
      {(owner || waiting.length > 0) && d.requests.length > 0 && (
        <div className="stack" style={{ gap: 8 }}>
          <b style={{ fontSize: 14 }}>Requests from your accountant{waiting.length ? ` (${waiting.length} waiting)` : ''}</b>
          {d.requests.map((r) => <Request key={r.id} r={r} canAnswer={owner || inv.me.role === 'admin'} />)}
        </div>
      )}
      {d.files.length > 0 && (
        <div className="stack" style={{ gap: 6 }}>
          <b style={{ fontSize: 14 }}>Returns and statements your accountant changed</b>
          {d.files.map((f) => {
            const [label, tone] = STATUS_CHIP[f.status];
            return (
              <button key={f.id} className="card card-pad row wrap" style={{ gap: 8, justifyContent: 'space-between', textAlign: 'left', cursor: 'pointer', background: '#fff' }} onClick={() => setOpen(f.id)}>
                <span style={{ minWidth: 0 }}>
                  <b>{f.label.charAt(0).toUpperCase() + f.label.slice(1)}</b>
                  <span className="faint" style={{ display: 'block', fontSize: 12 }}>{f.accepted_name || f.uploader_name}{f.practice_name ? `, ${f.practice_name}` : ''} · {f.changes} {f.changes === 1 ? 'change' : 'changes'} · {when(f.accepted_at || f.created_at)}</span>
                </span>
                <span className={'chip ' + tone}>{f.status === 'review' ? 'Not in use yet' : label}</span>
              </button>
            );
          })}
        </div>
      )}
      {open && <FileReview id={open} onClose={() => setOpen(null)} />}
    </div>
  );
}

function Practice({ p, canManage }: { p: OrgAccountants['practices'][number]; canManage: boolean }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [ending, setEnding] = useState(false);
  const [busy, setBusy] = useState(false);
  async function end() {
    setBusy(true);
    try { await rpc('practice_end', { p_client: p.client_id }); await qc.invalidateQueries({ queryKey: ['org-accountants'] }); toast(`${p.practice.name} no longer has places in the business.`); }
    catch (e) { toast(cleanError(e), 'err'); }
    setBusy(false);
  }
  return (
    <div className="card card-pad stack" style={{ gap: 8 }} data-testid="org-practice">
      <div className="row wrap" style={{ gap: 8, justifyContent: 'space-between' }}>
        <div style={{ minWidth: 0 }}>
          <b style={{ fontSize: 15 }}>{p.practice.name}</b>
          <div className="faint" style={{ fontSize: 13 }}>{[p.practice.email, p.practice.phone, p.practice.firm_reg && `Firm ${p.practice.firm_reg}`, `since ${fmtDay(p.started_at?.slice(0, 10))}`].filter(Boolean).join(' · ')}</div>
        </div>
        {p.pays_plan && <span className="chip t-green">Pays for your Counta plan</span>}
      </div>
      {p.partners.map((x) => (
        <div key={x.name} style={{ fontSize: 14 }}>{x.name} <span className="faint">· {x.licence}</span> {x.verified && <Icon name="shield" size={14} color="#15803D" />}</div>
      ))}
      <div className="faint" style={{ fontSize: 13 }}>
        People with a place in your business: {p.people.length ? p.people.map((x) => x.name).join(', ') : 'none yet'}. They have the Accountant role: change what it may do in Team and roles above.
      </div>
      <div className="faint" style={{ fontSize: 13 }}>Services: {serviceList(p.services)}</div>
      {canManage && (!ending
        ? <div><button className="btn btn-ghost btn-sm" onClick={() => setEnding(true)}>End our work with {p.practice.name}</button></div>
        : <div className="row wrap" style={{ gap: 8 }}>
            <span style={{ fontSize: 14 }}>Their places switch off at once{p.pays_plan ? ', and the plan they paid for runs to the end of its period' : ''}.</span>
            <button className="btn btn-danger btn-sm" disabled={busy} onClick={end}>{busy ? <Spinner small /> : null}End it</button>
            <button className="btn btn-ghost btn-sm" onClick={() => setEnding(false)}>Keep them</button>
          </div>)}
    </div>
  );
}

function Invite({ d }: { d: OrgAccountants }) {
  const { orgId } = useSession();
  const qc = useQueryClient();
  const toast = useToast();
  const [f, setF] = useState({ email: '', name: '', firm: '', billing: 'business', note: '' });
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  async function send() {
    setBusy('new'); setErr(null);
    try {
      const id = await rpc<string>('business_invite_accountant', { p_org: orgId, p: f });
      const r = await sendInvite('accountant', id);
      setF({ email: '', name: '', firm: '', billing: 'business', note: '' });
      await qc.invalidateQueries({ queryKey: ['org-accountants'] });
      if (r.ok) toast(`Invitation sent to ${r.sent_to}`); else toast(`Saved, but the email did not go: ${r.error}`, 'err');
    } catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }
  async function resend(id: string) {
    setBusy(id);
    const r = await sendInvite('accountant', id);
    setBusy(null);
    if (r.ok) { toast(`Sent to ${r.sent_to}`); await qc.invalidateQueries({ queryKey: ['org-accountants'] }); } else toast(r.error || 'Not sent.', 'err');
  }
  async function withdraw(id: string) {
    setBusy(id);
    try { await rpc('practice_withdraw', { p_client: id }); await qc.invalidateQueries({ queryKey: ['org-accountants'] }); toast('Withdrawn'); } catch (e) { toast(cleanError(e), 'err'); }
    setBusy(null);
  }
  return (
    <div className="stack" style={{ gap: 10 }}>
      {d.invitations.map((i) => (
        <div key={i.client_id} className="row wrap" style={{ gap: 8, justifyContent: 'space-between', fontSize: 14 }}>
          <span>{i.name || i.email} <span className="faint">· {i.email} · {i.expired ? 'link expired' : i.sent_at ? `sent ${when(i.sent_at)}` : 'not sent yet'}</span></span>
          <span className="row" style={{ gap: 6 }}>
            <button className="btn btn-ghost btn-sm" disabled={busy !== null} onClick={() => withdraw(i.client_id)}>Withdraw</button>
            <button className="btn btn-secondary btn-sm" disabled={busy !== null} onClick={() => resend(i.client_id)}>{busy === i.client_id ? <Spinner small /> : <Icon name="send" size={14} />}Send again</button>
          </span>
        </div>
      ))}
      <details open={!d.practices.length && !d.invitations.length}>
        <summary style={{ cursor: 'pointer', fontSize: 14, fontWeight: 600 }}>Invite {d.practices.length ? 'another' : 'your'} accountant</summary>
        <div className="stack" style={{ gap: 10, marginTop: 10 }}>
          <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
            <Field label="Their email" req><input className="input" type="email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} /></Field>
            <Field label="Their name"><input className="input" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} maxLength={80} /></Field>
            <Field label="Firm"><input className="input" value={f.firm} onChange={(e) => setF({ ...f, firm: e.target.value })} maxLength={120} /></Field>
            <Field label="Who pays for Counta">
              <select className="input" value={f.billing} onChange={(e) => setF({ ...f, billing: e.target.value })}><option value="business">We do</option><option value="practice">We would like the accountant to</option></select>
            </Field>
          </div>
          <Field label="A note"><input className="input" value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} maxLength={300} placeholder="For example: monthly VAT and the year-end accounts" /></Field>
          {err && <Alert kind="red" icon="alert">{err}</Alert>}
          <div><button className="btn btn-primary btn-sm" disabled={busy !== null || !/\S+@\S+\.\S+/.test(f.email)} onClick={send}>{busy === 'new' ? <Spinner small /> : <Icon name="send" size={14} color="#fff" />}Send the invitation</button></div>
        </div>
      </details>
    </div>
  );
}

function Request({ r, canAnswer }: { r: RequestRow; canAnswer: boolean }) {
  const { orgId } = useSession();
  const qc = useQueryClient();
  const toast = useToast();
  const [text, setText] = useState('');
  const [file, setFile] = useState<File | null>(null);
  const [busy, setBusy] = useState(false);
  const input = useRef<HTMLInputElement>(null);
  async function answer() {
    setBusy(true);
    try {
      let path: string | null = null;
      if (file) {
        if (file.size > 20_000_000) throw new Error('The file is larger than 20 MB.');
        const ext = (file.name.match(/\.[A-Za-z0-9]{1,6}$/)?.[0] || '').toLowerCase();
        path = `${orgId}/requests/${r.id}/${uuid()}${ext}`;
        const { error } = await supabase.storage.from('documents').upload(path, file, { contentType: file.type || undefined });
        if (error) throw new Error(cleanError(error));
      }
      await rpc('org_request_answer', { p_request: r.id, p: { answer: text.trim() || null, file_path: path, file_name: file?.name.slice(0, 140) || null } });
      setText(''); setFile(null);
      await qc.invalidateQueries({ queryKey: ['org-accountants'] });
      toast('Sent to your accountant');
    } catch (e) { toast(cleanError(e), 'err'); }
    setBusy(false);
  }
  const open = r.status === 'open' || r.status === 'answered';
  return (
    <div className="card card-pad stack" style={{ gap: 6 }} data-testid="org-request">
      <div className="row wrap" style={{ gap: 8, justifyContent: 'space-between' }}>
        <b>{r.title}</b>
        <span className={'chip ' + (r.status === 'open' ? 't-amber' : r.status === 'answered' ? 't-blue' : 't-grey')}>{r.status === 'open' ? 'Waiting for you' : r.status === 'answered' ? 'Answered' : r.status === 'done' ? 'Done' : 'Cancelled'}</span>
      </div>
      <div className="faint" style={{ fontSize: 12 }}>{r.asked_by}, {r.practice} · {when(r.created_at)}{r.due_date ? ` · needed by ${fmtDay(r.due_date)}` : ''}</div>
      {r.detail && <div style={{ fontSize: 14 }}>{r.detail}</div>}
      {(r.answer || r.file_path) && (
        <div className="faint" style={{ fontSize: 13 }}>
          You answered{r.answer ? `: ${r.answer}` : ''}{r.file_path && <> · <button className="btn btn-ghost btn-sm" onClick={() => openDoc(r.file_path!).catch((e) => toast(e.message, 'err'))}><Icon name="paperclip" size={12} />{r.file_name}</button></>}
        </div>
      )}
      {open && canAnswer && (
        <div className="row wrap" style={{ gap: 6 }}>
          <input className="input input-sm" style={{ flex: '1 1 240px', minWidth: 0 }} placeholder={r.status === 'answered' ? 'Add to your answer' : 'Your answer'} value={text} onChange={(e) => setText(e.target.value)} maxLength={2000} />
          <input ref={input} type="file" style={{ display: 'none' }} onChange={(e) => setFile(e.target.files?.[0] || null)} />
          <button className="btn btn-secondary btn-sm" onClick={() => input.current?.click()}><Icon name="paperclip" size={14} />{file ? file.name.slice(0, 24) : 'Attach a file'}</button>
          <button className="btn btn-primary btn-sm" disabled={busy || (!text.trim() && !file)} onClick={answer}>{busy ? <Spinner small /> : <Icon name="send" size={14} color="#fff" />}Send</button>
        </div>
      )}
    </div>
  );
}
