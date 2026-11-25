// Outils partagés de a11y.mjs, keyboard.mjs et i18n.mjs : pages par rôle, chemins dynamiques et états construits.
// Rien n'est envoyé hors de localhost.
import { chromium } from "playwright-core"
import { createHmac } from "node:crypto"
import { execFileSync } from "node:child_process"
import { hostname } from "node:os"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"

export const BASE = process.env.BASE || "http://localhost:4000"
export const ACCOUNTS = process.env.ACCOUNTS || "http://localhost:4001"
export const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
export const DEMO_PASSWORD = process.env.DEMO_PASSWORD || "mystic-demo-pass-1"
export const T = 20_000
export const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..")
export const DEMO = {
  lea: "lyra@mysticlore.test", // Premium
  hugo: "orion@mysticlore.test", // Free
  theo: "theo@mysticlore.test", // modérateur
  clara: "aster@mysticlore.test", // administratrice
}

export const pause = (ms) => new Promise((r) => setTimeout(r, ms))
export const launch = () => chromium.launch({ executablePath: CHROME, headless: !process.env.HEADED })

// ───────────────────────────────────────────── étapes (même convention que les autres scripts)
export function steps() {
  const results = []
  async function step(name, fn) {
    const t0 = Date.now()
    try {
      await fn()
      results.push(true)
      console.log(`  ✓ ${name} (${Date.now() - t0} ms)`)
    } catch (e) {
      results.push(false)
      console.log(`  ✗ ${name}\n      ${String(e.message || e).split("\n").slice(0, 6).join("\n      ")}`)
    }
  }
  const summary = () => {
    const ok = results.filter(Boolean).length
    console.log(`\n${ok}/${results.length} étapes OK`)
    return ok === results.length
  }
  return { step, summary, results }
}

// ───────────────────────────────────────────── contextes et pages
// Chaque page note ses erreurs JS et ses réponses 5xx (les 4xx sont des refus voulus).
export const allPages = []
export async function newContext(browser, { width = 1280, height = 900, lang = "en", ...rest } = {}) {
  const ctx = await browser.newContext({
    viewport: { width, height },
    locale: "en-US",
    timezoneId: "Europe/Paris",
    ...rest,
  })
  // visiteur : la langue vient du cookie du sélecteur du pied de page (MysticWeb.Locale)
  if (lang === "fr") await ctx.addCookies([{ name: "ml_locale", value: "fr", url: BASE, sameSite: "Lax", httpOnly: true }])
  return ctx
}
export async function newPage(ctx) {
  const page = await ctx.newPage()
  page.on("dialog", (d) => d.accept())
  page.errors = []
  page.on("pageerror", (e) => page.errors.push(String(e)))
  page.on("console", (m) => m.type() === "error" && !/Failed to load resource/.test(m.text()) && page.errors.push(m.text()))
  page.on("response", (r) => r.status() >= 500 && page.errors.push(`HTTP ${r.status()} ${r.url()}`))
  allPages.push(page)
  return page
}

export const connected = (page, timeout = T) => page.waitForSelector("[data-phx-main].phx-connected", { timeout })
// une page LiveView attend sa connexion ; une page servie par un contrôleur (connexion, /offline) non
export async function visit(page, path, { wait = "load" } = {}) {
  const response = await page.goto(BASE + path, { waitUntil: wait })
  if (await page.locator("[data-phx-main]").count()) await connected(page)
  return response
}
export const waitText = (page, selector, re, timeout = T) =>
  page.waitForFunction(([s, src]) => { const e = document.querySelector(s); return e && new RegExp(src, "i").test(e.innerText) }, [selector, re.source], { timeout })

