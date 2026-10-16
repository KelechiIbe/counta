import { useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { useInventory, useSession } from '../state/session';
import { useSuggestions, useCashStory } from '../shell/needsAction';
import { useCounts, useProposals } from '../lib/queries';
import { buildItems } from '../lib/domain';
import { aiStatus, buildContext, chatMartina, localAnswer, type ChatMsg } from '../lib/martina';
import { fmtTime } from '../lib/format';
import { Icon } from '../components/Icon';
import { Spinner } from '../components/ui';

export function useMartina() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const { suggestions } = useSuggestions();
  const proposals = useProposals();
  const counts = useCounts();
  const { story } = useCashStory('ALL');
  const items = useMemo(() => (inv ? buildItems(inv, 'ALL') : []), [inv]);
  const key = 'counta.chat.' + orgId;
  const [msgs, setMsgs] = useState<ChatMsg[]>(() => { try { return JSON.parse(sessionStorage.getItem(key) || '[]'); } catch { return []; } });
  const [busy, setBusy] = useState(false);
  useEffect(() => { try { sessionStorage.setItem(key, JSON.stringify(msgs.slice(-40))); } catch { /* ignore */ } }, [msgs, key]);
  async function send(text: string) {
    if (!inv || !text.trim() || busy) return;
    const next = [...msgs, { role: 'user' as const, text: text.trim(), at: Date.now() }];
    setMsgs(next); setBusy(true);
    const ctx = buildContext(inv, items, suggestions, proposals.data || [], story, counts.data || []);
    const reply = await chatMartina(next, ctx, (q) => localAnswer(q, inv, items, suggestions, proposals.data || [], story));
    setMsgs((m) => [...m, reply]); setBusy(false);
  }
  const push = (m: ChatMsg) => setMsgs((x) => [...x, m]);
  return { msgs, send, busy, clear: () => setMsgs([]), push, items, inv, suggestions };
}

export default function Assistant() {
  const nav = useNavigate();
  const { msgs, send, busy, clear, items, inv, suggestions } = useMartina();
  const status = useQuery({ queryKey: ['aiStatus'], queryFn: aiStatus, staleTime: 5 * 60 * 1000 });
  const [q, setQ] = useState('');
  const end = useRef<HTMLDivElement>(null);
  useEffect(() => { end.current?.scrollIntoView({ behavior: 'smooth', block: 'end' }); }, [msgs.length, busy]);
  if (!inv) return null;
  const top = suggestions[0];
  const starters = [
    `How many ${items[0]?.name.split(' ')[0] || 'cartons'} do we have left?`,
    'What is running low this week?',
    'Which items are losing money?',
    top ? `Should I reorder ${top.item.name.split(' ').slice(0, 2).join(' ')}?` : 'What expires soon?',
  ];
  const last = msgs[msgs.length - 1];
  return (
    <div className="container" style={{ maxWidth: 860, height: 'calc(100vh - 150px)', minHeight: 480, gap: 0 }}>
      <div className="card" style={{ display: 'flex', flexDirection: 'column', height: '100%', overflow: 'hidden' }}>
        <div className="card-hd">
          <div className="row" style={{ gap: 12 }}>
            <span style={{ width: 40, height: 40, borderRadius: '50%', background: 'linear-gradient(135deg,#0072F5,#7C3AED 55%,#DB2779)', display: 'grid', placeItems: 'center' }}><Icon name="sparkles" size={18} color="#fff" /></span>
            <div>
              <div style={{ fontSize: 15, fontWeight: 600 }}>Martina</div>
              <div className="muted" style={{ fontSize: 12 }}>{status.data == null ? 'Checking…' : status.data.configured ? `Answers from your records · Gemini` : 'Answers from your records · add a Gemini key in Settings for open questions'}</div>
            </div>
          </div>
          {msgs.length > 0 && <button className="btn btn-ghost btn-xs" onClick={clear}>New chat</button>}
        </div>
        <div style={{ flex: 1, overflowY: 'auto', padding: 20, display: 'flex', flexDirection: 'column', gap: 12, background: '#FAFAFA' }}>
          {!msgs.length && (
            <div style={{ margin: 'auto', textAlign: 'center', maxWidth: 520 }}>
              <div style={{ fontFamily: 'var(--font-brand)', fontSize: 22, fontWeight: 600 }}>Ask about your stock</div>
              <div className="ink3" style={{ fontSize: 14, marginTop: 6, lineHeight: 1.5 }}>Martina reads your items, branches, receipts, counts and takings. She can draft a purchase order, but nothing is sent or repriced until you approve it.</div>
              <div className="row wrap" style={{ justifyContent: 'center', marginTop: 16 }}>
                {starters.map((s) => <button key={s} className="pill" style={{ color: '#111827' }} onClick={() => send(s)}>{s}</button>)}
              </div>
            </div>
          )}
          {msgs.map((m, i) => (
            <div key={i} style={{ alignSelf: m.role === 'user' ? 'flex-end' : 'flex-start', maxWidth: '82%' }}>
              <div style={{ background: m.role === 'user' ? '#0072F5' : '#fff', color: m.role === 'user' ? '#fff' : '#111827', border: m.role === 'user' ? 0 : '1px solid #E6E6E6', borderRadius: m.role === 'user' ? '14px 14px 4px 14px' : '14px 14px 14px 4px', padding: '10px 14px', fontSize: 14, lineHeight: 1.5, whiteSpace: 'pre-wrap' }}>{m.text}</div>
              {m.role === 'bot' && (m.action || m.route) && (
                <div className="row" style={{ marginTop: 6 }}>
                  {m.action?.type === 'offer_po' && <button className="btn btn-primary btn-xs" onClick={() => nav('/inventory/reorder', { state: { draft: m.action!.item_id } })}>Open draft PO</button>}
                  {m.route && <button className="btn btn-secondary btn-xs" onClick={() => nav(m.route!)}>{m.cta || 'Open'}</button>}
                </div>
              )}
              <div className="faint" style={{ fontSize: 10, marginTop: 3, textAlign: m.role === 'user' ? 'right' : 'left' }}>{fmtTime(new Date(m.at).toISOString())}{m.role === 'bot' ? (m.source === 'ai' ? ' · Gemini' : ' · from your records') : ''}</div>
            </div>
          ))}
          {busy && <div className="row muted" style={{ fontSize: 13 }}><Spinner small />Martina is looking…</div>}
          <div ref={end} />
        </div>
        {last?.role === 'bot' && last.quick && last.quick.length > 0 && !busy && (
          <div className="row wrap" style={{ padding: '10px 16px 0', gap: 6 }}>{last.quick.map((qq) => <button key={qq} className="pill" style={{ padding: '6px 12px', fontSize: 12 }} onClick={() => send(qq)}>{qq}</button>)}</div>
        )}
        <form onSubmit={(e) => { e.preventDefault(); send(q); setQ(''); }} className="row" style={{ padding: 16, gap: 10 }}>
          <input className="input" value={q} onChange={(e) => setQ(e.target.value)} placeholder="Ask Martina…" aria-label="Message Martina" />
          <button className="btn btn-primary" type="submit" disabled={busy || !q.trim()} aria-label="Send"><Icon name="send" size={16} color="#fff" /></button>
        </form>
      </div>
    </div>
  );
}
