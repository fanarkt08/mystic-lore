// Parcours du forum dans Chrome, sur la pile de bin/dev (après bin/reset). Usage : cd e2e && node community.mjs
import { chromium } from "playwright-core"

const BASE = process.env.BASE || "http://localhost:4000"
const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
const PASSWORD = "mystic-demo-pass-1"
const SHOTS = process.env.SHOTS_DIR
const T = 15_000
const stamp = Date.now().toString(36)
const results = []
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

async function newPage(width = 1280) {
  const ctx = await browser.newContext({ viewport: { width, height: 900 }, locale: "en-US" })
  const page = await ctx.newPage()
  page.on("dialog", (d) => d.accept())
  page.errors = []
  page.on("pageerror", (e) => page.errors.push(String(e)))
  page.on("response", (r) => r.status() >= 500 && page.errors.push(`HTTP ${r.status()} ${r.url()}`))
  return page
}

const connected = (page) => page.waitForSelector("[data-phx-main].phx-connected", { timeout: T })
const expectText = (page, re, timeout = T) =>
  page.waitForFunction((src) => new RegExp(src, "i").test(document.body.innerText), re.source, { timeout })

async function login(page, who) {
  await page.goto(`${BASE}/login`)
  // les adresses de connexion des membres de démo n'ont pas changé (lyra@, orion@…)
  const email = { lea: "lyra", hugo: "orion", ines: "mika", sarah: "samira", clara: "aster" }[who] || who
  await page.fill('#login-form input[name$="[email]"]', `${email}@mysticlore.test`)
  await page.fill('#login-form input[name$="[password]"]', PASSWORD)
  await Promise.all([page.waitForLoadState("load"), page.click('#login-form button[type="submit"]')])
  if (page.url().includes("/login")) throw new Error(`login failed for ${who}`)
}

const title = `Does the Looping Grove accept while loops? ${stamp}`
let discussionUrl, replyId

console.log(`Forum journey — ${BASE}`)
const lea = await newPage()
const hugo = await newPage()
const theo = await newPage()
const ines = await newPage(390)

await step("Léa: forum list with seeded discussions (pinned announcement first)", async () => {
  await login(lea, "lea")
  await lea.goto(`${BASE}/community`)
  await connected(lea)
  const first = await lea.locator("#discussions li").first().innerText()
  if (!/Bienvenue sur le forum de MysticLore/.test(first) || !/Pinned/i.test(first)) throw new Error(first)
})

