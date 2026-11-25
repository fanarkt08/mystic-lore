// MysticLore browser entrypoint: LiveView socket, colocated hooks, navigation progress bar, member preferences.
// No secret and no direct call to the internal services ever happens in the browser.
import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/web"
import topbar from "../vendor/topbar"
import {reducedMotion} from "./motion"
import {watchConnection} from "./connection"
import {OfflineHooks, startOffline} from "./offline"
import {FocusHooks} from "./focus"

// the offline page (/offline, cached by the service worker) has no session, hence no CSRF token
const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
// The browser's time zone is only sent (the server validates it, for the `auto` preference): never saved.
const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken, tz: timeZone},
  hooks: {...colocatedHooks, ...OfflineHooks, ...FocusHooks},
})

// No animated progress bar when motion is reduced (preference or system setting).
topbar.config({barColors: {0: "#AD8BFF"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => reducedMotion() || topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// Preferences saved (or a VIP theme paused) while the page is open: same `data-*` attributes as the server render.
window.addEventListener("phx:ml:prefs", ({detail}) => {
  const root = document.documentElement
  for (const [name, value] of Object.entries(detail.attrs)) {
    value == null ? root.removeAttribute(name) : root.setAttribute(name, value)
  }
  document.querySelector("meta[name='color-scheme']")?.setAttribute("content", detail.scheme)
})

liveSocket.connect()
window.liveSocket = liveSocket
// « Reconnecting… » / « You seem to be offline » banner, « Retry now », live forms disabled while disconnected
watchConnection(liveSocket)
// Offline lessons: service worker for members, copies and queue in IndexedDB, synchronization
startOffline()

if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    reloader.enableServerLogs()
    window.liveReloader = reloader
  })
}
