// Parcours du centre de notifications avec trois navigateurs, sur la pile de bin/dev (après bin/reset).
// Usage : cd e2e && node notifications.mjs   (BASE, ACCOUNTS, CHROME, HEADED=1)
import { chromium } from "playwright-core"

const BASE = process.env.BASE || "http://localhost:4000"
const ACCOUNTS = process.env.ACCOUNTS || "http://localhost:4001"
const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
const PASSWORD = process.env.DEMO_PASSWORD || "mystic-demo-pass-1"
const T = 15_000
const results = []
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

async function member(email, width) {
  const ctx = await browser.newContext({ viewport: { width, height: 900 }, locale: "en-US", timezoneId: "Europe/Paris" })
  const page = await ctx.newPage()
  page.on("dialog", (d) => d.accept())
  page.errors = []
  page.on("pageerror", (e) => page.errors.push(String(e)))
  page.on("console", (m) => m.type() === "error" && !/Failed to load resource/.test(m.text()) && page.errors.push(m.text()))
  page.on("response", (r) => r.status() >= 500 && page.errors.push(`HTTP ${r.status()} ${r.url()}`))
  await page.goto(`${BASE}/login`)
  await page.fill('#login-form input[name="user[email]"]', email)
  await page.fill('#login-form input[name="user[password]"]', PASSWORD)
  await Promise.all([page.waitForURL(/\/dashboard/, { timeout: T }), page.click('#login-form button[type="submit"]')])
  return page
}

const connected = (page) => page.waitForSelector("[data-phx-main].phx-connected", { timeout: T })
const visit = async (page, path) => { await page.goto(BASE + path); await connected(page) }
const waitText = (page, selector, re, timeout = T) =>
  page.waitForFunction(([s, src]) => { const e = document.querySelector(s); return e && new RegExp(src, "i").test(e.innerText) }, [selector, re.source], { timeout })
const pause = (ms) => new Promise((r) => setTimeout(r, ms))

// le nombre de non-lues dit par la cloche (aria-label « Notifications, 3 unread » / « none unread »)
async function bell(page) {
  const label = await page.getAttribute("#nav-notifications, #mobile-bell", "aria-label")
  if (/none unread/.test(label)) return 0
  const m = label.match(/(\d+) unread/)
  if (!m) throw new Error(`bell label: ${label}`)
  return Number(m[1])
}
const waitBell = (page, n) =>
  page.waitForFunction((n) => {
    const l = (document.querySelector("#nav-notifications, #mobile-bell") || {}).getAttribute?.("aria-label") || ""
    return n === 0 ? /none unread/.test(l) : new RegExp(`\\b${n} unread`).test(l)
  }, n, { timeout: T })

async function say(page, text) {
  await page.fill("#composer textarea", text)
  await page.click("#send-message")
  await page.waitForSelector(`#messages li:has-text("${text}")`, { timeout: T })
}

async function mails() {
  const { data } = await (await fetch(`${ACCOUNTS}/dev/mailbox/json`)).json()
  return data
}
async function waitMail(predicate, timeout = 45_000) {
  const until = Date.now() + timeout
  while (Date.now() < until) {
    const found = (await mails()).find(predicate)
    if (found) return found
    await pause(1000)
  }
  throw new Error("expected e-mail not received")
}
const to = (mail, email) => JSON.stringify(mail.to).includes(email)

// défilement horizontal et contrôles < 44 px (même mesure que responsive.mjs)
const layout = (page) => page.evaluate(() => {
  const de = document.documentElement
  const visible = (e) => { const r = e.getBoundingClientRect(); const s = getComputedStyle(e); return r.width > 0 && r.height > 0 && s.visibility !== "hidden" && !e.closest("[hidden]") }
  const small = [...document.querySelectorAll("button, a.btn, input:not([type=hidden]):not([type=checkbox]):not([type=radio]), select, textarea")]
    .filter((e) => visible(e) && e.getBoundingClientRect().height < 44).slice(0, 3).map((e) => `${e.tagName}#${e.id} h=${Math.round(e.getBoundingClientRect().height)}`)
  return { overflow: de.scrollWidth - de.clientWidth, small }
})