export async function login(page, email, password = DEMO_PASSWORD) {
  await page.goto(`${BASE}/login`)
  await page.fill('#login-form input[name="user[email]"]', email)
  await page.fill('#login-form input[name="user[password]"]', password)
  await Promise.all([page.waitForURL(/\/(dashboard|welcome)/, { timeout: T }), page.click('#login-form button[type="submit"]')])
  if (/\/welcome/.test(page.url())) {
    await connected(page)
    await Promise.all([page.waitForURL(/\/dashboard/, { timeout: T }), page.click("#welcome-skip-tour")])
  }
  await connected(page)
}

// Langue d'un membre : sa préférence (paramètres › préférences), « auto » = celle du navigateur.
export async function setLanguage(page, value) {
  await visit(page, "/settings/preferences")
  if (await page.isChecked(`#language-choice-${value}`)) return
  await page.check(`#language-choice-${value}`)
  await Promise.all([page.waitForEvent("load", { timeout: T }), page.click("#save-language")])
  await connected(page)
}

// ───────────────────────────────────────────── nouveaux comptes (boîte de dev d'accounts)
export async function confirmationLink(email) {
  for (let i = 0; i < 60; i++) {
    const { data } = await (await fetch(`${ACCOUNTS}/dev/mailbox/json`)).json()
    const mail = data.filter((m) => JSON.stringify(m).includes(email)).pop()
    const url = mail && JSON.stringify(mail).match(/https?:\/\/[^"\\\s]+\/confirm\/[A-Za-z0-9_-]+/)?.[0]
    if (url) return url
    await pause(250)
  }
  throw new Error(`no confirmation e-mail for ${email}`)
}
export async function signUp(page, prefix) {
  const stamp = `${Date.now().toString(36)}${Math.floor(Math.random() * 1e4).toString(36)}`
  const member = { email: `${prefix}_${stamp}@mysticlore.test`, username: `${prefix.slice(0, 4)}_${stamp}`, name: `${prefix} ${stamp}`, password: "correct-horse-battery-staple" }
  await page.goto(`${BASE}/register`)
  await page.fill('#register-form input[name="user[email]"]', member.email)
  await page.fill('#register-form input[name="user[username]"]', member.username)
  await page.fill('#register-form input[name="user[display_name]"]', member.name)
  await page.fill('#register-form input[name="user[password]"]', member.password)
  await Promise.all([page.waitForLoadState("load"), page.click('#register-form button[type="submit"]')])
  await page.goto(await confirmationLink(member.email))
  await Promise.all([page.waitForLoadState("load"), page.click('#confirm-form button[type="submit"]')])
  await login(page, member.email, member.password)
  return member
}

// Code TOTP (RFC 6238 : HMAC-SHA1, 30 s, 6 chiffres) d'un secret en base32, calculé localement.
export function totp(secret, at = Date.now()) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
  let bits = ""
  for (const c of secret.replace(/[\s=-]/g, "").toUpperCase()) bits += alphabet.indexOf(c).toString(2).padStart(5, "0")
  const key = Buffer.from(bits.match(/.{8}/g).map((b) => parseInt(b, 2)))
  const counter = Buffer.alloc(8)
  counter.writeBigUInt64BE(BigInt(Math.floor(at / 30_000)))
  const mac = createHmac("sha1", key).update(counter).digest()
  const o = mac[mac.length - 1] & 0xf
  return String((mac.readUInt32BE(o) & 0x7fffffff) % 1_000_000).padStart(6, "0")
}
// Un compte neuf avec la double authentification : la connexion suivante passe par /login/2fa.
export async function memberWithTwoFactor(page) {
  const member = await signUp(page, "twofa")
  await visit(page, "/settings/security")
  await page.fill("#two-factor-setup-form input[type=password]", member.password)
  await page.click("#two-factor-setup-form button[type=submit]")
  await page.waitForSelector("#two-factor-secret", { timeout: T })
  member.secret = (await page.innerText("#two-factor-secret")).replace(/\s/g, "")
  await page.fill("#two-factor-enable-form input[name*=one_time_password]", totp(member.secret))
  await page.click("#two-factor-enable-form button[type=submit]")
  await page.waitForSelector("#recovery-codes", { timeout: T })
  member.recovery = (await page.innerText("#recovery-codes")).match(/\b[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}\b/)?.[0]
  return member
}
export async function logout(page) {
  await visit(page, "/settings")
  await Promise.all([page.waitForURL((u) => !u.pathname.startsWith("/settings"), { timeout: T }), page.click("#rail-logout, #more-menu a[data-to='/logout']")])
}

// ───────────────────────────────────────────── pages par rôle
// celles de responsive.mjs, plus les sections des paramètres, les détails et les formats de leçon
export const PUBLIC = ["/", "/adventures", "/adventures/la-foret-des-murmures", "/community", "/login", "/register", "/forgot-password",
  "/help", "/help?q=password", "/contact", "/legal", "/legal/privacy", "/legal/terms", "/legal/cookies", "/legal/accessibility",
  "/login?reason=expired&return_to=%2Fdashboard", "/offline",
  "DISCUSSION", "/members/lea_moreau", "/reset-password/not-a-real-token"]
export const MEMBER = ["/dashboard", "/adventures", "/adventures/la-machine-de-l-alchimiste", "LESSON", "/membership", "/friends", "/messages", "CONVERSATION",
  "GROUP", "/messages/new", "/members/hugo_bernard", "/settings", "/settings/privacy", "/achievements", "/multiplayer", "/community/new", "/studio",
  "/studio/credits", "/account/sanctions", "/notifications", "/settings/notifications",
  "/contact", "/welcome", "/welcome?step=adventures", "/legal/privacy",
  "PREMIUM_LESSON", "/settings/offline", "/offline", "OFFLINE_LESSON",
  "/settings/account", "/settings/security", "/settings/preferences", "/settings/accessibility", "/settings/learning", "/settings/data",
  "/community", "DISCUSSION", "PROJECT", "/studio/new", "LOBBY", "/members/lea_moreau", "/help", "/membership/cancel",
  "FORMAT_quiz", "FORMAT_code", "FORMAT_video", "FORMAT_simulation", "FORMAT_sequence", "FORMAT_constellation"]
export const MODERATOR = ["/admin", "/admin/reports", "/admin/members", "/admin/sanctions-appeals", "/admin/incidents",
  "/admin/support?status=all", "/studio/review"]
export const ADMIN = ["/admin", "/admin/reports", "/admin/members", "/admin/audit", "/admin/billing", "/admin/incidents", "/studio/review",
  "/admin/support?status=all", "SUPPORT_REQUEST",
  "/admin/sanctions-appeals", "MEMBER_DETAIL", "REPORT_DETAIL"]

export const FORMATS = {
  story: ["la-foret-des-murmures", "Le bosquet se réveille"],
  quiz: ["la-foret-des-murmures", "Compter les plants"],
  code: ["la-foret-des-murmures", "Le bosquet des boucles"],
  video: ["l-atlas-celeste", "Lire le ciel de nuit"],
  simulation: ["l-atlas-celeste", "L'étoile errante"],
  sequence: ["les-gardiens-des-archives", "Classer les sources"],
  constellation: ["l-atlas-celeste", "Tracer la Grande Ourse"],
}

const firstHref = (page, selector) => page.$eval(selector, (a) => a.getAttribute("href")).catch(() => null)

// Chemins dynamiques d'un membre (Léa, Premium) : leçons, conversations, discussion, projet, salon, copie hors ligne.
export async function resolveMember(page, { offline = true } = {}) {
  const dyn = {}
  const lessons = {}
  for (const slug of new Set(Object.values(FORMATS).map(([s]) => s))) {
    await visit(page, `/adventures/${slug}`)
    for (const [title, href] of await page.$$eval('#chapters a[href^="/learn/"]', (as) => as.map((a) => [a.textContent.trim(), a.getAttribute("href")])))
      lessons[title] = href
  }
  for (const [kind, [, title]] of Object.entries(FORMATS)) dyn[`FORMAT_${kind}`] = lessons[title] || null
  dyn.LESSON = dyn.FORMAT_story
  await visit(page, "/messages")
  dyn.CONVERSATION = await firstHref(page, '#conversations a[href^="/messages/"]')
  dyn.GROUP = await firstHref(page, '#conversations a:has-text("Révisions du soir")')
  await visit(page, "/community")
  dyn.DISCUSSION = await firstHref(page, '#discussions a[href^="/community/discussions/"]')
  await visit(page, "/studio")
  dyn.PROJECT = await page.$$eval('main a[href^="/studio/"]', (as) => as.map((a) => a.getAttribute("href")).find((h) => /^\/studio\/[0-9a-f-]{36}$/.test(h)) || null)
  await visit(page, "/multiplayer")
  dyn.LOBBY = await firstHref(page, 'main a[href^="/multiplayer/lobbies/"]')
  await visit(page, "/adventures/la-machine-de-l-alchimiste")
  dyn.PREMIUM_LESSON = await firstHref(page, 'a[href^="/learn/"]:has-text("Équilibrer les vannes")')
  dyn.OFFLINE_LESSON = null
  if (offline && dyn.PREMIUM_LESSON) {
    await visit(page, dyn.PREMIUM_LESSON)
    await page.waitForSelector("#offline-download:not([disabled])", { timeout: 10_000 }).catch(() => {})
    if (await page.locator("#offline-open:not([hidden])").count() === 0) await page.click("#offline-download").catch(() => {})
    dyn.OFFLINE_LESSON = await page.waitForSelector("#offline-open:not([hidden])", { timeout: 15_000 })
      .then(() => `/offline?lesson=${dyn.PREMIUM_LESSON.split("/").pop()}`).catch(() => null)
  }
  const missing = Object.entries(dyn).filter(([, v]) => !v).map(([k]) => k)
  if (missing.length) console.log(`      ⚠ chemins non résolus : ${missing.join(", ")}`)
  return dyn
}
export async function resolveVisitor(page) {
  await visit(page, "/community")
  return { DISCUSSION: await firstHref(page, '#discussions a[href^="/community/discussions/"]') }
}
// Chemins dynamiques du staff : une demande de support (créée par pages.mjs), une fiche de membre, un signalement.
export async function resolveAdmin(page) {
  await visit(page, "/admin/support?status=all")
  const request = await page.waitForSelector("#support-requests a[href^='/admin/support/']", { timeout: 5_000 }).then((a) => a.getAttribute("href")).catch(() => null)
  await visit(page, "/admin/members")
  const member = await firstHref(page, 'main a[href^="/admin/members/"]')
  await visit(page, "/admin/reports")
  const report = await firstHref(page, 'main a[href^="/admin/reports/"]')
  return { SUPPORT_REQUEST: request, MEMBER_DETAIL: member, REPORT_DETAIL: report }
}
export const resolve = (dyn, path) => (dyn && Object.hasOwn(dyn, path) ? dyn[path] : path)

// ───────────────────────────────────────────── pages d'erreur thématiques (403, 404, 500)
// En dev, `debug_errors: true` affiche Plug.Debugger : le vrai gabarit est donc rendu par le nœud web et servi par page.route.
export function renderErrorPages(locales = ["en", "fr"]) {
  const host = hostname().split(".")[0]
  const code = `
    node = :"web@${host}"
    true = Node.connect(node)
    for locale <- ~w(${locales.join(" ")}), code <- ~w(403 404 500) do
      html = :erpc.call(node, Code, :eval_string, [
        "Gettext.put_locale(MysticWeb.Gettext, \\"#{locale}\\"); MysticWeb.ErrorHTML.render(\\"#{code}.html\\", %{}) |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()"
      ]) |> elem(0)
      IO.puts("=====#{locale}:#{code}=====")
      IO.puts(Base.encode64(html))
    end`
  const out = execFileSync("elixir", ["--sname", `a11y_${process.pid}`, "--cookie", process.env.ERL_COOKIE || "mysticlore-dev-cookie", "-e", code], { encoding: "utf8", timeout: 60_000 })
  const pages = {}
  for (const [, key, b64] of out.matchAll(/=====(\w+:\d+)=====\n([A-Za-z0-9+/=]+)/g)) pages[key] = Buffer.from(b64, "base64").toString("utf8")
  return pages
}
export async function openErrorPage(page, html, code) {
  const url = `${BASE}/__a11y_error_preview_${code}`
  // servie avec le statut 200 : seul le gabarit est audité (le statut réel est vérifié par les tests de web)
  await page.route(url, (route) => route.fulfill({ status: 200, contentType: "text/html; charset=utf-8", body: html }))
  await page.goto(url, { waitUntil: "load" })
  await page.unroute(url)
}

// ───────────────────────────────────────────── états construits par les scripts
// `run(page, inspect, env)` amène la page dans l'état puis appelle `inspect(étiquette)` ; un état impossible fait échouer le script.
// juste avant l'envoi : une LiveView qui rend de nouveau le formulaire (phx-change) remettrait la validation du navigateur
const noValidate = (page, form) => page.$eval(form, (f) => { f.noValidate = true })
async function clearOfflineQueue(page) {
  await page.evaluate(() => new Promise((resolve) => {
    const open = indexedDB.open("mysticlore-offline")
    open.onsuccess = () => {
      const db = open.result
      if (!db.objectStoreNames.contains("queue")) return db.close(), resolve()
      const tx = db.transaction("queue", "readwrite")
      tx.objectStore("queue").clear()
      tx.oncomplete = () => (db.close(), resolve())
    }
    open.onerror = () => resolve()
  }))
}
async function conversationWith(page, name) {
  await visit(page, "/messages")
  const href = await page.$eval(`#conversations a:has-text("${name}")`, (a) => a.getAttribute("href"))
  await visit(page, href)
}
async function sendMessage(page, text) {
  await page.fill("#composer textarea", text)
  await page.click("#send-message")
  await waitText(page, "#messages", new RegExp(text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")))
}

export const STATES = [
  // ── hors ligne et connexion
  { id: "connection-offline", role: "member", run: async (page, inspect) => {
    await visit(page, "/settings/preferences")
    await page.context().setOffline(true)
    await page.waitForSelector("#connection-status:not([hidden])", { timeout: T })
    await inspect("bandeau « hors ligne », envois désactivés")
    await page.context().setOffline(false)
    await page.waitForSelector("#connection-status[hidden]", { state: "attached", timeout: T })
  } },
  { id: "connection-reconnecting", role: "member", run: async (page, inspect) => {
    await visit(page, "/contact")
    await page.evaluate(() => window.liveSocket.getSocket().disconnect())
    await waitText(page, "#connection-status", /Reconnect|Reconnexion|connexion/)
    await inspect("bandeau « reconnexion » et « Retry now »")
    await page.click("#connection-retry")
    await connected(page)
  } },
  { id: "offline-shell", role: "member", needs: ["PREMIUM_LESSON", "OFFLINE_LESSON"], run: async (page, inspect, { dyn }) => {
    // une copie hors ligne sur cet appareil (contexte neuf) : le premier téléchargement installe le service worker
    await visit(page, dyn.PREMIUM_LESSON)
    await page.waitForSelector("#offline-download:not([disabled])", { timeout: T })
    await page.click("#offline-download")
    await page.waitForSelector("#offline-open:not([hidden])", { timeout: T })
    await inspect("carte « Offline copy » : copie disponible")
    await visit(page, "/settings/preferences")
    await page.waitForFunction(() => navigator.serviceWorker?.controller, null, { timeout: T })
    await page.context().setOffline(true)
    try {
      await page.waitForSelector("#connection-offline-link:not([hidden])", { timeout: T })
      await inspect("bandeau « hors ligne » : les leçons hors ligne fonctionnent")
      await page.goto(`${BASE}/offline`)
      await page.waitForSelector("#offline-list li", { timeout: T })
      await inspect("/offline sans réseau : liste")
      await page.goto(BASE + dyn.OFFLINE_LESSON)
      await page.waitForSelector("#offline-quiz-form", { timeout: T })
      await page.click("#offline-save-answer")
      await page.waitForSelector("#offline-lesson-status:not(:empty)", { timeout: T })
      await inspect("/offline sans réseau : leçon, réponse manquante signalée")
      await page.locator("#offline-quiz-form label").first().click()
      await page.click("#offline-save-answer")
      await page.waitForSelector("#offline-lesson-pending", { timeout: T })
      await inspect("/offline sans réseau : réponse en attente de synchronisation")
      await page.goto(`${BASE}/dashboard`)
      await page.waitForSelector("#offline-page-unavailable", { timeout: T })
      await inspect("page du compte sans réseau → page hors ligne")
    } finally {
      // rien n'est synchronisé : la réponse mise en file est retirée avant le retour du réseau
      await clearOfflineQueue(page).catch(() => {})
      await page.context().setOffline(false)
    }
  } },
  // ── avis et toasts
  { id: "flash-error", role: "member", run: async (page, inspect) => {
    // Clara n'accepte aucune demande d'ami : le refus du service est affiché dans un toast d'erreur
    await visit(page, "/friends")
    await page.fill("#search-q", "clara")
    const row = page.locator("#search-results li", { hasText: "Clara" }).first()
    await row.getByRole("button", { name: /add friend|ajouter/i }).click()
    await page.waitForSelector("#flash-group [role=alert], #flash-group [role=status]", { timeout: T })
    await inspect("toast d'erreur (demande d'ami refusée)")
  } },
  { id: "notification-toast", role: "member", run: async (page, inspect, { actor }) => {
    await visit(page, "/dashboard")
    const hugo = await actor("hugo")
    await conversationWith(hugo, "Léa Moreau")
    await sendMessage(hugo, `Accessibility audit ping ${Date.now().toString(36)}`)
    await page.waitForSelector("#notification-toast", { timeout: T })
    await inspect("toast de notification et cloche")
  } },
  // ── dialogues, panneaux et menus
  { id: "studio-confirm", role: "member", needs: ["PROJECT"], run: async (page, inspect, { dyn }) => {
    await visit(page, `${dyn.PROJECT}?step=outline`)
    await page.click("#ai-outline")
    await page.waitForSelector("#confirm-generation", { timeout: T })
    await inspect("dialogue de confirmation d'une génération (studio)")
    await page.keyboard.press("Escape")
    await page.waitForSelector("#confirm-generation", { state: "detached", timeout: T })
  } },
  { id: "more-menu", role: "member", width: 390, run: async (page, inspect) => {
    await visit(page, "/dashboard")
    await page.click("button[popovertarget=more-menu]")
    await page.waitForSelector("#more-menu:popover-open", { timeout: T })
    await inspect("menu « More » ouvert (390 px)")
  } },
  { id: "message-details", role: "member", needs: ["GROUP"], run: async (page, inspect, { dyn }) => {
    await visit(page, dyn.GROUP)
    await page.click("#toggle-details")
    await page.waitForSelector("#details-panel", { timeout: T })
    await inspect("panneau des détails d'un groupe")
  } },
  { id: "message-sent", role: "member", needs: ["CONVERSATION"], run: async (page, inspect, { dyn }) => {
    await visit(page, dyn.CONVERSATION)
    await sendMessage(page, `Audit note ${Date.now().toString(36)}`)
    await inspect("conversation après un envoi")
  } },
  { id: "report-panel", role: "member", run: async (page, inspect) => {
    await visit(page, "/members/hugo_bernard")
    await page.locator("main button", { hasText: /^\s*(Report|Signaler)\s*$/ }).first().click()
    await page.waitForSelector("#report-panel", { timeout: T })
    await inspect("formulaire de signalement ouvert")
  } },
  { id: "forum-filters", role: "visitor", width: 390, run: async (page, inspect) => {
    await visit(page, "/community")
    await page.click(".community-filters-toggle")
    await page.waitForSelector("#community-filters.is-open", { timeout: T })
    await inspect("filtres du forum ouverts (390 px)")
  } },
  { id: "faq-open", role: "visitor", run: async (page, inspect) => {
    for (const path of ["/", "/help"]) {
      await visit(page, path)
      await page.$$eval("main details", (all) => all.forEach((d) => { d.open = true }))
      await inspect(`${path} : questions dépliées`)
    }
  } },
  { id: "video-transcript", role: "member", needs: ["FORMAT_video"], run: async (page, inspect, { dyn }) => {
    await visit(page, dyn.FORMAT_video)
    await page.click("#toggle-transcript")
    await page.waitForSelector("#transcript:not([hidden])", { timeout: T })
    await inspect("vidéo : transcription ouverte")
  } },
  // ── formulaires montrés avec leurs erreurs
  { id: "register-errors", role: "visitor", run: async (page, inspect) => {
    await visit(page, "/register")
    await noValidate(page, "#register-form")
    await page.fill('#register-form input[name="user[email]"]', "lyra@mysticlore.test")
    await page.fill('#register-form input[name="user[username]"]', "x")
    await page.fill('#register-form input[name="user[password]"]', "short")
    await Promise.all([page.waitForLoadState("load"), page.click('#register-form button[type="submit"]')])
    await page.waitForSelector(".field-error", { timeout: T })
    await inspect("inscription refusée : erreurs des champs")
  } },
  { id: "login-error", role: "visitor", run: async (page, inspect) => {
    await visit(page, "/login")
    await page.fill('#login-form input[name="user[email]"]', `nobody_${Date.now()}@mysticlore.test`)
    await page.fill('#login-form input[name="user[password]"]', "not-the-password")
    await Promise.all([page.waitForLoadState("load"), page.click('#login-form button[type="submit"]')])
    await page.waitForSelector("#login-error [role=alert]", { timeout: T })
    await inspect("connexion refusée")
  } },
  { id: "contact-errors", role: "visitor", run: async (page, inspect) => {
    await visit(page, "/contact")
    await page.fill("#contact_message", "short")
    await noValidate(page, "#contact-form")
    await page.click("#contact-submit")
    await page.waitForSelector("#contact-form .field-error, #contact-invalid", { timeout: T })
    await inspect("contact : erreurs de validation")
  } },
  { id: "discussion-errors", role: "member", run: async (page, inspect) => {
    await visit(page, "/community/new")
    await page.fill("#discussion_title", "ab")
    await noValidate(page, "#discussion-form")
    await page.click("#save-discussion")
    await page.waitForSelector("#discussion-form .field-error", { timeout: T })
    await inspect("nouvelle discussion : erreurs de validation")
  } },
  { id: "password-errors", role: "member", run: async (page, inspect) => {
    await visit(page, "/settings/account")
    await page.fill("#password-form input[name*=current_password]", "not-my-password")
    await page.fill("#password-form input[name*='[password]']:not([name*=current])", "another-long-password-1")
    await page.click("#change-password")
    await page.waitForSelector("#password-form .field-error, #password-form [role=alert]", { timeout: T })
    await inspect("mot de passe : erreur du mot de passe actuel")
  } },
  // ── lecteur de leçon : chaque format après une action
  { id: "quiz-answered", role: "member", needs: ["FORMAT_quiz"], run: async (page, inspect, { dyn }) => {
    await visit(page, dyn.FORMAT_quiz)
    await page.locator("#quiz-form label.choice").first().click()
    await page.click("#check-answer")
    await page.waitForSelector("#lesson-result", { timeout: T })
    await inspect("quiz : réponse corrigée")
  } },
  { id: "code-run", role: "member", needs: ["FORMAT_code"], run: async (page, inspect, { dyn }) => {
    await visit(page, dyn.FORMAT_code)
    await page.click("#run-code")
    await page.waitForSelector("#lesson-result", { timeout: T })
    await inspect("code : résultat de l'exécution")
  } },
  { id: "simulation-run", role: "member", needs: ["FORMAT_simulation"], run: async (page, inspect, { dyn }) => {
    await visit(page, dyn.FORMAT_simulation)
    await page.click("#run-sim")
    await page.waitForSelector("#sim-table", { timeout: T })
    await inspect("simulation : tableau des résultats")
  } },
  { id: "sequence-checked", role: "member", needs: ["FORMAT_sequence"], run: async (page, inspect, { dyn }) => {
    await visit(page, dyn.FORMAT_sequence)
    await page.locator("#sequence-list button:not([disabled])").first().click()
    await page.click("#check-game")
    await page.waitForSelector("#lesson-result, #game-score", { timeout: T })
    await inspect("mini-jeu (ordre) : vérifié")
  } },
  { id: "constellation-path", role: "member", needs: ["FORMAT_constellation"], run: async (page, inspect, { dyn }) => {
    await visit(page, dyn.FORMAT_constellation)
    for (const button of (await page.$$(".star-button")).slice(0, 2)) await button.click()
    await page.waitForSelector("#undo-star:not([disabled])", { timeout: T })
    await inspect("mini-jeu (constellation) : chemin commencé")
  } },
  // ── salon multijoueur : salle d'attente, puis partie
  { id: "lobby", role: "fresh", run: async (page, inspect, { actor }) => {
    // un hôte neuf : un membre héberge au plus 3 salons, et chaque exécution en crée un
    await signUp(page, "host")
    await visit(page, "/multiplayer")
    await page.fill("#create-lobby input[name*=title]", `Audit relay ${Date.now().toString(36)}`)
    await Promise.all([page.waitForURL(/\/multiplayer\/lobbies\//, { timeout: T }), page.click("#create-lobby button[type=submit]")])
    await connected(page)
    await page.waitForSelector("#members", { timeout: T })
    await inspect("salon : salle d'attente (hôte)")
    const hugo = await actor("hugo")
    await visit(hugo, new URL(page.url()).pathname)
    await hugo.click("#join-lobby")
    await hugo.waitForSelector("#ready-toggle", { timeout: T })
    await hugo.click("#ready-toggle")
    await page.click("#ready-toggle")
    await page.waitForSelector("#start-game:not([disabled])", { timeout: T })
    await page.click("#start-game")
    await page.waitForSelector("#my-hints li", { timeout: T })
    await inspect("salon : partie en cours")
  } },
  // ── paiement simulé (sans payer)
  { id: "local-checkout", role: "hugo", run: async (page, inspect) => {
    await visit(page, "/membership")
    await Promise.all([page.waitForURL(/\/membership\/local-checkout\//, { timeout: T }), page.click("#checkout-premium")])
    await connected(page)
    await inspect("page de paiement simulé")
  } },
  // ── double authentification d'un compte neuf
  { id: "two-factor", role: "fresh", run: async (page, inspect) => {
    const member = await memberWithTwoFactor(page)
    await inspect("codes de secours affichés une fois")
    await logout(page)
    await page.goto(`${BASE}/login`)
    await page.fill('#login-form input[name="user[email]"]', member.email)
    await page.fill('#login-form input[name="user[password]"]', member.password)
    await Promise.all([page.waitForURL(/\/login\/2fa/, { timeout: T }), page.click('#login-form button[type="submit"]')])
    await inspect("/login/2fa")
    await page.fill("#two-factor-form input[name*=one_time_password]", "000000")
    await Promise.all([page.waitForLoadState("load"), page.click("#two-factor-form button[type=submit]")])
    await page.waitForSelector("#two-factor-error [role=alert]", { timeout: T })
    await inspect("/login/2fa : code refusé")
  } },
]
