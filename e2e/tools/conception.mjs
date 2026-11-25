// Schémas de conception (docs/conception) : génération depuis le code et les bases, vérification des références, rendu.
//   node tools/conception.mjs [mpd | classes | verifier | rendu [motif]]   (sans argument : tout)
// Tout reste local : les bases sont lues en lecture seule et le rendu refuse toute requête réseau.
import { chromium } from "playwright-core"
import { spawnSync } from "node:child_process"
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const ICI = path.dirname(fileURLToPath(import.meta.url))
const RACINE = path.resolve(ICI, "../..")
const DOSSIER = path.join(RACINE, "docs/conception")
const DOSSIER_MPD = path.join(DOSSIER, "05-mpd")
const DOSSIER_CLASSES = path.join(DOSSIER, "03-classes")
const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
const MERMAID = path.join(ICI, "../node_modules/mermaid/dist/mermaid.min.js")
const SERVICES = ["accounts", "learning", "billing", "social", "multiplayer", "community", "studio", "notifications"]
const TECHNIQUES = ["schema_migrations", "oban_jobs", "oban_peers"]
const POLICE = "Verdana, 'DejaVu Sans', Arial, sans-serif"
const GENERE = "%% FICHIER GÉNÉRÉ par e2e/tools/conception.mjs"

const base = (service) => `ml_${service}_${process.env.MPD_SUFFIXE || "dev"}`
const rel = (p) => path.relative(RACINE, p)

// ─────────────────────────────────────────────────────────────────────────────────────────────── MPD (bases réelles)

const SQL_INTROSPECTION = `
WITH t AS (
  SELECT c.oid, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind IN ('r','p')
)
SELECT json_build_object(
 'database', current_database(),
 'server_version', current_setting('server_version'),
 'extensions', (SELECT json_agg(extname || ' ' || extversion ORDER BY extname) FROM pg_extension),
 'migrations', (SELECT json_agg(version ORDER BY version) FROM schema_migrations),
 'tables', (SELECT json_agg(json_build_object(
  'table', t.relname,
  'columns', (SELECT json_agg(json_build_object('name', a.attname, 'type', format_type(a.atttypid, a.atttypmod),
       'not_null', a.attnotnull, 'default', pg_get_expr(d.adbin, d.adrelid)) ORDER BY a.attnum)
     FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
     WHERE a.attrelid = t.oid AND a.attnum > 0 AND NOT a.attisdropped),
  'constraints', (SELECT json_agg(json_build_object('name', co.conname, 'type', co.contype,
       'columns', (SELECT json_agg(att.attname ORDER BY k.ord) FROM unnest(co.conkey) WITH ORDINALITY k(attnum, ord)
                   JOIN pg_attribute att ON att.attrelid = co.conrelid AND att.attnum = k.attnum),
       'ref_table', (SELECT relname FROM pg_class WHERE oid = co.confrelid),
       'ref_columns', (SELECT json_agg(att.attname ORDER BY k.ord) FROM unnest(co.confkey) WITH ORDINALITY k(attnum, ord)
                   JOIN pg_attribute att ON att.attrelid = co.confrelid AND att.attnum = k.attnum),
       'on_delete', co.confdeltype, 'deferrable', co.condeferrable, 'deferred', co.condeferred,
       'definition', pg_get_constraintdef(co.oid)) ORDER BY co.contype, co.conname)
     FROM pg_constraint co WHERE co.conrelid = t.oid),
  'indexes', (SELECT json_agg(json_build_object('name', ic.relname, 'unique', ix.indisunique, 'primary', ix.indisprimary,
       'constraint', (SELECT conname FROM pg_constraint WHERE conindid = ix.indexrelid AND conrelid = t.oid LIMIT 1),
       'predicate', pg_get_expr(ix.indpred, ix.indrelid), 'definition', pg_get_indexdef(ix.indexrelid)) ORDER BY ic.relname)
     FROM pg_index ix JOIN pg_class ic ON ic.oid = ix.indexrelid WHERE ix.indrelid = t.oid),
  'triggers', (SELECT json_agg(json_build_object('name', tg.tgname, 'definition', pg_get_triggerdef(tg.oid)) ORDER BY tg.tgname)
     FROM pg_trigger tg WHERE tg.tgrelid = t.oid AND NOT tg.tgisinternal)
 ) ORDER BY t.relname) FROM t)
)`

// Colonnes qui désignent une ligne sans clé étrangère : vers une autre base (UUID) ou dans la même base. Relevé dans
// les migrations (commentaires « pas de clé étrangère inter-bases ») et dans le code qui écrit ces colonnes.
const MEMBRE = "accounts.users"
const REFERENCES_LOGIQUES = {
  accounts: {
    "audit_entries.actor_id": "users (staff)",
    "sanctions.issued_by": "users (staff)",
    "sanctions.lifted_by": "users (staff)",
    "sanction_appeals.decided_by": "users (staff)",
    "incidents.created_by": "users (staff)",
    "incidents.resolved_by": "users (staff)",
    "incident_updates.author_id": "users (staff)",
    "support_replies.author_id": "users (staff)",
    "audit_entries.target_id": "objet de n'importe quel service (texte)",
  },
  learning: {
    "*.user_id": MEMBRE,
    "adventures.author_id": MEMBRE,
    "adventures.external_id": "studio.projects si source = 'studio'",
  },
  billing: {
    "*.user_id": MEMBRE,
    "credit_entries.user_id": "credit_accounts et accounts.users",
  },
  social: {
    "friendships.requester_id": MEMBRE, "friendships.addressee_id": MEMBRE,
    "blocks.blocker_id": MEMBRE, "blocks.blocked_id": MEMBRE,
    "conversations.user_low": MEMBRE, "conversations.user_high": MEMBRE, "conversations.owner_id": MEMBRE,
    "conversation_members.user_id": MEMBRE, "messages.sender_id": MEMBRE, "messages.removed_by": MEMBRE,
    "attachments.uploader_id": MEMBRE, "reports.reporter_id": MEMBRE, "reports.message_sender_id": MEMBRE,
    "reports.resolved_by": MEMBRE, "settings.user_id": MEMBRE,
    "reports.sanction_id": "accounts.sanctions",
    "reports.target_id": "accounts.users ou messages selon target_type",
    "reports.message_attachment_id": "attachments (l'instantané survit)",
  },
  multiplayer: {
    "lobbies.host_id": MEMBRE, "lobby_members.user_id": MEMBRE, "lobby_invites.inviter_id": MEMBRE,
    "lobby_invites.invitee_id": MEMBRE, "lobby_links.created_by": MEMBRE, "lobby_messages.user_id": MEMBRE,
    "match_events.user_id": MEMBRE, "match_rewards.user_id": MEMBRE,
    "lobbies.current_match_id": "matches",
  },
  community: {
    "discussions.author_id": MEMBRE, "replies.author_id": MEMBRE, "votes.user_id": MEMBRE,
    "follows.user_id": MEMBRE, "reports.reporter_id": MEMBRE, "reports.resolved_by": MEMBRE,
    "moderation_log.moderator_id": MEMBRE,
    "votes.target_id": "discussions ou replies selon target_type",
    "reports.target_id": "discussions ou replies selon target_type",
    "moderation_log.target_id": "discussions ou replies selon target_type",
  },
  studio: {
    "projects.owner_id": MEMBRE, "projects.reviewed_by": MEMBRE, "collaborators.user_id": MEMBRE,
    "collaborators.invited_by": MEMBRE, "versions.author_id": MEMBRE, "images.uploader_id": MEMBRE,
    "media.uploader_id": MEMBRE, "generations.user_id": MEMBRE, "member_settings.user_id": MEMBRE,
    "projects.published_adventure_id": "learning.adventures (texte)",
    "generations.retry_of": "generations",
  },
  notifications: {
    "*.user_id": MEMBRE,
    "notifications.actor_id": MEMBRE,
    "pending_emails.actor_id": MEMBRE,
    "pending_emails.notification_id": "notifications",
    "notifications.subject_id": "objet du service producteur (texte)",
  },
}

