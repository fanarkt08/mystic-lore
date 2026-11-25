// Parcours du studio dans Chrome, sur la pile de bin/dev. Usage : cd e2e && node studio.mjs
import { chromium } from "playwright-core"

const BASE = process.env.BASE || "http://localhost:4000"
const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
const PASS = "mystic-demo-pass-1"
const T = 20_000
const stamp = Date.now().toString(36)
const TITLE = `Night Garden Loops ${stamp}`
const results = []
const browser = await chromium.launch({ executablePath: CHROME, headless: true })

async function step(name, fn) {
  const t0 = Date.now()
  try { await fn(); results.push(["✓", name]); console.log(`  ✓ ${name} (${Date.now() - t0} ms)`) }
  catch (e) { results.push(["✗", name]); console.log(`  ✗ ${name}\n      ${String(e.message || e).split("\n").slice(0, 4).join("\n      ")}`) }
}

async function newPage(width = 1280) {
  const ctx = await browser.newContext({ viewport: { width, height: 900 }, locale: "en-US" })
  const page = await ctx.newPage()
  page.on("dialog", (d) => d.accept())
  page.errors = []
  page.on("pageerror", (e) => page.errors.push(String(e)))
  page.on("console", (m) => m.type() === "error" && !/Failed to load resource/.test(m.text()) && page.errors.push(m.text()))
  page.on("response", (r) => r.status() >= 500 && page.errors.push(`HTTP ${r.status()} ${r.url()}`))
  return page
}

const connected = (page) => page.waitForSelector("[data-phx-main].phx-connected", { timeout: T })
const text = (page, sel) => page.locator(sel).first().innerText({ timeout: T })
async function expectText(page, sel, re) {
  await page.waitForFunction(([s, src]) => { const el = document.querySelector(s); return el && new RegExp(src, "i").test(el.innerText) }, [sel, re.source], { timeout: T })
}

async function login(page, email) {
  await page.goto(`${BASE}/login`)
  await page.fill('#login-form input[name="user[email]"]', email)
  await page.fill('#login-form input[name="user[password]"]', PASS)
  await Promise.all([page.waitForLoadState("load"), page.click('#login-form button[type="submit"]')])
}

let projectUrl, balanceBefore
console.log(`Studio journey — ${BASE} — project « ${TITLE} »`)
const lea = await newPage()

await step("lea logs in and sees her seeded project and shared work in /studio", async () => {
  await login(lea, "lyra@mysticlore.test")
  await lea.goto(`${BASE}/studio`); await connected(lea)
  await expectText(lea, "#owned-projects", /Le Jardin au clair de lune/)
})

await step("AI credits before: balance shown on /studio/credits", async () => {
  await lea.goto(`${BASE}/studio/credits`); await connected(lea)
  balanceBefore = parseInt(await text(lea, "#credit-balance"), 10)
  if (!(balanceBefore > 0)) throw new Error(`balance ${balanceBefore}`)
  console.log(`      balance before: ${balanceBefore}`)
})

await step("creates a project from its brief (/studio/new)", async () => {
  await lea.goto(`${BASE}/studio/new`); await connected(lea)
  await lea.fill('#new-project-form input[name="brief[title]"]', TITLE)
  await lea.fill('#new-project-form textarea[name="brief[objectives]"]', "Explain what a loop repeats\nWater every plant with one loop")
  await lea.fill('#new-project-form input[name="brief[audience]"]', "Curious beginners, ages 10+")
  await lea.selectOption('#new-project-form select[name="brief[category]"]', "coding")
  await lea.fill('#new-project-form textarea[name="brief[summary]"]', "A moonlit garden where loops water every plant.")
  await Promise.all([lea.waitForURL(/\/studio\/[0-9a-f-]{36}\?step=outline/, { timeout: T }), lea.click("#create-project")])
  projectUrl = lea.url().split("?")[0]
  await connected(lea)
})

await step("outline by the DEMO provider: cost confirmed first, status in real time, applied", async () => {
  await expectText(lea, "#demo-mode", /DEMO MODE — not a real AI/)
  await lea.click("#ai-outline")
  await expectText(lea, "#confirm-cost", /This uses 2 credits/)
  await lea.click("#confirm-generate")
  // pending → running → succeeded pushed by the studio node over the cluster PubSub
  await lea.waitForSelector('[id^="apply-"]', { timeout: T })
  await lea.click('[id^="apply-"]')
  // module titles are editable inputs (autosave)
  await lea.waitForFunction(() => [...document.querySelectorAll('#modules input[name="title"]')].some((i) => /^Demo module 1/.test(i.value)), null, { timeout: T })
})

await step("the debit is visible: balance −2, ledger shows the outline", async () => {
  await lea.goto(`${BASE}/studio/credits`); await connected(lea)
  const after = parseInt(await text(lea, "#credit-balance"), 10)
  if (after !== balanceBefore - 2) throw new Error(`balance ${after}, expected ${balanceBefore - 2}`)
  await expectText(lea, "#credit-ledger", /Used[\s\S]*Outline/)
  await expectText(lea, "#generation-history", new RegExp(TITLE))
})

