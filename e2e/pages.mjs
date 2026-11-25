// Parcours des pages juridiques, de l'aide, du contact, de l'accueil guidé et des états expirés dans Chrome.
// Usage : cd e2e && node pages.mjs   (BASE, ACCOUNTS, CHROME, HEADED=1) ; bin/reset avant.
import { chromium } from "playwright-core"

const BASE = process.env.BASE || "http://localhost:4000"
const ACCOUNTS = process.env.ACCOUNTS || "http://localhost:4001"
const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
const PASSWORD = process.env.DEMO_PASSWORD || "mystic-demo-pass-1"
const T = 15_000
const LOCAL_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]"])
const results = []
const browser = await chromium.launch({ executablePath: CHROME, headless: !process.env.HEADED })
const pages = []

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

// Chaque page note ses erreurs JS, ses réponses 5xx et toute requête vers un autre hôte que localhost.
async function newPage({ width = 1280, javaScriptEnabled = true } = {}) {
  const ctx = await browser.newContext({ viewport: { width, height: 900 }, locale: "en-US", timezoneId: "Europe/Paris", javaScriptEnabled })
  const page = await ctx.newPage()
  page.on("dialog", (d) => d.accept())
  page.errors = []
  page.foreign = []
  page.fonts = []
  page.on("pageerror", (e) => page.errors.push(String(e)))
  page.on("console", (m) => m.type() === "error" && !/Failed to load resource/.test(m.text()) && page.errors.push(m.text()))
  page.on("response", (r) => r.status() >= 500 && page.errors.push(`HTTP ${r.status()} ${r.url()}`))
  page.on("request", (r) => {
    const url = new URL(r.url())
    if (!["http:", "https:", "ws:", "wss:"].includes(url.protocol)) return
    if (!LOCAL_HOSTS.has(url.hostname)) page.foreign.push(r.url())
    if (url.pathname.startsWith("/fonts/")) page.fonts.push(url.pathname)
  })
  pages.push(page)
  return page
}

const connected = (page) => page.waitForSelector("[data-phx-main].phx-connected", { timeout: T })
const visit = async (page, path) => { await page.goto(BASE + path); await connected(page) }
const waitText = (page, selector, re, timeout = T) =>
  page.waitForFunction(([s, src]) => { const e = document.querySelector(s); return e && new RegExp(src, "i").test(e.innerText) }, [selector, re.source], { timeout })
const pause = (ms) => new Promise((r) => setTimeout(r, ms))

async function login(page, email, password = PASSWORD, expected = /\/(dashboard|welcome)/) {
  await page.goto(`${BASE}/login`)
  await page.fill('#login-form input[name="user[email]"]', email)
  await page.fill('#login-form input[name="user[password]"]', password)
  await Promise.all([page.waitForURL(expected, { timeout: T }), page.click('#login-form button[type="submit"]')])
}

async function mails() {
  const { data } = await (await fetch(`${ACCOUNTS}/dev/mailbox/json`)).json()
  return data
}
async function waitMail(predicate, timeout = 30_000) {
  const until = Date.now() + timeout
  while (Date.now() < until) {
    const found = (await mails()).find(predicate)
    if (found) return found
    await pause(500)
  }
  throw new Error("expected e-mail not received")
}
const to = (mail, email) => JSON.stringify(mail.to).includes(email)

const layout = (page) => page.evaluate(() => {
  const de = document.documentElement
  const visible = (e) => { const r = e.getBoundingClientRect(); const s = getComputedStyle(e); return r.width > 0 && r.height > 0 && s.visibility !== "hidden" && !e.closest("[hidden]") }
  const small = [...document.querySelectorAll("button, a.btn, input:not([type=hidden]):not([type=checkbox]):not([type=radio]), select, textarea")]
    .filter((e) => visible(e) && e.getBoundingClientRect().height < 44).slice(0, 3).map((e) => `${e.tagName}#${e.id} h=${Math.round(e.getBoundingClientRect().height)}`)
  return { overflow: de.scrollWidth - de.clientWidth, small }
})

// envoi du formulaire de contact (visiteur : e-mail ; membre : l'adresse du compte)
async function sendContact(page, { topic = "bug", email, message }) {
  await visit(page, "/contact")
  await page.selectOption("#contact_topic", topic)
  if (email) await page.fill("#contact_email", email)
  await page.fill("#contact_message", message)
  await page.click("#contact-submit")
}

