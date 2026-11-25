// MysticLore service worker (docs/contracts/offline.md), served at /sw.js by MysticWeb.OfflineController, which
// writes VERSION, SHELL and PRECACHE above this line. It caches only the site's static files and the offline page,
// never the pages of an account, the services' answers, the LiveView connection or a non-GET request. Lesson
// copies are kept by the page itself in IndexedDB.

const CACHE = "mysticlore-static-" + VERSION
const STATIC_PREFIXES = ["/assets/", "/fonts/", "/icons/", "/images/"]
const STATIC_FILES = ["/favicon.ico"]

self.addEventListener("install", (event) => {
  event.waitUntil(precache().then(() => self.skipWaiting()))
})

// A new version replaces the old one: every older MysticLore cache is deleted.
self.addEventListener("activate", (event) => {
  event.waitUntil(
    (async () => {
      for (const name of await caches.keys()) {
        if (name.startsWith("mysticlore-") && name !== CACHE) await caches.delete(name)
      }
      await self.clients.claim()
    })(),
  )
})

// « Make available offline » asks for the cache to be filled when it is missing (deleted by « Clear offline data »)
// and waits for the answer on the port it sends: the copy is only said available once the cache holds the files.
self.addEventListener("message", (event) => {
  if (!event.data || event.data.type !== "ml:precache") return
  const port = event.ports && event.ports[0]
  event.waitUntil(
    precache().then(
      () => port && port.postMessage({ ok: true }),
      () => port && port.postMessage({ ok: false }),
    ),
  )
})

async function precache() {
  const cache = await caches.open(CACHE)
  await cache.addAll(PRECACHE.map((url) => new Request(url, { cache: "reload", credentials: "same-origin" })))
}

const isStatic = (url) =>
  STATIC_PREFIXES.some((prefix) => url.pathname.startsWith(prefix)) || STATIC_FILES.includes(url.pathname)

self.addEventListener("fetch", (event) => {
  const request = event.request
  if (request.method !== "GET") return
  const url = new URL(request.url)
  if (url.origin !== self.location.origin) return
  if (url.pathname === "/live" || url.pathname.startsWith("/live/")) return
  if (url.pathname === SHELL) {
    event.respondWith(fromNetwork(request, SHELL))
  } else if (request.mode === "navigate" && request.destination === "document") {
    // a page opened in the tab (never a frame: the offline page refuses to be framed)
    event.respondWith(navigation(request))
  } else if (isStatic(url)) {
    // digested files (production) never change: the cached copy is enough; others are refreshed when online
    event.respondWith(url.searchParams.get("vsn") === "d" ? cacheFirst(request) : fromNetwork(request, request))
  }
  // anything else is not handled: the browser asks the network, and nothing is kept
})

// A page of the site: always from the network, never cached. Offline: the offline page (it names the page).
async function navigation(request) {
  try {
    return await fetch(request)
  } catch (error) {
    return (await caches.match(SHELL, { ignoreSearch: true })) || Response.error()
  }
}

// The network first (the copy kept is refreshed), the kept copy when the network fails. A deleted cache (« Clear
// offline data », logout) is never created again here by a page still open: only the installation and « Make
// available offline » fill it.
async function fromNetwork(request, key) {
  try {
    const response = await fetch(request)
    if (response.ok && response.type === "basic" && (await caches.has(CACHE))) {
      const copy = response.clone()
      const cache = await caches.open(CACHE)
      await cache.put(key, copy)
    }
    return response
  } catch (error) {
    return (await caches.match(key, { ignoreSearch: true })) || Response.error()
  }
}

async function cacheFirst(request) {
  return (await caches.match(request)) || fromNetwork(request, request)
}
