# notifications : centre de notifications (contrat)

Service `src/notifications` : app OTP `:notifications`, modules `MlNotifications` /
`MlNotificationsWeb`, port **4008**, base `ml_notifications_dev` / `_test`, URL `NOTIFICATIONS_URL`. Mêmes règles
transverses que [docs/CONTRACTS.md](../CONTRACTS.md) : jeton interne (`MlShared.Plug.Internal`), JSON, UUID,
ISO 8601 UTC, `{"error": code}`, `422 {"error":"invalid","errors":{"champ":[message]}}`. « Membre » = jeton portant un
membre (`conn.assigns.user_id`, normalisé en UUID ; jamais un identifiant du corps ou de l'URL). « Service » = jeton
sans membre, dont le `svc` est le service appelant.

## Principes

- **Jamais de texte rédigé** : une notification est `category` + `kind` + `params` ; web écrit la phrase (gettext,
  `MysticWeb.Notifications.text/1`) et accounts rédige les e-mails (modèles en liste blanche, en / fr).
- **Jamais d'URL stockée** : web calcule le lien à partir de `kind` + `params` (`MysticWeb.Notifications.path/1`),
  chemins locaux construits avec des identifiants validés (UUID, slug) ; une valeur inattendue mène à une page générale.
  Aucune redirection ouverte possible.
- **Jamais de contenu privé** : ni texte d'un message, ni brouillon, ni corps de réponse du forum, ni motif de
  modération. `params` ne contient que des identifiants et de courtes chaînes publiques (titre de discussion, de salon,
  nom de badge, nom de groupe) ; clé inconnue, mauvais type ou texte trop long → `422`. Les décisions du studio ne
  portent que l'identifiant du projet : web relit le titre et le motif chez studio, qui vérifie l'accès du membre.
- **Jamais d'adresse e-mail** : l'envoi est demandé à accounts (`POST /api/internal/users/:id/notification-email`).

## Catégories, producteurs et canaux

Chaque service appelant (`svc` du jeton) ne crée que ses catégories (`403 forbidden` sinon, `web` compris).

| Catégorie | Producteur | Sortes (`kind`) et paramètres | In-app | E-mail |
|---|---|---|---|---|
| `security` | accounts | `password_changed` (`method`: `settings`\|`reset`), `email_changed`, `two_factor_enabled`, `two_factor_disabled`, `recovery_codes_regenerated`, `sessions_revoked` (`count`) | **verrouillé** | **verrouillé** : envoyé par le centre, jamais reporté ni limité ; `email_changed` : e-mails déjà envoyés par accounts (avis à l'ancienne adresse, lien à la nouvelle), le centre n'en ajoute pas |
| `account` | accounts | `sanction_issued` (`sanction_id`, `sanction_kind`, `ends_at`), `sanction_lifted` (`sanction_id`, `sanction_kind`), `appeal_decided` (`appeal_id`, `outcome`), `export_ready`, `export_failed` (`export_id`), `support_replied` (`request_id`) | **verrouillé** | **verrouillé** : sanctions, appels et réponses du support sont toujours e-mailés par accounts lui-même (au seul membre) ; le centre n'ajoute que l'entrée in-app ; export : in-app seulement |
| `billing` | billing | `subscription_activated` (`plan`), `payment_failed` (`plan`), `cancellation_scheduled` (`plan`, `period_end`), `subscription_ended` (`plan`) | activé | activé ; `payment_failed` et `subscription_ended` (conditionnent l'accès) sont **toujours** créés et envoyés, quelles que soient les préférences |
| `messages` | social | `message_received` (`conversation_id`, `conversation_kind`, `group_name`), agrégé par conversation | activé | désactivé |
| `friends` | social | `friend_request_received` (`request_id`), `friend_request_accepted`, `group_added` (`conversation_id`, `group_name`) | activé | désactivé |
| `community` | community | `community_reply` (`discussion_id`, `slug`, `title`), agrégé par discussion | activé | désactivé |
| `multiplayer` | multiplayer | `lobby_invite` (`invite_id`, `lobby_id`, `lobby_title`) | activé | désactivé |
| `studio` | studio | `review_approved`, `review_rejected` (`project_id`) | activé | désactivé |
| `learning` | learning | `badge_earned` (`badge_slug`, `badge_name`) | activé | désactivé |

Acteur (`actor_id`) : obligatoire pour `messages`, `friends`, `community_reply`, `lobby_invite` ; interdit ailleurs
(`422 must be empty for this kind`). Le relecteur du studio n'est jamais nommé. La préférence e-mail ne gouverne que
les catégories facultatives ; un canal in-app coupé ne crée pas de notification (l'e-mail suit sa propre préférence).

## Formes

- **Notification** : `{"id","category","kind","actor_id","actor": identité|null,"subject": {"type","id"}|null,
  "params","count","read","read_at","created_at","updated_at"}` : `actor` : identité d'accounts (`id`, `username`,
  `display_name`, `avatar`), en une requête par réponse (tranches de 100, sans relance ; accounts injoignable → `null`) ;
  un compte supprimé s'affiche « Deleted member ». `subject` est déduit de la sorte (`conversation`, `discussion`,
  `lobby`, `project`, `badge`, `sanction`, `appeal`, `export`, `plan`, `member`, `support_request`). `updated_at` : date du dernier
  événement agrégé (clé de tri). `count` : nombre d'événements agrégés.
- **Réglages** : `{"categories": [{"key","in_app","email","locked": ["in_app","email"]|[]}], "quiet_hours":
  {"enabled","start":"HH:MM","end":"HH:MM","time_zone": IANA|null,"active","ends_at": iso|null}, "pending_digest":
  {"count","send_at": iso|null}}` : catégories dans l'ordre du tableau ci-dessus ; `pending_digest` : e-mails reportés
  pendant les heures calmes et date du résumé.

## Routes internes (service)

| Méthode & chemin | Appelant | Entrée | Sortie |
|---|---|---|---|
| `POST /api/internal/notifications` | producteur de la catégorie | `{user_id, category, kind, actor_id?, params, dedupe_key, event_id?, occurred_at?}` | `201 {"status":"created","id","count":1,"email"}` · `200 {"status":"aggregated","id","count","email"}` · `200 {"status":"duplicate"}` (occurrence déjà traitée) · `200 {"status":"skipped"}` (canal in-app coupé, ou clé déjà lue après `occurred_at`) · `403 forbidden` (catégorie d'un autre service) · `422` (`category`, `kind`, `params`, `actor_id`, `dedupe_key`, `event_id`, `user_id`, `occurred_at`) : `email` : `queued` (demandé, jamais « envoyé » à ce stade) \| `deferred` (heures calmes) \| `none` |
| `POST /api/internal/notifications/read` | producteur (ses catégories) | `{user_id, dedupe_key, read_at?}` | `200 {"read": n}` : marque lue la notification de la clé si elle ne contient pas d'événement postérieur à `read_at`, et mémorise la lecture · `403` (appelant sans catégorie) · `422` |
| `POST /api/internal/notifications/clear-between` | **social** | `{a, b}` | `200 {"deleted": n}` : notifications de l'un dont l'autre est l'acteur, dans les deux sens, et leurs e-mails reportés · `403` · `422` |
| `GET /api/internal/users/:id/export` · `DELETE /api/internal/users/:id` | **accounts** | | voir [privacy](privacy.md) · `403` sinon · `404` (id mal formé) |

**`dedupe_key`** (`[A-Za-z0-9:_.-]`, 200 caractères) : au plus une notification non lue par clé et par destinataire
(index unique partiel). **`event_id`** (défaut : la clé) : une occurrence, traitée une seule fois (table
`notification_events`, 30 jours) : une nouvelle tentative du producteur ne crée jamais de doublon ni ne fausse
`count`. **Agrégation** : même clé et non lue → `count + 1`, remontée en tête (acteur et paramètres les plus récents) ;
déjà lue → nouvelle notification non lue. **`occurred_at`** (défaut : maintenant, jamais dans le futur) : date de
l'événement chez le producteur ; une création plus ancienne qu'une lecture déjà reçue pour sa clé est ignorée
(conversation lue avant que la notification de son message n'arrive). Création et lecture par clé d'un même
`(destinataire, clé)` sont sérialisées (verrou consultatif).

## Routes du membre (appelées par web)

| Méthode & chemin | Entrée | Sortie |
|---|---|---|
| `GET /api/me/notifications` | `?filter=all\|unread&before=<curseur>&limit=1..50` (20 par défaut) | `200 {"entries":[notification],"next_before": curseur\|null,"unread": n}` : du plus récent au plus ancien (`updated_at`, puis id) ; curseur opaque · `422 {"errors":{"before":["is invalid"]}}` |
| `GET /api/me/notifications/unread-count` | | `200 {"unread": n}` |
| `GET /api/me/notifications/:id` | | `200 {"notification"}` · `404` (inconnue, d'un autre membre, id mal formé : rien n'est révélé) |
| `POST /api/me/notifications/:id/read` | | `200 {"notification"}` (idempotent) · `404` |
| `POST /api/me/notifications/read-all` | | `200 {"read": n, "unread": 0}` |
| `GET /api/me/notification-settings` | | `200 {"settings"}` |
| `PATCH /api/me/notification-settings` | `{channels?: {catégorie: {in_app?, email?}}, quiet_hours?: {enabled?, start?, end?, time_zone?}}` | `200 {"settings"}` · `422` : `channels.<catégorie>.<canal>` (`is invalid`, `is locked` : un canal verrouillé ne se coupe pas), `quiet_hours.start\|end` (`is invalid` : `HH:MM`), `quiet_hours.end` (`must differ from the start`), `quiet_hours.time_zone` (`is not a known time zone`, `can't be blank` pour activer), `quiet_hours.enabled` |

## Événements (`"user:<id>"`)

- `{:notifications_changed, user_id, toast}` après chaque changement de la liste du membre (création, agrégation,
  lecture, tout lire, effacement) : `toast` : `%{"id", "category"}` d'une notification non lue à annoncer, ou `nil`
  (lecture, effacement, **heures calmes** : la liste et le compteur se mettent à jour, en silence). La sécurité n'est
  jamais rendue silencieuse. Aucun sondage périodique côté web.
- `{:notification_settings_changed, user_id}` après un changement des réglages (ses autres pages).

## Heures calmes

Une plage d'heures locales (`start` → `end`, qui peut passer minuit) dans le fuseau IANA enregistré avec elles ; web
envoie à chaque enregistrement le fuseau effectif de la page (`MysticWeb.Format.time_zone/0` : la préférence du membre,
ou celui du navigateur si elle vaut `auto`), et la page l'affiche. Appartenance : heure murale du fuseau comparée à
la plage. Fin : prochaine occurrence de `end` dans ce fuseau : heure sautée (passage à l'heure d'été) → premier instant
valide après le saut ; heure répétée (retour à l'heure d'hiver) → la première occurrence encore à venir. Vérifié en
Europe/Paris de part et d'autre des changements d'heure du 29 mars et du 25 octobre 2026.

Pendant les heures calmes : **aucun e-mail** (chacun est reporté dans `pending_emails`, puis UN résumé part à leur fin,
`MlNotifications.DigestWorker`, une ligne par clé, sans ce qui a été lu entre-temps : sauf sorte obligatoire) ;
**aucun toast** ; liste et cloche à jour en silence. La sécurité n'est jamais reportée. Changer ou couper les heures
calmes replanifie le résumé (tout de suite si elles ne sont plus en cours). Encore dans les heures calmes à l'heure
prévue (fuseau changé) → le résumé est repoussé à leur fin.

## E-mails

Sortes envoyées par le centre (`email: center`) : canal actif (ou obligatoire) → `MlNotifications.EmailWorker` (Oban,
file `email`, 8 essais, backoff d'Oban) qui demande l'envoi à accounts :

- **sécurité** : tout de suite, jamais reporté ni limité ;
- **obligatoires** (billing) : sans délai, sans limite, mais reportées pendant les heures calmes ;
- **facultatives** : après `email_delay_seconds` (60 s, `NOTIFICATIONS_EMAIL_DELAY_S` ; 10 s en dev), annulées si la
  notification a été lue entre-temps ou si le membre a coupé le canal ; **limite de débit** : un e-mail au plus par clé
  (ex. une conversation, une discussion) et par heure, et 20 par jour et par membre (hors sécurité) : au-delà, seule
  l'entrée in-app existe. La limite compte les e-mails demandés (`email_log`, purgé après 2 jours) ; `sent_at` n'est
  posé qu'après la confirmation d'accounts.

accounts `POST /api/internal/users/:id/notification-email` (appelant `notifications` seulement, `403` sinon) :
`{kind, params, actor_id?, count?}` ou `{kind: "digest", items: [{kind, params, actor_id, count}] (20 au plus), total}` →
`200 {"status":"sent"}` une fois remis au Mailer · `404` (compte inconnu) · `409 not_deliverable` (non confirmé,
supprimé, suppression en cours) · `422 invalid` (sorte hors liste blanche (dont `email_changed`, `sanction_*`,
`appeal_decided`), paramètres invalides) · `503 mailer_unavailable` (nouvel essai). Modèle en liste blanche, langue
du membre (`en`/`fr` ; `auto` → anglais), nom de l'acteur lu en base (« Deleted member » pour un compte supprimé),
titres publics seulement, lien calculé (ex. `/messages/<id>`), lien vers `/settings/notifications` ; un e-mail
obligatoire le dit. Jamais le texte d'un message, d'une réponse du forum, ni le motif d'une relecture.

## Producteurs

Un envoi ne bloque ni ne fait échouer l'action d'origine et n'annonce jamais une livraison qui n'a pas eu lieu ;
toujours une `dedupe_key` (et un `event_id` quand la clé agrège). Module partagé : `MlShared.Notifications`.

| Service | Voie | Déclencheurs |
|---|---|---|
| accounts | **durable** (Oban `MlAccounts.NotifyWorker`, file `notify`, 10 essais), inséré juste après l'action | mot de passe changé (paramètres) ou réinitialisé, e-mail confirmé, 2FA activée / désactivée, codes régénérés, session(s) révoquée(s) par le membre (pas une déconnexion), sanction posée / levée, appel tranché, export prêt / échoué |
| billing | **durable** (Oban `MlBilling.NotifyWorker`), inséré dans la transaction du changement (`MlBilling.Notices`) | passage à `active` (première activation, autre formule), à `past_due`, résiliation programmée, passage à `canceled` : webhooks Stripe (mode test) et mode simulé local, même pipeline ; drapeau de résiliation renvoyé par l'API Stripe |
| studio | **durable** (Oban `MlStudio.NotifyWorker`), inséré dans la transaction de la décision | approbation, retour en brouillon : propriétaire et éditeurs |
| social | au mieux (`MlShared.Notifications.async/1`) | message texte : chaque membre actuel sauf l'expéditeur, rien en sourdine (`muted_until`), rien entre membres qui ont un blocage, rien s'il a déjà lu jusque-là (clé `conversation:<id>`, `event_id` `message:<id>`) ; `POST /read` → lecture par clé ; demande reçue, acceptée (y compris croisée), ajout à un groupe ; demande acceptée/refusée → lue ; membre retiré ou parti → notifications du groupe lues ; blocage → `clear-between` |
| community | au mieux | réponse dans une discussion suivie, mêmes exclusions de blocage qu'avant (clé `discussion:<id>`, `event_id` `reply:<id>`) ; `{:community_reply, slug, title}` reste pour recharger la discussion ouverte |
| multiplayer | au mieux | invitation de salon (permission `lobby_invites` décidée par social ; clé `lobby_invite:<id>`) ; acceptée ou refusée → lue |
| learning | au mieux | badge gagné (clé `badge:<slug>`) |

Voie « au mieux » : tâche de `MlShared.TaskSupervisor`, 6 essais en environ 52 s (0,5 / 2 / 5 / 15 / 30 s) ; perdue si
le nœud s'arrête pendant ce temps ou si le centre reste injoignable plus longtemps (docs/LIMITS.md).

## Rétention

Cron quotidien (`MlNotifications.PurgeWorker`, 03:17 UTC) : notifications dont le dernier événement date de plus de
**90 jours** (lues ou non) ; **500** au plus par membre (les plus anciennes partent, aussi dès une création) ;
occurrences traitées de plus de 30 jours, marques de lecture de plus de 7 jours, journal des e-mails de plus de 2 jours,
e-mails reportés de plus de 7 jours. Choix : 90 jours couvrent un trimestre d'activité sans garder d'historique
indéfini ; 500 bornent une liste qu'aucun membre ne parcourt au-delà et la taille de la base.

## Données personnelles ([privacy](privacy.md), [suppression](../account-deletion.md))

- **Export** (`data`) : `notifications[]` reçues par le membre (`category`, `kind`, `actor_id`, `subject`, `params`,
  `count`, `read_at`, `created_at`, `updated_at` : jamais celles des autres), `settings` (`channels`, `quiet_hours`),
  `pending_emails[]` (`category`, `kind`, `inserted_at`).
- **Suppression** (idempotente, dernière étape avant accounts) : notifications reçues, réglages, e-mails reportés,
  journal des e-mails, occurrences, marques de lecture, tâches d'e-mail et de résumé en attente. **Choix** : les
  notifications dont le membre supprimé est l'acteur, reçues par d'autres, sont conservées (elles appartiennent à
  leurs destinataires, ne contiennent que des identifiants et des titres publics) et s'affichent « Deleted member »
  (accounts anonymise le compte), comme ses contributions ailleurs.

## Côté web

- **Cloche** (`MysticWeb.Layouts.bell/1`) sur toutes les pages connectées : rail (`#nav-notifications`), en-tête mobile
  (`#mobile-bell`), rail du staff (`#admin-bell`) ; compteur en direct (`@notifications`, `MysticWeb.Auth`, rechargé
  sur `{:notifications_changed, …}`), `aria-label` avec le nombre (« Notifications, 3 unread », « none unread »,
  « count unavailable » si le centre ne répond pas), cible de 46 px.
- **Toast** (`#notification-toasts`, région `aria-live="polite"`) : une notification nouvelle et non lue, 8 s, fermable,
  lien `?open=<id>` ; jamais pendant les heures calmes (le centre n'envoie pas de toast) ; pas sur `/notifications`, ni
  pour `messages` sur `/messages` (le fil et le compteur s'y mettent à jour, annoncés), ni pour la discussion ouverte
  sur sa page (son bandeau l'annonce déjà) : `@toast_except`. Animation seulement si `prefers-reduced-motion` ne la
  refuse pas et sans `data-motion="reduce"`.
- **`/notifications`** (`MysticWeb.NotificationsLive`) : du plus récent au plus ancien, non-lues marquées (visuel et
  texte « Unread. »), avatar et nom de l'acteur (ou icône de la catégorie), texte traduit, heure relative dans le fuseau
  du membre (`MysticWeb.Format.relative/1`), filtres « All » / « Unread » dans l'URL, lire une (`#read-<id>`), tout lire,
  « Load more » par curseur, état vide, état « indisponible » sans donnée fictive, mises à jour en direct ;
  `?open=<id>` marque lue puis mène à la cible (entrée d'historique remplacée) ; motif d'un retour en brouillon relu chez
  studio.
- **`/settings/notifications`** (après « Learning ») : matrice catégorie × canal (cases à cocher ≥ 44 px, lignes
  verrouillées « Always » expliquées), heures calmes (activation, `De`/`Jusqu'à`, fuseau effectif affiché et sa source,
  fuseau enregistré différent signalé, plage en cours, e-mails en attente et date du résumé) ; `role=status`, succès
  annoncé seulement après la réponse du centre, erreurs à côté des champs.

## Variables d'environnement

`NOTIFICATIONS_URL` (tous les appelants ; défaut `http://localhost:4008`) · `NOTIFICATIONS_EMAIL_DELAY_S` (centre ;
défaut 60, 10 en dev) · `ACCOUNTS_URL` (centre : identités et e-mails) · `PORT`, `DATABASE_URL`, `SECRET_KEY_BASE`,
`INTERNAL_SECRET` (production).
