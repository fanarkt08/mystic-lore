// Lecture seule des textes de l'interface : appels gettext de src/web/lib et traductions françaises des .po.
import { readFileSync, readdirSync, statSync } from "node:fs"
import { join } from "node:path"
import { ROOT } from "./audit.mjs"

const WEB = join(ROOT, "src", "web")
const files = (dir, re) => readdirSync(dir).flatMap((name) => {
  const path = join(dir, name)
  return statSync(path).isDirectory() ? files(path, re) : re.test(name) ? [path] : []
})
const unescape = (s) => s.replace(/\\(["\\nt])/g, (_, c) => ({ n: "\n", t: "\t" })[c] || c)
export const normalize = (s) => s.replace(/\s+/g, " ").trim()

// Appels gettext du code : msgid (et pluriel) de chaque appel, avec son domaine et son contexte.
// Formes reconnues : gettext, dgettext, pgettext, dpgettext, ngettext, dngettext, pngettext, dpngettext, *_noop.
const CALL = /\b(d?p?n?gettext)(?:_noop)?\(\s*/g
const STRING = /^"((?:[^"\\]|\\.)*)"\s*(?:,\s*)?/
export function codeMessages() {
  const messages = []
  for (const path of files(join(WEB, "lib"), /\.(ex|heex)$/)) {
    // ni la documentation (@moduledoc / @doc), ni les commentaires : seulement les appels réels
    const source = readFileSync(path, "utf8")
      .replace(/@(?:module)?doc\s+(?:~S)?"""[\s\S]*?"""/g, "")
      .replace(/^\s*#.*$/gm, "")
    for (const m of source.matchAll(CALL)) {
      const kind = m[1]
      let rest = source.slice(m.index + m[0].length)
      const strings = []
      const need = (kind.includes("d") ? 1 : 0) + (kind.includes("p") ? 1 : 0) + (kind.includes("n") ? 2 : 1)
      while (strings.length < need) {
        const s = rest.match(STRING)
        if (!s) break
        strings.push(unescape(s[1]))
        rest = rest.slice(s[0].length)
      }
      if (strings.length < need) continue // appel non littéral (gettext dynamique : Gettext.dgettext/3, hors catalogue)
      let i = 0
      const domain = kind.includes("d") ? strings[i++] : "default"
      const context = kind.includes("p") ? strings[i++] : null
      messages.push({ domain, context, msgid: strings[i], plural: kind.includes("n") ? strings[i + 1] : null, file: path.slice(WEB.length + 1) })
    }
  }
  return messages
}

// Traductions d'un fichier .po : clé « contexte\u0004msgid » → { msgstr: [formes], fuzzy }
export function readPo(path) {
  const entries = new Map()
  // une entrée par bloc (séparés par une ligne vide), comme les écrit `mix gettext`
  for (const block of readFileSync(path, "utf8").split(/\n\s*\n/)) {
    const entry = { fuzzy: false, msgstr: [] }
    let field = null
    for (const line of block.split("\n")) {
      if (line.startsWith("#,") && /\bfuzzy\b/.test(line)) entry.fuzzy = true
      if (line.startsWith("#")) continue
      const m = line.match(/^(msgctxt|msgid_plural|msgid|msgstr(?:\[(\d)\])?)\s+"(.*)"$/)
      const more = !m && line.match(/^"(.*)"$/)
      if (!m && !more) continue
      if (m) field = m[1].startsWith("msgstr") ? ["msgstr", Number(m[2] || 0)] : [m[1]]
      const value = unescape(m ? m[3] : more[1])
      if (field[0] === "msgstr") entry.msgstr[field[1]] = (m ? "" : entry.msgstr[field[1]] || "") + value
      else entry[field[0]] = (m ? "" : entry[field[0]] || "") + value
    }
    if (entry.msgid) entries.set(`${entry.msgctxt ?? ""}\u0004${entry.msgid}`, entry)
  }
  return entries
}
export function frenchCatalog() {
  const dir = join(WEB, "priv", "gettext", "fr", "LC_MESSAGES")
  return Object.fromEntries(readdirSync(dir).filter((f) => f.endsWith(".po")).map((f) => [f.replace(/\.po$/, ""), readPo(join(dir, f))]))
}
export function potMessages() {
  const dir = join(WEB, "priv", "gettext")
  return Object.fromEntries(readdirSync(dir).filter((f) => f.endsWith(".pot")).map((f) => [f.replace(/\.pot$/, ""), readPo(join(dir, f))]))
}

// Traduction française d'un message du code : "translated" (texte), "identical" (même texte en français),
// "pending" (absent du .po, vide ou fuzzy)
export function frenchStatus(catalog, message) {
  const entry = catalog[message.domain]?.get(`${message.context ?? ""}\u0004${message.msgid}`)
  if (!entry || entry.fuzzy || !entry.msgstr.length || entry.msgstr.some((s) => !s)) return { status: "pending" }
  const forms = message.plural ? [message.msgid, message.plural] : [message.msgid]
  return { status: entry.msgstr.every((s, i) => s === forms[Math.min(i, forms.length - 1)]) ? "identical" : "translated", msgstr: entry.msgstr }
}

// Texte visible → messages du code qui peuvent l'avoir produit (texte exact, ou gabarit avec %{…})
export function matcher(messages) {
  const exact = new Map(), patterns = []
  for (const message of messages)
    for (const form of [message.msgid, message.plural].filter(Boolean)) {
      const text = normalize(form)
      if (!text.includes("%{")) { if (!exact.has(text)) exact.set(text, []); exact.get(text).push(message); continue }
      const parts = text.split(/%\{\w+\}/)
      const fixed = parts.join("").trim().length
      const source = parts.map((part) => part.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("(.+?)")
      if (fixed >= 2) patterns.push([new RegExp(`^${source}$`, "s"), message, fixed])
    }
  return (text) => exact.get(text) || patterns.filter(([re, , fixed]) => fixed >= Math.max(4, 0.4 * text.length) && re.test(text)).map(([, m]) => m)
}

// Source de l'interface (gabarits, composants, scripts), espaces compactés, sans commentaires ni documentation :
// `literal(texte)` dit si le texte y figure entier, comme contenu d'une balise ou chaîne littérale (« >texte< »,
// « "texte" »), c'est-à-dire écrit en dur
export function webSource() {
  const source = [...files(join(WEB, "lib"), /\.(ex|heex)$/), ...files(join(WEB, "assets", "js"), /\.js$/)]
    .map((path) => normalize(readFileSync(path, "utf8")
      .replace(/@(?:module)?doc\s+(?:~S)?"""[\s\S]*?"""/g, "")
      .replace(/<%!--[\s\S]*?--%>/g, "")
      .replace(/^\s*(#|\/\/).*$/gm, ""))).join("\n")
  const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  return (text) => new RegExp(`(^|[>"'}\`])\\s?${escape(text)}\\s?($|[<"'{\`])`).test(source)
}