// réglages des seeds pour Léa : e-mail des messages coupé, heures calmes coupées (aussi après un parcours interrompu)
async function defaults(page) {
  await visit(page, "/settings/notifications")
  if (await page.isChecked("#channel-messages-email")) {
    await page.uncheck("#channel-messages-email")
    await page.click("#save-notification-channels")
    await waitText(page, "#notification-channels-status", /Notification choices saved/)
  }
  if (await page.isChecked("#quiet-enabled")) {
    await page.uncheck("#quiet-enabled")
    await page.click("#save-quiet-hours")
    await waitText(page, "#quiet-hours-status", /Quiet hours saved/)
  }
}

const stamp = Date.now().toString(36)
console.log(`Centre de notifications — ${BASE}`)
const lea = await member("lyra@mysticlore.test", 1280)
const hugo = await member("orion@mysticlore.test", 1024)
const ines = await member("mika@mysticlore.test", 390)
let direct, group, start
await defaults(lea)

console.log("1. Cloche et page /notifications")
await step("cloche de Léa : compteur réel (aria-label avec le nombre) = non-lues listées, du plus récent au plus ancien", async () => {
  await visit(lea, "/dashboard")
  start = await bell(lea)
  if (start < 1) throw new Error(`expected unread notifications (seeds), got ${start}`)
  await visit(lea, "/notifications")
  await lea.waitForSelector("#notification-list li", { timeout: T })
  // the scripts run before (social.mjs) can leave many newer read notifications: the unread ones are then reached
  // with « Load more », like a member would
  for (let more = 0; more < 5 && !(await lea.locator("#notification-list li.is-unread").count()); more++) {
    if (!(await lea.locator("#load-more").count())) break
    const before = await lea.locator("#notification-list li").count()
    await lea.click("#load-more")
    await lea.waitForFunction((n) => document.querySelectorAll("#notification-list li").length > n, before, { timeout: T })
  }
  if (!(await lea.locator("#notification-list li.is-unread").count())) throw new Error("no unread item marked")
  await lea.click("#filter-unread")
  await lea.waitForURL(/filter=unread/, { timeout: T })
  await lea.waitForSelector("#filter-unread[aria-current='page']", { timeout: T })
  const listed = await lea.locator("#notification-list li").count()
  if (listed !== Math.min(start, 20)) throw new Error(`${listed} unread listed, the bell says ${start}`)
  if (await lea.locator("#notification-list li:not(.is-unread)").count()) throw new Error("read item in the unread filter")
  const times = await lea.$$eval("#notification-list time", (ts) => ts.map((t) => Date.parse(t.getAttribute("datetime"))))
  for (let i = 1; i < times.length; i++) if (times[i] > times[i - 1]) throw new Error("not newest first")
})

console.log("2. Messages : temps réel, lecture, sourdine")
await step("Hugo écrit à Léa : la cloche de Léa s'incrémente en direct, toast poli sans le texte", async () => {
  await visit(hugo, "/messages")
  await hugo.click('#conversations a:has-text("Léa Moreau")')
  await hugo.waitForURL(/\/messages\/[0-9a-f-]{36}$/, { timeout: T })
  direct = new URL(hugo.url()).pathname
  await connected(hugo)
  await visit(lea, "/dashboard")
  const before = await bell(lea)
  await say(hugo, `Secret plan ${stamp}: meet at the grove`)
  await waitBell(lea, before + 1)
  await waitText(lea, "#notification-toasts[aria-live='polite'] #notification-toast", /Hugo Bernard sent you a message/)
  if ((await lea.innerText("#notification-toast")).includes("Secret plan")) throw new Error("message text in the toast")
})
await step("lire la conversation efface la notification (la cloche redescend)", async () => {
  const before = await bell(lea)
  await visit(lea, direct)
  await waitText(lea, "#messages", new RegExp(`Secret plan ${stamp}`))
  await waitBell(lea, before - 1)
  await visit(lea, "/notifications")
  const item = lea.locator("#notification-list li", { hasText: "Hugo Bernard sent you" }).first()
  if (await item.evaluate((li) => li.classList.contains("is-unread"))) throw new Error("still unread")
})
await step("conversation en sourdine : aucun nouvel envoi ne notifie", async () => {
  await visit(lea, direct)
  await lea.click("#toggle-details")
  await lea.selectOption("#mute-duration", "always")
  await lea.click("#mute-submit")
  await waitText(lea, "#mute-status", /Muted until you turn it back on/)
  await visit(lea, "/dashboard")
  const before = await bell(lea)
  await say(hugo, `While muted ${stamp}`)
  await pause(2500)
  if ((await bell(lea)) !== before) throw new Error("a muted conversation notified")
  if (await lea.locator("#notification-toast").count()) throw new Error("toast for a muted conversation")
  // remise en état
  await visit(lea, direct)
  await lea.click("#toggle-details")
  await lea.click("#unmute")
  await waitText(lea, "#mute-status", /Notifications on/)
})

