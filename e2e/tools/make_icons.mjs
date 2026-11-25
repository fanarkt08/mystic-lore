// Génère les icônes de l'application installable à partir du sigle de la marque, dessiné en SVG puis photographié.
// Usage : cd e2e && node tools/make_icons.mjs   (écrit dans src/web/priv/static/icons/)
import { chromium } from "playwright-core"
import { mkdirSync, writeFileSync } from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
const OUT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../src/web/priv/static/icons")
const COLORS = { canvas: "#090e20", raised: "#192440", line: "#2c3858", magic: "#ad8bff", reward: "#edca85" }

// Le sigle (viewBox 32×32) : mêmes formes que brand_mark/1.
const mark = (x, y, size) => `
  <g transform="translate(${x} ${y}) scale(${size / 32})">
    <circle cx="16" cy="16" r="15" fill="${COLORS.raised}" stroke="${COLORS.line}" stroke-width="1" />
    <path d="M16 5l2.6 7.9H27l-6.8 4.9 2.6 8L16 21l-6.8 4.8 2.6-8L5 12.9h8.4z" fill="${COLORS.magic}" />
    <circle cx="16" cy="16" r="2.2" fill="${COLORS.reward}" />
  </g>`

function svg(size, maskable) {
  if (maskable) {
    // zone sûre : cercle de rayon 0,4 × taille ; le sigle (cercle de rayon 15/32) y tient avec une marge
    const markSize = size * 0.62
    const offset = (size - markSize) / 2
    return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">
      <rect width="${size}" height="${size}" fill="${COLORS.canvas}" />${mark(offset, offset, markSize)}</svg>`
  }
  const radius = size * 0.22
  const markSize = size * 0.8
  const offset = (size - markSize) / 2
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">
    <rect width="${size}" height="${size}" rx="${radius}" fill="${COLORS.canvas}" />${mark(offset, offset, markSize)}</svg>`
}

const ICONS = [
  ["icon-192.png", 192, false],
  ["icon-512.png", 512, false],
  ["icon-maskable-512.png", 512, true],
]

const browser = await chromium.launch({ executablePath: CHROME, headless: true })
mkdirSync(OUT, { recursive: true })
for (const [name, size, maskable] of ICONS) {
  const page = await browser.newPage({ viewport: { width: size, height: size }, deviceScaleFactor: 1 })
  await page.setContent(`<!doctype html><html><body style="margin:0;background:transparent">${svg(size, maskable)}</body></html>`)
  const png = await page.locator("svg").screenshot({ type: "png", omitBackground: true })
  writeFileSync(path.join(OUT, name), png)
  console.log(`${name} : ${size}×${size}${maskable ? " (maskable)" : ""}, ${(png.length / 1024).toFixed(1)} Ko`)
  await page.close()
}
await browser.close()
console.log(`→ ${OUT}`)
