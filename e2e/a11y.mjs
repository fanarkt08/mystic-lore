// Audit d'accessibilité automatisé avec axe-core dans Chrome, sur la pile de bin/dev (après pages.mjs).
// Usage : cd e2e && node a11y.mjs   (ONLY=<regex>, LOCALES=en,fr, THEMES=dark,light, NO_STATES=1, REPORT=<fichier.json>, HEADED=1)
import { readFileSync, writeFileSync } from "node:fs"
import { createRequire } from "node:module"
import { inflateSync } from "node:zlib"
import {
  ADMIN, BASE, DEMO, MEMBER, MODERATOR, PUBLIC, STATES, T, allPages, launch, login, newContext, newPage, openErrorPage,
  renderErrorPages, resolve, resolveAdmin, resolveMember, resolveVisitor, visit,
} from "./lib/audit.mjs"

const AXE_SOURCE = readFileSync(createRequire(import.meta.url).resolve("axe-core/axe.min.js"), "utf8")
const AXE_VERSION = JSON.parse(readFileSync(createRequire(import.meta.url).resolve("axe-core/package.json"), "utf8")).version
const WCAG = ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"]
const ONLY = process.env.ONLY ? new RegExp(process.env.ONLY) : null
const LOCALES = (process.env.LOCALES || "en,fr").split(",")
const BASE_THEMES = (process.env.THEMES || "dark,light").split(",")
const THEMES = {
  dark: { scheme: "dark", attrs: {} }, // défaut : thème « system » sur un appareil en sombre
  light: { scheme: "light", attrs: {} }, // thème clair (« system » sur un appareil en clair = data-theme="light")
  "dark+contrast": { scheme: "dark", attrs: { "data-contrast": "more" } },
  "light+contrast": { scheme: "light", attrs: { "data-contrast": "more" } },
  grove: { scheme: "dark", attrs: { "data-theme": "grove" } },
  ember: { scheme: "dark", attrs: { "data-theme": "ember" } },
  parchment: { scheme: "light", attrs: { "data-theme": "parchment" } },
}
// thèmes VIP (réservés aux membres VIP ; même CSS) sur un échantillon de pages de membre
const VIP_SAMPLE = new Set(["/dashboard", "LESSON", "FORMAT_quiz", "CONVERSATION", "/settings/preferences", "/community", "DISCUSSION",
  "/membership", "/notifications", "/offline", "/multiplayer", "PROJECT"])
// Faux positif vérifié dans la page à chaque exécution : une cible derrière une modale ouverte est inerte.
const EXCLUSIONS = [
  {
    rule: "target-size",
    reason: "contrôle inerte derrière une modale ouverte (showModal) : ni focus ni clic",
    proven: (selector) => {
      const el = document.querySelector(selector)
      const modal = document.querySelector("dialog:modal")
      if (!el || !modal || modal.contains(el)) return false
      const before = document.activeElement
      el.focus()
      const inert = document.activeElement !== el
      if (!inert) before?.focus?.()
      return inert
    },
  },
]
const excludedNodes = [] // { unit, lang, theme, rule, target, reason }

const results = [] // un audit = une page (ou un état) × un thème × une langue
const failures = [] // états ou pages qui n'ont pas pu être audités
let units = 0

// ───────────────────────────────────────────── axe
async function runAxe(page) {
  if (!(await page.evaluate(() => typeof window.axe === "object"))) await page.evaluate(AXE_SOURCE)
  return page.evaluate(async (tags) => {
    const res = await window.axe.run(document, { runOnly: { type: "tag", values: tags }, resultTypes: ["violations", "incomplete"] })
    const pick = (list) => list.map((r) => ({
      id: r.id, impact: r.impact, tags: r.tags, help: r.help,
      nodes: r.nodes.map((n) => ({
        target: n.target.join(" "), html: n.html.slice(0, 160), summary: (n.failureSummary || "").replace(/\s+/g, " ").slice(0, 300),
        data: (n.any[0] || n.all[0] || n.none[0] || {}).data || null,
      })),
    }))
    return { violations: pick(res.violations), incomplete: pick(res.incomplete) }
  }, [...WCAG, "best-practice"])
}

