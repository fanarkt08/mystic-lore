// Mise en page de 320 à 1440 px : défilement horizontal, contrôles < 44 px, erreurs JS et 5xx.
// Usage : node responsive.mjs   (SHOTS=1 pour des captures dans shots/, LOCALE=fr pour les libellés français)
import { chromium } from "playwright-core"
import { mkdirSync } from "node:fs"

const BASE = process.env.BASE || "http://localhost:4000"
const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
const WIDTHS = [320, 390, 768, 1024, 1440]
const LOCALE = process.env.LOCALE === "fr" ? "fr" : "en"
const newContext = async (width) => {
  const ctx = await browser.newContext({ viewport: { width, height: 900 }, locale: LOCALE === "fr" ? "fr-FR" : "en-US" })
  if (LOCALE === "fr") await ctx.addCookies([{ name: "ml_locale", value: "fr", url: BASE, sameSite: "Lax", httpOnly: true }])
  return ctx
}
const PUBLIC = ["/", "/adventures", "/adventures/la-foret-des-murmures", "/community", "/login", "/register", "/forgot-password",
  // aide, contact, pages juridiques provisoires, connexion après une session terminée
  "/help", "/help?q=password", "/contact", "/legal", "/legal/privacy", "/legal/terms", "/legal/cookies", "/legal/accessibility",
  "/login?reason=expired&return_to=%2Fdashboard",
  // page hors ligne (générique, sans leçon pour un visiteur)
  "/offline"]
const MEMBER = ["/dashboard", "/adventures", "/adventures/la-machine-de-l-alchimiste", "LESSON", "/membership", "/friends", "/messages", "CONVERSATION",
  "GROUP", "/messages/new", "/members/hugo_bernard", "/settings", "/settings/privacy", "/achievements", "/multiplayer", "/community/new", "/studio",
  "/studio/credits", "/account/sanctions", "/notifications", "/settings/notifications",
  // contact d'un membre (ses demandes), accueil guidé (première et dernière étapes), un document juridique
  "/contact", "/welcome", "/welcome?step=adventures", "/legal/privacy",
  // leçon premium avec sa carte « Offline copy », section des paramètres, page hors ligne (liste et
  // leçon gardée sur l'appareil)
  "PREMIUM_LESSON", "/settings/offline", "/offline", "OFFLINE_LESSON"]
const ADMIN = ["/admin", "/admin/reports", "/admin/members", "/admin/audit", "/admin/billing", "/admin/incidents", "/studio/review",
  "/admin/support?status=all", "SUPPORT_REQUEST"]
const problems = []
const browser = await chromium.launch({ executablePath: CHROME, headless: true })
if (process.env.SHOTS) mkdirSync("shots", { recursive: true })
console.log(`Mise en page — ${BASE} — langue ${LOCALE}, largeurs ${WIDTHS.join(", ")} px`)

async function login(ctx, email = "lyra@mysticlore.test") {
  const p = await ctx.newPage()
  await p.goto(`${BASE}/login`)
  await p.fill('#login-form input[name="user[email]"]', email)
  await p.fill('#login-form input[name="user[password]"]', process.env.DEMO_PASSWORD || "mystic-demo-pass-1")
  await Promise.all([p.waitForURL(/\/dashboard/), p.click('#login-form button[type="submit"]')])
  // résout les chemins dynamiques (une leçon, une conversation)
  await p.goto(`${BASE}/adventures/la-foret-des-murmures`)
  const lesson = await p.$eval('a[href^="/learn/"]', (a) => a.getAttribute("href")).catch(() => null)
  await p.goto(`${BASE}/messages`)
  const conv = await p.$eval('#conversations a[href^="/messages/"]', (a) => a.getAttribute("href")).catch(() => null)
  const group = await p.$eval('#conversations a:has-text("Révisions du soir")', (a) => a.getAttribute("href")).catch(() => null)
  // une leçon premium (Léa est Premium) gardée hors ligne : la page hors ligne a alors une liste et une leçon
  await p.goto(`${BASE}/adventures/la-machine-de-l-alchimiste`)
  const premium = await p.$eval('a[href^="/learn/"]:has-text("Équilibrer les vannes")', (a) => a.getAttribute("href")).catch(() => null)
  let offline = null
  if (premium) {
    await p.goto(BASE + premium)
    await p.waitForSelector("#offline-download:not([disabled])", { timeout: 10_000 }).catch(() => {})
    await p.click("#offline-download").catch(() => {})
    offline = await p.waitForSelector("#offline-open:not([hidden])", { timeout: 15_000 }).then(() => `/offline?lesson=${premium.split("/").pop()}`).catch(() => null)
  }
  await p.close()
  return {
    LESSON: lesson || "/dashboard", CONVERSATION: conv || "/messages", GROUP: group || "/messages",
    PREMIUM_LESSON: premium || "/dashboard", OFFLINE_LESSON: offline || "/offline",
  }
}

