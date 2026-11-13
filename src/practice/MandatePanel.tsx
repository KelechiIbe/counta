// A business the firm runs under full mandate, on its client page: the director's confirmation of the wallets, how the
// business sends its documents and where its alerts go, the engagement partner, the handover to the owner, the end of the
// mandate, the export of its records, and what was done in it (its activity log). A full mandate kept read-only after it
// ended without a handover shows only what still applies: the records kept, the export, the engagement partner and the log.
//
// The database decides who may do what; the panel shows each action to whoever may take it: partners and managers ask a
// director and set sending and alerts; partners also hand over, end, export and choose the engagement partner.
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc } from '../lib/supabase';
import { edge } from '../lib/api';
import { fmtDay, when } from '../lib/format';
import { useToast } from '../state/session';
import { Icon } from '../components/Icon';
import { Alert, Field, Spinner } from '../components/ui';
import { ActivityList } from '../components/ActivityList';
import { RecoveryHolderCard } from '../components/RecoveryHolder';
import { Card } from '../admin/ui';
import { type ClientDetail, type Mandate, sendInvite, usePracticeActivity, usePracticeHome } from './api';
import { LETTER_STATUS } from './pages/Letters';

const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const mb = (n: number) => (n >= 1024 * 1024 ? `${(n / 1024 / 1024).toFixed(1)} MB` : `${Math.max(1, Math.round(n / 1024))} KB`);

export function MandatePanel({ d }: { d: ClientDetail }) {
  const m = d.mandate;
  const activity = usePracticeActivity(d.client.id, !!m);
  if (!m) return null;
  const kept = !!m.read_only_at;
  const lead = d.can_lead;
  const partner = d.me.role === 'partner';
  return (
    <div className="stack" style={{ gap: 16 }} data-testid="mandate-panel">
      <Standing d={d} m={m} />
      {!kept && lead && d.client.org_id && <RecoveryHolderCard orgId={d.client.org_id} firm />}
      {!kept && lead && <Director d={d} m={m} />}
      {!kept && lead && <Sending d={d} m={m} />}
      {partner && <EngagementPartner d={d} m={m} />}
      {!kept && partner && <Handover d={d} m={m} />}
      {partner && <Records d={d} />}
      {!kept && partner && <EndMandate d={d} />}
      <section className="card card-pad stack" style={{ gap: 10 }} aria-labelledby="mandate-activity-h" data-testid="mandate-activity">
        <div>
          <h2 id="mandate-activity-h" style={{ fontWeight: 700, fontSize: 15, margin: 0 }}>What was done</h2>
          <div className="muted" style={{ fontSize: 13, marginTop: 4, lineHeight: 1.5 }}>
            Every change the firm made in the business, by whom and when. The owner sees the same record once the business is handed over.
          </div>
        </div>
        <ActivityList q={activity} empty="Nothing has been done in the business yet." />
      </section>
    </div>
  );
}

// Where the mandate stands: payments, the engagement letter, read-only and how long the records are kept.
function Standing({ d, m }: { d: ClientDetail; m: Mandate }) {
  const letter = m.letter;
  const status = letter ? LETTER_STATUS[letter.status] : null;
  return (
    <Card title="Full mandate" sub={m.read_only_at ? undefined : 'The firm runs the business for its owner. Counta sends the owner nothing, and documents carry the firm\'s name, not Counta\'s.'}>
      <div className="stack" style={{ gap: 10, fontSize: 14 }}>
        {m.read_only_at ? (
          <Alert kind="grey" icon="lock">
            Ended without a handover on {fmtDay(m.read_only_at.slice(0, 10))}. The business is read-only{m.retain_until ? ` and its records are kept until ${fmtDay(m.retain_until)}` : ''}.
            Only the engagement partner keeps a place in it.
          </Alert>
        ) : (
          <div className="row wrap" style={{ gap: 8 }}>
            <span className={'chip ' + (m.payments_open ? 't-green' : 't-amber')}>{m.payments_open ? 'Payments open' : 'Payments shut'}</span>
            <span className={'chip ' + (m.director_confirmed_at ? 't-green' : 't-grey')}>{m.director_confirmed_at ? `Director confirmed ${fmtDay(m.director_confirmed_at.slice(0, 10))}` : 'No director confirmation yet'}</span>
            <span className="chip t-grey">{m.send_mode === 'download_only' ? 'Download only' : 'Sends documents'}</span>
          </div>
        )}
        {letter && (
          <div className="row wrap" style={{ gap: 8, alignItems: 'center' }}>
            <span>Engagement letter</span>
            {status && <span className={'chip ' + status[1]}>{status[0]}</span>}
            <Link to={`/practice/${d.client.practice_id}/letters/${letter.id}`} style={{ fontSize: 13 }}>Open it</Link>
          </div>
        )}
      </div>
    </Card>
  );
}

