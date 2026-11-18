// The VAT on a line typed on an invoice, as Numens decided it: the answer and, behind the information icon, its reason.
// "Change" lets the person choose instead; the choice is recorded as theirs. An answer Numens is not sure of shows how
// sure it is, with "Keep" beside "Change". With no answer the person chooses. VatCheck asks about those lines before the
// invoice goes out.
import { useState } from 'react';
import { Modal, ModalHead, Seg, Spinner } from './ui';
import { VatInfo } from './VatInfo';
import { type LineVatState, type VatBy, type VatT, VAT_NAME, vatLabel } from '../lib/lineVat';
import type { Item } from '../lib/types';

const OPTIONS = (day?: string | null): { id: VatT; label: string }[] => [
  { id: 'standard', label: vatLabel('standard', day) }, { id: 'zero', label: VAT_NAME.zero }, { id: 'exempt', label: VAT_NAME.exempt },
];
const pct = (c: number | null | undefined) => `${Math.round((c ?? 0) * 100)}%`;
// "VAT at 7.5%", "zero-rated", "exempt": the treatment inside a sentence.
const phrase = (t: VatT, day?: string | null) => (t === 'standard' ? `VAT at ${vatLabel('standard', day).replace(/^VAT /, '')}` : VAT_NAME[t].toLowerCase());

// What the information icon says decided the line.
function basisOf(st: LineVatState, by: VatBy, treatment: VatT) {
  const a = st.answer;
  if (by === 'person') return { source: 'manual' as const, treatment, by: 'you', reason: a && a.source !== 'person' && a.treatment !== treatment ? `Numens said ${VAT_NAME[a.treatment].toLowerCase()}.` : null };
  if (!a) return null;
  if (a.source === 'person') return { source: 'manual' as const, treatment: a.treatment, by: a.by || 'someone on your team', at: a.at || undefined };
  return { source: a.source, treatment: a.treatment, confidence: a.confidence ?? undefined, reason: a.reason, law: a.law };
}

export function LineVat({ st, by, treatment, name, day, onPick, onNumens, testid }: {
  st: LineVatState; by: VatBy; treatment: VatT; name: string; day?: string | null;
  onPick: (t: VatT) => void;          // the person chose (or kept) this treatment
  onNumens?: () => void;              // the person gives the line back to Numens
  testid?: string;
}) {
  const [changing, setChanging] = useState(false);
  if (!name.trim()) return <span className="line-vat faint" data-testid={testid}>Numens decides the VAT from the description.</span>;
  const a = st.answer;
  const info = <VatInfo side="sale" treatment={treatment} name={name} day={day} nrsLabel={by === 'person' && a?.treatment !== treatment ? null : a?.nrs_label}
    item={{ vat_basis: basisOf(st, by, treatment) as any, vat_review: by !== 'person' && st.unsure }} size={13} />;
  if (changing) {
    return (
      <span className="line-vat" data-testid={testid}>
        <Seg value={treatment} options={OPTIONS(day)} onChange={(t) => { onPick(t); setChanging(false); }} />
        {by === 'person' && onNumens && a && a.source !== 'person' && <button type="button" className="lv-link" onClick={() => { onNumens(); setChanging(false); }}>Let Numens decide</button>}
        <button type="button" className="lv-link" onClick={() => setChanging(false)}>Cancel</button>
      </span>
    );
  }
  const change = <button type="button" className="lv-link" onClick={() => setChanging(true)} data-testid={testid && `${testid}-change`}>Change</button>;
  if (by === 'person') {
    return <span className="line-vat" data-testid={testid}><b>{vatLabel(treatment, day)}</b><span className="faint">· your choice</span>{info}{change}</span>;
  }
  if (st.loading) {
    return <span className="line-vat faint" data-testid={testid}><Spinner small />Numens is checking the VAT</span>;
  }
  if (!a) {
    return (
      <span className="line-vat lv-ask" data-testid={testid}>
        <span>Numens could not decide the VAT. Choose it:</span>
        <Seg value={'' as VatT} options={OPTIONS(day)} onChange={onPick} />
      </span>
    );
  }
  if (a.source === 'person') {
    return <span className="line-vat" data-testid={testid}><b>{vatLabel(a.treatment, day)}</b><span className="faint">· chosen by {a.by || 'your team'}</span>{info}{change}</span>;
  }
  if (st.unsure) {
    return (
      <span className="line-vat lv-ask" data-testid={testid}>
        <span>Numens thinks <b>{phrase(a.treatment, day)}</b>, {pct(a.confidence)} sure</span>{info}
        <button type="button" className="lv-link" onClick={() => onPick(a.treatment)} data-testid={testid && `${testid}-keep`}>Keep</button>{change}
      </span>
    );
  }
  return <span className="line-vat" data-testid={testid}><b>{vatLabel(a.treatment, day)}</b><span className="faint">· Numens</span>{info}{change}</span>;
}

