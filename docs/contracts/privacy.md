# Données personnelles : export et suppression de compte (contrat)

Coordonné par **accounts** (`MlAccounts.Privacy`, Oban), exécuté par
chaque service qui détient des données de membres. Politique de suppression service par service :
[docs/account-deletion.md](../account-deletion.md). Mêmes règles transverses que `docs/CONTRACTS.md` (JSON, UUID,
ISO 8601 UTC, `{"error": code}`, `422 {"error":"invalid","errors":{…}}`).

## Routes internes des 7 services à données (learning, billing, social, multiplayer, community, studio, notifications)

Jeton interne de **service** (sans utilisateur) ; **appelant `accounts` uniquement** : tout autre appelant
(`web` avec ou sans membre, un autre service) reçoit `403 {"error":"forbidden"}` ; sans jeton valide `401`.
accounts ne les expose pas en HTTP : sa propre section et sa propre anonymisation sont internes (`MlAccounts.Privacy`).

| Méthode & chemin | Entrée | Sortie |
|---|---|---|
| `GET /api/internal/users/:id/export` | | `200 {"data": {…}}` : uniquement les données de ce membre (détail ci-dessous) ; membre inconnu → sections vides · `404 not_found` si `:id` n'est pas un UUID |
| `DELETE /api/internal/users/:id` | | `204` : **idempotent** (rejouer ne change plus rien) · `404` si `:id` n'est pas un UUID · `503 {"error": code}` si une dépendance externe manque (studio : `credits_unavailable` ; billing : `provider_error`) : rien n'est perdu, accounts relance |

Contenu de `data` (clés en snake_case) :
- **learning** : `xp_total`, `level`, `streak_days`, `enrollments[]` (aventure, dates, dernière leçon), `lesson_progress[]`
  (statut, essais, **notes**, **brouillons**), `xp_events[]` (`ref_key`, `amount`), `badges[]` (équipés ou non),
  `authored_adventures[]` (aventures publiées depuis le studio), `offline_actions[]` (reçus des actions
  synchronisées depuis les leçons hors ligne : clé, leçon, action, résultat rendu, date ; jamais la réponse envoyée,
  [offline](offline.md)). Les copies hors ligne elles-mêmes ne sont pas sur un serveur : elles sont dans le navigateur
  du membre (effacées à la déconnexion).
- **billing** : `entitlements`, `subscription` (formule, statut, fournisseur, période), `invoices[]`, `checkouts[]`,
  `credits.account` et `credits.ledger[]` (registre complet).