// Effet des fonctions de déclencheur (corps lus dans les migrations).
const DECLENCHEURS = {
  audit_entries_append_only: "refuse toute modification ou suppression (journal en ajout seul)",
  credit_entries_immutable: "refuse toute modification d'une ligne du registre",
  studio_versions_immutable: "refuse toute modification d'une version (instantanés immuables)",
  lessons_track_revision: "fixe revision = 1 à l'insertion ; +1 et revised_at = now() si titre, sorte, texte, contenu ou solution changent",
}

const SUPPRESSION = { a: "NO ACTION", r: "RESTRICT", c: "CASCADE", n: "SET NULL", d: "SET DEFAULT" }

function environnementPg() {
  const env = { ...process.env, PGOPTIONS: "-c default_transaction_read_only=on" }
  if (process.env.DB_USER) env.PGUSER = process.env.DB_USER
  if (process.env.DB_PASSWORD) env.PGPASSWORD = process.env.DB_PASSWORD
  if (process.env.DB_HOST) env.PGHOST = process.env.DB_HOST
  return env
}

function lancer(commande, args) {
  const r = spawnSync(commande, args, { env: environnementPg(), encoding: "utf8", maxBuffer: 256 * 1024 * 1024 })
  if (r.error) throw new Error(`${commande} introuvable ou en échec : ${r.error.message}`)
  if (r.status !== 0) throw new Error(`${commande} ${args.join(" ")} : ${r.stderr.trim()}`)
  return r.stdout
}

// Types de format_type() abrégés par leurs alias PostgreSQL exacts (jeton unique exigé par erDiagram).
function typeCourt(type) {
  return type
    .replace(/character varying/g, "varchar")
    .replace(/ without time zone/g, "")
    .replace(/ with time zone/g, "tz")
    .replace(/\s+/g, "_")
}

function defautCourt(expr) {
  if (expr == null) return null
  return expr
    .replace(/^nextval\('([\w.]+)'::regclass\)$/, "nextval($1)")
    .replace(/::(character varying|text|jsonb|time|bpchar)(\[\])?(\s*without time zone)?/g, "")
    .replace(/ARRAY\[\]/g, "ARRAY[]")
}