// Payments open only once a director of the company on its CAC record confirms the wallets: the firm picks the director
// from the record and sends the link to their own email, or copies it to send another way. Whoever opens it proves with
// their NIN that they are that director, and a code goes to the phone on their NIN record and their CAC email.
type DirectorState = {
  confirmed_at: string | null; cac: boolean; directors: { name: string; role: string }[];
  latest: { id: string; status: string; name: string; email: string | null; created_at: string; matched_name: string | null; review_reason: string | null;
    decline_reason: string | null; step: 'nin' | 'code' | 'slip' | null; link_live: boolean } | null;
};
const STEP_TEXT: Record<string, string> = { nin: 'has not entered their NIN yet', code: 'has the code and has not entered it yet', slip: 'has no phone or email to get a code: they upload their NIN slip' };

function Director({ d, m }: { d: ClientDetail; m: Mandate }) {
  const qc = useQueryClient();
  const toast = useToast();
  const st = useQuery({ queryKey: ['director-state', d.client.id], staleTime: 15_000,
    queryFn: () => rpc<DirectorState>('practice_director_state', { p_client: d.client.id }) });
  const s = st.data;
  const x = s?.latest;
  const [open, setOpen] = useState(false);
  const [f, setF] = useState({ name: '', email: '' });
  const [link, setLink] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const refresh = () => Promise.all([qc.invalidateQueries({ queryKey: ['practice-client', d.client.id] }), qc.invalidateQueries({ queryKey: ['director-state', d.client.id] })]);
  async function send() {
    setErr(null);
    if (!f.name) { setErr('Choose the director from the CAC record.'); return; }
    if (f.email.trim() && !EMAIL.test(f.email.trim())) { setErr('That email address is not valid.'); return; }
    setBusy('send');
    try {
      const r = await rpc<{ link?: string; sent: boolean; email: string | null }>('practice_director_request', { p_client: d.client.id, p: { name: f.name, email: f.email.trim() || null } });
      await refresh();
      setOpen(false); setF({ name: '', email: '' });
      if (r?.link) setLink(r.link); else toast(`Sent to ${r?.email || 'the director'}`);
    } catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }
  async function newLink() {
    if (!x) return;
    setBusy('link'); setErr(null);
    try {
      const r = await rpc<{ link: string }>('practice_director_link', { p_confirmation: x.id });
      setLink(r.link);
      await refresh();
    } catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }
  async function copy() {
    if (!link) return;
    try { await navigator.clipboard.writeText(link); toast('Link copied'); } catch { toast('Select the link and copy it'); }
  }
  const who = x?.name ? `${x.name}${x.email ? ` (${x.email})` : ''}` : 'The director';
  let state: React.ReactNode;
  let ask: string | null = 'Ask a director';
  if (m.director_confirmed_at) {
    state = <Alert kind="green" icon="check">{x?.status === 'confirmed' && x.name ? `${x.matched_name || x.name} confirmed` : 'A director confirmed'} the wallets on {fmtDay(m.director_confirmed_at.slice(0, 10))}.</Alert>;
    ask = null;
  } else if (x?.status === 'pending') {
    state = <span>Waiting for {who}, who {STEP_TEXT[x.step || 'nin']}. Asked {when(x.created_at)}.</span>;
    ask = 'Ask again';
  } else if (x?.status === 'review') {
    state = <Alert kind="blue" icon="clock">TaxStreem is checking {who}'s confirmation before payments open{x.review_reason === 'no_nin_phone' ? ': NIMC has no phone number for their NIN' : x.review_reason === 'no_channel' ? ': they sent their NIN slip' : ''}. It usually takes a working day.</Alert>;
    ask = null;
  } else if (x?.status === 'declined') {
    state = <Alert kind="amber" icon="alert">{who} declined{x.decline_reason ? `: “${x.decline_reason}”` : ''}. TaxStreem has been told. You can ask again, or ask another director.</Alert>;
    ask = 'Ask again';
  } else {
    state = <span className="muted">No director has been asked yet.</span>;
  }
  if (s && !s.cac && !m.director_confirmed_at) {
    state = <Alert kind="amber" icon="alert">Add the business's CAC record first (open the business, then Settings, Business profile), so Counta knows its directors.</Alert>;
    ask = null;
  }
  return (
    <Card title="The director's confirmation" sub="The business wallet and the tax wallet open only once a director on the CAC record confirms. They prove it with their NIN and a code sent to the phone on their NIN record and their email on the CAC record.">
      <div className="stack" style={{ gap: 10, fontSize: 14 }} data-testid="director-status">{st.isLoading ? <Spinner small /> : state}</div>
      {link && (
        <div className="stack" style={{ gap: 6 }} data-testid="director-link">
          <div style={{ fontSize: 13 }}>Send this link to the director yourself (it works for 14 days, and a new link replaces it):</div>
          <div className="row wrap" style={{ gap: 8 }}>
            <input className="input" readOnly value={link} style={{ flex: '1 1 260px', fontSize: 13 }} onFocus={(e) => e.currentTarget.select()} aria-label="The director's link" />
            <button type="button" className="btn btn-secondary btn-sm" style={{ minHeight: 40 }} onClick={copy} data-testid="director-link-copy"><Icon name="copy" size={14} />Copy</button>
          </div>
        </div>
      )}
      {x?.status === 'pending' && !m.director_confirmed_at && !open && (
        <div><button type="button" className="btn btn-ghost btn-sm" style={{ minHeight: 40 }} disabled={busy === 'link'} onClick={newLink} data-testid="director-new-link">
          {busy === 'link' ? <Spinner small /> : <Icon name="link" size={14} />}Get a new link to send
        </button></div>
      )}
      {ask && !open && (
        <div><button type="button" className="btn btn-secondary btn-sm" style={{ minHeight: 40 }} onClick={() => { setOpen(true); setLink(null); }} data-testid="director-request">
          <Icon name="mail" size={14} />{ask}
        </button></div>
      )}
      {open && (
        <form className="stack" style={{ gap: 10 }} onSubmit={(e) => { e.preventDefault(); void send(); }}>
          <div className="row wrap" style={{ gap: 8 }}>
            <Field label="Director, from the CAC record" style={{ flex: '2 1 240px' }}>
              <select className="input" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} data-testid="director-name">
                <option value="">Choose…</option>
                {(s?.directors || []).map((p) => <option key={p.name + p.role} value={p.name}>{p.name}{p.role === 'owner' ? ' (proprietor)' : ''}</option>)}
              </select>
            </Field>
            <Field label="Their own email (optional)" style={{ flex: '2 1 240px' }}>
              <input className="input" type="email" value={f.email} maxLength={254} autoComplete="off" onChange={(e) => setF({ ...f, email: e.target.value })} data-testid="director-email" />
            </Field>
          </div>
          <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }}>Not an address at the firm. Without an email, you get the link to send yourself. A new request replaces any sent before.</div>
          {err && <Alert kind="red" icon="alert"><span role="alert">{err}</span></Alert>}
          <div className="row wrap" style={{ gap: 8 }}>
            <button className="btn btn-primary btn-sm" disabled={busy === 'send'} data-testid="director-send">{busy === 'send' ? <Spinner small /> : <Icon name="send" size={14} color="#fff" />}{f.email.trim() ? 'Send the request' : 'Get the link'}</button>
            <button type="button" className="btn btn-ghost btn-sm" onClick={() => { setOpen(false); setErr(null); }}>Cancel</button>
          </div>
        </form>
      )}
      {err && !open && <Alert kind="red" icon="alert"><span role="alert">{err}</span></Alert>}
    </Card>
  );
}