// ───────────────────────────────────────────── contraste mesuré sur le rendu
function decodePng(buffer) {
  let pos = 8, width, height, type, idat = []
  while (pos < buffer.length) {
    const length = buffer.readUInt32BE(pos), kind = buffer.toString("latin1", pos + 4, pos + 8)
    const data = buffer.subarray(pos + 8, pos + 8 + length)
    if (kind === "IHDR") { width = data.readUInt32BE(0); height = data.readUInt32BE(4); type = data[9] }
    if (kind === "IDAT") idat.push(data)
    pos += 12 + length
  }
  const raw = inflateSync(Buffer.concat(idat))
  const bpp = type === 6 ? 4 : 3, stride = width * bpp
  const out = new Uint8Array(width * height * 3)
  let prev = new Uint8Array(stride)
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)], line = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1)), cur = new Uint8Array(stride)
    for (let x = 0; x < stride; x++) {
      const a = x >= bpp ? cur[x - bpp] : 0, b = prev[x], c = x >= bpp ? prev[x - bpp] : 0
      const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c)
      const pred = [0, a, b, (a + b) >> 1, pa <= pb && pa <= pc ? a : pb <= pc ? b : c][filter]
      cur[x] = (line[x] + pred) & 0xff
    }
    for (let x = 0; x < width; x++) for (let k = 0; k < 3; k++) out[(y * width + x) * 3 + k] = cur[x * bpp + k]
    prev = cur
  }
  return { width, height, data: out }
}
const LINEAR = Array.from({ length: 256 }, (_, i) => { const c = i / 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4 })
const luminance = (r, g, b) => 0.2126 * LINEAR[r] + 0.7152 * LINEAR[g] + 0.0722 * LINEAR[b]
const ratio = (l1, l2) => (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05)
const hex = (c) => "#" + c.map((v) => v.toString(16).padStart(2, "0")).join("")

// Feuille adoptée par l'audit : « freeze » coupe les animations, « hide » rend aussi le texte transparent pour mesurer le fond.
const AUDIT_SHEET = `window.setAuditSheet = (mode) => {
  if (!window.__a11ySheet) {
    window.__a11ySheet = new CSSStyleSheet()
    document.adoptedStyleSheets = [...document.adoptedStyleSheets, window.__a11ySheet]
  }
  const freeze = "*, *::before, *::after { transition: none !important; animation: none !important; }"
  const hide = "*, *::before, *::after, *::placeholder, *::marker, *::first-letter, *::first-line { color: transparent !important; -webkit-text-fill-color: transparent !important; text-shadow: none !important; caret-color: transparent !important; text-decoration-color: transparent !important; } svg text, svg tspan, svg textPath { fill: transparent !important; stroke: transparent !important; }"
  window.__a11ySheet.replaceSync(mode === "hide" ? freeze + hide : mode === "freeze" ? freeze : "")
}`
async function auditSheet(page, mode) {
  if (!(await page.evaluate(() => typeof window.setAuditSheet === "function"))) await page.evaluate(AUDIT_SHEET)
  await page.evaluate((m) => window.setAuditSheet(m), mode)
  await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))))
}