const stamp = Date.now().toString(36)
console.log(`Pages, ${BASE}`)
const visitor = await newPage()

console.log("1. Polices auto-hébergées, aucune requête tierce")
await step("visiteur : 7 pages principales, chaque requête reste sur localhost, polices servies par /fonts", async () => {
  for (const path of ["/", "/adventures", "/community", "/login", "/register", "/help", "/legal/privacy"]) {
    await visitor.goto(BASE + path, { waitUntil: "networkidle" })
  }
  if (visitor.foreign.length) throw new Error(`third-party requests: ${[...new Set(visitor.foreign)].slice(0, 3).join(" | ")}`)
  const loaded = await visitor.evaluate(async () => {
    await document.fonts.ready
    return ["600 32px 'Cormorant Garamond'", "400 16px Inter", "600 16px Inter"].map((f) => document.fonts.check(f))
  })
  if (loaded.includes(false)) throw new Error(`fonts not loaded: ${JSON.stringify(loaded)}`)
  if (!visitor.fonts.some((p) => /inter-latin-400-normal\.woff2$/.test(p))) throw new Error(`no font request: ${visitor.fonts.join(", ")}`)
  const font = await visitor.request.get(`${BASE}/fonts/cormorant-garamond-latin-600-normal.woff2`)
  const head = (await font.body()).subarray(0, 4).toString("latin1")
  if (font.status() !== 200 || head !== "wOF2") throw new Error(`font: ${font.status()} ${head}`)
  const csp = (await visitor.request.get(`${BASE}/login`)).headers()["content-security-policy"]
  if (/googleapis|gstatic|https:\/\//.test(csp)) throw new Error(`CSP still allows a third party: ${csp}`)
})
const lea = await newPage()
await login(lea, "lyra@mysticlore.test")
await step("membre : tableau de bord, messages, paramètres, contact — toujours aucune requête tierce", async () => {
  for (const path of ["/dashboard", "/messages", "/settings", "/contact", "/notifications"]) {
    await lea.goto(BASE + path, { waitUntil: "networkidle" })
    await connected(lea)
  }
  if (lea.foreign.length) throw new Error(`third-party requests: ${[...new Set(lea.foreign)].slice(0, 3).join(" | ")}`)
})

console.log("2. Pages juridiques provisoires")
await step("4 documents : bandeau provisoire, version, emplacements « à compléter », navigation", async () => {
  for (const doc of ["privacy", "terms", "cookies", "accessibility"]) {
    await visit(visitor, `/legal/${doc}`)
    await waitText(visitor, "#legal-banner", /Provisional text, to be validated by a lawyer before any production use/)
    // vie privée, cookies et accessibilité en 0.2, conditions en 0.1
    await waitText(visitor, "#legal-version", ["privacy", "cookies", "accessibility"].includes(doc) ? /Version 0\.2 · last updated/ : /Version 0\.1 · last updated/)
    if (!(await visitor.locator(".legal-placeholder").count())) throw new Error(`${doc}: no placeholder`)
    if (!(await visitor.locator(`#legal-nav-${doc}[aria-current="page"]`).count())) throw new Error(`${doc}: nav`)
  }
  await visit(visitor, "/legal")
  for (const id of ["entity", "address", "registration", "host", "dpo"])
    await waitText(visitor, `#operator-${id}`, /To be completed by the operator/)
})
await step("cookies : l'inventaire réel (session, langue, LiveView) et pas de bannière ; vie privée : liens des droits", async () => {
  await visit(visitor, "/legal/cookies")
  const cookies = await visitor.innerText("#cookie-table")
  for (const name of ["_mystic_web", "ml_locale", "__phoenix_flash__", "__phoenix_reload_status__"])
    if (!cookies.includes(name)) throw new Error(`cookie ${name} missing from the inventory`)
  const storage = await visitor.innerText("#storage-table")
  for (const name of ["phx:nav-history-position", "phx:fallback:LongPoll", "consecutive-reloads"])
    if (!storage.includes(name)) throw new Error(`storage entry ${name} missing from the inventory`)
  // la réalité du navigateur d'un membre connecté : chaque cookie et chaque entrée de stockage est dans l'inventaire
  for (const c of await lea.context().cookies())
    if (!cookies.includes(c.name)) throw new Error(`cookie ${c.name} set but not listed`)
  const keys = await lea.evaluate(() => [...Object.keys(localStorage), ...Object.keys(sessionStorage)])
  for (const key of keys)
    if (!storage.includes(key.replace(/^\/.*-consecutive-reloads$/, "consecutive-reloads"))) throw new Error(`storage ${key} not listed`)
  await waitText(visitor, "#no-banner", /no fake banner/)
  if (await visitor.locator("[class*=consent], #cookie-banner").count()) throw new Error("a consent banner exists")
  await visit(visitor, "/legal/privacy")
  for (const sel of ["#rights-export[href='/settings/data']", "#rights-delete[href='/settings/data']", "#rights-contact[href='/contact?topic=privacy']"])
    if (!(await visitor.locator(sel).count())) throw new Error(`missing ${sel}`)
  await waitText(visitor, "#processor-stripe-status", /simulated locally|Stripe keys are configured|disabled/)
})
await step("liens : pied de page public, inscription, rail du membre et paramètres de données", async () => {
  await visit(visitor, "/")
  for (const id of ["footer-privacy-link", "footer-terms-link", "footer-cookies-link", "footer-accessibility-link", "footer-help-link", "footer-contact-link"])
    if (!(await visitor.locator(`#${id}`).count())) throw new Error(`missing #${id}`)
  await visitor.goto(`${BASE}/register`)
  await waitText(visitor, "#register-legal", /terms of use.*privacy notice/)
  await visit(lea, "/settings/data")
  for (const sel of ["#data-privacy-link", "#data-cookies-link", "#data-contact-link", "#rail-legal", "#rail-help"])
    if (!(await lea.locator(sel).count())) throw new Error(`missing ${sel}`)
})

console.log("3. Aide")
await step("recherche SANS JavaScript : GET /help?q= filtré par le serveur", async () => {
  const nojs = await newPage({ javaScriptEnabled: false })
  await nojs.goto(`${BASE}/help`)
  await nojs.fill("#help-q", "password")
  await Promise.all([nojs.waitForURL(/\/help\?q=password/, { timeout: T }), nojs.click("#help-submit")])
  await waitText(nojs, "#help-results-status", /answers? for « password »/)
  if (!(await nojs.locator("#help-result-forgot-password").count())) throw new Error("expected answer missing")
  if (await nojs.locator("#help-result-xp").count()) throw new Error("unrelated answer shown")
  await nojs.context().close()
})
await step("recherche avec JavaScript : l'URL suit, accents ignorés, aucun résultat → contact", async () => {
  await visit(visitor, "/help")
  await visitor.fill("#help-q", "ÉXPORT")
  await visitor.click("#help-submit")
  await visitor.waitForURL(/q=%C3%89XPORT|q=ÉXPORT/, { timeout: T })
  await visitor.waitForSelector("#help-result-export", { timeout: T })
  await visitor.fill("#help-q", "zzqqxx")
  await visitor.click("#help-submit")
  await visitor.waitForSelector("#help-no-result a[href='/contact']", { timeout: T })
})

console.log("4. Contact")
const target = `visitor_${stamp}@example.test`
const secret = `Visitor secret ${stamp}`
let reference
await step("visiteur : demande envoyée, référence affichée, accusé reçu SANS le texte soumis", async () => {
  await sendContact(visitor, { email: target, message: `${secret}: my quiz answer is refused.` })
  await waitText(visitor, "#contact-sent", /Request received/)
  reference = (await visitor.innerText("#contact-sent")).match(/REQ-[0-9A-Z]{5}-[0-9A-Z]{5}/)[0]
  await waitText(visitor, "#contact-acknowledged", /doesn't repeat your message/)
  const ack = await waitMail((m) => to(m, target) && m.subject.includes(reference))
  if (JSON.stringify(ack).includes(secret)) throw new Error("the acknowledgement repeats the submitted text")
})
await step("champ piège rempli : refus explicite, rien n'est envoyé", async () => {
  await visit(visitor, "/contact")
  await visitor.selectOption("#contact_topic", "other")
  await visitor.fill("#contact_email", `bot_${stamp}@example.test`)
  await visitor.fill("#contact_message", "Buy cheap potions now, best prices!")
  await visitor.$eval("#contact-website", (el) => { el.value = "http://spam.example"; el.dispatchEvent(new Event("input", { bubbles: true })) })
  await visitor.click("#contact-submit")
  await waitText(visitor, "#contact-trap", /Leave this field empty/)
  await pause(1000)
  if ((await mails()).some((m) => to(m, `bot_${stamp}@example.test`))) throw new Error("an e-mail was sent for the trap")
})
await step("limite par adresse cible : 3 accusés par 24 h, le 4e envoi est refusé", async () => {
  for (let i = 2; i <= 3; i++) {
    await sendContact(visitor, { email: target, message: `Follow-up number ${i} about my quiz.` })
    await waitText(visitor, "#contact-sent", /Request received/)
  }
  await sendContact(visitor, { email: target, message: "A fourth message about my quiz." })
  await waitText(visitor, "#contact-quota", /3 acknowledgements in the last 24 hours/)
  if ((await mails()).filter((m) => to(m, target)).length !== 3) throw new Error("not exactly 3 acknowledgements")
})
const theo = await newPage()
await login(theo, "theo@mysticlore.test")
await step("staff (modérateur) : la demande dans /admin/support, adresse masquée, réponse reçue dans la boîte de dev", async () => {
  await visit(theo, `/admin/support?status=all&q=${reference}`)
  const row = theo.locator("#support-requests tbody tr", { hasText: reference })
  await row.waitFor({ timeout: T })
  if (!/v•••@example\.test/.test(await row.innerText())) throw new Error(`address not masked: ${await row.innerText()}`)
  await Promise.all([theo.waitForURL(/\/admin\/support\/[0-9a-f-]{36}$/, { timeout: T }), row.locator("a").first().click()])
  await connected(theo)
  await waitText(theo, "#support-message", new RegExp(secret))
  await theo.fill("#support-reply-form textarea", `Fixed for you ${stamp}.`)
  await theo.click("#send-reply")
  await waitText(theo, "#support-replies", /e-mail sent/)
  const reply = await waitMail((m) => to(m, target) && m.subject === `Reply to your request ${reference}`)
  if (!reply.text_body.includes(`Fixed for you ${stamp}.`)) throw new Error("reply text missing")
  if (reply.text_body.includes(secret)) throw new Error("the reply repeats the original message")
  await theo.selectOption("#manage_status", "closed")
  await theo.fill("#manage_internal_note", "Answered by e-mail.")
  await theo.click("#save-support")
  await theo.waitForSelector("#support-closed-note", { timeout: T })
})
await step("un membre ordinaire reçoit 403 sur /admin/support (le service le refuse aussi)", async () => {
  const r = await lea.goto(`${BASE}/admin/support`)
  if (r.status() !== 403) throw new Error(`status ${r.status()}`)
  await lea.goto(`${BASE}/dashboard`)
})

console.log("5. Accueil guidé d'un compte neuf")
const newbie = { email: `welcome_${stamp}@mysticlore.test`, username: `wel_${stamp}`, name: `Welcome ${stamp}`, password: "correct-horse-battery-staple" }
const n = await newPage()
let confirmUrl
await step("inscription, confirmation par la boîte de dev, connexion → /welcome", async () => {
  await n.goto(`${BASE}/register`)
  await n.fill('#register-form input[name="user[email]"]', newbie.email)
  await n.fill('#register-form input[name="user[username]"]', newbie.username)
  await n.fill('#register-form input[name="user[display_name]"]', newbie.name)
  await n.fill('#register-form input[name="user[password]"]', newbie.password)
  await Promise.all([n.waitForLoadState("load"), n.click('#register-form button[type="submit"]')])
  const mail = await waitMail((m) => to(m, newbie.email) && /confirm/i.test(m.subject))
  confirmUrl = JSON.stringify(mail).match(/https?:\/\/[^"\\\s]+\/confirm\/[A-Za-z0-9_-]+/)[0]
  await n.goto(confirmUrl)
  await Promise.all([n.waitForLoadState("load"), n.click('#confirm-form button[type="submit"]')])
  await login(n, newbie.email, newbie.password, /\/welcome/)
  await connected(n)
  await waitText(n, "#welcome-steps li[aria-current='step']", /Language and time zone/)
})
await step("étapes enregistrées par accounts : langue et fuseau, centres d'intérêt, objectif ; « Retour » montre la valeur enregistrée", async () => {
  await n.check("#welcome-language-en")
  await n.selectOption("#welcome-time-zone", "Europe/Paris")
  await n.click("#welcome-save")
  await n.waitForURL(/step=interests/, { timeout: T })
  await waitText(n, "#welcome-status", /Language and time zone saved/)
  await n.check("#welcome-interest-astronomy")
  await n.check("#welcome-interest-mythology")
  await n.click("#welcome-save")
  await n.waitForURL(/step=goal/, { timeout: T })
  await n.check("#welcome-goal-50")
  await n.click("#welcome-save")
  await n.waitForURL(/step=accessibility/, { timeout: T })
  await n.click("#welcome-back")
  await n.waitForURL(/step=goal/, { timeout: T })
  if (!(await n.isChecked("#welcome-goal-50"))) throw new Error("the saved goal is not shown back")
  await n.click("#welcome-skip-step")
  await n.waitForURL(/step=accessibility/, { timeout: T })
  await n.check("#welcome-underline-links")
  await n.click("#welcome-save")
  await n.waitForURL(/step=adventures/, { timeout: T })
  if ((await n.getAttribute("html", "data-links")) !== "underline") throw new Error("accessibility not applied at once")
})
await step("dernière étape : vraies recommandations, fin → tableau de bord (objectif de 50 XP)", async () => {
  await n.waitForSelector("#welcome-recommendations li", { timeout: T })
  await Promise.all([n.waitForURL(/\/dashboard$/, { timeout: T }), n.click("#welcome-finish")])
  await connected(n)
  await waitText(n, "#goal-progress", /\/ 50 XP today/)
})
await step("connexion suivante : plus de redirection vers /welcome ; relance depuis les paramètres", async () => {
  await Promise.all([n.waitForURL((u) => !u.pathname.startsWith("/dashboard"), { timeout: T }), n.click("#rail-logout")])
  await login(n, newbie.email, newbie.password, /\/dashboard$/)
  await visit(n, "/settings/preferences")
  await Promise.all([n.waitForURL(/\/welcome$/, { timeout: T }), n.click("#restart-onboarding")])
  await connected(n)
  await Promise.all([n.waitForURL(/\/dashboard$/, { timeout: T }), n.click("#welcome-skip-tour")])
})
await step("contact d'un membre : réponse du staff → notification, réponse visible sur /contact, e-mail au compte", async () => {
  const memberSecret = `Member secret ${stamp}`
  await sendContact(n, { topic: "account", message: `${memberSecret}: where is my badge?` })
  await waitText(n, "#contact-acknowledged", new RegExp(newbie.email.replace(/[.]/g, "\\.")))
  const memberRef = (await n.innerText("#contact-sent")).match(/REQ-[0-9A-Z]{5}-[0-9A-Z]{5}/)[0]
  await visit(theo, `/admin/support?q=${memberRef}`)
  await Promise.all([theo.waitForURL(/\/admin\/support\/[0-9a-f-]{36}$/, { timeout: T }), theo.locator("#support-requests a", { hasText: memberRef }).click()])
  await connected(theo)
  await theo.fill("#support-reply-form textarea", `Your badge is back ${stamp}.`)
  await theo.click("#send-reply")
  await waitText(theo, "#support-replies", /e-mail sent/)
  await waitText(n, "#my-requests", new RegExp(`Your badge is back ${stamp}`))
  await visit(n, "/notifications")
  await waitText(n, "#notification-list", /The team answered your support request/)
  const mail = await waitMail((m) => to(m, newbie.email) && m.subject === `Reply to your request ${memberRef}`)
  if (mail.text_body.includes(memberSecret)) throw new Error("the reply repeats the member's message")
})

console.log("6. États expirés que l'on peut provoquer")
await step("lien de confirmation déjà utilisé, lien de réinitialisation et d'invitation inconnus", async () => {
  await n.goto(confirmUrl)
  await Promise.all([n.waitForLoadState("load"), n.click('#confirm-form button[type="submit"]')])
  await waitText(n, "#confirm-invalid", /This link can't be used/)
  await n.goto(`${BASE}/reset-password/not-a-real-token-${stamp}`)
  await waitText(n, "#reset-invalid", /This link can't be used/)
  await visit(n, `/multiplayer/join/${"x".repeat(24)}${stamp}`)
  await waitText(n, "#link-invalid", /isn't valid/)
})
await step("changement d'e-mail inconnu, export introuvable, paiement annulé : état explicite et action suivante", async () => {
  await visit(n, "/settings/confirm-email/not-a-real-token")
  await n.click("#confirm-email-button")
  await waitText(n, "#confirm-email-invalid", /links last 24 hours/)
  await n.goto(`${BASE}/settings/exports/00000000-0000-4000-8000-000000000000/download`)
  await n.waitForURL(/\/settings\/data\?export=missing/, { timeout: T })
  await waitText(n, "#export-link-state", /This export doesn't exist/)
  await visit(n, "/membership/cancel")
  await waitText(n, "#checkout-canceled", /No payment was made/)
})
await step("session révoquée ailleurs : la page ouverte mène à la connexion qui l'explique, puis y revient", async () => {
  const other = await newPage()
  await login(other, newbie.email, newbie.password, /\/dashboard$/)
  await visit(n, "/friends")
  await visit(other, "/settings/security")
  await other.click("#revoke-other-sessions")
  await n.waitForURL(/\/login\?reason=expired&return_to=%2Ffriends/, { timeout: T })
  await waitText(n, "#session-expired", /Your session has ended/)
  await n.fill('#login-form input[name="user[email]"]', newbie.email)
  await n.fill('#login-form input[name="user[password]"]', newbie.password)
  await Promise.all([n.waitForURL(/\/friends$/, { timeout: T }), n.click('#login-form button[type="submit"]')])
  await other.context().close()
})

console.log("7. États réseau")
await step("hors ligne (context.setOffline) : bandeau poli « offline », envois désactivés, puis rétablis", async () => {
  await visit(lea, "/settings/preferences")
  await lea.context().setOffline(true)
  await lea.waitForSelector("#connection-status:not([hidden])", { timeout: T })
  await waitText(lea, "#connection-status", /You seem to be offline/)
  if ((await lea.getAttribute("#connection-status", "role")) !== "status") throw new Error("not a polite status")
  if (!(await lea.isDisabled("#save-language"))) throw new Error("submit still enabled while offline")
  await lea.context().setOffline(false)
  await lea.waitForSelector("#connection-status[hidden]", { state: "attached", timeout: T })
  await connected(lea)
  if (await lea.isDisabled("#save-language")) throw new Error("submit still disabled once online")
})
await step("connexion LiveView perdue : « Reconnecting… », puis « Retry now » reconnecte vraiment", async () => {
  await visit(lea, "/contact")
  await lea.evaluate(() => window.liveSocket.getSocket().disconnect())
  await lea.waitForSelector("#connection-status:not([hidden])", { timeout: T })
  await waitText(lea, "#connection-status", /Reconnecting/)
  if (!(await lea.isDisabled("#contact-submit"))) throw new Error("submit enabled while disconnected")
  await lea.click("#connection-retry")
  await connected(lea)
  await lea.waitForSelector("#connection-status[hidden]", { state: "attached", timeout: T })
  if (await lea.isDisabled("#contact-submit")) throw new Error("submit still disabled after reconnecting")
})

console.log("8. Page d'accueil")
await step("aperçu statique du studio, aucun témoignage ni note, aide/contact/juridique, 390 px sans défilement", async () => {
  const phone = await newPage({ width: 390 })
  await visit(phone, "/")
  await waitText(phone, "#studio-preview", /Example — static illustration/)
  // aucun avis inventé : ni section de témoignages, ni note (le projet n'a pas de vrais retours à montrer)
  if (await phone.locator("#testimonials, [id^=testimonial-]").count()) throw new Error("testimonials are shown")
  if (/★|☆|\d\s?\/\s?5\b/.test(await phone.innerText("main"))) throw new Error("a rating is shown")
  // la mention du projet de formation reste, discrète, dans le pied de page
  await waitText(phone, "footer .demo-note", /Demo project/)
  for (const sel of ["#home-help[href='/help']", "#home-contact[href='/contact']", "#home-legal[href='/legal']"])
    if (!(await phone.locator(sel).count())) throw new Error(`missing ${sel}`)
  for (const path of ["/", "/help", "/contact", "/legal/privacy", "/legal/cookies"]) {
    await visit(phone, path)
    const info = await layout(phone)
    if (info.overflow > 0) throw new Error(`${path}: horizontal scroll ${info.overflow}px`)
    if (info.small.length) throw new Error(`${path}: small controls ${info.small.join(" | ")}`)
  }
})

await step("aucune erreur JS ni réponse 5xx pendant le parcours", async () => {
  const errors = pages.flatMap((p) => p.errors)
  if (errors.length) throw new Error(errors.slice(0, 3).join(" ; "))
})

await browser.close()
const ok = results.filter(Boolean).length
console.log(`\n${ok}/${results.length} étapes OK`)
process.exit(ok === results.length ? 0 : 1)
