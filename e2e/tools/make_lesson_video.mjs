// Génère la vidéo de la leçon « Lire le ciel de nuit », son affiche et ses sous-titres, avec MediaRecorder dans Chrome.
// Usage : cd e2e && node tools/make_lesson_video.mjs   (écrit dans src/web/priv/static/media/lessons/)
import { chromium } from "playwright-core"
import { mkdirSync, writeFileSync } from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
const OUT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../src/web/priv/static/media/lessons")
const NAME = "reading-the-night-sky"
const DURATION = 34 // secondes
const W = 960, H = 540

// Répliques : temps (s), anglais, français. La transcription de la leçon (seeds learning) reprend ce texte.
const CUES = [
  [0.5, 5.0, "Tonight we read the night sky, one landmark at a time.",
    "Ce soir, nous lisons le ciel nocturne, un repère après l'autre."],
  [5.0, 10.5, "Watch long enough and every star turns slowly around one point: the north celestial pole.",
    "Observez assez longtemps : chaque étoile tourne lentement autour d'un point, le pôle céleste nord."],
  [10.5, 16.0, "Seven bright stars draw the Great Dipper: four for the bowl, three for the handle.",
    "Sept étoiles brillantes dessinent la Grande Ourse : quatre pour la casserole, trois pour le manche."],
  [16.0, 21.5, "Follow its two pointer stars, Merak then Dubhe, about five times the gap between them…",
    "Suivez ses deux étoiles de repère, Merak puis Dubhé, sur environ cinq fois leur écart…"],
  [21.5, 26.0, "…and you reach Polaris, the pole star, which barely moves all night.",
    "…et vous atteignez Polaris, l'étoile polaire, qui bouge à peine de la nuit."],
  [26.0, 30.5, "On the other side of Polaris, the W of Cassiopeia keeps watch.",
    "De l'autre côté de Polaris, le W de Cassiopée veille."],
  [30.5, 34.0, "Find the pointers, follow them north, and you will never lose your way.",
    "Trouvez les repères, suivez-les vers le nord, et vous ne perdrez jamais votre chemin."],
]

