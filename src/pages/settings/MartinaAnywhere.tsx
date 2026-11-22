// Martina beyond the app: on WhatsApp (TaxStreem's number) and on Siri (an iPhone shortcut). Each person links their own
// WhatsApp number or makes their own shortcut key, for this business; Martina then acts as them, within their role.
import { useEffect, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { rpc, SUPABASE_URL } from '../../lib/supabase';
import { can, useInventory, useSession, useToast } from '../../state/session';
import { fmtDay, when } from '../../lib/format';
import { Icon } from '../../components/Icon';
import { Alert, Field, Spinner } from '../../components/ui';

type Link = { id: string; channel: 'whatsapp' | 'siri'; status: 'pending' | 'active'; label: string | null; phone: string | null; key_last4: string | null;
  linked_at: string | null; last_used_at: string | null; person?: string };
type Mine = { links: Link[]; whatsapp: { ready: boolean; number: string | null }; martina: boolean; team_links: number | null };

const pretty = (digits: string | null) => (digits ? `+${digits.slice(0, 3)} ${digits.slice(3, 6)} ${digits.slice(6, 9)} ${digits.slice(9)}`.trim() : '');

export function useChatLinks() {
  const { orgId } = useSession();
  return useQuery({ queryKey: ['chat-links', orgId], enabled: !!orgId, queryFn: () => rpc<Mine>('chat_links_mine', { p_org: orgId }) });
}

function WhatsAppLink({ data }: { data: Mine }) {
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const [phone, setPhone] = useState('');
  const [busy, setBusy] = useState(false);
  const [code, setCode] = useState<{ code: string; wa_link: string; number: string; at: number } | null>(null);
  const linked = data.links.filter((l) => l.channel === 'whatsapp' && l.status === 'active');
  // While a code waits, look every few seconds for the link to go live.
  useEffect(() => {
    if (!code) return;
    const t = setInterval(() => { void qc.invalidateQueries({ queryKey: ['chat-links', orgId] }); if (Date.now() - code.at > 15 * 60_000) setCode(null); }, 4000);
    return () => clearInterval(t);
  }, [code, orgId, qc]);
  useEffect(() => {
    if (code && linked.some((l) => l.linked_at && Date.parse(l.linked_at) >= code.at - 5000)) { setCode(null); toast('Linked. Martina is on your WhatsApp.'); }
  }, [linked, code, toast]);
  async function start() {
    setBusy(true);
    try {
      const r = await rpc<{ code: string; wa_link: string; number: string }>('chat_whatsapp_start', { p_org: orgId, p_phone: phone });
      setCode({ ...r, at: Date.now() });
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  async function remove(id: string) {
    try { await rpc('chat_link_revoke', { p_link: id }); await qc.invalidateQueries({ queryKey: ['chat-links', orgId] }); toast('Unlinked'); }
    catch (e) { toast((e as Error).message, 'err'); }
  }
  if (!data.whatsapp.ready) {
    return <Alert kind="grey" icon="info">Martina is not on WhatsApp yet. TaxStreem is connecting its number; this is where you will link yours.</Alert>;
  }
  return (
    <div className="stack" style={{ gap: 10 }} data-testid="wa-link">
      <div className="ink3" style={{ fontSize: 13.5, lineHeight: 1.55 }}>
        Chat with Martina on WhatsApp at <b>{pretty(data.whatsapp.number)}</b>, by text or voice note. Ask how sales are going, who owes you or what is running low. She records sales, raises invoices and quotes, confirms orders, updates deliveries, moves stock between branches, answers the questions in the books inbox and approves tax returns with your approval PIN, each after she reads it back and you answer yes. Send her a photo of a supplier&apos;s invoice and it becomes a bill to check; send a product photo and she adds it to your products. She never sends money: payouts and tax payments open in Counta for you to approve.
        {' '}Counta also sends your alerts to this chat, and the daily report below if you want it.
      </div>
      {linked.map((l) => (
        <div key={l.id} className="row wrap" style={{ gap: 10, alignItems: 'center' }}>
          <span className="chip t-green">Linked</span><b className="mono">{l.phone}</b>
          <span className="faint" style={{ fontSize: 12 }}>{l.last_used_at ? `last used ${when(l.last_used_at)}` : `linked ${when(l.linked_at)}`}</span>
          <button className="btn btn-ghost btn-sm" onClick={() => remove(l.id)}>Unlink</button>
        </div>
      ))}
      {code ? (
        <div className="card card-pad stack" style={{ gap: 10, background: 'var(--row)' }}>
          <div style={{ fontSize: 14 }}>From the phone with that number, send this to <b>{pretty(code.number)}</b> within 15 minutes:</div>
          <div className="mono" style={{ fontSize: 26, letterSpacing: '.12em', fontWeight: 700 }} data-testid="wa-code">LINK {code.code}</div>
          <div className="row wrap" style={{ gap: 8, alignItems: 'center' }}>
            <a className="btn btn-primary btn-sm" href={code.wa_link} target="_blank" rel="noreferrer"><Icon name="wa" size={14} color="#fff" />Open WhatsApp</a>
            <span className="faint" style={{ fontSize: 12 }}><Spinner small /> Waiting for your message…</span>
            <button className="btn btn-ghost btn-sm" onClick={() => setCode(null)}>Cancel</button>
          </div>
        </div>
      ) : (
        <div className="row wrap" style={{ gap: 8, alignItems: 'flex-end' }}>
          <Field label={linked.length ? 'Link another number' : 'Your WhatsApp number'} style={{ maxWidth: 240 }}>
            <input className="input" inputMode="tel" placeholder="0803 123 4567" value={phone} onChange={(e) => setPhone(e.target.value)} aria-label="Your WhatsApp number" />
          </Field>
          <button className="btn btn-secondary" disabled={busy || phone.replace(/\D/g, '').length < 10} onClick={start}>{busy ? <Spinner small /> : <Icon name="wa" size={16} />}Get a code</button>
        </div>
      )}
      <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }}>Send UNLINK to Martina at any time to stop. Never send passwords or card details on WhatsApp; Martina never asks for them.</div>
    </div>
  );
}

function SiriKeys({ data }: { data: Mine }) {
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const [label, setLabel] = useState('My iPhone');
  const [busy, setBusy] = useState(false);
  const [key, setKey] = useState<string | null>(null);
  const keys = data.links.filter((l) => l.channel === 'siri' && l.status === 'active');
  const url = `${SUPABASE_URL}/functions/v1/chat/siri?format=text`;
  async function make() {
    setBusy(true);
    try { const r = await rpc<{ key: string }>('chat_siri_key', { p_org: orgId, p_label: label }); setKey(r.key); await qc.invalidateQueries({ queryKey: ['chat-links', orgId] }); }
    catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  async function remove(id: string) {
    try { await rpc('chat_link_revoke', { p_link: id }); await qc.invalidateQueries({ queryKey: ['chat-links', orgId] }); toast('Key removed. Shortcuts using it stop working.'); }
    catch (e) { toast((e as Error).message, 'err'); }
  }
  const copy = (t: string, what: string) => navigator.clipboard?.writeText(t).then(() => toast(`${what} copied`));
  return (
    <div className="stack" style={{ gap: 10 }} data-testid="siri">
      <div className="ink3" style={{ fontSize: 13.5, lineHeight: 1.55 }}>
        On an iPhone, a shortcut lets you say <b>"Hey Siri, Ask Martina"</b> and talk to her without opening Counta. It uses a key that is yours alone, for this business. Apple does not offer iMessage to businesses in Nigeria, so this is how Martina reaches iPhones.
      </div>
      {keys.map((k) => (
        <div key={k.id} className="row wrap" style={{ gap: 10, alignItems: 'center' }}>
          <span className="chip t-blue">Key</span><b>{k.label}</b><span className="mono faint">…{k.key_last4}</span>
          <span className="faint" style={{ fontSize: 12 }}>{k.last_used_at ? `last used ${when(k.last_used_at)}` : 'not used yet'}</span>
          <button className="btn btn-ghost btn-sm" onClick={() => remove(k.id)}>Remove</button>
        </div>
      ))}
      {key ? (
        <div className="card card-pad stack" style={{ gap: 10, background: 'var(--row)' }}>
          <Alert kind="amber" icon="lock">Copy the key now. Counta keeps only a fingerprint of it, so it cannot be shown again. Anyone with it can talk to Martina as you.</Alert>
          <div className="row" style={{ gap: 6, minWidth: 0 }}>
            <code className="mono" data-testid="siri-key" style={{ fontSize: 12.5, wordBreak: 'break-all', flex: 1 }}>{key}</code>
            <button className="btn btn-secondary btn-sm" onClick={() => copy(key, 'Key')}><Icon name="copy" size={14} />Copy</button>
          </div>
          <ol style={{ margin: 0, paddingLeft: 18, fontSize: 13, lineHeight: 1.7 }}>
            <li>On the iPhone, open <b>Shortcuts</b>, tap <b>+</b> and name it <b>Ask Martina</b>.</li>
            <li>Add <b>Dictate Text</b>.</li>
            <li>Add <b>Get Contents of URL</b>. Set the URL to the address below, Method to <b>POST</b>, add a header <b>Authorization</b> with the value <b>Bearer</b>, a space and your key, and set Request Body to <b>File</b> with <b>Dictated Text</b>.</li>
            <li>Add <b>Speak Text</b> with <b>Contents of URL</b>.</li>
            <li>Say <b>"Hey Siri, Ask Martina"</b>, then what you need.</li>
          </ol>
          <div className="row" style={{ gap: 6, minWidth: 0 }}>
            <code className="mono ellipsis" style={{ fontSize: 12, flex: 1, minWidth: 0 }}>{url}</code>
            <button className="btn btn-secondary btn-sm" onClick={() => copy(url, 'Address')}><Icon name="copy" size={14} />Copy</button>
          </div>
          <div><button className="btn btn-ghost btn-sm" onClick={() => setKey(null)}>Done</button></div>
        </div>
      ) : (
        <div className="row wrap" style={{ gap: 8, alignItems: 'flex-end' }}>
          <Field label="Name the device" style={{ maxWidth: 240 }}>
            <input className="input" maxLength={60} value={label} onChange={(e) => setLabel(e.target.value)} aria-label="Name the device" />
          </Field>
          <button className="btn btn-secondary" disabled={busy || !label.trim()} onClick={make}>{busy ? <Spinner small /> : <Icon name="mic" size={16} />}Make a shortcut key</button>
        </div>
      )}
    </div>
  );
}

// Everyone's links, for whoever manages the team: someone who leaves is cut off here (or by disabling them on the team).
function TeamLinks() {
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const q = useQuery({ queryKey: ['chat-links-team', orgId], enabled: !!orgId, queryFn: () => rpc<Link[]>('chat_links_team', { p_org: orgId }) });
  if (!q.data?.length) return null;
  async function remove(id: string) {
    try { await rpc('chat_link_revoke', { p_link: id }); await qc.invalidateQueries({ queryKey: ['chat-links-team', orgId] }); await qc.invalidateQueries({ queryKey: ['chat-links', orgId] }); toast('Removed'); }
    catch (e) { toast((e as Error).message, 'err'); }
  }
  return (
    <div className="stack" style={{ gap: 6 }}>
      <div className="field-label">Everyone using Martina outside Counta</div>
      {q.data.map((l) => (
        <div key={l.id} className="row wrap" style={{ gap: 10, alignItems: 'center', fontSize: 13 }}>
          <b>{l.person}</b><span className="faint">{l.channel === 'whatsapp' ? `WhatsApp ${l.phone}` : `Siri, ${l.label} …${l.key_last4}`}</span>
          <span className="faint" style={{ fontSize: 12 }}>{l.last_used_at ? `last used ${when(l.last_used_at)}` : 'not used yet'}</span>
          <button className="btn btn-ghost btn-sm" onClick={() => remove(l.id)}>Remove</button>
        </div>
      ))}
    </div>
  );
}

type PinStatus = { set: boolean; set_at: string | null; last_used_at: string | null; locked_until: string | null };

// The six digits Martina asks for before she files a tax return on WhatsApp. Counta keeps only a hash of it.
function ApprovalPin() {
  const toast = useToast();
  const qc = useQueryClient();
  const q = useQuery({ queryKey: ['approval-pin'], queryFn: () => rpc<PinStatus>('approval_pin_status') });
  const [open, setOpen] = useState(false);
  const [pin, setPin] = useState('');
  const [again, setAgain] = useState('');
  const [busy, setBusy] = useState(false);
  const digits = (v: string) => v.replace(/\D/g, '').slice(0, 6);
  async function save() {
    if (pin !== again) { toast('The two PINs are different. Type it again.', 'err'); return; }
    setBusy(true);
    try { qc.setQueryData(['approval-pin'], await rpc<PinStatus>('set_approval_pin', { p_pin: pin })); setOpen(false); setPin(''); setAgain(''); toast('Approval PIN saved'); }
    catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  async function clear() {
    try { qc.setQueryData(['approval-pin'], await rpc<PinStatus>('clear_approval_pin')); toast('Approval PIN removed. Tax returns are approved in Counta only.'); }
    catch (e) { toast((e as Error).message, 'err'); }
  }
  const st = q.data;
  if (!st) return q.isLoading ? <Spinner small /> : null;
  return (
    <div className="stack" style={{ gap: 10 }} data-testid="approval-pin">
      <div className="ink3" style={{ fontSize: 13.5, lineHeight: 1.55 }}>
        Martina files a tax return from WhatsApp only after you type this PIN in the chat as a message on its own. It is yours alone; Counta keeps only a scrambled copy, and five wrong tries lock it for an hour.
      </div>
      {st.locked_until && <Alert kind="amber" icon="lock">Locked after too many wrong tries until {when(st.locked_until)}. Approve returns in Counta until then, or set a new PIN.</Alert>}
      {st.set && !open && (
        <div className="row wrap" style={{ gap: 10, alignItems: 'center' }}>
          <span className="chip t-green">PIN set</span>
          <span className="faint" style={{ fontSize: 12 }}>{st.last_used_at ? `last used ${when(st.last_used_at)}` : `set ${when(st.set_at)}`}</span>
          <button className="btn btn-ghost btn-sm" onClick={() => setOpen(true)}>Change</button>
          <button className="btn btn-ghost btn-sm" onClick={clear}>Remove</button>
        </div>
      )}
      {(open || !st.set) && (
        <div className="row wrap" style={{ gap: 8, alignItems: 'flex-end' }}>
          <Field label={st.set ? 'New PIN' : 'Choose a six-digit PIN'} style={{ maxWidth: 180 }}>
            <input className="input mono" type="password" inputMode="numeric" autoComplete="new-password" value={pin} onChange={(e) => setPin(digits(e.target.value))} aria-label="Approval PIN" />
          </Field>
          <Field label="Type it again" style={{ maxWidth: 180 }}>
            <input className="input mono" type="password" inputMode="numeric" autoComplete="new-password" value={again} onChange={(e) => setAgain(digits(e.target.value))} aria-label="Approval PIN again" />
          </Field>
          <button className="btn btn-secondary" disabled={busy || pin.length !== 6 || again.length !== 6} onClick={save}>{busy ? <Spinner small /> : <Icon name="lock" size={16} />}Save PIN</button>
          {st.set && <button className="btn btn-ghost" onClick={() => { setOpen(false); setPin(''); setAgain(''); }}>Cancel</button>}
        </div>
      )}
    </div>
  );
}

type ReportPrefs = { enabled: boolean; hour: number; email: boolean; whatsapp: boolean; explicit: boolean; allowed: boolean; parts: string[]; email_to: string | null;
  whatsapp_linked: boolean; last: { day: string; status: string; channels: string[] | null; at: string; error: string | null } | null };
const PART: Record<string, string> = { sales: 'sales', money: 'money in and out', orders: 'orders and deliveries', stock: 'stock', books: 'the books', tax: 'tax coming due', people: 'who did what' };
const hourWords = (h: number) => `${h === 12 ? 12 : h % 12}:00 ${h < 12 ? 'am' : 'pm'}`;

// The day's activity as a PDF, each evening by WhatsApp and email. Each person chooses for themselves.
function DailyReport() {
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const q = useQuery({ queryKey: ['daily-report', orgId], enabled: !!orgId, queryFn: () => rpc<ReportPrefs>('get_daily_report_prefs', { p_org: orgId }) });
  const p = q.data;
  if (!p) return q.isLoading ? <Spinner small /> : null;
  if (!p.allowed) return <div className="faint" style={{ fontSize: 13 }}>Daily reports are not sent for this business.</div>;
  async function save(change: Partial<ReportPrefs>) {
    const before = p!;
    const next = { enabled: p!.enabled, hour: p!.hour, email: p!.email, whatsapp: p!.whatsapp, ...change };
    // Shown as chosen at once; put back if saving fails.
    qc.setQueryData(['daily-report', orgId], { ...before, ...change });
    try { qc.setQueryData(['daily-report', orgId], await rpc<ReportPrefs>('save_daily_report_prefs', { p_org: orgId, p: next })); }
    catch (e) { qc.setQueryData(['daily-report', orgId], before); toast((e as Error).message, 'err'); }
  }
  const parts = p.parts.map((k) => PART[k] || k);
  return (
    <div className="stack" style={{ gap: 10 }} data-testid="daily-report">
      <div className="ink3" style={{ fontSize: 13.5, lineHeight: 1.55 }}>
        Each evening Counta sends you a short PDF of the day: {parts.length > 1 ? `${parts.slice(0, -1).join(', ')} and ${parts[parts.length - 1]}` : parts[0] || 'what your role sees'}. A day with nothing recorded is skipped. You can also ask Martina on WhatsApp for any day&apos;s report.
      </div>
      <label className="check" style={{ fontSize: 13.5 }}>
        <input type="checkbox" checked={p.enabled} onChange={(e) => save({ enabled: e.target.checked })} aria-label="Send me the daily report" /> Send me the daily report
      </label>
      {p.enabled && (
        <div className="row wrap" style={{ gap: 14, alignItems: 'center' }}>
          <Field label="At" style={{ maxWidth: 130 }}>
            <select className="input" value={p.hour} onChange={(e) => save({ hour: Number(e.target.value) })} aria-label="Time of the daily report">
              {Array.from({ length: 17 }, (_, i) => i + 6).map((h) => <option key={h} value={h}>{hourWords(h)}</option>)}
            </select>
          </Field>
          <label className="check" style={{ fontSize: 13 }}>
            <input type="checkbox" checked={p.whatsapp} onChange={(e) => save({ whatsapp: e.target.checked })} /> On WhatsApp{!p.whatsapp_linked && <span className="faint"> (link your number above first)</span>}
          </label>
          <label className="check" style={{ fontSize: 13 }}>
            <input type="checkbox" checked={p.email} onChange={(e) => save({ email: e.target.checked })} /> By email{p.email_to ? <span className="faint"> to {p.email_to}</span> : null}
          </label>
        </div>
      )}
      {p.last && (
        <div className="faint" style={{ fontSize: 12 }}>
          Last report, for {fmtDay(p.last.day)}: {p.last.status === 'sent' ? `sent ${when(p.last.at)}${p.last.channels?.length ? ` by ${p.last.channels.map((c) => (c === 'whatsapp' ? 'WhatsApp' : 'email')).join(' and ')}` : ''}`
            : p.last.status === 'empty' ? 'nothing was recorded that day' : p.last.status === 'failed' ? `not sent (${p.last.error || 'it failed'})` : 'on its way'}.
        </div>
      )}
    </div>
  );
}

export function MartinaAnywhere() {
  const { data: inv } = useInventory();
  const q = useChatLinks();
  if (!q.data) return q.isLoading ? <Spinner /> : <Alert kind="red" icon="alert">{(q.error as Error)?.message || 'Could not load this.'}</Alert>;
  if (!q.data.martina) return <Alert kind="grey" icon="info">Martina is paused for this business, so she is not on WhatsApp or Siri either.</Alert>;
  return (
    <div className="stack" style={{ gap: 18 }}>
      <div className="stack" style={{ gap: 8 }}><div className="field-label"><Icon name="wa" size={14} /> WhatsApp</div><WhatsAppLink data={q.data} /></div>
      <div className="stack" style={{ gap: 8 }}><div className="field-label"><Icon name="lock" size={14} /> Approval PIN for tax returns</div><ApprovalPin /></div>
      <div className="stack" style={{ gap: 8 }}><div className="field-label"><Icon name="file" size={14} /> Daily report</div><DailyReport /></div>
      <div className="stack" style={{ gap: 8 }}><div className="field-label"><Icon name="mic" size={14} /> Siri on iPhone</div><SiriKeys data={q.data} /></div>
      {can(inv, 'manage_team') && <TeamLinks />}
    </div>
  );
}
