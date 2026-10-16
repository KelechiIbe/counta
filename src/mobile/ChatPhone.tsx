import { useEffect, useRef, useState } from 'react';
import { can } from '../state/session';
import { useAction } from '../lib/queries';
import { rpc } from '../lib/supabase';
import { N, fmtTime } from '../lib/format';
import { pluralUnit, poMessage, waLink } from '../lib/domain';
import { useMartina } from '../pages/Assistant';
import { Icon } from '../components/Icon';
import { useM } from './ctx';

export default function ChatScreen() {
  const { msgs, send, busy, push, inv, suggestions } = useMartina();
  const { queue } = useM();
  const { run, busy: posting } = useAction();
  const [q, setQ] = useState('');
  const end = useRef<HTMLDivElement>(null);
  useEffect(() => { end.current?.scrollIntoView({ behavior: 'smooth', block: 'end' }); }, [msgs.length, busy]);
  if (!inv) return null;
  const last = msgs[msgs.length - 1];
  const offer = last?.role === 'bot' && last.action?.type === 'offer_po' ? last.action : null;
  const approver = can(inv, 'approve_pos');

  async function approve() {
    if (!offer || !inv) return;
    const it = inv.items.find((i) => i.id === offer.item_id);
    if (!it) return;
    const sug = suggestions.find((s) => s.item.id === it.id);
    const qty = Math.max(1, Math.round(Number(offer.qty || sug?.qtyPU || 1)));
    const vendor = inv.vendors.find((v) => v.id === (offer.vendor_id || sug?.vendor?.id || it.preferred_vendor_id)) || null;
    if (!vendor) { push({ role: 'bot', text: `${it.name} has no preferred vendor yet. Pick one on the Reorder page and I will draft it there.`, at: Date.now() }); return; }
    const unitCost = sug?.unitCostPU ?? (it.last_cost != null ? Number(it.last_cost) * it.pack_size : 0);
    push({ role: 'user', text: 'APPROVE', at: Date.now() });
    const r = await run(() => rpc<any>('save_po', { p_org: inv.org.id, p_vendor: vendor.id, p_lines: [{ item_id: it.id, qty, unit_cost: unitCost }], p_send: true, p_sent_via: vendor.channel }), { invalidate: ['pos', 'inv'] });
    if (!r) return;
    const text = poMessage({ org: inv.org.name, ref: r.ref, vendor: vendor.name, lines: [{ name: it.name, qty, unit: it.purchase_unit, unitCost: inv.can_see_costs ? unitCost : null }], total: inv.can_see_costs ? Number(r.total) : null });
    push({ role: 'bot', at: Date.now(), text: `Approved ${r.ref}: ${qty} ${pluralUnit(it.purchase_unit.toLowerCase(), qty)} of ${it.name} from ${vendor.name}${inv.can_see_costs ? `, ${N(r.total)}` : ''}. Tap below to send it on ${vendor.channel === 'email' ? 'email' : 'WhatsApp'}. The delivery invoice closes it in Receive.`,
      route: vendor.channel === 'email' ? `mailto:${vendor.email || ''}?subject=${encodeURIComponent(r.ref)}&body=${encodeURIComponent(text)}` : waLink(vendor.phone, text), cta: `Send to ${vendor.name.split(' ')[0]}` });
  }

  const quick = !busy && last?.role === 'bot' ? (offer ? (approver ? ['APPROVE', 'Change quantity', 'Not yet'] : ['Not yet']) : last.quick || []) : [];
  return (
    <div style={{ display: 'flex', flexDirection: 'column', flex: 1, background: '#ECE5DD', minHeight: 0 }}>
      <div className="row" style={{ gap: 10, padding: '10px 14px', paddingTop: 'max(10px, env(safe-area-inset-top))', background: '#075E54', color: '#fff', position: 'sticky', top: 0, zIndex: 5 }}>
        <span style={{ width: 36, height: 36, borderRadius: '50%', background: 'linear-gradient(135deg,#0072F5,#7C3AED 55%,#DB2779)', display: 'grid', placeItems: 'center' }}><Icon name="sparkles" size={16} color="#fff" /></span>
        <div className="grow"><div style={{ fontSize: 15, fontWeight: 600 }}>Martina · TaxStreem</div><div style={{ fontSize: 11, opacity: 0.85 }}>{queue.online ? 'online' : 'offline · answering from the copy on this phone'}</div></div>
      </div>
      <div style={{ flex: 1, overflowY: 'auto', padding: '14px 12px', display: 'flex', flexDirection: 'column', gap: 8 }}>
        <div style={{ alignSelf: 'center', background: '#FFF5C4', color: '#6B7280', fontSize: 11, borderRadius: 8, padding: '4px 10px' }}>Ask about stock, costs you can see, or what to reorder</div>
        {msgs.map((m, i) => (
          <div key={i} style={{ alignSelf: m.role === 'user' ? 'flex-end' : 'flex-start', maxWidth: '86%', background: m.role === 'user' ? '#DCF8C6' : '#fff', borderRadius: m.role === 'user' ? '10px 10px 2px 10px' : '10px 10px 10px 2px', padding: '8px 12px', fontSize: 13, lineHeight: 1.45, boxShadow: '0 1px 1px rgba(0,0,0,.08)' }}>
            <div style={{ whiteSpace: 'pre-wrap' }}>{m.text}</div>
            {m.route && (/^(https?:|mailto:)/.test(m.route) ? <a href={m.route} target="_blank" rel="noreferrer" style={{ display: 'inline-block', marginTop: 6, fontWeight: 600 }}>{m.cta || 'Open'}</a> : null)}
            <div style={{ fontSize: 10, color: '#9CA3AF', textAlign: 'right', marginTop: 2 }}>{fmtTime(new Date(m.at).toISOString())}</div>
          </div>
        ))}
        {busy && <div style={{ alignSelf: 'flex-start', background: '#fff', borderRadius: 10, padding: '8px 12px', fontSize: 13, color: '#6B7280' }}>typing…</div>}
        <div ref={end} />
      </div>
      <div style={{ padding: '10px 12px', display: 'flex', flexDirection: 'column', gap: 8, background: '#F0F0F0', paddingBottom: 10 }}>
        {(quick.length > 0 || !msgs.length) && (
          <div className="row wrap" style={{ gap: 6 }}>
            {(msgs.length ? quick : ['What is running low here?', 'Which items are losing money?', 'What expires soon?']).map((x) => (
              <button key={x} disabled={posting} onClick={() => (x === 'APPROVE' ? approve() : send(x))}
                style={{ border: '1px solid ' + (x === 'APPROVE' ? '#25D366' : '#D1D5DB'), background: '#fff', color: x === 'APPROVE' ? '#075E54' : '#4B5563', borderRadius: 999, padding: '7px 12px', fontSize: 12, fontWeight: x === 'APPROVE' ? 600 : 500, cursor: 'pointer' }}>{x}</button>
            ))}
          </div>
        )}
        <form className="row" style={{ gap: 8 }} onSubmit={(e) => { e.preventDefault(); send(q); setQ(''); }}>
          <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Message" aria-label="Message Martina" style={{ flex: 1, background: '#fff', border: 0, borderRadius: 999, padding: '10px 14px', fontSize: 14, outline: 'none' }} />
          <button type="submit" aria-label="Send" disabled={!q.trim() || busy} style={{ width: 40, height: 40, borderRadius: '50%', background: '#25D366', display: 'grid', placeItems: 'center', border: 0, cursor: 'pointer' }}><Icon name="send" size={16} color="#fff" /></button>
        </form>
      </div>
    </div>
  );
}
