// Vérifications au clavier au-delà d'axe : focus, cibles, mouvement, espacement du texte, glisser-déposer, connexion.
// Usage : cd e2e && node keyboard.mjs   (ONLY=<regex d'étape>, BASE, CHROME, HEADED=1)
import {
  ADMIN, BASE, DEMO, MEMBER, MODERATOR, PUBLIC, T, allPages, connected, launch, login, logout, memberWithTwoFactor,
  newContext, newPage, openErrorPage, renderErrorPages, resolve, resolveAdmin, resolveMember, resolveVisitor, signUp,
  steps, totp, visit, waitText,
} from "./lib/audit.mjs"

const ONLY = process.env.ONLY ? new RegExp(process.env.ONLY) : null
const { step: runStep, summary } = steps()
const step = (name, fn) => (ONLY && !ONLY.test(name) ? null : runStep(name, fn))
const browser = await launch()
// Animations réduites par défaut : le défilement provoqué par le focus est instantané, la position mesurée après
// chaque Tab est donc la position finale (les vérifications du mouvement choisissent leur réglage elles-mêmes).
const ctx = (opts = {}) => newContext(browser, { reducedMotion: "reduce", ...opts })

// ───────────────────────────────────────────── outils dans la page
const FOCUSABLE = "a[href], area[href], button, input:not([type=hidden]), select, textarea, summary, iframe, video[controls], audio[controls], [tabindex], [contenteditable=''], [contenteditable=true]"
// contrôles qui doivent être atteints par Tab (visibles, actifs, hors tabindex=-1 ; un groupe radio compte une fois)
function focusables(selector) {
  const visible = (el) => {
    const r = el.getBoundingClientRect(), s = getComputedStyle(el)
    if (r.width <= 0 || r.height <= 0 || s.visibility !== "visible" || el.closest("[inert], [hidden]")) return false
    const details = el.closest("details:not([open])")
    return !details || (el.tagName === "SUMMARY" && el.parentElement === details)
  }
  const list = [...document.querySelectorAll(selector)].filter((el) => !el.disabled && el.tabIndex >= 0 && el.getAttribute("tabindex") !== "-1" && visible(el))
  list.forEach((el, i) => { el.__kbd = i })
  window.__kbdList = list
  const describe = (el) => `${el.tagName.toLowerCase()}${el.id ? `#${el.id}` : ""}${el.name ? `[name=${el.name}]` : ""} « ${(el.getAttribute("aria-label") || el.innerText || el.value || "").trim().replace(/\s+/g, " ").slice(0, 30)} »`
  return list.map((el) => ({ index: el.__kbd, radio: el.type === "radio" ? `${el.form?.id || ""}|${el.name}` : null, label: describe(el), positive: el.tabIndex > 0 }))
}
// état du focus : élément (index DOM), indicateur visible, caché par un autre élément
function focusState() {
  const el = document.activeElement
  if (!el || el === document.body || el === document.documentElement) return null
  const styles = (e) => [null, "::before", "::after"].map((p) => {
    const s = getComputedStyle(e, p)
    const outline = s.outlineStyle !== "none" && parseFloat(s.outlineWidth) > 0 && !/rgba\(0, 0, 0, 0\)|transparent/.test(s.outlineColor)
    return `${outline ? `${s.outlineStyle} ${s.outlineWidth} ${s.outlineColor}` : "-"}|${s.boxShadow}`
  })
  const chain = [el, el.parentElement, el.parentElement?.parentElement].filter(Boolean)
  window.__kbdLast = { el, chain, focused: chain.map(styles) }
  const r = el.getBoundingClientRect()
  const vw = innerWidth, vh = innerHeight
  const box = { l: Math.max(0, r.left), t: Math.max(0, r.top), r: Math.min(vw, r.right), b: Math.min(vh, r.bottom) }
  const opaque = (e) => /^(IMG|VIDEO|CANVAS|svg)$/.test(e.tagName) || [null, "::before", "::after"].some((p) => {
    const s = getComputedStyle(e, p)
    if (p && s.content === "none") return false
    return s.backgroundImage !== "none" || !/rgba\(0, 0, 0, 0\)|transparent/.test(s.backgroundColor) || s.backdropFilter !== "none"
  })
  let hidden = true, cover = null
  if (box.r - box.l >= 1 && box.b - box.t >= 1) {
    const points = [[0.5, 0.5], [0.15, 0.2], [0.85, 0.2], [0.15, 0.8], [0.85, 0.8]].map(([x, y]) => [box.l + (box.r - box.l) * x, box.t + (box.b - box.t) * y])
    for (const [x, y] of points) {
      let blocked = null
      for (const hit of document.elementsFromPoint(x, y)) {
        if (hit === el || el.contains(hit) || hit.contains(el)) break
        if (opaque(hit)) { blocked = hit; break }
      }
      if (!blocked) { hidden = false; break }
      cover = `${blocked.tagName.toLowerCase()}${blocked.id ? `#${blocked.id}` : ""}.${String(blocked.className).split(" ")[0]}`
    }
  }
  const label = `${el.tagName.toLowerCase()}${el.id ? `#${el.id}` : ""} « ${(el.getAttribute("aria-label") || el.innerText || el.value || "").trim().replace(/\s+/g, " ").slice(0, 30)} »`
  return { index: el.__kbd ?? -1, label, inMain: !!el.closest("main"), hidden, cover, skip: el.classList.contains("skip-link"), top: r.top }
}
// le dernier élément quitté : son style sans le focus (l'indicateur doit venir du focus)
function lastBlurred() {
  const last = window.__kbdLast
  if (!last) return null
  const styles = (e) => [null, "::before", "::after"].map((p) => {
    const s = getComputedStyle(e, p)
    const outline = s.outlineStyle !== "none" && parseFloat(s.outlineWidth) > 0 && !/rgba\(0, 0, 0, 0\)|transparent/.test(s.outlineColor)
    return `${outline ? `${s.outlineStyle} ${s.outlineWidth} ${s.outlineColor}` : "-"}|${s.boxShadow}`
  })
  const blurred = last.chain.map(styles)
  const visible = last.focused.some((list, i) => list.some((value, k) => value !== "-|none" && value !== blurred[i][k]))
  return { visible }
}

