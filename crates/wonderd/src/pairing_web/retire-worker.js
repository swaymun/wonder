// Retire old Wonder browser installations without registering a new app.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", event => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter(key => key.startsWith("wonder-shell-")).map(key => caches.delete(key)));
    await self.registration.unregister();
    const windows = await self.clients.matchAll({ type: "window" });
    await Promise.all(windows.map(client => {
      const url = new URL(client.url);
      return client.navigate("/pair" + (url.pathname === "/pair" ? url.hash : ""));
    }));
  })());
});
