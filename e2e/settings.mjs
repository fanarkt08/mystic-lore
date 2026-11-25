// Paramètres et profil dans Chrome : langue, fuseau, thèmes, accessibilité, avatar et visibilité du profil.
// Usage : cd e2e && node settings.mjs   (BASE, ACCOUNTS, CHROME, HEADED=1, DEMO_PASSWORD)
import { chromium } from "playwright-core"

const BASE = process.env.BASE || "http://localhost:4000"
const ACCOUNTS = process.env.ACCOUNTS || "http://localhost:4001"
const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
const DEMO_PASSWORD = process.env.DEMO_PASSWORD || "mystic-demo-pass-1"
const T = 20_000
const results = []
const pages = []
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

async function newPage(options = {}) {
  const { width = 1280, ...rest } = options
  const ctx = await browser.newContext({ viewport: { width, height: 900 }, locale: "en-US", ...rest })
  const page = await ctx.newPage()
  page.on("dialog", (d) => d.accept())
  page.errors = []
  page.on("pageerror", (e) => page.errors.push(String(e)))
  page.on("console", (m) => m.type() === "error" && !/Failed to load resource/.test(m.text()) && page.errors.push(m.text()))
  page.on("response", (r) => r.status() >= 500 && page.errors.push(`HTTP ${r.status()} ${r.url()}`))
  pages.push(page)
  return page
}

const connected = (page) => page.waitForSelector("[data-phx-main].phx-connected", { timeout: T })
const html = (page, name) => page.evaluate((n) => document.documentElement.getAttribute(n), name)
async function expectText(page, sel, re) {
  await page.waitForFunction(([s, src]) => { const el = document.querySelector(s); return el && new RegExp(src, "i").test(el.innerText) }, [sel, re.source], { timeout: T })
}
async function login(page, email, password = DEMO_PASSWORD) {
  await page.goto(`${BASE}/login`)
  await page.fill('#login-form input[name="user[email]"]', email)
  await page.fill('#login-form input[name="user[password]"]', password)
  await Promise.all([page.waitForURL(/\/(dashboard|welcome)/, { timeout: T }), page.click('#login-form button[type="submit"]')])
  await passWelcome(page)
}

// Un compte neuf passe par l'accueil guidé à sa première connexion ; « Passer l'accueil » l'enregistre.
async function passWelcome(page) {
  if (!/\/welcome/.test(page.url())) return
  await page.waitForSelector("[data-phx-main].phx-connected", { timeout: T })
  await Promise.all([page.waitForURL(/\/dashboard/, { timeout: T }), page.click("#welcome-skip-tour")])
}

async function open(page, path) {
  await page.goto(BASE + path)
  await connected(page)
}
// a time shown by the single date utility: "14:05 CET" → {minutes, zone}
function clock(text) {
  const m = text.match(/(\d{2}):(\d{2}) ([A-Z]{2,5}|[+-]\d{2,4})/)
  if (!m) throw new Error(`no time in « ${text} »`)
  return { minutes: Number(m[1]) * 60 + Number(m[2]), zone: m[3] }
}
const shift = (a, b) => (((b.minutes - a.minutes) % 1440) + 1440) % 1440