// Animation (exécutée dans la page) : tout dépend du temps t, image par image (rendu identique à chaque appel).
const PAGE = `<!doctype html><html><body style="margin:0;background:#000">
<canvas id="c" width="${W}" height="${H}"></canvas>
<script>
const c = document.getElementById("c"), g = c.getContext("2d"), W = ${W}, H = ${H}
let seed = 7; const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647
const pole = { x: W * 0.6, y: H * 0.3 }
const field = Array.from({ length: 320 }, () => ({ a: rnd() * Math.PI * 2, d: 30 + rnd() * 620, m: rnd(), p: rnd() * 6 }))
// Grande Ourse et Cassiopée, coordonnées relatives au pôle (px)
const dipper = { Alkaid: [-330, 150], Mizar: [-260, 112], Alioth: [-200, 108], Megrez: [-140, 118],
  Phecda: [-138, 190], Merak: [-40, 205], Dubhe: [-30, 122] }
const dipperPath = ["Alkaid", "Mizar", "Alioth", "Megrez", "Dubhe", "Merak", "Phecda", "Megrez"]
const cassiopeia = [[150, -150], [205, -95], [255, -140], [305, -85], [360, -128]]
const ease = (x) => x <= 0 ? 0 : x >= 1 ? 1 : x * x * (3 - 2 * x)
const fade = (t, a, b, f = 0.8) => Math.min(ease((t - a) / f), ease((b - t) / f))
function rot(p, angle) { const [x, y] = p, s = Math.sin(angle), k = Math.cos(angle); return [pole.x + x * k - y * s, pole.y + x * s + y * k] }
function star(x, y, r, alpha, color = "255,247,230") {
  g.fillStyle = "rgba(" + color + "," + alpha + ")"; g.beginPath(); g.arc(x, y, r, 0, Math.PI * 2); g.fill()
}
function label(text, x, y, alpha, size = 18, color = "#edca85") {
  g.globalAlpha = alpha; g.fillStyle = color; g.font = size + "px Georgia, serif"; g.fillText(text, x, y); g.globalAlpha = 1
}
function title(text, sub, alpha) {
  g.globalAlpha = alpha; g.textAlign = "center"; g.fillStyle = "#f3f1ff"; g.font = "bold 52px Georgia, serif"
  g.fillText(text, W / 2, H * 0.78); if (sub) { g.font = "22px Georgia, serif"; g.fillStyle = "#ad8bff"; g.fillText(sub, W / 2, H * 0.86) }
  g.textAlign = "left"; g.globalAlpha = 1
}
window.drawAt = function (t) {
  const sky = g.createLinearGradient(0, 0, 0, H); sky.addColorStop(0, "#0b1230"); sky.addColorStop(1, "#1d1440")
  g.fillStyle = sky; g.fillRect(0, 0, W, H)
  const angle = -0.05 * Math.max(0, t - 5) // le ciel tourne autour du pôle (sens antihoraire vu du nord)
  for (const s of field) {
    const tw = 0.55 + 0.45 * Math.sin(t * 2.3 + s.p)
    const [x, y] = rot([Math.cos(s.a) * s.d, Math.sin(s.a) * s.d], angle)
    star(x, y, 0.6 + s.m * 1.3, (0.35 + 0.5 * s.m) * tw)
  }
  // traînées circulaires (scène 2)
  const trails = fade(t, 5, 10.5)
  if (trails > 0) { g.strokeStyle = "rgba(116,230,226," + 0.35 * trails + ")"; g.lineWidth = 1
    for (const d of [90, 170, 260, 360]) { g.beginPath(); g.arc(pole.x, pole.y, d, 0, Math.PI * 2); g.stroke() } }
  // Grande Ourse
  const dip = Object.fromEntries(Object.entries(dipper).map(([k, p]) => [k, rot(p, angle)]))
  const dipAlpha = ease((t - 10.5) / 1.2) * (1 - 0.6 * ease((t - 26) / 1))
  for (const [x, y] of Object.values(dip)) star(x, y, 3.4, 0.9)
  if (dipAlpha > 0) {
    const n = Math.min(dipperPath.length - 1, (t - 10.5) * 2.2)
    g.strokeStyle = "rgba(173,139,255," + dipAlpha + ")"; g.lineWidth = 2.5; g.beginPath()
    for (let i = 0; i <= Math.floor(n); i++) { const [x, y] = dip[dipperPath[i]]; i ? g.lineTo(x, y) : g.moveTo(x, y) }
    g.stroke()
    label("La Grande Ourse", dip.Alkaid[0] - 20, dip.Alkaid[1] + 52, dipAlpha, 22, "#ad8bff")
  }
  // étoiles de repère → Polaris
  const ptr = ease((t - 16) / 4.5)
  if (t > 16 && t < 30.5) {
    const a = fade(t, 16, 30.5)
    const [mx, my] = dip.Merak, [dx, dy] = dip.Dubhe, px = mx + (pole.x - mx) * ptr, py = my + (pole.y - my) * ptr
    star(mx, my, 6, 0.5 * a, "237,202,133"); star(dx, dy, 6, 0.5 * a, "237,202,133")
    g.setLineDash([8, 8]); g.strokeStyle = "rgba(237,202,133," + a + ")"; g.lineWidth = 2
    g.beginPath(); g.moveTo(mx, my); g.lineTo(px, py); g.stroke(); g.setLineDash([])
    label("Merak", mx + 10, my + 22, a); label("Dubhé", dx + 10, dy - 10, a)
  }
  const pol = ease((t - 21.5) / 1)
  star(pole.x, pole.y, 4.2 + 2.5 * pol, 0.95)
  if (pol > 0) { star(pole.x, pole.y, 16, 0.18 * pol, "116,230,226"); label("Polaris", pole.x + 16, pole.y - 12, pol, 24, "#74e6e2") }
  // Cassiopée
  const cas = fade(t, 26, 40)
  const cp = cassiopeia.map((p) => rot(p, angle))
  for (const [x, y] of cp) star(x, y, 3.2, 0.85)
  if (cas > 0) { g.strokeStyle = "rgba(143,224,181," + cas + ")"; g.lineWidth = 2.5; g.beginPath()
    cp.forEach(([x, y], i) => i ? g.lineTo(x, y) : g.moveTo(x, y)); g.stroke(); label("Cassiopée", cp[2][0] - 30, cp[2][1] - 24, cas, 22, "#8fe0b5") }
  title("Lire le ciel de nuit", "MysticLore · L'Atlas céleste", fade(t, 0.3, 5.2))
  title("Suivez les repères vers le nord", null, fade(t, 30.5, 40))
}
window.record = async function (seconds) {
  const stream = c.captureStream(30)
  const mime = MediaRecorder.isTypeSupported("video/webm;codecs=vp9") ? "video/webm;codecs=vp9" : "video/webm"
  const rec = new MediaRecorder(stream, { mimeType: mime, videoBitsPerSecond: 650000 })
  const chunks = []; rec.ondataavailable = (e) => e.data.size && chunks.push(e.data)
  const done = new Promise((r) => (rec.onstop = r))
  const t0 = performance.now(); drawAt(0); rec.start(1000)
  const timer = setInterval(() => { const t = (performance.now() - t0) / 1000; drawAt(Math.min(t, seconds)); if (t >= seconds) { clearInterval(timer); rec.stop() } }, 1000 / 30)
  await done
  const buf = new Uint8Array(await new Blob(chunks, { type: "video/webm" }).arrayBuffer())
  let s = ""; for (let i = 0; i < buf.length; i += 0x8000) s += String.fromCharCode.apply(null, buf.subarray(i, i + 0x8000))
  return { mime, data: btoa(s), elapsed: (performance.now() - t0) / 1000 }
}
</script></body></html>`

