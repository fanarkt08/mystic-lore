# accounts : demandes de support (formulaire de contact) : contrat

Les demandes envoyées par le formulaire de contact (`/contact`, visiteurs et membres) sont
**stockées par accounts** : il détient déjà l'adresse vérifiée des membres, le Mailer, les limites de débit en base
(`throttle_events`), le journal d'audit du staff et l'export / la suppression des données : un nouveau service
aurait dû redemander tout cela à accounts. Mêmes règles transverses que [docs/CONTRACTS.md](../CONTRACTS.md) (jeton
interne, JSON, UUID, ISO 8601 UTC, `{"error": code}`, `422 {"error":"invalid","errors":{…}}`, pagination
`{"entries","page","total_pages","total"}`). Le rôle du staff est lu en base à chaque requête (voir
[admin](admin.md)).

## Formes
- **Demande vue du demandeur** : `{"id","reference","topic","message","status","inserted_at","answered_at",
  "closed_at","replies":[{"id","body","inserted_at"}]}` : jamais la note interne ni l'identité du staff.
- **Ligne de la file du staff** : `{"id","reference","topic","status","locale","requester","replies" (nombre),
  "inserted_at","updated_at","answered_at","closed_at"}` : jamais le texte de la demande ;
  `requester` = `{"kind":"member"|"visitor","member":{"id","username","display_name"}|null,"email","email_masked"}`
  (adresse du visiteur, ou adresse actuelle du compte du membre : **masquée** `v•••@domaine` pour un modérateur,
  complète pour un admin).
- **Détail pour le staff** : ligne + `{"message","internal_note","replies":[{"id","body","author":{"id","username",
  "display_name"},"email_status":"sent"|"failed"|"pending","inserted_at"}]}`.
- `reference` : `REQ-XXXXX-XXXXX` (10 caractères base32 de Crockford aléatoires, index unique) ; `topic` ∈
  `account billing privacy bug other` ; `status` ∈ `open answered closed` ; `locale` ∈ `en fr` (langue de la page,
  celle des e-mails).

## Routes

| Méthode & chemin | Jeton | Entrée | Sortie |
|---|---|---|---|
| `POST /api/support/requests` | service ; membre **facultatif** (visiteur : sans membre) | `{topic, message, email (visiteur seulement ; ignoré pour un membre), locale?}` | `201 {"request":{"id","reference","topic","status","inserted_at"},"acknowledgement":"sent"\|"failed"}` · `422` (`topic` : `is invalid` ; `message` : `can't be blank`, `is invalid`, `must not contain control characters`, `should be at least 10 character(s)`, `should be at most 4000 character(s)` ; `email` : `can't be blank`, `must have the @ sign and no spaces`, `should be at most 160 character(s)`, `is invalid`) · `429 rate_limited` · `401` (membre du jeton inconnu, non confirmé ou en cours de suppression) |
| `GET /api/me/support/requests` | membre | | `200 {"requests":[demande vue du demandeur]}` (50 plus récentes) |
| `GET /api/admin/support/requests` | staff | `?status=open\|answered\|closed&topic=&q=&page=` | page de 20 lignes (`open` : les plus anciennes d'abord ; sinon les plus récentes) ; `q` = préfixe de la référence (et de l'adresse pour un admin). Admin : consultation **auditée** (`accounts.support.listed`) |
| `GET /api/admin/support/requests/:id` | staff | | `200 {"request": détail}`, consultation **auditée avant la réponse** (`accounts.support.viewed`, `metadata.topic`) · `404` |
| `POST /api/admin/support/requests/:id/replies` | staff | `{body}` (2 à 5 000 caractères, sans caractère de contrôle) | `201 {"request": détail}` : réponse enregistrée, statut `answered`, audit `accounts.support.replied` (`reply_id`, `length`) dans la transaction, puis e-mail au demandeur (`email_status` dit si le Mailer l'a accepté) et, pour un membre, notification in-app · `409 closed` · `422` · `404` |
| `PATCH /api/admin/support/requests/:id` | staff | `{status?, internal_note?}` (note ≤ 4 000 caractères, vide = effacée) | `200 {"request": détail}` ; chaque changement réel est audité (`accounts.support.status_changed` `{from,to}`, `accounts.support.note_updated` `{length}`) ; `closed` date la clôture (rétention), une réouverture l'efface · `422` · `404` |
| `DELETE /api/admin/support/requests/:id` | **admin** | | `204` : la demande et ses réponses sont effacées aussitôt (par exemple à la demande d'un visiteur, qui n'a pas de compte à supprimer), audit `accounts.support.deleted` (sujet, référence : jamais le texte) dans la transaction · `403` pour un modérateur · `404` |

Un membre (rôle `user`) reçoit `403 forbidden` sur toutes les routes `/api/admin/support/*` ; sans jeton valide `401`.

## Règles (font foi)
- **Validation** côté accounts : texte normalisé (retours à la ligne, espaces de bord), caractères de contrôle refusés
  (catégorie Cc sauf tabulation et retours à la ligne) ainsi que les contrôles bidirectionnels (U+202A–U+202E,
  U+2066–U+2069) ; adresse normalisée comme à l'inscription.
- **Limites de débit** (fenêtre glissante de 24 h en base, verrou consultatif ; `config :accounts, :support_limits`) :
  **5 demandes par compte** (membre) et **3 par adresse cible** saisie par un visiteur. La clé de la limite par adresse
  est un HMAC de l'adresse (secret interne) : aucune adresse n'est écrite en clair dans `throttle_events`. Un membre
  n'est pas soumis à la limite par adresse (il ne choisit pas l'adresse : celle de son compte, vérifiée) : sinon un
  visiteur pourrait le priver du support en saisissant son adresse. La limite **par IP** est tenue par web
  (`MysticWeb.RateLimit`, `:contact`, 10 par heure ; 200 en dev), qui ne transmet ni ne stocke l'IP.