// dans la page : couleur du texte (avec l'opacité des ancêtres), puis texte rendu transparent
function contrastSetup(selectors) {
  const g = new OffscreenCanvas(1, 1).getContext("2d", { willReadFrequently: true })
  const rgba = (css) => { g.clearRect(0, 0, 1, 1); g.fillStyle = "#000"; g.fillStyle = css; g.fillRect(0, 0, 1, 1); const d = g.getImageData(0, 0, 1, 1).data; return [[d[0], d[1], d[2]], d[3] / 255] }
  window.__a11yTargets = selectors.map((selector) => {
    const el = document.querySelector(selector)
    if (!el) return null
    let opacity = 1
    for (let e = el; e && e.nodeType === 1; e = e.parentElement) opacity *= Number(getComputedStyle(e).opacity)
    // un texte SVG est peint par `fill` (et son opacité), pas par `color`
    const style = getComputedStyle(el)
    const svg = el instanceof SVGElement
    const [fg, alpha] = rgba(svg ? style.fill : style.color)
    if (svg) opacity *= Number(style.fillOpacity)
    return { el, fg, alpha: alpha * opacity }
  })
  setAuditSheet("hide")
  document.activeElement?.blur?.()
  return window.__a11yTargets.map((t) => t && { fg: t.fg, alpha: t.alpha })
}
function contrastTeardown() {
  setAuditSheet("freeze")
  window.scrollTo(0, 0)
}
// zones du texte (lignes des nœuds texte, ou boîte de contenu d'un champ), visibles et non recouvertes, à l'écran
function contrastBoxes(ids) {
  const vw = innerWidth, vh = innerHeight
  return ids.map((id) => {
    const t = window.__a11yTargets[id]
    if (!t || !t.el.isConnected) return { id, lines: [] }
    const el = t.el
    let rects = []
    for (const node of el.childNodes) {
      if (node.nodeType !== 3 || !node.textContent.trim()) continue
      const range = document.createRange()
      range.selectNodeContents(node)
      rects.push(...[...range.getClientRects()].filter((r) => r.width > 0.5 && r.height > 0.5))
    }
    if (!rects.length) {
      const r = el.getBoundingClientRect(), s = getComputedStyle(el), px = (v) => parseFloat(v) || 0
      const l = px(s.borderLeftWidth) + px(s.paddingLeft), rt = px(s.borderRightWidth) + px(s.paddingRight)
      const tp = px(s.borderTopWidth) + px(s.paddingTop), bt = px(s.borderBottomWidth) + px(s.paddingBottom)
      if (r.width - l - rt > 0.5 && r.height - tp - bt > 0.5) rects.push(new DOMRect(r.left + l, r.top + tp, r.width - l - rt, r.height - tp - bt))
    }
    // ancêtres qui coupent (overflow hidden/clip : texte masqué par conception) et conteneurs qui défilent (le texte
    // y est visible une fois amené à l'écran)
    let clip = { l: -1e9, t: -1e9, r: 1e9, b: 1e9 }, view = { l: 0, t: 0, r: vw, b: vh }
    for (let a = el.parentElement; a && a !== document.documentElement; a = a.parentElement) {
      const s = getComputedStyle(a)
      if (s.overflowX === "visible" && s.overflowY === "visible") continue
      const r = a.getBoundingClientRect()
      const target = /auto|scroll/.test(s.overflowX + s.overflowY) ? view : clip
      Object.assign(target, { l: Math.max(target.l, r.left), t: Math.max(target.t, r.top), r: Math.min(target.r, r.right), b: Math.min(target.b, r.bottom) })
    }
    // recouvert : un élément dessiné au-dessus du texte (autre qu'un ancêtre ou un descendant) avec un fond, une
    // image ou un média (un calque transparent, comme le lien étendu d'une carte, ne cache rien)
    const opaque = (e) => {
      if (/^(IMG|VIDEO|CANVAS|IFRAME|svg)$/.test(e.tagName)) return true
      return [null, "::before", "::after"].some((pseudo) => {
        const s = getComputedStyle(e, pseudo)
        if (pseudo && s.content === "none") return false
        return s.backgroundImage !== "none" || !/rgba\(0, 0, 0, 0\)|transparent/.test(s.backgroundColor) || s.backdropFilter !== "none"
      })
    }
    const covered = (x, y) => {
      for (const hit of document.elementsFromPoint(x, y)) {
        if (hit === el || el.contains(hit) || hit.contains(el)) return false
        if (opaque(hit)) return true
      }
      return false
    }
    const lines = rects.map((r) => {
      const box = { l: Math.max(r.left, clip.l), t: Math.max(r.top, clip.t), r: Math.min(r.right, clip.r), b: Math.min(r.bottom, clip.b) }
      if (box.r - box.l < 1 || box.b - box.t < 1) return { state: "clipped" }
      if (box.t < view.t - 0.5 || box.b > view.b + 0.5 || box.l < view.l - 0.5 || box.r > view.r + 0.5) return { state: "offscreen" }
      const w = box.r - box.l, h = box.b - box.t
      if ([[0.5, 0.5], [0.1, 0.25], [0.9, 0.25], [0.1, 0.75], [0.9, 0.75]].some(([x, y]) => covered(box.l + w * x, box.t + h * y))) return { state: "covered" }
      return { state: "ok", box }
    })
    return { id, lines }
  })
}
async function renderedContrast(page, nodes) {
  const found = []
  if (!nodes.length) return found
  await auditSheet(page, "freeze")
  const colors = await page.evaluate(contrastSetup, nodes.map((n) => n.target))
  try {
    // id → { done: lignes déjà mesurées, finished, worst… } ; chaque capture mesure toutes les lignes visibles
    const todo = new Map()
    nodes.forEach((n, id) => colors[id] && todo.set(id, { worst: Infinity, bg: null, measured: 0, finished: false }))
    for (let round = 0; round < 80; round++) {
      const ids = [...todo.keys()].filter((id) => !todo.get(id).finished)
      if (!ids.length) break
      // la première cible restante est amenée au centre de l'écran (y compris dans un conteneur qui défile)
      const next = ids[0]
      await page.evaluate((id) => window.__a11yTargets[id]?.el.scrollIntoView({ block: "center", inline: "nearest" }), next)
      const shot = decodePng(await page.screenshot({ type: "png", animations: "disabled", caret: "hide" }))
      for (const { id, lines } of await page.evaluate(contrastBoxes, ids)) {
        const entry = todo.get(id)
        entry.done ||= lines.map(() => false)
        lines.forEach((line, k) => {
          if (line.state !== "ok" || entry.done[k]) return
          entry.done[k] = true
          const { fg, alpha } = colors[id]
          const x0 = Math.max(0, Math.ceil(line.box.l)), x1 = Math.min(shot.width, Math.max(x0 + 1, Math.floor(line.box.r)))
          const y0 = Math.max(0, Math.ceil(line.box.t)), y1 = Math.min(shot.height, Math.max(y0 + 1, Math.floor(line.box.b)))
          for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
            const i = (y * shot.width + x) * 3, bg = [shot.data[i], shot.data[i + 1], shot.data[i + 2]]
            const text = fg.map((c, j) => Math.round(c * alpha + bg[j] * (1 - alpha)))
            const value = ratio(luminance(...text), luminance(...bg))
            if (value < entry.worst) { entry.worst = value; entry.bg = bg; entry.text = text }
          }
          entry.measured++
        })
        // terminé quand toutes ses lignes visibles ont été mesurées ; la cible amenée à l'écran ne progressera plus
        // (une ligne masquée par un ancêtre, `overflow`, n'est pas du texte affiché)
        const left = entry.done.filter((done, k) => !done && lines[k]?.state !== "clipped").length
        if (id === next || left === 0) entry.finished = true
      }
    }
    for (const [id, entry] of todo) {
      const node = nodes[id]
      const required = parseFloat(node.data?.expectedContrastRatio) || 4.5
      if (!entry.measured) found.push({ ...node, status: "unmeasured", required })
      else if (entry.worst + 1e-9 < required)
        found.push({ ...node, status: "fail", required, worst: Math.round(entry.worst * 100) / 100, fg: hex(entry.text), bg: hex(entry.bg) })
      else found.push({ ...node, status: "pass", required, worst: Math.round(entry.worst * 100) / 100 })
    }
  } finally {
    await page.evaluate(contrastTeardown)
  }
  return found
}

