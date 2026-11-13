// The clauses of an engagement letter, edited as blocks beside a live preview numbered exactly as the signed PDF will be
// (the same renderModel the practice function uses). Numbers are never typed: headings, clauses and list items number
// themselves, so moving or removing a block can never leave a gap like the old "1.1(a)(ii)".
import { useMemo, useState } from 'react';
import { Icon } from '../components/Icon';
import {
  deriveMerge, LETTER_FIELDS, type LetterBlock, type LetterBody, type MergeValues, renderModel,
} from '../../supabase/functions/_shared/letter.ts';

const KINDS: [LetterBlock['kind'], string][] = [['heading', 'Heading'], ['clause', 'Clause'], ['list', 'List item'], ['paragraph', 'Paragraph'],
  ['signature', 'Signature']];
const LEVEL_OF: Record<LetterBlock['kind'], number> = { heading: 1, clause: 2, list: 3, paragraph: 1, signature: 1 };

type Props = { body: LetterBody; merge: MergeValues; variant: 'full' | 'involved'; editable: boolean; onChange: (b: LetterBody) => void };

export function LetterEditor({ body, merge, variant, editable, onChange }: Props) {
  const [open, setOpen] = useState<string | null>(null);
  const blocks = body.blocks;
  const preview = useMemo(() => {
    try {
      return { blocks: renderModel(body, deriveMerge(merge), variant), error: null as string | null };
    } catch (e) {
      return { blocks: [], error: (e as Error).message };
    }
  }, [body, merge, variant]);

  const set = (next: LetterBlock[]) => onChange({ version: 1, blocks: next });
  const patch = (i: number, p: Partial<LetterBlock>) => set(blocks.map((b, j) => (j === i ? { ...b, ...p } : b)));
  const move = (i: number, by: -1 | 1) => {
    const j = i + by;
    if (j < 0 || j >= blocks.length) return;
    const next = blocks.slice();
    [next[i], next[j]] = [next[j], next[i]];
    set(next);
  };
  const remove = (i: number) => set(blocks.filter((_, j) => j !== i));
  const add = () => {
    let n = blocks.length + 1;
    const used = new Set(blocks.map((b) => b.id));
    while (used.has(`b${n}`)) n++;
    const id = `b${n}`;
    set([...blocks, { id, kind: 'clause', level: 2, text: 'New clause' }]);
    setOpen(id);
  };

  return (
    <div className="letter-ed">
      <div className="stack" style={{ gap: 8, minWidth: 0 }}>
        {blocks.map((b, i) => {
          const isOpen = editable && open === b.id;
          return (
            <div key={b.id} className={'letter-blk' + (isOpen ? ' open' : '')} data-testid="letter-block">
              <div className="row" style={{ gap: 8, alignItems: 'flex-start' }}>
                <span className="chip t-grey" style={{ flexShrink: 0 }}>{KINDS.find(([k]) => k === b.kind)?.[1]}{b.kind === 'list' && b.level === 4 ? ' (sub)' : ''}</span>
                {b.variant && <span className="chip t-blue" style={{ flexShrink: 0 }}>{b.variant === 'full' ? 'Full mandate only' : 'Involved only'}</span>}
                {b.optional && <span className="chip t-amber" style={{ flexShrink: 0 }} title={`Only while ${b.optional} is filled in`}>If {b.optional}</span>}
                <span className="grow" />
                {editable && (
                  <span className="row" style={{ gap: 2 }}>
                    <button type="button" className="btn btn-ghost btn-sm" aria-label="Move up" disabled={i === 0} onClick={() => move(i, -1)}><span aria-hidden="true">↑</span></button>
                    <button type="button" className="btn btn-ghost btn-sm" aria-label="Move down" disabled={i === blocks.length - 1} onClick={() => move(i, 1)}><span aria-hidden="true">↓</span></button>
                    <button type="button" className="btn btn-ghost btn-sm" aria-expanded={isOpen} onClick={() => setOpen(isOpen ? null : b.id)}>{isOpen ? 'Done' : 'Edit'}</button>
                  </span>
                )}
              </div>
              {isOpen ? (
                <div className="stack" style={{ gap: 8, marginTop: 8 }}>
                  <div className="row" style={{ gap: 8, flexWrap: 'wrap' }}>
                    <label className="stack" style={{ gap: 4, minWidth: 140 }}>
                      <span className="muted" style={{ fontSize: 12 }}>Kind</span>
                      <select className="input input-sm" value={b.kind} onChange={(e) => {
                        const kind = e.target.value as LetterBlock['kind'];
                        patch(i, { kind, level: LEVEL_OF[kind], text: kind === 'signature' ? 'firm' : b.text });
                      }}>
                        {KINDS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}
                      </select>
                    </label>
                    {(b.kind === 'list' || b.kind === 'paragraph') && (
                      <label className="stack" style={{ gap: 4, minWidth: 120 }}>
                        <span className="muted" style={{ fontSize: 12 }}>{b.kind === 'list' ? 'Level' : 'Indent'}</span>
                        <select className="input input-sm" value={b.level} onChange={(e) => patch(i, { level: Number(e.target.value) })}>
                          {(b.kind === 'list' ? [3, 4] : [1, 2, 3, 4]).map((n) => (
                            <option key={n} value={n}>{b.kind === 'list' ? (n === 3 ? '(a), (b)…' : '(i), (ii)…') : `Level ${n}`}</option>
                          ))}
                        </select>
                      </label>
                    )}
                    <label className="stack" style={{ gap: 4, minWidth: 160 }}>
                      <span className="muted" style={{ fontSize: 12 }}>In which letters</span>
                      <select className="input input-sm" value={b.variant || ''} onChange={(e) => patch(i, { variant: (e.target.value || null) as LetterBlock['variant'] })}>
                        <option value="">Every letter</option>
                        <option value="full">Full mandate only</option>
                        <option value="involved">Involved only</option>
                      </select>
                    </label>
                    <label className="stack" style={{ gap: 4, minWidth: 180 }}>
                      <span className="muted" style={{ fontSize: 12 }}>Only while this is filled in</span>
                      <select className="input input-sm" value={b.optional || ''} onChange={(e) => patch(i, { optional: e.target.value || null })}>
                        <option value="">Always</option>
                        {LETTER_FIELDS.map((f) => <option key={f} value={f}>{f}</option>)}
                      </select>
                    </label>
                  </div>
                  {b.kind === 'signature' ? (
                    <label className="stack" style={{ gap: 4 }}>
                      <span className="muted" style={{ fontSize: 12 }}>Whose signature</span>
                      <select className="input input-sm" value={b.text} onChange={(e) => patch(i, { text: e.target.value })} data-testid="letter-block-text">
                        <option value="firm">The firm's</option>
                        <option value="client">The client's</option>
                      </select>
                    </label>
                  ) : (
                    <label className="stack" style={{ gap: 4 }}>
                      <span className="muted" style={{ fontSize: 12 }}>Text (fields in double braces, for example {'{{client.name}}'})</span>
                      <textarea className="input" rows={Math.min(10, Math.max(3, Math.ceil(b.text.length / 90)))} value={b.text}
                        onChange={(e) => patch(i, { text: e.target.value })} data-testid="letter-block-text" />
                    </label>
                  )}
                  <div className="row" style={{ justifyContent: 'flex-end' }}>
                    <button type="button" className="btn btn-ghost btn-sm" style={{ color: 'var(--red, #B42318)' }} onClick={() => { remove(i); setOpen(null); }}>
                      Remove this block
                    </button>
                  </div>
                </div>
              ) : (
                <p className="letter-blk-text" style={{ margin: '6px 0 0', paddingLeft: (b.level - 1) * 14 }}>{b.kind === 'signature' ? (b.text === 'client' ? 'The client signs here.' : 'The firm signs here.') : b.text}</p>
              )}
            </div>
          );
        })}
        {editable && (
          <button type="button" className="btn btn-secondary" onClick={add} data-testid="letter-block-add" style={{ alignSelf: 'flex-start', minHeight: 44 }}>
            <Icon name="plus" size={16} />Add a clause
          </button>
        )}
      </div>
      <section className="letter-preview" aria-label="Preview" data-testid="letter-preview">
        <div className="muted" style={{ fontSize: 12, marginBottom: 10 }}>Preview, numbered as it will be signed</div>
        {preview.error ? <p style={{ color: '#B42318' }} role="alert">{preview.error}</p> : preview.blocks.map((b) => (
          b.kind === 'signature' ? (
            <p key={b.id} className="muted" style={{ margin: '18px 0 6px' }}>{b.text === 'client' ? 'Signed for the client' : 'Signed for the firm'}: ____________________</p>
          ) : (
            <p key={b.id} style={{
              margin: b.kind === 'heading' ? '16px 0 6px' : '6px 0', fontWeight: b.kind === 'heading' ? 600 : 400,
              paddingLeft: b.kind === 'heading' ? 0 : (b.level - 1) * 16, whiteSpace: 'pre-wrap',
            }}>
              {b.number && <span style={{ display: 'inline-block', minWidth: 34 }}>{b.number}</span>}{b.text}
            </p>
          )
        ))}
      </section>
    </div>
  );
}