// Parcours de la page au clavier (Tab), depuis le haut du document : ordre, indicateur, recouvrement, piège.
async function tabWalk(page, { max = 400 } = {}) {
  const expected = await page.evaluate(focusables, FOCUSABLE)
  const seen = [], problems = []
  let first = null, mediaStops = 0
  for (let i = 0; i < max; i++) {
    await press(page, "Tab")
    // l'élément quitté (lu avant de noter le nouveau) : son indicateur venait-il du focus ? Sans objet s'il garde le
    // focus (commandes internes d'un média)
    const blurred = i > 0 ? await page.evaluate(lastBlurred) : null
    const state = await page.evaluate(focusState)
    const stay = state && seen.length && state.index >= 0 && state.index === seen[seen.length - 1].index
    if (blurred && !blurred.visible && !stay) problems.push(`focus invisible : ${seen[seen.length - 1].label}`)
    if (!state) return { seen, expected, problems, ended: true, first }
    if (first === null) first = state
    // Tab entre les commandes internes d'un média (shadow DOM du navigateur) : même élément hôte, on continue
    if (seen.length && state.index >= 0 && state.index === seen[seen.length - 1].index && /^(video|audio)/.test(state.label)) {
      if (++mediaStops > 12) { problems.push(`commandes de ${state.label} : plus de 12 arrêts (piège ?)`); return { seen, expected, problems, ended: false, first } }
      continue
    }
    if (seen.length && state.index >= 0 && seen.some((s) => s.index === state.index)) {
      if (state.index === seen[0].index) return { seen, expected, problems, ended: true, first }
      problems.push(`boucle de focus (piège) : retour sur ${state.label}`)
      return { seen, expected, problems, ended: false, first }
    }
    if (state.hidden) problems.push(`focus entièrement caché : ${state.label}${state.cover ? ` sous ${state.cover}` : " (hors de l'écran)"}`)
    seen.push(state)
  }
  problems.push(`plus de ${max} Tab sans sortir de la page (piège ?)`)
  return { seen, expected, problems, ended: false, first }
}
function walkProblems(walk, { skipLink = true } = {}) {
  const problems = [...walk.problems]
  const reached = new Set(walk.seen.map((s) => s.index))
  const radios = new Set(walk.expected.filter((e) => e.radio && reached.has(e.index)).map((e) => e.radio))
  const missed = walk.expected.filter((e) => !reached.has(e.index) && !(e.radio && radios.has(e.radio)))
  if (missed.length) problems.push(`non atteints par Tab : ${missed.slice(0, 4).map((e) => e.label).join(" ; ")}${missed.length > 4 ? ` (+${missed.length - 4})` : ""}`)
  const positive = walk.expected.filter((e) => e.positive)
  if (positive.length) problems.push(`tabindex positif : ${positive.map((e) => e.label).join(" ; ")}`)
  const order = walk.seen.map((s) => s.index).filter((i) => i >= 0)
  const back = order.findIndex((v, k) => k > 0 && v < order[k - 1])
  if (back > 0) problems.push(`ordre de tabulation différent de l'ordre du document : ${walk.seen.find((s) => s.index === order[back - 1]).label} → ${walk.seen.find((s) => s.index === order[back]).label}`)
  if (skipLink && !walk.first?.skip) problems.push(`premier Tab : ${walk.first?.label || "rien"} (lien d'évitement attendu)`)
  return problems
}
async function skipLinkWorks(page) {
  await press(page, "Tab")
  const skip = await page.evaluate(focusState)
  if (!skip?.skip) return `premier Tab : ${skip?.label || "rien"}`
  if (skip.hidden || skip.top < 0) return "lien d'évitement invisible au focus"
  await press(page, "Enter")
  await press(page, "Tab")
  const next = await page.evaluate(focusState)
  return next?.inMain ? null : `après le lien d'évitement, Tab mène à ${next?.label || "rien"} (hors du contenu)`
}
const fail = (problems) => { if (problems.length) throw new Error(problems.join("\n")) }
// après chaque touche, deux trames : le style du focus (transitions de 0,01 ms avec les animations réduites) est appliqué
const settle = (page) => page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))))
async function press(page, key) {
  await page.keyboard.press(key)
  await settle(page)
}

// ───────────────────────────────────────────── comptes et chemins
const errorPages = renderErrorPages(["en"])
const lyraCtx = await ctx()
const lea = await newPage(lyraCtx)
await login(lea, DEMO.lea)
const dyn = await resolveMember(lea)
const adminCtx = await ctx()
const clara = await newPage(adminCtx)
await login(clara, DEMO.clara)
const adminDyn = await resolveAdmin(clara)
const visitorCtx = await ctx()
const visitor = await newPage(visitorCtx)
const visitorDyn = await resolveVisitor(visitor)
const ALL = [
  ...PUBLIC.map((p) => ["visiteur", visitor, resolve(visitorDyn, p), p]),
  ...MEMBER.map((p) => ["membre", lea, resolve(dyn, p), p]),
  ...ADMIN.map((p) => ["admin", clara, resolve(adminDyn, p), p]),
].filter(([, , target]) => target)
console.log(`Vérifications au clavier, ${BASE}, ${ALL.length} pages`)