// Images built in the browser (canvas): a real PNG, and a JPEG given an EXIF segment with GPS coordinates.
async function canvasImage(page, type) {
  const url = await page.evaluate((t) => {
    const c = document.createElement("canvas")
    c.width = c.height = 128
    const g = c.getContext("2d")
    g.fillStyle = "#1d2457"
    g.fillRect(0, 0, 128, 128)
    g.fillStyle = "#edca85"
    g.beginPath()
    g.arc(64, 64, 40, 0, Math.PI * 2)
    g.fill()
    return c.toDataURL(t, 0.9)
  }, type)
  return Buffer.from(url.split(",")[1], "base64")
}
function withExifGps(jpeg) {
  const tiff = Buffer.concat([
    Buffer.from([0x4d, 0x4d, 0x00, 0x2a, 0x00, 0x00, 0x00, 0x08]),
    // IFD0 : 1 entrée, pointeur vers l'IFD GPS (0x8825) à l'offset 26
    Buffer.from([0x00, 0x01, 0x88, 0x25, 0x00, 0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x1a, 0x00, 0x00, 0x00, 0x00]),
    // IFD GPS : GPSLatitudeRef = "N"
    Buffer.from([0x00, 0x01, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x4e, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
    Buffer.from("GPS-E2E-SECRET 48.8584N 2.2945E"),
  ])
  const payload = Buffer.concat([Buffer.from("Exif\0\0", "binary"), tiff])
  const app1 = Buffer.concat([Buffer.from([0xff, 0xe1, (payload.length + 2) >> 8, (payload.length + 2) & 0xff]), payload])
  // après le segment APP0 (JFIF) de Chrome
  const at = jpeg[3] === 0xe0 ? 4 + ((jpeg[4] << 8) | jpeg[5]) : 2
  return Buffer.concat([jpeg.subarray(0, at), app1, jpeg.subarray(at)])
}
async function upload(page, file) {
  await page.setInputFiles("#avatar-form input[type=file]", file)
  await page.click("#upload-avatar")
}

const stamp = Date.now().toString(36)
const newbie = { email: `settings_${stamp}@mysticlore.test`, username: `set_${stamp}`, name: `Settings ${stamp}`, password: "correct-horse-battery-staple" }
console.log(`Settings and profile — ${BASE} — new member ${newbie.email}`)
const p = await newPage({ timezoneId: "UTC" })

await step("a new member signs up, confirms the e-mail and logs in", async () => {
  await p.goto(`${BASE}/register`)
  await p.fill('#register-form input[name="user[email]"]', newbie.email)
  await p.fill('#register-form input[name="user[username]"]', newbie.username)
  await p.fill('#register-form input[name="user[display_name]"]', newbie.name)
  await p.fill('#register-form input[name="user[password]"]', newbie.password)
  await Promise.all([p.waitForLoadState("load"), p.click('#register-form button[type="submit"]')])
  let url
  for (let i = 0; i < 30 && !url; i++) {
    const { data } = await (await fetch(`${ACCOUNTS}/dev/mailbox/json`)).json()
    const mail = data.filter((m) => JSON.stringify(m).includes(newbie.email)).pop()
    const m = mail && JSON.stringify(mail).match(/https?:\/\/[^"\\\s]+\/confirm\/[A-Za-z0-9_-]+/)
    if (m) url = m[0]
    else await new Promise((r) => setTimeout(r, 250))
  }
  if (!url) throw new Error("no confirmation e-mail")
  await p.goto(url)
  await Promise.all([p.waitForLoadState("load"), p.click('#confirm-form button[type="submit"]')])
  await login(p, newbie.email, newbie.password)
})

// ───────────────────────────────────────────── 1. langue
console.log("1. Language: the member's choice, kept after logout and login; visitor selector")
await step("French chosen in the settings: the page reloads in French (<html lang=fr>)", async () => {
  await open(p, "/settings/preferences")
  await p.check("#language-choice-fr")
  await Promise.all([p.waitForURL(/\/settings\/preferences/, { timeout: T }), p.waitForEvent("load"), p.click("#save-language")])
  await connected(p)
  if ((await html(p, "lang")) !== "fr") throw new Error(`lang=${await html(p, "lang")}`)
  await expectText(p, "#nav-dashboard", /Tableau de bord/)
})
await step("logged out: the English browser gets English; logged in again: French everywhere", async () => {
  await Promise.all([p.waitForURL((u) => !u.pathname.startsWith("/settings"), { timeout: T }), p.click("#rail-logout")])
  await p.goto(`${BASE}/login`)
  if ((await html(p, "lang")) !== "en") throw new Error(`visitor lang=${await html(p, "lang")}`)
  await login(p, newbie.email, newbie.password)
  await connected(p)
  if ((await html(p, "lang")) !== "fr") throw new Error(`member lang=${await html(p, "lang")}`)
  await open(p, "/adventures")
  if ((await html(p, "lang")) !== "fr") throw new Error("not kept on /adventures")
})
await step("back to « Automatic » (browser language)", async () => {
  await open(p, "/settings/preferences")
  await p.check("#language-choice-auto")
  await Promise.all([p.waitForEvent("load"), p.click("#save-language")])
  await connected(p)
  if ((await html(p, "lang")) !== "en") throw new Error(`lang=${await html(p, "lang")}`)
})
const visitor = await newPage({ timezoneId: "UTC" })
await step("visitor: the footer selector sets a SameSite=Lax cookie and comes back to the same page", async () => {
  await open(visitor, "/adventures?difficulty=beginner")
  if ((await html(visitor, "lang")) !== "en") throw new Error("visitor not in English")
  await visitor.selectOption("#locale-select", "fr")
  await Promise.all([visitor.waitForEvent("load"), visitor.click("#locale-submit")])
  const url = new URL(visitor.url())
  if (url.pathname + url.search !== "/adventures?difficulty=beginner") throw new Error(`back to ${url.pathname}${url.search}`)
  if ((await html(visitor, "lang")) !== "fr") throw new Error("not French after the choice")
  const cookie = (await visitor.context().cookies()).find((c) => c.name === "ml_locale")
  if (!cookie || cookie.value !== "fr" || cookie.sameSite !== "Lax" || !cookie.httpOnly) throw new Error(JSON.stringify(cookie))
})
await step("visitor: no open redirect, and no change without the CSRF token", async () => {
  const token = await visitor.locator("meta[name='csrf-token']").getAttribute("content")
  const ok = await visitor.request.post(`${BASE}/locale`, { form: { _csrf_token: token, locale: "en", return_to: "https://evil.example/phish" }, maxRedirects: 0 })
  if (ok.status() !== 302 || ok.headers().location !== "/") throw new Error(`${ok.status()} → ${ok.headers().location}`)
  const forged = await visitor.request.post(`${BASE}/locale`, { form: { locale: "fr", return_to: "/" }, maxRedirects: 0 })
  if (forged.status() !== 403) throw new Error(`without CSRF token: ${forged.status()}`)
})

// ───────────────────────────────────────────── 2. avatar
console.log("2. Avatar: PNG accepted and shown with the member's contributions; text refused; JPEG cleaned of EXIF")
let pngUrl
await step("a PNG made in the browser is accepted, then shown on the profile", async () => {
  await open(p, "/settings/profile")
  await upload(p, { name: "crest.png", mimeType: "image/png", buffer: await canvasImage(p, "image/png") })
  await expectText(p, "#avatar-status", /Avatar saved/)
  pngUrl = await p.locator("#avatar-section img.avatar-picture").getAttribute("src")
  if (!/^\/media\/avatars\/[0-9a-f]{32}\.png$/.test(pngUrl)) throw new Error(`src ${pngUrl}`)
  const resp = await p.request.get(BASE + pngUrl)
  if (resp.status() !== 200 || resp.headers()["content-type"] !== "image/png" || resp.headers()["x-content-type-options"] !== "nosniff")
    throw new Error(`${resp.status()} ${resp.headers()["content-type"]}`)
  await open(p, `/members/${newbie.username}`)
  await p.waitForSelector(`#member-profile img.avatar-picture[src="${pngUrl}"]`, { timeout: T })
  if (!(await p.locator(`#member-profile img[src="${pngUrl}"]`).evaluate((img) => img.complete && img.naturalWidth === 128)))
    throw new Error("the image doesn't render")
})
await step("…and next to the member's forum discussion (list and page), with the @username", async () => {
  await open(p, "/community/new")
  await p.selectOption("#discussion_category", "help-questions")
  await p.fill("#discussion_title", `Avatar check ${stamp}`)
  await p.fill("#discussion_body", "Does my new crest show up next to this question?")
  await Promise.all([p.waitForURL(/\/community\/discussions\//, { timeout: T }), p.click("#save-discussion")])
  await connected(p)
  await p.waitForSelector(`main img.avatar-picture[src="${pngUrl}"]`, { timeout: T })
  await expectText(p, "main", new RegExp(`@${newbie.username}`))
  await open(p, "/community")
  const card = p.locator("article", { hasText: `Avatar check ${stamp}` })
  if (!(await card.locator(`img[src="${pngUrl}"]`).count())) throw new Error("no avatar on the card")
})
await step("a text file renamed .png is refused (magic bytes), the avatar stays", async () => {
  await open(p, "/settings/profile")
  await upload(p, { name: "notes.png", mimeType: "image/png", buffer: Buffer.from("Just some notes, not an image at all.\n") })
  await expectText(p, "#avatar-error", /PNG, JPEG or WebP/)
  if ((await p.locator("#avatar-section img.avatar-picture").getAttribute("src")) !== pngUrl) throw new Error("avatar changed")
})
await step("a JPEG with EXIF GPS is served WITHOUT EXIF; the previous image is gone", async () => {
  const jpeg = withExifGps(await canvasImage(p, "image/jpeg"))
  if (!jpeg.includes("Exif") || !jpeg.includes("GPS-E2E-SECRET")) throw new Error("test image without EXIF")
  await upload(p, { name: "holiday.jpg", mimeType: "image/jpeg", buffer: jpeg })
  await expectText(p, "#avatar-status", /Avatar saved/)
  const src = await p.locator("#avatar-section img.avatar-picture").getAttribute("src")
  if (!/\.jpg$/.test(src)) throw new Error(`src ${src}`)
  const resp = await p.request.get(BASE + src)
  const body = Buffer.from(await resp.body())
  if (resp.headers()["content-type"] !== "image/jpeg") throw new Error(resp.headers()["content-type"])
  if (body.includes("Exif") || body.includes("GPS-E2E-SECRET")) throw new Error("EXIF still served")
  if (body[0] !== 0xff || body[1] !== 0xd8 || body.length > jpeg.length) throw new Error("not a cleaned JPEG")
  console.log(`      ${jpeg.length} → ${body.length} bytes, no APP1/EXIF`)
  if ((await p.request.get(BASE + pngUrl)).status() !== 404) throw new Error("old PNG still served")
})

// ───────────────────────────────────────────── 3. visibilité « friends » et aperçu
console.log("3. Visibility: Sarah shares her profile with friends only; the preview matches")
const sarah = await newPage()
const hugo = await newPage()
await step("the new member and Sarah become friends", async () => {
  await open(p, "/friends")
  await p.fill("#search-q", "sarah")
  const row = p.locator("#search-results li", { hasText: "Sarah Lefèvre" })
  await row.getByRole("button", { name: /add friend/i }).click()
  await expectText(p, "body", /request sent/)
  await login(sarah, "samira@mysticlore.test")
  await open(sarah, "/friends")
  const req = sarah.locator("li", { hasText: newbie.name }).first()
  await req.getByRole("button", { name: /^accept/i }).click()
  await sarah.waitForSelector(`#friends-list >> text=${newbie.name}`, { timeout: T })
})
let friendBio
await step("a friend sees the bio; a member who isn't a friend and a visitor don't", async () => {
  await open(p, "/members/sarah_lefevre")
  friendBio = await p.locator("#member-profile-bio").innerText({ timeout: T })
  if (!/vieilles cartes/.test(friendBio)) throw new Error(`friend sees « ${friendBio} »`)
  await login(hugo, "orion@mysticlore.test")
  await open(hugo, "/members/sarah_lefevre")
  await hugo.waitForSelector("#member-profile-hidden", { timeout: T })
  if (await hugo.locator("#member-profile-bio").count()) throw new Error("non-friend sees the bio")
  await open(visitor, "/members/sarah_lefevre")
  await visitor.waitForSelector("#member-profile-hidden", { timeout: T })
  if (await visitor.locator("#member-profile-bio, #member-record").count()) throw new Error("visitor sees the bio or the record")
  if (await visitor.locator("#member-profile button").count()) throw new Error("member actions offered to a visitor")
})
await step("Sarah's preview (visitor, member, friend) equals what those readers really got", async () => {
  await open(sarah, "/settings/data")
  for (const as of ["visitor", "member", "friend"]) {
    await sarah.click(`#preview-as-${as}`)
    await sarah.waitForSelector(`#preview-as-${as}[aria-pressed=true]`, { timeout: T })
    const bio = await sarah.locator("#preview-profile-bio").count()
    const hidden = await sarah.locator("#preview-profile-hidden").count()
    if (as === "friend") {
      if (!bio || (await sarah.locator("#preview-profile-bio").innerText()) !== friendBio) throw new Error("friend preview ≠ friend's page")
      if (!(await sarah.locator("#preview-record").count())) throw new Error("friend preview without the academy record")
    } else if (bio || !hidden) throw new Error(`${as} preview shows the bio`)
  }
})

// ───────────────────────────────────────────── 4. fuseau
console.log("4. Time zone: the same real timestamp, shifted by the zone (browser's or chosen)")
let utcTime, discussionId
await step("auto: the browser's zone (Intl) shifts a forum time from UTC to Tokyo (+9 h, JST)", async () => {
  await open(visitor, "/community")
  discussionId = await visitor.locator("#discussions article").first().getAttribute("id")
  utcTime = clock(await visitor.locator(`#${discussionId} time`).innerText())
  if (utcTime.zone !== "UTC") throw new Error(`zone ${utcTime.zone}`)
  const tokyo = await newPage({ timezoneId: "Asia/Tokyo" })
  await open(tokyo, "/community")
  await tokyo.waitForFunction((id) => /JST/.test(document.querySelector(`#${id} time`)?.innerText || ""), discussionId, { timeout: T })
  const t = clock(await tokyo.locator(`#${discussionId} time`).innerText())
  if (shift(utcTime, t) !== 9 * 60) throw new Error(`UTC ${JSON.stringify(utcTime)} → Tokyo ${JSON.stringify(t)}`)
  console.log(`      ${discussionId}: ${await visitor.locator(`#${discussionId} time`).innerText()} → ${await tokyo.locator(`#${discussionId} time`).innerText()}`)
})
await step("a zone chosen in the settings wins over the browser's (New York: −5 h, EST)", async () => {
  await open(p, "/settings/preferences")
  await p.selectOption("#time-zone", "America/New_York")
  await p.click("#save-language")
  await expectText(p, "#language-status", /saved.*E[SD]T/)
  await open(p, "/community")
  const t = clock(await p.locator(`#${discussionId} time`).innerText())
  if (t.zone !== "EST" || shift(utcTime, t) !== 19 * 60) throw new Error(`${JSON.stringify(t)} vs ${JSON.stringify(utcTime)}`)
})

// ───────────────────────────────────────────── 5. thèmes
console.log("5. Themes: a VIP theme is refused to Hugo (Free), accepted for Inès (VIP)")
await step("Hugo (Free): the VIP theme is refused by accounts, explained next to the field", async () => {
  await open(hugo, "/settings/preferences")
  await hugo.check("#vip-theme-choice-grove")
  await hugo.click("#save-appearance")
  await expectText(hugo, "#theme-error", /VIP membership/)
  if ((await html(hugo, "data-theme")) !== "system") throw new Error(`theme ${await html(hugo, "data-theme")}`)
  await hugo.reload()
  if ((await html(hugo, "data-theme")) !== "system") throw new Error("refused theme applied after reload")
})
const ines = await newPage()
await step("Inès (VIP): her « grove » theme is applied; « ember » is saved and applied at once", async () => {
  await login(ines, "mika@mysticlore.test")
  if ((await html(ines, "data-theme")) !== "grove") throw new Error(`seeded theme ${await html(ines, "data-theme")}`)
  await open(ines, "/settings/preferences")
  await ines.check("#vip-theme-choice-ember")
  await ines.click("#save-appearance")
  await expectText(ines, "#appearance-status", /Appearance saved/)
  await ines.waitForFunction(() => document.documentElement.dataset.theme === "ember", null, { timeout: T })
  const bg = await ines.evaluate(() => getComputedStyle(document.body).backgroundColor)
  await ines.reload()
  if ((await html(ines, "data-theme")) !== "ember") throw new Error("not kept after reload")
  console.log(`      body background with ember: ${bg}`)
  await connected(ines)
  await ines.check("#vip-theme-choice-grove")
  await ines.click("#save-appearance")
  await ines.waitForFunction(() => document.documentElement.dataset.theme === "grove", null, { timeout: T })
})

// ───────────────────────────────────────────── 6. accessibilité
console.log("6. Accessibility: <html> attributes, effects, captions")
await step("motion, contrast, underlined links and text size are applied at once and after reload", async () => {
  await open(p, "/settings/accessibility")
  await p.check("#a11y-reduce-motion")
  await p.check("#a11y-high-contrast")
  await p.check("#a11y-underline-links")
  await p.check("#text-size-choice-150")
  await p.click("#save-accessibility")
  await expectText(p, "#accessibility-status", /saved/)
  await p.waitForFunction(() => document.documentElement.dataset.textSize === "150", null, { timeout: T })
  // a new page load: the server renders the same attributes
  await open(p, "/settings/profile")
  const a = await p.evaluate(() => {
    const d = document.documentElement
    const link = document.querySelector("#identity-note a")
    return {
      motion: d.dataset.motion, contrast: d.dataset.contrast, links: d.dataset.links, size: d.dataset.textSize,
      font: getComputedStyle(d).fontSize,
      transition: getComputedStyle(document.querySelector(".btn")).transitionDuration,
      underline: link ? getComputedStyle(link).textDecorationLine : "none",
      muted: getComputedStyle(document.querySelector(".text-muted")).color, ink: getComputedStyle(d).getPropertyValue("--color-ink").trim(),
    }
  })
  if (a.motion !== "reduce" || a.contrast !== "more" || a.links !== "underline" || a.size !== "150") throw new Error(JSON.stringify(a))
  if (a.font !== "24px") throw new Error(`root font ${a.font}`)
  if (!a.transition.split(",").every((s) => parseFloat(s) < 0.001)) throw new Error(`transition ${a.transition}`)
  if (!/underline/.test(a.underline)) throw new Error(`links ${a.underline}`)
  console.log(`      root font ${a.font}, transitions ${a.transition}, muted text ${a.muted}`)
})
await step("captions: a `default` track only while the preference is on", async () => {
  const tracks = async () => {
    await open(p, "/adventures/l-atlas-celeste")
    await Promise.all([p.waitForURL(/\/learn\//, { timeout: T }), p.click('#chapters a:has-text("Lire le ciel de nuit")')])
    await connected(p)
    return p.evaluate(() => [...document.querySelectorAll("#lesson-video track")].map((t) => `${t.srclang}${t.default ? "*" : ""}`).join(","))
  }
  const on = await tracks()
  if (!/en\*/.test(on)) throw new Error(`on: ${on}`)
  await open(p, "/settings/accessibility")
  await p.uncheck("#a11y-captions")
  await p.click("#save-accessibility")
  await expectText(p, "#accessibility-status", /saved/)
  const off = await tracks()
  if (off.includes("*") || !off.includes("en")) throw new Error(`off: ${off}`)
  console.log(`      captions on: ${on} · off: ${off}`)
})
await step("text at 150 %: no horizontal scroll at 390 px on the main pages", async () => {
  const small = await newPage({ width: 390, timezoneId: "UTC" })
  await login(small, newbie.email, newbie.password)
  const paths = ["/dashboard", "/adventures", "/adventures/la-foret-des-murmures", "/community", "/friends", "/messages",
    "/achievements", "/membership", "/multiplayer", "/studio", "/settings", "/settings/preferences",
    "/settings/accessibility", "/settings/data", "/members/sarah_lefevre", `/members/${newbie.username}`,
    // section « Offline lessons »
    "/settings/offline"]
  const wide = []
  for (const path of paths) {
    await open(small, path)
    if ((await html(small, "data-text-size")) !== "150") throw new Error(`text size lost on ${path}`)
    const over = await small.evaluate(() => document.scrollingElement.scrollWidth - window.innerWidth)
    if (over > 1) wide.push(`${path} (+${over}px)`)
  }
  if (wide.length) throw new Error(wide.join(", "))
  console.log(`      ${paths.length} pages checked`)
})

const errors = pages.flatMap((pg) => pg.errors).filter((e) => !/favicon/i.test(e))
await step("no JavaScript / console error during the journeys", async () => {
  if (errors.length) throw new Error(errors.slice(0, 3).join(" | "))
})

await browser.close()
const failed = results.filter(([s]) => s === "✗").length
console.log(`\n${results.length - failed}/${results.length} checks passed`)
process.exit(failed ? 1 : 0)