// Before an invoice goes out (or a recurring schedule that issues them is saved): the lines whose VAT Numens is not sure
// of, or could not decide. Each starts at Numens' answer; the person keeps or changes it, and that is recorded as theirs.
export function VatCheck({ lines, day, title, sub, action, onDone, onClose }: {
  lines: { key: string; description: string; st: LineVatState }[]; day?: string | null; title: string; sub: string; action: string;
  onDone: (picks: Record<string, VatT>) => void; onClose: () => void;
}) {
  const [picks, setPicks] = useState<Record<string, VatT | undefined>>(() => Object.fromEntries(lines.map((l) => [l.key, l.st.answer?.treatment])));
  const ready = lines.every((l) => picks[l.key]);
  return (
    <Modal onClose={onClose} width={560}>
      <ModalHead title={title} sub={sub} onClose={onClose} />
      <div className="modal-body" data-testid="vat-check">
        {lines.map((l) => {
          const a = l.st.answer;
          return (
            <div key={l.key} className="stack" style={{ gap: 6, paddingBottom: 12, borderBottom: '1px solid var(--line)' }} data-testid="vat-check-line">
              <b style={{ fontSize: 14, overflowWrap: 'anywhere' }}>{l.description.trim()}</b>
              <div className="muted" style={{ fontSize: 13, lineHeight: 1.45 }}>
                {a ? <>Numens thinks {phrase(a.treatment, day)}, {pct(a.confidence)} sure.{a.reason ? ` ${a.reason.trim().replace(/\.?$/, '.')}` : ''}</>
                  : 'Numens could not decide this one. Choose the VAT.'}
              </div>
              <Seg value={(picks[l.key] || '') as VatT} options={OPTIONS(day)} onChange={(t) => setPicks((p) => ({ ...p, [l.key]: t }))} />
            </div>
          );
        })}
        <div className="faint" style={{ fontSize: 12, lineHeight: 1.45 }}>What you choose is recorded as your decision and used for the same description from now on.</div>
      </div>
      <div className="modal-ft m-wrap">
        <button className="btn btn-secondary" onClick={onClose}>Back</button>
        <button className="btn btn-primary" disabled={!ready} onClick={() => onDone(picks as Record<string, VatT>)} data-testid="vat-check-go">{action}</button>
      </div>
    </Modal>
  );
}

// A product's VAT on sales, as Numens decides it. A new product shows that Numens decides once it is saved; a saved one
// shows its VAT and who decided it. "Change" lets someone who may set VAT choose instead (recorded as theirs), and "Let
// Numens decide" hands it back.
export function ItemVat({ item, value, name, canSet, canAsk, onChange, vatRegistered, testid }: {
  item?: Pick<Item, 'vat_treatment' | 'vat_basis' | 'vat_review'> | null;  // the saved product, when editing one
  value: VatT | 'auto';                                                    // 'auto': Numens decides when it is saved
  name: string; canSet: boolean; canAsk?: boolean; onChange: (v: VatT | 'auto') => void; vatRegistered?: boolean; testid?: string;
}) {
  const [changing, setChanging] = useState(false);
  const saved = item?.vat_treatment as VatT | undefined;
  const b = item?.vat_basis;
  if (changing) {
    return (
      <span className="line-vat" data-testid={testid}>
        <Seg value={(value === 'auto' ? '' : value) as VatT} options={OPTIONS()} onChange={(t) => { onChange(t); setChanging(false); }} />
        {value !== 'auto' && (canAsk ?? true) && <button type="button" className="lv-link" onClick={() => { onChange('auto'); setChanging(false); }}>Let Numens decide</button>}
        <button type="button" className="lv-link" onClick={() => setChanging(false)}>Cancel</button>
      </span>
    );
  }
  const change = canSet ? <button type="button" className="lv-link" onClick={() => setChanging(true)} data-testid={testid && `${testid}-change`}>Change</button> : null;
  if (value === 'auto') {
    return (
      <span className="line-vat" data-testid={testid}>
        <span>{item ? 'Numens decides again when you save.' : 'Numens decides the VAT once it is saved, under the Nigeria Tax Act 2025.'}</span>
        {item && saved ? <button type="button" className="lv-link" onClick={() => onChange(saved)}>Keep {vatLabel(saved).replace(/^VAT /, 'VAT at ')}</button> : change}
      </span>
    );
  }
  if (item && value === saved) {
    const who = !b ? null : b.source === 'manual' ? `set by ${b.by || 'your team'}` : b.source === 'import' ? 'from your product list'
      : `Numens${typeof b.confidence === 'number' ? `, ${pct(b.confidence)} sure` : ''}`;
    return (
      <span className={'line-vat' + (item.vat_review ? ' lv-ask' : '')} data-testid={testid}>
        <b>{vatLabel(value)}</b>{who && <span className={item.vat_review ? '' : 'faint'}>· {who}{item.vat_review ? ', not sure: check it' : ''}</span>}
        <VatInfo side="sale" treatment={value} name={name} item={item} vatRegistered={vatRegistered} size={13} />
        {change}
        {b?.source === 'manual' && canAsk && <button type="button" className="lv-link" onClick={() => onChange('auto')}>Let Numens decide</button>}
      </span>
    );
  }
  return (
    <span className="line-vat" data-testid={testid}>
      <b>{vatLabel(value)}</b><span className="faint">· your choice</span>
      <VatInfo side="sale" treatment={value} name={name} vatRegistered={vatRegistered} size={13} />{change}
    </span>
  );
}