// ───────────────────────────────────────────── 1–2. clavier : pages clés
console.log("1. Clavier seul et focus visible : chaque contrôle des pages clés, dans l'ordre, sans piège ni focus caché")
const KEY_PAGES = [
  ["visiteur", visitor, "/"], ["visiteur", visitor, "/login"], ["visiteur", visitor, "/register"], ["visiteur", visitor, "/help"],
  ["visiteur", visitor, "/contact"], ["visiteur", visitor, "/community"],
  ["membre", lea, "/dashboard"], ["membre", lea, dyn.FORMAT_quiz], ["membre", lea, dyn.FORMAT_code], ["membre", lea, dyn.FORMAT_sequence],
  ["membre", lea, dyn.FORMAT_video], ["membre", lea, dyn.CONVERSATION], ["membre", lea, "/community/new"], ["membre", lea, dyn.DISCUSSION],
  ["membre", lea, "/settings/preferences"], ["membre", lea, "/settings/accessibility"], ["membre", lea, "/offline"], ["membre", lea, "/notifications"],
  ["admin", clara, "/admin"], ["admin", clara, "/admin/support?status=all"],
]
for (const width of [1280, 390]) {
  for (const [role, base, path] of KEY_PAGES) {
    if (width === 390 && !["/", "/login", "/dashboard", dyn.FORMAT_quiz, dyn.CONVERSATION, "/settings/preferences", "/admin"].includes(path)) continue
    await step(`${width} px — ${role} ${path} : tous les contrôles au clavier, ordre du document, focus visible et non caché`, async () => {
      await base.setViewportSize({ width, height: 900 })
      await visit(base, path, { wait: "networkidle" })
      const walk = await tabWalk(base)
      fail(walkProblems(walk))
      console.log(`      ${walk.seen.length} arrêts de tabulation, ${walk.expected.length} contrôles attendus`)
    })
  }
}
await lea.setViewportSize({ width: 1280, height: 900 })
await clara.setViewportSize({ width: 1280, height: 900 })
await visitor.setViewportSize({ width: 1280, height: 900 })
await step("lien d'évitement : premier Tab, visible, puis Tab mène dans le contenu (visiteur, membre, staff, page d'erreur)", async () => {
  const problems = []
  for (const [page, path] of [[visitor, "/"], [visitor, "/login"], [lea, "/dashboard"], [lea, dyn.CONVERSATION], [clara, "/admin"], [clara, "/admin/members"]]) {
    await visit(page, path)
    const problem = await skipLinkWorks(page)
    if (problem) problems.push(`${path} : ${problem}`)
  }
  await openErrorPage(visitor, errorPages["en:404"], "404")
  const problem = await skipLinkWorks(visitor)
  if (problem) problems.push(`page 404 : ${problem}`)
  fail(problems)
})

// ───────────────────────────────────────────── parcours au clavier seul
console.log("   parcours au clavier seul (aucun clic)")
// Tab jusqu'à l'élément voulu (sélecteur CSS, ou { text } : bouton du contenu portant ce texte), sinon il n'est pas
// atteignable au clavier
async function tabTo(page, target, max = 150) {
  for (let i = 0; i < max; i++) {
    const found = await page.evaluate((t) => {
      const el = document.activeElement
      if (!el) return false
      return typeof t === "string" ? el.matches(t) : el.tagName === "BUTTON" && !!el.closest("main") && el.innerText.trim() === t.text
    }, target)
    if (found) return
    await page.keyboard.press("Tab")
  }
  throw new Error(`${typeof target === "string" ? target : target.text} non atteint en ${max} Tab`)
}
const focusedId = (page) => page.evaluate(() => document.activeElement?.id || document.activeElement?.tagName)

