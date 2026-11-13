// The other side of a client's matters (a dispute, a deal, a tax matter), saved on the client so every later conflicts
// check finds them and the firm never acts for both sides. Partners and managers record and remove them; the database
// refuses anyone else.
import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc } from '../lib/supabase';
import { useToast } from '../state/session';
import { Icon } from '../components/Icon';
import { Field, Spinner } from '../components/ui';

export type Opposing = { id: string; name: string; rc_number: string | null; note: string | null };

export function OpposingList({ pid, clientId, list, editable = true }: { pid: string; clientId: string; list: Opposing[]; editable?: boolean }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [f, setF] = useState({ name: '', rc: '', note: '' });
  const [busy, setBusy] = useState<string | null>(null);
  async function save(key: string, p: Record<string, unknown>) {
    setBusy(key);
    try {
      await rpc('practice_opposing_save', { p_practice: pid, p });
      await qc.invalidateQueries({ queryKey: ['practice-client', clientId] });
      return true;
    } catch (e) { toast(cleanError(e), 'err'); return false; } finally { setBusy(null); }
  }
  async function add() {
    if (await save('add', { client_id: clientId, name: f.name.trim(), rc_number: f.rc.trim() || null, note: f.note.trim() || null })) setF({ name: '', rc: '', note: '' });
  }
  return (
    <div className="stack" style={{ gap: 10 }}>
      {!list.length && <div className="faint" style={{ fontSize: 14 }}>None recorded.</div>}
      {list.map((o) => (
        <div key={o.id} className="row" style={{ gap: 8, justifyContent: 'space-between', alignItems: 'flex-start', fontSize: 14 }} data-testid="opposing-party-row">
          <span style={{ minWidth: 0 }}>
            {o.name}{o.rc_number ? <span className="muted"> · {o.rc_number}</span> : null}
            {o.note && <span className="faint" style={{ display: 'block', fontSize: 12, lineHeight: 1.5 }}>{o.note}</span>}
          </span>
          {editable && (
            <button type="button" className="btn btn-ghost btn-sm" style={{ minWidth: 40, minHeight: 40 }} disabled={busy !== null} onClick={() => save(o.id, { id: o.id, remove: true })}
              aria-label={`Remove ${o.name}`} data-testid="opposing-party-remove">
              {busy === o.id ? <Spinner small /> : <Icon name="trash" size={14} />}
            </button>
          )}
        </div>
      ))}
      {editable && (
        <form className="row wrap" style={{ gap: 8, alignItems: 'flex-end' }} onSubmit={(e) => { e.preventDefault(); if (f.name.trim().length >= 2) void add(); }}>
          <Field label="Name" style={{ flex: '2 1 200px' }}>
            <input className="input" value={f.name} maxLength={160} onChange={(e) => setF({ ...f, name: e.target.value })} data-testid="opposing-party-name" />
          </Field>
          <Field label="RC number" style={{ flex: '1 1 120px' }}><input className="input" value={f.rc} maxLength={40} onChange={(e) => setF({ ...f, rc: e.target.value })} /></Field>
          <Field label="The matter (optional)" style={{ flex: '2 1 200px' }}><input className="input" value={f.note} maxLength={500} onChange={(e) => setF({ ...f, note: e.target.value })} /></Field>
          <button className="btn btn-secondary" style={{ minHeight: 40 }} disabled={busy !== null || f.name.trim().length < 2} data-testid="opposing-party-add">
            {busy === 'add' ? <Spinner small /> : <Icon name="plus" size={14} />}Record
          </button>
        </form>
      )}
    </div>
  );
}
