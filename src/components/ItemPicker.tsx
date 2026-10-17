import { useMemo, useState } from 'react';
import type { Item } from '../lib/types';
import { Icon } from './Icon';

// Type to find an item by name, SKU or barcode. Enter picks the first match.
export function ItemPicker({ items, onPick, placeholder = 'Add an item: type its name, SKU or barcode', exclude = [], autoFocus }: {
  items: Item[]; onPick: (i: Item) => void; placeholder?: string; exclude?: string[]; autoFocus?: boolean;
}) {
  const [q, setQ] = useState('');
  const hits = useMemo(() => {
    const s = q.trim().toLowerCase();
    if (s.length < 1) return [];
    return items.filter((i) => !exclude.includes(i.id) && (i.name.toLowerCase().includes(s) || (i.sku || '').toLowerCase().includes(s) || (i.barcode || '').includes(s)))
      .sort((a, b) => Number(!a.name.toLowerCase().startsWith(s)) - Number(!b.name.toLowerCase().startsWith(s)) || a.name.localeCompare(b.name))
      .slice(0, 8);
  }, [items, q, exclude]);
  const pick = (i: Item) => { onPick(i); setQ(''); };
  return (
    <div style={{ position: 'relative' }}>
      <div className="row" style={{ border: '1px solid var(--line, #E5E7EB)', borderRadius: 10, padding: '0 10px', background: '#fff' }}>
        <Icon name="search" size={15} color="#9CA3AF" />
        <input className="input" style={{ border: 0, boxShadow: 'none', paddingLeft: 6 }} value={q} autoFocus={autoFocus} placeholder={placeholder} aria-label="Find an item"
          onChange={(e) => setQ(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter' && hits[0]) { e.preventDefault(); pick(hits[0]); } if (e.key === 'Escape') setQ(''); }} />
      </div>
      {hits.length > 0 && (
        <div className="card" style={{ position: 'absolute', left: 0, right: 0, top: 'calc(100% + 4px)', zIndex: 30, padding: 4, boxShadow: 'var(--shadow-lg, 0 10px 30px rgba(0,0,0,.12))' }}>
          {hits.map((i) => (
            <button key={i.id} type="button" className="nav-item" style={{ width: '100%', textAlign: 'left', padding: '8px 10px', fontSize: 13.5, display: 'flex', justifyContent: 'space-between', gap: 8 }} onClick={() => pick(i)}>
              <span className="ellipsis">{i.name}</span><span className="faint" style={{ fontSize: 12, flex: 'none' }}>{i.sku || i.category}</span>
            </button>
          ))}
        </div>
      )}
      {q.trim() && !hits.length && <div className="faint" style={{ fontSize: 12, marginTop: 4 }}>No item matches “{q.trim()}”.</div>}
    </div>
  );
}