let newbie
await step("connexion au clavier : lien d'évitement, e-mail, mot de passe, Entrée → tableau de bord", async () => {
  const c = await ctx()
  const p = await newPage(c)
  await visit(p, "/login")
  const problem = await skipLinkWorks(p)
  if (problem) throw new Error(problem)
  await tabTo(p, '#login-form input[name="user[email]"]')
  await p.keyboard.type(DEMO.hugo)
  await p.keyboard.press("Tab")
  await p.keyboard.type(process.env.DEMO_PASSWORD || "mystic-demo-pass-1")
  await Promise.all([p.waitForURL(/\/dashboard/, { timeout: T }), p.keyboard.press("Enter")])
  await c.close()
})
await step("leçon au clavier : choix par flèches et Espace, « Check » par Entrée, résultat annoncé sans perdre le focus", async () => {
  const c = await ctx()
  const p = await newPage(c)
  newbie = await signUp(p, "keys")
  await visit(p, dyn.FORMAT_quiz)
  await tabTo(p, "#quiz-form input[type=radio]")
  await p.keyboard.press("Space")
  if (!(await p.evaluate(() => document.activeElement.checked))) throw new Error("Space didn't select the choice")
  await p.keyboard.press("ArrowDown")
  if (!(await p.evaluate(() => document.activeElement.checked && document.activeElement.type === "radio"))) throw new Error("arrow keys don't move in the choices")
  await tabTo(p, "#check-answer")
  await p.keyboard.press("Enter")
  await p.waitForFunction(() => document.querySelector("#lesson-result")?.innerText.trim(), null, { timeout: T })
  const live = await p.evaluate(() => !!document.querySelector("#lesson-result").closest("[aria-live], [role=status], [role=alert]"))
  if (!live) throw new Error("the result isn't in a live region")
  const id = await focusedId(p)
  if (!["check-answer", "next-lesson"].includes(id) && !(await p.evaluate(() => document.activeElement.closest("#lesson-result, #quiz-form, main")))) throw new Error(`focus lost (${id})`)
  await c.close()
})
await step("message au clavier : zone de saisie, texte, « Send » par Entrée, message affiché", async () => {
  await visit(lea, dyn.CONVERSATION)
  await tabTo(lea, "#composer textarea")
  const text = `Keyboard only ${Date.now().toString(36)}`
  await lea.keyboard.type(text)
  await tabTo(lea, "#send-message")
  await lea.keyboard.press("Enter")
  await waitText(lea, "#messages", new RegExp(text))
})
await step("sujet de forum au clavier : catégorie (saisie au clavier), titre, texte, publication par Entrée", async () => {
  const c = await ctx()
  const p = await newPage(c)
  await login(p, DEMO.hugo)
  await visit(p, "/community/new")
  await tabTo(p, "#discussion_category")
  await p.keyboard.type("Help")
  if (!(await p.evaluate(() => document.querySelector("#discussion_category").value))) throw new Error("no category chosen with the keyboard")
  await tabTo(p, "#discussion_title")
  await p.keyboard.type(`Keyboard topic ${Date.now().toString(36)}`)
  await tabTo(p, "#discussion_body")
  await p.keyboard.type("Written and published with the keyboard only.")
  await tabTo(p, "#save-discussion")
  await Promise.all([p.waitForURL(/\/community\/discussions\//, { timeout: T }), p.keyboard.press("Enter")])
  await c.close()
})
await step("paramètres au clavier : case cochée par Espace, « Save » par Entrée, statut annoncé, focus gardé", async () => {
  const c = await ctx()
  const p = await newPage(c)
  await login(p, newbie.email, newbie.password)
  await visit(p, "/settings/accessibility")
  await tabTo(p, "#a11y-underline-links")
  await p.keyboard.press("Space")
  await tabTo(p, "#save-accessibility")
  await p.keyboard.press("Enter")
  await waitText(p, "#accessibility-status", /saved/)
  if ((await focusedId(p)) !== "save-accessibility") throw new Error(`focus moved to ${await focusedId(p)}`)
  if ((await p.getAttribute("html", "data-links")) !== "underline") throw new Error("preference not applied")
  await c.close()
})
await step("page hors ligne au clavier (sans réseau) : ouvrir la leçon, choisir, mettre la réponse en attente", async () => {
  const c = await ctx()
  const p = await newPage(c)
  await login(p, DEMO.lea)
  await visit(p, dyn.PREMIUM_LESSON)
  await p.waitForSelector("#offline-download:not([disabled])", { timeout: T })
  await tabTo(p, "#offline-download")
  await p.keyboard.press("Enter")
  await p.waitForSelector("#offline-open:not([hidden])", { timeout: T })
  await visit(p, "/dashboard")
  await p.waitForFunction(() => navigator.serviceWorker?.controller, null, { timeout: T })
  await c.setOffline(true)
  try {
    await p.goto(`${BASE}/offline`)
    await p.waitForSelector("#offline-list li", { timeout: T })
    await tabTo(p, "#offline-list a")
    await Promise.all([p.waitForSelector("#offline-quiz-form", { timeout: T }), p.keyboard.press("Enter")])
    await tabTo(p, "#offline-quiz-form input[type=radio]")
    await p.keyboard.press("Space")
    await tabTo(p, "#offline-save-answer")
    await p.keyboard.press("Enter")
    await p.waitForSelector("#offline-lesson-pending", { timeout: T })
    const live = await p.evaluate(() => !!document.querySelector("#offline-lesson-status")?.closest("[aria-live], [role=status], [role=alert]"))
    if (!live) throw new Error("the pending status isn't announced (no live region)")
  } finally {
    // rien n'est synchronisé : la réponse est retirée de la file avant le retour du réseau
    await p.evaluate(() => new Promise((r) => { const o = indexedDB.open("mysticlore-offline"); o.onsuccess = () => { const tx = o.result.transaction("queue", "readwrite"); tx.objectStore("queue").clear(); tx.oncomplete = () => { o.result.close(); r() } }; o.onerror = () => r() })).catch(() => {})
    await c.setOffline(false)
    await c.close()
  }
})
await step("dialogue du studio : ouvert au clavier, focus dedans, Tab reste dedans, Échap le ferme, focus rendu au déclencheur", async () => {
  await visit(lea, `${dyn.PROJECT}?step=outline`)
  await tabTo(lea, "#ai-outline")
  await lea.keyboard.press("Enter")
  await lea.waitForSelector("#confirm-generation", { timeout: T })
  await lea.waitForFunction(() => document.activeElement?.closest("#confirm-generation"), null, { timeout: T })
  // modale native : après son dernier contrôle, Tab passe par l'interface du navigateur (focus sur <body>) puis revient
  // au premier ; il n'atteint jamais la page derrière (inerte)
  for (let i = 0; i < 12; i++) {
    await press(lea, "Tab")
    if (!(await lea.evaluate(() => document.activeElement === document.body || document.activeElement?.closest("#confirm-generation"))))
      throw new Error(`Tab reaches the page behind the modal dialog (${await focusedId(lea)})`)
  }
  await lea.keyboard.press("Escape")
  await lea.waitForSelector("#confirm-generation", { state: "detached", timeout: T })
  await lea.waitForFunction(() => document.activeElement?.id === "ai-outline", null, { timeout: 5_000 }).catch(async () => { throw new Error(`focus after Escape: ${await focusedId(lea)}`) })
})
await step("menu « More » (390 px) : ouvert par Entrée, Tab entre dans le menu, Échap le ferme, focus rendu au bouton", async () => {
  const c = await ctx({ width: 390 })
  const p = await newPage(c)
  await login(p, DEMO.lea)
  await tabTo(p, "button[popovertarget=more-menu]")
  await p.keyboard.press("Enter")
  await p.waitForSelector("#more-menu:popover-open", { timeout: T })
  await p.keyboard.press("Tab")
  if (!(await p.evaluate(() => document.activeElement?.closest("#more-menu")))) throw new Error(`Tab after opening: ${await focusedId(p)}`)
  await p.keyboard.press("Escape")
  await p.waitForSelector("#more-menu:not(:popover-open)", { state: "attached", timeout: T })
  if (!(await p.evaluate(() => document.activeElement?.matches("button[popovertarget=more-menu]")))) throw new Error(`focus after Escape: ${await focusedId(p)}`)
  await c.close()
})
await step("formulaire de signalement : ouvert au clavier (focus dedans), « Cancel » rend le focus au bouton « Report »", async () => {
  await visit(lea, "/members/hugo_bernard")
  await tabTo(lea, { text: "Report" })
  await lea.keyboard.press("Enter")
  await lea.waitForSelector("#report-panel", { timeout: T })
  await lea.waitForFunction(() => document.activeElement?.closest("#report-panel"), null, { timeout: T })
  await tabTo(lea, "#report-panel button[phx-click=cancel_report]")
  await lea.keyboard.press("Enter")
  await lea.waitForSelector("#report-panel", { state: "detached", timeout: T })
  await lea.waitForFunction(() => document.activeElement?.tagName === "BUTTON" && document.activeElement.innerText.trim() === "Report", null, { timeout: 5_000 })
    .catch(async () => { throw new Error(`focus after Cancel: ${await focusedId(lea)}`) })
})

// ───────────────────────────────────────────── 3. taille des cibles
console.log("3. Taille des cibles (2.5.8) : ≥ 24 × 24 px, ou cercle de 24 px sans autre cible ; liens dans le texte exceptés")
function smallTargets() {
  const sel = "a[href], button, input:not([type=hidden]), select, textarea, summary, [role=button], [role=link], [role=checkbox], [role=radio], [role=tab], [role=menuitem], [role=switch]"
  const visible = (el) => { const r = el.getBoundingClientRect(), s = getComputedStyle(el); return r.width > 0 && r.height > 0 && s.visibility === "visible" && !el.closest("[hidden], [inert]") && Number(s.opacity) > 0 }
  const targets = [...document.querySelectorAll(sel)].filter((el) => visible(el) && !el.disabled && !el.closest(".sr-only"))
  // une case à cocher ou un bouton radio : sa zone comprend son libellé
  const rect = (el) => {
    let r = el.getBoundingClientRect(), box = { l: r.left, t: r.top, r: r.right, b: r.bottom }
    if (/^(checkbox|radio)$/.test(el.type)) for (const label of el.labels || []) { const lr = label.getBoundingClientRect(); box = { l: Math.min(box.l, lr.left), t: Math.min(box.t, lr.top), r: Math.max(box.r, lr.right), b: Math.max(box.b, lr.bottom) } }
    return box
  }
  // lien dans une phrase : contraint par la hauteur de ligne du texte (exception de 2.5.8)
  const inline = (el) => el.tagName === "A" && getComputedStyle(el).display === "inline" && [...el.parentElement.childNodes].some((n) => n !== el && n.nodeType === 3 && n.textContent.trim())
  const boxes = targets.map((el) => ({ el, box: rect(el) }))
  const problems = []
  for (const { el, box } of boxes) {
    const w = box.r - box.l, h = box.b - box.t
    if ((w >= 24 && h >= 24) || inline(el)) continue
    // vidéo et contrôles natifs du navigateur : exception « contrôle de l'agent utilisateur »
    if (el.tagName === "VIDEO") continue
    const cx = (box.l + box.r) / 2, cy = (box.t + box.b) / 2
    const clash = boxes.find(({ el: other, box: o }) => {
      if (other === el || other.contains(el) || el.contains(other)) return false
      const nx = Math.max(o.l, Math.min(cx, o.r)), ny = Math.max(o.t, Math.min(cy, o.b))
      if (Math.hypot(nx - cx, ny - cy) < 12) return true
      const ow = o.r - o.l, oh = o.b - o.t
      return (ow < 24 || oh < 24) && Math.hypot((o.l + o.r) / 2 - cx, (o.t + o.b) / 2 - cy) < 24
    })
    if (clash) problems.push(`${el.tagName.toLowerCase()}${el.id ? `#${el.id}` : ""} « ${(el.getAttribute("aria-label") || el.innerText || "").trim().slice(0, 24)} » ${Math.round(w)}×${Math.round(h)} près de ${clash.el.tagName.toLowerCase()}${clash.el.id ? `#${clash.el.id}` : ""}`)
  }
  return problems
}
for (const width of [390, 1280]) {
  await step(`${width} px : toutes les pages (${ALL.length}) — cibles assez grandes ou assez espacées`, async () => {
    const problems = []
    for (const [role, page, target, path] of ALL) {
      await page.setViewportSize({ width, height: 900 })
      await visit(page, target, { wait: "networkidle" })
      for (const p of await page.evaluate(smallTargets)) problems.push(`${role} ${path} : ${p}`)
    }
    fail(problems.slice(0, 12).concat(problems.length > 12 ? [`(+${problems.length - 12})`] : []))
  })
}
for (const page of [lea, clara, visitor]) await page.setViewportSize({ width: 1280, height: 900 })

// ───────────────────────────────────────────── 4. mouvement
console.log("4. Mouvement : prefers-reduced-motion et préférence « animations réduites »")
const motion = () => {
  const long = [...document.querySelectorAll("*")].filter((el) => {
    const s = getComputedStyle(el)
    const max = (v) => Math.max(...v.split(",").map((x) => parseFloat(x) * (x.trim().endsWith("ms") ? 0.001 : 1)))
    return (s.animationName !== "none" && max(s.animationDuration) > 0.01) || max(s.transitionDuration) > 0.01
  }).slice(0, 3).map((el) => `${el.tagName.toLowerCase()}.${String(el.className).split(" ")[0]}`)
  return { long, scroll: getComputedStyle(document.documentElement).scrollBehavior, topbar: [...document.querySelectorAll("body > canvas")].some((c) => c.style.display !== "none") }
}
await step("appareil en « mouvement réduit » : aucune animation ni transition, défilement instantané, pas de barre animée", async () => {
  const c = await ctx({ reducedMotion: "reduce" })
  const p = await newPage(c)
  await login(p, newbie.email, newbie.password)
  // une première leçon terminée : le gain d'XP est animé (xp-pop) quand le mouvement n'est pas réduit
  await visit(p, dyn.LESSON)
  await p.click("#complete-lesson")
  await p.waitForSelector(".xp-gain", { timeout: T })
  const problems = []
  for (const path of ["/dashboard", dyn.LESSON, "/messages", "/community"]) {
    if (path !== dyn.LESSON) {
      // navigation LiveView (la barre de progression n'apparaît pas)
      await Promise.all([p.waitForURL((u) => u.pathname === path.split("?")[0], { timeout: T }), p.evaluate((h) => window.liveSocket.js().navigate(h), path).catch(() => p.goto(BASE + path))])
      await connected(p)
    }
    const m = await p.evaluate(motion)
    if (m.long.length) problems.push(`${path} : ${m.long.join(", ")}`)
    if (m.scroll !== "auto") problems.push(`${path} : scroll-behavior ${m.scroll}`)
    if (m.topbar) problems.push(`${path} : barre de progression animée affichée`)
  }
  fail(problems)
  await c.close()
})
await step("préférence « animations réduites » du membre (appareil sans réglage) : même effet", async () => {
  const c = await ctx({ reducedMotion: "no-preference" })
  const p = await newPage(c)
  await login(p, newbie.email, newbie.password)
  await visit(p, "/dashboard")
  const before = await p.evaluate(motion)
  if (!before.long.length) throw new Error("no animation even without the preference: the check proves nothing")
  await p.evaluate(() => document.documentElement.setAttribute("data-motion", "reduce"))
  const after = await p.evaluate(motion)
  if (after.long.length || after.scroll !== "auto") throw new Error(JSON.stringify(after))
  await c.close()
})

// ───────────────────────────────────────────── 5. espacement du texte, zoom
console.log("5. Mise en page : espacement du texte (1.4.12), zoom 200 % (1.4.4) ; reflow à 320 px : responsive.mjs")
const SPACING = "* { line-height: 1.5 !important; letter-spacing: 0.12em !important; word-spacing: 0.16em !important; } p { margin-bottom: 2em !important; }"
function clipped() {
  const out = []
  for (const el of document.querySelectorAll("body *")) {
    const s = getComputedStyle(el), r = el.getBoundingClientRect()
    if (r.width <= 1 || r.height <= 1 || el.closest(".sr-only, [hidden]") || s.visibility !== "visible") continue
    // aperçus tronqués par conception (dernier message d'une conversation, extrait d'une discussion) : le texte
    // entier est sur la page ouverte par le lien
    if (el.matches(".conversation-preview, .discussion-card-excerpt")) continue
    const clipX = /hidden|clip/.test(s.overflowX), clipY = /hidden|clip/.test(s.overflowY)
    if (!clipX && !clipY && s.webkitLineClamp === "none") continue
    if (!el.innerText?.trim()) continue
    if ((clipX && el.scrollWidth > el.clientWidth + 1) || ((clipY || s.webkitLineClamp !== "none") && el.scrollHeight > el.clientHeight + 1))
      out.push(`${el.tagName.toLowerCase()}${el.id ? `#${el.id}` : ""}.${String(el.className).split(" ").slice(0, 2).join(".")} « ${el.innerText.trim().replace(/\s+/g, " ").slice(0, 30)} »`)
  }
  return { clipped: out, overflow: document.scrollingElement.scrollWidth - innerWidth }
}
async function withSheet(page, css) {
  await page.evaluate((rules) => { const s = new CSSStyleSheet(); s.replaceSync(rules); document.adoptedStyleSheets = [...document.adoptedStyleSheets, s] }, css)
  await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))))
}
for (const width of [390, 1280]) {
  await step(`espacement du texte à ${width} px (interligne 1,5, lettres 0,12 em, mots 0,16 em, paragraphes 2 em) : rien de rogné, pas de défilement horizontal`, async () => {
    const problems = []
    for (const [role, page, target, path] of ALL) {
      await page.setViewportSize({ width, height: 900 })
      await visit(page, target, { wait: "networkidle" })
      const before = await page.evaluate(clipped)
      await withSheet(page, SPACING)
      const after = await page.evaluate(clipped)
      const added = after.clipped.filter((c) => !before.clipped.includes(c))
      if (added.length) problems.push(`${role} ${path} : texte rogné ${added.slice(0, 2).join(" ; ")}`)
      if (after.overflow > 1) problems.push(`${role} ${path} : défilement horizontal +${after.overflow}px`)
    }
    fail(problems.slice(0, 15).concat(problems.length > 15 ? [`(+${problems.length - 15})`] : []))
  })
}
for (const page of [lea, clara, visitor]) await page.setViewportSize({ width: 1280, height: 900 })
await step(`zoom 200 % (fenêtre de 1280 px : 640 px CSS, densité 2) : toutes les pages, sans défilement horizontal ni texte rogné`, async () => {
  const problems = []
  const contexts = {
    visiteur: await newPage(await ctx({ width: 640, height: 450, deviceScaleFactor: 2 })),
    membre: await newPage(await ctx({ width: 640, height: 450, deviceScaleFactor: 2 })),
    admin: await newPage(await ctx({ width: 640, height: 450, deviceScaleFactor: 2 })),
  }
  await login(contexts.membre, DEMO.lea)
  await login(contexts.admin, DEMO.clara)
  for (const [role, , target, path] of ALL) {
    const page = contexts[role]
    await visit(page, target, { wait: "networkidle" })
    const info = await page.evaluate(clipped)
    if (info.overflow > 1) problems.push(`${role} ${path} : défilement horizontal +${info.overflow}px`)
  }
  for (const page of Object.values(contexts)) await page.context().close()
  fail(problems)
})
// Texte seul à 200 % : relevé pour information, WCAG 1.4.4 étant déjà satisfait par le zoom de la page.
{
  const wide = []
  for (const [role, page, target, path] of ALL) {
    await visit(page, target, { wait: "networkidle" })
    await withSheet(page, "html { font-size: 200% !important; }")
    const info = await page.evaluate(clipped)
    if (info.overflow > 1) wide.push(`${role} ${path} (+${info.overflow}px)`)
  }
  console.log(`  ℹ texte seul à 200 % (information, non bloquant) : ${wide.length ? `défilement horizontal sur ${wide.join(", ")}` : "aucun défilement horizontal"}`)
}

// ───────────────────────────────────────────── 6. glisser-déposer
console.log("6. Glisser-déposer (2.5.7) : aucune action par glissement ; mini-jeux et listes au clic ou au clavier")
await step("aucun élément déplaçable ; une zone de dépôt de fichier a toujours son champ « choisir un fichier »", async () => {
  const problems = []
  let zones = 0
  for (const [role, page, target, path] of ALL) {
    await visit(page, target)
    const found = await page.evaluate(() => ({
      draggable: document.querySelectorAll("[draggable=true], [ondragstart], [ondrop]").length,
      // dépôt de fichiers (LiveView) : le champ de fichier du même formulaire est l'alternative sans glissement
      zones: [...document.querySelectorAll("[phx-drop-target]")].map((zone) => {
        const input = document.getElementById(zone.getAttribute("phx-drop-target"))
        return !!input && input.type === "file" && !input.disabled
      }),
    }))
    zones += found.zones.length
    if (found.draggable) problems.push(`${role} ${path} : ${found.draggable} élément(s) déplaçable(s)`)
    if (found.zones.includes(false)) problems.push(`${role} ${path} : zone de dépôt sans champ de fichier`)
  }
  // les scripts de l'application (hors LiveView, dont les zones de dépôt sont vérifiées ci-dessus) n'écoutent aucun glissement
  const js = await (await visitor.request.get(`${BASE}/assets/js/app.js`)).text()
  for (const api of ["dragstart", "dragover", "pointermove", "touchmove"]) {
    const uses = (js.match(new RegExp(api, "g")) || []).length
    if (uses && api !== "dragover") problems.push(`app.js écoute ${api} (${uses})`)
  }
  fail(problems)
  console.log(`      0 élément déplaçable ; ${zones} zone(s) de dépôt, chacune avec son champ de fichier`)
})
await step("mini-jeu « ordre » : un élément déplacé par le bouton « Move down » au clavier (Entrée), le focus le suit", async () => {
  const c = await ctx()
  const p = await newPage(c)
  await login(p, newbie.email, newbie.password)
  await visit(p, dyn.FORMAT_sequence)
  const order = () => p.$$eval("#sequence-list li", (lis) => lis.map((li) => li.id))
  const before = await order()
  await tabTo(p, "#sequence-list button:not([disabled])")
  const label = await p.evaluate(() => document.activeElement.innerText + (document.activeElement.getAttribute("aria-label") || ""))
  await p.keyboard.press("Enter")
  await p.waitForFunction((b) => [...document.querySelectorAll("#sequence-list li")].map((li) => li.id).join() !== b.join(), before, { timeout: T })
  if (!(await p.evaluate(() => document.activeElement?.closest("#sequence-list")))) throw new Error(`focus lost after the move (${label})`)
  await c.close()
})

// ───────────────────────────────────────────── 7. authentification
console.log("7. Authentification accessible (3.3.8) : collage permis, saisie automatique, aucune énigme")
const AUTH_FIELDS = "input[type=password], input[autocomplete=one-time-code], input[name*=one_time_password], input[type=email]"
async function pasteCheck(page, where) {
  const problems = []
  const fields = await page.$$(AUTH_FIELDS)
  if (!fields.length) return [`${where} : aucun champ d'authentification`]
  for (const field of fields) {
    if (!(await field.isVisible())) continue
    const info = await field.evaluate((el) => {
      el.value = ""
      el.focus()
      const data = new DataTransfer()
      data.setData("text/plain", "Pasted-Secret-123456")
      const event = new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true })
      const allowed = el.dispatchEvent(event)
      return { name: el.name || el.id, allowed, autocomplete: el.getAttribute("autocomplete"), type: el.type }
    })
    if (!info.allowed) problems.push(`${where} ${info.name} : collage bloqué`)
    // le gestionnaire de mots de passe doit pouvoir remplir le champ
    if (!info.autocomplete || /^off$/i.test(info.autocomplete)) problems.push(`${where} ${info.name} : autocomplete ${info.autocomplete}`)
  }
  // un vrai collage par le presse-papiers (Meta/Ctrl+V) dans le premier champ de mot de passe
  const password = await page.$("input[type=password], input[autocomplete=one-time-code]")
  if (password) {
    await password.fill("")
    await password.focus()
    await page.evaluate(() => navigator.clipboard.writeText("Pasted-Secret-123456"))
    await page.keyboard.press("ControlOrMeta+V")
    if ((await password.inputValue()) !== "Pasted-Secret-123456") problems.push(`${where} : le collage au clavier n'a rien saisi`)
  }
  const puzzle = await page.evaluate(() => [...document.querySelectorAll("iframe, img, canvas, [class*=captcha], [id*=captcha]")].filter((e) => /captcha|recaptcha|hcaptcha|puzzle/i.test(e.outerHTML)).length)
  if (puzzle) problems.push(`${where} : énigme ou CAPTCHA présent`)
  return problems
}
await step("connexion, inscription, mot de passe oublié et réinitialisation, double authentification : collage permis et saisie automatique", async () => {
  const c = await ctx({ permissions: ["clipboard-read", "clipboard-write"] })
  const p = await newPage(c)
  const problems = []
  for (const path of ["/login", "/register", "/forgot-password"]) {
    await visit(p, path)
    problems.push(...(await pasteCheck(p, path)))
  }
  // compte neuf avec la double authentification : la page du code
  const member = await memberWithTwoFactor(p)
  await logout(p)
  await visit(p, "/login")
  await p.fill('#login-form input[name="user[email]"]', member.email)
  await p.fill('#login-form input[name="user[password]"]', member.password)
  await Promise.all([p.waitForURL(/\/login\/2fa/, { timeout: T }), p.click('#login-form button[type="submit"]')])
  problems.push(...(await pasteCheck(p, "/login/2fa")))
  // un code collé suffit à se connecter (aucune autre épreuve) : un code de secours (le code TOTP de cette fenêtre de
  // 30 s vient de servir à activer la double authentification, il ne vaut qu'une fois)
  await p.fill("#two-factor-form input[name*=one_time_password]", "")
  await p.evaluate((code) => navigator.clipboard.writeText(code), member.recovery)
  await p.focus("#two-factor-form input[name*=one_time_password]")
  await p.keyboard.press("ControlOrMeta+V")
  await Promise.all([p.waitForURL(/\/(dashboard|welcome)/, { timeout: T }), p.keyboard.press("Enter")])
  await visit(p, "/settings/account")
  problems.push(...(await pasteCheck(p, "/settings/account")))
  fail(problems)
  await c.close()
})

