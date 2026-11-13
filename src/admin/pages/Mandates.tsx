// Full mandates, for TaxStreem: a firm runs a business for its owner, and payments open only once a director of the
// company has confirmed the wallets. Here TaxStreem checks the confirmations that looked wrong (answered from the firm's
// own connection, or from one that could not be read), pauses a practice's full mandates when it must (admins), and works
// through the open flags: a company already on Counta under someone else, a director who declined, a handover to someone
// other than the director who confirmed. Every decision takes a note. Admins also set the extra free-mail domains.
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc } from '../../lib/supabase';
import { when } from '../../lib/format';
import { useToast } from '../../state/session';
import { Icon } from '../../components/Icon';
import { Alert, Spinner } from '../../components/ui';
import { Card, PageHead } from '../ui';
import { type AdminMandates, useAdminMandates } from '../api';

const REVIEW_WHY: Record<string, string> = {
  firm_ip: 'Answered from an address the firm\'s people signed in from in the last 30 days.',
  ip_unreadable: 'The address it was answered from could not be read.',
};
const FLAG: Record<AdminMandates['flags'][number]['kind'], [string, string]> = {
  duplicate_company: ['Company already on Counta', 't-red'], director_declined: ['Director declined', 't-amber'],
  director_review: ['Director confirmation to check', 't-blue'], handover: ['Handover to someone else', 't-amber'],
};
const STATUS_WORD: Record<string, string> = {
  pending: 'not checked', review: 'in review', verified: 'verified', approved: 'approved', rejected: 'rejected', not_required: 'not needed',
};

export default function Mandates({ admin }: { admin: boolean }) {
  const q = useAdminMandates();
  const d = q.data;
  return (
    <>
      <PageHead title="Mandates" sub="Firms that run businesses for their owners. Payments open only once a director of the company confirms the wallets; here TaxStreem checks what looked wrong." />
      {q.isLoading ? <div className="row" style={{ justifyContent: 'center', padding: 40 }}><Spinner /></div>
        : q.isError || !d ? <Alert kind="red" icon="alert">{cleanError(q.error)}</Alert> : (
        <>
          <section className="stack" style={{ gap: 12 }} data-testid="mandate-reviews" aria-labelledby="mr-h">
            <h2 id="mr-h" style={{ fontSize: 17, margin: 0 }}>Director confirmations to check {d.reviews.length ? <span className="chip t-amber">{d.reviews.length}</span> : null}</h2>
            {!d.reviews.length ? <Alert kind="green" icon="check">Nothing waiting.</Alert> : d.reviews.map((r) => <DirectorReview key={r.id} r={r} />)}
          </section>
          <section className="stack" style={{ gap: 12 }} data-testid="mandate-flags" aria-labelledby="mf-h">
            <h2 id="mf-h" style={{ fontSize: 17, margin: 0 }}>Open flags {d.flags.length ? <span className="chip t-amber">{d.flags.length}</span> : null}</h2>
            {!d.flags.length ? <Alert kind="green" icon="check">No open flags.</Alert> : d.flags.map((f) => <Flag key={f.id} f={f} admin={admin} />)}
          </section>
          <section className="stack" style={{ gap: 12 }} data-testid="mandate-practices" aria-labelledby="mp-h">
            <h2 id="mp-h" style={{ fontSize: 17, margin: 0 }}>Practices</h2>
            <Card pad={false}>
              {!d.practices.length ? <div className="card-pad faint">No practice runs or may run full mandates yet.</div> : d.practices.map((p) => <Practice key={p.id} p={p} admin={admin} />)}
            </Card>
          </section>
          {admin && <FreeMail list={d.settings?.free_mail_domains || []} />}
        </>
      )}
    </>
  );
}

// A note of at least five characters, then one of the actions; the same row for every decision on the page.
function Decide({ actions, placeholder, testid }: { actions: { label: string; tone: 'primary' | 'danger' | 'secondary'; run: (note: string) => Promise<void>; testid: string }[];
  placeholder: string; testid?: string }) {
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  async function go(a: (typeof actions)[number]) {
    if (note.trim().length < 5) { setErr('Write a note of at least 5 characters first.'); return; }
    setBusy(a.label); setErr(null);
    try { await a.run(note.trim()); setNote(''); } catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }
  return (
    <div className="stack" style={{ gap: 6 }}>
      <div className="row wrap" style={{ gap: 8 }}>
        <input className="input" style={{ flex: '1 1 260px', minWidth: 0, minHeight: 40 }} placeholder={placeholder} aria-label="Note" maxLength={1000}
          value={note} onChange={(e) => setNote(e.target.value)} data-testid={testid} />
        {actions.map((a) => (
          <button key={a.label} type="button" className={`btn btn-sm btn-${a.tone}`} style={{ minHeight: 40 }} disabled={busy !== null} onClick={() => go(a)} data-testid={a.testid}>
            {busy === a.label ? <Spinner small /> : null}{a.label}
          </button>
        ))}
      </div>
      {err && <Alert kind="red" icon="alert"><span role="alert">{err}</span></Alert>}
    </div>
  );
}

