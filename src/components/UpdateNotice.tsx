// The notice that a new version of Counta is ready (lib/update.ts). It shows on every page, the phone app and sign-in too.
import { useSyncExternalStore } from 'react';
import { updateLater, updateNow, updateStore } from '../lib/update';
import { Icon } from './Icon';
import { Spinner } from './ui';

export function UpdateNotice() {
  const s = useSyncExternalStore(updateStore.subscribe, updateStore.get);
  if (!s.ready || s.hidden) return null;
  return (
    <div className="update-notice" role="status" aria-live="polite" data-testid="update-notice">
      <span className="update-notice-icon"><Icon name="refresh" size={18} color="#0072F5" /></span>
      <div className="grow" style={{ minWidth: 0 }}>
        <div style={{ fontWeight: 600, fontSize: 14 }}>A new version of Counta is ready</div>
        <div className="muted" style={{ fontSize: 13, lineHeight: 1.45 }}>Updating takes a few seconds and brings you back to this page. Save anything you are typing first.</div>
      </div>
      <div className="update-notice-actions">
        <button className="btn btn-ghost btn-sm" onClick={updateLater} disabled={s.busy}>Later</button>
        <button className="btn btn-primary btn-sm" onClick={() => void updateNow()} disabled={s.busy} data-testid="update-now">
          {s.busy ? <Spinner small /> : <Icon name="refresh" size={14} color="#fff" />}Update now
        </button>
      </div>
    </div>
  );
}
