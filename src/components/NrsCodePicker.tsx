// Search NRS's HS codes or service codes, by number or by words, and choose one.
import { useEffect, useState } from 'react';
import { useNrsCodes } from '../lib/einvoice';
import { Icon } from './Icon';

export function NrsCodePicker({ list, onPick, onCancel, busy, initial = '' }: {
  list: 'hs-codes' | 'services-codes'; onPick: (code: string) => void; onCancel?: () => void; busy?: boolean; initial?: string;
}) {
  const [q, setQ] = useState(initial);
  const [term, setTerm] = useState(initial);
  useEffect(() => { const t = setTimeout(() => setTerm(q), 250); return () => clearTimeout(t); }, [q]);
  const r = useNrsCodes(list, term);
  const rows = term.trim().length >= 2 ? r.data || [] : [];
  const what = list === 'hs-codes' ? 'HS code' : 'service code';
  return (
    <div className="stack" style={{ gap: 6, minWidth: 0 }}>
      <div className="row" style={{ gap: 6 }}>
        <div className="row" style={{ border: '1px solid var(--line, #E6E6E6)', borderRadius: 10, padding: '6px 10px', flex: '1 1 auto', minWidth: 0 }}>
          <Icon name="search" size={14} color="#9CA3AF" />
          <input className="bare" autoFocus value={q} onChange={(e) => setQ(e.target.value)} aria-label={`Search NRS's ${what}s`}
            placeholder={list === 'hs-codes' ? 'A number (1902) or words (pasta)' : 'A number (4711) or words (retail)'}
            style={{ border: 0, outline: 0, flex: 1, minWidth: 0, fontSize: 14, background: 'transparent' }} />
        </div>
        {onCancel && <button className="btn btn-ghost btn-sm" onClick={onCancel}>Cancel</button>}
      </div>
      {term.trim().length >= 2 && (
        <div className="stack" role="listbox" aria-label={`NRS ${what}s`} style={{ gap: 2, maxHeight: 240, overflowY: 'auto' }}>
          {r.isFetching && !rows.length && <div className="faint" style={{ fontSize: 13 }}>Searching…</div>}
          {!r.isFetching && !rows.length && <div className="faint" style={{ fontSize: 13 }}>No {what} on NRS's list matches. Try fewer words or the first digits.</div>}
          {rows.map((c) => (
            <button key={c.code} role="option" aria-selected={false} className="btn btn-ghost btn-sm" disabled={busy} onClick={() => onPick(c.code)}
              style={{ justifyContent: 'flex-start', textAlign: 'left', height: 'auto', padding: '6px 8px', whiteSpace: 'normal', lineHeight: 1.35 }}>
              <b style={{ flex: 'none', fontVariantNumeric: 'tabular-nums' }}>{c.code}</b><span className="muted" style={{ marginLeft: 8, minWidth: 0 }}>{c.label}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