// ───────────────────────────────────────────── un audit (page ou état) dans un thème
async function excluded(page, rule, target) {
  for (const e of EXCLUSIONS) if (e.rule === rule && (await page.evaluate(e.proven, target))) return e.reason
  return null
}
async function auditTheme(page, unit, lang, theme, original) {
  const t = THEMES[theme]
  await page.emulateMedia({ colorScheme: t.scheme, reducedMotion: "reduce" })
  await page.evaluate(({ attrs, original }) => {
    const root = document.documentElement
    for (const name of ["data-theme", "data-contrast"]) {
      const value = Object.hasOwn(attrs, name) ? attrs[name] : original[name]
      value == null ? root.removeAttribute(name) : root.setAttribute(name, value)
    }
  }, { attrs: t.attrs, original })
  await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))))
  const axe = await runAxe(page)
  const contrastNodes = axe.incomplete.filter((r) => r.id === "color-contrast").flatMap((r) => r.nodes)
  const measured = await renderedContrast(page, contrastNodes)
  const blocking = [], best = [], review = []
  for (const v of axe.violations) {
    const nodes = []
    for (const n of v.nodes) {
      const reason = await excluded(page, v.id, n.target)
      if (reason) excludedNodes.push({ unit, lang, theme, rule: v.id, target: n.target, reason })
      else nodes.push(n)
    }
    if (!nodes.length) continue
    ;(v.tags.some((tag) => WCAG.includes(tag)) ? blocking : best).push({ rule: v.id, help: v.help, nodes })
  }
  const rendered = measured.filter((m) => m.status === "fail")
  if (rendered.length) blocking.push({ rule: "color-contrast", help: "contraste mesuré sur le rendu", nodes: rendered })
  const unmeasured = measured.filter((m) => m.status === "unmeasured")
  if (unmeasured.length) review.push({ rule: "color-contrast", help: "contraste non mesuré : texte recouvert (menu ou dialogue ouvert) ou jamais affiché à l'écran", nodes: unmeasured })
  for (const r of axe.incomplete) if (r.id !== "color-contrast") review.push({ rule: r.id, help: r.help, nodes: r.nodes })
  return { unit, lang, theme, blocking, best, review, measured: measured.length, rendered: rendered.length }
}
async function audit(page, unit, lang, themes) {
  if (ONLY && !ONLY.test(unit)) return
  units++
  const original = await page.evaluate(() => ({ "data-theme": document.documentElement.getAttribute("data-theme"), "data-contrast": document.documentElement.getAttribute("data-contrast") }))
  const notes = []
  await auditSheet(page, "freeze")
  for (const theme of themes) {
    const result = await auditTheme(page, unit, lang, theme, original)
    results.push(result)
    const { blocking, best } = result
    const count = blocking.reduce((n, v) => n + v.nodes.length, 0)
    if (count) notes.push(`${theme}: ${blocking.map((v) => `${v.rule}×${v.nodes.length}`).join(" ")}`)
    if (best.length && theme === themes[0]) notes.push(`(bonnes pratiques : ${best.map((v) => `${v.rule}×${v.nodes.length}`).join(" ")})`)
  }
  await page.emulateMedia({ colorScheme: "dark", reducedMotion: "reduce" })
  await page.evaluate((o) => { for (const [k, v] of Object.entries(o)) v == null ? document.documentElement.removeAttribute(k) : document.documentElement.setAttribute(k, v) }, original)
  await auditSheet(page, "freeze")
  await auditSheet(page, "")
  console.log(`  [${lang}] ${unit} → ${notes.length ? notes.join(" · ") : "0 violation"}`)
}