await step("Léa: search and filter kept in the URL", async () => {
  await lea.selectOption("#filters_filter", "solved")
  await lea.waitForURL(/filter=solved/, { timeout: T })
  await expectText(lea, /Pourquoi range\(3\) s'arrête à 2/)
  await lea.fill("#filters_q", "zzz-nothing")
  await lea.waitForURL(/q=zzz-nothing/, { timeout: T })
  await lea.waitForSelector("#community-empty", { timeout: T })
})

await step("Léa: creates a discussion (plain text, HTML escaped, safe link)", async () => {
  await lea.goto(`${BASE}/community/new`)
  await connected(lea)
  await lea.selectOption("#discussion_category", "help-questions")
  if (await lea.locator("#discussion_category option[value='announcements']").count()) throw new Error("announcements offered to a member")
  await lea.fill("#discussion_title", title)
  await lea.fill("#discussion_body", "I tried <b>while</b> in the grove. Reference: https://example.com/grove-docs.")
  await Promise.all([lea.waitForURL(/\/community\/discussions\//, { timeout: T }), lea.click("#save-discussion")])
  discussionUrl = lea.url()
  await connected(lea)
  await expectText(lea, /Discussion published/)
  const html = await lea.locator("#discussion-body").innerHTML()
  if (html.includes("<b>")) throw new Error("raw HTML rendered")
  const rel = await lea.locator('#discussion-body a[href="https://example.com/grove-docs"]').getAttribute("rel")
  if (rel !== "nofollow ugc noopener noreferrer") throw new Error(`rel=${rel}`)
  await lea.waitForSelector("#unfollow", { timeout: T }) // suivi automatique
})

await step("Hugo replies; Léa (follower) gets it live with an aria-live notice", async () => {
  await login(hugo, "hugo")
  await hugo.goto(discussionUrl)
  await connected(hugo)
  await hugo.fill("#reply-form textarea", "Not yet: the grove only understands for loops. Try range() instead!")
  await hugo.click("#post-reply")
  await expectText(hugo, /Reply posted/)
  await lea.waitForSelector("#community-live .community-notice", { timeout: T })
  await expectText(lea, /the grove only understands for loops/)
  replyId = (await lea.locator("li[id^='reply-']").first().getAttribute("id")).replace("reply-", "")
})

await step("Léa votes the reply helpful and marks it as the solution", async () => {
  await lea.click(`#vote-reply-${replyId}`)
  await lea.waitForSelector(`#vote-reply-${replyId}[aria-pressed='true']`, { timeout: T })
  if (!/1/.test(await lea.locator(`#vote-reply-${replyId} .vote-count`).innerText())) throw new Error("count not 1")
  await lea.click(`#solution-${replyId}`)
  await expectText(lea, /Marked as the solution/)
  await lea.waitForSelector(`#reply-${replyId}.is-solution`, { timeout: T })
})

await step("Hugo votes the discussion; no vote button on his own reply", async () => {
  await hugo.reload()
  await connected(hugo)
  if (await hugo.locator(`#vote-reply-${replyId}`).count()) throw new Error("own reply votable")
  await hugo.click("[id^='vote-discussion-']")
  await hugo.waitForSelector("[id^='vote-discussion-'][aria-pressed='true']", { timeout: T })
})

await step("Théo (moderator) hides the reply with a reason and locks the discussion", async () => {
  await login(theo, "theo")
  await theo.goto(discussionUrl)
  await connected(theo)
  await theo.waitForSelector("#moderation-tools", { timeout: T })
  await theo.click(`#mod-hide-${replyId}`)
  await theo.fill("#moderation-reason", "Demo moderation: please keep answers on the lesson.")
  await theo.click("#moderation-form button[type='submit']")
  await expectText(theo, /Moderation action recorded/)
  await theo.waitForSelector(`#reply-${replyId} >> text=Hidden by moderators`, { timeout: T })
  await theo.click("#mod-lock")
  await theo.waitForSelector("#mod-lock >> text=Unlock", { timeout: T })
})

await step("Hugo (author) still sees his hidden reply with the reason; replies are locked", async () => {
  await hugo.reload()
  await connected(hugo)
  await expectText(hugo, /Reason: Demo moderation/)
  await hugo.waitForSelector("#discussion-locked", { timeout: T })
})

await step("Visitors no longer see the hidden reply; members see no moderation tools", async () => {
  const visitor = await newPage()
  await visitor.goto(discussionUrl)
  await connected(visitor)
  if (await visitor.locator(`#reply-${replyId}`).count()) throw new Error("hidden reply visible to a visitor")
  await visitor.waitForSelector("#login-to-reply", { timeout: T })
  if (await lea.locator("#moderation-tools").count()) throw new Error("tools shown to a member")
})

await step("Inès (390 px) reports the discussion, then blocks a member: their posts vanish at once", async () => {
  await login(ines, "ines")
  await ines.goto(discussionUrl)
  await connected(ines)
  await ines.click("[id^='report-discussion-']")
  await ines.selectOption("#report-reason", "other")
  await ines.fill("#report-details", `Journey ${stamp}: demo report`)
  await ines.click("#report-form button[type='submit']")
  await expectText(ines, /Report sent/)
  // bloquer Sarah, autrice d'une discussion seedée
  await ines.goto(`${BASE}/community?q=coin+lecture`)
  await connected(ines)
  await ines.click("#discussions a")
  await ines.waitForURL(/votre-coin-lecture/, { timeout: T })
  await connected(ines)
  await Promise.all([ines.waitForURL(/\/community$/, { timeout: T }), ines.click("[id^='block-discussion-']")])
  await connected(ines)
  await expectText(ines, /Member blocked/)
  // moins de 15 s après la lecture précédente : seule l'invalidation par l'événement de social peut l'expliquer
  await ines.goto(`${BASE}/community?q=coin+lecture`)
  await connected(ines)
  await ines.waitForSelector("#community-empty", { timeout: T })
})

await step("Mobile layout: filters fold behind a toggle, no horizontal scroll", async () => {
  await ines.goto(`${BASE}/community`)
  await connected(ines)
  if (await ines.locator("#filters").isVisible()) throw new Error("filters open by default on mobile")
  await ines.click(".community-filters-toggle")
  await ines.waitForSelector("#filters", { state: "visible", timeout: T })
  for (const [page, url] of [[ines, `${BASE}/community`], [ines, discussionUrl]]) {
    await page.goto(url)
    await connected(page)
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)
    if (overflow > 0) throw new Error(`horizontal overflow ${overflow}px on ${url}`)
    if (SHOTS) await page.screenshot({ path: `${SHOTS}/390_${url.includes("discussions") ? "discussion" : "list"}.png`, fullPage: true })
  }
  await lea.goto(discussionUrl)
  await connected(lea)
  if (SHOTS) await lea.screenshot({ path: `${SHOTS}/1280_discussion.png`, fullPage: true })
})

for (const p of [lea, hugo, theo, ines]) if (p.errors.length) console.log("  page errors:", p.errors)
await browser.close()
console.log(`${results.filter(Boolean).length}/${results.length} steps OK`)
console.log(`DISCUSSION_URL=${discussionUrl}`)
process.exit(results.every(Boolean) ? 0 : 1)
