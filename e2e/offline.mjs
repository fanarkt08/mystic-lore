// Parcours des leçons hors ligne dans Chrome : téléchargement, réponses hors ligne, synchronisation et effacement.
// Usage : cd e2e && node offline.mjs   (BASE, ACCOUNTS, CHROME, HEADED=1) ; bin/reset avant.
import { chromium } from "playwright-core"

const BASE = process.env.BASE || "http://localhost:4000"
const ACCOUNTS = process.env.ACCOUNTS || "http://localhost:4001"
const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
const DEMO_PASSWORD = process.env.DEMO_PASSWORD || "mystic-demo-pass-1"
const T = 20_000
const DAY = 86_400_000
const results = []
const pages = []
const browser = await chromium.launch({ executablePath: CHROME, headless: !process.env.HEADED })

async function step(name, fn) {
  const t0 = Date.now()
  try {
    await fn()
    results.push(true)
    console.log(`  ✓ ${name} (${Date.now() - t0} ms)`)
  } catch (e) {
    results.push(false)
    console.log(`  ✗ ${name}\n      ${String(e.message || e).split("\n").slice(0, 4).join("\n      ")}`)
  }
}

// erreurs JS et réponses 5xx de chaque page (les 4xx sont des refus voulus ; une ressource que le navigateur
// hors ligne ne peut pas charger n'est pas une erreur de l'application)
async function newPage(width = 1280) {
  const ctx = await browser.newContext({ viewport: { width, height: 900 }, locale: "en-US", timezoneId: "Europe/Paris" })
  const page = await ctx.newPage()
  page.on("dialog", (d) => d.accept())
  page.errors = []
  page.on("pageerror", (e) => page.errors.push(String(e)))
  page.on("console", (m) => m.type() === "error" && !/Failed to load resource/.test(m.text()) && page.errors.push(m.text()))
  page.on("response", (r) => r.status() >= 500 && page.errors.push(`HTTP ${r.status()} ${r.url()}`))
  pages.push(page)
  return page
}

const connected = (page) => page.waitForSelector("[data-phx-main].phx-connected", { timeout: T })
const visit = async (page, path) => {
  await page.goto(BASE + path)
  await connected(page)
}
const waitText = (page, selector, re, timeout = T) =>
  page.waitForFunction(([s, src]) => { const e = document.querySelector(s); return e && new RegExp(src, "i").test(e.innerText) }, [selector, re.source], { timeout })

async function login(page, email, password = DEMO_PASSWORD, expected = /\/(dashboard|welcome)/) {
  await page.goto(`${BASE}/login`)
  await page.fill('#login-form input[name="user[email]"]', email)
  await page.fill('#login-form input[name="user[password]"]', password)
  await Promise.all([page.waitForURL(expected, { timeout: T }), page.click('#login-form button[type="submit"]')])
}

// lecture du stockage du navigateur, sans créer la base si elle n'existe pas
const idb = (page, store) =>
  page.evaluate(async (store) => {
    if (!(await indexedDB.databases()).some((d) => d.name === "mysticlore-offline")) return null
    return new Promise((resolve, reject) => {
      const open = indexedDB.open("mysticlore-offline")
      open.onsuccess = () => {
        const db = open.result
        if (!db.objectStoreNames.contains(store)) return db.close(), resolve(null)
        const all = db.transaction(store).objectStore(store).getAll()
        all.onsuccess = () => (db.close(), resolve(all.result))
        all.onerror = () => (db.close(), reject(all.error))
      }
      open.onerror = () => reject(open.error)
    })
  }, store)
const putQueue = (page, actions) =>
  page.evaluate(async (actions) => new Promise((resolve, reject) => {
    const open = indexedDB.open("mysticlore-offline")
    open.onsuccess = () => {
      const db = open.result
      const tx = db.transaction("queue", "readwrite")
      for (const action of actions) tx.objectStore("queue").put(action)
      tx.oncomplete = () => (db.close(), resolve())
      tx.onerror = () => (db.close(), reject(tx.error))
    }
  }), actions)
const cachedPaths = (page) =>
  page.evaluate(async () => {
    const paths = []
    for (const name of await caches.keys()) for (const r of await (await caches.open(name)).keys()) paths.push(`${name} ${new URL(r.url).pathname}${new URL(r.url).search}`)
    return paths
  })
