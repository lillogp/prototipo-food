/* Service worker minimale: serve per l'installazione; non mette in cache nulla (l'app resta sempre aggiornata). */
self.addEventListener('install', function () { self.skipWaiting(); });
self.addEventListener('activate', function (e) { e.waitUntil(self.clients.claim()); });
self.addEventListener('fetch', function () {});
