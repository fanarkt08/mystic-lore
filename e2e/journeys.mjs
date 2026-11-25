// Parcours de bout en bout dans Chrome sur la pile de bin/dev ; chaque exécution crée un nouveau membre.
// Usage : cd e2e && npm i && node journeys.mjs   (BASE, ACCOUNTS, CHROME, HEADED=1)
import { chromium } from "playwright-core"

const BASE = process.env.BASE || "http://localhost:4000"
const ACCOUNTS = process.env.ACCOUNTS || "http://localhost:4001"
const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
const DEMO_PASSWORD = process.env.DEMO_PASSWORD || "mystic-demo-pass-1"
const T = 15_000

const results = []
const browser = await chromium.launch({ executablePath: CHROME, headless: !process.env.HEADED })

async function step(name, fn) {
  const t0 = Date.now()
  try {
    await fn()
    results.push(["✓", name, Date.now() - t0])
    console.log(`  ✓ ${name} (${Date.now() - t0} ms)`)
  } catch (e) {
    results.push(["✗", name, Date.now() - t0])
    console.log(`  ✗ ${name}\n      ${String(e.message || e).split("\n").slice(0, 3).join("\n      ")}`)
  }
}

async function newPage(width = 1280) {
  const ctx = await browser.newContext({ viewport: { width, height: 900 }, locale: "en-US" })
  const page = await ctx.newPage()
  page.on("dialog", (d) => d.accept()) // confirmations data-confirm (bloquer, résilier…)
  page.errors = []
  page.on("pageerror", (e) => page.errors.push(String(e)))
  // erreurs JS et réponses 5xx uniquement : les 4xx sont des refus voulus (ex. connexion non confirmée → 403)
  page.on("console", (m) => m.type() === "error" && !/Failed to load resource/.test(m.text()) && page.errors.push(m.text()))
  page.on("response", (r) => r.status() >= 500 && page.errors.push(`HTTP ${r.status()} ${r.url()}`))
  return page
}

// attend que la LiveView soit connectée (websocket établi)
const connected = (page) => page.waitForSelector("[data-phx-main].phx-connected", { timeout: T })

async function login(page, email, password) {
  await page.goto(`${BASE}/login`)
  await page.fill('#login-form input[name="user[email]"]', email)
  await page.fill('#login-form input[name="user[password]"]', password)
  await Promise.all([page.waitForLoadState("load"), page.click('#login-form button[type="submit"]')])
}

// Un compte neuf passe par l'accueil guidé à sa première connexion ; « Passer l'accueil » l'enregistre.
async function passWelcome(page) {
  if (!/\/welcome/.test(page.url())) return
  await page.waitForSelector("[data-phx-main].phx-connected", { timeout: T })
  await Promise.all([page.waitForURL(/\/dashboard/, { timeout: T }), page.click("#welcome-skip-tour")])
}

async function expectText(page, re, timeout = T) {
  await page.waitForFunction((src) => new RegExp(src, "i").test(document.body.innerText), re.source, { timeout })
}

const stamp = Date.now().toString(36)
const newbie = { email: `e2e_${stamp}@mysticlore.test`, username: `e2e_${stamp}`, name: `Wanderer ${stamp}`, password: "correct-horse-battery-staple" }

console.log(`MysticLore E2E — ${BASE} — membre de test : ${newbie.email}`)

