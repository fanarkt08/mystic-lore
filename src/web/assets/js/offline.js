// Offline lessons, browser side (docs/contracts/offline.md). The service worker is registered only on a device
// where a member made a lesson available offline. Copies are kept in IndexedDB for the signed-in member only, and
// an answer given offline is queued, never graded here: it is replayed through POST /offline/sync once back online.
// Logout, another member signing in or an ended Premium access delete the copies. Every sentence shown comes
// translated from the server (`data-texts`).
import * as store from "./offline_store"

const SYNC_LOCK = "mysticlore-offline-sync"
const MAX_REPORTS = 20
const state = { packages: 0, pending: 0 }

const fill = (text, values) => String(text || "").replace(/%\{(\w+)\}/g, (match, key) => (key in values ? values[key] : match))
const pageMember = () => document.getElementById("offline-notice")?.dataset.member || null
const isOnline = () => navigator.onLine !== false
const texts = (el) => {
  try {
    return JSON.parse(el.dataset.texts || "{}")
  } catch (_error) {
    return {}
  }
}

function formats(el) {
  const lang = el.dataset.locale || document.documentElement.lang || undefined
  const zone = el.dataset.timeZone || undefined
  const options = { year: "numeric", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", timeZoneName: "short" }
  let dates
  try {
    dates = new Intl.DateTimeFormat(lang, { ...options, timeZone: zone })
  } catch (_error) {
    dates = new Intl.DateTimeFormat(lang, options)
  }
  const sizes = new Intl.NumberFormat(lang, { style: "unit", unit: "kilobyte", unitDisplay: "short", maximumFractionDigits: 1 })
  return {
    date: (iso) => (iso ? dates.format(new Date(iso)) : ""),
    size: (bytes) => sizes.format(Math.max(bytes, 1) / 1000),
  }
}

function element(tag, attrs = {}, ...children) {
  const el = document.createElement(tag)
  for (const [name, value] of Object.entries(attrs)) {
    if (value === false || value === null || value === undefined) continue
    if (name === "text") el.textContent = value
    else el.setAttribute(name, value === true ? "" : value)
  }
  el.append(...children.filter((child) => child !== null && child !== undefined && child !== false))
  return el
}

const icon = (name) => element("span", { class: `${name} size-5`, "aria-hidden": "true" })

// ---------------------------------------------------------------- device state

async function publish() {
  window.dispatchEvent(new CustomEvent("ml:offline-state", { detail: { ...state } }))
}

async function refreshState(member) {
  if (!store.supported() || !(await store.exists())) {
    state.packages = 0
    state.pending = 0
  } else {
    member = member || (await deviceMember())
    state.packages = (await livePackages(member)).packages.length
    state.pending = (await pendingActions(member)).length
  }
  publish()
  return state
}

export const offlineState = () => ({ ...state })

async function deviceMember() {
  return (await store.get("meta", "member"))?.id || null
}

// The device's data belongs to one member: another member signed in → everything of the previous one is deleted.
async function claimDevice(member) {
  const meta = await store.get("meta", "member")
  if (meta && meta.id === member) return false
  if (meta) await store.clearAll()
  await store.put("meta", { key: "member", id: member })
  return Boolean(meta)
}

// Copies of `member` still valid; expired ones (and any of another member) are deleted, never shown.
async function livePackages(member) {
  const now = Date.now()
  const packages = []
  const expired = []
  if (!member) return { packages, expired }
  for (const pkg of await store.getAll("packages")) {
    if (pkg.member_id !== member) {
      await store.remove("packages", pkg.lesson_id)
    } else if (!(Date.parse(pkg.expires_at) > now)) {
      await store.remove("packages", pkg.lesson_id)
      expired.push(pkg)
    } else {
      packages.push(pkg)
    }
  }
  packages.sort((a, b) => String(a.title).localeCompare(String(b.title)))
  return { packages, expired }
}

async function pendingActions(member) {
  if (!member) return []
  return (await store.getAll("queue"))
    .filter((action) => action.member_id === member)
    .sort((a, b) => String(a.queued_at).localeCompare(String(b.queued_at)))
}

async function lastReports(member) {
  if (!member) return []
  return (await store.getAll("reports"))
    .filter((report) => report.member_id === member)
    .sort((a, b) => String(b.at).localeCompare(String(a.at)))
}

async function saveReports(reports) {
  for (const report of reports) await store.put("reports", report)
  const all = (await store.getAll("reports")).sort((a, b) => String(b.at).localeCompare(String(a.at)))
  for (const old of all.slice(MAX_REPORTS)) await store.remove("reports", old.key)
}

async function deleteCaches() {
  if (!window.caches) return
  for (const name of await caches.keys()) if (name.startsWith("mysticlore-")) await caches.delete(name)
}

// Everything this device keeps offline goes: the database, the caches and the service worker (logout, « Clear
// offline data »). The next « Make available offline » registers the worker again.
async function forgetDevice() {
  await store.destroy()
  await deleteCaches()
  for (const registration of (await navigator.serviceWorker?.getRegistrations?.()) || []) await registration.unregister()
}

// ---------------------------------------------------------------- service worker

function registerWorker() {
  return navigator.serviceWorker.register("/sw.js", { scope: "/", updateViaCache: "none" })
}

const within = (promise, ms, what) =>
  Promise.race([promise, new Promise((_resolve, reject) => setTimeout(() => reject(new Error(what)), ms))])

// Asks the worker to fill its cache (static files and offline page) and waits for its answer.
function precacheBy(worker) {
  return new Promise((resolve, reject) => {
    if (!worker) return reject(new Error("no active service worker"))
    const channel = new MessageChannel()
    channel.port1.onmessage = (event) => (event.data?.ok ? resolve() : reject(new Error("precache failed")))
    worker.postMessage({ type: "ml:precache" }, [channel.port2])
  })
}

// The copy is only « available offline » once the worker is active and its cache holds the static files and the
// offline page in the current language (a cache deleted by « Clear offline data » is filled again first).
async function ensureWorker() {
  await registerWorker()
  const registration = await within(navigator.serviceWorker.ready, 15000, "service worker not ready")
  const cached = (await caches.keys()).some((name) => name.startsWith("mysticlore-static-"))
  if (cached && navigator.serviceWorker.controller) {
    // the offline page, in the current language: fetched through the worker, which keeps it
    await fetch("/offline", { credentials: "same-origin", cache: "no-store" }).catch(() => null)
  } else {
    await within(precacheBy(registration.active), 30000, "precache timeout")
  }
  return registration
}

// ---------------------------------------------------------------- copies

async function download(lessonId) {
  let response
  try {
    response = await fetch(`/offline/packages/${encodeURIComponent(lessonId)}`, {
      headers: { accept: "application/json" },
      credentials: "same-origin",
      cache: "no-store",
    })
  } catch (_error) {
    return { ok: false }
  }
  const body = await response.json().catch(() => null)
  if (!response.ok || !body?.package) return { ok: false, status: response.status, message: body?.message }
  try {
    await ensureWorker()
  } catch (_error) {
    // the worker didn't start: nothing is kept (the copy couldn't be opened offline)
    return { ok: false }
  }
  const pkg = body.package
  await claimDevice(pkg.member_id)
  const record = { ...pkg, stored_at: new Date().toISOString(), size: 0 }
  record.size = new Blob([JSON.stringify(record)]).size
  await store.put("packages", record)
  await refreshState(pkg.member_id)
  return { ok: true, package: record }
}

async function removePackage(lessonId) {
  await store.remove("packages", lessonId)
  await refreshState()
}

async function queueAction(pkg, kind, answer, label) {
  const action = {
    key: crypto.randomUUID(),
    member_id: pkg.member_id,
    lesson_id: pkg.lesson_id,
    title: pkg.title,
    kind,
    answer: kind === "submit" ? answer : undefined,
    answer_label: label,
    revision: pkg.revision,
    queued_at: new Date().toISOString(),
  }
  await store.put("queue", action)
  await refreshState(pkg.member_id)
  return action
}

// Premium access ended: every premium copy goes (all copies are premium). The answers stay queued: the server
// refuses them explicitly at the next synchronization if the access is still over. → number of copies deleted.
let purging = Promise.resolve(0)
function purge(message) {
  purging = purging.catch(() => 0).then(async () => {
    if (!(await store.exists())) return 0
    const packages = await store.getAll("packages")
    for (const pkg of packages) await store.remove("packages", pkg.lesson_id)
    await refreshState()
    if (packages.length) showNotice(message)
    return packages.length
  })
  return purging
}

// the server's dated message; its generic sentence (`data-generic`) if an event came without one
function showNotice(message) {
  const notice = document.getElementById("offline-notice") || document.getElementById("offline-alert")
  if (!notice) return
  notice.querySelector("#offline-notice-text, #offline-alert-text").textContent = message || notice.dataset.generic || ""
  notice.hidden = false
}

// ---------------------------------------------------------------- synchronization

async function fetchSession() {
  try {
    const response = await fetch("/offline/session", { headers: { accept: "application/json" }, credentials: "same-origin", cache: "no-store" })
    if (response.status === 401) return { status: "signed_out" }
    if (!response.ok) return { status: "error" }
    return { status: "ok", ...(await response.json()) }
  } catch (_error) {
    return { status: "error" }
  }
}

function report(action, result) {
  return {
    key: action.key,
    member_id: action.member_id,
    lesson_id: action.lesson_id,
    lesson_title: action.title,
    kind: action.kind,
    status: result.status,
    reason: result.reason || null,
    correct: result.correct ?? null,
    title: result.title || "",
    message: result.message || "",
    xp_text: result.xp_text || "",
    at: new Date().toISOString(),
  }
}

let syncing = null

// → { status: "offline" | "busy" | "signed_out" | "error" | "empty" | "done", reports?, wiped? }
export function synchronize() {
  if (syncing) return syncing
  syncing = (async () => {
    try {
      if (!isOnline()) return { status: "offline" }
      if (!store.supported() || !(await store.exists())) return { status: "empty" }
      if (navigator.locks) {
        return await navigator.locks.request(SYNC_LOCK, { ifAvailable: true }, (lock) => (lock ? runSync() : { status: "busy" }))
      }
      return await runSync()
    } catch (_error) {
      return { status: "error" }
    } finally {
      syncing = null
    }
  })()
  return syncing
}

async function runSync() {
  const session = await fetchSession()
  if (session.status !== "ok") return { status: session.status }
  const wiped = await claimDevice(session.member_id)
  if (session.premium === false) await purge(session.message)
  const actions = await pendingActions(session.member_id)
  if (!actions.length) {
    await refreshState(session.member_id)
    return { status: "empty", wiped }
  }
  const response = await fetch("/offline/sync", {
    method: "POST",
    credentials: "same-origin",
    headers: { "content-type": "application/json", accept: "application/json", "x-csrf-token": session.csrf_token },
    body: JSON.stringify({ actions: actions.slice(0, 50).map(({ key, lesson_id, kind, answer, revision }) => ({ key, lesson_id, kind, answer, revision })) }),
  })
  if (response.status === 401) return { status: "signed_out" }
  if (!response.ok) return { status: "error" }
  const body = await response.json()
  const byKey = new Map(actions.map((action) => [action.key, action]))
  const reports = []
  for (const result of body.results || []) {
    const action = byKey.get(result.key)
    if (!action) continue
    reports.push(report(action, result))
    if (result.status === "retry") continue
    await store.remove("queue", action.key)
    // a lesson that changed or vanished: its copy is outdated
    if (result.reason === "lesson_changed" || result.reason === "not_found") await store.remove("packages", action.lesson_id)
  }
  if (body.purge) await purge(body.purge.message)
  await saveReports(reports)
  await refreshState(session.member_id)
  return { status: "done", reports, wiped }
}

function autoSync() {
  if (isOnline() && (state.pending > 0 || state.packages > 0)) return synchronize().then((result) => (refreshState(), result))
  return Promise.resolve({ status: "empty" })
}

// ---------------------------------------------------------------- logout: delete everything first

function interceptLogout() {
  window.addEventListener(
    "phoenix.link.click",
    (event) => {
      const link = event.target.closest?.('a[data-method="delete"][data-to="/logout"]')
      if (!link || link.dataset.offlineCleared === "1") return
      event.preventDefault()
      link.dataset.offlineCleared = "1"
      const cleared = forgetDevice().catch(() => null)
      // never keep the member waiting: the server's Clear-Site-Data does the same
      Promise.race([cleared, new Promise((resolve) => setTimeout(resolve, 3000))]).finally(() => link.click())
    },
    true,
  )
}

// ---------------------------------------------------------------- shared rendering

function syncBlock(root, t, pending, result) {
  const status = root.querySelector("#offline-sync-status")
  const reason = root.querySelector("#offline-sync-reason")
  const button = root.querySelector("#offline-sync-now")
  const lines = []
  if (result) {
    const message = {
      done: t.sync_done,
      empty: pending.length ? "" : t.sync_nothing,
      signed_out: t.sync_signed_out,
      error: t.sync_error,
      busy: t.sync_busy,
      offline: "",
    }[result.status]
    if (message) lines.push(message)
  }
  lines.push(pending.length ? fill(t.pending_count, { count: pending.length }) : t.sync_nothing)
  status.textContent = [...new Set(lines.filter(Boolean))].join(" ")
  if (!isOnline()) {
    button.disabled = true
    reason.textContent = t.sync_offline_reason
  } else if (!pending.length) {
    button.disabled = true
    reason.textContent = t.sync_nothing
  } else {
    button.disabled = false
    reason.textContent = ""
  }
}

function resultsBlock(root, t, fmt, reports) {
  const section = root.querySelector("#offline-results")
  const list = root.querySelector("#offline-results-list")
  if (!section || !list) return
  section.hidden = reports.length === 0
  list.replaceChildren(
    ...reports.slice(0, 6).map((r) =>
      element(
        "li",
        { class: `offline-result offline-result-${r.status === "done" ? (r.correct === false ? "wrong" : "right") : r.status}` },
        element("p", { class: "font-medium text-ink", text: `${r.lesson_title} — ${r.title}` }),
        r.message ? element("p", { class: "text-sm", text: r.message }) : null,
        r.xp_text ? element("p", { class: "text-sm font-medium", text: r.xp_text }) : null,
        element("p", { class: "text-xs text-muted", text: fill(t.result_at, { date: fmt.date(r.at) }) }),
      ),
    ),
  )
}

function packageItem(t, fmt, pkg, pending, { link, onRemove }) {
  const waiting = pending.some((action) => action.lesson_id === pkg.lesson_id)
  return element(
    "li",
    { class: "offline-item", id: `offline-item-${pkg.lesson_id}` },
    element(
      "div",
      { class: "min-w-0 flex-1 space-y-1" },
      element(
        "p",
        { class: "flex flex-wrap items-center gap-2" },
        element("span", { class: "tag", text: pkg.kind === "exercise" ? t.kind_exercise : t.kind_story }),
        waiting ? element("span", { class: "tag tag-info", text: t.pending_tag }) : null,
      ),
      link
        ? element("a", { href: `/offline?lesson=${encodeURIComponent(pkg.lesson_id)}`, class: "offline-item-title", text: pkg.title })
        : element("p", { class: "offline-item-title", text: pkg.title }),
      element("p", { class: "text-sm text-muted", text: pkg.adventure?.title || "" }),
      element("p", { class: "text-sm", text: fill(t.expires, { date: fmt.date(pkg.expires_at) }) }),
      element("p", {
        class: "text-xs text-muted",
        text: [fill(t.downloaded, { date: fmt.date(pkg.downloaded_at) }), fill(t.size, { size: fmt.size(pkg.size || 0) }), fill(t.version, { revision: pkg.revision })].join(" · "),
      }),
    ),
    onRemove
      ? (() => {
          const button = element("button", { type: "button", class: "btn btn-ghost", id: `offline-remove-${pkg.lesson_id}` }, icon("hero-trash"), element("span", { text: t.remove }))
          button.addEventListener("click", () => onRemove(pkg))
          return button
        })()
      : null,
  )
}

// ---------------------------------------------------------------- hooks (live pages)

const OfflineLesson = {
  mounted() {
    this.t = texts(this.el)
    this.fmt = formats(this.el)
    this.message = ""
    this.status = this.el.querySelector("#offline-copy-status")
    this.button = this.el.querySelector("#offline-download")
    this.label = this.button.querySelector("[data-label]")
    this.open = this.el.querySelector("#offline-open")
    this.removeButton = this.el.querySelector("#offline-remove")
    this.button.addEventListener("click", () => this.download())
    this.removeButton.addEventListener("click", () => this.remove())
    this.repaint = () => this.render()
    for (const name of ["ml:offline-state", "online", "offline"]) window.addEventListener(name, this.repaint)
    this.render()
  },
  destroyed() {
    for (const name of ["ml:offline-state", "online", "offline"]) window.removeEventListener(name, this.repaint)
  },
  async current() {
    const member = pageMember()
    if (!member || !(await store.exists())) return { pkg: null, pending: [] }
    await claimDevice(member)
    const { packages } = await livePackages(member)
    const pending = await pendingActions(member)
    const id = this.el.dataset.lessonId
    return { pkg: packages.find((p) => p.lesson_id === id) || null, pending: pending.filter((a) => a.lesson_id === id) }
  },
  async render() {
    const t = this.t
    if (!store.supported()) {
      this.status.textContent = t.unsupported
      this.button.disabled = true
      return
    }
    const { pkg, pending } = await this.current()
    const outdated = pkg && String(pkg.revision) !== this.el.dataset.revision
    const lines = [this.message]
    if (pkg) lines.push(outdated ? t.outdated : fill(t.downloaded_ok, { date: this.fmt.date(pkg.expires_at) }))
    if (pending.length) lines.push(fill(t.pending_count, { count: pending.length }))
    if (!isOnline()) lines.push(t.need_connection)
    this.status.textContent = lines.filter(Boolean).join(" ")
    this.label.textContent = pkg ? t.download_again : t.download
    this.button.disabled = !isOnline() || this.busy === true
    this.open.hidden = !pkg
    this.removeButton.hidden = !pkg
  },
  async download() {
    this.busy = true
    this.message = ""
    this.label.textContent = this.t.downloading
    this.button.disabled = true
    const result = await download(this.el.dataset.lessonId)
    this.busy = false
    this.message = result.ok ? "" : result.unsupported ? this.t.unsupported : result.message || this.t.download_failed
    await this.render()
    if (result.ok) this.open.focus()
  },
  async remove() {
    await removePackage(this.el.dataset.lessonId)
    this.message = fill(this.t.removed, { title: this.el.dataset.title })
    await this.render()
    this.button.focus()
  },
}

const OfflineSettings = {
  mounted() {
    this.t = texts(this.el)
    this.fmt = formats(this.el)
    this.result = null
    this.notes = []
    this.el.querySelector("#offline-sync-now").addEventListener("click", () => this.sync())
    this.clearButton = this.el.querySelector("#offline-clear")
    this.clearButton.addEventListener("click", () => this.clear())
    this.repaint = () => this.render()
    for (const name of ["ml:offline-state", "online", "offline"]) window.addEventListener(name, this.repaint)
    this.render()
  },
  destroyed() {
    for (const name of ["ml:offline-state", "online", "offline"]) window.removeEventListener(name, this.repaint)
  },
  async render() {
    const t = this.t
    const summary = this.el.querySelector("#offline-summary")
    const list = this.el.querySelector("#offline-packages")
    if (!store.supported()) {
      summary.textContent = t.unsupported
      return
    }
    const member = pageMember()
    let packages = []
    let pending = []
    let reports = []
    if (member && (await store.exists())) {
      await claimDevice(member)
      const live = await livePackages(member)
      packages = live.packages
      for (const pkg of live.expired) this.notes.push(fill(t.expired_removed, { title: pkg.title }))
      pending = await pendingActions(member)
      reports = await lastReports(member)
    }
    const used = packages.reduce((sum, pkg) => sum + (pkg.size || 0), 0)
    summary.textContent = [
      ...this.notes,
      packages.length ? `${fill(t.count_lessons, { count: packages.length })} · ${fill(t.total_size, { size: this.fmt.size(used) })}` : t.empty,
    ].join(" ")
    list.replaceChildren(
      ...packages.map((pkg) =>
        packageItem(t, this.fmt, pkg, pending, {
          link: true,
          onRemove: async (removed) => {
            await removePackage(removed.lesson_id)
            this.notes = [fill(t.removed, { title: removed.title })]
            await this.render()
            this.el.querySelector("#offline-summary").focus()
          },
        }),
      ),
    )
    syncBlock(this.el, t, pending, this.result)
    resultsBlock(this.el, t, this.fmt, reports)
    this.clearButton.disabled = false
    this.pendingCount = pending.length
  },
  async sync() {
    const button = this.el.querySelector("#offline-sync-now")
    button.disabled = true
    button.querySelector("[data-label]").textContent = this.t.syncing
    this.result = await synchronize()
    button.querySelector("[data-label]").textContent = this.t.sync_now
    this.notes = []
    await this.render()
  },
  async clear() {
    const t = this.t
    const question = this.pendingCount ? fill(t.clear_confirm_pending, { count: this.pendingCount }) : t.clear_confirm
    if (!window.confirm(question)) return
    this.clearButton.disabled = true
    this.clearButton.querySelector("[data-label]").textContent = t.clearing
    // the database, the caches and the worker: nothing offline is left on this device
    await forgetDevice().catch(() => null)
    this.clearButton.querySelector("[data-label]").textContent = t.clear
    this.notes = [t.cleared]
    this.result = null
    await refreshState()
    await this.render()
  },
}

export const OfflineHooks = { OfflineLesson, OfflineSettings }

// ---------------------------------------------------------------- the offline page (/offline, no LiveView)

const ALLOWED_TAGS = new Set(["DIV", "P", "FIELDSET", "LEGEND", "LABEL", "INPUT", "SPAN"])
const ALLOWED_ATTRS = new Set(["class", "id", "for", "type", "name", "value"])

// The package HTML is rendered and escaped by the server; it is still rebuilt here from an allowlist (no script,
// no event attribute, no link, no comment survives).
function sanitized(html) {
  const doc = new DOMParser().parseFromString(String(html || ""), "text/html")
  const fragment = document.createDocumentFragment()
  const copy = (from, to) => {
    for (const node of from.childNodes) {
      if (node.nodeType === Node.TEXT_NODE) {
        to.append(node.textContent)
      } else if (node.nodeType === Node.ELEMENT_NODE && ALLOWED_TAGS.has(node.tagName)) {
        if (node.tagName === "INPUT" && !["radio", "text"].includes(node.getAttribute("type"))) continue
        const el = document.createElement(node.tagName.toLowerCase())
        for (const attr of node.attributes) if (ALLOWED_ATTRS.has(attr.name)) el.setAttribute(attr.name, attr.value)
        copy(node, el)
        to.append(el)
      }
    }
  }
  copy(doc.body, fragment)
  return fragment
}

function startShell(root) {
  const t = texts(root)
  const fmt = formats(root)
  const lessonId = new URLSearchParams(window.location.search).get("lesson")
  const notes = []
  let result = null
  let lessonNote = ""

  const unavailable = document.getElementById("offline-page-unavailable")
  if (window.location.pathname !== "/offline") {
    unavailable.querySelector("#offline-page-unavailable-text").textContent = fill(t.page_unavailable, { path: window.location.pathname })
    unavailable.hidden = false
  }

  const alertBox = document.getElementById("offline-alert")
  const showAlert = (message) => {
    if (!message) return
    alertBox.querySelector("#offline-alert-text").textContent = message
    alertBox.hidden = false
  }

  async function data() {
    if (!store.supported() || !(await store.exists())) return { member: null, packages: [], pending: [], reports: [] }
    const member = await deviceMember()
    const live = await livePackages(member)
    for (const pkg of live.expired) notes.push(fill(t.expired_removed, { title: pkg.title }))
    return { member, packages: live.packages, pending: await pendingActions(member), reports: await lastReports(member) }
  }

  async function render() {
    const network = document.getElementById("offline-network")
    network.textContent = isOnline() ? t.online_now : t.offline_now
    network.dataset.state = isOnline() ? "online" : "offline"
    const backNote = document.getElementById("offline-back-note")
    backNote.textContent = t.online_only
    backNote.hidden = isOnline()

    if (!store.supported()) {
      showAlert(t.unsupported)
      return
    }
    const { packages, pending, reports } = await data()
    if (notes.length) showAlert(notes.splice(0).join(" "))
    syncBlock(root, t, pending, result)
    resultsBlock(root, t, fmt, reports)

    const listSection = document.getElementById("offline-list-section")
    const article = document.getElementById("offline-lesson")
    if (lessonId) {
      listSection.hidden = true
      article.hidden = false
      renderLesson(article, packages.find((p) => p.lesson_id === lessonId), pending, reports)
    } else {
      article.hidden = true
      listSection.hidden = false
      document.getElementById("offline-empty").textContent = t.empty
      document.getElementById("offline-empty").hidden = packages.length > 0
      document.getElementById("offline-list").replaceChildren(...packages.map((pkg) => packageItem(t, fmt, pkg, pending, { link: true })))
    }
  }

  function renderLesson(article, pkg, pending, reports) {
    const back = element("a", { href: "/offline", class: "link text-sm", id: "offline-back-list", text: `← ${t.back_list}` })
    if (!pkg) {
      article.replaceChildren(back, element("p", { class: "notice notice-warning", role: "status", id: "offline-lesson-missing", text: t.not_found }))
      return
    }
    const waiting = pending.find((action) => action.lesson_id === pkg.lesson_id)
    const last = reports.find((r) => r.lesson_id === pkg.lesson_id && r.status !== "retry")
    const status = element("p", { id: "offline-lesson-status", class: "text-sm", role: "status", "aria-live": "polite", tabindex: "-1" })
    const content = element("div", { id: "offline-lesson-content", class: "space-y-6" })
    content.append(sanitized(pkg.html))

    let action
    if (pkg.kind === "exercise") {
      const form = element("form", { id: "offline-quiz-form", class: "card space-y-4", "data-offline-ok": true })
      const fieldset = content.querySelector("fieldset")
      if (fieldset) form.append(fieldset)
      const save = element("button", { type: "submit", class: "btn btn-primary", id: "offline-save-answer" }, element("span", { text: t.answer_save }))
      form.append(save)
      form.addEventListener("submit", async (event) => {
        event.preventDefault()
        const chosen = form.querySelector('input[name="answer"]:checked') || form.querySelector('input[name="answer"][type="text"]')
        const value = chosen ? chosen.value.trim() : ""
        if (!value) {
          status.textContent = t.choose_first
          return
        }
        const label = chosen.type === "radio" ? chosen.closest("label")?.textContent.trim() || value : value
        save.disabled = true
        await queueAction(pkg, "submit", value, label)
        lessonNote = t.answer_saved
        await afterQueue()
      })
      action = form
      if (waiting) {
        for (const input of form.querySelectorAll("input, button")) input.disabled = true
        status.textContent = [lessonNote, fill(t.answer_pending, { answer: waiting.answer_label || "" })].filter(Boolean).join(" ")
      }
    } else {
      const done = element("button", { type: "button", class: "btn btn-primary", id: "offline-mark-read" }, icon("hero-check"), element("span", { text: t.story_done }))
      done.addEventListener("click", async () => {
        done.disabled = true
        await queueAction(pkg, "complete", null, null)
        lessonNote = t.story_saved
        await afterQueue()
      })
      action = element("div", { "data-offline-ok": true }, done)
      if (waiting) {
        done.disabled = true
        status.textContent = lessonNote || t.story_pending
      }
    }

    const lastResult = last
      ? element(
          "div",
          { id: "offline-lesson-result", class: `notice ${last.status === "done" ? (last.correct === false ? "notice-danger" : "notice-success") : "notice-warning"}` },
          element(
            "div",
            { class: "min-w-0 flex-1 space-y-1" },
            element("p", { class: "font-semibold text-ink", text: last.title }),
            last.message ? element("p", { text: last.message }) : null,
            last.xp_text ? element("p", { class: "font-medium", text: last.xp_text }) : null,
            element("p", { class: "text-xs text-muted", text: fill(t.result_at, { date: fmt.date(last.at) }) }),
          ),
        )
      : null

    const online = element("a", { href: `/learn/${encodeURIComponent(pkg.adventure?.slug || "")}/${encodeURIComponent(pkg.lesson_id)}`, class: "btn btn-ghost", id: "offline-open-online" }, icon("hero-globe-alt"), element("span", { text: t.open_online }))
    const onlineNote = isOnline() ? null : element("span", { class: "text-sm text-muted", text: t.online_only })

    article.replaceChildren(
      ...[
      back,
      element(
        "header",
        { class: "space-y-3" },
        element(
          "p",
          { class: "flex flex-wrap gap-2" },
          element("span", { class: "tag", text: pkg.kind === "exercise" ? t.kind_exercise : t.kind_story }),
          waiting ? element("span", { class: "tag tag-info", id: "offline-lesson-pending", text: t.pending_tag }) : null,
        ),
        element("h1", { id: "offline-lesson-title", class: "text-4xl md:text-5xl", text: pkg.title }),
        element("p", { class: "text-sm text-muted", text: `${pkg.adventure?.title || ""} · ${fill(t.copy_note, { date: fmt.date(pkg.expires_at) })}` }),
      ),
      content,
      action,
      status,
      lastResult,
      element("p", { class: "flex flex-wrap items-center gap-3" }, online, onlineNote),
      ].filter(Boolean),
    )
  }

  // Queued: online, the server checks it at once (its verdict replaces the « waiting » note); offline, it waits.
  async function afterQueue() {
    if (isOnline()) {
      result = await synchronize()
      if (result.status === "done") lessonNote = ""
    }
    await render()
    document.getElementById("offline-lesson-status")?.focus?.()
  }

  root.querySelector("#offline-sync-now").addEventListener("click", async () => {
    const button = root.querySelector("#offline-sync-now")
    button.disabled = true
    button.querySelector("[data-label]").textContent = t.syncing
    result = await synchronize()
    button.querySelector("[data-label]").textContent = t.sync_now
    await render()
  })

  window.addEventListener("online", async () => {
    await render()
    result = await synchronize()
    await render()
  })
  window.addEventListener("offline", () => render())

  ;(async () => {
    await render()
    if (isOnline() && store.supported() && (await store.exists())) {
      result = await synchronize()
      if (result.wiped) showAlert(t.wiped_other)
      await render()
    }
  })()
}

// ---------------------------------------------------------------- start

export function startOffline() {
  window.addEventListener("phx:ml:offline-purge", (event) => purge(event.detail?.message))
  if (!store.supported()) return
  interceptLogout()
  const member = pageMember()
  if (member) {
    ;(async () => {
      // nothing is stored for a member who never made a lesson available offline here: no database, no worker
      if (!(await store.exists())) return publish()
      registerWorker().catch(() => null)
      await claimDevice(member)
      await refreshState(member)
      await autoSync()
    })().catch(() => null)
    window.addEventListener("online", () => autoSync())
  }
  const shell = document.getElementById("offline-app")
  if (shell) startShell(shell)

  document.addEventListener("click", (event) => {
    if (event.target.closest?.("#offline-notice-close")) document.getElementById("offline-notice").hidden = true
  })
}