// Whether the business sends its documents to its customers, and which of the firm's addresses gets its alerts.
function Sending({ d, m }: { d: ClientDetail; m: Mandate }) {
  const qc = useQueryClient();
  const toast = useToast();
  const home = usePracticeHome(d.client.practice_id);
  const [alert, setAlert] = useState(m.alert_email || '');
  const [busy, setBusy] = useState<string | null>(null);
  const firm = [...new Set([home.data?.practice.email, ...(home.data?.members || []).filter((x) => x.status === 'active').map((x) => x.email)]
    .filter((e): e is string => !!e).map((e) => e.toLowerCase()))];
  async function mode(v: 'send' | 'download_only') {
    if (v === m.send_mode) return;
    setBusy('mode');
    try { await rpc('practice_set_send_mode', { p_client: d.client.id, p_mode: v }); await qc.invalidateQueries({ queryKey: ['practice-client', d.client.id] }); toast('Saved'); }
    catch (e) { toast(cleanError(e), 'err'); }
    setBusy(null);
  }
  async function saveAlert() {
    setBusy('alert');
    try { await rpc('practice_set_alert_email', { p_client: d.client.id, p_email: alert.trim() || null }); await qc.invalidateQueries({ queryKey: ['practice-client', d.client.id] }); toast('Saved'); }
    catch (e) { toast(cleanError(e), 'err'); }
    setBusy(null);
  }
  const OPTS: ['send' | 'download_only', string, string][] = [
    ['send', 'Send documents to customers', 'Invoices, receipts and reminders go to the business\'s customers in the firm\'s name, with no Counta branding.'],
    ['download_only', 'Download only', 'Counta sends nothing. You download each document and send it yourselves.'],
  ];
  return (
    <Card title="Sending and alerts">
      <fieldset className="stack" style={{ gap: 8, border: 0, padding: 0, margin: 0 }} data-testid="send-mode" disabled={busy !== null}>
        <legend style={{ fontWeight: 600, fontSize: 14, marginBottom: 6 }}>Documents</legend>
        {OPTS.map(([v, l, h]) => (
          <label key={v} className="row" style={{ gap: 10, alignItems: 'flex-start', minHeight: 44, cursor: 'pointer' }}>
            <input type="radio" name={`send-mode-${d.client.id}`} checked={m.send_mode === v} onChange={() => mode(v)} style={{ marginTop: 3 }} />
            <span><span style={{ fontSize: 14 }}>{l}</span><span className="faint" style={{ display: 'block', fontSize: 12, lineHeight: 1.5 }}>{h}</span></span>
          </label>
        ))}
      </fieldset>
      <form className="stack" style={{ gap: 6 }} onSubmit={(e) => { e.preventDefault(); void saveAlert(); }}>
        <div className="row wrap" style={{ gap: 8, alignItems: 'flex-end' }}>
          <Field label="Send the business's alerts to" style={{ flex: '0 1 380px' }}>
            <input className="input" type="email" list={`firm-emails-${d.client.id}`} value={alert} maxLength={254} onChange={(e) => setAlert(e.target.value)} data-testid="alert-email" />
          </Field>
          <button className="btn btn-secondary btn-sm" style={{ minHeight: 40 }} disabled={busy !== null || alert.trim() === (m.alert_email || '')} data-testid="alert-email-save">
            {busy === 'alert' ? <Spinner small /> : null}Save
          </button>
        </div>
        <datalist id={`firm-emails-${d.client.id}`}>{firm.map((e) => <option key={e} value={e} />)}</datalist>
        <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }}>One of the firm's addresses. Leave it empty and alerts stay in Counta.</div>
      </form>
    </Card>
  );
}