- **social** : `friends[]` (`user_id` + `username` publics), `friend_requests[]` (`sent|received`), `blocks[]` (posés par
  le membre), `settings` (réglages de confidentialité), `conversations[]` (`kind` `direct|group`, `with_user_id` ou `name`,
  `role` `owner|member`, `joined_at`, `last_read_at`, `muted_until`), `messages_sent[]` (`kind`, `body`, `system`,
  `attachment_id`) (**jamais les messages des autres participants**), `attachments_sent[]` (ses pièces jointes :
  métadonnées, texte alternatif, statut antivirus et contenu `data_base64` ; jamais celles des autres),
  `reports_filed[]` (sans l'instantané du message signalé).
- **multiplayer** : `lobbies[]`, `hosted_lobbies[]`, `messages_sent[]` (ses messages de chat seulement), `matches[]`,
  `attempts[]` (ses tentatives : jamais le secret ni les indices du journal), `rewards[]`, `invites[]`, `links_created[]`.
- **community** : `discussions[]`, `replies[]` (tous statuts, motif de modération), `votes[]`, `follows[]`,
  `reports_filed[]` (sans l'instantané), `moderation_actions[]` (s'il est modérateur).
- **studio** : `ai_settings`, `projects[]` (projets possédés, avec leur contenu, images (métadonnées), collaborateurs et
  versions), `collaborations[]` (projets partagés avec lui : id, titre, rôle), `generations[]` (brief et résultat),
  `images_uploaded[]`.
- **notifications** : `notifications[]` reçues par le membre (`category`, `kind`, `actor_id`, `subject`,
  `params`, `count`, `read_at`, `created_at`, `updated_at` : jamais celles des autres membres), `settings` (`channels`,
  `quiet_hours` avec son fuseau), `pending_emails[]` (e-mails reportés : `category`, `kind`, `inserted_at`). Aucune
  adresse e-mail n'y est jamais stockée.

## accounts : routes du membre connecté (jeton interne portant le membre, appelées par web)

Forme d'un export : `{"id","status":"pending|ready|failed|expired","failed_services":[service],"inserted_at","completed_at","expires_at"}`.
L'utilisateur privé (`POST /api/sessions`, `GET /api/sessions/current`, `PATCH /api/me`…) gagne
`"deletion_scheduled_at": iso|null`.

| Méthode & chemin | Entrée | Sortie |
|---|---|---|
| `POST /api/me/exports` | `{password}` | `202 {"id","status":"pending"}` · `401 invalid_credentials` · `429 locked` (compteur commun du mot de passe actuel) · `429 rate_limited` (3 demandes / 24 h) |
| `GET /api/me/exports` | | `200 {"exports":[export]}` (les siens seulement, le plus récent d'abord) |
| `GET /api/me/exports/:id/download` | | `200` document `{"format":"mysticlore-export/1","user_id","requested_at","generated_at","expires_at","services":{"accounts":{…},"learning":{…},…}}` · `404 not_found` (inconnu, mal formé, **export d'un autre membre**) · `409 not_ready` (`pending`, `failed`) · `410 expired` |
| `POST /api/me/deletion` | `{password, confirm_username}` | `200 {"deletion_scheduled_at": iso}` (J+`ACCOUNT_DELETION_GRACE_DAYS`, 30 par défaut ; déjà programmée → même date, sans effet) · `401` · `429 locked` · `422` (`confirm_username` : `does not match your username`) |
| `DELETE /api/me/deletion` | | `204` (annulée) · `404 not_found` (rien de programmé) · `409 deletion_in_progress` (échéance passée) |
| `POST /api/sessions` (**modifié**) | | pendant le délai : inchangé (`201`, l'utilisateur porte `deletion_scheduled_at`) · échéance passée : `403 {"error":"account_deleted"}` (mot de passe correct) · compte anonymisé : `401 invalid_credentials` |

Échéance passée (suppression en cours) : `GET /api/sessions/current` → `401`, et toute route « utilisateur » → `401`.
Compte anonymisé : `GET /api/users?ids=` → `{"id","username":"deleted_<16 hex>","display_name":"Deleted member","avatar":null}` ;
`GET /api/users/by-username/:u` → `404` (ancien comme nouveau pseudonyme) ; exclu de `GET /api/users/search`.
Les pseudonymes `deleted_…` et les adresses `…@deleted.invalid` sont réservés (`422 is reserved` à l'inscription).

## Règles (font foi)
**Export** : mot de passe exigé (réauthentification ; échecs comptés avec ceux du mot de passe actuel), puis quota de
3 demandes par 24 h (fenêtre glissante en base, `throttle_events`, clé `export:<id>`). Une tâche Oban `ExportWorker`
(file `privacy`) assemble la section `accounts` (profil avec e-mail, pronoms, centres d'intérêt, couverture, visibilité
et avatar (blason, ou image téléversée en Base64 avec son type), préférences, état 2FA sans secret, sessions avec appareil
et IP anonymisée, suppression programmée, sanctions, et l'état de l'accueil guidé (`onboarding`)
et les demandes de support du membre (`support_requests` : message, statut, réponses du staff sans son identité, note
interne : voir [support](support.md))) puis appelle les 7 services. Fin de l'export (prêt ou échoué) :
notification in-app `export_ready` / `export_failed` (catégorie `account`). Un service injoignable ou en erreur est redemandé
**seul** aux essais suivants (les sections obtenues sont gardées) : 6 essais, backoff borné 15 s → 4 min ; au-delà,
`failed` avec `failed_services`. Terminé (`ready` ou `failed`) : `expires_at` = +24 h ; le balayage (cron `*/5`) purge
les exports expirés. Le document n'est servi qu'à son propriétaire (`404` sinon : pas d'IDOR).
**Événement** : `"user:<id>"` → `{:data_export_changed, user_id}` à chaque changement d'état (web recharge la liste).

**Suppression** : programmée avec le mot de passe et le pseudonyme exacts : `deletion_scheduled_at` = maintenant +
`ACCOUNT_DELETION_GRACE_DAYS` jours ; toutes les sessions et challenges 2FA sont supprimés, `{:sessions_revoked, id}`
est publié sur `"user:<id>"`, un e-mail donne la date et le moyen d'annuler. Jusqu'à l'échéance, le membre se reconnecte
normalement et peut annuler. À l'échéance : connexion refusée (`403 account_deleted`), sessions refusées, annulation
impossible.
**social** (étape `social` de l'exécuteur, idempotente) : les fichiers des pièces jointes du membre sont effacés de
`SOCIAL_STORAGE_DIR` après l'écriture en base (`erased_at` posé, nom, texte alternatif et clé retirés : le fil des autres
garde la place du message, « pièce jointe supprimée », et le téléchargement répond `404`) ; il quitte chacun de ses groupes
(propriété transférée au plus ancien, groupe vide supprimé avec ses fichiers) ; amitiés, demandes, blocages (deux sens),
réglages et appartenances sont supprimés ; ses messages restent, signés « Deleted member ».

**Exécuteur** : le balayage (cron `*/5 * * * *`, `SweepWorker`) met en file un `DeletionWorker` par membre dû (tâche
**unique** par membre tant qu'elle n'est pas terminée ; 20 essais, backoff 30 s → 1 h ; le balayage en recrée une
ensuite). Il coupe à nouveau les sessions, puis appelle `DELETE /api/internal/users/:id` dans l'ordre
**multiplayer → studio → community → social → billing → learning → notifications** (d'abord les services qui écrivent
chez les autres : récompenses d'XP, imports d'aventures, réservations de crédits ; le centre de notifications en
dernier, quand plus aucune étape ne peut lui en créer). Chaque succès est enregistré dans `deletion_steps`
(`user_id, service`) et **jamais rejoué** ; le premier échec arrête la passe (relance ultérieure à partir de là). Quand
les 7 étapes ont réussi : **anonymisation** en une transaction : e-mail `deleted-<id>@deleted.invalid`, pseudonyme
`deleted_<16 derniers hex de l'id>`, nom affiché « Deleted member », bio, pronoms, centres d'intérêt, couverture et avatar
effacés, visibilité et préférences par défaut, rôle `user`, mot de passe remplacé par
le hachage bcrypt d'un secret aléatoire jeté (inutilisable), secrets 2FA, codes de récupération, challenges, sessions,
jetons, exports, demandes de support et leurs réponses, compteurs et échecs de connexion supprimés, `deleted_at` posé, étape `accounts` enregistrée ; après
l'écriture en base, le fichier de l'avatar téléversé est supprimé de `ACCOUNTS_STORAGE_DIR` (une image remplacée,
réinitialisée ou retirée l'est aussi dès le changement).
**notifications** (étape `notifications`, idempotente, la dernière avant accounts) : notifications reçues, réglages,
e-mails reportés, journal des e-mails, occurrences et marques de lecture supprimés, tâches d'e-mail et de résumé en
attente annulées ; les notifications dont il est l'acteur, reçues par d'autres, restent chez leurs destinataires et
s'affichent « Deleted member ».
**Déclenchement manuel en dev** : `MlAccounts.Privacy.enqueue_due_deletions/0` (ou `execute_deletion/1`) par RPC sur le
nœud accounts (voir `e2e/privacy_smoke.exs`).

## Côté web
`/settings/data` (section **Privacy & data**, avec la visibilité du profil et son aperçu : voir
[accounts-profile](accounts-profile.md)) → **Your data** (`MysticWeb.PrivacyComponents`) : demande d'export (mot de passe), liste des exports
avec statut (mise à jour en temps réel sur `{:data_export_changed, _}` + bouton Refresh), téléchargement par
`GET /settings/exports/:id/download` (contrôleur `MysticWeb.Privacy.ExportController` : membre de la session, proxy du
document d'accounts avec `content-disposition: attachment; filename="mysticlore-data-<date>.json"` et
`cache-control: no-store` ; export d'un autre membre, expiré ou pas prêt → retour à `/settings/data` avec un message) ;
**Delete my account** : ce qui est supprimé, conservé sous « Deleted member », et la facturation ; mot de passe +
pseudonyme ; succès → `/login` avec la date. Pendant le délai : bannière avec la date et **Cancel deletion** sur
`/dashboard` et `/settings` (`DELETE /api/me/deletion`, puis rechargement du membre). Connexion pendant une suppression
en cours : message dédié (`403 account_deleted`).

## Variables d'environnement
`ACCOUNT_DELETION_GRACE_DAYS` (accounts, défaut `30`) · `ACCOUNTS_STORAGE_DIR` (accounts : avatars téléversés) ·
`SOCIAL_STORAGE_DIR` (social : pièces jointes des messages). accounts lit chaque section avec un délai de 30 s (la section
social porte les fichiers en Base64).

Vérifié par `e2e/privacy_smoke.exs` : la pièce jointe de A figure (contenu PNG) dans son export, puis, après la suppression,
le message reste chez B avec `available: false` et le téléchargement répond `404`.