function DirectorReview({ r }: { r: AdminMandates['reviews'][number] }) {
  const qc = useQueryClient();
  const toast = useToast();
  const decide = (approve: boolean) => async (note: string) => {
    await rpc('admin_director_decide', { p_id: r.id, p_approve: approve, p_note: note });
    await qc.invalidateQueries({ queryKey: ['admin-mandates'] });
    toast(approve ? `Accepted: ${r.business.name} can open its wallets` : 'Declined: the firm is told to ask again');
  };
  return (
    <div className="card card-pad stack" style={{ gap: 10 }} data-testid="director-review-row">
      <div className="row wrap" style={{ gap: 10, alignItems: 'flex-start' }}>
        <div style={{ flex: '1 1 260px', minWidth: 0 }}>
          <div style={{ fontWeight: 700, fontSize: 16 }}>{r.business.name}</div>
          <div className="faint" style={{ fontSize: 13 }}>Run by {r.practice.name} · confirmed {when(r.created_at)}</div>
        </div>
        <span className="chip t-amber">Waiting</span>
      </div>
      <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14, fontSize: 14, lineHeight: 1.6 }}>
        <div>
          <div className="mini-label">The director</div>
          <div>{r.director.name}</div>
          <div className="faint" style={{ wordBreak: 'break-all' }}>{r.director.email}{r.director.phone ? ` · ${r.director.phone}` : ''}</div>
        </div>
        <div>
          <div className="mini-label">Why it is here</div>
          <div>{REVIEW_WHY[r.reason || ''] || 'Flagged for a check.'}</div>
          <div className="faint" style={{ wordBreak: 'break-all' }}>{r.ip || 'No address'}{r.ua ? ` · ${r.ua.slice(0, 90)}` : ''}</div>
        </div>
      </div>
      <Decide placeholder="Note (what you checked, e.g. called the director on the CAC phone number)" testid="director-note"
        actions={[{ label: 'Accept', tone: 'primary', run: decide(true), testid: 'director-approve' }, { label: 'Decline', tone: 'danger', run: decide(false), testid: 'director-decline' }]} />
    </div>
  );
}

function detailLines(f: AdminMandates['flags'][number]): string[] {
  const x = f.detail || {};
  if (f.kind === 'duplicate_company' && x.source === 'owner') return [
    `${x.email || 'Someone'} tried to set up this company as its owner${x.name ? ` (as ${x.name})` : ''}, matched on the ${x.matched_on === 'tax_id' ? 'Tax ID' : 'RC number'}. They were told to ask the firm to hand it over, and nothing was set up.`,
  ];
  if (f.kind === 'duplicate_company') return [
    `Matched on the ${x.matched_on === 'tax_id' ? 'Tax ID' : 'RC number'}${f.intake?.rc_number ? ` (${f.intake.rc_number})` : f.intake?.tax_id ? ` (${f.intake.tax_id})` : ''}${x.source === 'cac' ? ', when the firm chose the CAC record' : ', at intake'}.`,
  ];
  if (f.kind === 'handover') return [
    x.reason === 'no_director' ? 'No director had confirmed the wallets before the handover.' : 'Taken by someone other than the director who confirmed the wallets.',
    x.ip_matches_firm === true ? `Accepted from ${x.ip}, an address the firm's people signed in from.` : x.ip ? `Accepted from ${x.ip}.` : 'The accepting address could not be read.',
  ];
  if (f.kind === 'director_declined') return [x.reason ? `The director said: "${x.reason}"` : 'The director gave no reason.'];
  return [REVIEW_WHY[x.reason] || 'A director\'s confirmation to check.'];
}

function Flag({ f, admin }: { f: AdminMandates['flags'][number]; admin: boolean }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [label, tone] = FLAG[f.kind];
  const waits = f.kind === 'handover' && !!f.identity?.pending;
  const reviewed = f.kind === 'director_review';
  async function resolve(note: string) {
    await rpc('admin_mandate_flag_resolve', { p_id: f.id, p_note: note });
    await qc.invalidateQueries({ queryKey: ['admin-mandates'] });
    toast('Resolved');
  }
  return (
    <div className="card card-pad stack" style={{ gap: 10 }} data-testid="mandate-flag-row">
      <div className="row wrap" style={{ gap: 10, alignItems: 'flex-start' }}>
        <div style={{ flex: '1 1 260px', minWidth: 0 }}>
          <div style={{ fontWeight: 700, fontSize: 16 }}>{f.business?.name || f.intake?.legal_name || 'A prospect'}</div>
          <div className="faint" style={{ fontSize: 13 }}>{f.practice.name} · {when(f.created_at)}</div>
        </div>
        <span className={'chip ' + tone}>{label}</span>
      </div>
      <div className="stack" style={{ gap: 2, fontSize: 14, lineHeight: 1.6 }}>
        {detailLines(f).map((l) => <div key={l}>{l}</div>)}
        {f.kind === 'duplicate_company' && f.detail?.org_id && (admin
          ? <div><Link to={`/admin/businesses/${f.detail.org_id}`}>{f.detail.source === 'owner' ? 'Open the owner\'s own business' : 'Open the business already on Counta'}</Link></div>
          : <div className="faint">{f.detail.source === 'owner' ? 'The owner\'s own business' : 'The business already on Counta'}: {String(f.detail.org_id)}</div>)}
        {f.kind === 'handover' && f.identity && (
          <div className="faint">Identity before the handover: {STATUS_WORD[f.identity.status_before || ''] || 'unknown'}; now {STATUS_WORD[f.identity.status] || f.identity.status}.</div>
        )}
      </div>
      {waits ? (
        <Alert kind="blue" icon="shield">
          Payments stay shut until the handover is decided in the identity review, which resolves this flag when it approves.{' '}
          <Link to="/admin/reviews">Open Identity reviews</Link>
        </Alert>
      ) : reviewed ? (
        <div className="faint" style={{ fontSize: 13 }}>Decided with the confirmation above.</div>
      ) : (
        <Decide placeholder="Note (what you found and did)" actions={[{ label: 'Resolve', tone: 'secondary', run: resolve, testid: 'flag-resolve' }]} />
      )}
    </div>
  );
}

