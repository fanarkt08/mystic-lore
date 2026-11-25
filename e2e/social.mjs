// Parcours de la messagerie avec trois navigateurs : groupes, pièces jointes, accusés de lecture et sourdine.
// Usage : cd e2e && node social.mjs   (BASE, CHROME, HEADED=1) ; bin/reset avant.
import { deflateSync } from "node:zlib"
import { chromium } from "playwright-core"

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
    results.push(true)
    console.log(`  ✓ ${name} (${Date.now() - t0} ms)`)
  } catch (e) {
    results.push(false)
    console.log(`  ✗ ${name}\n      ${String(e.message || e).split("\n").slice(0, 4).join("\n      ")}`)
  }
}

async function member(email, width) {
  const ctx = await browser.newContext({ viewport: { width, height: 900 }, locale: "en-US" })
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

// Session d'un membre sans navigateur (formulaire de connexion réel, jeton CSRF) : pour un téléchargement direct.
async function cookieLogin(email) {
  const form = await fetch(`${BASE}/login`)
  const cookie = form.headers.getSetCookie().map((c) => c.split(";")[0]).join("; ")
  const csrf = (await form.text()).match(/name="_csrf_token"[^>]* value="([^"]+)"/)[1]
  const body = new URLSearchParams({ _csrf_token: csrf, "user[email]": email, "user[password]": PASSWORD })
  const r = await fetch(`${BASE}/login`, { method: "POST", body, headers: { cookie }, redirect: "manual" })
  if (r.status !== 302) throw new Error(`login ${email}: HTTP ${r.status}`)
  return r.headers.getSetCookie().map((c) => c.split(";")[0]).join("; ")
}

const connected = (page) => page.waitForSelector("[data-phx-main].phx-connected", { timeout: T })
const visit = async (page, path) => { await page.goto(BASE + path); await connected(page) }
const waitText = (page, selector, re, timeout = T) =>
  page.waitForFunction(([s, src]) => { const e = document.querySelector(s); return e && new RegExp(src, "i").test(e.innerText) }, [selector, re.source], { timeout })
const pause = (ms) => new Promise((r) => setTimeout(r, ms))

async function say(page, text) {
  await page.fill("#composer textarea", text)
  await page.click("#send-message")
  await page.waitForSelector(`#messages li:has-text("${text}")`, { timeout: T })
}

async function attach(page, name, mimeType, buffer) {
  await page.setInputFiles("#composer input[type=file]", { name, mimeType, buffer })
  // progression : l'envoi au serveur web est terminé quand la barre est pleine
  await page.waitForSelector('#composer [role=progressbar][aria-valuenow="100"]', { timeout: T })
}

async function privacy(page, { online, receipts, requests, invites }) {
  await visit(page, "/settings/privacy")
  if (online !== undefined || receipts !== undefined) {
    if (online !== undefined) await page.setChecked("#privacy-show-online", online)
    if (receipts !== undefined) await page.setChecked("#privacy-read-receipts", receipts)
    await page.click("#save-presence")
    await waitText(page, "#presence-status", /Visibility saved/)
  }
  if (requests || invites) {
    if (requests) await page.check(`#privacy-friend-requests-${requests}`)
    if (invites) await page.check(`#privacy-lobby-invites-${invites}`)
    await page.click("#save-contacts")
    await waitText(page, "#contacts-status", /Contact permissions saved/)
  }
}

// PNG réel construit ici (IDAT zlib), avec un chunk texte « secret » que social doit retirer.
const crcTable = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0 })
const crc32 = (buf) => { let c = 0xffffffff; for (const b of buf) c = crcTable[(c ^ b) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0 }
function chunk(type, data) {
  const head = Buffer.alloc(4); head.writeUInt32BE(data.length)
  const body = Buffer.concat([Buffer.from(type, "latin1"), data])
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body))
  return Buffer.concat([head, body, crc])
}
function png(w, h) {
  const row = w * 3 + 1
  const raw = Buffer.alloc(row * h)
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) raw.set([20 + (y % 200), 40 + (x % 180), 140], y * row + 1 + x * 3)
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr.set([8, 2, 0, 0, 0], 8)
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk("IHDR", ihdr),
    chunk("tEXt", Buffer.from("Comment\0GPS-SECRET-48.85N", "latin1")), chunk("IDAT", deflateSync(raw)), chunk("IEND", Buffer.alloc(0))])
}
const PDF = Buffer.from("%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n2 0 obj << /Type /Pages /Kids [] /Count 0 >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n")

