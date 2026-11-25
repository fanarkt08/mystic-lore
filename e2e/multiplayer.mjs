// Parcours multijoueur à deux navigateurs, sur la pile de bin/dev (après bin/reset).
// Usage : cd e2e && node multiplayer.mjs [dossier_captures]   (BASE)
import { mkdirSync } from "node:fs"
import { chromium } from "playwright-core"

const BASE = process.env.BASE || "http://localhost:4000"
const SHOTS = process.argv[2] || "shots/multiplayer"
const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
const LOBBY = "00000000-0000-4000-8000-00000000b001"
const T = 15_000
const RUNES = ["Ember", "Storm", "Mist", "Stone", "Sun", "Moon", "Star", "Eye"]
const results = []
mkdirSync(SHOTS, { recursive: true })
const browser = await chromium.launch({ executablePath: CHROME, headless: true })

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
  await page.fill('#login-form input[name="user[password]"]', "mystic-demo-pass-1")
  await Promise.all([page.waitForURL(/\/dashboard/, { timeout: T }), page.click('#login-form button[type="submit"]')])
  return page
}

const connected = (page) => page.waitForSelector("[data-phx-main].phx-connected", { timeout: T })
const text = (page, selector) => page.$eval(selector, (e) => e.innerText)
const waitText = (page, selector, re) =>
  page.waitForFunction(([s, src]) => { const e = document.querySelector(s); return e && new RegExp(src, "i").test(e.innerText) }, [selector, re.source], { timeout: T })

function parseClue(line) {
  const id = (name) => RUNES.indexOf(name)
  let m
  if ((m = line.match(/^(\w+) is in position (\d)\.$/))) return (s) => s[m[2] - 1] === id(m[1])
  if ((m = line.match(/^(\w+) is not in position (\d)\.$/))) return (s) => s[m[2] - 1] !== id(m[1])
  if ((m = line.match(/^(\w+) is part of the sequence\.$/))) return (s) => s.includes(id(m[1]))
  if ((m = line.match(/^(\w+) is not in the sequence\.$/))) return (s) => !s.includes(id(m[1]))
  if ((m = line.match(/^(\w+) comes somewhere before (\w+)\.$/)))
    return (s) => s.includes(id(m[1])) && s.includes(id(m[2])) && s.indexOf(id(m[1])) < s.indexOf(id(m[2]))
  throw new Error(`clue not understood: ${line}`)
}

function solve(clues) {
  const all = []
  const walk = (prefix) => {
    if (prefix.length === 5) return all.push(prefix)
    for (let r = 0; r < 8; r++) if (!prefix.includes(r)) walk([...prefix, r])
  }
  walk([])
  const tests = clues.map(parseClue)
  return all.filter((s) => tests.every((t) => t(s)))
}

async function compose(page, sequence) {
  for (const rune of sequence) await page.click(`#rune-${rune}`)
  await waitText(page, "#current-guess", new RegExp(sequence.map((r) => RUNES[r]).join(", ")))
  await page.click("#propose")
}

console.log(`Multiplayer — parcours réel sur ${BASE}`)
const hugo = await member("orion@mysticlore.test", 390)
const lea = await member("lyra@mysticlore.test", 1280)
let solution, first, second, link

await step("Léa voit le salon ouvert d'Hugo dans la liste et le rejoint", async () => {
  await lea.goto(`${BASE}/multiplayer`)
  await connected(lea)
  await waitText(lea, "#mp-open", /Relais du soir/)
  await lea.click(`#open-${LOBBY} a`)
  await connected(lea)
  await lea.click("#join-lobby")
  await lea.waitForSelector("#ready-toggle", { timeout: T })
  await waitText(lea, "#members", /Hugo Bernard/)
})

await step("Hugo (mobile 390 px) ouvre son salon depuis « My activities » : Léa y apparaît en temps réel", async () => {
  await hugo.goto(`${BASE}/multiplayer`)
  await connected(hugo)
  await hugo.click(`#mine-${LOBBY} a`)
  await connected(hugo)
  await waitText(hugo, "#members", /Léa Moreau/)
  await waitText(hugo, "#members", /Online/)
})

await step("les deux se déclarent prêts ; le compteur se met à jour chez l'autre (PubSub inter-nœuds)", async () => {
  await lea.click("#ready-toggle")
  await waitText(hugo, "#ready-count", /1 player ready/)
  await hugo.click("#ready-toggle")
  await waitText(lea, "#ready-count", /2 players ready/)
})

await step("Hugo lance la partie : chacun reçoit SES indices privés, différents", async () => {
  await hugo.click("#start-game")
  await lea.waitForSelector("#my-hints li", { timeout: T })
  await hugo.waitForSelector("#my-hints li", { timeout: T })
  const mine = await lea.$$eval("#my-hints li", (l) => l.map((e) => e.innerText.trim()))
  const his = await hugo.$$eval("#my-hints li", (l) => l.map((e) => e.innerText.trim()))
  if (!mine.length || !his.length) throw new Error("missing clues")
  if (mine.some((c) => his.includes(c))) throw new Error("clues shared between players")
  const alone = [solve(mine).length, solve(his).length]
  solution = solve([...mine, ...his])
  console.log(`      Léa: ${mine.join(" | ")}\n      Hugo: ${his.join(" | ")}\n      seuls : ${alone.join(" / ")} candidates ; ensemble : ${solution.length}`)
  if (solution.length !== 1) throw new Error(`expected a unique solution, got ${solution.length}`)
  solution = solution[0]
})

