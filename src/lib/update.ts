// New versions of Counta. The app looks for one when it opens, whenever it comes back to the screen, when the connection
// returns and every half hour while open. A new version downloads in the background and then waits; the notice
// (components/UpdateNotice.tsx) offers it, and Update now starts it at once: the page reloads on the new version.
// Later leaves the notice off until the app next comes back to the screen; closing every Counta window also starts it.
import { registerSW } from 'virtual:pwa-register';

type State = { ready: boolean; hidden: boolean; busy: boolean };
let state: State = { ready: false, hidden: false, busy: false };
const subs = new Set<() => void>();
const set = (p: Partial<State>) => { state = { ...state, ...p }; subs.forEach((f) => f()); };
export const updateStore = {
  get: () => state,
  subscribe: (f: () => void) => { subs.add(f); return () => { subs.delete(f); }; },
};

let apply: ((reload?: boolean) => Promise<void>) | null = null;
let reg: ServiceWorkerRegistration | undefined;
let lastLook = 0;
const HALF_HOUR = 30 * 60_000;

function look(force = false) {
  if (!reg || !navigator.onLine) return;
  if (!force && Date.now() - lastLook < 60_000) return;
  lastLook = Date.now();
  reg.update().catch(() => { /* offline or the server is busy: the next look tries again */ });
}

// The marker tells a new version that this page can show the notice, so it waits for the person (public/push-sw.js).
// Pages from before the notice cannot show it; while none of these pages has run here, a new version starts by itself.
export const MARKER = '/__counta/update-notice';
async function markReady() {
  try { await (await caches.open('counta-meta')).put(MARKER, new Response('1')); } catch { /* private mode: the old way applies */ }
}

export function startUpdates() {
  if (!('serviceWorker' in navigator)) return;
  void markReady();
  apply = registerSW({
    immediate: true,
    onNeedRefresh: () => set({ ready: true, hidden: false }),
    onRegisteredSW: (_url, r) => {
      reg = r;
      lastLook = Date.now();
      setInterval(() => { if (document.visibilityState === 'visible') look(true); }, HALF_HOUR);
    },
  });
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState !== 'visible') return;
    look();
    if (reg?.waiting && state.hidden) set({ ready: true, hidden: false });
  });
  window.addEventListener('online', () => look());
}

export async function updateNow() {
  set({ busy: true });
  // The page reloads once the new version is in charge; if that signal never comes, it reloads anyway.
  navigator.serviceWorker.addEventListener('controllerchange', () => window.location.reload(), { once: true });
  if (reg?.waiting) reg.waiting.postMessage({ type: 'SKIP_WAITING' });
  else await apply?.(true);
  window.setTimeout(() => window.location.reload(), 6000);
}

export function updateLater() { set({ hidden: true }); }