// ───────────────────────────────────────────── parcours
const browser = await launch()
console.log(`Audit d'accessibilité (axe-core ${AXE_VERSION}, ${WCAG.join(", ")}) — ${BASE} — langues ${LOCALES.join(", ")}`)
const errorPages = renderErrorPages(LOCALES)

// Contrôle de l'outil : un texte secondaire volontairement trop pâle (#4a4f66 sur le fond sombre, environ 2:1) doit
// être détecté par la mesure sur le rendu ; sinon l'audit s'arrête (il ne prouverait rien).
{
  const ctx = await newContext(browser, { reducedMotion: "reduce", colorScheme: "dark" })
  const page = await newPage(ctx)
  await visit(page, "/", { wait: "networkidle" })
  await page.evaluate(() => { const s = new CSSStyleSheet(); s.replaceSync(".text-muted { color: #4a4f66 !important; }"); document.adoptedStyleSheets = [...document.adoptedStyleSheets, s] })
  await auditSheet(page, "freeze")
  const check = await auditTheme(page, "contrôle", "en", "dark", {})
  const caught = check.blocking.filter((v) => v.rule === "color-contrast").reduce((n, v) => n + v.nodes.length, 0)
  await ctx.close()
  if (!caught) { console.log("✗ contrôle de l'outil : un contraste insuffisant injecté n'a pas été détecté"); process.exit(1) }
  console.log(`contrôle de l'outil : ${caught} texte(s) trop pâle(s) injecté(s) détecté(s) (${check.measured} nœuds mesurés sur le rendu)`)
}

