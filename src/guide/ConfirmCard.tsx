// What Martina is about to do, held for approval: the same words she reads out, with Approve and Cancel. A spoken yes
// approves it through her; a tap approves it here.
import { useState } from 'react';
import { N2 } from '../lib/format';
import { Icon } from '../components/Icon';
import { usePendingAction } from './actions';
import { useGuideTalk } from './GuideProvider';

export function ConfirmCard({ compact }: { compact?: boolean }) {
  const p = usePendingAction();
  const g = useGuideTalk();
  const [busy, setBusy] = useState(false);
  if (!p) return null;
  return (
    <div className="g-confirm" role="group" aria-label={`Waiting for approval: ${p.title}`}>
      <div className="row" style={{ gap: 8, alignItems: 'flex-start' }}>
        <Icon name="martina" size={18} color="#0072F5" style={{ marginTop: 1 }} />
        <div className="grow" style={{ minWidth: 0 }}>
          <div style={{ fontWeight: 600, fontSize: 14 }}>{p.title}</div>
          <ul className="g-confirm-lines">{p.lines.map((l) => <li key={l}>{l}</li>)}</ul>
          {p.total != null && <div style={{ fontWeight: 600, fontSize: 14 }}>Total {N2(p.total)}</div>}
          {p.note && <div className="faint" style={{ fontSize: 12, marginTop: 2 }}>{p.note}</div>}
        </div>
      </div>
      <div className="row" style={{ gap: 8, justifyContent: 'flex-end', marginTop: compact ? 6 : 8 }}>
        <span className="faint grow" style={{ fontSize: 12 }}>Say “yes” or tap Approve</span>
        <button className="btn btn-secondary btn-sm" disabled={busy} onClick={() => g.cancelPending()}>Cancel</button>
        <button className="btn btn-primary btn-sm" disabled={busy} onClick={async () => { setBusy(true); await g.approvePending(); setBusy(false); }}>{busy ? 'Working…' : 'Approve'}</button>
      </div>
    </div>
  );
}

// The switch for "Hello Martina" on this device, with what the listener is doing.
export function HandsFreeSwitch({ small }: { small?: boolean }) {
  const g = useGuideTalk();
  if (!g.wakeSupported) return small ? null : <div className="faint" style={{ fontSize: 12 }}>This browser cannot listen for “Hello Martina”. Chrome, Edge and Safari can.</div>;
  const state = !g.handsFree ? null : g.status !== 'idle' ? 'In a conversation' : g.wakeState === 'listening' ? 'Listening for “Hello Martina”'
    : g.wakeState === 'blocked' ? 'Microphone blocked' : 'Starting…';
  return (
    <div className="stack" style={{ gap: 2 }}>
      <label className="check" style={{ fontSize: small ? 12.5 : 13.5 }} title="While Counta is open, say “Hello Martina” and what you need">
        <input type="checkbox" checked={g.handsFree} onChange={(e) => g.setHandsFree(e.target.checked)} />
        Hands-free: say “Hello Martina”
      </label>
      {(state || g.wakeNote) && <span className="row faint" style={{ gap: 6, fontSize: 11.5, paddingLeft: 24 }}>
        {state && <span className={'g-dot' + (g.wakeState === 'listening' || g.status !== 'idle' ? '' : ' wait')} />}{g.wakeNote || state}</span>}
    </div>
  );
}
