// Parcours administration et modération dans Chrome, sur la pile de bin/dev avec les comptes de démo.
// Usage : cd e2e && node admin.mjs   (BASE, CHROME, DEMO_PASSWORD, HEADED=1)
import { chromium } from "playwright-core"
import { readFile } from "node:fs/promises"

const BASE = process.env.BASE || "http://localhost:4000"
const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
const PASSWORD = process.env.DEMO_PASSWORD || "mystic-demo-pass-1"
const T = 15_000

const results = []
const browser = await chromium.launch({ executablePath: CHROME, headless: !process.env.HEADED })

async function step(name, fn) {
  const t0 = Date.now()
  try {
    await fn()
    results.push(["✓", name])
    console.log(`  ✓ ${name} (${Date.now() - t0} ms)`)
  } catch (e) {
    results.push(["✗", name])
    console.log(`  ✗ ${name}\n      ${String(e.message || e).split("\n").slice(0, 4).join("\n      ")}`)
  }
}

async function session(email, width = 1280) {
  const ctx = await browser.newContext({ viewport: { width, height: 900 }, locale: "en-US", acceptDownloads: true })
  const page = await ctx.newPage()
  page.on("dialog", (d) => d.accept())
  page.errors = []
  page.on("pageerror", (e) => page.errors.push(String(e)))
  page.on("response", (r) => r.status() >= 500 && page.errors.push(`HTTP ${r.status()} ${r.url()}`))
  await page.goto(`${BASE}/login`)
  await page.fill('#login-form input[name="user[email]"]', email)
  await page.fill('#login-form input[name="user[password]"]', PASSWORD)
  await Promise.all([page.waitForURL(/\/dashboard/, { timeout: T }), page.click('#login-form button[type="submit"]')])
  return page
}

const connected = (page) => page.waitForSelector("[data-phx-main].phx-connected", { timeout: T })
const text = (page, re, timeout = T) =>
  page.waitForFunction((src) => new RegExp(src, "i").test(document.body.innerText), re.source, { timeout })

async function openConversation(page, name) {
  await page.goto(`${BASE}/messages`)
  await connected(page)
  await Promise.all([page.waitForURL(/\/messages\/[0-9a-f-]{36}/, { timeout: T }), page.click(`#conversations a:has-text("${name}")`)])
  await connected(page)
}

const stamp = Date.now().toString(36)
const insult = `You are a useless wizard (${stamp})`
let messageId, sanctionId
console.log(`MysticLore — administration & modération — ${BASE}`)

const hugo = await session("orion@mysticlore.test")
const lea = await session("lyra@mysticlore.test")

console.log("1. Un membre signale un message privé")
await step("hugo envoie un message à lea", async () => {
  await openConversation(hugo, "Léa Moreau")
  await hugo.fill("#composer textarea", insult)
  await hugo.click("#send-message")
  const bubble = hugo.locator(`#messages li.bubble-mine:has-text("${stamp}")`)
  await bubble.waitFor({ timeout: T })
  messageId = (await bubble.getAttribute("id")).replace("message-", "")
})
await step("lea signale ce message (instantané gardé par social)", async () => {
  await openConversation(lea, "Hugo Bernard")
  await lea.waitForSelector(`#message-${messageId}`, { timeout: T })
  await lea.click(`#report-${messageId}`)
  await lea.selectOption('#report-form select[name="report[reason]"]', "harassment")
  await lea.fill('#report-form textarea[name="report[details]"]', "Insulting me")
  await lea.click('#report-form button[type="submit"]')
  await text(lea, /Report sent/)
})