- **Accusé de réception** : référence, sujet (liste fermée), lien vers l'aide : **jamais le texte soumis** (sinon le
  formulaire relaierait n'importe quel texte vers une adresse arbitraire). **Réponse du staff** : le texte du staff,
  la référence, le lien vers `/contact` ; jamais la demande d'origine. Aucun délai de réponse n'est promis.
- **Notification** : une réponse à un membre crée `account` / `support_replied` (`params.request_id`, clé
  `support_reply:<id>`) par `MlAccounts.Notify` (Oban, durable) ; le centre n'envoie pas d'e-mail (`:producer`, la
  réponse est déjà partie). web la mène à `/contact#request-<id>`.
- **Champ piège** (anti-robot) : tenu par web ; rempli → refus explicite, rien n'est envoyé à accounts.

## Données personnelles et rétention
- **Export** (section `accounts`) : `support_requests[]` du membre (référence, sujet, message, statut, langue, dates,
  réponses, **note interne** : elle le concerne), et `onboarding`.
- **Suppression du compte** : ses demandes et leurs réponses sont supprimées à l'anonymisation (et la clé
  `support_account:<id>` des limites). Les demandes de visiteurs ne sont rattachées à aucun compte.
- **Rétention** (`MlAccounts.Support.PurgeWorker`, cron quotidien 03:23 UTC) : demandes closes depuis plus de
  `SUPPORT_RETENTION_DAYS` jours (180 par défaut), demandes sans activité depuis 365 jours, tentatives comptées par les
  limites du support de plus de 24 h.

## Côté web
- `/contact` (`MysticWeb.ContactLive`, visiteurs et membres) : sujet (`?topic=` le présélectionne), message
  (10–4 000), adresse pour un visiteur (celle du compte, affichée, pour un membre), champ piège hors écran,
  limite par IP ; confirmation avec la référence, « accusé non envoyé » dit tel quel ; erreurs du service à côté des
  champs ; pour un membre, « Your requests » (demandes et réponses, rechargées sur `{:notifications_changed, …}`).
- `/admin/support` et `/admin/support/:id` (`MysticWeb.Admin.SupportLive`, entrée « Support » du rail du staff) :
  rôle vérifié par `MysticWeb.Admin.Guard` au montage et à chaque événement ; liste et détail chargés une fois la
  page connectée (le rendu HTTP initial ne compte pas comme une seconde consultation auditée) ; filtres dans l'URL ;
  réponse (« e-mail sent » / « e-mail not sent ») ; statut et note interne ; pour un admin, « Erase this request »
  (confirmation ; l'événement est refusé par le garde pour un modérateur, avant tout appel).

## Variables d'environnement
`SUPPORT_RETENTION_DAYS` (accounts, défaut `180`).
