import { createContext, useContext, useEffect, useState, type ReactNode } from 'react';
import { useInventory } from '../state/session';
import { Icon } from '../components/Icon';
import type { useQueue } from './queue';

// ---------- shared phone context: which branch this phone is standing in ----------
export const MCtx = createContext<{ loc: string; setLoc: (l: string) => void; queue: ReturnType<typeof useQueue> }>(null as any);
export const useM = () => useContext(MCtx);

export function MTop({ title, right }: { title: ReactNode; right?: ReactNode }) {
  const { queue } = useM();
  const s = !queue.online ? ['Offline', '#C2410C', '#FFF7ED', 'wifiOff'] : queue.syncing ? ['Syncing…', '#0072F5', '#F0F7FF', 'refresh'] : queue.pending.length ? [`${queue.pending.length} queued`, '#A16207', '#FEFCE8', 'clock'] : queue.lastSync && Date.now() - queue.lastSync.at < 60_000 ? ['Synced', '#15803D', '#F0FDF4', 'check'] : ['Online', '#15803D', '#F0FDF4', ''];
  return (
    <div className="m-top">
      <span className="m-title ellipsis">{title}</span>
      <div className="row" style={{ gap: 8 }}>
        {right}
        <span className="status-pill" style={{ color: s[1], background: s[2] }}>{s[3] && <Icon name={s[3]} size={12} color={s[1]} />}{s[0]}</span>
      </div>
    </div>
  );
}

export function QueueBanner() {
  const { queue } = useM();
  const n = queue.pending.length;
  const [shown, setShown] = useState<number | null>(null);
  useEffect(() => { if (queue.lastSync) { setShown(queue.lastSync.n); const t = setTimeout(() => setShown(null), 6000); return () => clearTimeout(t); } }, [queue.lastSync?.at]); // eslint-disable-line react-hooks/exhaustive-deps
  if (!queue.online) {
    return <div style={{ background: '#FFF7ED', color: '#9A3412', fontSize: 12, padding: '10px 16px', lineHeight: 1.45 }}>No data right now. {n ? `${n} movement${n === 1 ? ' is' : 's are'} saved on this phone and will post in order when you reconnect.` : 'Anything you record is saved on this phone and posts when data returns.'} Keep selling.</div>;
  }
  if (queue.syncing) return <div style={{ background: '#F0F7FF', height: 4, overflow: 'hidden' }}><div style={{ height: '100%', background: '#0072F5', animation: 'tsBar 1.8s linear forwards' }} /></div>;
  if (n) return <div className="row" style={{ background: '#FEFCE8', color: '#92400E', fontSize: 12, padding: '8px 16px', justifyContent: 'space-between' }}><span>{n} waiting to post.</span><button className="btn btn-xs btn-secondary" onClick={() => queue.sync()}>Sync now</button></div>;
  if (shown) return <div style={{ background: '#F0FDF4', color: '#166534', fontSize: 12, padding: '10px 16px', lineHeight: 1.45 }}>All {shown} movement{shown === 1 ? '' : 's'} posted to the books in order. No conflicts.</div>;
  return null;
}

export function BranchChip() {
  const { data: inv } = useInventory();
  const { loc, setLoc } = useM();
  if (!inv || inv.locations.length < 2) return null;
  return (
    <select aria-label="Branch" value={loc} onChange={(e) => setLoc(e.target.value)}
      style={{ border: '1px solid #E6E6E6', borderRadius: 8, padding: '3px 6px', fontSize: 12, fontWeight: 600, color: '#111827', background: '#fff', maxWidth: 110 }}>
      {inv.locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}
    </select>
  );
}