// ───────────────────────────────────────────── 8. aide cohérente
console.log("8. Aide cohérente (3.2.6) : le lien d'aide au même endroit relatif sur toutes les pages")
function helpPosition() {
  const shell = [...document.querySelectorAll("a[href], button")].filter((el) => !el.closest("main") && el.getBoundingClientRect().width > 0 && !el.closest("[hidden]"))
  const help = shell.findIndex((el) => /^\/help$/.test(el.getAttribute("href") || ""))
  if (help < 0) return null
  const key = (el) => el?.id || el?.getAttribute("href") || el?.getAttribute("popovertarget") || el?.tagName
  return `${key(shell[help - 1])} → [${key(shell[help])}] → ${key(shell[help + 1])}`
}
for (const width of [1280, 390]) {
  await step(`${width} px : un lien d'aide hors du contenu, à la même place dans chaque gabarit (visiteur, membre, staff, erreur)`, async () => {
    const positions = new Map(), problems = []
    // gabarits : pages publiques, pages de membre, pages du staff, page hors ligne (document à part, sans LiveView)
    const shellOf = (role, target) => (/^\/admin/.test(target) ? "staff" : /^\/offline/.test(target) ? "hors ligne" : role)
    for (const [role, page, target, path] of ALL) {
      await page.setViewportSize({ width, height: 900 })
      await visit(page, target)
      if (width === 390 && role !== "visiteur") {
        // barre mobile : l'aide est dans le menu « More »
        const more = page.locator("button[popovertarget=more-menu]")
        if (await more.count()) await more.click()
      }
      const position = await page.evaluate(helpPosition)
      const shell = shellOf(role, target)
      if (!position) { problems.push(`${role} ${path} : pas de lien d'aide`); continue }
      if (!positions.has(shell)) positions.set(shell, new Map())
      const list = positions.get(shell)
      list.set(position, [...(list.get(position) || []), path])
    }
    for (const [shell, list] of positions) if (list.size > 1) problems.push(`${shell} : ${[...list].map(([pos, paths]) => `${pos} (${paths.slice(0, 2).join(", ")}${paths.length > 2 ? `…+${paths.length - 2}` : ""})`).join(" ≠ ")}`)
    await openErrorPage(visitor, errorPages["en:404"], "404")
    if (!(await visitor.evaluate(() => !!document.querySelector("a[href='/help']")))) problems.push("page d'erreur : pas de lien d'aide")
    fail(problems)
    console.log(`      ${[...positions].map(([shell, list]) => `${shell} : ${[...list.keys()][0]}`).join(" · ")}`)
  })
}
for (const page of [lea, clara, visitor]) await page.setViewportSize({ width: 1280, height: 900 })