// Définition d'un CHECK (ou prédicat d'index) rendue lisible sans en changer le sens : transtypages ::text retirés,
// « = ANY ((ARRAY[…])) » écrit « IN (…) », parenthèses autour d'un seul identifiant et paires redondantes « ((…)) »
// retirées. Les parenthèses qui portent une priorité sont gardées.
function checkLisible(definition) {
  let s = definition.startsWith("CHECK (") && definition.endsWith(")") ? definition.slice(7, -1) : definition
  s = s.replace(/::(character varying|text|bpchar)(\[\])?/g, "")
  s = s.replace(/= ANY \(\(ARRAY\[([^\]]*)\]\)\)/g, "IN ($1)").replace(/= ANY \(ARRAY\[([^\]]*)\]\)/g, "IN ($1)")
  s = s.replace(/(?<![\w"])\(("?\w+"?)\)/g, "$1")
  return sansRedondance(s).replace(/\s+/g, " ").trim()
}

function paires(s) {
  const pile = []
  const correspondances = new Map()
  let chaine = false
  for (let i = 0; i < s.length; i++) {
    if (s[i] === "'") chaine = !chaine
    if (chaine) continue
    if (s[i] === "(") pile.push(i)
    else if (s[i] === ")") correspondances.set(pile.pop(), i)
  }
  return correspondances
}

function sansRedondance(s) {
  for (let passe = 0; passe < 50; passe++) {
    const p = paires(s)
    const double = [...p].find(([i, j]) => s[i + 1] === "(" && p.get(i + 1) === j - 1)
    if (double) s = s.slice(0, double[0]) + s.slice(double[0] + 1, double[1]) + s.slice(double[1] + 1)
    else if (s[0] === "(" && p.get(0) === s.length - 1) s = s.slice(1, -1)
    else break
  }
  return s
}

function colonnesIndex(index, colonnes) {
  const corps = index.definition.replace(/^.*?USING \w+ \(/, "").replace(/\)( WHERE .*)?$/, "")
  if (/^[\w", ]+$/.test(corps)) return corps.split(",").map((c) => c.trim().replace(/"/g, "").replace(/ (ASC|DESC)$/, ""))
  return colonnes.filter((c) => new RegExp(`\\b${c}\\b`).test(corps))
}

function referenceLogique(service, table, colonne) {
  const refs = REFERENCES_LOGIQUES[service] || {}
  return refs[`${table}.${colonne}`] || (colonne === "user_id" ? refs["*.user_id"] : undefined)
}

function mmdMpd(service, db) {
  const tables = db.tables.filter((t) => !TECHNIQUES.includes(t.table))
  // LR : les tables d'un même rang s'empilent ; meilleur rapport à la page A4 que TB pour les 8 bases (mesuré)
  const lignes = [GENERE + " (mpd) depuis la base " + db.database + " — ne pas modifier à la main.", "erDiagram", "  direction LR"]
  const checks = []
  const partiels = []
  const declencheurs = []
  const relations = []

  for (const t of tables) {
    const contraintes = t.constraints || []
    const pk = contraintes.find((c) => c.type === "p")?.columns || []
    const fks = contraintes.filter((c) => c.type === "f")
    const uniques = [
      ...contraintes.filter((c) => c.type === "u").map((c) => ({ nom: c.name, colonnes: c.columns, predicat: null, differe: c.deferrable ? (c.deferred ? "DEFERRABLE INITIALLY DEFERRED" : "DEFERRABLE") : null })),
      ...(t.indexes || []).filter((i) => i.unique && !i.primary && !i.constraint).map((i) => ({
        nom: i.name, colonnes: colonnesIndex(i, t.columns.map((c) => c.name)), predicat: i.predicate,
        expression: !/USING \w+ \([\w", ]+\)/.test(i.definition) ? i.definition.replace(/^.*?USING \w+ /, "").replace(/ WHERE .*$/, "") : null,
      })),
    ]
    lignes.push(`  ${t.table} {`)
    for (const c of t.columns) {
      const cles = []
      if (pk.includes(c.name)) cles.push("PK")
      if (fks.some((f) => f.columns.includes(c.name))) cles.push("FK")
      if (uniques.some((u) => !u.predicat && !u.expression && u.colonnes.includes(c.name))) cles.push("UK")
      const notes = []
      if (c.not_null && !pk.includes(c.name)) notes.push("NN")
      const defaut = defautCourt(c.default)
      if (defaut) notes.push(`déf. ${defaut}`)
      for (const f of fks.filter((f) => f.columns.includes(c.name)))
        notes.push(`→ ${f.ref_table}.${f.ref_columns.join(", ")} ${SUPPRESSION[f.on_delete]}`)
      for (const u of uniques.filter((u) => u.colonnes.includes(c.name))) {
        if (u.expression) notes.push(`UQ ${u.expression}`)
        else if (u.predicat) notes.push(`UQ partiel (${u.colonnes.join(", ")}) WHERE ${checkLisible(u.predicat)}`)
        else if (u.colonnes.length > 1) notes.push(`UQ (${u.colonnes.join(", ")})${u.differe ? " " + u.differe : ""}`)
      }
      const logique = referenceLogique(service, t.table, c.name)
      if (logique) notes.push(`⇢ ${logique}`)
      const commentaire = notes.length ? ` "${notes.join(" · ").replace(/"/g, "'")}"` : ""
      lignes.push(`    ${typeCourt(c.type)} ${c.name}${cles.length ? " " + cles.join(", ") : ""}${commentaire}`)
    }
    lignes.push("  }")
    for (const c of contraintes.filter((c) => c.type === "c")) checks.push(`${t.table} — ${c.name} : ${checkLisible(c.definition)}`)
    for (const u of uniques.filter((u) => u.predicat || u.expression))
      partiels.push(`${t.table} — ${u.nom} : UNIQUE ${u.expression || "(" + u.colonnes.join(", ") + ")"}${u.predicat ? " WHERE " + checkLisible(u.predicat) : ""}`)
    for (const g of t.triggers || []) {
      const m = g.definition.match(/CREATE TRIGGER (\w+) (BEFORE|AFTER) (.+?) ON .*EXECUTE FUNCTION (\w+)\(\)/)
      if (m) declencheurs.push(`${t.table} — ${m[1]} (${m[2]} ${m[3]}, ${m[4]}()) : ${DECLENCHEURS[m[4]] || "voir ddl"}`)
    }
    for (const f of fks) {
      const colonnes = t.columns.filter((c) => f.columns.includes(c.name))
      const obligatoire = colonnes.every((c) => c.not_null)
      const unique = uniques.some((u) => !u.predicat && !u.expression && u.colonnes.length === f.columns.length && f.columns.every((c) => u.colonnes.includes(c)))
        || (pk.length === f.columns.length && f.columns.every((c) => pk.includes(c)))
      const identifiante = f.columns.every((c) => pk.includes(c))
      relations.push(`  ${f.ref_table} ${obligatoire ? "||" : "|o"}${identifiante ? "--" : ".."}${unique ? "o|" : "o{"} ${t.table} : "${f.columns.join(", ")}"`)
    }
  }
  lignes.push(...relations)

  const derniere = db.migrations?.at(-1)
  const legende = [
    `%% @titre MPD — base ${db.database} (service ${service}) : modèle physique relevé dans PostgreSQL`,
    `%% @legende Relevé en lecture seule dans pg_catalog le ${new Date().toISOString().slice(0, 10)} (PostgreSQL ${db.server_version.replace(/ \(.*\)$/, "")}, ${db.migrations?.length || 0} migrations appliquées, dernière : ${derniere}) par e2e/tools/conception.mjs mpd.`,
    "%% @legende Notation : PK clé primaire · FK clé étrangère · UK colonne d'une contrainte ou d'un index d'unicité complet · NN = NOT NULL · déf. = valeur par défaut · UQ (a, b) = unicité composée · → table.colonne CASCADE | SET NULL | NO ACTION = cible de la clé étrangère et sa règle ON DELETE · ⇢ = référence SANS clé étrangère (autre base, ou colonne qui vise plusieurs tables).",
    "%% @legende Types : alias PostgreSQL exacts — varchar(n) = character varying(n), timestamp(0) = timestamp(0) without time zone, time(0) = time(0) without time zone.",
    "%% @legende Liens : uniquement les clés étrangères réelles (trait plein : identifiante, la FK fait partie de la PK ; pointillé : non identifiante). Une référence vers une autre base (⇢ accounts.users…) n'a jamais de clé étrangère : chaque base est séparée ; elle est seulement signalée en commentaire (relevé dans les migrations et le code).",
    `%% @legende Omis (simplification) : tables techniques ${db.tables.filter((t) => TECHNIQUES.includes(t.table)).map((t) => t.table).join(", ")} ; index non uniques. Définitions complètes : 05-mpd/ddl/${db.database}.sql (pg_dump --schema-only).`,
  ]
  if (checks.length) legende.push("%% @legende Contraintes CHECK (transtypages ::text omis pour la lecture) :", ...checks.map((c) => `%% @legende • ${c}`))
  if (partiels.length) legende.push("%% @legende Index uniques partiels ou sur expression :", ...partiels.map((c) => `%% @legende • ${c}`))
  if (declencheurs.length) legende.push("%% @legende Déclencheurs :", ...declencheurs.map((c) => `%% @legende • ${c}`))
  return [lignes[0], ...legende, ...lignes.slice(1)].join("\n") + "\n"
}

function etapeMpd() {
  for (const dossier of ["donnees", "ddl"]) mkdirSync(path.join(DOSSIER_MPD, dossier), { recursive: true })
  for (const service of SERVICES) {
    const nom = base(service)
    const brut = lancer("psql", ["-X", "-A", "-t", "-q", "-v", "ON_ERROR_STOP=1", "-d", nom, "-c", SQL_INTROSPECTION])
    const db = JSON.parse(brut)
    writeFileSync(path.join(DOSSIER_MPD, "donnees", `${nom}.json`), JSON.stringify(db, null, 1) + "\n")
    const ddl = lancer("pg_dump", ["--schema-only", "--no-owner", "--no-privileges", "--no-comments", "-d", nom])
    writeFileSync(path.join(DOSSIER_MPD, "ddl", `${nom}.sql`), ddl)
    writeFileSync(path.join(DOSSIER_MPD, `mpd-${service}.mmd`), mmdMpd(service, db))
    const n = db.tables.filter((t) => !TECHNIQUES.includes(t.table)).length
    console.log(`mpd   ${nom} : ${n} tables (+ ${db.tables.length - n} techniques), ${db.migrations?.length || 0} migrations → 05-mpd/mpd-${service}.mmd`)
  }
}

// ─────────────────────────────────────────────────────────────────────────── classes (schémas Ecto + modules)

// Modules de contexte retenus et leurs fonctions clés : chaque fonction est cherchée dans le source (nom et arité),
// chaque schéma « utilisé » doit être nommé dans le source du module. Une entrée introuvable arrête la génération.
const CONTEXTES = {
  accounts: [
    { module: "MlAccounts", fonctions: ["register/1", "confirm/1", "login/3", "complete_two_factor_login/3", "get_session_user/1", "change_password/3", "request_password_reset/1", "reset_password/2", "update_profile/2", "update_preferences/2"], utilise: ["User", "Session", "ConfirmationToken", "LoginChallenge", "LoginFailure", "UserToken"] },
    { module: "MlAccounts.TwoFactor", fonctions: ["setup/2", "enable/3", "disable/3", "verify/3", "regenerate_recovery_codes/2"], utilise: ["User", "RecoveryCode"] },
    { module: "MlAccounts.Privacy", fonctions: ["request_export/2", "build_export/2", "schedule_deletion/2", "cancel_deletion/1", "execute_deletion/1"], utilise: ["DataExport", "DeletionStep"] },
    { module: "MlAccounts.Sanctions", fonctions: ["issue/3", "lift/3", "appeal/3", "decide/3"], utilise: ["Sanction", "SanctionAppeal"] },
    { module: "MlAccounts.Support", fonctions: ["create/2", "reply/3", "update/3", "delete/2", "purge/1"], utilise: ["SupportRequest", "SupportReply"] },
    { module: "MlAccounts.Audit", fonctions: ["record!/6", "create/2", "list/1", "export/2"], utilise: ["AuditEntry"] },
    { module: "MlAccounts.Incidents", fonctions: ["open/2", "add_update/3", "list/1"], utilise: ["Incident", "IncidentUpdate"] },
    { module: "MlAccounts.Throttle", fonctions: ["reserve/3", "reserve/5", "clear/1"], utilise: [] },
  ],
  learning: [
    { module: "MlLearning.Catalog", fonctions: ["list_adventures/1", "fetch_adventure/1", "fetch_lesson/1", "neighbours/1"], utilise: ["Adventure", "Chapter", "Lesson"] },
    { module: "MlLearning.Progress", fonctions: ["enroll/2", "open/2", "submit/3", "complete/2", "award_xp/3", "dashboard/2"], utilise: ["Enrollment", "LessonProgress", "XpEvent"] },
    { module: "MlLearning.Grader", fonctions: ["grade/3"], utilise: ["Lesson"] },
    { module: "MlLearning.Gamification", fonctions: ["after_xp/2", "settle_quests/2", "profile/1"], utilise: [] },
    { module: "MlLearning.Gamification.Badges", fonctions: ["award/2", "achievements/2", "equip/2"], utilise: ["Badge", "UserBadge"] },
    { module: "MlLearning.Gamification.Quests", fonctions: ["settle/2"], utilise: ["Quest"] },
    { module: "MlLearning.Offline", fonctions: ["package/3", "submit/4", "complete/4"], utilise: ["Action", "Lesson"] },
    { module: "MlLearning.Entitlements", fonctions: ["check/2", "premium?/1", "fresh/1"], utilise: [] },
    { module: "MlLearning.Importer", fonctions: ["import/1"], utilise: ["Adventure", "Chapter", "Lesson"] },
  ],
  billing: [
    { module: "MlBilling", fonctions: ["entitlements/2", "create_checkout/2", "simulate_payment/3", "cancel/1", "resume/1", "broadcast/1"], utilise: ["Subscription", "CheckoutSession", "Invoice"] },
    { module: "MlBilling.Webhooks", fonctions: ["handle/3"], utilise: ["WebhookEvent", "Subscription", "Invoice", "CheckoutSession"] },
    { module: "MlBilling.Credits", fonctions: ["reserve/5", "consume/3", "release/3", "adjust/5", "sync_plan/2", "overview/3"], utilise: ["CreditAccount", "CreditEntry"] },
    { module: "MlBilling.Signature", fonctions: ["header/3", "verify/4"], utilise: [] },
    { module: "MlBilling.Notices", fonctions: ["transition!/2"], utilise: [] },
    { module: "MlBilling.PeriodEndWorker", fonctions: ["perform/1"], utilise: ["Subscription"] },
  ],
  social: [
    { module: "MlSocial.Chat", fonctions: ["list/1", "open/2", "messages/3", "send_message/3", "mark_read/2", "mute/3"], utilise: ["Conversation", "Member", "Message"] },
    { module: "MlSocial.Groups", fonctions: ["create/2", "rename/3", "add_member/3", "remove_member/3", "leave/2"], utilise: ["Conversation", "Member", "Message"] },
    { module: "MlSocial.Friends", fonctions: ["send_request/2", "accept/2", "decline/2", "remove/2", "block/2", "unblock/2"], utilise: ["Friendship", "Block"] },
    { module: "MlSocial.Attachments", fonctions: ["prepare/1", "store!/1", "read/2", "erase/1"], utilise: ["Attachment"] },
    { module: "MlSocial.Delivery", fonctions: ["new_message/2", "message_removed/1", "read/3", "changed/2"], utilise: [] },
    { module: "MlSocial.Settings", fonctions: ["get/1", "update/2", "can_contact/3"], utilise: ["Setting"] },
    { module: "MlSocial.Moderation", fonctions: ["list/1", "evidence/3", "resolve/3"], utilise: ["Report"] },
    { module: "MlSocial.Reports", fonctions: ["create/2"], utilise: ["Report"] },
  ],
  multiplayer: [
    { module: "MlMultiplayer.Lobbies", fonctions: ["create/2", "join/2", "approve/3", "set_ready/3", "start/3", "attempt/3", "leave/2", "kick/3"], utilise: ["Lobby", "Member"] },
    { module: "MlMultiplayer.Invitations", fonctions: ["invite/3", "accept/2", "decline/2", "create_link/4", "join_link/3"], utilise: ["Invite", "Link"] },
    { module: "MlMultiplayer.Matches", fonctions: ["create!/3", "replay/1", "commit/4"], utilise: ["Match", "MatchEvent"] },
    { module: "MlMultiplayer.MatchServer", fonctions: ["propose/3", "set_absent/3", "abort/2"], utilise: [] },
    { module: "MlMultiplayer.RuneRelay", fonctions: ["start_event/2", "init/1", "decide/3", "score/2"], utilise: [] },
    { module: "MlMultiplayer.Chat", fonctions: ["list/3", "post/4"], utilise: ["Message"] },
    { module: "MlMultiplayer.Rewards", fonctions: ["finalize/2", "deliver_due/1"], utilise: ["Reward"] },
    { module: "MlMultiplayer.Presence", fonctions: ["heartbeat/3", "sweep/1"], utilise: ["Member"] },
  ],
  community: [
    { module: "MlCommunity.Forum", fonctions: ["categories/0", "list_discussions/2", "fetch_discussion/2", "list_replies/3"], utilise: ["Category", "Discussion", "Reply"] },
    { module: "MlCommunity.Posts", fonctions: ["create_discussion/2", "update_discussion/3", "create_reply/3", "set_solution/3", "follow/2"], utilise: ["Discussion", "Reply", "Follow"] },
    { module: "MlCommunity.Votes", fonctions: ["set/3"], utilise: ["Vote"] },
    { module: "MlCommunity.Reports", fonctions: ["create/2", "list_open/1", "resolve/3"], utilise: ["Report"] },
    { module: "MlCommunity.Moderation", fonctions: ["act/4", "log/6"], utilise: ["ModerationEntry"] },
  ],
  studio: [
    { module: "MlStudio.Projects", fonctions: ["create/2", "get/2", "update_brief/3", "add_module/3", "add_lesson/4", "update_lesson/4", "invite/3", "create_version/3", "restore_version/3"], utilise: ["Project", "CourseModule", "Lesson", "Collaborator", "Version"] },
    { module: "MlStudio.AI", fonctions: ["info/1", "set_consent/2", "create/4", "cancel/2", "retry/3", "apply/2", "run/2", "settle/1"], utilise: ["Generation", "Setting"] },
    { module: "MlStudio.Publishing", fonctions: ["checks/2", "attest/3", "submit/2", "approve/2", "reject/3", "retry_import/2"], utilise: ["Project"] },
    { module: "MlStudio.Images", fonctions: ["upload/3", "store_generated/4", "delete/3"], utilise: ["Image"] },
    { module: "MlStudio.Media", fonctions: ["upload_video/4", "add_captions/4", "fetch_published/1"], utilise: ["Medium"] },
    { module: "MlStudio.Services", fonctions: ["reserve/4", "settle/3", "import_adventure/1", "plan/1"], utilise: [] },
    { module: "MlStudio.AI.GenerationWorker", fonctions: ["perform/1"], utilise: ["Generation"] },
    { module: "MlStudio.AI.SettleWorker", fonctions: ["perform/1"], utilise: ["Generation"] },
  ],
  notifications: [
    { module: "MlNotifications.Inbox", fonctions: ["create/3", "list/2", "unread_count/1", "read/3", "read_all/2", "read_by_key/3", "clear_between/1", "purge/1"], utilise: ["Notification", "PendingEmail"] },
    { module: "MlNotifications.Preferences", fonctions: ["get/1", "enabled?/4", "update/3"], utilise: ["Setting"] },
    { module: "MlNotifications.Emails", fonctions: ["plan/4", "limited?/3", "request/2"], utilise: ["EmailLog", "PendingEmail"] },
    { module: "MlNotifications.QuietHours", fonctions: ["active?/2", "ends_at/2"], utilise: [] },
    { module: "MlNotifications.Catalog", fonctions: ["validate/2", "mandatory?/1"], utilise: [] },
    { module: "MlNotifications.EmailWorker", fonctions: ["perform/1"], utilise: [] },
    { module: "MlNotifications.DigestWorker", fonctions: ["perform/1"], utilise: [] },
  ],
}

function fichiersEx(dossier) {
  return readdirSync(dossier, { withFileTypes: true }).flatMap((e) =>
    e.isDirectory() ? fichiersEx(path.join(dossier, e.name)) : e.name.endsWith(".ex") ? [path.join(dossier, e.name)] : [])
}

// Découpe « a, %{b: c}, d \\ 1 » au niveau supérieur (parenthèses, crochets, accolades, chaînes).
function decouper(texte) {
  const parts = []
  let profondeur = 0
  let chaine = false
  let courant = ""
  for (let i = 0; i < texte.length; i++) {
    const c = texte[i]
    if (c === '"' && texte[i - 1] !== "\\") chaine = !chaine
    if (!chaine) {
      if ("([{".includes(c)) profondeur++
      if (")]}".includes(c)) profondeur--
      if (c === "," && profondeur === 0) {
        parts.push(courant.trim())
        courant = ""
        continue
      }
    }
    courant += c
  }
  if (courant.trim()) parts.push(courant.trim())
  return parts
}

function parametresDe(tete) {
  return decouper(tete).map((p) => {
    const sansDefaut = p.split("\\\\")[0].trim()
    const egal = sansDefaut.split(/\s=\s/).map((s) => s.trim())
    const variable = egal.reverse().find((s) => /^[a-z_][a-zA-Z0-9_]*[?!]?$/.test(s))
    if (variable) return variable.replace(/^_(?=[a-z])/, "")
    const structure = sansDefaut.match(/^%([A-Z][\w.]*)\{/)
    if (structure) return structure[1].split(".").at(-1).replace(/([a-z0-9])([A-Z])/g, "$1_$2").toLowerCase()
    if (/^%\{/.test(sansDefaut)) return "map"
    if (/^"/.test(sansDefaut)) return sansDefaut
    return "…"
  })
}

// Têtes publiques « def nom(…) » d'un module (premier niveau d'indentation), avec arités possibles (valeurs par défaut).
function definitions(source) {
  const defs = []
  const re = /^ {2}def ([a-z_][a-zA-Z0-9_?!]*)(\(|,|\s+do\b|\s+when\b|$)/gm
  let m
  while ((m = re.exec(source))) {
    let parametres = []
    if (m[2] === "(") {
      let i = m.index + m[0].length
      let profondeur = 1
      let fin = i
      while (fin < source.length && profondeur > 0) {
        if (source[fin] === "(") profondeur++
        if (source[fin] === ")") profondeur--
        fin++
      }
      parametres = decouper(source.slice(i, fin - 1).replace(/\s+/g, " "))
    }
    const defauts = parametres.filter((p) => p.includes("\\\\")).length
    defs.push({ nom: m[1], arites: [parametres.length - defauts, parametres.length], noms: parametresDe(parametres.join(", ")), ligne: source.slice(0, m.index).split("\n").length + 1 })
  }
  return defs
}

function indexModules(service) {
  const index = new Map()
  for (const fichier of fichiersEx(path.join(RACINE, "src", service, "lib"))) {
    const source = readFileSync(fichier, "utf8")
    const morceaux = source.split(/^(?=defmodule )/m)
    let decalage = 0
    for (const morceau of morceaux) {
      const m = morceau.match(/^defmodule ([\w.]+) do/)
      if (m) index.set(m[1], { fichier, source: morceau, ligne: source.slice(0, decalage).split("\n").length })
      decalage += morceau.length
    }
  }
  return index
}

function typeEcto(type) {
  const t = type.trim()
  const tableau = t.match(/^\{:array,\s*:?([\w.]+)\}$/)
  if (tableau) return `array~${tableau[1]}~`
  return t.replace(/^:/, "")
}

// Mermaid refuse « { } » dans un attribut de classe : la source porte des accolades pleine chasse (｛｝), que le rendu
// remet en accolades ordinaires ; le SVG et le PNG affichent donc le littéral Elixir exact (%{}).
function valeurDefaut(texte) {
  return texte.trim().replace(/\{/g, "｛").replace(/\}/g, "｝")
}

function optionsDe(reste) {
  const opts = {}
  for (const part of decouper(reste)) {
    const m = part.match(/^([a-z_]+):\s*(.+)$/s)
    if (m) opts[m[1]] = m[2].trim()
  }
  return opts
}

// Lit le bloc `schema "table" do … end` (ou embedded_schema) d'un module Ecto.
function lireSchema(nom, entree) {
  const src = entree.source
  const bloc = src.match(/^ {2}(schema "(\w+)"|embedded_schema) do\n([\s\S]*?)^ {2}end$/m)
  if (!bloc) return null
  const table = bloc[2] || null
  const attrsModule = src.slice(0, bloc.index)
  const cle = attrsModule.match(/@primary_key\s+(false|\{:(\w+),\s*:?([\w.]+)(?:,[^}]*)?\})/)
  const typeFk = attrsModule.match(/@foreign_key_type\s+:?([\w.]+)/)?.[1] || "id"
  const optsHorodatage = attrsModule.match(/@timestamps_opts\s+\[(.*)\]/)?.[1]
  const champs = []
  const associations = []
  if (!cle && table) champs.push({ nom: "id", type: "id", pk: true })
  else if (cle && cle[1] !== "false") champs.push({ nom: cle[2], type: typeEcto(":" + cle[3]), pk: true })
  for (const brute of bloc[3].split("\n")) {
    const ligne = brute.trim()
    let m
    if ((m = ligne.match(/^field :(\w+)(?:,\s*(\{[^}]*\}|[\w.:]+))?(?:,\s*(.*))?$/))) {
      const opts = optionsDe(m[3] || "")
      champs.push({ nom: m[1], type: typeEcto(m[2] || ":string"), pk: opts.primary_key === "true", virtuel: opts.virtual === "true", masque: opts.redact === "true", defaut: opts.default && valeurDefaut(opts.default) })
    } else if ((m = ligne.match(/^belongs_to :(\w+),\s*([\w.]+)(?:,\s*(.*))?$/))) {
      const opts = optionsDe(m[3] || "")
      const fk = opts.foreign_key?.replace(/^:/, "") || `${m[1]}_id`
      champs.push({ nom: fk, type: typeEcto(opts.type || ":" + typeFk), pk: opts.primary_key === "true", fk: true })
      associations.push({ type: "belongs_to", nom: m[1], cible: m[2], fk })
    } else if ((m = ligne.match(/^(has_many|has_one|embeds_one|embeds_many) :(\w+),\s*([\w.]+)(?:,\s*(.*))?$/))) {
      const opts = optionsDe(m[4] || "")
      associations.push({ type: m[1], nom: m[2], cible: m[3], fk: opts.foreign_key?.replace(/^:/, "") })
    } else if ((m = ligne.match(/^timestamps\((.*)\)$/))) {
      const opts = optionsDe(m[1] || optsHorodatage || "")
      const type = typeEcto(opts.type || ":naive_datetime")
      if (opts.inserted_at !== "false") champs.push({ nom: "inserted_at", type })
      if (opts.updated_at !== "false") champs.push({ nom: "updated_at", type })
    }
  }
  return { nom, table, champs, associations, fichier: entree.fichier, ligne: entree.ligne }
}

function idClasse(module) {
  return module.replace(/^Ml\w+?\./, "").replace(/\./g, "_")
}

function mmdClasses(service, db) {
  const index = indexModules(service)
  const schemas = []
  for (const [nom, entree] of index) {
    const s = /^ {2}(schema "|embedded_schema)/m.test(entree.source) && lireSchema(nom, entree)
    if (s) schemas.push(s)
  }
  schemas.sort((a, b) => (a.table || "~").localeCompare(b.table || "~"))
  const parTable = new Map(schemas.filter((s) => s.table).map((s) => [s.table, s]))
  const parNom = new Map(schemas.map((s) => [s.nom, s]))
  const court = (nom) => nom.split(".").at(-1)

  const lignes = [GENERE + " (classes) depuis src/" + service + "/lib et la base " + db.database + " — ne pas modifier à la main."]
  const refs = []
  const blocSchemas = []
  for (const s of schemas) {
    blocSchemas.push(`    class ${idClasse(s.nom)}["${s.nom}"] {`)
    blocSchemas.push(`      <<${s.table ? "schema " + s.table : "embedded_schema"}>>`)
    for (const c of s.champs) {
      const marques = [c.pk && "«PK»", c.fk && "«FK»", c.virtuel && "«virtual»", c.masque && "«redact»"].filter(Boolean)
      blocSchemas.push(`      +${c.nom} : ${c.type}${c.defaut ? " = " + c.defaut : ""}${marques.length ? " " + marques.join(" ") : ""}`)
    }
    for (const a of s.associations.filter((a) => a.type.startsWith("embeds"))) blocSchemas.push(`      +${a.nom} : ${court(a.cible)} «embeds»`)
    blocSchemas.push("    }")
    refs.push(`%% @ref ${court(s.nom)} ${rel(s.fichier)}:${s.ligne} | defmodule ${s.nom} do`)
  }

  const blocModules = []
  const dependances = []
  const erreurs = []
  const methodesDeSchema = new Map()
  for (const ctx of CONTEXTES[service]) {
    const entree = index.get(ctx.module)
    if (!entree) {
      erreurs.push(`module introuvable : ${ctx.module}`)
      continue
    }
    const defs = definitions(entree.source)
    const travail = entree.source.match(/use Oban\.Worker,\s*queue: :(\w+)/)
    const genserver = /use GenServer/.test(entree.source)
    // module qui est aussi un schéma Ecto (ex. MlAccounts.Throttle) : ses fonctions vont dans la boîte du schéma
    const aussiSchema = schemas.some((sc) => sc.nom === ctx.module)
    const boite = aussiSchema ? [] : blocModules
    boite.push(`    class ${idClasse(ctx.module)}["${ctx.module}"] {`)
    boite.push(`      <<${travail ? "Oban.Worker file " + travail[1] : genserver ? "module GenServer" : "module"}>>`)
    for (const f of ctx.fonctions) {
      const [nomF, arite] = f.split("/")
      const clauses = defs.filter((d) => d.nom === nomF && Number(arite) >= d.arites[0] && Number(arite) <= d.arites[1])
      const d = clauses[0]
      if (!d) {
        const arites = defs.filter((d) => d.nom === nomF).map((d) => d.arites.join("..")).join(", ")
        erreurs.push(`fonction introuvable : ${ctx.module}.${f} (${rel(entree.fichier)}${arites ? ", arités présentes : " + arites : ""})`)
        continue
      }
      // nom de chaque paramètre : la première variable nommée à cette position parmi les clauses de même arité
      const noms = Array.from({ length: Number(arite) }, (_, i) =>
        clauses.map((c) => c.noms[i]).find((n) => n && !["map", "…"].includes(n) && !n.startsWith('"')) || d.noms[i])
      boite.push(`      +${nomF}(${noms.join(", ")})`)
      if (aussiSchema) methodesDeSchema.set(ctx.module, [...(methodesDeSchema.get(ctx.module) || []), `      +${nomF}(${noms.join(", ")})`])
    }
    boite.push("    }")
    for (const u of ctx.utilise) {
      const cible = schemas.find((s) => court(s.nom) === u)
      if (!new RegExp(`\\b${u}\\b`).test(entree.source) || !cible) {
        erreurs.push(`${ctx.module} : schéma « ${u} » ${cible ? "non nommé dans le module" : "introuvable"}`)
        continue
      }
      if (cible.nom !== ctx.module) dependances.push(`  ${idClasse(ctx.module)} ..> ${idClasse(cible.nom)}`)
    }
    if (!aussiSchema) refs.push(`%% @ref ${court(ctx.module)} ${rel(entree.fichier)}:${entree.ligne} | defmodule ${ctx.module} do`)
  }
  for (const [module, methodes] of methodesDeSchema) {
    const fin = blocSchemas.findIndex((l, i) => i > blocSchemas.indexOf(`    class ${idClasse(module)}["${module}"] {`) && l === "    }")
    blocSchemas.splice(fin, 0, ...methodes)
  }
  if (erreurs.length) throw new Error(`classes ${service} :\n  ` + erreurs.join("\n  "))

  // Associations : une par clé étrangère réelle (multiplicités tirées de NOT NULL et des index uniques), nommée par
  // les associations Ecto qui la couvrent ; puis embeds_one.
  const associations = []
  for (const t of db.tables.filter((t) => parTable.has(t.table))) {
    const enfant = parTable.get(t.table)
    const contraintes = t.constraints || []
    const pk = contraintes.find((c) => c.type === "p")?.columns || []
    for (const f of contraintes.filter((c) => c.type === "f")) {
      const parent = parTable.get(f.ref_table)
      if (!parent) continue
      const colonne = f.columns[0]
      const obligatoire = t.columns.find((c) => c.name === colonne)?.not_null
      const unique = (t.indexes || []).some((i) => i.unique && !i.predicate && new RegExp(`\\(${colonne}\\)$`).test(i.definition))
        || (pk.length === 1 && pk[0] === colonne)
      const cote = enfant.associations.find((a) => a.type === "belongs_to" && a.fk === colonne)
      const inverse = parent.associations.find((a) => ["has_many", "has_one"].includes(a.type) && parNom.get(a.cible) === enfant && (!a.fk || a.fk === colonne))
      const noms = [inverse && `${inverse.type} ${inverse.nom}`, cote && `belongs_to ${cote.nom}`].filter(Boolean)
      const etiquette = noms.length ? noms.join(" / ") : `FK ${colonne} (champ simple)`
      associations.push(`  ${idClasse(parent.nom)} "${obligatoire ? "1" : "0..1"}" -- "${unique ? "0..1" : "0..*"}" ${idClasse(enfant.nom)} : ${etiquette}`)
    }
  }
  for (const s of schemas)
    for (const a of s.associations.filter((a) => a.type === "embeds_one"))
      associations.push(`  ${idClasse(s.nom)} "1" *-- "1" ${idClasse(parNom.get(a.cible)?.nom || a.cible)} : embeds_one ${a.nom}`)

  lignes.push(
    `%% @titre Diagramme de classes — service ${service} : schémas Ecto et modules de contexte`,
    "%% @legende Elixir n'a pas de classes : chaque boîte « schema » est un schéma Ecto (une structure liée à une table) ; chaque boîte « module » est un module de fonctions (contexte métier), sans état ni instance.",
    "%% @legende Attributs : champs du schéma Ecto avec leur type Ecto (binary_id, Ecto.UUID, utc_datetime…) et leur valeur par défaut ; «PK» clé primaire, «FK» champ de belongs_to, «virtual» non enregistré en base, «redact» masqué dans les journaux, «embeds» structure incluse (embeds_one).",
    "%% @legende Associations : une par clé étrangère réelle de la base ; multiplicités tirées de NOT NULL (1 ou 0..1) et des index uniques (0..1 ou 0..*) ; libellé = association Ecto qui la porte, ou « champ simple » quand le schéma n'a qu'un champ *_id. Les identifiants d'une autre base (user_id…) ne sont pas des associations : voir le MCD et le MPD.",
    "%% @legende Modules : fonctions publiques clés seulement (sélection), paramètres tels qu'écrits dans la première clause ; flèche pointillée = le module manipule ce schéma. Généré par e2e/tools/conception.mjs classes (noms et arités vérifiés dans le source).",
    ...refs,
    "classDiagram",
    "  direction LR",
    '  note "Elixir n’a pas de classes : ce diagramme représente les structures (schémas Ecto) et les modules (fonctions)."',
    "  namespace Schémas_Ecto {",
    ...blocSchemas,
    "  }",
    "  namespace Modules_de_contexte {",
    ...blocModules,
    "  }",
    ...associations,
    ...dependances,
  )
  return lignes.join("\n") + "\n"
}

function etapeClasses() {
  mkdirSync(DOSSIER_CLASSES, { recursive: true })
  const erreurs = []
  for (const service of SERVICES) {
   try {
    const fichier = path.join(DOSSIER_MPD, "donnees", `${base(service)}.json`)
    if (!existsSync(fichier)) throw new Error(`${rel(fichier)} absent : lancez d'abord « node tools/conception.mjs mpd »`)
    const db = JSON.parse(readFileSync(fichier, "utf8"))
    writeFileSync(path.join(DOSSIER_CLASSES, `classes-${service}.mmd`), mmdClasses(service, db))
    console.log(`classes ${service} → 03-classes/classes-${service}.mmd`)
   } catch (e) {
    erreurs.push(e.message)
   }
  }
  if (erreurs.length) throw new Error(erreurs.join("\n"))
}

// ──────────────────────────────────────────────────────────────────────────────── vérification des références

function sourcesMmd(filtre) {
  const tous = []
  const parcourir = (d) => {
    for (const e of readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name)
      if (e.isDirectory()) parcourir(p)
      else if (e.name.endsWith(".mmd")) tous.push(p)
    }
  }
  parcourir(DOSSIER)
  return tous.sort().filter((p) => !filtre || rel(p).includes(filtre))
}

// « %% @ref <repère> <chemin depuis la racine>:<ligne>[-<ligne>] | <texte attendu dans ces lignes> »
function lireRefs(source) {
  return source.split("\n").flatMap((l) => {
    const m = l.match(/^%%\s*@ref\s+(\S+)\s+(\S+?):(\d+)(?:-(\d+))?\s*\|\s*(.+?)\s*$/)
    return m ? [{ repere: m[1], chemin: m[2], debut: Number(m[3]), fin: Number(m[4] || m[3]), attendu: m[5] }] : []
  })
}

function etapeVerifier(filtre) {
  let total = 0
  const erreurs = []
  for (const fichier of sourcesMmd(filtre)) {
    for (const r of lireRefs(readFileSync(fichier, "utf8"))) {
      total++
      const cible = path.join(RACINE, r.chemin)
      if (!existsSync(cible)) {
        erreurs.push(`${rel(fichier)} [${r.repere}] fichier absent : ${r.chemin}`)
        continue
      }
      const lignes = readFileSync(cible, "utf8").split("\n")
      const extrait = lignes.slice(r.debut - 1, r.fin).join("\n")
      if (r.fin > lignes.length || !extrait.includes(r.attendu)) {
        const trouve = lignes.findIndex((l) => l.includes(r.attendu))
        erreurs.push(`${rel(fichier)} [${r.repere}] « ${r.attendu} » absent de ${r.chemin}:${r.debut}-${r.fin}${trouve >= 0 ? ` (présent ligne ${trouve + 1})` : ""}`)
      }
    }
  }
  console.log(`verifier : ${total} références contrôlées, ${erreurs.length} en défaut`)
  for (const e of erreurs) console.log("  ✗ " + e)
  return erreurs.length === 0
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────── rendu

const CONFIG_MERMAID = {
  startOnLoad: false,
  securityLevel: "strict",
  theme: "base",
  look: "classic",
  htmlLabels: false,
  fontFamily: POLICE,
  flowchart: { htmlLabels: false, curve: "basis", padding: 12, nodeSpacing: 40, rankSpacing: 55, wrappingWidth: 320 },
  sequence: { mirrorActors: false, messageAlign: "center", actorMargin: 40, boxMargin: 8, noteMargin: 8, wrap: false },
  class: { htmlLabels: false },
  er: { layoutDirection: "LR", minEntityWidth: 80 },
  themeVariables: {
    fontFamily: POLICE,
    fontSize: "14px",
    primaryColor: "#f2f3f5",
    primaryTextColor: "#111111",
    primaryBorderColor: "#4b5563",
    secondaryColor: "#fbfbf3",
    tertiaryColor: "#ffffff",
    lineColor: "#374151",
    textColor: "#111111",
    mainBkg: "#f2f3f5",
    nodeBorder: "#4b5563",
    clusterBkg: "#fafafa",
    clusterBorder: "#9ca3af",
    edgeLabelBackground: "#ffffff",
    noteBkgColor: "#fff7d6",
    noteTextColor: "#111111",
    noteBorderColor: "#a8a29e",
    actorBkg: "#f2f3f5",
    actorBorder: "#4b5563",
    actorTextColor: "#111111",
    actorLineColor: "#6b7280",
    signalColor: "#111111",
    signalTextColor: "#111111",
    labelBoxBkgColor: "#eceef1",
    labelBoxBorderColor: "#6b7280",
    labelTextColor: "#111111",
    loopTextColor: "#111111",
    activationBkgColor: "#e5e7eb",
    activationBorderColor: "#6b7280",
    attributeBackgroundColorOdd: "#ffffff",
    attributeBackgroundColorEven: "#f6f7f9",
  },
  // usecase-beta : texte centré dans les ellipses, texte des notes sans contour, traits foncés pour l'impression
  themeCSS: [
    ".usecase-ellipse text{text-anchor:middle}",
    ".usecase-note text{fill:#111111;stroke:none}",
    ".usecase-note path[fill]{fill:#fff7d6}",
    ".usecase-actor path,.usecase-actor circle,.usecase-actor line{stroke:#374151}",
    "text{stroke:none}",
  ].join(" "),
}

// Balises de mise en forme des libellés (<b>, <u>, <i>) remplacées par des marqueurs invisibles avant Mermaid (qui,
// sans HTML, les afficherait telles quelles), puis rendues en <tspan> stylés : le SVG reste du SVG pur.
function preparer(source) {
  return source
    .split("\n")
    .map((l) => (l.trimStart().startsWith("%%") ? l : l.replace(/<\/?b>/g, "\u2062").replace(/<\/?u>/g, "\u2063").replace(/<\/?i>/g, "\u2061")))
    .join("\n")
}

function directives(source) {
  const lire = (cle) => source.split("\n").flatMap((l) => {
    const m = l.match(new RegExp(`^%%\\s*@${cle}\\s+(.*)$`))
    return m ? [m[1].trim()] : []
  })
  return { titre: lire("titre")[0] || "", legendes: lire("legende"), refs: lireRefs(source) }
}

// Exécuté dans la page : rendu, mise en forme des marqueurs, trait sous le nom des entités, composition finale.
async function rendreDansLaPage([id, source, opts, police]) {
  const NS = "http://www.w3.org/2000/svg"
  const { svg } = await window.mermaid.render(id, source)
  const hote = document.getElementById("hote")
  hote.innerHTML = svg
  const dessin = hote.querySelector("svg")

  for (const texte of dessin.querySelectorAll("text")) {
    if (!/[\u2061\u2062\u2063]/.test(texte.textContent)) continue
    const etat = { g: false, s: false, i: false }
    const noeuds = []
    const marcheur = document.createTreeWalker(texte, NodeFilter.SHOW_TEXT)
    while (marcheur.nextNode()) noeuds.push(marcheur.currentNode)
    for (const n of noeuds) {
      const fragment = document.createDocumentFragment()
      for (const p of n.data.split(/([\u2061\u2062\u2063])/)) {
        if (p === "\u2062") etat.g = !etat.g
        else if (p === "\u2063") etat.s = !etat.s
        else if (p === "\u2061") etat.i = !etat.i
        else if (p) {
          if (etat.g || etat.s || etat.i) {
            const t = document.createElementNS(NS, "tspan")
            if (etat.g) t.setAttribute("font-weight", "bold")
            if (etat.s) t.setAttribute("text-decoration", "underline")
            if (etat.i) t.setAttribute("font-style", "italic")
            t.textContent = p
            fragment.appendChild(t)
          } else fragment.appendChild(document.createTextNode(p))
        }
      }
      n.replaceWith(fragment)
    }
  }

  // MCD : trait horizontal sous la première ligne (nom de l'entité) des nœuds de classe « entite »
  for (const noeud of dessin.querySelectorAll("g.node.entite, g.node.externe")) {
    const cadre = noeud.querySelector(".label-container") || noeud.querySelector("rect")
    const rangs = [...noeud.querySelectorAll("tspan.row")]
    if (!cadre || rangs.length < 2) continue
    const b = cadre.getBBox()
    const inverse = noeud.getScreenCTM().inverse()
    const bas = rangs[0].getBoundingClientRect().bottom
    const haut = rangs[1].getBoundingClientRect().top
    const y = new DOMPoint(0, (bas + haut) / 2).matrixTransform(inverse).y + 2
    const trait = document.createElementNS(NS, "line")
    for (const [k, v] of Object.entries({ x1: b.x, x2: b.x + b.width, y1: y, y2: y, stroke: "#4b5563", "stroke-width": 1 })) trait.setAttribute(k, v)
    cadre.after(trait)
  }

  // dimensions naturelles du dessin
  const [vx, vy, vw, vh] = dessin.getAttribute("viewBox").split(/[\s,]+/).map(Number)

  // séquences : sans acteurs répétés en bas (mirrorActors: false), Mermaid laisse les lignes de vie à y2 = 2000 ;
  // elles sont prolongées jusqu'au bas du dessin
  for (const ligne of dessin.querySelectorAll("line.actor-line, line[class*='actor-line']"))
    ligne.setAttribute("y2", String(vy + vh - 8))
  dessin.setAttribute("width", vw)
  dessin.setAttribute("height", vh)
  dessin.removeAttribute("style")

  // composition : titre, dessin, légende (texte mesuré et replié)
  const marge = 28
  const largeurMin = 900
  const W = Math.ceil(Math.max(vw + 2 * marge, largeurMin))
  const contexte = document.createElement("canvas").getContext("2d")
  const mesure = (t, taille, gras) => {
    contexte.font = `${gras ? "bold " : ""}${taille}px ${police}`
    return contexte.measureText(t).width
  }
  const replier = (texte, largeur, taille, gras = false) => {
    const mots = texte.split(" ")
    const lignes = []
    let courante = ""
    for (const mot of mots) {
      const essai = courante ? courante + " " + mot : mot
      if (mesure(essai, taille, gras) > largeur && courante) {
        lignes.push(courante)
        courante = mot
      } else courante = essai
    }
    if (courante) lignes.push(courante)
    return lignes
  }
  const echapper = (t) => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  const morceaux = []
  let y = marge
  if (opts.titre) {
    for (const l of replier(opts.titre, W - 2 * marge, 19, true)) {
      y += 22
      morceaux.push(`<text x="${marge}" y="${y}" font-size="19" font-weight="bold" fill="#111111">${echapper(l)}</text>`)
    }
    y += 16
  }
  const dx = Math.round((W - vw) / 2)
  const yDessin = y
  y += vh + 18
  const corps = 12.5
  const interligne = 17
  if (opts.legendes.length) {
    morceaux.push(`<line x1="${marge}" x2="${W - marge}" y1="${y}" y2="${y}" stroke="#9ca3af" stroke-width="1"/>`)
    y += 8
    for (const legende of opts.legendes) {
      const puce = legende.startsWith("• ")
      const retrait = puce ? 14 : 0
      replier(legende, W - 2 * marge - retrait, corps).forEach((l, i) => {
        y += interligne
        morceaux.push(`<text x="${marge + (i === 0 ? 0 : retrait)}" y="${y}" font-size="${corps}" fill="#1f2937">${echapper(l)}</text>`)
      })
    }
    y += 6
  }
  if (opts.refs.length) {
    const groupes = []
    for (const r of opts.refs) {
      const cle = r.repere
      const texte = `${r.chemin.replace(/^src\//, "")}:${r.debut}${r.fin !== r.debut ? "-" + r.fin : ""}`
      const g = groupes.find((g) => g.cle === cle)
      if (g) g.textes.push(texte)
      else groupes.push({ cle, textes: [texte] })
    }
    y += interligne + 4
    morceaux.push(`<text x="${marge}" y="${y}" font-size="${corps}" font-weight="bold" fill="#111111">${echapper(opts.titreRefs)}</text>`)
    const items = groupes.map((g) => `${g.cle} — ${g.textes.join(" ; ")}`)
    const largeurItem = Math.max(...items.map((t) => mesure(t, corps - 0.5))) + 28
    const colonnes = Math.max(1, Math.min(3, Math.floor((W - 2 * marge) / largeurItem)))
    const parColonne = Math.ceil(items.length / colonnes)
    const largeurColonne = (W - 2 * marge) / colonnes
    let yMax = y
    items.forEach((item, i) => {
      const c = Math.floor(i / parColonne)
      const lignes = colonnes === 1 ? replier(item, W - 2 * marge - 14, corps - 0.5) : [item]
      const yItem = y + (i % parColonne + 1) * interligne + (colonnes === 1 ? 0 : 0)
      lignes.forEach((l, k) => {
        morceaux.push(`<text x="${marge + c * largeurColonne + (k ? 14 : 0)}" y="${yItem + k * interligne}" font-size="${corps - 0.5}" fill="#1f2937">${echapper(l)}</text>`)
      })
      yMax = Math.max(yMax, yItem + (lignes.length - 1) * interligne)
    })
    y = yMax + 6
  }
  const H = Math.ceil(y + marge)
  dessin.setAttribute("x", dx)
  dessin.setAttribute("y", yDessin)
  const interieur = new XMLSerializer().serializeToString(dessin)
  const final = `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" font-family="${police.replace(/"/g, "'")}">` +
    `<rect width="${W}" height="${H}" fill="#ffffff"/>${morceaux.join("")}${interieur}</svg>`
  hote.innerHTML = ""
  return { svg: final.replace(/[\u2061\u2062\u2063]/g, "").replace(/｛/g, "{").replace(/｝/g, "}"), largeur: W, hauteur: H, objetsEtrangers: (final.match(/<foreignObject/g) || []).length }
}

async function etapeRendu(filtre) {
  if (!existsSync(MERMAID)) throw new Error("mermaid absent : lancez « cd e2e && npm install »")
  const fichiers = sourcesMmd(filtre)
  const navigateur = await chromium.launch({ executablePath: CHROME, headless: true })
  const bloquees = []
  const page = await navigateur.newPage()
  await page.route("**/*", (route) => {
    bloquees.push(route.request().url())
    route.abort()
  })
  await page.setContent('<!doctype html><html><head><meta charset="utf-8"></head><body><div id="hote"></div></body></html>')
  await page.addScriptTag({ content: readFileSync(MERMAID, "utf8") })
  await page.evaluate((config) => window.mermaid.initialize(config), CONFIG_MERMAID)
  const photo = await navigateur.newPage({ deviceScaleFactor: 1 })
  await photo.route("**/*", (route) => {
    bloquees.push(route.request().url())
    route.abort()
  })
  let n = 0
  let echecs = 0
  for (const fichier of fichiers) {
    const source = readFileSync(fichier, "utf8")
    const d = directives(source)
    const opts = { titre: d.titre, legendes: d.legendes, refs: d.refs, titreRefs: /02-sequences/.test(fichier) ? "Origine de chaque étape dans le code (fichier : lignes — « src/ » omis)" : "Sources dans le dépôt (fichier : lignes — « src/ » omis)" }
    let resultat
    try {
      resultat = await page.evaluate(rendreDansLaPage, [`d${n++}`, preparer(source), opts, POLICE])
    } catch (e) {
      echecs++
      console.log(`✗ ${rel(fichier)} : ${String(e.message || e).split("\n").slice(0, 3).join(" ")}`)
      continue
    }
    const sortie = fichier.replace(/\.mmd$/, "")
    writeFileSync(sortie + ".svg", resultat.svg)
    // PNG pour une impression A4 (zone utile 17 × 25 cm) : au moins 300 ppp une fois la figure ajustée à la page,
    // échelle comprise entre 2 et 4, côté plafonné à 16 000 px (limite de Chrome)
    const { largeur: W, hauteur: H } = resultat
    const ajuste = W / H > 17 / 25 ? 2008 / W : 2953 / H
    const echelle = Math.min(Math.max(ajuste, 2), 4, 16000 / W, 16000 / H)
    const w = Math.round(W * echelle)
    const h = Math.round(H * echelle)
    await photo.setViewportSize({ width: w, height: h })
    const donnees = Buffer.from(resultat.svg).toString("base64")
    await photo.setContent(`<!doctype html><html><body style="margin:0;background:#fff"><img id="i" width="${w}" height="${h}" src="data:image/svg+xml;base64,${donnees}"></body></html>`)
    await photo.locator("#i").evaluate((img) => img.decode())
    writeFileSync(sortie + ".png", await photo.screenshot({ type: "png", clip: { x: 0, y: 0, width: w, height: h } }))
    const ppp = Math.round((W / H > 17 / 25 ? w / (17 / 2.54) : h / (25 / 2.54)))
    console.log(`rendu ${rel(fichier)} → svg ${W}×${H}, png ${w}×${h} (≈ ${ppp} ppp en A4)${resultat.objetsEtrangers ? " ⚠ foreignObject" : ""}`)
  }
  await navigateur.close()
  console.log(`rendu : ${fichiers.length - echecs}/${fichiers.length} schémas ; requêtes réseau bloquées : ${bloquees.length} (attendu : 0)`)
  if (bloquees.length) console.log("  " + bloquees.slice(0, 5).join("\n  "))
  return echecs === 0 && bloquees.length === 0
}

// ───────────────────────────────────────────────────────────────────────────────────────────────── commande

const [commande = "tout", filtre] = process.argv.slice(2)
try {
  if (commande === "mpd") etapeMpd()
  else if (commande === "classes") etapeClasses()
  else if (commande === "verifier") process.exitCode = etapeVerifier(filtre) ? 0 : 1
  else if (commande === "rendu") process.exitCode = (await etapeRendu(filtre)) ? 0 : 1
  else if (commande === "tout") {
    etapeMpd()
    etapeClasses()
    if (!etapeVerifier()) throw new Error("références en défaut : corrigez les « %% @ref » avant le rendu")
    process.exitCode = (await etapeRendu()) ? 0 : 1
  } else {
    console.log("usage : node tools/conception.mjs [tout|mpd|classes|verifier|rendu [motif]]")
    process.exitCode = 2
  }
} catch (e) {
  console.error("✗ " + e.message)
  process.exitCode = 1
}
