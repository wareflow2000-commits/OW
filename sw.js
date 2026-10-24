/* ORSHAP WMS service worker: app-shell caching only. Remote business data is never cached here. */
'use strict';
const CACHE_NAME = 'orshap-wms-shell-v13-9-58-r2';
const APP_SHELL = [
  './index.html',
  './qr-reader.js?v=13.9.58',
  './app.css?v=13.9.62-topbar-content-distribution',
  './app.js?v=13.9.58-layout3',
  './SQLite-db.js?v=13.9.58',
  './supabase-client.js?v=13.9.58',
  './manifest.webmanifest'
];
self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE_NAME).then(cache => cache.addAll(APP_SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(key => key.startsWith('orshap-wms-shell-') && key !== CACHE_NAME).map(key => caches.delete(key)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', event => {
  const request = event.request;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;
  if (request.mode === 'navigate') {
    event.respondWith(fetch(request).then(response => {
      if (response.ok) caches.open(CACHE_NAME).then(cache => cache.put('./index.html', response.clone()));
      return response;
    }).catch(() => caches.match('./index.html')));
    return;
  }
  const isAppAsset = /\.(?:js|css)$/.test(url.pathname);
  if (isAppAsset) {
    event.respondWith(fetch(request).then(response => {
      if (response.ok && response.type === 'basic') caches.open(CACHE_NAME).then(cache => cache.put(request, response.clone()));
      return response;
    }).catch(() => caches.match(request)));
    return;
  }
  event.respondWith(caches.match(request).then(cached => cached || fetch(request).then(response => {
    if (response.ok && response.type === 'basic') caches.open(CACHE_NAME).then(cache => cache.put(request, response.clone()));
    return response;
  })));
});
