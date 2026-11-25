// Connection status of the page: a polite banner (#connection-status, rendered by MysticWeb.Layouts.flash_group)
// says when the LiveView socket is lost or the browser is offline, and « Retry now » really reconnects the socket.
// While disconnected, the live forms' submit buttons are disabled: LiveView drops events it can't send, so nothing
// may look saved. The offline lesson views (`[data-offline-ok]`) are exempted, since they queue answers locally.

const SHOW_AFTER_MS = 1000

// buttons whose click needs the server: an event name, or JS commands that push or navigate
const needsServer = (value) => {
  const v = (value || "").trim()
  if (!v.startsWith("[")) return true
  return /\["(push|navigate|patch)"/.test(v)
}

const ACTIONS = [
  "[data-phx-main] form[phx-submit] button:not([type=button]):not([type=reset])",
  "[data-phx-main] form[phx-submit] input[type=submit]",
  "[data-phx-main] button[phx-click]",
].join(", ")

export function watchConnection(liveSocket) {
  const socket = liveSocket.getSocket()
  // lessons kept and answers waiting on this device (`ml:offline-state`, from offline.js)
  let device = { packages: 0, pending: 0 }
  let socketLost = false
  let unloading = false
  let shown = false
  let timer = null

  const banner = () => document.getElementById("connection-status")
  const live = () => document.querySelector("[data-phx-main]") !== null
  const offline = () => navigator.onLine === false
  const lost = () => offline() || (socketLost && live())

  function setActionsDisabled(disabled) {
    if (disabled) {
      document.querySelectorAll(ACTIONS).forEach((el) => {
        if (el.disabled || el.closest("#connection-status, #flash-group, #notification-toasts, [data-offline-ok]")) return
        if (el.matches("button[phx-click]") && !needsServer(el.getAttribute("phx-click"))) return
        // the focused control stays focusable (a disabled one loses the keyboard focus): aria-disabled, blocked below
        if (el === document.activeElement) el.setAttribute("aria-disabled", "true")
        else el.disabled = true
        el.setAttribute("data-ml-offline", "")
      })
    } else {
      document.querySelectorAll("[data-ml-offline]").forEach((el) => {
        el.disabled = false
        el.removeAttribute("aria-disabled")
        el.removeAttribute("data-ml-offline")
      })
    }
  }
  // while the connection is lost, the marked actions do nothing (clicks, and form submissions, Enter included)
  for (const type of ["click", "submit"])
    window.addEventListener(type, (e) => {
      const blocked = type === "submit" ? e.target.querySelector?.("[data-ml-offline]") : e.target.closest?.("[data-ml-offline]")
      if (blocked) {
        e.preventDefault()
        e.stopImmediatePropagation()
      }
    }, true)

  function paint() {
    const el = banner()
    if (!el) return
    const text = el.querySelector("#connection-status-text")
    const pending = el.querySelector("#connection-status-pending")
    const link = el.querySelector("#connection-offline-link")
    const kept = device.packages > 0 || device.pending > 0
    if (shown && lost()) {
      text.textContent = offline() ? (kept ? el.dataset.offlineLessons : el.dataset.offline) : el.dataset.reconnecting
      if (pending) {
        pending.textContent = (el.dataset.pending || "").replace("%{count}", device.pending)
        pending.hidden = !(offline() && device.pending > 0)
      }
      if (link) link.hidden = !(offline() && kept)
      el.hidden = false
      document.documentElement.setAttribute("data-connection", offline() ? "offline" : "lost")
    } else {
      el.hidden = true
      document.documentElement.removeAttribute("data-connection")
    }
  }

  function update() {
    if (unloading) return
    clearTimeout(timer)
    setActionsDisabled(lost())
    if (!lost()) {
      shown = false
    } else if (offline()) {
      // the browser says so: no need to wait
      shown = true
    } else if (!shown) {
      // a socket that comes back within a second (navigation, short blip) shows nothing
      timer = setTimeout(() => {
        shown = lost()
        paint()
      }, SHOW_AFTER_MS)
    }
    paint()
  }

  // Reconnect now instead of waiting for the next backoff step. After a clean disconnect the socket does not
  // reconnect by itself, so it is connected again; otherwise the socket's own « reconnect immediately » path is used
  // (the one it follows when a hidden page becomes visible again).
  function retry() {
    if (socket.isConnected()) return update()
    if (socket.closeWasClean || !socket.connection) {
      socket.connect()
    } else if (typeof socket.handleVisibilityChange === "function") {
      socket.handleVisibilityChange()
    } else {
      socket.disconnect(() => socket.connect())
    }
  }

  socket.onOpen(() => {
    socketLost = false
    update()
  })
  socket.onError(() => {
    socketLost = true
    update()
  })
  socket.onClose(() => {
    socketLost = true
    update()
  })

  window.addEventListener("offline", update)
  window.addEventListener("online", () => {
    update()
    if (socketLost && live()) retry()
  })
  window.addEventListener("pagehide", () => (unloading = true))
  window.addEventListener("pageshow", () => {
    unloading = false
    update()
  })
  // a live navigation renders a new page (and a new banner)
  window.addEventListener("phx:page-loading-stop", update)
  window.addEventListener("ml:offline-state", ({ detail }) => {
    device = { packages: detail?.packages || 0, pending: detail?.pending || 0 }
    paint()
  })

  document.addEventListener("click", (e) => {
    if (e.target.closest("#connection-retry")) {
      e.preventDefault()
      retry()
    }
  })

  // a live form submitted while the connection is lost (Enter in a field…) is stopped before LiveView sees it
  window.addEventListener(
    "submit",
    (e) => {
      if (
        lost() &&
        e.target.closest("[data-phx-main]") &&
        e.target.hasAttribute("phx-submit") &&
        !e.target.closest("[data-offline-ok]")
      ) {
        e.preventDefault()
        e.stopImmediatePropagation()
        shown = true
        paint()
      }
    },
    true,
  )

  update()
}