console.log("3. Amis et salons : notification dont le lien mène à la bonne page")
await step("demande d'ami de Inès à Hugo → notification d'Hugo, son lien mène à /friends", async () => {
  await visit(ines, "/friends")
  await ines.fill("#search-q", "hugo")
  await ines.locator('#search-results li:has-text("Hugo Bernard")').getByRole("button", { name: /add friend/i }).click()
  await waitText(ines, "body", /Friend request sent/)
  await visit(hugo, "/notifications")
  await waitText(hugo, "#notification-list", /Inès Petit sent you a friend request/)
  await hugo.locator("#notification-list a", { hasText: "Inès Petit sent you a friend request" }).first().click()
  await hugo.waitForURL(/\/friends$/, { timeout: T })
  await connected(hugo)
  // remise en état : Hugo refuse la demande
  await hugo.locator('li[id^="incoming-"]:has-text("Inès Petit")').getByRole("button", { name: /decline/i }).click()
  await hugo.waitForSelector('li[id^="incoming-"]:has-text("Inès Petit")', { state: "detached", timeout: T })
})
await step("invitation de salon de Léa → toast chez Hugo, son lien mène à /multiplayer", async () => {
  await visit(hugo, "/dashboard")
  await visit(lea, "/multiplayer")
  await lea.fill("#create-lobby input[name='lobby[title]']", `Owl relay ${stamp}`)
  await Promise.all([lea.waitForURL(/\/multiplayer\/lobbies\//, { timeout: T }), lea.click("#create-submit")])
  await connected(lea)
  await lea.click('#invite-friends li:has-text("Hugo Bernard") button')
  await waitText(hugo, "#notification-toast", new RegExp(`invited you to the activity “Owl relay ${stamp}”`))
  await hugo.click("#notification-toast-link")
  await hugo.waitForURL(/\/multiplayer$/, { timeout: T })
  await connected(hugo)
  await waitText(hugo, "body", new RegExp(`Owl relay ${stamp}`))
  // remise en état : Léa quitte son salon (il est fermé)
  await Promise.all([lea.waitForURL(/\/multiplayer$/, { timeout: T }), lea.click("#leave-lobby")])
})

console.log("4. E-mail et heures calmes")
await step("la ligne sécurité est verrouillée (« Always »), les autres se règlent", async () => {
  await visit(lea, "/settings/notifications")
  await waitText(lea, "#channel-security-email-locked", /Always/)
  await waitText(lea, "#channel-security-in_app-locked", /Always/)
  if (await lea.locator("#channel-security-email").count()) throw new Error("security e-mail has a checkbox")
  await waitText(lea, "#channels-security-hint", /Always on/)
})
await step("e-mail activé pour les messages : la boîte de dev reçoit un e-mail SANS le corps du message", async () => {
  await lea.check("#channel-messages-email")
  await lea.click("#save-notification-channels")
  await waitText(lea, "#notification-channels-status", /Notification choices saved/)
  // un groupe neuf : la limite d'un e-mail par conversation et par heure ne gêne pas une relance du parcours
  await visit(lea, "/messages/new")
  await lea.fill("#new-group-form input[name='group[name]']", `Owl post ${stamp}`)
  for (const friend of ["Hugo Bernard", "Inès Petit"]) await lea.check(`#new-group-form label:has-text("${friend}") input`)
  await Promise.all([lea.waitForURL(/\/messages\/[0-9a-f-]{36}$/, { timeout: T }), lea.click("#create-group")])
  group = new URL(lea.url()).pathname
  await visit(lea, "/dashboard")
  await visit(hugo, group)
  const sent = Date.now()
  await say(hugo, `Hidden words ${stamp}`)
  const mail = await waitMail((m) => to(m, "lyra@mysticlore.test") && m.subject === `Hugo Bernard wrote in “Owl post ${stamp}”`)
  const body = mail.text_body || ""
  if (body.includes(`Hidden words ${stamp}`) || JSON.stringify(mail).includes("Hidden words")) throw new Error("message text in the e-mail")
  if (!body.includes(`${BASE}/messages/`) || !body.includes(`${BASE}/settings/notifications`)) throw new Error(`links missing: ${body}`)
  console.log(`      e-mail reçu ${Math.round((Date.now() - sent) / 1000)} s après l'envoi (délai de dev : 10 s)`)
})
await step("heures calmes (Europe/Paris) : pas de toast, la cloche monte en silence, e-mail reporté et visible", async () => {
  // Léa lit le groupe : le prochain message y crée une nouvelle notification (sinon il s'agrégerait)
  await visit(lea, group)
  await waitText(lea, "#messages", new RegExp(`Hidden words ${stamp}`))
  // une plage qui contient maintenant, dans le fuseau effectif de la page (celui du navigateur : Europe/Paris)
  const hhmm = (d) => d.toLocaleTimeString("en-GB", { timeZone: "Europe/Paris", hour: "2-digit", minute: "2-digit" })
  await visit(lea, "/settings/notifications")
  await waitText(lea, "#quiet-time-zone", /Europe\/Paris/)
  await lea.check("#quiet-enabled")
  await lea.fill("#quiet-start", hhmm(new Date(Date.now() - 3600_000)))
  await lea.fill("#quiet-end", hhmm(new Date(Date.now() + 3600_000)))
  await lea.click("#save-quiet-hours")
  await waitText(lea, "#quiet-hours-status", /Quiet hours saved/)
  await waitText(lea, "#quiet-active", /Quiet hours are on right now/)
  await visit(lea, "/dashboard")
  const before = await bell(lea)
  const ours = async () => (await mails()).filter((m) => to(m, "lyra@mysticlore.test") && JSON.stringify(m).includes(`Owl post ${stamp}`)).length
  const mailsBefore = await ours()
  await say(hugo, `Late news ${stamp}`)
  await waitBell(lea, before + 1)
  await pause(1500)
  if (await lea.locator("#notification-toast").count()) throw new Error("toast during quiet hours")
  // le report se voit dans les réglages (API du centre), sans attendre la fin des heures calmes
  await visit(lea, "/settings/notifications")
  await waitText(lea, "#quiet-pending", /1 e-mail is waiting: it will be sent in one summary at/)
  await pause(12_000) // plus que le délai d'un e-mail en dev : rien ne doit partir
  if ((await ours()) !== mailsBefore) throw new Error("e-mail sent during quiet hours")
})
await step("fin des heures calmes : UN résumé, sans le texte du message", async () => {
  await visit(lea, "/settings/notifications")
  await lea.uncheck("#quiet-enabled")
  await lea.click("#save-quiet-hours")
  await waitText(lea, "#quiet-hours-status", /Quiet hours saved/)
  const digest = await waitMail((m) => to(m, "lyra@mysticlore.test") && /^While your quiet hours were on: 1 notification$/.test(m.subject) &&
    (m.text_body || "").includes(`Owl post ${stamp}`))
  if (!/Hugo Bernard wrote in “Owl post/.test(digest.text_body)) throw new Error(digest.text_body)
  if (digest.text_body.includes("Late news")) throw new Error("message text in the digest")
  await visit(lea, "/settings/notifications")
  if (await lea.locator("#quiet-pending").count()) throw new Error("digest still pending")
})

console.log("5. Mise en page")
await step("/notifications et /settings/notifications à 390 px (Inès) : 0 défilement, 0 contrôle < 44 px, cloche ≥ 44 px", async () => {
  for (const path of ["/notifications", "/settings/notifications", "/dashboard"]) {
    await visit(ines, path)
    const info = await layout(ines)
    if (info.overflow > 0) throw new Error(`${path}: horizontal scroll ${info.overflow}px`)
    if (info.small.length) throw new Error(`${path}: small controls ${info.small.join(" | ")}`)
    const box = await ines.locator("#mobile-bell").boundingBox()
    if (!box || box.width < 44 || box.height < 44) throw new Error(`${path}: bell ${JSON.stringify(box)}`)
  }
})

// remise en état des seeds de Léa (permet de relancer le parcours), groupe quitté
await defaults(lea)
if (group) {
  for (const page of [hugo, ines, lea]) {
    await visit(page, group)
    await page.click("#toggle-details")
    await page.click("#leave-group")
  }
}
await step("aucune erreur JS ni réponse 5xx pendant le parcours", async () => {
  const errors = [...lea.errors, ...hugo.errors, ...ines.errors]
  if (errors.length) throw new Error(errors.slice(0, 3).join(" ; "))
})

await browser.close()
const ok = results.filter(Boolean).length
console.log(`\n${ok}/${results.length} étapes OK`)
process.exit(ok === results.length ? 0 : 1)