// The partner or manager answerable for the business. After the mandate ends, theirs is the one place kept.
function EngagementPartner({ d, m }: { d: ClientDetail; m: Mandate }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [busy, setBusy] = useState(false);
  const leads = d.team.filter((t) => t.member.role === 'partner' || t.member.role === 'manager').map((t) => t.member);
  async function pick(id: string) {
    setBusy(true);
    try {
      await rpc('practice_set_engagement_partner', { p_client: d.client.id, p_member: id });
      await qc.invalidateQueries({ queryKey: ['practice-client', d.client.id] });
      toast('Saved');
    } catch (e) { toast(cleanError(e), 'err'); }
    setBusy(false);
  }
  return (
    <Card title="Engagement partner" sub={m.read_only_at ? 'The one person of the firm who keeps a place in the business while its records are kept.' : 'Answerable for the business. If the mandate ends without a handover, theirs is the one place kept.'}>
      <div className="row wrap" style={{ gap: 8, alignItems: 'center' }}>
        <select className="input" style={{ maxWidth: 320 }} value={m.engagement_partner_id || ''} disabled={busy} onChange={(e) => e.target.value && pick(e.target.value)}
          aria-label="Engagement partner" data-testid="engagement-partner">
          {!m.engagement_partner_id && <option value="">Choose a partner or manager</option>}
          {leads.map((x) => <option key={x.id} value={x.id}>{x.display_name} · {x.role === 'partner' ? 'Partner' : 'Manager'}</option>)}
        </select>
        {busy && <Spinner small />}
      </div>
    </Card>
  );
}

