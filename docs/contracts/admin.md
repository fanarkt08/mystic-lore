# Administration & modération : contrat (écran 12)

Routes du staff et des admins de **tous** les services, journal
d'audit central, sanctions et appels, incidents, indicateurs. Mêmes règles transverses que `docs/CONTRACTS.md`
(jeton interne, JSON, UUID, ISO 8601 UTC, `{"error": code}`, `422 {"error":"invalid","errors":{…}}`, pagination
`{"entries","page","total_pages","total"}`). Matrice des droits : [docs/admin-permissions.md](../admin-permissions.md).

## Rôles (règle commune à chaque service)
- **staff** = rôle `moderator` ou `admin` ; **admin** = rôle `admin`. Le rôle est lu chez accounts
  (`GET /api/internal/users/:id`) pour le membre porté par le jeton interne (`conn.assigns.user_id`) : jamais depuis
  le corps, l'URL, un en-tête ou la formule d'abonnement (un VIP n'est pas admin). accounts lit sa propre base.
- Cache : social et multiplayer 10 s, community 30 s, **invalidés aussitôt** par `{:sanction_changed, id}` /
  `{:role_changed, id}` sur le topic `"members"` ; learning, billing et studio relisent à chaque appel.
- Rôle insuffisant : `403 forbidden`. accounts injoignable : `503 roles_unavailable` (social, community, multiplayer,
  learning, billing) ou `503 accounts_unavailable` (studio) : jamais d'accès par défaut.

## Journal d'audit central (accounts)
Table `audit_entries` en **ajout seul** (déclencheur PostgreSQL : `UPDATE`/`DELETE` refusés). Entrée :
`{"id" (entier croissant),"service","actor":{"id","username","display_name"},"action","target_type","target_id","reason","metadata","inserted_at"}`.
`action` = `"<service>.<objet>.<verbe>"`. Chaque action du staff de chaque service écrit son entrée **dans la
transaction de l'action** (ou, pour une lecture de preuve, **avant** de répondre) : si l'entrée ne peut pas être
écrite, l'action est annulée (`503 audit_unavailable`).

| Méthode & chemin | Jeton | Entrée | Sortie |
|---|---|---|---|
| `POST /api/internal/audit` | **service** ; appelants `social`, `community`, `multiplayer`, `billing`, `learning`, `studio` (sinon `403 forbidden`, `web` compris) | `{actor_id (UUID, requis), action (préfixée par "<appelant>.", ≤ 80, ^[a-z_]+(\.[a-z_]+){1,3}$), target_type? (≤ 40), target_id? (≤ 120), reason? (≤ 2000), metadata? (objet ≤ 4 Ko)}` | `201 {"id"}` · `422` : `metadata` refusée si une clé (à toute profondeur, casse ignorée) vaut `body, content, text, message, message_body, details, password, token, secret, code, email, payload` : **jamais de secret, d'e-mail ni de contenu de message** |
| `GET /api/admin/audit` | admin | `?action=` (préfixe) `&actor=` (pseudonyme ou UUID) `&from=&to=` (AAAA-MM-JJ, inclus) `&page=` | page de 50 entrées, plus récentes d'abord · `422` (date invalide) |
| `GET /api/admin/audit/export` | admin | mêmes filtres | `200 text/csv` (RFC 4180, en-tête `id,inserted_at,service,actor_id,actor_username,action,target_type,target_id,reason,metadata`), **10 000 lignes au plus** (les plus récentes ; en-tête de réponse `x-export-truncated: true|false`). Toute cellule commençant par `= + - @`, une tabulation ou un retour chariot est préfixée par `'`. L'export est **lui-même audité** (`accounts.audit.exported`, filtres et nombre de lignes) avant d'être renvoyé |

## accounts (4001)
Membre vu du staff : `{"id","username","display_name","email","email_masked":bool,"role","confirmed","restricted_until"|null,"deletion_scheduled_at"|null,"inserted_at"}` :
e-mail **masqué** (`o•••@domaine`) pour un modérateur, complet pour un admin. Fiche : + `{"bio","two_factor":bool,"sanctions":[sanction]}`.
Sanction (staff) : `{"id","user_id","kind":"warning|restriction","reason","status":"active|expired|lifted","ends_at"|null,"ref"|null,"issued_by":personne,"inserted_at","lifted_at","lifted_by","lift_reason","appeals":[appel]}`.
Appel : `{"id","sanction_id","status":"open|accepted|rejected","body","decision_reason","decided_at","decided_by","inserted_at"}` (+ `"member"` et `"sanction"` dans la file).
Incident : `{"id","title","severity":"low|medium|high|critical","status":"open|investigating|resolved","summary","created_by","resolved_by","resolved_at","inserted_at","updated_at"}` (+ `"updates":[{"id","body","status","severity","author","inserted_at"}]` en détail).

| Méthode & chemin | Accès | Entrée | Sortie |
|---|---|---|---|
| `GET /api/admin/stats` | staff | | `200 {"stats":{"members","new_7d","confirmed","restricted","open_appeals","sanctions_7d","open_incidents"}}` (comptes de comptes non anonymisés) |
| `GET /api/admin/users` | staff | `?q` (préfixe pseudonyme / nom affiché ; + e-mail pour un admin) `&role&page` | page de 25 membres (comptes anonymisés exclus). Admin : consultation **auditée** (`accounts.members.listed`) |
| `GET /api/admin/users/:id` | staff | | `200 {"user": fiche}` · 404. Admin : consultation auditée (`accounts.member.viewed`) |
| `PUT /api/admin/users/:id/role` | **admin** | `{role: user|moderator|admin, reason (5..500)}` | `200 {"user"}` · `403 self` (jamais son propre rôle) · `409 last_admin` · `403 forbidden` (l'auteur n'est plus admin) · 422 · 404. Lignes admin verrouillées (`FOR UPDATE`) puis rôle de l'auteur revérifié sous ce verrou. Audit `accounts.role.changed` `{from,to}` ; `{:role_changed, id}` sur `"user:<id>"` et `"members"` |
| `POST /api/admin/users/:id/sanctions` | staff | `{kind: warning|restriction, reason (5..1000), duration_hours (1..720, restriction seulement), ref? (^[a-z]+:[A-Za-z0-9:_-]{1,120}$)}` | `201 {"sanction","replayed":false}` · `200 {…,"replayed":true}` (même `ref` déjà posée pour ce membre : idempotent) · `403 self` · `409 staff_target` (seuls les membres au rôle `user` sont sanctionnables) · `409 conflict` (`ref` d'un autre membre) · 422 · 404. Audit `accounts.sanction.issued` |
| `POST /api/admin/sanctions/:id/lift` | staff | `{reason (5..1000)}` | `200 {"sanction"}` · `409 not_active` (levée ou échue) · 422 · 404. Audit `accounts.sanction.lifted` |
| `GET /api/admin/appeals` | staff | `?status=open|decided&page` | page de 20 (ouverts : plus anciens d'abord) |
| `POST /api/admin/appeals/:id/decide` | staff **autre que l'auteur de la sanction** | `{decision: accept|reject, reason (5..1000)}` | `200 {"appeal"}` · `403 same_staff` · `409 already_decided` · 422 · 404. Accepter **lève** la sanction (si encore active). Audit `accounts.appeal.accepted|rejected` |
| `GET /api/admin/incidents` | staff | `?status&page` | page de 20 (non résolus d'abord) |
| `POST /api/admin/incidents` | staff | `{title (3..140), severity, body? (3..2000 : première entrée de la chronologie)}` | `201 {"incident": détail}` · 422. Audit `accounts.incident.opened` |
| `GET /api/admin/incidents/:id` | staff | | `200 {"incident": détail}` · 404 |
| `POST /api/admin/incidents/:id/updates` | staff | `{body (3..2000), status?, severity?, summary? (10..2000, **requis** pour status=resolved)}` | `200 {"incident"}` · `409 already_resolved` (définitif) · 422 · 404. Audit `accounts.incident.updated|resolved` |
| `GET /api/me/sanctions` | utilisateur | | `200 {"sanctions":[{"id","kind","reason","status","ends_at","inserted_at","lifted_at","lift_reason","appealable":bool,"appeal":{…dernier appel}|null}]}` (sans l'identité du staff) |
| `POST /api/me/sanctions/:id/appeal` | utilisateur (SA sanction) | `{body (10..2000)}` | `201 {"appeal"}` · `409 appeal_open` (un seul appel ouvert par sanction, index unique partiel) · `409 not_appealable` (sanction levée ou échue) · 404 (sanction d'un autre) · 422 |

Modifications : `GET /api/internal/users/:id` et l'utilisateur privé (`sessions/current`…) gagnent
`"restricted_until": iso|null` (fin de la restriction active la plus lointaine, recalculée sous verrou du membre ;
`null` une fois passée). Après chaque sanction posée, levée ou appel tranché : `{:sanction_changed, user_id}` sur
`"user:<id>"` **et** `"members"`, et un e-mail au membre (lien `<WEB_URL>/account/sanctions`). L'export de données
(privacy) inclut les sanctions et appels du membre ; l'anonymisation les supprime. Une
notification in-app de la catégorie `account` (verrouillée) s'y ajoute (`sanction_issued`, `sanction_lifted`,
`appeal_decided`, sans le motif (seulement la sorte, l'échéance et l'issue)) ; l'e-mail reste envoyé par accounts, sans
doublon ([notifications](notifications.md)).

## social (4004)
| Méthode & chemin | Accès | Entrée | Sortie |
|---|---|---|---|
| `GET /api/moderation/reports` | staff | `?status=open|resolved&page` | page de 20 signalements `{"id","target_type":"user|message","target_id","reason","details","context":"multiplayer"|null,"status","reporter","reported_user","message":{"id","sent_at","removed"}|null,"resolution":{"action","reason","moderator_id","sanction_id","resolved_at"}|null,"inserted_at"}` : **jamais le texte d'un message** |
| `GET /api/moderation/reports/:id` | staff | | `200 {"report"}` · 404 |
| `POST /api/moderation/reports/:id/evidence` | staff | `{reason}` (**≥ 10** caractères, ≤ 1000) | `200 {"evidence":{"report_id","message_id","body","sender","sent_at","removed","attachment":{"id","kind","content_type","filename","byte_size","available"}|null}}` : l'**instantané** du message signalé, et lui seul, renvoyé **après** l'entrée `social.report.evidence_viewed` (motif, sans contenu) · `422` (motif) · `409 no_evidence` (signalement de membre) · `503 audit_unavailable` (rien n'est renvoyé) · 404 |
| `POST /api/moderation/reports/:id/attachment` | staff | `{reason}` (**≥ 10** caractères) | `200` octets de la **pièce jointe** du message signalé, renvoyés **après** l'entrée `social.report.attachment_viewed` (motif ; `metadata` : `message_id`, `attachment_id`, `kind`) · `422` · `409 no_attachment` · `404` (fichier effacé avec le compte de l'expéditeur) · `503 audit_unavailable` (rien n'est renvoyé) |
| `POST /api/moderation/reports/:id/resolve` | staff | `{action: dismiss|remove_message|warn|restrict, reason (5..1000), duration_hours (1..720, restrict)}` | `200 {"report"}` · `409 already_resolved` · `409 staff_target` · `422` (`remove_message` sur un signalement de membre…) · `503 accounts_unavailable|audit_unavailable` (rien n'est résolu) |
| `GET /api/admin/stats` | staff | | `200 {"stats":{"messages_7d","open_reports"}}` |

`remove_message` = suppression **logique** (`messages.removed_at`, le texte et le fichier d'une pièce jointe restent pour
les preuves et les appels), règle tous les signalements ouverts sur ce message et livre `{:message_removed, message}` à
chaque membre de la conversation sur `"user:<id>"` ([social](social.md)) ; la pièce jointe n'est plus servie aux membres
(`404`), seulement au staff par la route de preuve auditée ci-dessus.
`warn` / `restrict` posent la sanction chez accounts **au nom du membre du staff** (`POST /api/admin/users/:id/sanctions`,
`ref` = `"social:report:<id>"` : un nouvel essai ne la pose pas deux fois). Audit `social.report.resolved`.
**Aucune route du staff ne lit une conversation** ; les routes des conversations restent réservées à leurs membres (404).

Modifications : message `{…,"body": null si retiré,"removed": bool}` ; `POST /api/conversations/:id/messages` →
`403 {"error":"restricted","restricted_until": iso}` pour un membre restreint (vérifié en premier), `503
accounts_unavailable` si accounts ne répond pas ; signalement : `status`, `resolution…` ajoutés.

## community (4006)
API de modération existante (docs/contracts/community.md), plus :
`GET /api/moderation/reports/:id` (staff, `200 {"report"}` ouvert ou résolu · 404) et `GET /api/admin/stats` (staff,
`{"stats":{"discussions_7d","replies_7d","open_reports"}}`). Chaque action de modération et chaque résolution est aussi
écrite dans le journal central (`community.discussion.<action>`, `community.reply.<action>`, `community.report.resolved`)
dans la même transaction que `moderation_log` (`503 audit_unavailable` sinon).
Modifications : `POST /api/discussions`, `POST /api/discussions/:slug/replies`, `PATCH /api/discussions/:slug`,
`PATCH /api/replies/:id` → `403 {"error":"restricted","restricted_until"}` pour un membre restreint ; accounts injoignable :
`503 roles_unavailable` (la lecture continue).

## multiplayer (4005)
`GET /api/admin/stats` (staff) → `{"stats":{"open_lobbies","matches_7d"}}`. Modification : `POST /api/lobbies/:id/messages`
→ `403 restricted` (+ `restricted_until`) pour un membre restreint, `503 accounts_unavailable` si accounts ne répond pas.
Les signalements de joueurs passent par social (`context: "multiplayer"`).

## learning (4002)
`GET /api/admin/stats` (staff) → `{"stats":{"enrollments","lessons_completed_7d","xp_7d"}}`.

## billing (4003) : admin seulement
| Méthode & chemin | Entrée | Sortie |
|---|---|---|
| `GET /api/admin/stats` | | `200 {"stats":{"active_subscriptions":{"premium","vip"},"past_due_subscriptions","revenue_month_cents" (factures payées du mois UTC),"currency","failed_webhook_events"}}` |
| `GET /api/admin/subscriptions` | `?status&plan&page` | page de 25 `{"id","user_id","plan","status","provider","current_period_end","cancel_at_period_end","past_due_since","updated_at"}` : **lecture seule** |
| `GET /api/admin/webhook-events` | `?page` | événements `failed` `{"id","provider","provider_event_id","type","error","user_id","event_created_at","inserted_at"}` (jamais la charge utile) |
| `POST /api/admin/credits/adjustments` | `{user_id (membre existant chez accounts), amount (1..5000), reason (5..500), ref (^admin:[A-Za-z0-9_-]{8,100}$)}` | `201 {"adjustment":{"ref","status":"applied","amount","balance","reserved"}}` · `200 {…"status":"duplicate"}` (même `ref` : rien de plus) · 422 · `503 audit_unavailable` (rien n'est crédité) |

Ajustement = ligne `adjustment` (+amount) du registre des crédits (allocation exceptionnelle, expire en fin de mois
comme les autres), idempotente par `(user_id, kind, ref)`, auditée (`billing.credits.adjusted`, motif, montant, ref,
solde) dans la transaction. **Aucune route ne modifie un abonnement** : seuls les webhooks signés changent les droits.

## studio (4007)
File de relecture existante (docs/contracts/studio.md). `approve`, `reject` et `retry-import` sont audités dans leur
transaction (`studio.project.approved|rejected|import_retried`, `503 audit_unavailable` sinon).
`GET /api/admin/stats` (staff) → `{"stats":{"review_queue" (projets soumis),"failed_generations_24h"}}`.

## Événements
- `"user:<id>"` : `{:sanction_changed, user_id}`, `{:role_changed, user_id}` (web recharge le membre : navigation,
  pages du staff, page `/account/sanctions`).
- `"members"` : `{:sanction_changed, user_id}`, `{:role_changed, user_id}` (invalidation des caches des services).
- `"user:<id>"` de chaque membre de la conversation : `{:message_removed, message}` (web remplace le message par « removed
  by moderation ») : livraison par membre, plus de topic `"conversation:<id>"`.

## Côté web
`/admin` (indicateurs ; une mesure inexistante (temps de réponse, disponibilité) s'affiche « Unavailable : not
measured », un service muet « Temporarily unavailable »), `/admin/reports` (+ `/admin/reports/:source/:id`),
`/admin/members` (+ fiche), `/admin/sanctions-appeals`, `/admin/incidents` (+ détail), `/admin/audit` (+
`GET /admin/audit/export`, CSV en pièce jointe, `cache-control: no-store`), `/admin/billing`, lien vers
`/studio/review` ; `/account/sanctions` pour le membre. Les pages sont dans la `live_session :member` ; rôle vérifié au
mount (`MysticWeb.Admin.Guard`, page 403 sinon) **et** à chaque `handle_event` (événements admin listés par
`admin_events/0`). Entrée « Administration » de la navigation pour le staff seulement. Messagerie : bouton
« Report » sur les messages de l'autre participant, message retiré affiché « Message removed by moderation ». Dossier d'un
message signalé : après la preuve, sa pièce jointe éventuelle (nom, type, taille) et un formulaire « Download the
attachment » (motif ≥ 10 caractères, jeton CSRF) vers `POST /admin/reports/social/:id/attachment`, qui relaie le fichier
toujours en téléchargement (`content-disposition: attachment`, `no-store`, `nosniff`, CSP `sandbox`).
Parcours réel : `e2e/admin.mjs`.
