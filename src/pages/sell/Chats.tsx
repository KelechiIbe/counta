// Customer chats: a business's customers on WhatsApp. When a customer writes back to a document, receipt or order Counta
// sent them (on TaxStreem's number, or the business's own when it chose that), Martina answers for the business from its
// records: what they owe, its products, an order, a word that they paid. Anything she cannot settle comes here for a person,
// with a push to everyone who records sales. A reply from here goes to the customer on WhatsApp, and Martina then stays
// quiet in that chat for twelve hours so the two do not talk over each other.
import { useEffect, useRef, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { can, useInventory, useSession, useToast } from '../../state/session';
import { cleanError, rpc, signedDoc } from '../../lib/supabase';
import { edge } from '../../lib/api';
import { fmtTime, when } from '../../lib/format';
import { Icon } from '../../components/Icon';
import { Alert, Drawer, Empty, Pills, SkeletonRows, Spinner } from '../../components/ui';

type Chat = { id: string; customer_id: string | null; name: string | null; phone: string; via: 'counta' | 'own'; status: 'open' | 'needs_reply' | 'closed';
  last_at: string; last_text: string | null; unread: number; paused: boolean; handed_reason: string | null };
type Settings = { on: boolean; own_number: boolean; own_linked: boolean };
type List = { chats: Chat[]; settings: Settings; can_change: boolean };
type Turn = { id: number; role: 'customer' | 'martina' | 'team'; text: string; at: string; media_path: string | null; by: string | null };
type Thread = { chat: Omit<Chat, 'last_text' | 'unread' | 'paused'> & { paused_until: string | null }; turns: Turn[] };

const STATUS: Record<Chat['status'], [string, string]> = { needs_reply: ['Needs a reply', 't-amber'], open: ['Open', 't-blue'], closed: ['Done', 't-grey'] };

function ChatSettings({ s: saved, onClose }: { s: Settings; onClose: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const [busy, setBusy] = useState(false);
  // Shown as chosen at once; put back if saving fails.
  const [s, setS] = useState(saved);
  async function save(change: Partial<Settings>) {
    setBusy(true);
    const before = s;
    setS({ ...s, ...change });
    try {
      await rpc('save_customer_chat_settings', { p_org: orgId, p: { on: s.on, own_number: s.own_number, ...change } });
      // The business's own number sends its customers' messages here only once its webhooks say so.
      if (change.own_number && s.own_linked) {
        const r = await edge('messaging', { action: 'wa_hooks', org_id: orgId });
        if (r.ok === false) toast(r.error || 'Saved, but the WhatsApp number could not be updated. Try again.', 'err');
      }
      await qc.invalidateQueries({ queryKey: ['customer-chats', orgId] });
    } catch (e) { setS(before); toast(cleanError(e), 'err'); }
    setBusy(false);
  }
  return (
    <div className="card card-pad stack" style={{ gap: 10 }} data-testid="chat-settings">
      <label className="check" style={{ fontSize: 13.5 }}>
        <input type="checkbox" checked={s.on} disabled={busy} onChange={(e) => save({ on: e.target.checked })} /> Martina answers customers who write back on WhatsApp
      </label>
      <div className="faint" style={{ fontSize: 12.5, lineHeight: 1.5, marginTop: -4 }}>
        Switched off, every message comes here for a person to answer.
      </div>
      <label className="check" style={{ fontSize: 13.5 }}>
        <input type="checkbox" checked={s.own_number} disabled={busy || (!s.own_linked && !s.own_number)} onChange={(e) => save({ own_number: e.target.checked })} /> Also on the business&apos;s own WhatsApp number
      </label>
      <div className="faint" style={{ fontSize: 12.5, lineHeight: 1.5, marginTop: -4 }}>
        {s.own_linked ? 'Martina answers anyone who writes to your linked number, and leaves the chat to you when you reply from here.'
          : 'Link your own number in Integrations, WhatsApp first. Until then, customers reach Martina on TaxStreem\'s number when they write back to what Counta sent them.'}
      </div>
      <div><button className="btn btn-ghost btn-sm" onClick={onClose}>Done</button></div>
    </div>
  );
}

function Photo({ path }: { path: string }) {
  const [busy, setBusy] = useState(false);
  async function open() {
    setBusy(true);
    const u = await signedDoc(path);
    setBusy(false);
    if (u) window.open(u, '_blank', 'noopener');
  }
  return <button className="btn btn-ghost btn-xs" onClick={open} disabled={busy}>{busy ? <Spinner small /> : <Icon name="file" size={12} />}Open the picture</button>;
}

function ChatDrawer({ id, onClose }: { id: string; onClose: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const q = useQuery({ queryKey: ['customer-chat', id], queryFn: () => rpc<Thread>('get_customer_chat', { p_chat: id }), refetchInterval: 10_000 });
  const [text, setText] = useState('');
  const [busy, setBusy] = useState(false);
  const end = useRef<HTMLDivElement>(null);
  const turns = q.data?.turns || [];
  useEffect(() => { end.current?.scrollIntoView({ block: 'end' }); }, [turns.length]);
  useEffect(() => { void qc.invalidateQueries({ queryKey: ['customer-chats', orgId] }); void qc.invalidateQueries({ queryKey: ['attention'] }); }, [q.dataUpdatedAt, orgId, qc]);
  async function send() {
    setBusy(true);
    try {
      const r = await rpc<{ ok: boolean; status: string; error: string | null }>('customer_chat_reply', { p_chat: id, p_text: text });
      if (r.status === 'failed') toast(`Not sent: ${r.error || 'WhatsApp did not take it'}`, 'err'); else setText('');
      await q.refetch();
    } catch (e) { toast(cleanError(e), 'err'); }
    setBusy(false);
  }
  async function set(p: Record<string, string>, done: string) {
    try { qc.setQueryData(['customer-chat', id], await rpc<Thread>('customer_chat_set', { p_chat: id, p })); toast(done); }
    catch (e) { toast(cleanError(e), 'err'); }
  }
  const c = q.data?.chat;
  return (
    <Drawer onClose={onClose} width={560}>
      <div className="drawer-hd row" style={{ justifyContent: 'space-between', gap: 10 }}>
        <div style={{ minWidth: 0 }}>
          <div style={{ fontWeight: 600, fontSize: 16 }} className="ellipsis">{c?.name || c?.phone || 'Customer'}</div>
          {c && <div className="faint" style={{ fontSize: 12 }}>{c.phone} · {c.via === 'own' ? 'your WhatsApp number' : 'TaxStreem\'s WhatsApp number'}</div>}
        </div>
        <button className="x-btn" onClick={onClose} aria-label="Close"><Icon name="x" size={18} /></button>
      </div>
      {!q.data ? (q.isError ? <div style={{ padding: 16 }}><Alert kind="red" icon="alert">{cleanError(q.error)}</Alert></div> : <SkeletonRows n={6} />) : (
        <div className="stack" style={{ gap: 0, flex: 1, minHeight: 0 }}>
          {c!.status === 'needs_reply' && c!.handed_reason && (
            <div style={{ padding: '12px 16px 0' }}><Alert kind="amber" icon="info">Martina passed this to the team: {c!.handed_reason}</Alert></div>
          )}
          <div style={{ flex: 1, overflowY: 'auto', padding: 16, display: 'flex', flexDirection: 'column', gap: 10, background: '#FAFAFA' }} data-testid="chat-turns">
            {turns.map((t) => {
              const ours = t.role !== 'customer';
              return (
                <div key={t.id} style={{ alignSelf: ours ? 'flex-end' : 'flex-start', maxWidth: '84%' }}>
                  <div style={{ background: t.role === 'team' ? '#0072F5' : '#fff', color: t.role === 'team' ? '#fff' : '#111827', border: t.role === 'team' ? 0 : '1px solid #E6E6E6',
                    borderRadius: 12, padding: '8px 12px', fontSize: 13.5, lineHeight: 1.5, whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>
                    {t.text}
                    {t.media_path && <div style={{ marginTop: 6 }}><Photo path={t.media_path} /></div>}
                  </div>
                  <div className="faint" style={{ fontSize: 10.5, marginTop: 3, textAlign: ours ? 'right' : 'left' }}>
                    {t.role === 'martina' ? 'Martina' : t.role === 'team' ? (t.by || 'Your team') : (c!.name || 'Customer')} · {fmtTime(t.at)}
                  </div>
                </div>
              );
            })}
            {!turns.length && <Empty>No messages yet.</Empty>}
            <div ref={end} />
          </div>
          <div className="stack" style={{ gap: 8, padding: 16, borderTop: '1px solid var(--row)' }}>
            <textarea className="input" rows={3} maxLength={2000} placeholder={`Reply to ${c!.name || 'the customer'} on WhatsApp`} value={text} onChange={(e) => setText(e.target.value)}
              aria-label="Reply on WhatsApp" />
            <div className="row wrap" style={{ gap: 8, justifyContent: 'space-between' }}>
              <div className="row wrap" style={{ gap: 6 }}>
                {c!.paused_until
                  ? <button className="btn btn-ghost btn-sm" onClick={() => set({ martina: 'resume' }, 'Martina answers this chat again')}>Hand back to Martina</button>
                  : <button className="btn btn-ghost btn-sm" onClick={() => set({ martina: 'pause' }, 'Martina stays out of this chat for a week')}>Keep Martina out</button>}
                {c!.status === 'closed'
                  ? <button className="btn btn-ghost btn-sm" onClick={() => set({ status: 'open' }, 'Reopened')}>Reopen</button>
                  : <button className="btn btn-ghost btn-sm" onClick={() => set({ status: 'closed' }, 'Marked done')}>Mark done</button>}
              </div>
              <button className="btn btn-primary btn-sm" disabled={busy || !text.trim()} onClick={send} data-testid="chat-send">
                {busy ? <Spinner small /> : <Icon name="send" size={14} color="#fff" />}Send on WhatsApp</button>
            </div>
            <div className="faint" style={{ fontSize: 11.5 }}>
              {c!.paused_until ? `Martina is staying out of this chat until ${when(c!.paused_until)}.` : 'When you reply, Martina stays out of this chat for twelve hours.'}
            </div>
          </div>
        </div>
      )}
    </Drawer>
  );
}

export default function Chats() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const [tab, setTab] = useState<'waiting' | 'all'>('waiting');
  // A notification or the books inbox opens a chat with ?open=<chat id>.
  const [params, setParams] = useSearchParams();
  const [open, setOpenState] = useState<string | null>(() => params.get('open'));
  function setOpen(id: string | null) {
    setOpenState(id);
    if (!id && params.get('open')) { params.delete('open'); setParams(params, { replace: true }); }
  }
  const [settings, setSettings] = useState(false);
  const allowed = can(inv, 'record_sales');
  const q = useQuery({ queryKey: ['customer-chats', orgId], enabled: !!orgId && allowed, refetchInterval: 20_000,
    queryFn: () => rpc<List>('get_customer_chats', { p_org: orgId }) });
  if (!inv) return null;
  if (!allowed) return <div className="container" style={{ maxWidth: 1000 }}><Alert kind="yellow" icon="shield">Only someone who records sales sees the customer chats.</Alert></div>;
  const all = q.data?.chats || [];
  const waiting = all.filter((c) => c.status === 'needs_reply');
  const rows = tab === 'waiting' ? waiting : all;
  return (
    <div className="container" style={{ maxWidth: 1000 }}>
      <div className="row wrap" style={{ justifyContent: 'space-between', gap: 12 }}>
        <div className="muted" style={{ fontSize: 14, maxWidth: 640, lineHeight: 1.5 }}>
          Customers who write back on WhatsApp to an invoice, receipt or order you sent them talk to Martina. She answers from your records, takes orders and notes when they say they paid. Anything else waits here for you.
        </div>
        {q.data?.can_change && <button className="btn btn-secondary btn-sm" onClick={() => setSettings((v) => !v)}><Icon name="settings" size={14} />Settings</button>}
      </div>
      {q.data && !q.data.settings.on && <Alert kind="grey" icon="info">Martina is not answering customers. Every message waits here for a person.</Alert>}
      {settings && q.data && <ChatSettings s={q.data.settings} onClose={() => setSettings(false)} />}
      <Pills value={tab} onChange={setTab} options={[{ id: 'waiting', label: 'Needs a reply', count: waiting.length || undefined }, { id: 'all', label: 'All chats' }]} />
      <div className="card" style={{ overflow: 'hidden' }}>
        {q.isLoading ? <SkeletonRows n={5} /> : q.isError ? <div style={{ padding: 16 }}><Alert kind="red" icon="alert">{cleanError(q.error)}</Alert></div>
          : !rows.length ? <div style={{ padding: 20 }}><Empty>{tab === 'waiting' ? 'Nobody is waiting for a reply.' : 'No customer has written on WhatsApp yet. When one writes back to something Counta sent them, the chat appears here.'}</Empty></div> : (
          <>
            <div className="tr head shade th rsp" style={{ gridTemplateColumns: 'minmax(0,1.4fr) minmax(0,2fr) 120px 120px' }}><span>Customer</span><span>Last message</span><span>When</span><span className="right">Status</span></div>
            {rows.map((c) => {
              const [label, tone] = STATUS[c.status];
              return (
                <button key={c.id} type="button" className="tr click rsp" onClick={() => setOpen(c.id)} data-testid="chat-row"
                  style={{ gridTemplateColumns: 'minmax(0,1.4fr) minmax(0,2fr) 120px 120px', width: '100%', textAlign: 'left', background: 'none', border: 0, borderTop: '1px solid var(--row)', font: 'inherit', color: 'inherit' }}>
                  <span className="m-main" style={{ minWidth: 0 }}>
                    <b className="ellipsis" style={{ display: 'block' }}>{c.name || c.phone}{c.unread > 0 && <span className="chip t-blue" style={{ marginLeft: 6 }}>{c.unread}</span>}</b>
                    <span className="faint" style={{ display: 'block', fontSize: 12 }}>{c.phone}{c.paused ? ' · Martina out' : ''}</span>
                  </span>
                  <span className="muted ellipsis" style={{ minWidth: 0 }}>{c.status === 'needs_reply' && c.handed_reason ? c.handed_reason : c.last_text}</span>
                  <span className="faint" style={{ fontSize: 12.5 }}>{when(c.last_at)}</span>
                  <span className="right"><span className={'chip ' + tone}>{label}</span></span>
                </button>
              );
            })}
          </>
        )}
      </div>
      {open && <ChatDrawer id={open} onClose={() => setOpen(null)} />}
    </div>
  );
}