// défilement horizontal et contrôles < 44 px (même mesure que responsive.mjs)
const layout = (page) => page.evaluate(() => {
  const de = document.documentElement
  const visible = (e) => { const r = e.getBoundingClientRect(); const s = getComputedStyle(e); return r.width > 0 && r.height > 0 && s.visibility !== "hidden" && !e.closest("[hidden]") }
  const small = [...document.querySelectorAll("button, a.btn, input:not([type=hidden]):not([type=checkbox]):not([type=radio]), select, textarea")]
    .filter((e) => visible(e) && e.getBoundingClientRect().height < 44).slice(0, 3).map((e) => `${e.tagName}#${e.id} h=${Math.round(e.getBoundingClientRect().height)}`)
  return { overflow: de.scrollWidth - de.clientWidth, small }
})

const stamp = Date.now().toString(36)
const name = `Night owls ${stamp}`
console.log(`Social — groupes, pièces jointes, accusés, sourdine, présence, permissions — ${BASE}`)
const lea = await member("lyra@mysticlore.test", 1280)
const hugo = await member("orion@mysticlore.test", 1024)
const ines = await member("mika@mysticlore.test", 390)
let groupPath, imageUrl

console.log("1. Groupe en temps réel")
await step("Léa crée un groupe en choisissant parmi ses amis (Hugo, Inès)", async () => {
  await visit(lea, "/messages/new")
  await lea.fill("#new-group-form input[name='group[name]']", name)
  for (const friend of ["Hugo Bernard", "Inès Petit"]) await lea.check(`#new-group-form label:has-text("${friend}") input`)
  await Promise.all([lea.waitForURL(/\/messages\/[0-9a-f-]{36}$/, { timeout: T }), lea.click("#create-group")])
  groupPath = new URL(lea.url()).pathname
  await waitText(lea, "#thread-title", new RegExp(name))
  await waitText(lea, "#messages", /created the group/)
})
await step("les messages arrivent en direct chez les autres membres (livraison par membre)", async () => {
  await visit(hugo, groupPath)
  await visit(ines, groupPath)
  await say(lea, `Hello night owls ${stamp}`)
  await hugo.waitForSelector(`#messages li:has-text("Hello night owls ${stamp}")`, { timeout: T })
  await ines.waitForSelector(`#messages li:has-text("Hello night owls ${stamp}")`, { timeout: T })
  await say(hugo, `Hugo is here ${stamp}`)
  await lea.waitForSelector(`#messages li:has-text("Hugo is here ${stamp}") .bubble-sender:has-text("Hugo Bernard")`, { timeout: T })
  await ines.waitForSelector(`#messages li:has-text("Hugo is here ${stamp}")`, { timeout: T })
})
await step("renommage par la propriétaire : nouveau nom et message système en direct chez les autres", async () => {
  await lea.click("#toggle-details")
  await lea.fill("#rename-form input[name='group[name]']", `Early birds ${stamp}`)
  await lea.click("#rename-submit")
  await waitText(hugo, "#thread-title", new RegExp(`Early birds ${stamp}`))
  await waitText(ines, "#messages", new RegExp(`Léa Moreau renamed the group “Early birds ${stamp}”`))
  await lea.click("#toggle-details")
})

