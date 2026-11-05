/* Service worker dell'amministrazione: serve per l'installazione. Non mette in cache nulla (dati sempre aggiornati). */
self.addEventListener('install', function () { self.skipWaiting(); });
self.addEventListener('activate', function (e) { e.waitUntil(self.clients.claim()); });
self.addEventListener('fetch', function () {});
