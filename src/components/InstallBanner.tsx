import { useEffect, useState } from 'react';
import { useToast } from '../state/session';
import { enablePush, iosVersion, promptInstall, store, usePwaState } from '../lib/pwa';
import { Icon } from './Icon';

const WEEK = 7 * 24 * 3600_000;
const snoozed = (k: string) => Number(store.get(k) || 0) > Date.now() - WEEK;

// The iOS share glyph, so the steps match what is on screen.
function ShareGlyph() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#0072F5" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-label="Share" style={{ verticalAlign: '-3px' }}>
      <path d="M12 3v12" /><path d="m8 7 4-4 4 4" /><path d="M6 11H5a1 1 0 0 0-1 1v8a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1v-8a1 1 0 0 0-1-1h-1" />
    </svg>
  );
}

// Asks to install Counta as an app, then (once installed, or on browsers that allow it) to turn on
// notifications. Each ask can be put off for a week.
export function InstallBanner({ phone = false }: { phone?: boolean }) {
  const s = usePwaState();
  const toast = useToast();
  const [hideInstall, setHideInstall] = useState(() => snoozed('counta-install-later'));
  const [hidePush, setHidePush] = useState(() => snoozed('counta-push-later'));
  const [busy, setBusy] = useState(false);
  const touch = s.ios || s.android;

  // Permission granted earlier but this device lost its subscription (new key, cleared data): quietly resubscribe.
  useEffect(() => {
    if (s.permission === 'granted' && s.subscribed === false && s.pushSupported) enablePush().catch(() => {});
  }, [s.permission, s.subscribed, s.pushSupported]);

  const later = (k: string, set: (b: boolean) => void) => { store.set(k, String(Date.now())); set(true); };

  let body: JSX.Element | null = null;
  if (!s.standalone && !hideInstall && (s.canPrompt || touch)) {
    const oldIos = s.ios && (iosVersion() ?? 99) < 16.4;
    body = (
      <>
        <img src="/pwa-192.png" alt="" width={40} height={40} style={{ borderRadius: 10, flex: 'none' }} />
        <div className="grow" style={{ minWidth: 0 }}>
          <div style={{ fontSize: 14, fontWeight: 600 }}>Install Counta on this {touch ? 'phone' : 'computer'}</div>
          {s.ios ? (
            <div className="ink3" style={{ fontSize: 13, lineHeight: 1.5, marginTop: 2 }}>
              Tap <ShareGlyph /> <b>Share</b> in Safari, then <b>Add to Home Screen</b>. Open Counta from its icon and you can turn on notifications.
              {oldIos && ' Notifications need iOS 16.4 or later.'}
            </div>
          ) : s.canPrompt ? (
            <div className="ink3" style={{ fontSize: 13, lineHeight: 1.5, marginTop: 2 }}>It opens full screen from your home screen, keeps working without data and can notify you.</div>
          ) : (
            <div className="ink3" style={{ fontSize: 13, lineHeight: 1.5, marginTop: 2 }}>Open the browser menu <b>⋮</b> and tap <b>Install app</b> or <b>Add to Home screen</b>.</div>
          )}
        </div>
        <div className="row" style={{ gap: 4, flex: 'none' }}>
          {s.canPrompt && <button className="btn btn-primary btn-sm" onClick={async () => { const ok = await promptInstall(); if (!ok) later('counta-install-later', setHideInstall); }}>Install</button>}
          <button className="x-btn" aria-label="Not now" onClick={() => later('counta-install-later', setHideInstall)}><Icon name="x" size={16} color="#9CA3AF" /></button>
        </div>
      </>
    );
  } else if (s.pushSupported && s.permission === 'default' && !hidePush && (s.standalone || !touch || s.android)) {
    body = (
      <>
        <span style={{ width: 40, height: 40, borderRadius: 10, background: '#F0F7FF', display: 'grid', placeItems: 'center', flex: 'none' }}><Icon name="bell" size={20} color="#0072F5" /></span>
        <div className="grow" style={{ minWidth: 0 }}>
          <div style={{ fontSize: 14, fontWeight: 600 }}>Turn on notifications</div>
          <div className="ink3" style={{ fontSize: 13, lineHeight: 1.5, marginTop: 2 }}>Counta tells you when a count needs approval, an invoice needs checking or stock is on its way to your branch.</div>
        </div>
        <div className="row" style={{ gap: 4, flex: 'none' }}>
          <button className="btn btn-primary btn-sm" disabled={busy} onClick={async () => {
            setBusy(true);
            const r = await enablePush();
            setBusy(false);
            if (r.ok) toast('Notifications are on for this device'); else { toast(r.error || 'Could not turn on notifications', 'err'); later('counta-push-later', setHidePush); }
          }}>Turn on</button>
          <button className="x-btn" aria-label="Not now" onClick={() => later('counta-push-later', setHidePush)}><Icon name="x" size={16} color="#9CA3AF" /></button>
        </div>
      </>
    );
  }
  if (!body) return null;
  return (
    <div className={'install-banner rise' + (phone ? ' m-card' : ' card')} role="region" aria-label="Install and notifications">
      {body}
    </div>
  );
}
