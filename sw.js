/* Service worker: serve per l'installazione e per le notifiche push. Non mette in cache nulla (l'app resta sempre aggiornata). */
self.addEventListener('install', function () { self.skipWaiting(); });
self.addEventListener('activate', function (e) { e.waitUntil(self.clients.claim()); });
self.addEventListener('fetch', function () {});
self.addEventListener('push', function (e) {
  var d = {};
  try { d = e.data ? e.data.json() : {}; } catch (x) { d = { title: 'Frog’s', body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Frog’s', {
    body: d.body || '', tag: d.tag || undefined, icon: d.icon || 'icon-192.png', badge: d.badge || 'badge-96.png', data: { url: d.url || './index.html' }
  }));
});
self.addEventListener('notificationclick', function (e) {
  e.notification.close();
  var url = new URL((e.notification.data && e.notification.data.url) || './index.html', self.registration.scope).href;
  var go = (/[?&]go=([^&]+)/.exec(url) || [])[1];
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (cs) {
    for (var i = 0; i < cs.length; i++) {
      if (cs[i].url.indexOf(self.registration.scope) === 0) { if (go) cs[i].postMessage({ go: decodeURIComponent(go) }); return cs[i].focus(); }
    }
    return self.clients.openWindow(url);
  }));
});