const xpTotal = async (page) => {
  await visit(page, "/dashboard")
  await waitText(page, "#level", /XP in total/)
  return Number((await page.innerText("#level")).match(/(\d+) XP in total/)[1])
}
const pngSize = (buffer) => [buffer.readUInt32BE(16), buffer.readUInt32BE(20)]

const stamp = Date.now().toString(36)
const member = { email: `offline_${stamp}@mysticlore.test`, username: `off_${stamp}`, name: `Offline ${stamp}`, password: "correct-horse-battery-staple" }
console.log(`Leçons hors ligne, ${BASE}, membre de test : ${member.email}`)

// ────────────────────────────────────────────────────────────────────────── 1. un membre Premium neuf
console.log("1. Membre neuf abonné à Premium (paiement simulé)")
const p = await newPage()
await step("inscription, confirmation par la boîte de dev, connexion, accueil passé", async () => {
  await p.goto(`${BASE}/register`)
  await p.fill('#register-form input[name="user[email]"]', member.email)
  await p.fill('#register-form input[name="user[username]"]', member.username)
  await p.fill('#register-form input[name="user[display_name]"]', member.name)
  await p.fill('#register-form input[name="user[password]"]', member.password)
  await Promise.all([p.waitForLoadState("load"), p.click('#register-form button[type="submit"]')])
  let confirmUrl
  for (let i = 0; i < 40 && !confirmUrl; i++) {
    const { data } = await (await fetch(`${ACCOUNTS}/dev/mailbox/json`)).json()
    const mail = data.filter((m) => JSON.stringify(m).includes(member.email)).pop()
    confirmUrl = mail && JSON.stringify(mail).match(/https?:\/\/[^"\\\s]+\/confirm\/[A-Za-z0-9_-]+/)?.[0]
    if (!confirmUrl) await new Promise((r) => setTimeout(r, 250))
  }
  if (!confirmUrl) throw new Error("no confirmation link")
  await p.goto(confirmUrl)
  await Promise.all([p.waitForLoadState("load"), p.click('#confirm-form button[type="submit"]')])
  await login(p, member.email, member.password, /\/welcome/)
  await connected(p)
  await Promise.all([p.waitForURL(/\/dashboard/, { timeout: T }), p.click("#welcome-skip-tour")])
})
await step("abonnement Premium simulé : activé par l'événement signé du webhook", async () => {
  await visit(p, "/membership")
  await Promise.all([p.waitForURL(/\/membership\/local-checkout\//, { timeout: T }), p.click("#checkout-premium")])
  await connected(p)
  await Promise.all([p.waitForURL(/\/membership\/success/, { timeout: T }), p.click("#pay")])
  await connected(p)
  await waitText(p, "#status-title", /Welcome to Premium/)
})

// identifiants des leçons premium (récit et exercice) de La Machine de l'alchimiste
const lessons = {}
await step("leçons premium : un récit et un exercice proposent « Make available offline »", async () => {
  await visit(p, "/adventures/la-machine-de-l-alchimiste")
  for (const [title, href] of await p.$$eval('a[href^="/learn/"]', (as) => as.map((a) => [a.textContent.trim(), a.getAttribute("href")])))
    lessons[title] = href
  if (!lessons["Le fourneau froid"] || !lessons["Équilibrer les vannes"]) throw new Error(`lessons: ${Object.keys(lessons).join(", ")}`)
  for (const title of ["Le fourneau froid", "Équilibrer les vannes"]) {
    await visit(p, lessons[title])
    await p.waitForSelector("#offline-download:not([disabled])", { timeout: T })
    await waitText(p, "[id^='offline-copy-'].offline-card", /never after the end of your paid period/)
  }
  // a simulation is not offered (only stories and quizzes)
  await visit(p, lessons["Le cœur de la machine"])
  if (await p.locator(".offline-card").count()) throw new Error("a simulation offers an offline copy")
})
const lessonId = (title) => lessons[title].split("/").pop()

// ────────────────────────────────────────────────────────────────────────── 2. application installable
console.log("2. Application installable et service worker")
await step("manifeste : nom, couleurs, icônes 192/512/maskable réelles (PNG générés)", async () => {
  const link = await p.getAttribute('link[rel="manifest"]', "href")
  const response = await p.request.get(BASE + link)
  if (!/application\/manifest\+json/.test(response.headers()["content-type"])) throw new Error(response.headers()["content-type"])
  const manifest = await response.json()
  if (manifest.name !== "MysticLore" || manifest.display !== "standalone" || manifest.theme_color !== "#090E20") throw new Error(JSON.stringify(manifest))
  const expected = { "192x192 any": 192, "512x512 any": 512, "512x512 maskable": 512 }
  for (const icon of manifest.icons) {
    const size = expected[`${icon.sizes} ${icon.purpose}`]
    const png = await p.request.get(BASE + icon.src)
    const [w, h] = pngSize(await png.body())
    if (png.status() !== 200 || w !== size || h !== size) throw new Error(`${icon.src}: ${png.status()} ${w}×${h}`)
    delete expected[`${icon.sizes} ${icon.purpose}`]
  }
  if (Object.keys(expected).length) throw new Error(`missing icons: ${Object.keys(expected)}`)
})
await step("/sw.js : JavaScript servi à la racine, Cache-Control no-cache, version et liste de précache", async () => {
  const response = await p.request.get(`${BASE}/sw.js`)
  const headers = response.headers()
  if (!/javascript/.test(headers["content-type"]) || headers["cache-control"] !== "no-cache") throw new Error(JSON.stringify(headers))
  const source = await response.text()
  for (const needle of ["const VERSION", "const PRECACHE", '"/offline"', "/assets/js/app.js"]) if (!source.includes(needle)) throw new Error(`sw.js lacks ${needle}`)
})
// ce que l'appareil garde hors ligne : base, caches MysticLore, service workers
const deviceState = (page) =>
  page.evaluate(async () => ({
    databases: (await indexedDB.databases()).map((d) => d.name).filter((name) => name === "mysticlore-offline"),
    caches: (await caches.keys()).filter((name) => name.startsWith("mysticlore-")),
    workers: (await navigator.serviceWorker.getRegistrations()).length,
  }))
const nothingStored = (state) => !state.databases.length && !state.caches.length && !state.workers
await step("avant tout téléchargement : ni service worker, ni cache, ni base sur l'appareil du membre Premium", async () => {
  for (const path of ["/dashboard", lessons["Le fourneau froid"], "/settings/offline"]) {
    await visit(p, path)
    await p.waitForLoadState("networkidle")
  }
  const state = await deviceState(p)
  if (!nothingStored(state)) throw new Error(`stored before any download: ${JSON.stringify(state)}`)
})

// ────────────────────────────────────────────────────────────────────────── 3. téléchargement
console.log("3. Copies hors ligne")
let session
await step("récit et exercice téléchargés : copie IndexedDB du membre, sans solution ni script, expiration ≤ 14 jours", async () => {
  for (const title of ["Le fourneau froid", "Équilibrer les vannes"]) {
    await visit(p, lessons[title])
    await p.waitForSelector("#offline-download:not([disabled])", { timeout: T })
    await p.click("#offline-download")
    await p.waitForSelector("#offline-open:not([hidden])", { timeout: T })
    await waitText(p, "#offline-copy-status", /Available offline until/)
  }
  session = await p.evaluate(async () => (await fetch("/offline/session", { headers: { accept: "application/json" } })).json())
  const packages = await idb(p, "packages")
  if (packages?.length !== 2) throw new Error(`packages: ${packages?.length}`)
  for (const pkg of packages) {
    if (pkg.member_id !== session.member_id) throw new Error("copy of another member")
    if (/<script|\son\w+=|2 H2 \+ O2 donne 2 H2O|Comptez les atomes|solution/i.test(pkg.html)) throw new Error(`unsafe or revealing copy: ${pkg.title}`)
    const life = Date.parse(pkg.expires_at) - Date.parse(pkg.downloaded_at)
    if (!(life > 0 && life <= 14 * DAY)) throw new Error(`expiry ${pkg.expires_at}`)
    if (!(pkg.revision >= 1 && pkg.downloaded_at && pkg.size > 0)) throw new Error(JSON.stringify(pkg).slice(0, 200))
  }
  const quiz = packages.find((pkg) => pkg.kind === "exercise")
  if (!/Deux volumes d(?:'|&#39;|&#x27;)eau/.test(quiz.html)) throw new Error("the question's choices are missing")
})
await step("le premier téléchargement installe le service worker, qui contrôle ensuite les pages du membre", async () => {
  const script = await p.evaluate(async () => (await navigator.serviceWorker.ready).active.scriptURL)
  if (!script.endsWith("/sw.js")) throw new Error(script)
  await visit(p, "/dashboard")
  if (!(await p.evaluate(() => navigator.serviceWorker.controller?.scriptURL))) throw new Error("the page is not controlled by the worker")
})
await step("Cache Storage : seulement les fichiers statiques et la page hors ligne (aucune page du compte ni réponse d'API)", async () => {
  const paths = await cachedPaths(p)
  if (!paths.some((path) => / \/offline$/.test(path))) throw new Error("offline page not cached")
  const unexpected = paths.filter((path) => !/^mysticlore-static-\S+ (\/(assets|fonts|icons|images)\/|\/favicon\.ico|\/offline$)/.test(path))
  if (unexpected.length) throw new Error(`unexpected cache entries: ${unexpected.slice(0, 3).join(" | ")}`)
})
await step("paramètres › Leçons hors ligne : taille, expiration, suppression, rien en attente", async () => {
  await visit(p, "/settings/offline")
  await waitText(p, "#offline-summary", /Lessons on this device: 2 · Space used on this device/)
  const list = await p.innerText("#offline-packages")
  for (const re of [/Le fourneau froid/, /Équilibrer les vannes/, /Available offline until/, /Size on this device/])
    if (!re.test(list)) throw new Error(`list: ${re}`)
  if ((await p.locator("#offline-packages button[id^='offline-remove-']").count()) !== 2) throw new Error("no remove buttons")
  await waitText(p, "#offline-sync-status", /Nothing is waiting for synchronization/)
  if (!(await p.isDisabled("#offline-sync-now"))) throw new Error("« Synchronize now » enabled with nothing to send")
})

// ────────────────────────────────────────────────────────────────────────── 4. hors ligne
console.log("4. Hors ligne (context.setOffline)")
await step("la coquille /offline s'ouvre sans réseau : 2 leçons, synchronisation désactivée avec sa raison", async () => {
  await p.context().setOffline(true)
  await p.goto(`${BASE}/offline`)
  await p.waitForSelector("#offline-list li", { timeout: T })
  if ((await p.locator("#offline-list li").count()) !== 2) throw new Error("expected 2 lessons")
  await waitText(p, "#offline-network", /You're offline/)
  if (!(await p.isDisabled("#offline-sync-now"))) throw new Error("sync enabled offline")
  await waitText(p, "#offline-sync-reason", /needs a connection/)
})
await step("une page du compte hors ligne mène à la coquille, qui le dit", async () => {
  await p.goto(`${BASE}/dashboard`)
  await waitText(p, "#offline-page-unavailable", /« \/dashboard » can't be shown offline/)
  await p.waitForSelector("#offline-list li", { timeout: T })
})
await step("exercice hors ligne : réponse mise en file « en attente », jamais notée sur l'appareil", async () => {
  await p.goto(`${BASE}/offline?lesson=${lessonId("Équilibrer les vannes")}`)
  await p.waitForSelector("#offline-quiz-form", { timeout: T })
  await waitText(p, "#offline-lesson", /Deux volumes d'hydrogène rencontrent un volume d'oxygène/)
  await p.click("#offline-save-answer")
  await waitText(p, "#offline-lesson-status", /Choose an answer first/)
  await p.locator("#offline-quiz-form label", { hasText: "Deux volumes d'eau" }).click()
  await p.click("#offline-save-answer")
  await p.waitForSelector("#offline-lesson-pending", { timeout: T })
  await waitText(p, "#offline-lesson-status", /NOT checked yet/)
  if (/Well done|Not quite|\bcorrect\b|\bwrong\b|\+25 XP/i.test(await p.innerText("main"))) throw new Error("the answer was graded on the device")
  if (!(await p.isDisabled("#offline-save-answer"))) throw new Error("a second answer is possible while one is waiting")
})
await step("récit hors ligne : « lu » mis en file, la coquille reste utilisable", async () => {
  await p.goto(`${BASE}/offline?lesson=${lessonId("Le fourneau froid")}`)
  await p.click("#offline-mark-read")
  await p.waitForSelector("#offline-lesson-pending", { timeout: T })
  await waitText(p, "#offline-lesson-status", /waiting for synchronization/)
  const queue = await idb(p, "queue")
  if (queue?.length !== 2) throw new Error(`queue: ${queue?.length}`)
  for (const action of queue)
    if (!/^[0-9a-f-]{36}$/.test(action.key) || action.revision < 1 || action.member_id !== session.member_id) throw new Error(JSON.stringify(action))
  await p.goto(`${BASE}/offline`)
  await waitText(p, "#offline-sync-status", /Waiting for synchronization: 2/)
})

// ────────────────────────────────────────────────────────────────────────── 5. synchronisation
console.log("5. Retour du réseau : synchronisation")
let queued
let xpAfter
await step("retour en ligne : synchronisation automatique, vrai résultat et XP accordée une fois", async () => {
  queued = await idb(p, "queue")
  await p.context().setOffline(false)
  await waitText(p, "#offline-sync-status", /Synchronization finished/)
  const report = await p.innerText("#offline-results")
  for (const re of [/Le fourneau froid — Marked as read/, /\+15 XP/, /Équilibrer les vannes — Well done!/, /\+25 XP/])
    if (!re.test(report)) throw new Error(`report: ${re} in ${report}`)
  if ((await idb(p, "queue")).length !== 0) throw new Error("queue not emptied")
  xpAfter = await xpTotal(p)
  // 15 + 25, plus the daily quests these first completions settle (lesson of the day, 30 XP of the day)
  if (xpAfter < 40) throw new Error(`XP ${xpAfter}`)
})
await step("resynchronisation des mêmes actions (mêmes clés), par le bouton puis au chargement : rien n'est compté deux fois", async () => {
  // « Synchronize now » : the same actions queued again while the page is open (the section is told the device
  // changed, as offline.js itself does after queuing)
  await visit(p, "/settings/offline")
  await waitText(p, "#offline-sync-status", /Nothing is waiting for synchronization/)
  await putQueue(p, queued)
  await p.evaluate(() => window.dispatchEvent(new CustomEvent("ml:offline-state", { detail: {} })))
  await waitText(p, "#offline-sync-status", /Waiting for synchronization: 2/)
  await p.click("#offline-sync-now")
  await waitText(p, "#offline-sync-status", /Synchronization finished/)
  let report = await p.innerText("#offline-results")
  if ((report.match(/Already synchronized earlier: nothing was counted twice/g) || []).length < 2) throw new Error(report)
  // automatic: queued again, then a page load synchronizes by itself
  await putQueue(p, queued)
  await visit(p, "/settings/offline")
  await p.waitForFunction(async () => {
    const open = indexedDB.open("mysticlore-offline")
    const db = await new Promise((r) => (open.onsuccess = () => r(open.result)))
    const queue = await new Promise((r) => { const g = db.transaction("queue").objectStore("queue").getAll(); g.onsuccess = () => r(g.result) })
    db.close()
    return queue.length === 0
  }, null, { timeout: T })
  report = await p.innerText("#offline-results")
  if (!/Already synchronized earlier/.test(report)) throw new Error(report)
  // the raw route answers the same way
  const raw = await p.evaluate(async (actions) => {
    const s = await (await fetch("/offline/session", { headers: { accept: "application/json" } })).json()
    const r = await fetch("/offline/sync", {
      method: "POST",
      headers: { "content-type": "application/json", accept: "application/json", "x-csrf-token": s.csrf_token },
      body: JSON.stringify({ actions: actions.map(({ key, lesson_id, kind, answer, revision }) => ({ key, lesson_id, kind, answer, revision })) }),
    })
    return r.json()
  }, queued)
  if (!raw.results.every((r) => r.status === "done" && r.replayed === true)) throw new Error(JSON.stringify(raw))
  if ((await xpTotal(p)) !== xpAfter) throw new Error("XP changed on a replay")
})
await step("sans jeton CSRF, la synchronisation est refusée", async () => {
  const status = await p.evaluate(async () => (await fetch("/offline/sync", { method: "POST", headers: { "content-type": "application/json" }, body: "{\"actions\":[]}" })).status)
  if (status !== 403) throw new Error(`status ${status}`)
})

// ────────────────────────────────────────────────────────────────────────── 6. membre Free
console.log("6. Membre Free")
await step("membre Free : aucun bouton (leçon gratuite ou premium) et la route refuse (402)", async () => {
  const hugo = await newPage()
  await login(hugo, "orion@mysticlore.test")
  await visit(hugo, "/adventures/la-foret-des-murmures")
  const free = await hugo.$eval('a[href^="/learn/"]', (a) => a.getAttribute("href"))
  await visit(hugo, free)
  if (await hugo.locator(".offline-card").count()) throw new Error("offline card on a free lesson")
  await visit(hugo, lessons["Le fourneau froid"])
  await hugo.waitForSelector("#lesson-premium", { timeout: T })
  if (await hugo.locator(".offline-card, #offline-download").count()) throw new Error("offline card for a Free member")
  const refused = await hugo.evaluate(async (id) => {
    const r = await fetch(`/offline/packages/${id}`, { headers: { accept: "application/json" } })
    return [r.status, (await r.json()).error]
  }, lessonId("Le fourneau froid"))
  if (refused[0] !== 402 || refused[1] !== "premium_required") throw new Error(`refused: ${refused}`)
  if (await idb(hugo, "packages")) throw new Error("a database was created for a Free member")
  await hugo.context().close()
})

// ────────────────────────────────────────────────────────────────────────── 7. expiration, autre membre
console.log("7. Expiration et changement de membre sur l'appareil")
await step("copie expirée (horloge du navigateur avancée de 15 jours) : plus affichée, supprimée", async () => {
  const q = await newPage()
  await login(q, member.email, member.password, /\/dashboard/)
  await visit(q, lessons["Le fourneau froid"])
  await q.waitForSelector("#offline-download:not([disabled])", { timeout: T })
  await q.click("#offline-download")
  await q.waitForSelector("#offline-open:not([hidden])", { timeout: T })
  await q.context().clock.setFixedTime(new Date(Date.now() + 15 * DAY))
  await q.goto(`${BASE}/offline`)
  await waitText(q, "#offline-alert", /“Le fourneau froid” expired and was removed from this device/)
  await waitText(q, "#offline-empty", /No lesson is available offline on this device/)
  if ((await q.locator("#offline-list li").count()) !== 0) throw new Error("an expired copy is listed")
  if ((await idb(q, "packages")).length !== 0) throw new Error("the expired copy is still stored")
  await q.goto(`${BASE}/offline?lesson=${lessonId("Le fourneau froid")}`)
  await waitText(q, "#offline-lesson", /isn't available offline on this device/)
  await q.context().close()
})
await step("un autre membre se connecte sur l'appareil : les données du précédent sont effacées", async () => {
  const d = await newPage()
  await login(d, member.email, member.password, /\/dashboard/)
  await visit(d, lessons["Équilibrer les vannes"])
  await d.waitForSelector("#offline-download:not([disabled])", { timeout: T })
  await d.click("#offline-download")
  await d.waitForSelector("#offline-open:not([hidden])", { timeout: T })
  // the session ends without a logout (expired cookie), then lea logs in on the same browser
  await d.context().clearCookies()
  await login(d, "lyra@mysticlore.test")
  await connected(d)
  await d.waitForFunction(async () => {
    const open = indexedDB.open("mysticlore-offline")
    const db = await new Promise((r) => (open.onsuccess = () => r(open.result)))
    const read = (s) => new Promise((r) => { const g = db.transaction(s).objectStore(s).getAll(); g.onsuccess = () => r(g.result) })
    const [packages, meta] = [await read("packages"), await read("meta")]
    db.close()
    return packages.length === 0 && meta.length === 1
  }, null, { timeout: T })
  const lea = await d.evaluate(async () => (await (await fetch("/offline/session", { headers: { accept: "application/json" } })).json()).member_id)
  const meta = await idb(d, "meta")
  if (meta[0].id !== lea) throw new Error("the device still belongs to the previous member")
  await d.context().close()
})

await step("« Clear offline data » : base, caches et service worker supprimés, rien n'est recréé ensuite", async () => {
  const e = await newPage()
  await login(e, member.email, member.password, /\/dashboard/)
  await visit(e, lessons["Le fourneau froid"])
  await e.waitForSelector("#offline-download:not([disabled])", { timeout: T })
  await e.click("#offline-download")
  await e.waitForSelector("#offline-open:not([hidden])", { timeout: T })
  await visit(e, "/settings/offline")
  await waitText(e, "#offline-summary", /Lessons on this device: 1/)
  if (nothingStored(await deviceState(e))) throw new Error("nothing stored before clearing")
  await e.click("#offline-clear") // confirmation acceptée (newPage)
  await waitText(e, "#offline-summary", /Offline data deleted from this device/)
  let state = await deviceState(e)
  if (!nothingStored(state)) throw new Error(`left after clearing: ${JSON.stringify(state)}`)
  // navigation LiveView depuis la page restée ouverte (encore contrôlée par l'ancien worker), puis page rechargée
  await Promise.all([e.waitForURL(/\/dashboard/, { timeout: T }), e.click("a.rail-brand")])
  await connected(e)
  await e.waitForLoadState("networkidle")
  await visit(e, "/adventures/la-machine-de-l-alchimiste")
  await e.waitForLoadState("networkidle")
  state = await deviceState(e)
  if (!nothingStored(state)) throw new Error(`stored again after clearing: ${JSON.stringify(state)}`)
  // un nouveau téléchargement réinstalle tout : la copie s'ouvre de nouveau sans réseau
  await visit(e, lessons["Le fourneau froid"])
  await e.waitForSelector("#offline-download:not([disabled])", { timeout: T })
  await e.click("#offline-download")
  await e.waitForSelector("#offline-open:not([hidden])", { timeout: T })
  await e.context().setOffline(true)
  await e.goto(`${BASE}/offline`)
  await e.waitForSelector("#offline-list li", { timeout: T })
  await e.context().setOffline(false)
  await e.context().close()
})

// ────────────────────────────────────────────────────────────────────────── 8. déconnexion
console.log("8. Déconnexion")
await step("déconnexion : IndexedDB, Cache Storage et service worker effacés (vérifié dans le navigateur)", async () => {
  await visit(p, "/dashboard")
  if (!(await idb(p, "packages"))?.length) throw new Error("nothing to erase before the logout")
  if (!(await cachedPaths(p)).length) throw new Error("no cache before the logout")
  await Promise.all([p.waitForURL((u) => u.pathname === "/", { timeout: T }), p.click("#rail-logout")])
  await p.waitForLoadState("load")
  const left = await p.evaluate(async () => ({
    databases: (await indexedDB.databases()).map((d) => d.name),
    caches: await caches.keys(),
    workers: (await navigator.serviceWorker.getRegistrations()).length,
  }))
  if (left.databases.includes("mysticlore-offline") || left.caches.some((c) => c.startsWith("mysticlore-")) || left.workers)
    throw new Error(`left after logout: ${JSON.stringify(left)}`)
  // a visitor's page doesn't register anything again
  await p.goto(`${BASE}/adventures`)
  await p.waitForLoadState("networkidle")
  if ((await p.evaluate(async () => (await navigator.serviceWorker.getRegistrations()).length)) !== 0) throw new Error("worker registered for a visitor")
})

await step("déconnexion sans le script de la page : l'en-tête Clear-Site-Data du serveur efface aussi tout", async () => {
  const c = await newPage()
  await login(c, member.email, member.password, /\/dashboard/)
  await visit(c, lessons["Le fourneau froid"])
  await c.waitForSelector("#offline-download:not([disabled])", { timeout: T })
  await c.click("#offline-download")
  await c.waitForSelector("#offline-open:not([hidden])", { timeout: T })
  const headers = await c.evaluate(async () => {
    const link = document.querySelector('a[data-to="/logout"]')
    const form = document.createElement("form")
    form.method = "post"
    form.action = "/logout"
    for (const [name, value] of [["_method", "delete"], ["_csrf_token", link.dataset.csrf]]) {
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = name
      input.value = value
      form.append(input)
    }
    document.body.append(form)
    // a plain submission: offline.js doesn't see it, only the server's answer acts
    setTimeout(() => HTMLFormElement.prototype.submit.call(form), 0)
    return true
  })
  if (!headers) throw new Error("no logout form")
  await c.waitForURL((u) => u.pathname === "/", { timeout: T })
  await c.waitForLoadState("load")
  const left = await c.evaluate(async () => ({
    databases: (await indexedDB.databases()).map((d) => d.name),
    caches: await caches.keys(),
    workers: (await navigator.serviceWorker.getRegistrations()).length,
  }))
  if (left.databases.length || left.caches.length || left.workers) throw new Error(`left: ${JSON.stringify(left)}`)
  await c.context().close()
})

await step("aucune erreur JavaScript ni réponse 5xx pendant le parcours", async () => {
  const errors = pages.flatMap((page) => page.errors)
  if (errors.length) throw new Error(errors.slice(0, 3).join(" ; "))
})

await browser.close()
const ok = results.filter(Boolean).length
console.log(`\n${ok}/${results.length} étapes OK`)
process.exit(ok === results.length ? 0 : 1)