// ───────────────────────────────────────────── 9. messages de statut
console.log("9. Messages de statut (4.1.3) : dans une zone live présente avant le message, sans déplacer le focus")
async function statusCheck(page, label, act, messageSelector) {
  await page.evaluate(() => { window.__liveBefore = new Set(document.querySelectorAll("[aria-live], [role=status], [role=alert], [role=log]")) })
  const before = await page.evaluate(() => document.activeElement)
  await act()
  await page.waitForFunction((s) => { const e = document.querySelector(s); return e && e.innerText.trim() }, messageSelector, { timeout: T })
  const result = await page.evaluate(([s]) => {
    const el = document.querySelector(s)
    const region = el.closest("[aria-live], [role=status], [role=alert], [role=log]")
    return { region: region ? `${region.tagName.toLowerCase()}#${region.id}` : null, existed: !!region && [...window.__liveBefore].some((r) => r === region || r.contains(region)), focus: document.activeElement?.id || document.activeElement?.tagName }
  }, [messageSelector])
  const problems = []
  if (!result.region) problems.push(`${label} : message hors d'une zone live`)
  else if (!result.existed) problems.push(`${label} : zone live ${result.region} créée avec le message (annonce peu fiable)`)
  return { problems, focus: result.focus, before }
}
await step("enregistrement des paramètres, recherche de l'aide, réponse d'un quiz, copie hors ligne, toast, bandeau hors ligne", async () => {
  const problems = []
  const c = await ctx()
  const p = await newPage(c)
  await login(p, newbie.email, newbie.password)
  // paramètres : le bouton garde le focus
  await visit(p, "/settings/accessibility")
  await p.focus("#save-accessibility")
  let r = await statusCheck(p, "paramètres", () => p.keyboard.press("Enter"), "#accessibility-status")
  problems.push(...r.problems)
  if (r.focus !== "save-accessibility") problems.push(`paramètres : focus déplacé vers ${r.focus}`)
  // aide : le champ de recherche garde le focus
  await visit(p, "/help")
  await p.focus("#help-q")
  await p.keyboard.type("password")
  r = await statusCheck(p, "aide", () => p.keyboard.press("Enter"), "#help-results-status")
  problems.push(...r.problems)
  // quiz
  await visit(p, dyn.FORMAT_quiz)
  await p.check("#quiz-form input[type=radio] >> nth=0")
  await p.focus("#check-answer")
  r = await statusCheck(p, "quiz", () => p.keyboard.press("Enter"), "#lesson-result")
  problems.push(...r.problems)
  // toast de notification (Hugo écrit à Léa)
  await visit(lea, "/dashboard")
  const hugo = await newPage(await ctx())
  await login(hugo, DEMO.hugo)
  await visit(hugo, "/messages")
  await visit(hugo, await hugo.$eval('#conversations a:has-text("Léa Moreau")', (a) => a.getAttribute("href")))
  await lea.evaluate(() => { window.__liveBefore = new Set(document.querySelectorAll("[aria-live], [role=status], [role=alert], [role=log]")) })
  await hugo.fill("#composer textarea", `Status check ${Date.now().toString(36)}`)
  await hugo.click("#send-message")
  await lea.waitForSelector("#notification-toast", { timeout: T })
  const toast = await lea.evaluate(() => { const region = document.querySelector("#notification-toast").closest("[aria-live], [role=status]"); return region && [...window.__liveBefore].includes(region) })
  if (!toast) problems.push("toast : zone live absente avant le toast")
  await hugo.context().close()
  // bandeau hors ligne
  await visit(p, "/settings/preferences")
  await p.focus("#save-language")
  r = await statusCheck(p, "bandeau hors ligne", () => c.setOffline(true), "#connection-status-text")
  problems.push(...r.problems)
  if (r.focus !== "save-language") problems.push(`bandeau hors ligne : focus déplacé vers ${r.focus}`)
  await c.setOffline(false)
  await c.close()
  fail(problems)
})
await step("erreurs d'un formulaire LiveView : annoncées (zone live ou focus sur le premier champ en erreur)", async () => {
  const c = await ctx()
  const p = await newPage(c)
  await login(p, newbie.email, newbie.password)
  await visit(p, "/community/new")
  await p.fill("#discussion_title", "ab")
  // après la saisie (une LiveView qui rend de nouveau le formulaire remettrait la validation du navigateur)
  await p.$eval("#discussion-form", (f) => { f.noValidate = true })
  await p.focus("#save-discussion")
  await p.keyboard.press("Enter")
  await p.waitForSelector("#discussion-form .field-error", { timeout: T })
  // la réponse du serveur à l'envoi (pas seulement une erreur montrée pendant la saisie) : jusqu'à 5 s
  const state = () => p.evaluate(() => ({
    focusInvalid: document.activeElement?.getAttribute("aria-invalid") === "true",
    live: !!document.querySelector("#discussion-form .field-error")?.closest("[aria-live], [role=status], [role=alert]"),
    focus: document.activeElement?.id,
  }))
  await p.waitForFunction(() => document.activeElement?.getAttribute("aria-invalid") === "true", null, { timeout: 5_000 }).catch(() => {})
  const info = await state()
  if (!info.focusInvalid && !info.live) throw new Error(`errors neither announced nor focused (focus on ${info.focus})`)
  await c.close()
})

const jsErrors = [...new Set(allPages.flatMap((p) => p.errors))]
await step("aucune erreur JavaScript ni réponse 5xx pendant les vérifications", async () => {
  if (jsErrors.length) throw new Error(jsErrors.slice(0, 3).join(" | "))
})
await browser.close()
process.exit(summary() ? 0 : 1)