// The business handed to the person who will own it. They become the owner; the firm keeps an accountant's place.
function Handover({ d, m }: { d: ClientDetail; m: Mandate }) {
  const qc = useQueryClient();
  const toast = useToast();
  const h = m.handover?.status === 'pending' ? m.handover : null;
  const [open, setOpen] = useState(false);
  const [f, setF] = useState({ name: '', email: '' });
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  async function email(id: string, to: string) {
    const r = await sendInvite('handover', id);
    if (r.ok === false) { setErr(`The handover is saved, but the email to ${to} did not go: ${r.error || 'try sending it again.'}`); return false; }
    toast(`Sent to ${r.sent_to || to}`);
    return true;
  }
  async function start() {
    setErr(null);
    if (f.name.trim().length < 2) { setErr('Enter the name of the person taking the business over.'); return; }
    if (!EMAIL.test(f.email.trim())) { setErr('Enter their email address.'); return; }
    setBusy('start');
    try {
      const r = await rpc<{ id: string }>('practice_handover_start', { p_client: d.client.id, p: { name: f.name.trim(), email: f.email.trim() } });
      const sent = await email(r.id, f.email.trim());
      await qc.invalidateQueries({ queryKey: ['practice-client', d.client.id] });
      if (sent) { setOpen(false); setF({ name: '', email: '' }); }
    } catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }
  async function resend() {
    if (!h) return;
    setErr(null); setBusy('resend');
    try { await email(h.id, h.email || 'them'); await qc.invalidateQueries({ queryKey: ['practice-client', d.client.id] }); } catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }
  return (
    <Card title="Hand the business over" sub="The person you name becomes its owner on Counta and the firm keeps an accountant's place. Unless they are the director who confirmed the wallets, TaxStreem checks the handover before payments open again.">
      {h && !open && (
        <div className="stack" style={{ gap: 8, fontSize: 14 }}>
          <span>Waiting for {h.email || 'the owner'} to accept{h.sent_at ? `, emailed ${when(h.sent_at)}` : ''}. The link works for 14 days.</span>
          <div className="row wrap" style={{ gap: 8 }}>
            <button type="button" className="btn btn-secondary btn-sm" disabled={busy !== null} onClick={resend}>{busy === 'resend' ? <Spinner small /> : <Icon name="send" size={14} />}Send the email again</button>
            <button type="button" className="btn btn-ghost btn-sm" onClick={() => setOpen(true)}>Hand over to someone else</button>
          </div>
        </div>
      )}
      {!h && !open && (
        <div><button type="button" className="btn btn-secondary btn-sm" style={{ minHeight: 40 }} onClick={() => setOpen(true)} data-testid="handover-start">
          <Icon name="users" size={14} />Hand over to the owner
        </button></div>
      )}
      {open && (
        <form className="stack" style={{ gap: 10 }} onSubmit={(e) => { e.preventDefault(); void start(); }}>
          <div className="row wrap" style={{ gap: 8 }}>
            <Field label="Their name" style={{ flex: '1 1 220px' }}>
              <input className="input" value={f.name} maxLength={120} autoComplete="off" onChange={(e) => setF({ ...f, name: e.target.value })} data-testid="handover-name" />
            </Field>
            <Field label="Their own email address" style={{ flex: '1 1 240px' }}>
              <input className="input" type="email" value={f.email} maxLength={254} autoComplete="off" onChange={(e) => setF({ ...f, email: e.target.value })} data-testid="handover-email" />
            </Field>
          </div>
          {h && <div className="faint" style={{ fontSize: 12 }}>The link sent to {h.email} stops working.</div>}
          <div className="row wrap" style={{ gap: 8 }}>
            <button className="btn btn-primary btn-sm" disabled={busy !== null} data-testid="handover-send">{busy === 'start' ? <Spinner small /> : <Icon name="send" size={14} color="#fff" />}Send the handover</button>
            <button type="button" className="btn btn-ghost btn-sm" onClick={() => { setOpen(false); setErr(null); }}>Cancel</button>
          </div>
        </form>
      )}
      {err && <Alert kind="red" icon="alert"><span role="alert">{err}</span></Alert>}
    </Card>
  );
}