console.log("2. Pièces jointes")
await step("image avec texte alternatif : progression, aperçu chez Hugo, métadonnées retirées", async () => {
  await attach(lea, "sky.png", "image/png", png(160, 90))
  await lea.fill("#attachment-alt", "A test sky over the grove")
  await lea.fill("#composer textarea", `Our sky ${stamp}`)
  await lea.click("#send-message")
  await lea.waitForSelector('.attachment img[alt="A test sky over the grove"]', { timeout: T })
  await hugo.waitForFunction(() => { const i = document.querySelector('.attachment img[alt="A test sky over the grove"]'); return i && i.complete && i.naturalWidth === 160 }, null, { timeout: T })
  imageUrl = BASE + (await hugo.getAttribute('.attachment img[alt="A test sky over the grove"]', "src"))
  const res = await hugo.context().request.get(imageUrl)
  if (res.status() !== 200) throw new Error(`member: HTTP ${res.status()}`)
  const bytes = await res.body()
  if (bytes.includes("GPS-SECRET")) throw new Error("metadata still present")
  if (res.headers()["content-type"] !== "image/png") throw new Error(res.headers()["content-type"])
})
await step("non-membre (Sarah) : la même image répond 404", async () => {
  const cookie = await cookieLogin("samira@mysticlore.test")
  const r = await fetch(imageUrl, { headers: { cookie } })
  if (r.status !== 404) throw new Error(`HTTP ${r.status}`)
  const anonymous = await fetch(imageUrl)
  if (anonymous.status !== 404) throw new Error(`anonymous: HTTP ${anonymous.status}`)
})
await step("PDF : toujours en téléchargement (attachment), no-store, nosniff, CSP sandbox", async () => {
  await attach(lea, "star-guide.pdf", "application/pdf", PDF)
  await lea.click("#send-message")
  await hugo.waitForSelector('.attachment-file[download="star-guide.pdf"]', { timeout: T })
  const href = await hugo.getAttribute('.attachment-file[download="star-guide.pdf"]', "href")
  const h = (await hugo.context().request.get(BASE + href)).headers()
  const expected = { "content-type": "application/pdf", "content-disposition": "attachment", "cache-control": "private, no-store", "x-content-type-options": "nosniff" }
  for (const [k, v] of Object.entries(expected)) if (h[k] !== v) throw new Error(`${k}: ${h[k]}`)
  if (!/sandbox/.test(h["content-security-policy"])) throw new Error(`csp: ${h["content-security-policy"]}`)
})
await step("sans antivirus configuré : « Not scanned by an antivirus » sous chaque pièce jointe", async () => {
  await waitText(hugo, ".attachment-scan", /Not scanned by an antivirus/)
  const n = await ines.locator(".attachment-scan:has-text('Not scanned by an antivirus')").count()
  if (n < 2) throw new Error(`${n} mention(s) chez Inès`)
})

console.log("3. Accusés de lecture, débit, retrait")
await step("accusé « Seen by 1: Hugo Bernard » en direct (Inès a coupé les siens : jamais comptée)", async () => {
  await say(lea, `Did you read this ${stamp}?`)
  await waitText(lea, "#read-receipt", /Seen by 1: Hugo Bernard/)
  if (/Mika/.test(await lea.innerText("#read-receipt"))) throw new Error("Inès counted")
})
await step("limite de débit : Inès envoie trop vite → 429 affiché, envoi suspendu", async () => {
  // fenêtres fixes de 10 s : 41 envois rapides en remplissent forcément une au-delà de 20
  for (let i = 1; i <= 41; i++) {
    const text = `burst ${i} ${stamp}`
    await ines.fill("#composer textarea", text)
    await ines.click("#send-message")
    await ines.waitForFunction((t) => document.querySelector("#composer-throttled") ||
      [...document.querySelectorAll("#messages li")].some((li) => li.innerText.includes(t)), text, { timeout: T })
    if (await ines.locator("#composer-throttled").count()) break
  }
  await waitText(ines, "#composer-throttled", /too quickly.*\d+ second/)
  if (!(await ines.isDisabled("#send-message"))) throw new Error("send button still enabled")
})
await step("membre retiré : sa page ouverte ne reçoit plus rien, l'API lui répond 404", async () => {
  await lea.click("#toggle-details")
  await lea.click('#group-members li:has-text("Inès Petit") button:has-text("Remove")')
  await ines.waitForSelector("#conversation-not-found", { timeout: T })
  await lea.click("#toggle-details")
  await say(lea, `After removal ${stamp}`)
  await hugo.waitForSelector(`#messages li:has-text("After removal ${stamp}")`, { timeout: T })
  await pause(1500)
  if ((await ines.content()).includes(`After removal ${stamp}`)) throw new Error("removed member received it")
  await visit(ines, groupPath)
  await ines.waitForSelector("#conversation-not-found", { timeout: T })
  const r = await ines.context().request.get(imageUrl)
  if (r.status() !== 404) throw new Error(`attachment: HTTP ${r.status()}`)
})
await step("accusés de lecture qui disparaissent quand Hugo coupe le réglage", async () => {
  await say(lea, `Still with us ${stamp}?`)
  await waitText(lea, "#read-receipt", /Seen by 1: Hugo Bernard/)
  await privacy(hugo, { receipts: false })
  await lea.waitForSelector("#read-receipt", { state: "detached", timeout: T })
})

