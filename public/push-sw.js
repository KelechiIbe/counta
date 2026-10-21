/* Counta's own service worker handlers, imported into the Workbox service worker (see vite.config.ts): how a new version
   takes over, and push notifications. */

// A new version waits until the person presses Update now on the notice (src/lib/update.ts). Pages from before that notice
// cannot show it, so while none of the newer pages has run on this device (they leave a marker), a new version takes over
// at once, as it always did, and those pages reload onto it.
self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    try {
      const meta = await caches.open('counta-meta');
      if (await meta.match('/__counta/update-notice')) return;
    } catch (e) { /* no cache storage: take over */ }
    await self.skipWaiting();
  })());
});
self.addEventListener('push', (event) => {
  let d = {};
  try { d = event.data ? event.data.json() : {}; } catch (e) { d = { body: event.data ? event.data.text() : '' }; }
  const title = d.title || 'Counta';
  event.waitUntil(self.registration.showNotification(title, {
    body: d.body || '',
    icon: '/pwa-192.png',
    badge: '/badge-96.png',
    tag: d.tag || undefined,
    renotify: Boolean(d.tag),
    data: { url: d.url || '/', id: d.id || null },
  }));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const target = new URL((event.notification.data && event.notification.data.url) || '/', self.location.origin).href;
  event.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const mine = wins.filter((w) => new URL(w.url).origin === self.location.origin);
    const win = mine.find((w) => w.focused) || mine[0];
    if (win) {
      await win.focus();
      win.postMessage({ type: 'counta:navigate', url: target });
      return;
    }
    await self.clients.openWindow(target);
  })());
});