// Every record of the business in one file (a ZIP of its tables, ledger and activity log), for a partner.
function Records({ d }: { d: ClientDetail }) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [file, setFile] = useState<{ url: string; sha256: string; bytes: number } | null>(null);
  async function go() {
    setErr(null); setFile(null); setBusy(true);
    const r = await edge<{ url: string; sha256: string; bytes: number }>('practice', { action: 'export', client_id: d.client.id });
    setBusy(false);
    if (r.ok === false || !r.url) { setErr(r.error || 'The export could not be made just now. Try again.'); return; }
    setFile({ url: r.url, sha256: r.sha256, bytes: r.bytes });
  }
  return (
    <Card title="The business's records" sub="Every table, the ledger and the activity log in one file, with private details left out. It can take a minute.">
      <div className="row wrap" style={{ gap: 8, alignItems: 'center' }}>
        <button type="button" className="btn btn-secondary btn-sm" style={{ minHeight: 40 }} disabled={busy} onClick={go} data-testid="export-records">
          {busy ? <><Spinner small />Preparing the file…</> : <><Icon name="download" size={14} />Export the records</>}
        </button>
        {file && <a className="btn btn-primary btn-sm" href={file.url} download rel="noopener noreferrer"><Icon name="download" size={14} color="#fff" />Download ({mb(file.bytes)})</a>}
      </div>
      {file && <div className="faint" style={{ fontSize: 12, lineHeight: 1.5, wordBreak: 'break-all' }}>The download link works for 10 minutes. SHA-256 {file.sha256}</div>}
      {err && <Alert kind="red" icon="alert"><span role="alert">{err}</span></Alert>}
    </Card>
  );
}

