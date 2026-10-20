// Loom's service worker: notifications only. No fetch handler, so nothing is
// cached and every request goes to the server as if this were not here.
//
// The server sends Declarative Web Push messages (`web_push: 8030`). Safari
// 18.4+ can show one by itself; everywhere else it arrives here as plain JSON
// and is shown from the same fields. See `Loom.Push`.

self.addEventListener("install", () => self.skipWaiting())
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()))

self.addEventListener("push", (event) => {
  let message = {}
  try {
    message = event.data ? event.data.json() : {}
  } catch {
    // Not ours to parse; still shown, as a push that shows nothing costs the
    // subscription on Safari.
  }
  const n = message.notification ?? {}
  event.waitUntil(
    self.registration.showNotification(n.title || "loom", {
      body: n.body || "",
      tag: n.tag,
      icon: "/icons/icon-192.png",
      badge: "/icons/icon-192.png",
      data: { navigate: n.navigate || "/", session: n.data?.session ?? null },
    }),
  )
})

// Back to the session: an open window is told which one and brought forward,
// otherwise the app is opened on it.
self.addEventListener("notificationclick", (event) => {
  event.notification.close()
  const { navigate, session } = event.notification.data ?? {}
  event.waitUntil(
    (async () => {
      const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true })
      const open = windows.find((w) => new URL(w.url).origin === self.location.origin)
      if (open) {
        if (session) open.postMessage({ type: "open-session", session })
        await open.focus()
        return
      }
      await self.clients.openWindow(navigate || "/")
    })(),
  )
})