async function audit(page, path, width, label) {
  const errors = []
  const onConsole = (m) => m.type() === "error" && !/Failed to load resource/.test(m.text()) && errors.push(m.text())
  const onPageError = (e) => errors.push(String(e))
  page.on("console", onConsole)
  page.on("pageerror", onPageError)
  const resp = await page.goto(BASE + path, { waitUntil: "networkidle" })
  await page.waitForSelector("[data-phx-main].phx-connected", { timeout: 10_000 }).catch(() => {})
  const info = await page.evaluate(() => {
    const de = document.documentElement
    const visible = (e) => { const r = e.getBoundingClientRect(); const s = getComputedStyle(e); return r.width > 0 && r.height > 0 && s.visibility !== "hidden" && !e.closest("[hidden]") }
    const wide = [...document.querySelectorAll("body *")].filter((e) => visible(e) && e.getBoundingClientRect().right > de.clientWidth + 1 && getComputedStyle(e).position !== "fixed")
      .slice(0, 3).map((e) => `${e.tagName}#${e.id}.${String(e.className).slice(0, 40)}`)
    const small = [...document.querySelectorAll("button, a.btn, input:not([type=hidden]):not([type=checkbox]):not([type=radio]), select, textarea")]
      .filter((e) => visible(e) && e.getBoundingClientRect().height < 44).slice(0, 3).map((e) => `${e.tagName}#${e.id} h=${Math.round(e.getBoundingClientRect().height)}`)
    return { overflow: de.scrollWidth > de.clientWidth + 1, wide, small }
  })
  page.off("console", onConsole)
  page.off("pageerror", onPageError)
  const status = resp ? resp.status() : 0
  const tag = `${LOCALE} ${label} ${width}px ${path}`
  if (status >= 500) problems.push(`${tag}: HTTP ${status}`)
  if (info.overflow) problems.push(`${tag}: défilement horizontal (${info.wide.join(" | ")})`)
  if (info.small.length) problems.push(`${tag}: contrôles < 44 px (${info.small.join(" | ")})`)
  if (errors.length) problems.push(`${tag}: erreurs (${errors.slice(0, 2).join(" ; ").slice(0, 200)})`)
  if (process.env.SHOTS && (width === 390 || width === 1440))
    await page.screenshot({ path: `shots/${LOCALE}_${label}_${width}_${path.replace(/\W+/g, "_") || "home"}.png`, fullPage: true })
  console.log(`${tag} → ${status}${info.overflow ? " OVERFLOW" : ""}${info.small.length ? " SMALL" : ""}${errors.length ? " ERR" : ""}`)
}

for (const width of WIDTHS) {
  const anon = await newContext(width)
  const page = await anon.newPage()
  for (const path of PUBLIC) await audit(page, path, width, "public")
  await anon.close()
  const ctx = await newContext(width)
  const dyn = await login(ctx)
  const mp = await ctx.newPage()
  for (const path of MEMBER) await audit(mp, dyn[path] || path, width, "member")
  await ctx.close()
  const adminCtx = await newContext(width)
  await login(adminCtx, "aster@mysticlore.test")
  const ap = await adminCtx.newPage()
  // une demande de support (créée par pages.mjs, qui passe avant) : la liste se charge une fois la page connectée
  await ap.goto(BASE + "/admin/support?status=all")
  await ap.waitForSelector("[data-phx-main].phx-connected", { timeout: 10_000 }).catch(() => {})
  const request = await ap.waitForSelector("#support-requests a[href^='/admin/support/']", { timeout: 5_000 })
    .then((a) => a.getAttribute("href")).catch(() => null)
  const adminDyn = { SUPPORT_REQUEST: request || "/admin/support" }
  for (const path of ADMIN) await audit(ap, adminDyn[path] || path, width, "admin")
  await adminCtx.close()
}
await browser.close()
console.log(`\n${(PUBLIC.length + MEMBER.length + ADMIN.length) * WIDTHS.length} contrôles (${PUBLIC.length + MEMBER.length + ADMIN.length} pages × ${WIDTHS.length} largeurs, langue ${LOCALE})`)
console.log("\n=== PROBLÈMES ===\n" + (problems.length ? problems.join("\n") : "aucun"))
process.exit(problems.length ? 1 : 0)