await step("keyboard reordering of modules (Move down keeps the focus)", async () => {
  await lea.goto(`${projectUrl}?step=outline`); await connected(lea)
  const first = await lea.locator("#modules > li").first().getAttribute("id")
  await lea.focus(`#${first}-down`); await lea.keyboard.press("Enter")
  await lea.waitForFunction((id) => document.querySelector("#modules > li:nth-child(2)")?.id === id, first, { timeout: T })
  await lea.waitForFunction((id) => document.activeElement?.id === `${id}-up`, first, { timeout: T })
  await expectText(lea, "#studio-announce", /moved to position 2 of 2/)
})

await step("lesson drafts by the DEMO provider for every quiz and puzzle (5 credits each)", async () => {
  await lea.goto(`${projectUrl}?step=build`); await connected(lea)
  const tabs = await lea.locator(".studio-lesson-tab").evaluateAll((els) => els.map((e) => [e.getAttribute("href"), e.innerText]))
  for (const [href, title] of tabs.filter(([, t]) => /^(Quiz|Practice):/.test(t))) {
    await lea.goto(`${BASE}${href}`); await connected(lea)
    await lea.click("#ai-draft")
    await expectText(lea, "#confirm-cost", /This uses 5 credits/)
    await lea.click("#confirm-generate")
    await lea.waitForSelector('[id^="apply-"]', { timeout: T })
    await lea.click('[id^="apply-"]')
    await lea.waitForSelector('[id^="apply-"]', { state: "detached", timeout: T })
  }
})

await step("review: all automatic checks pass, declarations confirmed, learner preview", async () => {
  await lea.goto(`${projectUrl}?step=review`); await connected(lea)
  await lea.waitForSelector("#checks", { timeout: T })
  const failing = await lea.locator("#checks .text-danger").count()
  if (failing > 0) throw new Error(await text(lea, "#checks"))
  for (const k of ["accuracy", "safety", "accessibility"]) { await lea.check(`#attest-${k}`); await lea.waitForTimeout(300) }
  await expectText(lea, "#attestations-state", /confirmed for the current content/)
  await expectText(lea, "#learner-preview", /Chapter 1/)
})

await step("submit for review → locked", async () => {
  await lea.goto(`${projectUrl}?step=publish`); await connected(lea)
  await lea.click("#submit-project")
  await expectText(lea, "#project-status", /In review/)
  await expectText(lea, "#locked-notice", /Locked during the review/)
})

const theo = await newPage()
await step("theo_garnier (moderator) approves from the queue → import into learning → published", async () => {
  await login(theo, "theo@mysticlore.test")
  await theo.goto(`${BASE}/studio/review`); await connected(theo)
  await theo.click(`#review-queue a:has-text("${TITLE}")`)
  await connected(theo)
  await expectText(theo, "#snapshot", /Correct answer/)
  await theo.click("#approve")
  await expectText(theo, "#review-status", /Approved|Published/)
  await expectText(theo, "#review-status", /Published/)
})

let slug
await step("lea sees « Live in the academy » and opens the published adventure", async () => {
  await lea.goto(`${projectUrl}?step=publish`); await connected(lea)
  await expectText(lea, "#published", /Live in the academy/)
  slug = (await lea.locator("#published a").getAttribute("href")).split("/").pop()
  await Promise.all([lea.waitForURL(/\/adventures\//, { timeout: T }), lea.click("#published a")])
  await connected(lea)
  await lea.waitForFunction((t) => document.querySelector("h1")?.innerText.includes(t), TITLE, { timeout: T })
  console.log(`      published as /adventures/${slug}`)
})

await step("membership shows the AI credits of the month", async () => {
  await lea.goto(`${BASE}/membership`); await connected(lea)
  await expectText(lea, "#ai-credits", /credits left this month/)
})

await step("responsive: project editor on a phone (390 px) without horizontal overflow", async () => {
  const phone = await newPage(390)
  await login(phone, "lyra@mysticlore.test")
  for (const s of ["brief", "outline", "build", "review", "publish"]) {
    await phone.goto(`${projectUrl}?step=${s}`); await connected(phone)
    const overflow = await phone.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)
    if (overflow > 1) throw new Error(`step ${s}: ${overflow}px overflow`)
  }
  await phone.screenshot({ path: process.env.SHOT || "studio_phone.png", fullPage: true })
})

for (const p of [lea, theo]) if (p.errors.length) console.log("  page errors:", p.errors.slice(0, 5))
await browser.close()
const failed = results.filter(([s]) => s === "✗").length
console.log(`\n${results.length - failed}/${results.length} OK`)
process.exit(failed ? 1 : 0)
