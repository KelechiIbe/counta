// A small information icon beside a VAT treatment. Tapping it opens why the product or line carries that VAT.
import { useState } from 'react';
import { Icon } from './Icon';
import { Popover } from './ui';
import { vatNote, type VatNoteInput } from '../lib/vatNotes';

export function VatInfo(props: VatNoteInput & { size?: number }) {
  const [at, setAt] = useState<HTMLButtonElement | null>(null);
  const n = vatNote(props);
  return (
    <>
      <button type="button" className="vat-info" aria-label={`Why: ${n.title}`} aria-expanded={!!at} aria-haspopup="dialog" title="Why this VAT?"
        onClick={(e) => { e.stopPropagation(); e.preventDefault(); setAt(at ? null : e.currentTarget); }}>
        <Icon name="info" size={props.size ?? 14} />
      </button>
      {at && (
        <Popover anchor={at} onClose={() => setAt(null)} side="bottom-start" width={320} label={n.title}>
          <div className="vat-note" role="dialog" aria-label={n.title}>
            <b>{n.title}</b>
            {n.body.map((p, i) => <p key={i}>{p}</p>)}
            {n.basis && <p className="faint">{n.basis}</p>}
            {n.law && <div className="vat-law"><Icon name="book" size={12} />{n.law}</div>}
          </div>
        </Popover>
      )}
    </>
  );
}