for (const lang of LOCALES) {
  const themesFor = (path, role) => [
    ...BASE_THEMES,
    ...(lang === "en" ? ["dark+contrast", "light+contrast"] : []),
    ...(lang === "en" && role === "member" && VIP_SAMPLE.has(path) ? ["grove", "ember", "parchment"] : []),
  ]
  const options = { lang, reducedMotion: "reduce", colorScheme: "dark" }
  const contexts = []
  const open = async (opts = {}) => { const ctx = await newContext(browser, { ...options, ...opts }); contexts.push(ctx); return ctx }
  const actors = {}
  const actor = async (key) => {
    if (!actors[key]) { const page = await newPage(await open()); await login(page, DEMO[key]); actors[key] = page }
    return actors[key]
  }
  const pages = async (label, role, paths, dyn, page) => {
    for (const path of paths) {
      const target = resolve(dyn, path)
      const unit = `${label} ${path}${target !== path ? ` (${target})` : ""}`
      if (ONLY && !ONLY.test(unit)) continue
      if (!target) { failures.push(`${unit} : chemin non résolu`); continue }
      try {
        await visit(page, target, { wait: "networkidle" })
        await audit(page, unit, lang, themesFor(path, role))
      } catch (e) {
        failures.push(`[${lang}] ${unit} : ${String(e.message || e).split("\n")[0]}`)
      }
    }
  }

  console.log(`\n── ${lang} : visiteur`)
  const visitor = await newPage(await open())
  await pages("visiteur", "visitor", PUBLIC, await resolveVisitor(visitor), visitor)
  console.log(`\n── ${lang} : membre Premium (Léa)`)
  const member = await newPage(await open())
  await login(member, DEMO.lea)
  const memberDyn = await resolveMember(member)
  await pages("membre", "member", MEMBER, memberDyn, member)
  console.log(`\n── ${lang} : modérateur (Théo)`)
  const moderator = await newPage(await open())
  await login(moderator, DEMO.theo)
  await pages("modérateur", "staff", MODERATOR, {}, moderator)
  console.log(`\n── ${lang} : administratrice (Clara)`)
  const admin = await newPage(await open())
  await login(admin, DEMO.clara)
  await pages("admin", "staff", ADMIN, await resolveAdmin(admin), admin)

  console.log(`\n── ${lang} : pages d'erreur (gabarit réel rendu par le nœud web)`)
  for (const code of ["403", "404", "500"]) {
    const unit = `erreur ${code}`
    if (ONLY && !ONLY.test(unit)) continue
    await openErrorPage(visitor, errorPages[`${lang}:${code}`], code)
    await audit(visitor, unit, lang, BASE_THEMES)
  }

  if (!process.env.NO_STATES) {
    console.log(`\n── ${lang} : états construits`)
    for (const state of STATES) {
      if (ONLY && !ONLY.test(`état ${state.id}`) && !ONLY.test(state.id)) continue
      const dyn = state.role === "member" ? memberDyn : {}
      if ((state.needs || []).some((k) => !dyn[k])) { failures.push(`[${lang}] état ${state.id} : chemin manquant (${state.needs.join(", ")})`); continue }
      const ctx = await open(state.width ? { width: state.width } : {})
      const page = await newPage(ctx)
      try {
        if (state.role === "member") await login(page, DEMO.lea)
        if (state.role === "hugo") await login(page, DEMO.hugo)
        await state.run(page, (label) => audit(page, `état ${state.id} › ${label}`, lang, BASE_THEMES), { dyn, actor, lang })
      } catch (e) {
        failures.push(`[${lang}] état ${state.id} : ${String(e.message || e).split("\n")[0]}`)
      } finally {
        await ctx.close()
      }
    }
  }
  for (const ctx of contexts) await ctx.close().catch(() => {})
}
await browser.close()

