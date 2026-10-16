import { useMemo, useState } from 'react';
import { useInventory, useSession, useToast } from '../state/session';
import { N, num } from '../lib/format';
import { pluralUnit, puAbbr, qtyLabel, suAbbr } from '../lib/domain';
import type { Item } from '../lib/types';
import { Icon } from '../components/Icon';
import { Thumb } from '../components/ui';
import { enqueue } from './queue';
import { useM } from './ctx';

export function ItemSearch({ onPick, placeholder = 'Search by name or barcode' }: { onPick: (i: Item) => void; placeholder?: string }) {
  const { data: inv } = useInventory();
  const { loc } = useM();
  const [q, setQ] = useState('');
  const hits = useMemo(() => {
    const s = q.trim().toLowerCase();
    if (!inv || s.length < 2) return [];
    return inv.items.filter((i) => i.name.toLowerCase().includes(s) || (i.barcode || '').includes(s) || i.qr_code.toLowerCase() === s || (i.sku || '').toLowerCase() === s).slice(0, 8);
  }, [inv, q]);
  return (
    <div className="stack" style={{ gap: 8 }}>
      <div className="row" style={{ border: '1px solid #E6E6E6', borderRadius: 10, padding: '10px 12px' }}>
        <Icon name="search" size={16} color="#9CA3AF" />
        <input value={q} onChange={(e) => setQ(e.target.value)} placeholder={placeholder} aria-label="Search items" style={{ border: 'none', fontSize: 15, flex: 1, minWidth: 0, outline: 'none', boxShadow: 'none' }} />
      </div>
      {hits.map((i) => (
        <button key={i.id} className="m-card row" style={{ cursor: 'pointer', font: 'inherit', textAlign: 'left' }} onClick={() => { onPick(i); setQ(''); }}>
          <Thumb name={i.name} path={i.photo_path} size={36} />
          <span className="grow"><span style={{ display: 'block', fontSize: 13, fontWeight: 600 }}>{i.name}</span><span className="faint" style={{ fontSize: 11 }}>{qtyLabel(i, Number(i.qty?.[loc] || 0))} here · {N(i.price)}/{suAbbr(i.selling_unit)}</span></span>
        </button>
      ))}
      {q.trim().length >= 2 && !hits.length && <div className="muted" style={{ fontSize: 13 }}>No item matches "{q}".</div>}
    </div>
  );
}

// Record a sale for one item; queues offline and posts with the original time.
export function SaleSheet({ item, onDone, onCancel, voice }: {
  item: Item; onDone: (msg: string) => void; onCancel: () => void;
  voice?: { qty: number; unit_kind: 'purchase' | 'selling'; transcript: string; clean: boolean; location_id?: string | null };
}) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const { loc } = useM();
  const toast = useToast();
  const [qty, setQty] = useState(String(voice?.qty ?? 1));
  const [kind, setKind] = useState<'purchase' | 'selling'>(voice?.unit_kind && item.pack_size > 1 ? voice.unit_kind : 'selling');
  const [busy, setBusy] = useState(false);
  const where = voice?.location_id || loc;
  const su = Number(qty) * (kind === 'purchase' ? item.pack_size : 1);
  const onHand = Number(item.qty?.[where] || 0);
  const value = su * Number(item.price);
  const err = !(Number(qty) > 0) ? 'Enter a quantity above zero.' : null;
  async function save() {
    if (err || !inv || !orgId) return;
    setBusy(true);
    await enqueue({
      org: orgId, kind: 'sale', label: voice ? 'Voice sale' : 'Sale', detail: `${num(Number(qty))} ${kind === 'purchase' ? puAbbr(item.purchase_unit) : suAbbr(item.selling_unit)} ${item.name}`,
      payload: { item_id: item.id, location_id: where, qty: su, unit_price: Number(item.price), channel: voice ? 'Voice' : 'Phone app', voice: !!voice, note: voice?.transcript || null, voice_clean: voice?.clean ?? true },
      author: inv.me.display_name,
    });
    setBusy(false);
    if (su > onHand) toast(`Recorded, but ${inv.locations.find((l) => l.id === where)?.name} only shows ${qtyLabel(item, onHand)}. The owner will see the difference.`, 'err');
    onDone(`${num(su)} ${pluralUnit(item.selling_unit, su)} of ${item.name} sold · ${N(value)}`);
  }
  return (
    <div className="m-card stack" style={{ gap: 12 }}>
      <div className="row"><Thumb name={item.name} path={item.photo_path} size={40} /><div className="grow"><div style={{ fontSize: 14, fontWeight: 600 }}>{item.name}</div><div className="faint" style={{ fontSize: 11 }}>{N(item.price)} per {item.selling_unit} · {qtyLabel(item, onHand)} here</div></div></div>
      <div style={{ display: 'grid', gridTemplateColumns: item.pack_size > 1 ? '1fr 1fr' : '1fr', gap: 10 }}>
        <input className={'input' + (err ? ' err' : '')} type="number" inputMode="decimal" min={0} value={qty} onChange={(e) => setQty(e.target.value)} aria-label="Quantity sold" style={{ fontSize: 18, fontWeight: 600 }} />
        {item.pack_size > 1 && (
          <select className="input" value={kind} onChange={(e) => setKind(e.target.value as any)} aria-label="Unit">
            <option value="selling">{pluralUnit(item.selling_unit, 2)}</option>
            <option value="purchase">{pluralUnit(item.purchase_unit.toLowerCase(), 2)} ({item.pack_size})</option>
          </select>
        )}
      </div>
      <div className="row" style={{ justifyContent: 'space-between', fontSize: 13 }}><span className="muted">{num(su)} {pluralUnit(item.selling_unit, su)}</span><b>{N(value)}</b></div>
      <div className="row" style={{ gap: 8 }}>
        <button className="m-btn secondary" style={{ flex: 1 }} onClick={onCancel}>Cancel</button>
        <button className="m-btn" style={{ flex: 1 }} disabled={!!err || busy} onClick={save}>Record sale</button>
      </div>
    </div>
  );
}

export function Done({ title, body, action, onAction, icon = 'check', tone = 'green' }: { title: string; body: string; action: string; onAction: () => void; icon?: string; tone?: 'green' | 'amber' }) {
  return (
    <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 12, padding: 24, textAlign: 'center' }} className="rise">
      <div style={{ width: 64, height: 64, borderRadius: '50%', background: tone === 'green' ? '#F0FDF4' : '#FEFCE8', display: 'grid', placeItems: 'center' }}><Icon name={icon} size={28} color={tone === 'green' ? '#15803D' : '#A16207'} sw={2.5} /></div>
      <div style={{ fontSize: 17, fontWeight: 600 }}>{title}</div>
      <div className="muted" style={{ fontSize: 13, lineHeight: 1.5, maxWidth: 320 }}>{body}</div>
      <button className="btn btn-secondary btn-sm" style={{ marginTop: 8, color: '#0072F5', borderColor: '#B9D4FF' }} onClick={onAction}>{action}</button>
    </div>
  );
}