// ---- Durée WebM : insère/remplace l'élément Duration (0x4489, flottant 64 bits, en unités TimecodeScale) dans Info.
function vint(buf, pos, keepMarker) {
  const first = buf[pos]; let len = 1, mask = 0x80
  while (len <= 8 && !(first & mask)) { len++; mask >>= 1 }
  let value = keepMarker ? first : first & (mask - 1)
  for (let i = 1; i < len; i++) value = value * 256 + buf[pos + i]
  return { value, len }
}
function sizeVint(n) { const b = Buffer.alloc(8); b[0] = 0x01; b.writeUIntBE(Math.floor(n / 2 ** 32), 1, 3); b.writeUInt32BE(n >>> 0, 4); return b }
function withDuration(webm, durationMs) {
  let pos = 0
  const ebml = vint(webm, pos, true); const ebmlSize = vint(webm, pos + ebml.len)
  pos += ebml.len + ebmlSize.len + ebmlSize.value // après l'en-tête EBML
  const seg = vint(webm, pos, true); if (seg.value !== 0x18538067) throw new Error("no Segment")
  const segSize = vint(webm, pos + seg.len)
  let child = pos + seg.len + segSize.len
  while (child < webm.length) {
    const id = vint(webm, child, true), size = vint(webm, child + id.len)
    const dataStart = child + id.len + size.len
    if (id.value === 0x1549a966) { // Info
      const parts = []; let p = dataStart, scale = 1000000
      while (p < dataStart + size.value) {
        const cid = vint(webm, p, true), csize = vint(webm, p + cid.len), end = p + cid.len + csize.len + csize.value
        if (cid.value === 0x2ad7b1) scale = webm.readUIntBE(p + cid.len + csize.len, csize.value)
        if (cid.value !== 0x4489) parts.push(webm.subarray(p, end))
        p = end
      }
      const dur = Buffer.alloc(11); dur[0] = 0x44; dur[1] = 0x89; dur[2] = 0x88; dur.writeDoubleBE(durationMs * 1e6 / scale, 3)
      const body = Buffer.concat([...parts, dur])
      return Buffer.concat([webm.subarray(0, child), Buffer.from([0x15, 0x49, 0xa9, 0x66]), sizeVint(body.length), body, webm.subarray(dataStart + size.value)])
    }
    if (size.value >= 2 ** (7 * size.len) - 1) break // taille inconnue (Cluster en direct) : Info manquant
    child = dataStart + size.value
  }
  throw new Error("no Info element")
}

const stamp = (s) => { const ms = Math.round(s * 1000), m = Math.floor(ms / 60000), r = ms % 60000; return `${String(m).padStart(2, "0")}:${String(Math.floor(r / 1000)).padStart(2, "0")}.${String(r % 1000).padStart(3, "0")}` }
const vtt = (i) => "WEBVTT\n\n" + CUES.map(([a, b, ...t], n) => `${n + 1}\n${stamp(a)} --> ${stamp(b)}\n${t[i]}\n`).join("\n")

const browser = await chromium.launch({ executablePath: CHROME, headless: true, args: ["--autoplay-policy=no-user-gesture-required"] })
const page = await browser.newPage({ viewport: { width: W, height: H } })
await page.setContent(PAGE)
console.log(`Enregistrement de ${DURATION} s (${W}×${H})…`)
const { mime, data, elapsed } = await page.evaluate((s) => window.record(s), DURATION)
const webm = withDuration(Buffer.from(data, "base64"), elapsed * 1000)
await page.evaluate(() => window.drawAt(24))
const poster = await page.locator("#c").screenshot({ type: "jpeg", quality: 82 })
await browser.close()

mkdirSync(OUT, { recursive: true })
writeFileSync(path.join(OUT, `${NAME}.webm`), webm)
writeFileSync(path.join(OUT, `${NAME}.jpg`), poster)
writeFileSync(path.join(OUT, `${NAME}.en.vtt`), vtt(0))
writeFileSync(path.join(OUT, `${NAME}.fr.vtt`), vtt(1))
console.log(`${mime} · ${(webm.length / 1e6).toFixed(2)} Mo · ${elapsed.toFixed(1)} s · affiche ${(poster.length / 1e3).toFixed(0)} Ko → ${OUT}`)
