const CACHE_NAME = "mac-console-v50";
const ASSETS = [
  "/?v=50",
  "/index.html?v=50",
  "/styles.css?v=50",
  "/app.js?v=50",
  "/manifest.webmanifest?v=50",
  "/icon-192.png",
  "/icon-512.png",
  "/icon.svg"
];

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(ASSETS)));
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key)))
    )
  );
  self.clients.claim();
});

self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET") return;
  event.respondWith(fetch(event.request).catch(() => caches.match(event.request)));
});
