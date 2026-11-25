// Formats de leçon dans Chrome (vidéo, simulation, mini-jeux, accès premium), sur la pile de bin/dev.
// Usage : cd e2e && node formats.mjs   (BASE, ACCOUNTS, CHROME, HEADED=1)
import { chromium } from "playwright-core"
import { fileURLToPath } from "node:url"

const BASE = process.env.BASE || "http://localhost:4000"
const ACCOUNTS = process.env.ACCOUNTS || "http://localhost:4001"
const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
const T = 20_000
const results = []
const browser = await chromium.launch({
  executablePath: CHROME,
  headless: !process.env.HEADED,
  args: ["--autoplay-policy=no-user-gesture-required"],
})

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

async function newPage(width = 1280, options = {}) {
  const ctx = await browser.newContext({ viewport: { width, height: 900 }, locale: "en-US", ...options })
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
// ouvre une leçon depuis la page de l'aventure (lien du titre)
async function openLesson(page, slug, title) {
  await page.goto(`${BASE}/adventures/${slug}`)
  await connected(page)
  await Promise.all([page.waitForURL(/\/learn\//, { timeout: T }), page.click(`#chapters a:has-text("${title}")`)])
  await connected(page)
  await page.waitForSelector(`h1:has-text("${title}")`, { timeout: T })
}
const noHorizontalScroll = (page) =>
  page.evaluate(() => document.scrollingElement.scrollWidth <= window.innerWidth + 1)

const stamp = Date.now().toString(36)
const member = { email: `formats_${stamp}@mysticlore.test`, username: `fmt_${stamp}`, password: "correct-horse-battery-staple" }
console.log(`Lesson formats — ${BASE} — new Free member ${member.email}`)
const p = await newPage()

await step("a new Free member signs up, confirms the e-mail and logs in", async () => {
  await p.goto(`${BASE}/register`)
  await p.fill('#register-form input[name="user[email]"]', member.email)
  await p.fill('#register-form input[name="user[username]"]', member.username)
  await p.fill('#register-form input[name="user[display_name]"]', `Formats ${stamp}`)
  await p.fill('#register-form input[name="user[password]"]', member.password)
  await Promise.all([p.waitForLoadState("load"), p.click('#register-form button[type="submit"]')])
  let url
  for (let i = 0; i < 30 && !url; i++) {
    const { data } = await (await fetch(`${ACCOUNTS}/dev/mailbox/json`)).json()
    const mail = data.filter((m) => JSON.stringify(m).includes(member.email)).pop()
    const m = mail && JSON.stringify(mail).match(/https?:\/\/[^"\\\s]+\/confirm\/[A-Za-z0-9_-]+/)
    if (m) url = m[0]
    else await new Promise((r) => setTimeout(r, 250))
  }
  if (!url) throw new Error("no confirmation e-mail")
  await p.goto(url)
  await Promise.all([p.waitForLoadState("load"), p.click('#confirm-form button[type="submit"]')])
  await login(p, member.email, member.password)
  await p.waitForURL(/\/(welcome|dashboard)/, { timeout: T })
  await passWelcome(p)
  await p.waitForURL(/\/dashboard/, { timeout: T })
})

// ───────────────────────────────────────────── 1. vidéo
console.log("1. Video « Lire le ciel de nuit »: captions, transcript, playback, completion, XP")
await step("the player has EN and FR WebVTT tracks (EN by default, cues loaded) and a poster", async () => {
  await openLesson(p, "l-atlas-celeste", "Lire le ciel de nuit")
  const info = await p.evaluate(async () => {
    const v = document.querySelector("#lesson-video")
    const tracks = [...v.querySelectorAll("track")].map((t) => ({ lang: t.srclang, def: t.default, src: t.src }))
    const en = [...v.textTracks].find((t) => t.language === "en")
    en.mode = "showing"
    for (let i = 0; i < 50 && !(en.cues && en.cues.length); i++) await new Promise((r) => setTimeout(r, 100))
    return { tracks, cues: en.cues ? en.cues.length : 0, poster: v.poster, first: en.cues?.[0]?.text }
  })
  if (info.tracks.length !== 2 || !info.tracks.find((t) => t.lang === "en" && t.def)) throw new Error(JSON.stringify(info.tracks))
  if (info.cues !== 7) throw new Error(`EN cues: ${info.cues}`)
  if (!/reading-the-night-sky\.jpg$/.test(info.poster)) throw new Error(`poster ${info.poster}`)
  console.log(`      ${info.cues} cues, first: « ${info.first} »`)
  const vtt = await (await p.request.get(`${BASE}/media/lessons/reading-the-night-sky.fr.vtt`)).text()
  if (!/^WEBVTT/.test(vtt) || !/Grande Ourse/.test(vtt)) throw new Error("FR captions")
})
await step("completion is disabled until 80% is played; the hook reports the share actually played", async () => {
  if (!(await p.isDisabled("#complete-lesson"))) throw new Error("complete enabled before playback")
  const duration = await p.evaluate(async () => {
    const v = document.querySelector("#lesson-video")
    v.muted = true
    v.playbackRate = 8
    await v.play()
    return v.duration
  })
  if (!(duration > 30 && duration < 40)) throw new Error(`duration ${duration}`)
  await p.waitForFunction(() => /Watched: (8\d|9\d|100)%/.test(document.querySelector("#video-watched")?.innerText || ""), null, { timeout: 30_000 })
  await p.waitForFunction(() => !document.querySelector("#complete-lesson")?.disabled, null, { timeout: T })
  console.log(`      ${await text(p, "#video-watched")} (duration ${duration.toFixed(1)} s)`)
})
await step("the transcript unfolds (aria-expanded) and holds the full text", async () => {
  if (await p.isVisible("#transcript")) throw new Error("transcript visible before opening")
  await p.click("#toggle-transcript")
  await p.waitForSelector("#toggle-transcript[aria-expanded=true]", { timeout: T })
  await p.waitForSelector("#transcript:not([hidden])", { state: "visible", timeout: T })
  await expectText(p, "#transcript", /Trouvez les repères, suivez-les vers le nord/)
})
await step("mark complete → +15 XP; after reload the lesson stays completed (XP once)", async () => {
  await p.click("#complete-lesson")
  await expectText(p, "#xp-awarded", /\+15 XP/)
  await p.reload()
  await connected(p)
  await p.waitForSelector("#lesson-completed", { timeout: T })
  if (await p.locator("#complete-lesson").count()) throw new Error("complete button still there")
})

// ───────────────────────────────────────────── 2. simulation
console.log("2. Simulation « L'étoile errante »: bounds, run → table, check → XP once")
await step("out-of-bounds parameter refused by the server (422 shown next to the field)", async () => {
  await Promise.all([p.waitForSelector(`h1:has-text("L'étoile errante")`, { timeout: T }), p.click("#next-lesson")])
  await p.fill("#params_velocity", "50")
  await p.click("#run-sim")
  await expectText(p, "#params_velocity-error", /must be between 4\.0 and 9\.0/)
  await p.waitForSelector("#sim-error[role=alert]", { timeout: T })
  if (await p.locator("#sim-table").count()) throw new Error("a table was shown")
})
await step("run → plot (aria-hidden), data table, metrics and description (aria-live)", async () => {
  await p.fill("#params_velocity", "7")
  await p.click("#run-sim")
  await p.waitForSelector("#sim-table tbody tr", { timeout: T })
  const rows = await p.locator("#sim-table tbody tr").count()
  if (rows < 2 || rows > 200) throw new Error(`${rows} rows`)
  if ((await p.getAttribute("#sim-plot", "aria-hidden")) !== "true") throw new Error("plot not aria-hidden")
  await expectText(p, "#sim-output #sim-description", /eccentricity/)
  console.log(`      ${rows} rows · ${await text(p, "#sim-engine")}`)
  console.log(`      ${await text(p, "#sim-description")}`)
})
await step("check with an elongated orbit → not quite, no XP", async () => {
  await p.click("#check-sim")
  await expectText(p, "#result", /Not quite/)
  await expectText(p, "#result", /too elongated/)
  if (await p.locator("#xp-awarded").count()) throw new Error("XP for a wrong answer")
})
await step("the solution (6.3 AU/yr) → well done, +30 XP; checking again → XP granted once", async () => {
  await p.fill("#params_velocity", "6.3")
  await p.click("#check-sim")
  await expectText(p, "#result", /Well done/)
  await expectText(p, "#xp-awarded", /\+30 XP/)
  await p.click("#check-sim")
  await p.waitForSelector("#xp-duplicate", { timeout: T })
})

// ───────────────────────────────────────────── 3. mini-jeux
console.log("3. Mini-games: wrong order → feedback, right order WITH THE KEYBOARD → XP")
await step("constellation: a wrong path → feedback and score, no XP", async () => {
  await Promise.all([p.waitForSelector('h1:has-text("Tracer la Grande Ourse")', { timeout: T }), p.click("#next-lesson")])
  for (const name of ["Alkaid", "Dubhe"]) await p.click(`.star-button:has-text("${name}")`)
  await expectText(p, "#star-path", /Alkaid → Dubhe/)
  await p.click("#check-game")
  await expectText(p, "#result", /Not quite/)
  await expectText(p, "#game-score", /Score: \d+\/100/)
})
await step("constellation: the Great Dipper traced with Tab/Enter only → +25 XP", async () => {
  await p.focus("#reset-game")
  await p.keyboard.press("Enter")
  await expectText(p, "#star-path", /No star selected/)
  const dipper = ["Alkaid", "Mizar", "Alioth", "Megrez", "Dubhe", "Merak", "Phecda", "Megrez"]
  for (const [k, name] of dipper.entries()) {
    await p.focus(`.star-button:has-text("${name}")`)
    await p.keyboard.press("Enter")
    // each selection is announced politely before the next one
    await expectText(p, "#game-announce", new RegExp(`${name} added: star ${k + 1} of your path`))
  }
  await expectText(p, "#star-path", /Alkaid → Mizar → Alioth → Megrez → Dubhe → Merak → Phecda → Megrez/)
  await expectText(p, "#game-announce", /Megrez added: star 8/)
  await p.focus("#check-game")
  await p.keyboard.press("Enter")
  await expectText(p, "#xp-awarded", /\+25 XP/)
})
const year = (label) => { const m = label.match(/\((?:vers )?(\d+)( av\. J\.-C\.)?\)/); return m[2] ? -Number(m[1]) : Number(m[1]) }
await step("sequence (Les Gardiens des archives): the shuffled order is wrong → feedback", async () => {
  await openLesson(p, "les-gardiens-des-archives", "Classer les sources")
  await p.click("#check-game")
  await expectText(p, "#result", /Not quite/)
  await expectText(p, "#result", /of 5 items are in the right place/)
})
await step("sequence: sorted by date with the Move up buttons and Enter (focus follows the item) → +25 XP", async () => {
  const labels = async () => p.$$eval("#sequence-list li", (lis) => lis.map((li) => li.querySelector("span.min-w-0").innerText))
  const target = [...(await labels())].sort((a, b) => year(a) - year(b))
  for (let i = 0; i < target.length; i++) {
    const current = await labels()
    const from = current.indexOf(target[i])
    if (from === i) continue
    const id = await p.$$eval("#sequence-list li", (lis, k) => lis[k].id, from)
    await p.focus(`#${id}-up`)
    for (let k = from; k > i; k--) {
      await p.keyboard.press("Enter")
      await expectText(p, "#game-announce", new RegExp(`position ${k} of 5`))
      // the focus stays on the moved item (or moves to its other button at the top)
      await p.waitForFunction((el) => document.activeElement?.id?.startsWith(el), id, { timeout: T })
    }
  }
  if (JSON.stringify(await labels()) !== JSON.stringify(target)) throw new Error("not sorted")
  await p.focus("#check-game")
  await p.keyboard.press("Enter")
  await expectText(p, "#result", /right order/)
  await expectText(p, "#xp-awarded", /\+25 XP/)
  await expectText(p, "#game-score", /Score: 100\/100/)
})

// ───────────────────────────────────────────── 4. premium
console.log("4. Premium: La Machine de l'alchimiste is refused to a Free member")
await step("a Free member gets the upgrade notice on the reaction simulation and the valve mini-game", async () => {
  await p.goto(`${BASE}/adventures/la-machine-de-l-alchimiste`)
  await connected(p)
  const ids = []
  for (const title of ["Le cœur de la machine", "Redémarrer la vanne"])
    ids.push([title, await p.locator(`#chapters li.lesson-row:has-text("${title}")`).getAttribute("id")])
  for (const [title, id] of ids) {
    await p.goto(`${BASE}/learn/la-machine-de-l-alchimiste/${id.replace("lesson-", "")}`)
    await connected(p)
    await p.waitForSelector("#lesson-premium", { timeout: T })
    if (await p.locator("#simulation, #minigame").count()) throw new Error(`${title} rendered for a Free member`)
  }
})
await step("a Premium member (lea) runs the reaction chamber: balanced equation, flat atom totals", async () => {
  const lea = await newPage()
  await login(lea, "lyra@mysticlore.test", "mystic-demo-pass-1")
  await openLesson(lea, "la-machine-de-l-alchimiste", "Le cœur de la machine")
  await lea.fill("#params_h2", "2")
  await lea.fill("#params_o2", "1")
  await lea.fill("#params_h2o", "2")
  await lea.click("#run-sim")
  await expectText(lea, "#sim-description", /2 H2 \+ O2 → 2 H2O.*Every atom is conserved/)
  await lea.waitForSelector("#sim-table tbody tr", { timeout: T })
  if (lea.errors.length) throw new Error(lea.errors.join("\n"))
  await lea.context().close()
})

// ───────────────────────────────────────────── 5. studio → publication → proxy des médias publiés
console.log("5. Studio: a real WebM + WebVTT uploaded, reviewed, published; learners play it through the proxy")
const MEDIA = fileURLToPath(new URL("../src/web/priv/static/media/lessons/", import.meta.url))
const TITLE = `Night Film ${stamp}`
const author = await newPage()
let projectUrl, publishedSrc
await step("lea builds a video lesson in the studio: text, transcript, video upload, captions upload", async () => {
  await login(author, "lyra@mysticlore.test", "mystic-demo-pass-1")
  await author.goto(`${BASE}/studio/new`); await connected(author)
  await author.fill('#new-project-form input[name="brief[title]"]', TITLE)
  await author.fill('#new-project-form textarea[name="brief[objectives]"]', "Find the pole star from the Great Dipper")
  await author.fill('#new-project-form input[name="brief[audience]"]', "Curious stargazers")
  await author.selectOption('#new-project-form select[name="brief[category]"]', "science")
  await author.fill('#new-project-form textarea[name="brief[summary]"]', "A short star-film with captions and a transcript.")
  await Promise.all([author.waitForURL(/\/studio\/[0-9a-f-]{36}\?step=outline/, { timeout: T }), author.click("#create-project")])
  projectUrl = author.url().split("?")[0]
  await connected(author)
  await author.fill("#new-module-title", "The star-film")
  await author.click('#add-module button[type="submit"]')
  await author.waitForSelector('form[id^="add-lesson-"]', { timeout: T })
  await author.fill('form[id^="add-lesson-"] input[name="title"]', "Lire le ciel de nuit")
  await author.selectOption('form[id^="add-lesson-"] select[name="kind"]', "video")
  await author.click('form[id^="add-lesson-"] button[type="submit"]')
  await author.goto(`${projectUrl}?step=build`); await connected(author)
  await author.waitForSelector("#video-media", { timeout: T })
  await author.fill("#lesson_body", "Watch the star-film, with captions, or read its transcript.")
  await author.fill("#lesson_transcript", "Tonight we read the night sky. Follow the pointers, Merak then Dubhe, to Polaris.")
  await author.fill("#lesson_duration_s", "34")
  await expectText(author, "#lesson-saved", /Saved/)
  await author.setInputFiles("#video-upload-form input[type=file]", MEDIA + "reading-the-night-sky.webm")
  await author.click("#upload-video")
  await author.waitForSelector("#video-preview", { timeout: 60_000 })
  await expectText(author, "#video-current", /video\/webm, 1\.\d MB/)
  await author.selectOption("#captions-lang", "en")
  await author.setInputFiles("#captions-form input[type=file]", MEDIA + "reading-the-night-sky.en.vtt")
  await author.click("#upload-captions")
  await author.waitForSelector("#captions-en", { timeout: T })
  const preview = await author.evaluate(async () => (await fetch(document.querySelector("#video-preview").src)).headers.get("content-type"))
  if (preview !== "video/webm") throw new Error(`preview ${preview}`)
})
await step("checks pass, declarations, submission; theo (moderator) approves → imported into learning", async () => {
  await author.goto(`${projectUrl}?step=review`); await connected(author)
  await author.waitForSelector("#check-videos", { timeout: T })
  const failing = await author.locator("#checks .text-danger").count()
  if (failing > 0) throw new Error(await text(author, "#checks"))
  for (const k of ["accuracy", "safety", "accessibility"]) { await author.check(`#attest-${k}`); await author.waitForTimeout(300) }
  await expectText(author, "#attestations-state", /confirmed for the current content/)
  await author.goto(`${projectUrl}?step=publish`); await connected(author)
  await author.click("#submit-project")
  await expectText(author, "#project-status", /In review/)
  const theo = await newPage()
  await login(theo, "theo@mysticlore.test", "mystic-demo-pass-1")
  await theo.goto(`${BASE}/studio/review`); await connected(theo)
  await theo.click(`#review-queue a:has-text("${TITLE}")`)
  await connected(theo)
  await theo.click("#approve")
  await expectText(theo, "#review-status", /Published/)
  await theo.context().close()
})
await step("a learner plays the published video through /media/studio/:id (captions loaded)", async () => {
  await author.goto(`${projectUrl}?step=publish`); await connected(author)
  const slug = (await author.locator("#published a").getAttribute("href")).split("/").pop()
  await openLesson(p, slug, "Lire le ciel de nuit")
  const info = await p.evaluate(async () => {
    const v = document.querySelector("#lesson-video")
    const src = v.querySelector("source").getAttribute("src")
    const track = v.querySelector("track")
    const res = await fetch(src)
    const en = v.textTracks[0]; en.mode = "showing"
    v.muted = true; await v.play()
    for (let i = 0; i < 50 && !(en.cues && en.cues.length); i++) await new Promise((r) => setTimeout(r, 100))
    return { src, track: track.getAttribute("src"), status: res.status, type: res.headers.get("content-type"), cues: en.cues?.length || 0, duration: v.duration }
  })
  if (!/^\/media\/studio\/[0-9a-f-]{36}$/.test(info.src) || info.status !== 200 || info.type !== "video/webm") throw new Error(JSON.stringify(info))
  if (info.cues !== 7 || !(info.duration > 30)) throw new Error(JSON.stringify(info))
  publishedSrc = info.src
  console.log(`      ${info.src} → ${info.status} ${info.type}, ${info.cues} cues, ${info.duration.toFixed(1)} s`)
})
await step("draft media are never served to learners; the published one stays available", async () => {
  // a new upload makes the project a draft again: the new file is only visible to its authors
  await author.goto(`${projectUrl}?step=build`); await connected(author)
  await author.setInputFiles("#video-upload-form input[type=file]", MEDIA + "reading-the-night-sky.webm")
  await author.click("#upload-video")
  await author.waitForFunction((old) => { const v = document.querySelector("#video-preview"); return v && !v.src.endsWith(old.split("/").pop()) }, publishedSrc, { timeout: 60_000 })
  const draftId = (await author.getAttribute("#video-preview", "src")).split("/").pop()
  const draft = await p.request.get(`${BASE}/media/studio/${draftId}`)
  const published = await p.request.get(BASE + publishedSrc)
  const anonymous = await (await browser.newContext()).request.get(BASE + publishedSrc)
  if (draft.status() !== 404 || published.status() !== 200 || anonymous.status() !== 404)
    throw new Error(`draft ${draft.status()}, published ${published.status()}, anonymous ${anonymous.status()}`)
  if (author.errors.length) throw new Error(author.errors.join("\n"))
})

// ───────────────────────────────────────────── 6. responsive, mouvement réduit, erreurs
console.log("6. 390 px with reduced motion: no horizontal scroll, controls ≥ 44 px")
await step("video, simulation and mini-game pages fit a 390 px phone", async () => {
  const phone = await newPage(390, { reducedMotion: "reduce" })
  await login(phone, member.email, member.password)
  for (const [slug, title, controls] of [
    ["l-atlas-celeste", "Lire le ciel de nuit", "#toggle-transcript"],
    ["l-atlas-celeste", "L'étoile errante", "#run-sim, #check-sim"],
    ["les-gardiens-des-archives", "Classer les sources", "#sequence-list button, #check-game"],
    ["l-atlas-celeste", "Tracer la Grande Ourse", ".star-button, #check-game"],
  ]) {
    await openLesson(phone, slug, title)
    if (title === "L'étoile errante") { await phone.click("#run-sim"); await phone.waitForSelector("#sim-table", { timeout: T }) }
    if (!(await noHorizontalScroll(phone))) throw new Error(`${title}: horizontal scroll`)
    const small = await phone.$$eval(controls, (els) => els.filter((e) => e.getBoundingClientRect().height < 44).length)
    if (small) throw new Error(`${title}: ${small} control(s) < 44 px`)
  }
  if (phone.errors.length) throw new Error(phone.errors.join("\n"))
})
await step("no JavaScript error nor 5xx during the journey", async () => {
  if (p.errors.length) throw new Error(p.errors.join("\n"))
})

await browser.close()
const failed = results.filter(([s]) => s === "✗").length
console.log(`\n${results.length - failed}/${results.length} checks passed`)
process.exit(failed ? 1 : 0)
