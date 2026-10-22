// New versions of Counta. The app looks for one when it opens, whenever it comes back to the screen, when the connection
// returns and every half hour while open. A new version downloads in the background and then waits; the notice
// (components/UpdateNotice.tsx) offers it, and Update now starts it: the page reloads once the new version is in charge.
// Later leaves the notice off until the app next comes back to the screen; closing every Counta window also starts it.
import { registerSW } from 'virtual:pwa-register';

type State = { ready: boolean; hidden: boolean; busy: boolean; slow: boolean };
let state: State = { ready: false, hidden: false, busy: false, slow: false };
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

// Update now is remembered for a few minutes in this tab, so a page that loads before the new version has taken over
// carries on with it instead of asking again.
const KEY = 'counta-updating';
const REMEMBER = 3 * 60_000;
function updating() {
  try { return Date.now() - Number(sessionStorage.getItem(KEY) || 0) < REMEMBER; } catch { return false; }
}
function remember(on: boolean) {
  try { if (on) sessionStorage.setItem(KEY, String(Date.now())); else sessionStorage.removeItem(KEY); } catch { /* private mode */ }
}

// Asks the waiting version to take over and reloads the page only once it has: the browser holds a new version back while
// the old one is still answering a request (a slow connection, a font still loading), and a page reloaded before then
// comes back on the old version with the notice again. While it waits it asks again every few seconds, so a newer
// version that arrives meanwhile is started too, and after ten seconds the notice says it is still finishing.
let finishing = false;
function finish() {
  if (finishing) return;
  finishing = true;
  let done = false;
  const go = () => { if (done) return; done = true; window.location.reload(); };
  navigator.serviceWorker.addEventListener('controllerchange', go, { once: true });
  const watched = new WeakSet<ServiceWorker>();
  const ask = () => {
    const w = reg?.waiting;
    if (w) {
      if (!watched.has(w)) { watched.add(w); w.addEventListener('statechange', () => { if (w.state === 'activated') go(); }); }
      w.postMessage({ type: 'SKIP_WAITING' });
    } else if (!reg?.installing) {
      // Nothing waits any more: the new version is in charge (or is just taking over), so the reload opens it.
      go();
    }
  };
  ask();
  const started = Date.now();
  const t = window.setInterval(() => {
    if (done) { window.clearInterval(t); return; }
    if (Date.now() - started > 10_000 && !state.slow) set({ slow: true });
    ask();
  }, 2500);
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
      // Reloaded while the update was still finishing: carry on with it. Otherwise the update is done.
      if (updating()) {
        if (r?.waiting) { set({ ready: true, hidden: false, busy: true }); finish(); } else remember(false);
      }
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
  remember(true);
  if (reg) { finish(); return; }
  // Not registered yet (a very slow start): the plugin asks the waiting version itself, and the page reloads when it takes over.
  navigator.serviceWorker.addEventListener('controllerchange', () => window.location.reload(), { once: true });
  await apply?.(true);
}

export function updateLater() { set({ hidden: true }); }