function Practice({ p, admin }: { p: AdminMandates['practices'][number]; admin: boolean }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [open, setOpen] = useState(false);
  const suspended = !!p.suspended_at;
  const act = (on: boolean) => async (note: string) => {
    await rpc('admin_practice_suspend', { p_practice: p.id, p_on: on, p_note: note });
    await qc.invalidateQueries({ queryKey: ['admin-mandates'] });
    setOpen(false);
    toast(on ? `${p.name}'s full mandates are paused` : `${p.name}'s full mandates are resumed`);
  };
  return (
    <div className="stack" style={{ gap: 10, padding: '12px 16px', borderTop: '1px solid var(--row)' }} data-testid="mandate-practice-row">
      <div className="row wrap" style={{ gap: 8, alignItems: 'center' }}>
        <b style={{ flex: '1 1 200px', minWidth: 0 }}>{p.name}</b>
        <span className={'chip ' + (p.partner_verified ? 't-green' : 't-grey')}>{p.partner_verified ? 'Licence verified' : 'No verified licence'}</span>
        <span className="chip t-grey">{p.full_clients} under full mandate</span>
        {suspended && <span className="chip t-red">Paused {when(p.suspended_at)}</span>}
        {admin && !open && (suspended
          ? <button type="button" className="btn btn-secondary btn-sm" onClick={() => setOpen(true)} data-testid="practice-resume">Resume</button>
          : <button type="button" className="btn btn-ghost btn-sm" style={{ color: '#B42318' }} onClick={() => setOpen(true)} data-testid="practice-suspend">Pause full mandates</button>)}
      </div>
      {admin && open && (
        <div className="stack" style={{ gap: 6 }}>
          {!suspended && <div className="faint" style={{ fontSize: 13 }}>Pausing shuts the payments of every business {p.name} runs under full mandate, and it takes on no new one, until you resume. The firm is told the reason.</div>}
          <Decide placeholder={suspended ? 'Why it resumes' : 'Reason (the firm sees it)'}
            actions={[suspended ? { label: 'Resume', tone: 'primary', run: act(false), testid: 'practice-resume-confirm' } : { label: 'Pause them', tone: 'danger', run: act(true), testid: 'practice-suspend-confirm' }]} />
          <div><button type="button" className="btn btn-ghost btn-sm" onClick={() => setOpen(false)}>Cancel</button></div>
        </div>
      )}
    </div>
  );
}

// Domains anyone can have an address on, beyond the built-in list: an address there never counts as the firm's.
function FreeMail({ list }: { list: string[] }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [text, setText] = useState(list.join('\n'));
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function save() {
    setBusy(true); setErr(null);
    try {
      const r = await rpc<{ free_mail_domains: string[] }>('admin_mandate_settings_save', { p: { free_mail_domains: text.split(/[\s,;]+/).map((x) => x.trim()).filter(Boolean) } });
      setText(r.free_mail_domains.join('\n'));
      await qc.invalidateQueries({ queryKey: ['admin-mandates'] });
      toast('Saved');
    } catch (e) { setErr(cleanError(e)); }
    setBusy(false);
  }
  return (
    <Card title="Free-mail domains" sub="Gmail, Yahoo, Outlook and the other big ones are built in. Add any other domain anyone can get an address on: an address there never counts as a firm's own, so a firm cannot use it to look like its client.">
      <textarea className="input mono" rows={5} value={text} onChange={(e) => setText(e.target.value)} placeholder={'one domain per line, e.g.\nmail.example.ng'} aria-label="Free-mail domains" />
      {err && <Alert kind="red" icon="alert"><span role="alert">{err}</span></Alert>}
      <div><button type="button" className="btn btn-primary btn-sm" style={{ minHeight: 40 }} disabled={busy} onClick={save}>{busy ? <Spinner small /> : null}Save the domains</button></div>
    </Card>
  );
}
