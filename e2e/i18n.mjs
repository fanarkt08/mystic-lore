// Passe française : chaque page et chaque état en anglais puis en français, pour repérer les textes non traduits.
// Usage : cd e2e && ALLOW_PENDING=1 node i18n.mjs   (ONLY=<regex>, NO_STATES=1, BASE, CHROME) ; les .po ne sont jamais modifiés.
import {
  ADMIN, BASE, DEMO, MEMBER, MODERATOR, PUBLIC, STATES, allPages, launch, login, newContext, newPage, openErrorPage,
  renderErrorPages, resolve, resolveAdmin, resolveMember, resolveVisitor, setLanguage, visit,
} from "./lib/audit.mjs"
import { codeMessages, frenchCatalog, frenchStatus, matcher, normalize, webSource } from "./lib/gettext.mjs"
import { writeFileSync } from "node:fs"

const ONLY = process.env.ONLY ? new RegExp(process.env.ONLY) : null
const ALLOW_PENDING = !!process.env.ALLOW_PENDING
const messages = codeMessages()
const catalog = frenchCatalog()
const lookup = matcher(messages)
const literal = webSource()
const seen = { en: new Map(), fr: new Map() } // unité → Map(texte → genre)
const failures = []

// ───────────────────────────────────────────── relevé des textes d'une page
function extractTexts() {
  const lang = document.documentElement.lang
  const out = []
  const skip = (el) => {
    if (el.closest("script, style, template, code, pre, textarea, .code-editor, .identity, [translate=no], .bubble-body, .secret-key")) return true
    const other = el.closest("[lang]")
    return other && other.getAttribute("lang") !== lang
  }
  const add = (text, kind) => { const t = (text || "").replace(/\s+/g, " ").trim(); if (t) out.push([t, kind]) }
  add(document.title, "title")
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT)
  for (let node; (node = walker.nextNode());) {
    const el = node.parentElement
    if (!el || skip(el)) continue
    add(node.textContent, el.closest(".field-error") ? "error" : "text")
  }
  const attrs = ["aria-label", "placeholder", "alt", "title", "aria-description", "data-confirm", "aria-valuetext", "aria-roledescription"]
  for (const el of document.body.querySelectorAll("*")) {
    if (skip(el)) continue
    for (const name of attrs) if (el.hasAttribute(name)) add(el.getAttribute(name), name)
    if (el.matches("input[type=submit], input[type=button]")) add(el.value, "value")
    // textes des scripts, traduits par le serveur (data-texts, data-offline…)
    for (const attr of el.attributes) {
      if (!attr.name.startsWith("data-") || attr.name.startsWith("data-phx") || attrs.includes(attr.name)) continue
      const value = attr.value.trim()
      if (/^[[{]/.test(value)) {
        try {
          const walk = (v) => (typeof v === "string" ? add(v, "script") : v && typeof v === "object" ? Object.values(v).forEach(walk) : null)
          walk(JSON.parse(value))
        } catch { /* pas du JSON */ }
      } else if (/\p{L}{2,}[\s\S]*\s[\s\S]*\p{L}{2,}/u.test(value) && !/^(\/|https?:|#|[\w-]+:)/.test(value)) add(value, "script")
    }
  }
  return out
}
async function inspect(page, unit, lang) {
  if (ONLY && !ONLY.test(unit)) return
  const texts = await page.evaluate(extractTexts)
  const map = seen[lang].get(unit) || new Map()
  for (const [text, kind] of texts) if (!map.has(text) || kind === "error") map.set(text, kind)
  seen[lang].set(unit, map)
  console.log(`  [${lang}] ${unit} : ${map.size} textes`)
}

// ───────────────────────────────────────────── parcours (anglais, puis français)
const browser = await launch()
const errorPages = renderErrorPages(["en", "fr"])
console.log(`Passe française — ${BASE} — ${messages.length} appels gettext dans le code`)
const languageOwners = new Map() // page de membre dont la préférence de langue a été changée

async function member(ctxs, lang, email) {
  const ctx = await newContext(browser, { lang: "en" })
  ctxs.push(ctx)
  const page = await newPage(ctx)
  await login(page, email)
  await setLanguage(page, lang === "fr" ? "fr" : "auto")
  if (lang === "fr") languageOwners.set(email, page)
  return page
}

try {
  for (const lang of ["en", "fr"]) {
    const ctxs = []
    const actors = {}
    const actor = async (key) => (actors[key] ||= await member(ctxs, lang, DEMO[key]))
    const pages = async (label, paths, dyn, page) => {
      for (const path of paths) {
        const target = resolve(dyn, path)
        const unit = `${label} ${path}`
        if (ONLY && !ONLY.test(unit)) continue
        if (!target) { failures.push(`${unit} : chemin non résolu`); continue }
        try {
          await visit(page, target, { wait: "networkidle" })
          await inspect(page, unit, lang)
        } catch (e) {
          failures.push(`[${lang}] ${unit} : ${String(e.message || e).split("\n")[0]}`)
        }
      }
    }
    console.log(`\n── ${lang}`)
    const vctx = await newContext(browser, { lang })
    ctxs.push(vctx)
    const visitor = await newPage(vctx)
    await pages("visiteur", PUBLIC, await resolveVisitor(visitor), visitor)
    const lea = await member(ctxs, lang, DEMO.lea)
    const memberDyn = await resolveMember(lea)
    await pages("membre", MEMBER, memberDyn, lea)
    await pages("modérateur", MODERATOR, {}, await member(ctxs, lang, DEMO.theo))
    const clara = await member(ctxs, lang, DEMO.clara)
    await pages("admin", ADMIN, await resolveAdmin(clara), clara)
    for (const code of ["403", "404", "500"]) {
      await openErrorPage(visitor, errorPages[`${lang}:${code}`], code)
      await inspect(visitor, `erreur ${code}`, lang)
    }
    if (!process.env.NO_STATES)
      for (const state of STATES) {
        if (ONLY && !ONLY.test(`état ${state.id}`)) continue
        const dyn = state.role === "member" ? memberDyn : {}
        // l'état est construit dans un contexte neuf : un membre y retrouve sa préférence de langue
        const ctx = await newContext(browser, { lang: state.role === "visitor" || state.role === "fresh" ? lang : "en", ...(state.width ? { width: state.width } : {}) })
        const page = await newPage(ctx)
        try {
          if (state.role === "member") await login(page, DEMO.lea)
          if (state.role === "hugo") { await actor("hugo"); await login(page, DEMO.hugo) }
          await state.run(page, (label) => inspect(page, `état ${state.id} › ${label}`, lang), { dyn, actor, lang })
        } catch (e) {
          failures.push(`[${lang}] état ${state.id} : ${String(e.message || e).split("\n")[0]}`)
        } finally {
          await ctx.close()
        }
      }
    // retour à « Automatic » avant de fermer les contextes du français
    for (const [email, page] of languageOwners) { await setLanguage(page, "auto").catch((e) => failures.push(`langue de ${email} non rétablie : ${e.message}`)); languageOwners.delete(email) }
    for (const ctx of ctxs) await ctx.close().catch(() => {})
  }
} finally {
  // en cas d'interruption : les membres de démo retrouvent « Automatic »
  for (const [email, page] of languageOwners) await setLanguage(page, "auto").catch(() => console.log(`⚠ langue de ${email} restée en français`))
  await browser.close()
}

// ───────────────────────────────────────────── classement des textes identiques
const SAME = new Set(["MysticLore", "Premium", "VIP", "XP", "English", "Français", "Stripe", "Anthropic", "GroveScript", "WebVTT", "PNG", "JPEG", "WebP", "PDF", "OK"])
function excludedReason(text) {
  if (!/\p{L}/u.test(text)) return "nombre ou symbole"
  if (SAME.has(text)) return "marque ou mot identique"
  if (/^[\p{L}\d]+(?:[ ·:/+×-]+[\p{L}\d]+)*$/u.test(text) && text.split(/[ ·:/+×-]+/).every((w) => SAME.has(w) || /^\d+$/.test(w) || /^[A-Z]{2,5}$/.test(w))) return "marque ou mot identique"
  if (/^@[\w.-]+$/.test(text) || /^[\w.+-]+@[\w.-]+$/.test(text) || /^(https?:\/\/|\/)\S*$/.test(text)) return "pseudonyme, adresse ou lien"
  if (/^REQ-[0-9A-Z]{5}-[0-9A-Z]{5}$|^[0-9a-f]{8}-[0-9a-f-]{27}$|^[\w-]+\.(png|jpe?g|webp|pdf|svg|webm|vtt)$|^[A-Z][a-z]+\/[A-Za-z_]+$|^[A-Z]{2,5}$/.test(text)) return "code, fichier ou fuseau"
  if (/^[\d\s:.,/+-]*(UTC|CET|CEST|EST|EDT|JST|GMT)?[\d\s:.,/+-]*$/.test(text)) return "date ou heure"
  if (/^[A-Z][A-Za-z_]+(\/[A-Za-z_]+)+ \(UTC[+-]\d{2}:\d{2}\)$/.test(text)) return "code, fichier ou fuseau"
  if (/^[a-z_]+(\.[a-z_]+)+$/.test(text)) return "code, fichier ou fuseau"
  return null
}
const report = { bug: [], hardcoded: [], service: [], pending: [] }
const excluded = new Map(), content = new Map()
let compared = 0
for (const [unit, fr] of seen.fr) {
  const en = seen.en.get(unit)
  if (!en) { failures.push(`${unit} : relevé en français seulement`); continue }
  compared += fr.size
  for (const [text, kind] of fr) {
    if (!en.has(text)) continue
    const reason = excludedReason(text)
    if (reason) { excluded.set(reason, (excluded.get(reason) || 0) + 1); continue }
    const candidates = lookup(normalize(text))
    if (candidates.length) {
      const statuses = candidates.map((m) => [m, frenchStatus(catalog, m)])
      if (statuses.some(([, s]) => s.status === "identical")) { excluded.set("identique dans le catalogue", (excluded.get("identique dans le catalogue") || 0) + 1); continue }
      const translated = statuses.find(([, s]) => s.status === "translated")
      if (translated) report.bug.push({ unit, text, kind, where: translated[0].file })
      else report.pending.push({ unit, text, kind, where: statuses[0][0].file, msgid: statuses[0][0].msgid })
      continue
    }
    if (literal(text)) report.hardcoded.push({ unit, text, kind })
    // message d'erreur d'un champ de formulaire renvoyé par un service : à déclarer dans @service_errors
    else if (kind === "error") report.service.push({ unit, text, kind })
    else content.set(text, (content.get(text) || new Set()).add(unit.split(" ")[0]))
  }
}

const show = (list) => {
  const byText = new Map()
  for (const item of list) {
    const entry = byText.get(item.text) || { ...item, units: new Set() }
    entry.units.add(item.unit)
    byText.set(item.text, entry)
  }
  return [...byText.values()].map((e) => `  « ${e.text} » (${e.kind}${e.where ? `, ${e.where}` : ""}) — ${[...e.units].slice(0, 3).join(" | ")}${e.units.size > 3 ? ` (+${e.units.size - 3})` : ""}`).join("\n") || "  aucun"
}
console.log(`\n=== Locale non appliquée (traduit dans le catalogue, affiché en anglais) ===\n${show(report.bug)}`)
console.log(`\n=== Écrits en dur (hors gettext) ===\n${show(report.hardcoded)}`)
console.log(`\n=== Erreurs de service non déclarées (@service_errors) ===\n${show(report.service)}`)
console.log(`\n=== En attente de traduction (gettext, sans traduction française) ===\n${show(report.pending)}`)
console.log(`\n=== Exclusions (non comptées) ===\n${[...excluded].map(([r, n]) => `  ${r} : ${n}`).join("\n") || "  aucune"}`)
console.log(`  contenus des services ou des membres (non traduits par l’interface, par conception, ${content.size} textes) :\n    ${[...content].slice(0, process.env.VERBOSE ? Infinity : 40).map(([t, roles]) => `« ${t.slice(0, 80)} » [${[...roles].join(",")}]`).join("\n    ")}${content.size > 40 && !process.env.VERBOSE ? `\n    … (+${content.size - 40} ; VERBOSE=1 pour tout voir)` : ""}`)

// textes du code sans traduction française, toutes pages confondues
const missing = new Map()
for (const m of messages) if (frenchStatus(catalog, m).status === "pending") missing.set(`${m.domain}|${m.context ?? ""}|${m.msgid}`, m)
console.log(`\n=== Textes du code sans traduction française (${missing.size}) ===\n${[...missing.values()].map((m) => `  [${m.domain}${m.context ? `, ${m.context}` : ""}] « ${m.msgid} »${m.plural ? ` / « ${m.plural} »` : ""} — ${m.file}`).join("\n") || "  aucun"}`)
if (failures.length) console.log(`\n=== Relevés impossibles ===\n  ${failures.join("\n  ")}`)
if (process.env.REPORT) writeFileSync(process.env.REPORT, JSON.stringify({ report, content: [...content].map(([t, r]) => [t, [...r]]), failures }, null, 1))
const jsErrors = [...new Set(allPages.flatMap((p) => p.errors))]
if (jsErrors.length) console.log(`\n=== Erreurs JS / 5xx ===\n  ${jsErrors.slice(0, 10).join("\n  ")}`)

const unique = (list) => new Set(list.map((item) => item.text)).size
const blocking = unique([...report.bug, ...report.hardcoded, ...report.service])
const pending = unique(report.pending)
console.log(`\n${seen.fr.size} pages et états relevés dans les deux langues, ${compared} textes français comparés`)
console.log(`Textes suspects : ${blocking + pending} textes distincts (${blocking} à corriger, ${pending} en attente de traduction, ${report.pending.length} occurrences${ALLOW_PENDING ? ", tolérés : ALLOW_PENDING=1" : ""}) — objectif 0 hors exclusions documentées`)
process.exit(blocking || failures.length || jsErrors.length || (!ALLOW_PENDING && pending) ? 1 : 0)
