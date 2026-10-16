/* Counta push handlers. Imported into the Workbox service worker (see vite.config.ts). */
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