console.log("4. Présence et sourdine")
await step("point « en ligne » d'Hugo chez Léa (pas pour Inès, qui le cache) ; il disparaît quand Hugo le coupe", async () => {
  await visit(lea, "/friends")
  await lea.waitForSelector('#friends-list li:has-text("Hugo Bernard") .presence-dot', { timeout: T })
  if (await lea.locator('#friends-list li:has-text("Inès Petit") .presence-dot').count()) throw new Error("Inès shown online")
  await privacy(hugo, { online: false })
  await lea.waitForSelector('#friends-list li:has-text("Hugo Bernard") .presence-dot', { state: "detached", timeout: T })
})
await step("sourdine : le groupe garde son compteur, mais sort du badge global", async () => {
  await visit(hugo, "/messages")
  await visit(lea, groupPath)
  await say(lea, `Ping one ${stamp}`)
  // le badge de la navigation (rendu deux fois selon la largeur : présent dans le DOM)
  await hugo.waitForSelector("#nav-messages .count-badge", { state: "attached", timeout: T })
  await visit(hugo, groupPath)
  await hugo.click("#toggle-details")
  await hugo.selectOption("#mute-duration", "always")
  await hugo.click("#mute-submit")
  await waitText(hugo, "#mute-status", /Muted until you turn it back on/)
  await visit(hugo, "/messages")
  if (await hugo.locator("#nav-messages .count-badge").count()) throw new Error("badge before the new message")
  await say(lea, `Ping two ${stamp}`)
  await hugo.waitForSelector(`#conversations li:has-text("Early birds ${stamp}") .count-badge-muted`, { timeout: T })
  await pause(1000)
  if (await hugo.locator("#nav-messages .count-badge").count()) throw new Error("muted group counted in the badge")
})

console.log("5. Permissions de contact (décidées par social)")
await step("demande d'ami refusée par la permission « personne » (403 de social, message clair)", async () => {
  await privacy(hugo, { requests: "nobody", invites: "nobody" })
  await visit(ines, "/friends")
  await ines.fill("#search-q", "hugo")
  await ines.locator('#search-results li:has-text("Hugo Bernard")').getByRole("button", { name: /add friend/i }).click()
  await waitText(ines, "body", /doesn.t accept friend requests from you/)
})
await step("invitation dans un salon refusée de même (multiplayer demande à social)", async () => {
  await visit(lea, "/multiplayer")
  await lea.fill("#create-lobby input[name='lobby[title]']", `Owls relay ${stamp}`)
  await Promise.all([lea.waitForURL(/\/multiplayer\/lobbies\//, { timeout: T }), lea.click("#create-submit")])
  await connected(lea)
  await lea.click('#invite-friends li:has-text("Hugo Bernard") button')
  await waitText(lea, "body", /doesn.t accept activity invitations/)
  await Promise.all([lea.waitForURL(/\/multiplayer$/, { timeout: T }), lea.click("#leave-lobby")])
})

console.log("6. Mise en page")
await step("groupe à 390 px (Hugo), panneau ouvert compris : 0 défilement horizontal, 0 contrôle < 44 px", async () => {
  await hugo.setViewportSize({ width: 390, height: 844 })
  await visit(hugo, groupPath)
  const closed = await layout(hugo)
  await hugo.click("#toggle-details")
  await hugo.waitForSelector("#details-panel", { timeout: T })
  const open = await layout(hugo)
  for (const info of [closed, open]) {
    if (info.overflow > 0) throw new Error(`horizontal scroll ${info.overflow}px`)
    if (info.small.length) throw new Error(`small controls: ${info.small.join(" | ")}`)
  }
})

// remet Hugo dans l'état des seeds (permet de relancer le parcours)
await privacy(hugo, { online: true, receipts: true, requests: "everyone", invites: "friends" })
await step("aucune erreur JS ni réponse 5xx pendant le parcours", async () => {
  const errors = [...lea.errors, ...hugo.errors, ...ines.errors]
  if (errors.length) throw new Error(errors.slice(0, 3).join(" ; "))
})

await browser.close()
const ok = results.filter(Boolean).length
console.log(`\n${ok}/${results.length} étapes OK`)
process.exit(ok === results.length ? 0 : 1)