console.log("2. theo (moderator) traite le signalement")
const theo = await session("theo@mysticlore.test")
await step("l'entrée « Administration » est visible pour le staff", async () => {
  await theo.waitForSelector("#nav-admin", { timeout: T })
})
await step("file unifiée : le signalement apparaît sans le texte du message", async () => {
  await theo.goto(`${BASE}/admin/reports`)
  await connected(theo)
  await theo.waitForSelector("#reports", { timeout: T })
  if ((await theo.content()).includes(stamp)) throw new Error("le texte du message est visible dans la file")
})
await step("dossier : preuve refusée sans motif suffisant, montrée après un motif (audité)", async () => {
  const rows = theo.locator('#reports tbody tr:has-text("Private message"):has-text("Hugo")')
  await Promise.all([theo.waitForURL(/\/admin\/reports\/social\//, { timeout: T }), rows.last().locator("a").click()])
  await connected(theo)
  await theo.fill("#evidence-form textarea", "check")
  await theo.click("#view-evidence")
  await text(theo, /at least 10 characters/)
  if (await theo.locator("#evidence").count()) throw new Error("preuve affichée sans motif")
  await theo.fill("#evidence-form textarea", "Harassment report from Léa: checking the insult")
  await theo.click("#view-evidence")
  await theo.waitForSelector(`#evidence:has-text("${stamp}")`, { timeout: T })
})
await step("retrait du message (motif) → « removed by moderation » chez les participants, en direct", async () => {
  await theo.selectOption("#resolve-action", "remove_message")
  await theo.fill('#resolve-form textarea[name="resolve[reason]"]', "Insulting another member")
  await Promise.all([theo.waitForURL(/\/admin\/reports$/, { timeout: T }), theo.click("#resolve")])
  await lea.waitForSelector(`#message-${messageId}:has-text("Message removed by moderation")`, { timeout: T })
  await hugo.waitForSelector(`#message-${messageId}:has-text("Message removed by moderation")`, { timeout: T })
  if ((await lea.locator(`#message-${messageId}`).innerText()).includes(stamp)) throw new Error("texte encore affiché")
})

console.log("3. theo restreint hugo ; l'envoi est refusé ; hugo fait appel")
await step("restriction temporaire (1 h, motif)", async () => {
  await theo.goto(`${BASE}/admin/members?q=hugo`)
  await connected(theo)
  await Promise.all([theo.waitForURL(/\/admin\/members\/[0-9a-f-]{36}/, { timeout: T }), theo.click('#members a:has-text("Hugo Bernard")')])
  await connected(theo)
  // e-mail masqué pour un modérateur
  await text(theo, /o•••@mysticlore\.test/)
  await theo.selectOption("#sanction-kind", "restriction")
  await theo.waitForSelector("#sanction-duration", { timeout: T })
  await theo.selectOption("#sanction-duration", "1")
  await theo.fill('#sanction-form textarea[name="sanction[reason]"]', "Insulting other members in private messages")
  await theo.click("#issue-sanction")
  await text(theo, /Sanction recorded/)
  sanctionId = (await theo.locator('#member-sanctions li[id^="sanction-"]').first().getAttribute("id")).replace("sanction-", "")
})
await step("hugo : son envoi de message est refusé (restricted until…)", async () => {
  await openConversation(hugo, "Léa Moreau")
  await hugo.fill("#composer textarea", `still here? ${stamp}`)
  await hugo.click("#send-message")
  await hugo.waitForSelector('#composer-locked:has-text("restricted until")', { timeout: T })
})
await step("hugo fait un appel motivé depuis /account/sanctions", async () => {
  await hugo.goto(`${BASE}/account/sanctions`)
  await connected(hugo)
  await hugo.click(`#appeal-button-${sanctionId}`)
  await hugo.fill("#appeal-form textarea", "I was angry and I apologised to Léa; it will not happen again.")
  await hugo.click("#send-appeal")
  await text(hugo, /Appeal sent/)
  await hugo.waitForSelector(`#appeal-${sanctionId}:has-text("Appeal under review")`, { timeout: T })
})
await step("theo, auteur de la sanction, ne peut pas trancher l'appel", async () => {
  await theo.goto(`${BASE}/admin/sanctions-appeals`)
  await connected(theo)
  await theo.waitForSelector('#appeals li:has-text("Hugo Bernard") [id^="own-"]', { timeout: T })
})

console.log("4. clara (admin) accepte l'appel, change un rôle, exporte le journal")
const clara = await session("aster@mysticlore.test")
await step("clara accepte l'appel → restriction levée", async () => {
  await clara.goto(`${BASE}/admin/sanctions-appeals`)
  await connected(clara)
  const card = clara.locator('#appeals li:has-text("Hugo Bernard")').first()
  await card.locator('select[name="decision"]').selectOption("accept")
  await card.locator('textarea[name="reason"]').fill("Apology accepted, first offence")
  await card.locator('button[type="submit"]').click()
  await text(clara, /Appeal accepted/)
})
await step("hugo peut de nouveau écrire ; sa page de sanctions est à jour (temps réel)", async () => {
  await hugo.waitForSelector(`#appeal-${sanctionId}:has-text("Appeal accepted")`, { timeout: T })
  await openConversation(hugo, "Léa Moreau")
  await hugo.fill("#composer textarea", `sorry Léa ${stamp}`)
  await hugo.click("#send-message")
  await hugo.waitForSelector(`#messages li.bubble-mine:has-text("sorry Léa ${stamp}")`, { timeout: T })
})
await step("clara change le rôle de sarah (moderator) puis le rétablit (user)", async () => {
  await clara.goto(`${BASE}/admin/members?q=sarah`)
  await connected(clara)
  await text(clara, /samira@mysticlore\.test/) // e-mail complet pour un admin (consultation auditée)
  await Promise.all([clara.waitForURL(/\/admin\/members\/[0-9a-f-]{36}/, { timeout: T }), clara.click('#members a:has-text("Sarah Lefèvre")')])
  await connected(clara)
  for (const role of ["moderator", "user"]) {
    await clara.selectOption("#role-select", role)
    await clara.fill('#role-form input[name="role[reason]"]', role === "user" ? "Trial period over" : "Helping with the forum")
    await clara.click("#save-role")
    await text(clara, /Role updated/)
  }
})
await step("export CSV du journal (téléchargement), lui-même audité", async () => {
  await clara.goto(`${BASE}/admin/audit`)
  await connected(clara)
  const [download] = await Promise.all([clara.waitForEvent("download", { timeout: T }), clara.click("#export-csv")])
  const csv = await readFile(await download.path(), "utf8")
  if (!csv.startsWith("id,inserted_at,service,actor_id")) throw new Error("en-tête CSV inattendu")
  for (const action of ["social.report.evidence_viewed", "social.report.resolved", "accounts.sanction.issued", "accounts.appeal.accepted", "accounts.role.changed"])
    if (!csv.includes(action)) throw new Error(`action absente du CSV : ${action}`)
  if (csv.includes(stamp)) throw new Error("le contenu du message privé figure dans le journal")
  await clara.reload()
  await connected(clara)
  await clara.waitForSelector('#audit tbody tr:has-text("accounts.audit.exported")', { timeout: T })
})

console.log("5. Un membre normal (VIP) n'a pas accès")
await step("ines (VIP, rôle user) : /admin → 403, pas d'entrée Administration", async () => {
  const ines = await session("mika@mysticlore.test")
  if (await ines.locator("#nav-admin").count()) throw new Error("entrée Administration visible")
  const response = await ines.goto(`${BASE}/admin`)
  if (response.status() !== 403) throw new Error(`statut ${response.status()}`)
  // page 403 thématique (prod) ou page de Plug.Debugger (dev, debug_errors: true) : même statut, aucun contenu staff
  await text(ines, /don't have access|ForbiddenError/)
  if (await ines.locator("#admin-nav").count()) throw new Error("navigation d'administration rendue")
})

const errors = [hugo, lea, theo, clara].flatMap((p) => p.errors)
await step("aucune erreur JS ni réponse 5xx", async () => {
  if (errors.length) throw new Error(errors.join("\n"))
})

await browser.close()
const failed = results.filter(([s]) => s === "✗").length
console.log(`\n${results.length - failed}/${results.length} étapes réussies`)
process.exit(failed ? 1 : 0)