// The end of the mandate without a handover: refused while either wallet holds money or a payment is moving.
function EndMandate({ d }: { d: ClientDetail }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [failed, setFailed] = useState(0);
  const refresh = () => Promise.all([qc.invalidateQueries({ queryKey: ['practice-client', d.client.id] }), qc.invalidateQueries({ queryKey: ['practice-home'] }),
    qc.invalidateQueries({ queryKey: ['practice-activity', d.client.id] })]);
  async function end() {
    setErr(null); setBusy('end');
    const r = await edge<{ retain_until: string | null; feeds?: { unlinked: number; failed: number } }>('practice', { action: 'end_mandate', client_id: d.client.id, reason: reason.trim() });
    setBusy(null);
    if (r.ok === false) { setErr(r.error || 'The mandate could not be ended just now.'); return; }
    const n = r.feeds?.failed || 0;
    setFailed(n);
    toast(`Ended. The business is read-only${r.retain_until ? ` and kept until ${fmtDay(r.retain_until)}` : ''}.`);
    if (!n) await refresh();
  }
  async function retry() {
    setErr(null); setBusy('feeds');
    const r = await edge<{ feeds: { unlinked: number; failed: number } }>('practice', { action: 'unlink_feeds', client_id: d.client.id });
    setBusy(null);
    if (r.ok === false) { setErr(r.error || 'The bank feeds could not be unlinked just now.'); return; }
    setFailed(r.feeds?.failed || 0);
    if (!r.feeds?.failed) { toast('The bank feeds are unlinked.'); await refresh(); }
  }
  if (failed) return (
    <Card title="Bank feeds still linked">
      <Alert kind="amber" icon="alert">The mandate ended, but {failed === 1 ? 'one bank feed' : `${failed} bank feeds`} could not be unlinked at the bank's provider. Try again; nothing more is read from them meanwhile.</Alert>
      {err && <Alert kind="red" icon="alert"><span role="alert">{err}</span></Alert>}
      <div className="row wrap" style={{ gap: 8 }}>
        <button type="button" className="btn btn-primary btn-sm" disabled={busy !== null} onClick={retry}>{busy === 'feeds' ? <Spinner small /> : <Icon name="refresh" size={14} color="#fff" />}Unlink them again</button>
        <button type="button" className="btn btn-ghost btn-sm" onClick={() => { setFailed(0); void refresh(); }}>Later</button>
      </div>
    </Card>
  );
  return (
    <Card title="End the mandate" sub="Without a handover the business becomes read-only and its records are kept as long as the letter says, at least five years. Its connections pause, bank feeds unlink, its plan stops at the end of its period, and only the engagement partner keeps a place. Move the money out of both wallets first.">
      {!open ? (
        <div><button type="button" className="btn btn-secondary btn-sm" style={{ minHeight: 40, color: 'var(--red, #B42318)' }} onClick={() => setOpen(true)} data-testid="end-mandate">End the mandate for {d.client.business_name}</button></div>
      ) : (
        <form className="stack" style={{ gap: 10 }} onSubmit={(e) => { e.preventDefault(); void end(); }}>
          <Field label="Why it ends" hint="At least 10 characters. It goes in the business's activity log.">
            <textarea className="input" rows={3} maxLength={1000} value={reason} onChange={(e) => setReason(e.target.value)} data-testid="end-mandate-reason" />
          </Field>
          {err && <Alert kind="red" icon="alert"><span role="alert">{err}</span></Alert>}
          <div className="row wrap" style={{ gap: 8 }}>
            <button className="btn btn-danger btn-sm" disabled={busy !== null || reason.trim().length < 10} data-testid="end-mandate-confirm">
              {busy === 'end' ? <Spinner small /> : null}End it and keep the records
            </button>
            <button type="button" className="btn btn-ghost btn-sm" onClick={() => { setOpen(false); setErr(null); }}>Keep running it</button>
          </div>
        </form>
      )}
    </Card>
  );
}
