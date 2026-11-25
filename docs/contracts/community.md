# community (4006) : forum communautaire

Service `src/community` (`MlCommunity` / `MlCommunityWeb`), base `ml_community_*`. Toutes les routes `/api/*` exigent le
jeton interne (`MlShared.Plug.Internal`). **Lecture** (`GET /api/categories`, `/api/discussions`, `/api/discussions/:slug`) :
utilisateur facultatif (visiteur = contenus publics). **Actions** : le jeton doit porter un utilisateur (UUID, sinon
`401 unauthorized`). Toute autorisation repose sur `conn.assigns.user_id` ; aucun rôle ni identifiant du corps, de l'URL
ou des en-têtes n'est pris en compte. `GET /healthz` (sans jeton) → `200 {"status":"ok"}`.

## Lecteur, visibilité, blocages
- **Staff** = rôle `moderator|admin` lu chez accounts `GET /api/internal/users/:id` (cache 30 s). Accounts injoignable :
  lecture comme un non-staff, actions de modération `503 roles_unavailable`.
- **Statuts** : `visible` (tous) · `hidden`/`removed` (modération ; visibles du staff et de l'auteur, avec `moderation_reason`) ·
  `deleted` (suppression logique par l'auteur ; visible du staff seulement). Règle appliquée dans les requêtes SQL.
- **Blocages** : les discussions et réponses des membres avec lesquels le lecteur a un blocage (deux sens, social
  `GET /api/internal/blocks/:user_id`, cache 15 s invalidé par `{:friendship_changed, id}` sur `"user:<id>"`) sont exclues
  des listes, des pages, des compteurs de réponses, du filtre « sans réponse » et de toute action (réponse, vote, signalement → 404/422).
- **Option prudente si social est injoignable** (et pas de cache frais) : toute requête portant un utilisateur → `503 blocks_unavailable`
  (aucun contenu ni action, puisqu'on ne pourrait garantir l'exclusion) ; les visiteurs lisent normalement.
  Pour les notifications : si les blocages de l'auteur de la discussion sont illisibles, personne n'est notifié (la réponse reste publiée).
- **Auteurs** : user public d'accounts `{"id","username","display_name","bio"}`, une requête `GET /api/users?ids=` par réponse
  (tranches de 100) ; champs `null` (id conservé) si accounts est indisponible.

## Formes
- Catégorie : `{"slug","name","description","staff_only":bool,"can_post":bool}` (`can_post` : membre, et staff si `staff_only`).
  Catégories (données de référence de la migration) : `announcements` (staff seulement), `help-questions`, `showcase`, `study-groups`, `off-topic`.
- Discussion (liste) : `{"id","slug","title","excerpt" (200 car. + « … »),"category":{"slug","name"},"author":user,"status","pinned","locked",
  "solved":bool,"helpful_count","reply_count" (réponses visibles pour ce lecteur),"following":bool,"last_activity_at","inserted_at"}`.
- Discussion (détail) : liste sans `excerpt` + `{"body","edited_at"|null,"solution_reply_id"|null,"voted":bool,"can_edit":bool,"moderation_reason"|null}`.
- Réponse : `{"id","discussion_id","body","author","status","helpful_count","voted","solution":bool,"can_edit","moderation_reason"|null,"edited_at","inserted_at"}`.
- Texte brut (aucun HTML interprété) : titre 5–140 (espaces regroupés), corps de discussion 10–10 000, réponse 2–5 000 ; octet nul → 422.
- `can_edit` : auteur, contenu `visible`, moins de 30 minutes après la publication.

## Routes
| Méthode & chemin | Jeton | Entrée | Sortie |
|---|---|---|---|
| `GET /api/categories` | service (utilisateur facultatif) | | `200 {"categories":[catégorie]}` (ordre d'affichage) |
| `GET /api/discussions` | service (utilisateur facultatif) | `?q&category&filter=unanswered\|solved\|following&sort=recent\|helpful&page` | page de discussions (10 par page) |
| `GET /api/discussions/:slug` | service (utilisateur facultatif) | `?page` (réponses) | `200 {"discussion":détail,"replies":{"entries":[réponse],"page","total_pages","total"}}` (50 réponses par page, ordre chronologique) · 404 |
| `POST /api/discussions` | utilisateur | `{category,title,body}` | `201 {"discussion":détail}` · 422 · `403 forbidden` (catégorie staff) · `429 rate_limited` |
| `PATCH /api/discussions/:slug` | utilisateur (auteur) | `{title?,body?}` | `200 {"discussion"}` · `403 forbidden` (autre membre, contenu modéré) · `403 edit_window_expired` · 422 · 404 |
| `DELETE /api/discussions/:slug` | utilisateur (auteur) | | `204` (statut `deleted`) · 403 · 404 |
| `PUT` / `DELETE /api/discussions/:slug/follow` | utilisateur | | `200 {"following":bool}` (idempotent) · 404 |
| `PUT` / `DELETE /api/discussions/:slug/vote` | utilisateur | | `200 {"voted":bool,"helpful_count":int}` (idempotent) · `403 own_content` · `403 forbidden` (non visible) · 404 |
| `PUT /api/discussions/:slug/solution` | utilisateur (auteur de la discussion) | `{reply_id}` | `200 {"solution_reply_id"}` · 403 · `422` (réponse d'une autre discussion, non visible…) |
| `DELETE /api/discussions/:slug/solution` | utilisateur (auteur de la discussion) | | `200 {"solution_reply_id":null}` |
| `POST /api/discussions/:slug/replies` | utilisateur | `{body}` | `201 {"reply"}` · `403 locked` (sauf staff) · `403 forbidden` (discussion modérée) · 422 · `429 rate_limited` · 404 |
| `PATCH /api/replies/:id` | utilisateur (auteur) | `{body}` | `200 {"reply"}` · 403 (`forbidden`, `edit_window_expired`) · 404 |
| `DELETE /api/replies/:id` | utilisateur (auteur) | | `204` (statut `deleted`, n'est plus la solution) |
| `PUT` / `DELETE /api/replies/:id/vote` | utilisateur | | comme le vote d'une discussion |
| `POST /api/reports` | utilisateur | `{"target_type":"discussion\|reply","target_id","reason":"harassment\|spam\|inappropriate\|other","details"?}` (≤ 2000) | `201 {"id"}` · `409 already_reported` · 422 (`target_id` : `is invalid` si inconnu ou non visible, `cannot be your own content`) |
| `POST /api/moderation/discussions/:id` | staff | `{"action":"hide\|remove\|restore\|lock\|unlock\|pin\|unpin\|move","reason"?,"category"?}` | `204` · `403 forbidden` · `503 roles_unavailable` · 404 · `409 conflict` · 422 |
| `POST /api/moderation/replies/:id` | staff | `{"action":"hide\|remove\|restore","reason"?}` | idem |
| `GET /api/moderation/reports` | staff | `?page` | page de signalements ouverts, plus anciens d'abord (20 par page) |
| `POST /api/moderation/reports/:id/resolve` | staff | `{"action":"dismiss\|hide\|remove","reason"}` | `200 {"report"}` · `409 already_resolved` · 422 · 404 |

Signalement (staff) : `{"id","target_type","target_id","target_status" (statut actuel de la cible),"reason","details","status":"open|resolved",
"reporter":user,"snapshot":{"title" (titre de la discussion),"body","author":user,"discussion_slug","status","posted_at"},
"resolution":null|{"action","reason","moderator_id","resolved_at"},"inserted_at"}`.

## Règles
- **Slug** : titre en ASCII minuscule à tirets (60 car.) + `-` + 8 caractères aléatoires (base32) ; unique en base ; jamais modifié.
- **Réponses** : un seul niveau (on répond à la discussion). Discussion verrouillée : seul le staff répond.
- **Votes « utile »** : un par (membre, cible) imposé par la clé primaire `votes(user_id, target_type, target_id)` ; `PUT`/`DELETE`
  idempotents (l'interface bascule entre les deux) ; `helpful_count` modifié dans la même transaction, seulement si une ligne a été
  insérée ou supprimée ; jamais sur son propre contenu ni sur un contenu non `visible`.
- **Limite de débit** : 10 publications (discussions + réponses) par 10 minutes et par membre, comptées en base sous verrou consultatif
  du membre dans la transaction d'insertion → `429 rate_limited`.
- **Suivi** : automatique à la création et à chaque réponse ; manuel idempotent.
- **Recherche** : `q` (≤ 100 car.) en ILIKE sur titre ET corps, `%`, `_`, `\` échappés. Tri `recent` : épinglées d'abord puis dernière
  activité (création ou dernière réponse) ; `helpful` : votes. Page invalide → 1 ; au-delà de la dernière → `entries` vide.
- **Modération** : `hide`/`remove` exigent `reason` (≤ 500) ; `restore` seulement depuis `hidden|removed` ; contenu `deleted` → `409 conflict` ;
  `move` vers une catégorie existante. Masquer/retirer une réponse lui retire le statut de solution. Chaque action (et chaque résolution
  de signalement) est écrite dans `moderation_log` (`moderator_id, action, target_type, target_id, reason, metadata{from,to,…}`)
  dans la même transaction.
- **Signalements** : instantané du contenu copié à la création ; un seul ouvert par (rapporteur, cible) (index unique partiel) ;
  résolution sous verrou de ligne ; `hide`/`remove` modèrent la cible et règlent aussi les autres signalements ouverts sur elle ; `dismiss` ne règle que celui-ci.

## Événements
`"user:<id>"` → `{:community_reply, discussion_slug, title}` pour chaque abonné de la discussion à chaque nouvelle réponse, sauf l'auteur
de la réponse et les membres en blocage (deux sens) avec lui ou avec l'auteur de la discussion.

**Centre de notifications** ([contrat](notifications.md)) : pour les mêmes abonnés, une notification
`community_reply` AU mieux (`discussion_id`, `slug`, `title` publics ; jamais le corps de la réponse), agrégée par
discussion (`discussion:<id>`, occurrence `reply:<id>`). C'est elle que web annonce (toast) ; `{:community_reply, …}`
ne sert plus qu'à recharger la discussion ouverte, dont le bandeau « New reply in this discussion » reste la seule
annonce sur sa page (pas de double toast).