// ─────────────────────────────────────────────────────────────── 1. inscription → vérification → connexion
console.log("1. Inscription → e-mail de confirmation → connexion")
const p = await newPage()
await step("inscription", async () => {
  await p.goto(`${BASE}/register`)
  await p.fill('#register-form input[name="user[email]"]', newbie.email)
  await p.fill('#register-form input[name="user[username]"]', newbie.username)
  await p.fill('#register-form input[name="user[display_name]"]', newbie.name)
  await p.fill('#register-form input[name="user[password]"]', newbie.password)
  await Promise.all([p.waitForLoadState("load"), p.click('#register-form button[type="submit"]')])
  await expectText(p, /check your (email|inbox)/)
})
await step("connexion refusée tant que l'e-mail n'est pas confirmé", async () => {
  await login(p, newbie.email, newbie.password)
  if (!p.url().includes("/login")) throw new Error("connecté sans confirmation : " + p.url())
  await expectText(p, /confirm/)
})
let confirmUrl
await step("e-mail de confirmation reçu (boîte de dev d'accounts)", async () => {
  for (let i = 0; i < 20 && !confirmUrl; i++) {
    const { data } = await (await fetch(`${ACCOUNTS}/dev/mailbox/json`)).json()
    const mail = data.filter((m) => JSON.stringify(m).includes(newbie.email)).pop()
    const m = mail && JSON.stringify(mail).match(/https?:\/\/[^"\\\s]+\/confirm\/[A-Za-z0-9_-]+/)
    if (m) confirmUrl = m[0]
    else await new Promise((r) => setTimeout(r, 250))
  }
  if (!confirmUrl) throw new Error("aucun lien de confirmation trouvé")
})
await step("confirmation par le lien (bouton, pas de GET qui consomme)", async () => {
  await p.goto(confirmUrl)
  await Promise.all([p.waitForLoadState("load"), p.click('#confirm-form button[type="submit"]')])
  await expectText(p, /confirmed|you can now log in|welcome/)
})
await step("connexion → accueil guidé (compte neuf), passé → tableau de bord", async () => {
  await login(p, newbie.email, newbie.password)
  await p.waitForURL(/\/welcome/, { timeout: T })
  await passWelcome(p)
  await p.waitForURL(/\/dashboard/, { timeout: T })
  await connected(p)
  await expectText(p, new RegExp(newbie.name))
})

// ─────────────────────────────────────────────────────────────── 2. catalogue → leçon → progression, XP unique
console.log("2. Catalogue → inscription à l'aventure → leçons → XP accordée une seule fois")
await step("catalogue filtré dans l'URL", async () => {
  await p.goto(`${BASE}/adventures`)
  await connected(p)
  await p.fill('input[type="search"]', "murmures")
  await p.waitForURL(/q=murmures/, { timeout: T })
  await expectText(p, /La Forêt des murmures/)
})
await step("inscription à La Forêt des murmures → première leçon ouverte", async () => {
  await p.goto(`${BASE}/adventures/la-foret-des-murmures`)
  await connected(p)
  await Promise.all([p.waitForURL(/\/learn\//, { timeout: T }), p.click("#cta-enroll")])
})
await step("récit : terminer → +XP", async () => {
  await connected(p)
  await p.click("#complete-lesson")
  await p.waitForSelector("#xp-awarded", { timeout: T })
})
await step("quiz : mauvaise réponse puis bonne → +XP, puis répétition sans double XP", async () => {
  await Promise.all([p.waitForURL(/\/learn\//), p.click("#next-lesson")])
  await connected(p)
  await p.waitForSelector("#quiz-form", { timeout: T })
  const labels = await p.$$eval("#quiz-form label.choice", (ls) => ls.map((l) => l.innerText.trim()))
  const good = labels.findIndex((t) => /^0,\s*1,\s*2$/.test(t))
  if (good < 0) throw new Error("choix « 0, 1, 2 » introuvable : " + labels.join(" | "))
  const bad = good === 0 ? 1 : 0
  await p.check(`#choice-${bad}`)
  await p.click("#check-answer")
  await expectText(p, /not quite/)
  await p.check(`#choice-${good}`)
  await p.click("#check-answer")
  await p.waitForSelector("#xp-awarded", { timeout: T })
  await p.click("#check-answer")
  await p.waitForSelector("#xp-duplicate", { timeout: T })
})
await step("Le bosquet des boucles : boucle bornée → plants 0, 1, 2 arrosés → +XP", async () => {
  await Promise.all([p.waitForURL(/\/learn\//), p.click("#next-lesson")])
  await connected(p)
  const code = p.locator("#code-form textarea")
  await code.fill("water(0)\nwater(1)\nwater(2)\n")
  await p.click("#run-code")
  await expectText(p, /not quite/) // sans boucle : refusé
  await code.fill("for plant in range(3):\n    water(plant)\n")
  await p.click("#run-code")
  await p.waitForSelector("#xp-awarded", { timeout: T })
  await expectText(p, /well done/)
})
await step("progression sauvegardée : le tableau de bord affiche l'XP gagnée", async () => {
  await p.goto(`${BASE}/dashboard`)
  await connected(p)
  await expectText(p, /\b(1[2-9]\d|[7-9]\d)\s*XP/) // 10 + 20 + 40 (+ 50 bonus si l'aventure est finie)
})

// ─────────────────────────────────────────────────────────────── 3. abonnement : checkout → webhook signé → droits
console.log("3. Abonnement Premium (paiement simulé) → webhook signé → contenu premium débloqué")
await step("contenu premium verrouillé pour un membre gratuit", async () => {
  await p.goto(`${BASE}/adventures/la-machine-de-l-alchimiste`)
  await connected(p)
  await p.waitForSelector("#cta-upgrade", { timeout: T })
})
let checkoutPath
await step("checkout Premium → page de paiement de démonstration", async () => {
  await p.goto(`${BASE}/membership`)
  await connected(p)
  await Promise.all([p.waitForURL(/\/membership\/local-checkout\//, { timeout: T }), p.click("#checkout-premium")])
  checkoutPath = new URL(p.url()).pathname
  await expectText(p, /demo/)
})
await step("échec de paiement simulé : rien n'est accordé", async () => {
  await connected(p)
  await p.click("#simulate-failure")
  await p.waitForSelector("#payment-failed", { timeout: T })
})
await step("paiement simulé → « en attente » puis activation par l'événement du webhook", async () => {
  await Promise.all([p.waitForURL(/\/membership\/success/, { timeout: T }), p.click("#pay")])
  await connected(p)
  await p.waitForFunction(() => /Welcome to Premium/i.test(document.querySelector("#status-title")?.innerText || ""), null, { timeout: T })
})
await step("la session de checkout réutilisée est close", async () => {
  await p.goto(BASE + checkoutPath)
  await connected(p)
  await p.waitForSelector("#checkout-closed", { timeout: T })
})
await step("leçon premium désormais accessible", async () => {
  await p.goto(`${BASE}/adventures/la-machine-de-l-alchimiste`)
  await connected(p)
  await Promise.all([p.waitForURL(/\/learn\//, { timeout: T }), p.click("#cta-enroll")])
  await connected(p)
  const body = await p.innerText("body")
  if (/premium (plan )?required|upgrade to/i.test(body)) throw new Error("leçon encore verrouillée")
})
await step("résiliation en fin de période puis reprise", async () => {
  await p.goto(`${BASE}/membership`)
  await connected(p)
  await p.click("#cancel-subscription")
  await p.waitForSelector("#resume-subscription", { timeout: T })
  await p.click("#resume-subscription")
  await p.waitForSelector("#cancel-subscription", { timeout: T })
})

// ─────────────────────────────────────────────────────────────── 4. social : demande d'ami → acceptation → message temps réel → blocage
console.log("4. Ami → acceptation → messages en temps réel (2 navigateurs) → blocage")
const lea = await newPage()
await step("connexion de Léa (2e navigateur)", async () => {
  await login(lea, "lyra@mysticlore.test", DEMO_PASSWORD)
  await lea.waitForURL(/\/dashboard/, { timeout: T })
})
await step("le nouveau membre envoie une demande d'ami à Léa", async () => {
  await p.goto(`${BASE}/friends`)
  await connected(p)
  await p.fill("#search-q", "lea")
  const row = p.locator("#search-results li", { hasText: "Léa Moreau" })
  await row.getByRole("button", { name: /add friend/i }).click()
  await expectText(p, /request sent|requests sent/)
})
await step("Léa voit la demande et l'accepte", async () => {
  await lea.goto(`${BASE}/friends`)
  await connected(lea)
  const row = lea.locator("li", { hasText: newbie.name }).first()
  await row.getByRole("button", { name: /^accept/i }).click()
  await lea.waitForSelector(`#friends-list >> text=${newbie.name}`, { timeout: T })
})
let convPath
await step("conversation : le message du nouveau membre apparaît chez Léa SANS rechargement", async () => {
  await p.goto(`${BASE}/friends`)
  await connected(p)
  const row = p.locator("#friends-list li", { hasText: "Léa Moreau" })
  await Promise.all([p.waitForURL(/\/messages\//, { timeout: T }), row.getByRole("button", { name: /message/i }).click()])
  convPath = new URL(p.url()).pathname
  await connected(p)
  await lea.goto(BASE + convPath)
  await connected(lea)
  const text = `Hello from the grove ${stamp}`
  await p.fill("#composer textarea", text)
  await p.click("#send-message")
  await lea.waitForSelector(`#messages >> text=${text}`, { timeout: T })
  const reply = `Welcome, wanderer ${stamp}`
  await lea.fill("#composer textarea", reply)
  await lea.click("#send-message")
  await p.waitForSelector(`#messages >> text=${reply}`, { timeout: T })
})
await step("un autre membre (Sarah) ne peut pas lire cette conversation", async () => {
  const s = await newPage()
  await login(s, "samira@mysticlore.test", DEMO_PASSWORD)
  await s.goto(BASE + convPath)
  await connected(s)
  await s.waitForSelector("#conversation-not-found", { timeout: T })
  if (await s.locator(`text=Hello from the grove ${stamp}`).count()) throw new Error("message visible par un non-membre")
  await s.context().close()
})
await step("Léa bloque le membre → il ne peut plus lui écrire", async () => {
  await lea.goto(`${BASE}/friends`)
  await connected(lea)
  const row = lea.locator("#friends-list li", { hasText: newbie.name })
  await row.getByRole("button", { name: /^block/i }).click()
  await lea.waitForSelector(`text=Blocked members`, { timeout: T })
  await p.goto(BASE + convPath)
  await connected(p)
  const locked = await p.locator("#composer-locked").count()
  if (!locked) {
    await p.fill("#composer textarea", "are you there?")
    await p.click("#send-message")
    await expectText(p, /blocked|can.t (send|message)|no longer/)
  }
})

// ─────────────────────────────────────────────────────────────── 5. déconnexion et accès protégé
console.log("5. Déconnexion → pages protégées inaccessibles")
await step("déconnexion puis /dashboard redirige vers /login", async () => {
  await p.goto(`${BASE}/settings`)
  await connected(p)
  await Promise.all([p.waitForURL((u) => !u.pathname.startsWith("/settings"), { timeout: T }), p.click("#rail-logout")])
  await p.goto(`${BASE}/dashboard`)
  await p.waitForURL(/\/login/, { timeout: T })
})

const errs = [...p.errors, ...lea.errors].filter((e) => !/favicon/i.test(e))
await step("aucune erreur JavaScript / console pendant les parcours", async () => {
  if (errs.length) throw new Error(errs.slice(0, 3).join(" | "))
})

await browser.close()
const failed = results.filter((r) => r[0] === "✗")
console.log(`\n${results.length - failed.length}/${results.length} étapes réussies`)
process.exit(failed.length ? 1 : 0)