// ───────────────────────────────────────────── synthèse
const byRule = new Map(), byUnit = new Map(), bestByRule = new Map(), reviewByRule = new Map()
for (const r of results) {
  for (const v of r.blocking) {
    const entry = byRule.get(v.rule) || { nodes: 0, units: new Set(), help: v.help }
    entry.nodes += v.nodes.length
    entry.units.add(r.unit)
    byRule.set(v.rule, entry)
    const u = byUnit.get(r.unit) || []
    u.push(`${v.rule}×${v.nodes.length} [${r.lang}·${r.theme}] ${v.nodes.slice(0, 2).map((n) => n.target + (n.worst ? ` (${n.worst}:1 < ${n.required}:1, ${n.fg} sur ${n.bg})` : "")).join(" ; ")}`)
    byUnit.set(r.unit, u)
  }
  for (const [list, map] of [[r.best, bestByRule], [r.review, reviewByRule]])
    for (const v of list) {
      const entry = map.get(v.rule) || { nodes: 0, units: new Set(), help: v.help, sample: v.nodes[0]?.target }
      entry.nodes += v.nodes.length
      entry.units.add(r.unit)
      map.set(v.rule, entry)
    }
}
const allUnits = [...new Set(results.map((r) => r.unit))]
const clean = allUnits.filter((u) => !byUnit.has(u))
const measured = results.reduce((n, r) => n + r.measured, 0)
const list = (map, pages = false) => [...map].sort((a, b) => b[1].nodes - a[1].nodes)
  .map(([rule, e]) => `  ${rule.padEnd(28)} ${String(e.nodes).padStart(4)} nœud(s) sur ${e.units.size} page(s) — ${e.help}${e.sample ? ` (ex. ${e.sample})` : ""}${pages ? `\n      ${[...e.units].join("\n      ")}` : ""}`).join("\n") || "  aucune"

console.log(`\n=== Violations BLOQUANTES (${WCAG.join(", ")}) par règle ===\n${list(byRule)}`)
console.log(`\n=== Violations par page ===\n${[...byUnit].map(([u, l]) => `  ${u}\n    ${l.join("\n    ")}`).join("\n") || "  aucune"}`)
console.log(`\n=== Bonnes pratiques (non bloquantes) ===\n${list(bestByRule)}`)
console.log(`\n=== À vérifier (résultats « incomplete » d'axe, hors contraste mesuré) ===\n${list(reviewByRule, true)}`)
console.log(`\nContraste mesuré sur le rendu : ${measured} nœud(s) qu'axe ne savait pas trancher (dégradés, images, pseudo-éléments)`)
if (excludedNodes.length) console.log(`\n=== Exclusions (faux positifs démontrés dans la page) ===\n  ${excludedNodes.map((e) => `${e.rule} [${e.lang}·${e.theme}] ${e.unit} ${e.target} — ${e.reason}`).join("\n  ")}`)
if (failures.length) console.log(`\n=== Audits impossibles ===\n  ${failures.join("\n  ")}`)
const jsErrors = allPages.flatMap((p) => p.errors)
if (jsErrors.length) console.log(`\n=== Erreurs JS / 5xx ===\n  ${[...new Set(jsErrors)].slice(0, 10).join("\n  ")}`)
if (process.env.REPORT) writeFileSync(process.env.REPORT, JSON.stringify({ results, failures, jsErrors }, null, 1))
console.log(`\n${clean.length}/${allUnits.length} pages sans violation WCAG (${results.length} audits : pages et états × thèmes × langues)`)
process.exit(byRule.size || failures.length || jsErrors.length ? 1 : 0)
