// Installing Counta as an app, and Web Push for the installed app.
// Android/desktop Chrome fire `beforeinstallprompt`; iPhone has no prompt, so we show the Share → Add to
// Home Screen steps instead. iPhone only allows push inside the installed Home Screen app (iOS 16.4+).
import { useEffect, useState } from 'react';
import { rpc, supabase } from './supabase';

type InstallPromptEvent = Event & { prompt: () => Promise<void>; userChoice: Promise<{ outcome: 'accepted' | 'dismissed' }> };

let deferred: InstallPromptEvent | null = null;
const listeners = new Set<() => void>();
const emit = () => listeners.forEach((f) => f());

export function initPwa() {
  window.addEventListener('beforeinstallprompt', (e) => {
    e.preventDefault();
    deferred = e as InstallPromptEvent;
    emit();
  });
  window.addEventListener('appinstalled', () => {
    deferred = null;
    store.set('counta-installed', '1');
    emit();
  });
}

export const store = {
  get(k: string): string | null { try { return localStorage.getItem(k); } catch { return null; } },
  set(k: string, v: string) { try { localStorage.setItem(k, v); } catch { /* private mode */ } },
  del(k: string) { try { localStorage.removeItem(k); } catch { /* private mode */ } },
};

const ua = () => (typeof navigator === 'undefined' ? '' : navigator.userAgent);
export const isIOS = () => /iPad|iPhone|iPod/.test(ua()) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
export const isAndroid = () => /Android/i.test(ua());
export const isStandalone = () => window.matchMedia?.('(display-mode: standalone)').matches || (navigator as any).standalone === true;
export const iosVersion = (): number | null => {
  const m = ua().match(/OS (\d+)_(\d+)/);
  return m ? Number(m[1]) + Number(m[2]) / 10 : null;
};
export const canPromptInstall = () => !!deferred;

export async function promptInstall(): Promise<boolean> {
  if (!deferred) return false;
  const e = deferred;
  await e.prompt();
  const choice = await e.userChoice.catch(() => ({ outcome: 'dismissed' as const }));
  deferred = null;
  emit();
  return choice.outcome === 'accepted';
}

export function pushSupported() {
  return typeof window !== 'undefined' && 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
}
// On iPhone the Push API only exists inside the installed app.
export const pushNeedsInstall = () => isIOS() && !isStandalone();
export const pushPermission = (): NotificationPermission | 'unsupported' => ('Notification' in window ? Notification.permission : 'unsupported');

async function swReady(ms = 8000): Promise<ServiceWorkerRegistration | null> {
  if (!('serviceWorker' in navigator)) return null;
  return Promise.race([navigator.serviceWorker.ready, new Promise<null>((r) => setTimeout(() => r(null), ms))]);
}

function b64url(s: string): Uint8Array {
  const pad = '='.repeat((4 - (s.length % 4)) % 4);
  const raw = atob((s + pad).replace(/-/g, '+').replace(/_/g, '/'));
  return Uint8Array.from(raw, (c) => c.charCodeAt(0));
}
function sameKey(a: ArrayBuffer | null | undefined, b: Uint8Array) {
  if (!a) return false;
  const x = new Uint8Array(a);
  return x.length === b.length && x.every((v, i) => v === b[i]);
}

let vapid: string | null = null;
async function serverKey(): Promise<string> {
  if (vapid) return vapid;
  const { data, error } = await supabase.functions.invoke('push', { body: { action: 'config' } });
  if (error || !data?.publicKey) throw new Error('Notifications are not set up on the server yet.');
  vapid = data.publicKey as string;
  return vapid;
}

export async function currentSubscription(): Promise<PushSubscription | null> {
  if (!pushSupported()) return null;
  const reg = await swReady(3000);
  return reg ? reg.pushManager.getSubscription() : null;
}

async function save(sub: PushSubscription) {
  const j = sub.toJSON();
  await rpc('save_push_subscription', {
    p_endpoint: j.endpoint, p_p256dh: j.keys?.p256dh, p_auth: j.keys?.auth,
    p_platform: isIOS() ? 'ios' : isAndroid() ? 'android' : 'desktop', p_user_agent: ua().slice(0, 300),
  });
}

export async function enablePush(): Promise<{ ok: boolean; error?: string }> {
  try {
    if (!pushSupported()) {
      return { ok: false, error: pushNeedsInstall()
        ? 'On iPhone, add Counta to your Home Screen first, then turn on notifications from the app icon.'
        : 'This browser cannot show notifications.' };
    }
    const perm = await Notification.requestPermission();
    if (perm !== 'granted') {
      return { ok: false, error: perm === 'denied'
        ? 'Notifications are blocked for Counta. Allow them in your browser or phone settings, then try again.'
        : 'Notifications were not allowed.' };
    }
    const reg = await swReady();
    if (!reg) return { ok: false, error: 'The app is still installing. Reload the page and try again.' };
    const key = b64url(await serverKey());
    let sub = await reg.pushManager.getSubscription();
    if (sub && !sameKey(sub.options?.applicationServerKey, key)) { await sub.unsubscribe().catch(() => {}); sub = null; }
    if (!sub) sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key as BufferSource });
    await save(sub);
    store.set('counta-push', '1');
    emit();
    return { ok: true };
  } catch (e) {
    return { ok: false, error: (e as Error).message || 'Could not turn on notifications.' };
  }
}

export async function disablePush() {
  const sub = await currentSubscription();
  if (sub) {
    await rpc('disable_push_subscription', { p_endpoint: sub.endpoint }).catch(() => {});
    await sub.unsubscribe().catch(() => {});
  }
  store.del('counta-push');
  emit();
}

// After sign-in, re-link this device's subscription to whoever is signed in now.
export async function refreshPushSubscription() {
  if (pushPermission() !== 'granted') return;
  const sub = await currentSubscription().catch(() => null);
  if (sub) await save(sub).catch(() => {});
}

// Re-render when install or push state changes.
export function usePwaState() {
  const [, tick] = useState(0);
  const [subscribed, setSubscribed] = useState<boolean | null>(null);
  useEffect(() => {
    const f = () => {
      tick((n) => n + 1);
      currentSubscription().then((s) => setSubscribed(!!s)).catch(() => setSubscribed(false));
    };
    listeners.add(f);
    f();
    return () => { listeners.delete(f); };
  }, []);
  return {
    standalone: isStandalone(), ios: isIOS(), android: isAndroid(), canPrompt: canPromptInstall(),
    pushSupported: pushSupported(), pushNeedsInstall: pushNeedsInstall(), permission: pushPermission(), subscribed,
  };
}