await step("ils partagent leurs indices dans le chat (temps réel, filtré côté serveur)", async () => {
  for (const [page, other, who] of [[lea, hugo, "Léa"], [hugo, lea, "Hugo"]]) {
    const clues = await page.$$eval("#my-hints li", (l) => l.map((e) => e.innerText.trim()).join(" "))
    await page.fill("#chat-form input[name='chat[body]']", `${who}'s clues: ${clues}`.slice(0, 500))
    await page.click("#chat-send")
    await waitText(other, "#chat-log", new RegExp(`${who}'s clues`))
  }
})

await step("tour par tour : tentative inexacte notée par le serveur, puis la bonne → victoire chez les deux", async () => {
  const lyraFirst = /It's your turn/.test(await text(lea, "#game-status"))
  ;[first, second] = lyraFirst ? [lea, hugo] : [hugo, lea]
  await compose(first, [...solution.slice(1), solution[0]])
  await second.waitForSelector("#attempt-1", { timeout: T })
  await waitText(second, "#attempt-1", /0 in the right place, 5 in the wrong place/)
  await waitText(second, "#game-status", /It's your turn/)
  await waitText(second, "#mp-announce", /It's your turn/)
  await compose(second, solution)
  await first.waitForSelector("#game-won", { timeout: T })
  await second.waitForSelector("#game-won", { timeout: T })
  await waitText(first, "#attempt-2", /5 in the right place/)
})

await step("récompense : « +50 XP added to your progress » chez les deux (livrée par learning)", async () => {
  await waitText(lea, "#my-reward", /\+50 XP added to your progress/)
  await waitText(hugo, "#my-reward", /\+50 XP added to your progress/)
})

await step("lien d'invitation créé puis révoqué → page claire, sans rien révéler du salon", async () => {
  await hugo.click("#create-link")
  await hugo.waitForSelector("#new-link-url", { timeout: T })
  link = await hugo.$eval("#new-link-url", (e) => e.value)
  await hugo.click("#links [id^=revoke-]")
  await hugo.waitForSelector("#new-link", { state: "detached", timeout: T })
  await lea.goto(link)
  await connected(lea)
  await waitText(lea, "#link-invalid", /was revoked/)
  if (/Relais du soir/.test(await lea.innerText("main"))) throw new Error("lobby title leaked")
})

await step("aucune erreur JS ni réponse 5xx pendant le parcours", async () => {
  const errors = [...lea.errors, ...hugo.errors]
  if (errors.length) throw new Error(errors.slice(0, 3).join(" ; "))
})

// Contrôle responsive (défilement horizontal, contrôles < 44 px) des 3 pages, aux 4 largeurs.
const problems = []
for (const width of [390, 768, 1024, 1440]) {
  for (const [who, path] of [["hugo", "/multiplayer"], ["hugo", `/multiplayer/lobbies/${LOBBY}`], ["lea", `/multiplayer/lobbies/${LOBBY}`], ["lea", new URL(link).pathname]]) {
    const page = who === "hugo" ? hugo : lea
    await page.setViewportSize({ width, height: 900 })
    await page.goto(BASE + path, { waitUntil: "networkidle" })
    await connected(page)
    const info = await page.evaluate(() => {
      const de = document.documentElement
      const visible = (e) => { const r = e.getBoundingClientRect(); const s = getComputedStyle(e); return r.width > 0 && r.height > 0 && s.visibility !== "hidden" && !e.closest("[hidden]") }
      const wide = [...document.querySelectorAll("body *")].filter((e) => visible(e) && e.getBoundingClientRect().right > de.clientWidth + 1 && getComputedStyle(e).position !== "fixed").slice(0, 3).map((e) => `${e.tagName}#${e.id}.${String(e.className).slice(0, 40)}`)
      const small = [...document.querySelectorAll("button, a.btn, input:not([type=hidden]):not([type=checkbox]):not([type=radio]), select, textarea")].filter((e) => visible(e) && e.getBoundingClientRect().height < 44).slice(0, 3).map((e) => `${e.tagName}#${e.id} h=${Math.round(e.getBoundingClientRect().height)}`)
      return { overflow: de.scrollWidth > de.clientWidth + 1, wide, small }
    })
    const tag = `${who} ${width}px ${path.slice(0, 40)}`
    if (info.overflow) problems.push(`${tag}: horizontal scroll (${info.wide.join(" | ")})`)
    if (info.small.length) problems.push(`${tag}: controls < 44px (${info.small.join(" | ")})`)
    if (width === 390 || width === 1440) await page.screenshot({ path: `${SHOTS}/${who}_${width}_${path.split("/")[2] || "index"}.png`, fullPage: true })
  }
}
console.log("  responsive : " + (problems.length ? problems.join("\n    ") : "0 défilement horizontal, 0 contrôle < 44 px (4 largeurs × 4 vues)"))
if (problems.length) results.push(false)

await browser.close()
const ok = results.filter(Boolean).length
console.log(`\n${ok}/${results.length} étapes OK`)
process.exit(ok === results.length ? 0 : 1)
